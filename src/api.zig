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
    if (s.len == 0 or s[0] != '/') return null;
    if (std.mem.indexOfAny(u8, s, "?#")) |cut| s = s[0..cut];
    return s;
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
    // Bare `fetch("path")` / `axios("path")`.
    if (identEql(toks, source, i, "fetch") or identEql(toks, source, i, "axios")) {
        if (isPunct(toks, source, i + 1, '(')) {
            if (stringPath(toks, source, i + 2)) |p| return .{ .method = "GET", .path = p };
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
