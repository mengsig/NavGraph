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
/// `?query`/`#fragment`. Returns null when there is no path component.
fn pathOf(raw: []const u8) ?[]const u8 {
    var s = raw;
    if (std.mem.indexOf(u8, s, "://")) |p| {
        const rest = s[p + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
        s = rest[slash..];
    }
    // An empty path is valid: a collection route `@router.post("")` mounts at its
    // router's prefix root (FastAPI/Flask); the prefix is applied by the parser.
    if (s.len == 0) return s;
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
