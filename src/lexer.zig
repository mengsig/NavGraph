//! A small, allocation-light tokenizer shared by every supported language.
//!
//! It does not understand grammar; it classifies bytes into tokens (identifiers,
//! numbers, strings, comments, punctuation) so that the heuristic extractors in
//! `parser.zig` can scan a clean stream instead of raw bytes. Correctly skipping
//! strings and comments is the main value here: it keeps the extractor from
//! mistaking text inside a string/comment for a symbol or a call.

const std = @import("std");
const language = @import("language.zig");

pub const TokenKind = enum {
    identifier,
    number,
    string,
    comment,
    punct,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    start: u32,
    end: u32,
    line: u32,
    col: u32,
    /// Only meaningful for `comment`: whether it is a documentation comment.
    is_doc: bool = false,

    pub fn text(self: Token, source: []const u8) []const u8 {
        std.debug.assert(self.start <= self.end);
        std.debug.assert(self.end <= source.len);
        return source[self.start..self.end];
    }
};

const Lexer = struct {
    gpa: std.mem.Allocator,
    source: []const u8,
    cfg: language.Config,
    pos: u32 = 0,
    line: u32 = 1,
    col: u32 = 0,

    fn peek(self: *const Lexer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn at(self: *const Lexer, off: u32) u8 {
        const i = self.pos + off;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }

    fn advance(self: *Lexer) void {
        std.debug.assert(self.pos < self.source.len);
        if (self.source[self.pos] == '\n') {
            self.line += 1;
            self.col = 0;
        } else {
            self.col += 1;
        }
        self.pos += 1;
    }

    fn matches(self: *const Lexer, needle: []const u8) bool {
        if (needle.len == 0) return false;
        if (self.pos + needle.len > self.source.len) return false;
        return std.mem.eql(u8, self.source[self.pos .. self.pos + needle.len], needle);
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c == '@' or c >= 0x80;
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

/// Tokenize `source` into `out`. Caller owns `out` and provides the allocator.
/// Whitespace is skipped; a trailing `.eof` token is always appended.
pub fn tokenize(
    gpa: std.mem.Allocator,
    source: []const u8,
    cfg: language.Config,
    out: *std.ArrayList(Token),
) !void {
    std.debug.assert(source.len <= std.math.maxInt(u32));
    var lx = Lexer{ .gpa = gpa, .source = source, .cfg = cfg };
    while (lx.pos < lx.source.len) {
        const c = lx.peek();
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            lx.advance();
            continue;
        }
        try lexToken(&lx, out);
    }
    try out.append(gpa, .{ .kind = .eof, .start = lx.pos, .end = lx.pos, .line = lx.line, .col = lx.col });
}

/// Lex exactly one token at a non-whitespace position. Factored out of the main
/// loop so interpolation-hole lexing (`lexInterpHole`) reuses the same dispatch
/// — nested strings and f-strings inside `{...}` tokenize identically. Always
/// consumes at least one byte, so callers can loop without stalling.
fn lexToken(lx: *Lexer, out: *std.ArrayList(Token)) std.mem.Allocator.Error!void {
    const cfg = lx.cfg;
    if (try lexComment(lx, out)) return;
    if (cfg.line_string.len != 0 and lx.matches(cfg.line_string)) {
        try lexLineString(lx, out);
        return;
    }
    // Python f-strings: tokenize each `{...}` interpolation as code so a call
    // like `f"{jsonable_encoder(x)}"` becomes a real edge instead of vanishing
    // into a string literal. The `f`/`rf` prefix would otherwise lex as a stray
    // identifier and the whole string swallow its interpolations.
    if (cfg.language == .python) {
        if (detectPyFString(lx)) |fs| {
            try lexFString(lx, out, fs.quote, fs.prefix_len);
            return;
        }
    }
    const c = lx.peek();
    // JSX-text apostrophe guard: in JS/TS/JSX a `'` or `"` glued to the end of a
    // word (`you'll`, `don't`) is prose, not a string opener. Left unchecked, it
    // would open a string and swallow the rest of the file up to the next quote,
    // hiding every symbol and call after it. JS has no `b'…'`/`r'…'` string
    // prefixes, so a quote right after an identifier char is never a real string.
    if (cfg.template_strings and (c == '\'' or c == '"') and
        lx.pos > 0 and isIdentCont(lx.source[lx.pos - 1]))
    {
        try appendSingle(lx, out, .punct);
        return;
    }
    // C/C++ digit separators (`1'000'000`, `0xFF'FF`): a `'` immediately after a
    // number token is a separator, not a char-literal opener — otherwise it would
    // swallow to the next quote (often EOF, erasing the whole file). Keyed on the
    // previous *token* being a number so char prefixes like `L'a'`/`u'a'` (whose
    // previous token is an identifier) are untouched.
    if ((cfg.language == .c or cfg.language == .cpp) and c == '\'' and
        out.items.len > 0 and out.items[out.items.len - 1].kind == .number and
        out.items[out.items.len - 1].end == lx.pos)
    {
        try appendSingle(lx, out, .punct);
        return;
    }
    if (isStringDelim(cfg, c) or (cfg.template_strings and c == '`')) {
        try lexString(lx, out, c);
        return;
    }
    if (isIdentStart(c)) {
        try lexIdentifier(lx, out);
        return;
    }
    if (std.ascii.isDigit(c)) {
        try lexNumber(lx, out);
        return;
    }
    try appendSingle(lx, out, .punct);
}

fn isQuoteChar(c: u8) bool {
    return c == '"' or c == '\'';
}

/// A Python f-string at the cursor: its quote char and prefix length (`f"`,
/// `rf'`, `F"""`, …), or null. Only f-prefixed strings (the ones that
/// interpolate) are matched; plain/raw/byte strings lex normally.
fn detectPyFString(lx: *const Lexer) ?struct { quote: u8, prefix_len: u32 } {
    const isF = struct {
        fn f(c: u8) bool {
            return c == 'f' or c == 'F';
        }
    }.f;
    const isR = struct {
        fn r(c: u8) bool {
            return c == 'r' or c == 'R';
        }
    }.r;
    const c0 = lx.at(0);
    if (isF(c0) and isQuoteChar(lx.at(1))) return .{ .quote = lx.at(1), .prefix_len = 1 };
    const c1 = lx.at(1);
    if (((isF(c0) and isR(c1)) or (isR(c0) and isF(c1))) and isQuoteChar(lx.at(2)))
        return .{ .quote = lx.at(2), .prefix_len = 2 };
    return null;
}

/// Lex a Python f-string as byte-ordered pieces: `.string` tokens for the
/// literal runs and normal code tokens for each `{...}` interpolation. Pieces
/// stay sorted by start offset, so the token stream's ordering invariant holds.
fn lexFString(lx: *Lexer, out: *std.ArrayList(Token), quote: u8, prefix_len: u32) std.mem.Allocator.Error!void {
    var chunk_start = lx.pos;
    var chunk_line = lx.line;
    var chunk_col = lx.col;
    var p: u32 = 0;
    while (p < prefix_len) : (p += 1) lx.advance();
    const triple = lx.peek() == quote and lx.at(1) == quote and lx.at(2) == quote;
    lx.advance();
    if (triple) {
        lx.advance();
        lx.advance();
    }
    while (lx.pos < lx.source.len) {
        if (triple) {
            if (isTripleClose(lx, quote)) {
                lx.advance();
                lx.advance();
                lx.advance();
                break;
            }
        } else if (lx.peek() == quote) {
            lx.advance();
            break;
        }
        const c = lx.peek();
        if (!triple and c == '\\') { // escaped char (`\"`, `\n`, …)
            lx.advance();
            if (lx.pos < lx.source.len) lx.advance();
            continue;
        }
        if (c == '{') {
            if (lx.at(1) == '{') { // `{{` — an escaped literal brace
                lx.advance();
                lx.advance();
                continue;
            }
            try emitStringChunk(lx, out, chunk_start, chunk_line, chunk_col);
            lx.advance(); // consume '{'
            try lexInterpHole(lx, out);
            chunk_start = lx.pos;
            chunk_line = lx.line;
            chunk_col = lx.col;
            continue;
        }
        if (c == '}' and lx.at(1) == '}') { // `}}` — an escaped literal brace
            lx.advance();
            lx.advance();
            continue;
        }
        lx.advance();
    }
    try emitStringChunk(lx, out, chunk_start, chunk_line, chunk_col);
}

/// Emit `[start, pos)` as a `.string` token if non-empty (a literal run of an
/// interpolated string).
fn emitStringChunk(lx: *Lexer, out: *std.ArrayList(Token), start: u32, line: u32, col: u32) !void {
    if (lx.pos <= start) return;
    try out.append(lx.gpa, .{ .kind = .string, .start = start, .end = lx.pos, .line = line, .col = col });
}

/// Lex an interpolation hole's expression as code tokens up to (and consuming)
/// its matching `}` at brace depth 0. Nested `{}` (dict/set/format-spec) and
/// strings that embed `}` are handled so the true closing brace is found.
fn lexInterpHole(lx: *Lexer, out: *std.ArrayList(Token)) std.mem.Allocator.Error!void {
    var depth: u32 = 0;
    while (lx.pos < lx.source.len) {
        const c = lx.peek();
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            lx.advance();
            continue;
        }
        if (c == '}') {
            if (depth == 0) {
                lx.advance(); // consume the closing brace
                return;
            }
            depth -= 1;
            try appendSingle(lx, out, .punct);
            continue;
        }
        if (c == '{') {
            depth += 1;
            try appendSingle(lx, out, .punct);
            continue;
        }
        try lexToken(lx, out);
    }
}

fn isStringDelim(cfg: language.Config, c: u8) bool {
    return std.mem.indexOfScalar(u8, cfg.string_delims, c) != null;
}

fn lexComment(lx: *Lexer, out: *std.ArrayList(Token)) !bool {
    const cfg = lx.cfg;
    if (cfg.line_comment.len != 0 and lx.matches(cfg.line_comment)) {
        try lexLineComment(lx, out);
        return true;
    }
    if (cfg.block_open.len != 0 and lx.matches(cfg.block_open)) {
        try lexBlockComment(lx, out);
        return true;
    }
    return false;
}

fn lexLineComment(lx: *Lexer, out: *std.ArrayList(Token)) !void {
    const start = lx.pos;
    const line = lx.line;
    const col = lx.col;
    // Zig doc comments: `///` or `//!`. block_star `//` runs handled by extractor.
    const third = lx.at(2);
    const is_doc = lx.cfg.doc_style == .zig_slashes and lx.matches("//") and (third == '/' or third == '!');
    while (lx.pos < lx.source.len and lx.peek() != '\n') lx.advance();
    try out.append(lx.gpa, .{
        .kind = .comment,
        .start = start,
        .end = lx.pos,
        .line = line,
        .col = col,
        .is_doc = is_doc,
    });
}

fn lexBlockComment(lx: *Lexer, out: *std.ArrayList(Token)) !void {
    const start = lx.pos;
    const line = lx.line;
    const col = lx.col;
    const is_doc = lx.cfg.doc_style == .block_star and lx.at(2) == '*';
    // consume opener
    var i: usize = 0;
    while (i < lx.cfg.block_open.len) : (i += 1) lx.advance();
    while (lx.pos < lx.source.len and !lx.matches(lx.cfg.block_close)) lx.advance();
    i = 0;
    while (i < lx.cfg.block_close.len and lx.pos < lx.source.len) : (i += 1) lx.advance();
    try out.append(lx.gpa, .{
        .kind = .comment,
        .start = start,
        .end = lx.pos,
        .line = line,
        .col = col,
        .is_doc = is_doc,
    });
}

/// Lex a to-end-of-line string literal (Zig `\\...`). Each such line becomes one
/// `.string` token so its contents are never mistaken for code (e.g. a route
/// decorator embedded in a test fixture must not be parsed as a real route).
fn lexLineString(lx: *Lexer, out: *std.ArrayList(Token)) !void {
    const start = lx.pos;
    const line = lx.line;
    const col = lx.col;
    while (lx.pos < lx.source.len and lx.peek() != '\n') lx.advance();
    std.debug.assert(lx.pos >= start);
    try out.append(lx.gpa, .{
        .kind = .string,
        .start = start,
        .end = lx.pos,
        .line = line,
        .col = col,
        .is_doc = false,
    });
}

fn lexString(lx: *Lexer, out: *std.ArrayList(Token), quote: u8) !void {
    const start = lx.pos;
    const line = lx.line;
    const col = lx.col;
    // Python triple-quoted strings.
    const triple = (quote == '"' or quote == '\'') and lx.at(1) == quote and lx.at(2) == quote;
    lx.advance();
    if (triple) {
        lx.advance();
        lx.advance();
        while (lx.pos < lx.source.len and !isTripleClose(lx, quote)) lx.advance();
        if (lx.pos < lx.source.len) {
            lx.advance();
            lx.advance();
            lx.advance();
        }
    } else {
        while (lx.pos < lx.source.len and lx.peek() != quote) {
            if (lx.peek() == '\\') lx.advance();
            if (lx.pos < lx.source.len) lx.advance();
        }
        if (lx.pos < lx.source.len) lx.advance();
    }
    try out.append(lx.gpa, .{ .kind = .string, .start = start, .end = lx.pos, .line = line, .col = col });
}

fn isTripleClose(lx: *const Lexer, quote: u8) bool {
    return lx.peek() == quote and lx.at(1) == quote and lx.at(2) == quote;
}

fn lexIdentifier(lx: *Lexer, out: *std.ArrayList(Token)) !void {
    const start = lx.pos;
    const line = lx.line;
    const col = lx.col;
    // Zig `@"..."` builtins/identifiers.
    if (lx.peek() == '@' and lx.at(1) == '"') {
        lx.advance();
        try lexString(lx, out, '"');
        // Rewrite the just-appended string token as an identifier spanning @"..".
        var last = &out.items[out.items.len - 1];
        last.kind = .identifier;
        last.start = start;
        last.line = line;
        last.col = col;
        return;
    }
    lx.advance();
    while (lx.pos < lx.source.len and isIdentCont(lx.peek())) lx.advance();
    try out.append(lx.gpa, .{ .kind = .identifier, .start = start, .end = lx.pos, .line = line, .col = col });
}

fn lexNumber(lx: *Lexer, out: *std.ArrayList(Token)) !void {
    const start = lx.pos;
    const line = lx.line;
    const col = lx.col;
    while (lx.pos < lx.source.len and (std.ascii.isAlphanumeric(lx.peek()) or lx.peek() == '.' or lx.peek() == '_')) {
        lx.advance();
    }
    try out.append(lx.gpa, .{ .kind = .number, .start = start, .end = lx.pos, .line = line, .col = col });
}

fn appendSingle(lx: *Lexer, out: *std.ArrayList(Token), kind: TokenKind) !void {
    const start = lx.pos;
    const line = lx.line;
    const col = lx.col;
    lx.advance();
    try out.append(lx.gpa, .{ .kind = kind, .start = start, .end = lx.pos, .line = line, .col = col });
}

test "tokenize skips strings and comments" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.zig);
    const src =
        \\// a comment with fn foo
        \\const x = "fn not_a_fn";
        \\pub fn bar() void {}
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);

    var idents: usize = 0;
    var saw_bar = false;
    for (toks.items) |t| {
        if (t.kind == .identifier) {
            idents += 1;
            if (std.mem.eql(u8, t.text(src), "bar")) saw_bar = true;
            try std.testing.expect(!std.mem.eql(u8, t.text(src), "not_a_fn"));
        }
    }
    try std.testing.expect(saw_bar);
    try std.testing.expect(idents > 0);
}

test "tokenize treats Zig multiline strings as strings, not code" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.zig);
    // A `\\` line-string embedding code-shaped text (as test fixtures do).
    const src =
        \\const fixture =
        \\    \\pub fn ghost() void {}
        \\    \\@app.get("/phantom")
        \\;
        \\pub fn real() void {}
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);

    var saw_real = false;
    for (toks.items) |t| {
        if (t.kind != .identifier) continue;
        // Names living only inside the multiline string must not surface.
        try std.testing.expect(!std.mem.eql(u8, t.text(src), "ghost"));
        try std.testing.expect(!std.mem.eql(u8, t.text(src), "phantom"));
        if (std.mem.eql(u8, t.text(src), "real")) saw_real = true;
    }
    try std.testing.expect(saw_real);
}

test "python f-string interpolations tokenize as code, sorted, and stay balanced" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.python);
    // A call, a `!r` conversion, a nested dict `{}` and a `}` inside a string —
    // the closing brace must be found past all of them.
    const src =
        \\msg = f"got {compute(x)!r} keys {d['}']} end"
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);

    var saw_call = false;
    var last_start: u32 = 0;
    var open_parens: i32 = 0;
    for (toks.items, 0..) |t, i| {
        // Token stream stays sorted by start offset (tokenAfterOffset relies on it).
        try std.testing.expect(t.start >= last_start);
        last_start = t.start;
        if (t.kind == .punct) {
            const c = src[t.start];
            if (c == '(') open_parens += 1;
            if (c == ')') open_parens -= 1;
        }
        if (t.kind == .identifier and std.mem.eql(u8, t.text(src), "compute") and
            i + 1 < toks.items.len and toks.items[i + 1].kind == .punct and
            src[toks.items[i + 1].start] == '(') saw_call = true;
    }
    // `compute(` surfaced as an identifier+`(` (a call the parser can record).
    try std.testing.expect(saw_call);
    // Parens introduced by the interpolation are balanced (the `}` in `'}'` did
    // not truncate the hole early).
    try std.testing.expectEqual(@as(i32, 0), open_parens);
}

test "a plain (non-f) python string is still one opaque token" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.python);
    const src =
        \\path = "/users/{id}/get"
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);
    // The `{id}` inside a normal string must NOT become a code token.
    for (toks.items) |t| {
        if (t.kind == .identifier) try std.testing.expect(!std.mem.eql(u8, t.text(src), "id"));
    }
}

test "JSX prose apostrophes do not open a string and swallow the code after" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.tsx);
    // `you'll` / `don't` would otherwise start a single-quoted string that runs
    // to the next quote — hiding every identifier until then.
    const src =
        \\function View() {
        \\  return <p>you'll like it, don't worry about it</p>;
        \\}
        \\function after() { return realCallAfterProse(); }
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);
    var saw_after = false;
    for (toks.items) |t| {
        if (t.kind == .identifier and std.mem.eql(u8, t.text(src), "realCallAfterProse")) saw_after = true;
    }
    try std.testing.expect(saw_after);
}

test "a real single-quoted JS string (in value position) is still a string" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.typescript);
    const src =
        \\const mode = 'production';
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);
    // `production` lives inside the string, so it must not surface as an ident.
    for (toks.items) |t| {
        if (t.kind == .identifier) try std.testing.expect(!std.mem.eql(u8, t.text(src), "production"));
    }
}

test "C++ digit separators do not open a char literal and swallow the file" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.cpp);
    // `1'000` (a single separator) would otherwise open a char literal that runs
    // to EOF, erasing every symbol after it.
    const src =
        \\int budget() { return 1'000; }
        \\int laterFn(int x) { return x; }
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);
    var saw_later = false;
    for (toks.items) |t| {
        if (t.kind == .identifier and std.mem.eql(u8, t.text(src), "laterFn")) saw_later = true;
    }
    try std.testing.expect(saw_later);
}

test "C++ char prefix (L'a') stays a char literal; code after it survives" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.cpp);
    const src =
        \\wchar_t w = L'a';
        \\int fnTwo(int q) { return q; }
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);
    var leaked_a = false;
    var saw_fn = false;
    for (toks.items) |t| {
        if (t.kind != .identifier) continue;
        if (std.mem.eql(u8, t.text(src), "a")) leaked_a = true; // would mean the char literal was broken
        if (std.mem.eql(u8, t.text(src), "fnTwo")) saw_fn = true;
    }
    try std.testing.expect(!leaked_a);
    try std.testing.expect(saw_fn);
}
