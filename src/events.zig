//! Detects string-keyed message dispatch — the event/WebSocket bus that the
//! HTTP-oriented `routes` view is blind to. One side *registers* a handler for a
//! string key (`@register("start")`, `bus.on("start")`), the other *emits* it
//! (`send("start")`, `socket.emit("start")`). We pair the two by the shared key,
//! mapping control flow that is otherwise only findable by grepping strings.
//!
//! Purely token-based (language-agnostic) and deliberately heuristic: a "verb"
//! is the identifier immediately before `(`, the key is the first string
//! argument. Keys are constrained to identifier-like literals (no whitespace,
//! bounded length) so a prose message passed to `send("saving…")` is not
//! mistaken for an event key.

const std = @import("std");
const lexer = @import("lexer.zig");

const Token = lexer.Token;

/// Which side of a dispatch a site sits on.
pub const Role = enum { handler, emitter };

/// A single dispatch site: `verb("key")` at `line`, with the string token's byte
/// offset so the caller can find the enclosing symbol.
pub const EventRef = struct {
    key: []const u8,
    role: Role,
    verb: []const u8,
    line: u32,
    offset: u32,
};

/// Max event-key length; longer literals are prose (log/error text), not keys.
const max_key_len = 64;

/// Verbs that register/subscribe a handler for a key (the receiving side). Kept
/// to unambiguous dispatch verbs — generic ones (`handle`, `bind`, `event`, DOM
/// `addEventListener`) matched HTTP/DOM calls that `routes` already covers.
const handler_verbs = std.StaticStringMap(void).initComptime(.{
    .{"register"},    .{"on"},     .{"subscribe"},
    .{"listen"},      .{"addlistener"},
});

/// Verbs that fire/emit a key (the sending side). `post`/`call`/`invoke` were
/// dropped: they matched HTTP client calls and generic invocations, not the bus.
const emitter_verbs = std.StaticStringMap(void).initComptime(.{
    .{"emit"},      .{"send"},   .{"dispatch"},  .{"publish"},
    .{"trigger"},   .{"fire"},   .{"broadcast"}, .{"notify"},
    .{"sendmessage"},
});

/// The dispatch role of `verb` (case-insensitive; a leading decorator `@` is
/// stripped), or null when it is not a known dispatch verb.
fn roleOf(verb_raw: []const u8) ?Role {
    const verb = if (verb_raw.len != 0 and verb_raw[0] == '@') verb_raw[1..] else verb_raw;
    if (verb.len == 0 or verb.len > 32) return null;
    var buf: [32]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..verb.len], verb);
    if (handler_verbs.has(lower)) return .handler;
    if (emitter_verbs.has(lower)) return .emitter;
    return null;
}

/// Scan `toks` for `verb("key")` dispatch sites, appending an `EventRef` for each
/// to `out`. Recognizes bare (`send("x")`), member (`bus.emit("x")`) and
/// decorator (`@register("x")`) forms — in every case the verb is the identifier
/// immediately before the `(`. Only identifier-like keys are kept.
pub fn collect(toks: []const Token, source: []const u8, out: *std.ArrayList(EventRef), gpa: std.mem.Allocator) !void {
    std.debug.assert(source.len == 0 or toks.len != 0);
    if (toks.len < 3) return;
    var i: usize = 1;
    while (i + 1 < toks.len) : (i += 1) {
        if (!isPunct(toks, source, i, '(')) continue;
        const verb_tok = toks[i - 1];
        const key_tok = toks[i + 1];
        if (verb_tok.kind != .identifier or key_tok.kind != .string) continue;
        const role = roleOf(verb_tok.text(source)) orelse continue;
        const key = eventKey(key_tok.text(source)) orelse continue;
        std.debug.assert(key.len != 0 and key.len <= max_key_len);
        try out.append(gpa, .{
            .key = key,
            .role = role,
            .verb = verb_tok.text(source),
            .line = key_tok.line,
            .offset = key_tok.start,
        });
    }
}

/// The event key inside a (possibly prefixed) string literal, or null when the
/// literal is not a plausible key: empty, too long, whitespace/prose, a URL path
/// (`/`-bearing — that is `routes`' domain), or an interpolated/dynamic fragment.
/// An f-string key like `f"start"` reads as `start`; a cut f-string fragment such
/// as `f"/api/jobs/` (the lexer stops at the first `{`) has no closing quote and
/// is dropped as dynamic.
fn eventKey(raw: []const u8) ?[]const u8 {
    const lit = stripStringPrefix(raw);
    if (lit.len < 2) return null;
    const q = lit[0];
    if (q != '"' and q != '\'' and q != '`') return null;
    if (lit[lit.len - 1] != q) return null;
    const key = lit[1 .. lit.len - 1];
    if (key.len == 0 or key.len > max_key_len) return null;
    for (key) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return null;
        if (c == '/') return null;
        if (c == '{') return null;
    }
    if (std.mem.indexOf(u8, key, "${") != null) return null;
    return key;
}

/// Strip a leading string prefix (Python `f`/`r`/`b`/`u` and combinations) so an
/// f-string literal is read by its quoted body. Returns `raw` unchanged when no
/// letters precede the opening quote, or the empty tail when there is no quote.
fn stripStringPrefix(raw: []const u8) []const u8 {
    var i: usize = 0;
    while (i < raw.len and raw[i] != '"' and raw[i] != '\'' and raw[i] != '`') : (i += 1) {
        const lower = raw[i] | 0x20;
        if (lower < 'a' or lower > 'z') return raw;
    }
    return raw[i..];
}

fn isPunct(toks: []const Token, source: []const u8, i: usize, c: u8) bool {
    return i < toks.len and toks[i].kind == .punct and source[toks[i].start] == c;
}

const language = @import("language.zig");

fn collectSource(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayList(EventRef)) !void {
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try lexer.tokenize(gpa, src, language.configFor(.python), &toks);
    try collect(toks.items, src, out, gpa);
}

test "collect pairs a handler registration with an emitter by shared key" {
    const testing = std.testing;
    const src =
        \\@register("start_optimization")
        \\def handler(msg):
        \\    socket.send("start_optimization")
        \\    log("just a message with spaces")
        \\    bus.emit("dynamic_${x}")
    ;
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(testing.allocator);
    try collectSource(testing.allocator, src, &out);
    // Two hits for "start_optimization" (register + send); the spaced prose and
    // the dynamic key are excluded.
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("start_optimization", out.items[0].key);
    try testing.expectEqual(Role.handler, out.items[0].role);
    try testing.expectEqualStrings("start_optimization", out.items[1].key);
    try testing.expectEqual(Role.emitter, out.items[1].role);
}

test "roleOf classifies verbs case-insensitively and strips a decorator @" {
    try std.testing.expectEqual(Role.handler, roleOf("@register").?);
    try std.testing.expectEqual(Role.handler, roleOf("On").?);
    try std.testing.expectEqual(Role.emitter, roleOf("emit").?);
    try std.testing.expectEqual(@as(?Role, null), roleOf("computeTotal"));
}
