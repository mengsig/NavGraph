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


// ---------------------------------------------------------------------------
// Appended hardening tests for src/events.zig
// ---------------------------------------------------------------------------

fn tokenizeForTest(gpa: std.mem.Allocator, src: []const u8, toks: *std.ArrayList(Token)) !void {
    try lexer.tokenize(gpa, src, language.configFor(.python), toks);
}

fn quotedKey(comptime n: usize) []const u8 {
    return "\"" ++ ("a" ** n) ++ "\"";
}

// ---- roleOf: every handler verb ------------------------------------------

test "roleOf maps every handler verb to .handler" {
    const handlers = [_][]const u8{ "register", "on", "subscribe", "listen", "addlistener" };
    for (handlers) |v| {
        try std.testing.expectEqual(Role.handler, roleOf(v).?);
    }
}

// ---- roleOf: every emitter verb ------------------------------------------

test "roleOf maps every emitter verb to .emitter" {
    const emitters = [_][]const u8{
        "emit", "send", "dispatch", "publish", "trigger",
        "fire", "broadcast", "notify", "sendmessage",
    };
    for (emitters) |v| {
        try std.testing.expectEqual(Role.emitter, roleOf(v).?);
    }
}

// ---- roleOf: case-insensitivity on both sides -----------------------------

test "roleOf is case-insensitive for handler and emitter verbs" {
    try std.testing.expectEqual(Role.handler, roleOf("REGISTER").?);
    try std.testing.expectEqual(Role.handler, roleOf("SubScribe").?);
    try std.testing.expectEqual(Role.handler, roleOf("ADDLISTENER").?);
    try std.testing.expectEqual(Role.emitter, roleOf("EMIT").?);
    try std.testing.expectEqual(Role.emitter, roleOf("SendMessage").?);
    try std.testing.expectEqual(Role.emitter, roleOf("BroadCast").?);
}

// ---- roleOf: decorator @ stripping ---------------------------------------

test "roleOf strips a leading decorator @ before matching" {
    try std.testing.expectEqual(Role.handler, roleOf("@register").?);
    try std.testing.expectEqual(Role.handler, roleOf("@on").?);
    // @ strip combined with case folding.
    try std.testing.expectEqual(Role.handler, roleOf("@ON").?);
    try std.testing.expectEqual(Role.emitter, roleOf("@emit").?);
}

test "roleOf returns null for a bare @ with no verb after it" {
    try std.testing.expectEqual(@as(?Role, null), roleOf("@"));
}

// ---- roleOf: unknown / deliberately-excluded verbs -----------------------

test "roleOf returns null for unknown verbs" {
    try std.testing.expectEqual(@as(?Role, null), roleOf("computeTotal"));
    try std.testing.expectEqual(@as(?Role, null), roleOf("log"));
}

test "roleOf returns null for the deliberately-excluded generic verbs" {
    // Documented exclusions: generic invocations / HTTP-ish verbs / DOM listener.
    const excluded = [_][]const u8{
        "handle", "bind", "event", "addeventlistener",
        "post", "call", "invoke", "get", "put",
    };
    for (excluded) |v| {
        try std.testing.expectEqual(@as(?Role, null), roleOf(v));
    }
}

// ---- roleOf: length boundaries -------------------------------------------

test "roleOf returns null on empty verb" {
    try std.testing.expectEqual(@as(?Role, null), roleOf(""));
}

test "roleOf returns null when verb exceeds 32 bytes without overflowing" {
    const long = "a" ** 33; // > 32, rejected before the lowercase buffer is used
    try std.testing.expectEqual(@as(?Role, null), roleOf(long));
}

test "roleOf handles a 32-byte unknown verb via the lowercase path without matching" {
    const at_limit = "A" ** 32; // exactly 32: exercises lowerString, still not a known verb
    try std.testing.expectEqual(@as(usize, 32), at_limit.len);
    try std.testing.expectEqual(@as(?Role, null), roleOf(at_limit));
}

// ---- eventKey: valid keys across quote styles and prefixes ----------------

test "eventKey extracts the body of a double-quoted literal" {
    try std.testing.expectEqualStrings("start", eventKey("\"start\"").?);
}

test "eventKey accepts single-quote and backtick literals" {
    try std.testing.expectEqualStrings("start", eventKey("'start'").?);
    try std.testing.expectEqualStrings("start", eventKey("`start`").?);
}

test "eventKey reads an f-string / prefixed literal by its quoted body" {
    try std.testing.expectEqualStrings("start", eventKey("f\"start\"").?);
    try std.testing.expectEqualStrings("start", eventKey("rb\"start\"").?);
}

test "eventKey permits a literal $ that is not an interpolation" {
    try std.testing.expectEqualStrings("a$b", eventKey("\"a$b\"").?);
}

// ---- eventKey: null cases -------------------------------------------------

test "eventKey rejects an empty key" {
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"\""));
}

test "eventKey rejects literals shorter than two characters" {
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\""));
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey(""));
}

test "eventKey rejects a non-string token" {
    // No opening quote after any prefix letters.
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("xyz"));
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("123"));
}

test "eventKey rejects a mismatched closing quote" {
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"start'"));
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("'start\""));
}

test "eventKey rejects whitespace-bearing prose keys" {
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"a b\""));
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"a\tb\""));
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"a\nb\""));
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"a\rb\""));
}

test "eventKey rejects URL-path keys containing a slash" {
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"/api/jobs\""));
}

test "eventKey rejects keys with an interpolation brace" {
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"a{b\""));
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey("\"a${b}\""));
}

// ---- eventKey: max_key_len boundary --------------------------------------

test "eventKey accepts a key of exactly max_key_len bytes" {
    const raw = comptime quotedKey(max_key_len);
    const got = eventKey(raw).?;
    try std.testing.expectEqual(@as(usize, max_key_len), got.len);
}

test "eventKey rejects a key one byte over max_key_len" {
    const raw = comptime quotedKey(max_key_len + 1);
    try std.testing.expectEqual(@as(?[]const u8, null), eventKey(raw));
}

// ---- stripStringPrefix ----------------------------------------------------

test "stripStringPrefix leaves an unprefixed literal unchanged" {
    try std.testing.expectEqualStrings("\"x\"", stripStringPrefix("\"x\""));
    try std.testing.expectEqualStrings("'x'", stripStringPrefix("'x'"));
    try std.testing.expectEqualStrings("`x`", stripStringPrefix("`x`"));
}

test "stripStringPrefix drops leading Python string-prefix letters" {
    try std.testing.expectEqualStrings("\"x\"", stripStringPrefix("f\"x\""));
    try std.testing.expectEqualStrings("\"x\"", stripStringPrefix("rb\"x\""));
    try std.testing.expectEqualStrings("\"x\"", stripStringPrefix("F\"x\"")); // case-folded letter
    try std.testing.expectEqualStrings("'x'", stripStringPrefix("f'x'"));
}

test "stripStringPrefix returns the empty tail when there is no quote" {
    try std.testing.expectEqualStrings("", stripStringPrefix("abc"));
    try std.testing.expectEqualStrings("", stripStringPrefix(""));
}

test "stripStringPrefix returns raw unchanged when a non-letter precedes the quote" {
    try std.testing.expectEqualStrings("1\"x\"", stripStringPrefix("1\"x\""));
    try std.testing.expectEqualStrings("-\"x\"", stripStringPrefix("-\"x\""));
}

// ---- isPunct --------------------------------------------------------------

test "isPunct matches only the requested punctuation at a punct token" {
    const gpa = std.testing.allocator;
    const src = "send(\"x\")";
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenizeForTest(gpa, src, &toks);
    // Tokens: [ident send][punct (][string "x"][punct )]
    try std.testing.expect(isPunct(toks.items, src, 1, '('));
    try std.testing.expect(!isPunct(toks.items, src, 1, ')')); // right index, wrong char
    try std.testing.expect(!isPunct(toks.items, src, 0, '(')); // identifier, not punct
    try std.testing.expect(isPunct(toks.items, src, 3, ')'));
}

test "isPunct returns false for an out-of-range index" {
    const gpa = std.testing.allocator;
    const src = "send(\"x\")";
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenizeForTest(gpa, src, &toks);
    try std.testing.expect(!isPunct(toks.items, src, 999, '('));
}

// ---- collect / collectSource ---------------------------------------------

test "collectSource recognizes the bare, member, and decorator dispatch forms" {
    const gpa = std.testing.allocator;
    const src =
        \\@register("evt")
        \\send("evt")
        \\bus.emit("evt")
    ;
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(gpa);
    try collectSource(gpa, src, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(Role.handler, out.items[0].role);
    // The Python lexer keeps the decorator @ in the identifier token; roleOf
    // strips it, but the stored verb retains the raw text.
    try std.testing.expectEqualStrings("@register", out.items[0].verb);
    try std.testing.expectEqual(Role.emitter, out.items[1].role);
    try std.testing.expectEqualStrings("send", out.items[1].verb);
    try std.testing.expectEqual(Role.emitter, out.items[2].role);
    try std.testing.expectEqualStrings("emit", out.items[2].verb);
    for (out.items) |ref| try std.testing.expectEqualStrings("evt", ref.key);
}

test "collectSource records line and offset of the key token" {
    const gpa = std.testing.allocator;
    const src = "send(\"x\")"; // string literal begins at byte 5, line 1
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(gpa);
    try collectSource(gpa, src, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u32, 1), out.items[0].line);
    try std.testing.expectEqual(@as(u32, 5), out.items[0].offset);
}

test "collectSource assigns the correct line for a key on a later line" {
    const gpa = std.testing.allocator;
    const src =
        \\x = 1
        \\emit("later")
    ;
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(gpa);
    try collectSource(gpa, src, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u32, 2), out.items[0].line);
    try std.testing.expectEqualStrings("later", out.items[0].key);
}

test "collectSource skips unknown verbs, prose, and dynamic keys" {
    const gpa = std.testing.allocator;
    const src =
        \\log("hello world")
        \\emit("saving files here")
        \\bus.emit("dyn_${x}")
        \\emit("/api/route")
        \\handle("evt")
    ;
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(gpa);
    try collectSource(gpa, src, &out);
    // log -> unknown verb; the two prose keys have spaces; ${} is dynamic;
    // /api/route is a URL path; handle is an excluded verb. Nothing survives.
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "collectSource skips a call whose argument is not a string" {
    const gpa = std.testing.allocator;
    const src = "emit(evt)"; // identifier arg, not a string literal
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(gpa);
    try collectSource(gpa, src, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "collectSource skips a call whose verb token is not an identifier" {
    const gpa = std.testing.allocator;
    const src = "123(\"evt\")"; // number before '(' is not an identifier verb
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(gpa);
    try collectSource(gpa, src, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "collectSource returns nothing for empty or trivially short input" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(gpa);
    try collectSource(gpa, "", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try collectSource(gpa, "x", &out); // < 3 tokens
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "collectSource pairs multiple distinct keys independently" {
    const gpa = std.testing.allocator;
    const src =
        \\@register("alpha")
        \\emit("beta")
        \\subscribe("gamma")
    ;
    var out: std.ArrayList(EventRef) = .empty;
    defer out.deinit(gpa);
    try collectSource(gpa, src, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("alpha", out.items[0].key);
    try std.testing.expectEqual(Role.handler, out.items[0].role);
    try std.testing.expectEqualStrings("beta", out.items[1].key);
    try std.testing.expectEqual(Role.emitter, out.items[1].role);
    try std.testing.expectEqualStrings("gamma", out.items[2].key);
    try std.testing.expectEqual(Role.handler, out.items[2].role);
}
