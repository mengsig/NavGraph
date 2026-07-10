//! Cross-language API linking: recognize HTTP route definitions (FastAPI/Flask
//! decorators, Express `app.get(...)`) and HTTP client calls (`fetch`, `axios`,
//! `requests`) from the shared token stream, and match a client call's path to
//! a route's path pattern. This is what lets NavGraph draw an edge from a
//! frontend `fetch("/users/1")` to the backend route that serves it.
//!
//! Everything here is pure (no allocation, no parser/graph dependency): the
//! `parser` wires the recognizers into symbol emission and `index` uses the
//! matchers to resolve `route_call` references across files and languages.

const std = @import("std");
const lexer = @import("lexer.zig");

const Token = lexer.Token;

/// A recognized endpoint: an HTTP method ("GET".."DELETE" or "ANY") and a
/// URL path that always begins with '/'.
pub const Endpoint = struct {
    method: []const u8,
    path: []const u8,
};

/// A recognized route definition, plus token positions for the parser to build
/// a route symbol and find its handler.
pub const RouteDef = struct {
    endpoint: Endpoint,
    /// Token index of the receiver (start of the call), for span/line.
    recv_i: u32,
    /// Token index of the `(` opening the route call's argument list.
    open_i: u32,
};

// Receiver identifiers that denote a server/router (route definition) vs an
// HTTP client. Kept small and explicit to avoid false positives; the decorator
// form (`@x.get(...)`) is accepted regardless of receiver name.
const router_receivers = std.StaticStringMap(void).initComptime(.{
    .{"app"},        .{"router"}, .{"server"}, .{"blueprint"},
    .{"bp"},         .{"application"},
});
const client_receivers = std.StaticStringMap(void).initComptime(.{
    .{"axios"},  .{"http"},   .{"https"},    .{"client"}, .{"api"},
    .{"request"},.{"requests"},.{"session"}, .{"httpx"},  .{"ky"},
    .{"got"},    .{"superagent"},
});

/// Map a route/client verb to an HTTP method string, or null if not a verb.
fn verbMethod(verb: []const u8) ?[]const u8 {
    const map = .{
        .{ "get", "GET" },     .{ "post", "POST" }, .{ "put", "PUT" },
        .{ "patch", "PATCH" }, .{ "delete", "DELETE" },
        .{ "route", "ANY" },   .{ "use", "ANY" },   .{ "all", "ANY" },
    };
    inline for (map) |e| if (std.mem.eql(u8, verb, e[0])) return e[1];
    return null;
}

/// Canonical uppercase HTTP method for a case-insensitive verb literal
/// (`"post"`, `"POST"`), or null when it is not a recognized method.
fn canonMethod(verb: []const u8) ?[]const u8 {
    const map = .{
        .{ "get", "GET" },     .{ "post", "POST" },    .{ "put", "PUT" },
        .{ "patch", "PATCH" }, .{ "delete", "DELETE" }, .{ "head", "HEAD" },
        .{ "options", "OPTIONS" },
    };
    inline for (map) |e| if (std.ascii.eqlIgnoreCase(verb, e[0])) return e[1];
    return null;
}

/// The HTTP method of a `fetch`/`axios` call whose args open at `open_i`,
/// honouring an inline options object `{ method: "POST" }`; `default_method`
/// (GET) when no such option is present. Scans a bounded window and stops at the
/// call's own matching close paren so a later sibling call can't leak in.
fn clientMethodOverride(toks: []const Token, source: []const u8, open_i: u32, default_method: []const u8) []const u8 {
    if (!isPunct(toks, source, open_i, '(')) return default_method;
    var depth: i32 = 0;
    var j = open_i;
    const limit = @min(@as(u32, @intCast(toks.len)), open_i + 64);
    while (j < limit) : (j += 1) {
        if (isPunct(toks, source, j, '(') or isPunct(toks, source, j, '{') or isPunct(toks, source, j, '[')) {
            depth += 1;
        } else if (isPunct(toks, source, j, ')') or isPunct(toks, source, j, '}') or isPunct(toks, source, j, ']')) {
            depth -= 1;
            if (depth <= 0) break;
        } else if (identEql(toks, source, j, "method") and isPunct(toks, source, j + 1, ':') and
            j + 2 < toks.len and toks[j + 2].kind == .string)
        {
            if (canonMethod(stripQuotes(toks[j + 2].text(source)))) |m| return m;
        }
    }
    return default_method;
}

fn isPunct(toks: []const Token, source: []const u8, i: u32, c: u8) bool {
    return i < toks.len and toks[i].kind == .punct and source[toks[i].start] == c;
}

fn isIdent(toks: []const Token, i: u32) bool {
    return i < toks.len and toks[i].kind == .identifier;
}

fn identEql(toks: []const Token, source: []const u8, i: u32, name: []const u8) bool {
    return isIdent(toks, i) and std.mem.eql(u8, toks[i].text(source), name);
}

/// The path of a string-literal token at `i`, normalized to start at '/'
/// (URLs are reduced to their path, query/fragment stripped). Null if the token
/// is not a string or has no usable path.
fn stringPath(toks: []const Token, source: []const u8, i: u32) ?[]const u8 {
    if (i >= toks.len or toks[i].kind != .string) return null;
    return pathOf(stripQuotes(toks[i].text(source)));
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    const q = s[0];
    if ((q == '"' or q == '\'' or q == '`') and s[s.len - 1] == q) return s[1 .. s.len - 1];
    return s;
}

/// Extract a leading-'/' path from a raw literal, dropping scheme+host and any
/// `?query`/`#fragment`. A leading JS template interpolation is treated as a
/// base-URL prefix and skipped: `${API_BASE}/logs` → `/logs`. Returns null when
/// there is no literal path (a fully-dynamic URL like `${BASE}${path}`, a bare
/// variable, or a relative string).
fn pathOf(raw: []const u8) ?[]const u8 {
    var s = raw;
    if (std.mem.indexOf(u8, s, "://")) |p| {
        const rest = s[p + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        s = rest[slash..];
    }
    // Skip leading `${…}` interpolations — a base-URL prefix like `${API_BASE}`
    // added by a client wrapper. After skipping, an empty/non-`/` remainder means
    // the URL is fully dynamic (no literal path to match on).
    var skipped_interp = false;
    while (s.len >= 2 and s[0] == '$' and s[1] == '{') {
        const close = std.mem.indexOfScalar(u8, s, '}') orelse return null;
        s = s[close + 1 ..];
        skipped_interp = true;
    }
    // An empty path is valid ONLY when the literal was genuinely empty (a
    // collection route `@router.post("")` at its router's prefix root) — not when
    // it emptied out after dropping a `${…}` prefix.
    if (s.len == 0) return if (skipped_interp) null else s;
    if (s[0] != '/') return null;
    if (std.mem.indexOfAny(u8, s, "?#")) |cut| s = s[0..cut];
    return s;
}

/// A router variable declaration that carries a URL prefix, e.g.
/// `admin_router = APIRouter(prefix="/api/admin")` or a Flask
/// `bp = Blueprint("admin", __name__, url_prefix="/admin")`. Routes hung off
/// `name` mount under `prefix`.
pub const RouterDecl = struct {
    name: []const u8,
    prefix: []const u8,
};

/// Router constructors whose keyword argument sets a mount prefix.
fn prefixKeyword(ctor: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ctor, "APIRouter") or std.mem.eql(u8, ctor, "Router")) return "prefix";
    if (std.mem.eql(u8, ctor, "Blueprint")) return "url_prefix";
    return null;
}

/// At token `i`, recognize `name = Ctor( ... <kw>="/prefix" ... )` where `Ctor`
/// is a router constructor. Returns the bound name and its prefix path, or null.
pub fn matchRouterDecl(toks: []const Token, source: []const u8, i: u32) ?RouterDecl {
    if (!isIdent(toks, i) or i + 3 >= toks.len) return null;
    if (!isPunct(toks, source, i + 1, '=') or !isIdent(toks, i + 2)) return null;
    const kw = prefixKeyword(toks[i + 2].text(source)) orelse return null;
    if (!isPunct(toks, source, i + 3, '(')) return null;
    // Scan a bounded window of the argument list for `<kw> = "/path"`.
    var j = i + 4;
    const limit = @min(@as(u32, @intCast(toks.len)), i + 4 + 48);
    while (j + 2 < limit) : (j += 1) {
        if (isPunct(toks, source, j, ')')) break;
        if (!identEql(toks, source, j, kw)) continue;
        if (!isPunct(toks, source, j + 1, '=')) continue;
        const prefix = stringPath(toks, source, j + 2) orelse return null;
        return .{ .name = toks[i].text(source), .prefix = prefix };
    }
    return null;
}

/// A recognized router-mount call: `<recv>.include_router(<router>, prefix="/x")`.
/// `module` is the receiver-module of a dotted router argument (`orders.router` →
/// "orders"), or "" for a bare argument (`router`, `orders_router`). `router` is
/// the bare last identifier. `prefix` is the mount prefix path.
pub const RouterMount = struct {
    module: []const u8,
    router: []const u8,
    prefix: []const u8,
};

/// At token `i`, recognize a FastAPI-style mount `recv.include_router(arg, ...,
/// prefix="/x", ...)`. Returns null unless a `prefix="/path"` argument is present
/// (a mount with no prefix changes no route path, so there is nothing to record).
pub fn matchIncludeRouter(toks: []const Token, source: []const u8, i: u32) ?RouterMount {
    if (!isIdent(toks, i) or i + 4 >= toks.len) return null;
    if (!isPunct(toks, source, i + 1, '.') or !identEql(toks, source, i + 2, "include_router")) return null;
    if (!isPunct(toks, source, i + 3, '(')) return null;
    if (!isIdent(toks, i + 4)) return null;
    var module: []const u8 = "";
    var router = toks[i + 4].text(source);
    if (isPunct(toks, source, i + 5, '.') and isIdent(toks, i + 6)) {
        module = toks[i + 4].text(source);
        router = toks[i + 6].text(source);
    }
    // Scan a bounded window of the argument list for `prefix = "/path"`.
    var j = i + 5;
    const limit = @min(@as(u32, @intCast(toks.len)), i + 5 + 64);
    var depth: i32 = 1; // the include_router '(' is already open
    while (j < limit) : (j += 1) {
        if (isPunct(toks, source, j, '(') or isPunct(toks, source, j, '[') or isPunct(toks, source, j, '{')) {
            depth += 1;
        } else if (isPunct(toks, source, j, ')') or isPunct(toks, source, j, ']') or isPunct(toks, source, j, '}')) {
            depth -= 1;
            if (depth <= 0) break;
        } else if (depth == 1 and identEql(toks, source, j, "prefix") and isPunct(toks, source, j + 1, '=')) {
            const prefix = stringPath(toks, source, j + 2) orelse return null;
            if (prefix.len == 0) return null;
            return .{ .module = module, .router = router, .prefix = prefix };
        }
    }
    return null;
}

/// At token `i`, recognize a route definition `recv.verb("path", ...)`, either
/// decorator-form (`@recv.verb(...)`) or a router receiver. Null otherwise.
pub fn matchRouteDef(toks: []const Token, source: []const u8, i: u32) ?RouteDef {
    if (!isIdent(toks, i) or i + 4 >= toks.len) return null;
    if (!isPunct(toks, source, i + 1, '.') or !isIdent(toks, i + 2)) return null;
    const method = verbMethod(toks[i + 2].text(source)) orelse return null;
    if (!isPunct(toks, source, i + 3, '(')) return null;
    const path = stringPath(toks, source, i + 4) orelse return null;

    // A decorator may be glued to the receiver (`@app` is one identifier in the
    // Python lexer) or be a separate `@` punct token before it.
    const recv = toks[i].text(source);
    const bare = if (recv.len != 0 and recv[0] == '@') recv[1..] else recv;
    const decorated = recv.len != 0 and recv[0] == '@' or (i >= 1 and isPunct(toks, source, i - 1, '@'));
    if (!decorated and !router_receivers.has(bare)) return null;
    return .{ .endpoint = .{ .method = method, .path = path }, .recv_i = i, .open_i = i + 3 };
}

/// At token `i`, recognize an HTTP client call: `fetch("path")`, `axios("path")`,
/// or `client.verb("path")` for a known client receiver. Null otherwise.
pub fn matchClientCall(toks: []const Token, source: []const u8, i: u32) ?Endpoint {
    if (!isIdent(toks, i)) return null;
    // Bare `fetch("path")` / `axios("path")`. The method defaults to GET but is
    // overridden by an inline `{ method: "POST" }` options argument, so a
    // `fetch("/x", { method: "POST" })` links to the POST route, not the GET one.
    if (identEql(toks, source, i, "fetch") or identEql(toks, source, i, "axios")) {
        if (isPunct(toks, source, i + 1, '(')) {
            if (stringPath(toks, source, i + 2)) |p|
                return .{ .method = clientMethodOverride(toks, source, i + 1, "GET"), .path = p };
        }
    }
    // `recv.verb("path")` for a known client receiver.
    if (i + 4 >= toks.len) return null;
    if (!client_receivers.has(toks[i].text(source))) return null;
    if (!isPunct(toks, source, i + 1, '.') or !isIdent(toks, i + 2)) return null;
    const method = verbMethod(toks[i + 2].text(source)) orelse return null;
    if (!isPunct(toks, source, i + 3, '(')) return null;
    const path = stringPath(toks, source, i + 4) orelse return null;
    return .{ .method = method, .path = path };
}

/// True at token `i` for a bare `fetch(...)`/`axios(...)` whose URL argument has
/// no literal path — a fully-dynamic URL (`` `${BASE}${path}` ``) or a bare
/// variable. This is the signature of a request-wrapper's own fetch: the real
/// path is supplied by the wrapper's callers, so the enclosing function is a
/// wrapper rather than a direct client call.
pub fn isDynamicFetch(toks: []const Token, source: []const u8, i: u32) bool {
    if (!identEql(toks, source, i, "fetch") and !identEql(toks, source, i, "axios")) return false;
    if (!isPunct(toks, source, i + 1, '(')) return false;
    return stringPath(toks, source, i + 2) == null;
}

/// At token `i`, recognize a call to a known request-wrapper function
/// (`request("/x", { method: "POST" })`). The wrapper forwards its path argument
/// to `fetch`, so the call is effectively a client call to that path; the method
/// comes from an inline `{ method: … }` options argument (default GET). Only a
/// literal path argument links — a variable path stays unresolved.
pub fn matchWrapperCall(
    toks: []const Token,
    source: []const u8,
    i: u32,
    wrappers: *const std.StringHashMap(void),
) ?Endpoint {
    if (!isIdent(toks, i) or i + 2 >= toks.len) return null;
    if (!wrappers.contains(toks[i].text(source))) return null;
    if (!isPunct(toks, source, i + 1, '(')) return null;
    const path = stringPath(toks, source, i + 2) orelse return null;
    return .{ .method = clientMethodOverride(toks, source, i + 1, "GET"), .path = path };
}

/// A route/client key is "METHOD /path"; split it back into its parts.
pub fn splitKey(name: []const u8) ?Endpoint {
    const sp = std.mem.indexOfScalar(u8, name, ' ') orelse return null;
    return .{ .method = name[0..sp], .path = name[sp + 1 ..] };
}

/// Methods match when equal or either side is the wildcard "ANY".
pub fn methodsMatch(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or std.mem.eql(u8, a, "ANY") or std.mem.eql(u8, b, "ANY");
}

/// Whether a client path matches a route path pattern, segment by segment.
/// A path parameter (`{id}`, `:id`, `<int:id>`), a template interpolation
/// (`${x}`, `{x}`), a printf placeholder, or a bare numeric id acts as a
/// wildcard that matches any single segment.
pub fn pathsMatch(route: []const u8, client: []const u8) bool {
    var r = std.mem.tokenizeScalar(u8, trimSlash(route), '/');
    var c = std.mem.tokenizeScalar(u8, trimSlash(client), '/');
    while (true) {
        const rs = r.next();
        const cs = c.next();
        if (rs == null and cs == null) return true;
        if (rs == null or cs == null) return false;
        if (isWildcardSeg(rs.?) or isWildcardSeg(cs.?)) continue;
        if (!std.mem.eql(u8, rs.?, cs.?)) return false;
    }
}

fn trimSlash(s: []const u8) []const u8 {
    var out = s;
    while (out.len > 1 and out[out.len - 1] == '/') out = out[0 .. out.len - 1];
    return out;
}

fn isWildcardSeg(seg: []const u8) bool {
    if (seg.len == 0) return false;
    if (seg[0] == ':' or seg[0] == '{' or seg[0] == '<' or seg[0] == '*') return true;
    if (std.mem.indexOfAny(u8, seg, "${}%<") != null) return true;
    for (seg) |ch| if (ch < '0' or ch > '9') return false;
    return true; // all digits: a concrete id
}

test "route and client recognition + path matching" {
    const t = std.testing;
    try t.expect(pathsMatch("/users/{id}", "/users/123"));
    try t.expect(pathsMatch("/users/:id/posts", "/users/${u}/posts"));
    try t.expect(!pathsMatch("/users/{id}", "/users/1/posts"));
    try t.expect(!pathsMatch("/users", "/accounts"));
    try t.expect(methodsMatch("ANY", "GET"));
    try t.expect(!methodsMatch("POST", "GET"));

    const key = splitKey("GET /a/b").?;
    try t.expectEqualStrings("GET", key.method);
    try t.expectEqualStrings("/a/b", key.path);

    try t.expectEqualStrings("/users", pathOf("https://api.example.com/users?x=1").?);
    try t.expectEqualStrings("/x", pathOf("/x#frag").?);
    try t.expect(pathOf("relative") == null);
    // A `${BASE}` prefix (a client wrapper's base URL) is skipped to the literal.
    try t.expectEqualStrings("/logs/bundle", pathOf("${BASE}/logs/bundle").?);
    try t.expectEqualStrings("/planning/runs/${id}", pathOf("${API_BASE}/planning/runs/${id}").?);
    // A fully-dynamic URL has no literal path to match on.
    try t.expect(pathOf("${BASE}${path}") == null);
    try t.expect(pathOf("${url}") == null);
    // A genuinely empty route path (`@router.post("")`) stays valid.
    try t.expectEqualStrings("", pathOf("").?);
}

test "request wrapper: dynamic fetch is detected; a call to it resolves the path" {
    const t = std.testing;
    const gpa = t.allocator;
    const cfg = @import("language.zig").configFor(.typescript);
    const src =
        \\async function request(path, opts) { return fetch(`${BASE}${path}`, opts); }
        \\function listThings() { return request("/things"); }
        \\function makeThing() { return request("/things", { method: "POST" }); }
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try lexer.tokenize(gpa, src, cfg, &toks);

    // The wrapper's own `fetch(`${BASE}${path}`)` is dynamic (no literal path).
    var saw_dynamic = false;
    var i: u32 = 0;
    while (i < toks.items.len) : (i += 1) {
        if (isDynamicFetch(toks.items, src, i)) saw_dynamic = true;
    }
    try t.expect(saw_dynamic);

    // With `request` registered as a wrapper, its calls resolve to method+path.
    var wrappers = std.StringHashMap(void).init(gpa);
    defer wrappers.deinit();
    try wrappers.put("request", {});
    var get_ep: ?Endpoint = null;
    var post_ep: ?Endpoint = null;
    i = 0;
    while (i < toks.items.len) : (i += 1) {
        if (matchWrapperCall(toks.items, src, i, &wrappers)) |ep| {
            if (std.mem.eql(u8, ep.method, "POST")) post_ep = ep else get_ep = ep;
        }
    }
    try t.expectEqualStrings("/things", get_ep.?.path);
    try t.expectEqualStrings("GET", get_ep.?.method);
    try t.expectEqualStrings("/things", post_ep.?.path);
    try t.expectEqualStrings("POST", post_ep.?.method);
}

test "router prefix declaration recognized" {
    const t = std.testing;
    const gpa = t.allocator;
    const src = "admin_router = APIRouter(prefix=\"/api/admin\")\n";
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try lexer.tokenize(gpa, src, @import("language.zig").configFor(.python), &toks);

    var found: ?RouterDecl = null;
    var i: u32 = 0;
    while (i < toks.items.len) : (i += 1) {
        if (matchRouterDecl(toks.items, src, i)) |rd| found = rd;
    }
    try t.expect(found != null);
    try t.expectEqualStrings("admin_router", found.?.name);
    try t.expectEqualStrings("/api/admin", found.?.prefix);
}

test "include_router mount recognized (dotted and bare arg)" {
    const t = std.testing;
    const gpa = t.allocator;
    const lang = @import("language.zig");
    const cases = .{
        .{ "app.include_router(orders.router, prefix=\"/v1\")\n", "orders", "router", "/v1" },
        .{ "app.include_router(router, prefix=\"/api\")\n", "", "router", "/api" },
        .{ "app.include_router(orders_router, tags=[\"o\"], prefix=\"/v2\")\n", "", "orders_router", "/v2" },
    };
    inline for (cases) |c| {
        var toks: std.ArrayList(Token) = .empty;
        defer toks.deinit(gpa);
        try lexer.tokenize(gpa, c[0], lang.configFor(.python), &toks);
        var found: ?RouterMount = null;
        var i: u32 = 0;
        while (i < toks.items.len) : (i += 1) {
            if (matchIncludeRouter(toks.items, c[0], i)) |m| found = m;
        }
        try t.expect(found != null);
        try t.expectEqualStrings(c[1], found.?.module);
        try t.expectEqualStrings(c[2], found.?.router);
        try t.expectEqualStrings(c[3], found.?.prefix);
    }
    // A mount with no prefix is not recorded (nothing to apply).
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    const src = "app.include_router(orders.router)\n";
    try lexer.tokenize(gpa, src, lang.configFor(.python), &toks);
    var i: u32 = 0;
    while (i < toks.items.len) : (i += 1) {
        try t.expect(matchIncludeRouter(toks.items, src, i) == null);
    }
}

test "empty route path is accepted; non-slash relative still rejected" {
    const t = std.testing;
    try t.expectEqualStrings("", pathOf("").?);
    try t.expect(pathOf("relative") == null);
}

fn firstClientCall(src: []const u8) ?Endpoint {
    const gpa = std.testing.allocator;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    lexer.tokenize(gpa, src, @import("language.zig").configFor(.typescript), &toks) catch return null;
    var i: u32 = 0;
    while (i < toks.items.len) : (i += 1) {
        if (matchClientCall(toks.items, src, i)) |ep| return ep;
    }
    return null;
}

test "fetch options object overrides the default GET method" {
    const t = std.testing;
    const post = firstClientCall("fetch('/orders', { method: 'POST' });\n").?;
    try t.expectEqualStrings("POST", post.method);
    try t.expectEqualStrings("/orders", post.path);

    const del = firstClientCall("fetch(`/users/${id}`, { method: 'DELETE' });\n").?;
    try t.expectEqualStrings("DELETE", del.method);

    // No options → still GET.
    const get = firstClientCall("fetch('/orders');\n").?;
    try t.expectEqualStrings("GET", get.method);
}


// ---------------------------------------------------------------------------
// Appended tests for src/api.zig — pure matchers over token slices.
// ---------------------------------------------------------------------------

const api_test_lang = @import("language.zig");

/// Tokenize `src` in `lang` into a fresh ArrayList the caller must deinit.
fn apiTestToks(src: []const u8, lang: api_test_lang.Language) std.ArrayList(Token) {
    const gpa = std.testing.allocator;
    var toks: std.ArrayList(Token) = .empty;
    lexer.tokenize(gpa, src, api_test_lang.configFor(lang), &toks) catch @panic("tokenize failed");
    return toks;
}

/// First route definition recognized scanning every token index, or null.
fn firstRouteDef(src: []const u8, lang: api_test_lang.Language) ?RouteDef {
    var toks = apiTestToks(src, lang);
    defer toks.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < toks.items.len) : (i += 1) {
        if (matchRouteDef(toks.items, src, i)) |rd| return rd;
    }
    return null;
}

/// First router prefix declaration recognized, or null.
fn firstRouterDecl(src: []const u8, lang: api_test_lang.Language) ?RouterDecl {
    var toks = apiTestToks(src, lang);
    defer toks.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < toks.items.len) : (i += 1) {
        if (matchRouterDecl(toks.items, src, i)) |rd| return rd;
    }
    return null;
}

/// First client call recognized in the given language, or null.
fn firstClientCallIn(src: []const u8, lang: api_test_lang.Language) ?Endpoint {
    var toks = apiTestToks(src, lang);
    defer toks.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < toks.items.len) : (i += 1) {
        if (matchClientCall(toks.items, src, i)) |ep| return ep;
    }
    return null;
}

test "verbMethod maps every route/client verb and rejects unknowns" {
    const t = std.testing;
    try t.expectEqualStrings("GET", verbMethod("get").?);
    try t.expectEqualStrings("POST", verbMethod("post").?);
    try t.expectEqualStrings("PUT", verbMethod("put").?);
    try t.expectEqualStrings("PATCH", verbMethod("patch").?);
    try t.expectEqualStrings("DELETE", verbMethod("delete").?);
    // route/use/all are the "match any method" verbs.
    try t.expectEqualStrings("ANY", verbMethod("route").?);
    try t.expectEqualStrings("ANY", verbMethod("use").?);
    try t.expectEqualStrings("ANY", verbMethod("all").?);
    // verbMethod is case-sensitive and only knows this closed set.
    try t.expect(verbMethod("GET") == null);
    try t.expect(verbMethod("head") == null);
    try t.expect(verbMethod("options") == null);
    try t.expect(verbMethod("connect") == null);
    try t.expect(verbMethod("") == null);
}

test "canonMethod is case-insensitive over the HTTP method set" {
    const t = std.testing;
    try t.expectEqualStrings("GET", canonMethod("get").?);
    try t.expectEqualStrings("GET", canonMethod("GET").?);
    try t.expectEqualStrings("GET", canonMethod("Get").?);
    try t.expectEqualStrings("POST", canonMethod("post").?);
    try t.expectEqualStrings("PUT", canonMethod("put").?);
    try t.expectEqualStrings("PATCH", canonMethod("PATCH").?);
    try t.expectEqualStrings("DELETE", canonMethod("delete").?);
    try t.expectEqualStrings("HEAD", canonMethod("head").?);
    try t.expectEqualStrings("OPTIONS", canonMethod("OPTIONS").?);
    // route/use/all are NOT canonical HTTP methods.
    try t.expect(canonMethod("route") == null);
    try t.expect(canonMethod("use") == null);
    try t.expect(canonMethod("all") == null);
    try t.expect(canonMethod("bogus") == null);
    try t.expect(canonMethod("") == null);
}

test "pathOf strips scheme/host, query and fragment" {
    const t = std.testing;
    try t.expectEqualStrings("/users", pathOf("https://api.example.com/users?x=1").?);
    try t.expectEqualStrings("/x", pathOf("/x#frag").?);
    try t.expectEqualStrings("/a/b", pathOf("/a/b?q=1&r=2").?);
    // '#' before '?' still cuts at the first of the two.
    try t.expectEqualStrings("/a", pathOf("/a#f?q").?);
    // A URL with a host but no path becomes the root.
    try t.expectEqualStrings("/", pathOf("http://host").?);
    try t.expectEqualStrings("/", pathOf("https://host/").?);
    try t.expectEqualStrings("/v1/x", pathOf("http://h:8080/v1/x").?);
}

test "pathOf skips one or more leading interpolation prefixes" {
    const t = std.testing;
    try t.expectEqualStrings("/logs/bundle", pathOf("${BASE}/logs/bundle").?);
    try t.expectEqualStrings("/planning/runs/${id}", pathOf("${API_BASE}/planning/runs/${id}").?);
    // Multiple stacked prefixes are all skipped down to the literal path.
    try t.expectEqualStrings("/x", pathOf("${A}${B}/x").?);
    // A fully-dynamic URL (prefix then interpolation) has no literal path.
    try t.expect(pathOf("${BASE}${path}") == null);
    try t.expect(pathOf("${url}") == null);
    // An unterminated interpolation cannot be skipped → null.
    try t.expect(pathOf("${BASE/logs") == null);
}

test "pathOf rejects relative and dotted paths, accepts genuinely empty" {
    const t = std.testing;
    try t.expect(pathOf("relative") == null);
    try t.expect(pathOf("./api") == null);
    try t.expect(pathOf("../up") == null);
    try t.expect(pathOf("api.example.com/users") == null);
    // Genuinely empty literal (a collection route at its router prefix root).
    try t.expectEqualStrings("", pathOf("").?);
}

test "stripQuotes removes matching single/double/backtick delimiters only" {
    const t = std.testing;
    try t.expectEqualStrings("hello", stripQuotes("\"hello\""));
    try t.expectEqualStrings("hello", stripQuotes("'hello'"));
    try t.expectEqualStrings("hello", stripQuotes("`hello`"));
    // Empty quoted string → empty content.
    try t.expectEqualStrings("", stripQuotes("\"\""));
    // No quotes / mismatched delimiters / too short → returned unchanged.
    try t.expectEqualStrings("plain", stripQuotes("plain"));
    try t.expectEqualStrings("\"hello'", stripQuotes("\"hello'"));
    try t.expectEqualStrings("\"", stripQuotes("\""));
    try t.expectEqualStrings("", stripQuotes(""));
}

test "trimSlash drops trailing slashes but preserves root" {
    const t = std.testing;
    try t.expectEqualStrings("/users", trimSlash("/users/"));
    try t.expectEqualStrings("/users", trimSlash("/users///"));
    try t.expectEqualStrings("/", trimSlash("/"));
    try t.expectEqualStrings("users", trimSlash("users"));
    try t.expectEqualStrings("", trimSlash(""));
}

test "isWildcardSeg recognizes every parameter/placeholder form" {
    const t = std.testing;
    try t.expect(isWildcardSeg(":id"));
    try t.expect(isWildcardSeg("{id}"));
    try t.expect(isWildcardSeg("<int:id>"));
    try t.expect(isWildcardSeg("*rest"));
    try t.expect(isWildcardSeg("${x}"));
    try t.expect(isWildcardSeg("%d"));
    try t.expect(isWildcardSeg("id}"));
    // A bare all-digits segment is a concrete id → treated as a wildcard.
    try t.expect(isWildcardSeg("123"));
    try t.expect(isWildcardSeg("007"));
    // Plain literal segments (incl. mixed alnum) are NOT wildcards.
    try t.expect(!isWildcardSeg("users"));
    try t.expect(!isWildcardSeg("user2"));
    try t.expect(!isWildcardSeg("12a"));
    try t.expect(!isWildcardSeg(""));
}

test "pathsMatch treats every wildcard form as a single-segment match" {
    const t = std.testing;
    try t.expect(pathsMatch("/users/{id}", "/users/123"));
    try t.expect(pathsMatch("/users/:id/posts", "/users/${u}/posts"));
    try t.expect(pathsMatch("/users/<int:id>", "/users/5"));
    try t.expect(pathsMatch("/files/%d", "/files/9"));
    // Two concrete numeric ids each act as a wildcard, so they match.
    try t.expect(pathsMatch("/a/1", "/a/2"));
    // Trailing slashes are normalized away before comparing.
    try t.expect(pathsMatch("/users/", "/users"));
    try t.expect(pathsMatch("/", "/"));
    try t.expect(pathsMatch("", ""));
}

test "pathsMatch fails on segment-count or literal mismatch (case-sensitive)" {
    const t = std.testing;
    try t.expect(!pathsMatch("/users/{id}", "/users/1/posts"));
    try t.expect(!pathsMatch("/users", "/accounts"));
    try t.expect(!pathsMatch("/a", "/a/b"));
    try t.expect(!pathsMatch("/a/b", "/a"));
    try t.expect(!pathsMatch("/API", "/api"));
}

test "methodsMatch is exact-or-ANY on either side" {
    const t = std.testing;
    try t.expect(methodsMatch("GET", "GET"));
    try t.expect(methodsMatch("ANY", "GET"));
    try t.expect(methodsMatch("POST", "ANY"));
    try t.expect(methodsMatch("ANY", "ANY"));
    try t.expect(!methodsMatch("POST", "GET"));
    try t.expect(!methodsMatch("GET", "DELETE"));
}

test "splitKey separates method and path at the first space" {
    const t = std.testing;
    const k = splitKey("GET /a/b").?;
    try t.expectEqualStrings("GET", k.method);
    try t.expectEqualStrings("/a/b", k.path);
    const any = splitKey("ANY /users/{id}").?;
    try t.expectEqualStrings("ANY", any.method);
    try t.expectEqualStrings("/users/{id}", any.path);
    // Trailing space → empty path but still a valid split.
    const trailing = splitKey("GET ").?;
    try t.expectEqualStrings("GET", trailing.method);
    try t.expectEqualStrings("", trailing.path);
    // No space at all → no key.
    try t.expect(splitKey("noSpace") == null);
    try t.expect(splitKey("") == null);
}

test "prefixKeyword maps router constructors to their prefix keyword" {
    const t = std.testing;
    try t.expectEqualStrings("prefix", prefixKeyword("APIRouter").?);
    try t.expectEqualStrings("prefix", prefixKeyword("Router").?);
    try t.expectEqualStrings("url_prefix", prefixKeyword("Blueprint").?);
    try t.expect(prefixKeyword("Flask") == null);
    try t.expect(prefixKeyword("FastAPI") == null);
    try t.expect(prefixKeyword("") == null);
}

test "isPunct/isIdent/identEql classify tokens and are bounds-safe" {
    const t = std.testing;
    const src = "foo.bar(x)";
    var toks = apiTestToks(src, .zig);
    defer toks.deinit(std.testing.allocator);
    const items = toks.items;
    // foo(0) .(1) bar(2) ((3) x(4) )(5)
    try t.expect(isIdent(items, 0));
    try t.expect(!isIdent(items, 1));
    try t.expect(isPunct(items, src, 1, '.'));
    try t.expect(!isPunct(items, src, 1, '('));
    try t.expect(isPunct(items, src, 3, '('));
    try t.expect(identEql(items, src, 0, "foo"));
    try t.expect(!identEql(items, src, 0, "bar"));
    try t.expect(identEql(items, src, 2, "bar"));
    // Out-of-range indices never crash and are always false.
    try t.expect(!isIdent(items, 999));
    try t.expect(!isPunct(items, src, 999, '('));
    try t.expect(!identEql(items, src, 999, "x"));
}

test "stringPath resolves string tokens and rejects non-strings/OOB" {
    const t = std.testing;
    {
        const src = "\"/api/v1\"";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(std.testing.allocator);
        try t.expectEqualStrings("/api/v1", stringPath(toks.items, src, 0).?);
        // Index past the end (or at eof) is not a string → null.
        try t.expect(stringPath(toks.items, src, 999) == null);
    }
    {
        // A string with no usable path resolves to null via pathOf.
        const src = "\"relative\"";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(std.testing.allocator);
        try t.expect(stringPath(toks.items, src, 0) == null);
    }
    {
        // An identifier token is not a string → null.
        const src = "foo";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(std.testing.allocator);
        try t.expect(stringPath(toks.items, src, 0) == null);
    }
}

test "clientMethodOverride honours the inline method option for all verbs" {
    const t = std.testing;
    try t.expectEqualStrings("POST", firstClientCall("fetch('/x', { method: 'POST' });\n").?.method);
    try t.expectEqualStrings("PUT", firstClientCall("fetch('/x', { method: 'PUT' });\n").?.method);
    try t.expectEqualStrings("PATCH", firstClientCall("fetch('/x', { method: 'PATCH' });\n").?.method);
    try t.expectEqualStrings("DELETE", firstClientCall("fetch('/x', { method: 'DELETE' });\n").?.method);
    try t.expectEqualStrings("HEAD", firstClientCall("fetch('/x', { method: 'HEAD' });\n").?.method);
    try t.expectEqualStrings("OPTIONS", firstClientCall("fetch('/x', { method: 'OPTIONS' });\n").?.method);
    // The option value is canonicalized case-insensitively.
    try t.expectEqualStrings("DELETE", firstClientCall("fetch('/x', { method: 'delete' });\n").?.method);
}

test "clientMethodOverride falls back to the default method" {
    const t = std.testing;
    // No options object → default GET.
    try t.expectEqualStrings("GET", firstClientCall("fetch('/x');\n").?.method);
    // Options object without a method key → default GET.
    try t.expectEqualStrings("GET", firstClientCall("fetch('/x', { cache: 'no-store' });\n").?.method);
    // An unrecognized method value canonicalizes to null → default GET.
    try t.expectEqualStrings("GET", firstClientCall("fetch('/x', { method: 'TRACE' });\n").?.method);
    // A sibling call's method option after our close-paren must not leak in.
    try t.expectEqualStrings("GET", firstClientCall("fetch('/a', {}); const o = { method: 'POST' };\n").?.method);
}

test "clientMethodOverride returns the passed default when open_i is not '('" {
    const t = std.testing;
    const src = "fetch('/x')";
    var toks = apiTestToks(src, .typescript);
    defer toks.deinit(std.testing.allocator);
    // fetch(0) ((1) '/x'(2) )(3): the '(' is at index 1.
    try t.expectEqualStrings("GET", clientMethodOverride(toks.items, src, 1, "GET"));
    // Pointing at a non-'(' token yields the caller-supplied default verbatim.
    try t.expectEqualStrings("ZZZ", clientMethodOverride(toks.items, src, 0, "ZZZ"));
}

test "matchRouterDecl recognizes APIRouter/Router/Blueprint prefixes" {
    const t = std.testing;
    const api = firstRouterDecl("admin_router = APIRouter(prefix=\"/api/admin\")\n", .python).?;
    try t.expectEqualStrings("admin_router", api.name);
    try t.expectEqualStrings("/api/admin", api.prefix);

    const r = firstRouterDecl("r = Router(prefix=\"/v2\")\n", .python).?;
    try t.expectEqualStrings("r", r.name);
    try t.expectEqualStrings("/v2", r.prefix);

    const bp = firstRouterDecl("bp = Blueprint(\"admin\", __name__, url_prefix=\"/admin\")\n", .python).?;
    try t.expectEqualStrings("bp", bp.name);
    try t.expectEqualStrings("/admin", bp.prefix);
}

test "matchRouterDecl rejects wrong ctor, missing/mismatched kw, and variable prefix" {
    const t = std.testing;
    // Not a router constructor.
    try t.expect(firstRouterDecl("x = Flask(prefix=\"/y\")\n", .python) == null);
    // Router constructor but no prefix keyword argument at all.
    try t.expect(firstRouterDecl("r = APIRouter()\n", .python) == null);
    // Blueprint expects url_prefix, not prefix → not recognized.
    try t.expect(firstRouterDecl("bp = Blueprint(prefix=\"/x\")\n", .python) == null);
    // A non-literal (variable) prefix cannot be resolved.
    try t.expect(firstRouterDecl("r = APIRouter(prefix=BASE)\n", .python) == null);
}

test "matchRouteDef recognizes decorator and router-receiver forms" {
    const t = std.testing;
    const get = firstRouteDef("@app.get(\"/users\")\n", .python).?;
    try t.expectEqualStrings("GET", get.endpoint.method);
    try t.expectEqualStrings("/users", get.endpoint.path);

    const post = firstRouteDef("@router.post(\"/items\")\n", .python).?;
    try t.expectEqualStrings("POST", post.endpoint.method);
    try t.expectEqualStrings("/items", post.endpoint.path);

    // `route` decorator maps to the ANY method.
    const any = firstRouteDef("@app.route(\"/x\")\n", .python).?;
    try t.expectEqualStrings("ANY", any.endpoint.method);

    // Bare (non-decorated) call form on a known router receiver.
    const bare = firstRouteDef("router.get(\"/health\")\n", .python).?;
    try t.expectEqualStrings("GET", bare.endpoint.method);
    try t.expectEqualStrings("/health", bare.endpoint.path);
}

test "matchRouteDef reports recv_i and open_i and rejects unknown receiver / dynamic path" {
    const t = std.testing;
    const src = "router.get(\"/health\")\n";
    var toks = apiTestToks(src, .python);
    defer toks.deinit(std.testing.allocator);
    // router(0) .(1) get(2) ((3) "/health"(4) )(5)
    const rd = matchRouteDef(toks.items, src, 0).?;
    try t.expectEqual(@as(u32, 0), rd.recv_i);
    try t.expectEqual(@as(u32, 3), rd.open_i);
    try t.expect(isPunct(toks.items, src, rd.open_i, '('));

    // A non-router receiver without a decorator is not a route.
    try t.expect(firstRouteDef("foo.get(\"/x\")\n", .python) == null);
    // A dynamic (variable) path argument cannot be matched.
    try t.expect(firstRouteDef("@app.get(url)\n", .python) == null);
}

test "matchRouteDef accepts a decorator emitted as a separate '@' punct token" {
    const t = std.testing;
    // Hand-build the stream so the '@' precedes the receiver as its own punct
    // token (the branch a glued `@app` identifier does not exercise).
    const src = "@app.get(\"/x\")";
    const toks = [_]Token{
        .{ .kind = .punct, .start = 0, .end = 1, .line = 1, .col = 1 }, // @
        .{ .kind = .identifier, .start = 1, .end = 4, .line = 1, .col = 2 }, // app
        .{ .kind = .punct, .start = 4, .end = 5, .line = 1, .col = 5 }, // .
        .{ .kind = .identifier, .start = 5, .end = 8, .line = 1, .col = 6 }, // get
        .{ .kind = .punct, .start = 8, .end = 9, .line = 1, .col = 9 }, // (
        .{ .kind = .string, .start = 9, .end = 13, .line = 1, .col = 10 }, // "/x"
        .{ .kind = .punct, .start = 13, .end = 14, .line = 1, .col = 14 }, // )
    };
    const rd = matchRouteDef(&toks, src, 1).?;
    try t.expectEqualStrings("GET", rd.endpoint.method);
    try t.expectEqualStrings("/x", rd.endpoint.path);
    try t.expectEqual(@as(u32, 1), rd.recv_i);
}

test "matchClientCall recognizes bare fetch/axios and receiver.verb forms" {
    const t = std.testing;
    const f = firstClientCallIn("fetch(\"/users\")", .typescript).?;
    try t.expectEqualStrings("GET", f.method);
    try t.expectEqualStrings("/users", f.path);

    const a = firstClientCallIn("axios(\"/data\")", .typescript).?;
    try t.expectEqualStrings("GET", a.method);
    try t.expectEqualStrings("/data", a.path);

    const ap = firstClientCallIn("axios.post(\"/items\")", .typescript).?;
    try t.expectEqualStrings("POST", ap.method);
    try t.expectEqualStrings("/items", ap.path);

    const cd = firstClientCallIn("client.delete(\"/x\")", .typescript).?;
    try t.expectEqualStrings("DELETE", cd.method);
    try t.expectEqualStrings("/x", cd.path);

    // Python `requests.get(...)` is a recognized client receiver too.
    const rq = firstClientCallIn("requests.get(\"/y\")", .python).?;
    try t.expectEqualStrings("GET", rq.method);
    try t.expectEqualStrings("/y", rq.path);
}

test "matchClientCall rejects unknown receiver, non-verb, and non-literal URL" {
    const t = std.testing;
    // `foo` is neither fetch/axios nor a known client receiver.
    try t.expect(firstClientCallIn("foo.get(\"/x\")", .typescript) == null);
    // Known receiver but the member is not an HTTP verb.
    try t.expect(firstClientCallIn("client.connect(\"/x\")", .typescript) == null);
    // Bare fetch with a variable (non-string) URL argument.
    try t.expect(firstClientCallIn("fetch(url)", .typescript) == null);
}

test "isDynamicFetch flags fetch/axios with no literal path only" {
    const t = std.testing;
    {
        const src = "fetch(`${BASE}${path}`)";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(std.testing.allocator);
        try t.expect(isDynamicFetch(toks.items, src, 0));
    }
    {
        const src = "axios(url)";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(std.testing.allocator);
        try t.expect(isDynamicFetch(toks.items, src, 0));
    }
    {
        // A literal path is NOT dynamic.
        const src = "fetch(\"/x\")";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(std.testing.allocator);
        try t.expect(!isDynamicFetch(toks.items, src, 0));
    }
    {
        // Not a fetch/axios identifier.
        const src = "foo(bar)";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(std.testing.allocator);
        try t.expect(!isDynamicFetch(toks.items, src, 0));
    }
    {
        // fetch not immediately followed by '(' is not a call.
        const src = "fetch;";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(std.testing.allocator);
        try t.expect(!isDynamicFetch(toks.items, src, 0));
    }
}

test "matchWrapperCall resolves registered wrappers and rejects the rest" {
    const t = std.testing;
    const gpa = std.testing.allocator;
    var wrappers = std.StringHashMap(void).init(gpa);
    defer wrappers.deinit();
    try wrappers.put("request", {});

    // Registered wrapper with a literal path → GET by default.
    {
        const src = "request(\"/things\")";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(gpa);
        const ep = matchWrapperCall(toks.items, src, 0, &wrappers).?;
        try t.expectEqualStrings("GET", ep.method);
        try t.expectEqualStrings("/things", ep.path);
    }
    // Registered wrapper with an inline method option → that method.
    {
        const src = "request(\"/things\", { method: \"POST\" })";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(gpa);
        const ep = matchWrapperCall(toks.items, src, 0, &wrappers).?;
        try t.expectEqualStrings("POST", ep.method);
        try t.expectEqualStrings("/things", ep.path);
    }
    // An unregistered identifier is not a wrapper call.
    {
        const src = "notWrapper(\"/x\")";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(gpa);
        try t.expect(matchWrapperCall(toks.items, src, 0, &wrappers) == null);
    }
    // Registered wrapper but a variable (non-literal) path stays unresolved.
    {
        const src = "request(path)";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(gpa);
        try t.expect(matchWrapperCall(toks.items, src, 0, &wrappers) == null);
    }
    // Registered wrapper not followed by '(' is not a call.
    {
        const src = "request;";
        var toks = apiTestToks(src, .typescript);
        defer toks.deinit(gpa);
        try t.expect(matchWrapperCall(toks.items, src, 0, &wrappers) == null);
    }
}
