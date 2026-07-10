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
    // Rust lifetimes/labels (`'a`, `'static`) share the `'` that opens a char
    // literal. A char literal is short and closes fast (`'x'`, `'\n'`); a
    // lifetime is `'` + identifier with no closing `'`. Emit the `'` as punct in
    // the lifetime case so the following identifier lexes as code, not a string
    // that swallows to the next quote.
    if (cfg.language == .rust and c == '\'' and !isRustCharLiteral(lx)) {
        try appendSingle(lx, out, .punct);
        return;
    }
    // JS/TS/JSX regex literals (`/foo\/bar/gi`). A `/` here is not a comment
    // (lexComment ran first) so it is either division or a regex. In expression
    // position (after `=`, `(`, `,`, an operator, or a keyword like `return`) it
    // starts a regex; the quotes, brackets and escapes inside must be consumed as
    // one opaque literal — left unhandled they desync the tokenizer and silently
    // drop every symbol after the regex (the app.js 224-line drop).
    if (cfg.language.family() == .js and c == '/' and regexAllowedHere(out.items, lx.source)) {
        try lexRegex(lx, out);
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

/// Whether the `'` at the cursor opens a Rust char literal (`'x'`, `'\n'`) rather
/// than a lifetime/label (`'a`). A char literal has its closing `'` within a few
/// bytes; an escape (`'\`) is always a char literal.
fn isRustCharLiteral(lx: *const Lexer) bool {
    if (lx.at(1) == '\\') return true;
    return lx.at(2) == '\'';
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
    // Block opener is checked first: when the line-comment marker is a prefix of
    // the block opener (Lua's `--` vs `--[[`), a `--[[` must not be mis-lexed as
    // a one-line comment. For languages with disjoint markers order is moot.
    if (cfg.block_open.len != 0 and lx.matches(cfg.block_open)) {
        try lexBlockComment(lx, out);
        return true;
    }
    if (cfg.line_comment.len != 0 and lx.matches(cfg.line_comment)) {
        try lexLineComment(lx, out);
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

/// Whether a `/` at the cursor begins a regex literal, decided by the previous
/// significant (non-comment) token. A regex can only appear in expression
/// position; after a value (identifier, number, string, or a closing
/// `)`/`]`/`}`) the `/` is division. `<`/`>` are excluded so a JSX close tag
/// (`</div>`) is never mistaken for a regex.
fn regexAllowedHere(toks: []const Token, source: []const u8) bool {
    var i = toks.len;
    while (i > 0) {
        i -= 1;
        const t = toks[i];
        if (t.kind == .comment) continue;
        return switch (t.kind) {
            .number, .string => false,
            .identifier => regexKeyword(t.text(source)),
            .punct => std.mem.indexOfScalar(u8, "(,=:[!&|?{;+-*%^~", source[t.start]) != null,
            else => true,
        };
    }
    return true; // start of file: `/` can only be a regex
}

/// Keywords after which a `/` starts a regex rather than a division
/// (`return /x/`, `typeof /x/`). Any other identifier is a value, so `x / y` is
/// division.
fn regexKeyword(name: []const u8) bool {
    const kws = [_][]const u8{
        "return", "typeof", "instanceof", "in",   "of",     "new",   "delete",
        "void",   "do",     "else",       "yield", "case",   "throw", "await",
    };
    for (kws) |k| if (std.mem.eql(u8, name, k)) return true;
    return false;
}

/// Lex a JS/TS regex literal `/pattern/flags` as one opaque `.string` token so
/// its contents are never tokenized as code. Character classes (`[...]`) keep a
/// `/` from closing the regex; a backslash escapes the next byte. A regex cannot
/// span a newline, so an unterminated one stops at end-of-line, bounding the
/// damage of a misclassified division to a single line.
fn lexRegex(lx: *Lexer, out: *std.ArrayList(Token)) !void {
    const start = lx.pos;
    const line = lx.line;
    const col = lx.col;
    lx.advance(); // consume the opening '/'
    var in_class = false;
    while (lx.pos < lx.source.len) {
        const ch = lx.peek();
        if (ch == '\n') break;
        if (ch == '\\') {
            lx.advance();
            if (lx.pos < lx.source.len) lx.advance();
            continue;
        }
        if (ch == '[') {
            in_class = true;
        } else if (ch == ']') {
            in_class = false;
        } else if (ch == '/' and !in_class) {
            lx.advance(); // consume the closing '/'
            break;
        }
        lx.advance();
    }
    // Trailing flags (`g`, `i`, `m`, …) are part of the literal.
    while (lx.pos < lx.source.len and isIdentCont(lx.peek())) lx.advance();
    std.debug.assert(lx.pos > start);
    try out.append(lx.gpa, .{ .kind = .string, .start = start, .end = lx.pos, .line = line, .col = col });
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

test "JS regex literal with quotes/brackets does not desync the tokenizer" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.javascript);
    // A regex packed with quotes, escaped slashes and a char class — the exact
    // shape (app.js:997) that used to swallow every symbol after it.
    const src =
        \\const re = /("(?:[^"\\]|\\.)*")(\s*:)?|\/x\//g;
        \\function afterRegex() { return 1; }
        \\function lastOne() { return 2; }
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);
    var saw_after = false;
    var saw_last = false;
    for (toks.items) |t| {
        if (t.kind != .identifier) continue;
        if (std.mem.eql(u8, t.text(src), "afterRegex")) saw_after = true;
        if (std.mem.eql(u8, t.text(src), "lastOne")) saw_last = true;
    }
    try std.testing.expect(saw_after);
    try std.testing.expect(saw_last);
}

test "a `/` after a value is division, not a regex" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.javascript);
    // `total / count` is division; `count` and the code after must survive as
    // real identifiers (a regex would have swallowed to the next `/`).
    const src =
        \\const avg = total / count / 2;
        \\function tail() { return avg; }
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);
    var saw_count = false;
    var saw_tail = false;
    for (toks.items) |t| {
        if (t.kind != .identifier) continue;
        if (std.mem.eql(u8, t.text(src), "count")) saw_count = true;
        if (std.mem.eql(u8, t.text(src), "tail")) saw_tail = true;
    }
    try std.testing.expect(saw_count);
    try std.testing.expect(saw_tail);
}

test "JSX closing tag is not mistaken for a regex" {
    const gpa = std.testing.allocator;
    const cfg = language.configFor(.tsx);
    // `</div>` opens with `<` then `/`; treating the `/` as a regex would eat the
    // rest of the line and hide the component defined afterwards.
    const src =
        \\function View() { return <div>hi</div>; }
        \\function Sibling() { return null; }
    ;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try tokenize(gpa, src, cfg, &toks);
    var saw_sibling = false;
    for (toks.items) |t| {
        if (t.kind == .identifier and std.mem.eql(u8, t.text(src), "Sibling")) saw_sibling = true;
    }
    try std.testing.expect(saw_sibling);
}


// ===================================================================
// Appended hardening tests for lexer.zig
// ===================================================================

/// Tokenize `src` under `lang`'s config, returning the owned token list.
/// Caller must `deinit(gpa)` it.
fn lexAll(gpa: std.mem.Allocator, src: []const u8, lang: language.Language) !std.ArrayList(Token) {
    var toks: std.ArrayList(Token) = .empty;
    errdefer toks.deinit(gpa);
    try tokenize(gpa, src, language.configFor(lang), &toks);
    return toks;
}

/// Whether any `.identifier` token has exactly `name` for its text.
fn hasIdent(toks: []const Token, src: []const u8, name: []const u8) bool {
    for (toks) |t| {
        if (t.kind == .identifier and std.mem.eql(u8, t.text(src), name)) return true;
    }
    return false;
}

fn countKind(toks: []const Token, kind: TokenKind) usize {
    var n: usize = 0;
    for (toks) |t| {
        if (t.kind == kind) n += 1;
    }
    return n;
}

/// Return the first token of `kind`, or null.
fn firstOfKind(toks: []const Token, kind: TokenKind) ?Token {
    for (toks) |t| {
        if (t.kind == kind) return t;
    }
    return null;
}

/// Whether a `.punct` token exists whose single byte equals `c`.
fn hasPunct(toks: []const Token, src: []const u8, c: u8) bool {
    for (toks) |t| {
        if (t.kind == .punct and t.end == t.start + 1 and src[t.start] == c) return true;
    }
    return false;
}

// ---- character-class predicates (direct unit tests) ----------------

test "isIdentStart accepts letters/_/$/@/high-bytes, rejects digits and punct" {
    try std.testing.expect(isIdentStart('a'));
    try std.testing.expect(isIdentStart('Z'));
    try std.testing.expect(isIdentStart('_'));
    try std.testing.expect(isIdentStart('$'));
    try std.testing.expect(isIdentStart('@'));
    try std.testing.expect(isIdentStart(0x80)); // start of a UTF-8 lead byte range
    try std.testing.expect(isIdentStart(0xC3));
    try std.testing.expect(!isIdentStart('0'));
    try std.testing.expect(!isIdentStart('9'));
    try std.testing.expect(!isIdentStart(' '));
    try std.testing.expect(!isIdentStart('-'));
    try std.testing.expect(!isIdentStart('.'));
}

test "isIdentCont accepts alnum/_/$/high-bytes but NOT @" {
    try std.testing.expect(isIdentCont('a'));
    try std.testing.expect(isIdentCont('0'));
    try std.testing.expect(isIdentCont('9'));
    try std.testing.expect(isIdentCont('_'));
    try std.testing.expect(isIdentCont('$'));
    try std.testing.expect(isIdentCont(0x80));
    // '@' is a valid START char but not a CONT char (so `a@b` splits).
    try std.testing.expect(!isIdentCont('@'));
    try std.testing.expect(!isIdentCont(' '));
    try std.testing.expect(!isIdentCont('-'));
    try std.testing.expect(!isIdentCont('.'));
}

test "isQuoteChar only single and double quotes" {
    try std.testing.expect(isQuoteChar('"'));
    try std.testing.expect(isQuoteChar('\''));
    try std.testing.expect(!isQuoteChar('`'));
    try std.testing.expect(!isQuoteChar('a'));
    try std.testing.expect(!isQuoteChar(0));
}

test "isStringDelim honours the per-language delimiter set" {
    const zig_cfg = language.configFor(.zig);
    try std.testing.expect(isStringDelim(zig_cfg, '"'));
    try std.testing.expect(isStringDelim(zig_cfg, '\''));
    try std.testing.expect(!isStringDelim(zig_cfg, '`'));
    // unknown has no string delimiters at all.
    const unknown_cfg = language.configFor(.unknown);
    try std.testing.expect(!isStringDelim(unknown_cfg, '"'));
    try std.testing.expect(!isStringDelim(unknown_cfg, '\''));
}

test "isTripleClose true only on three matching quotes" {
    const cfg = language.configFor(.python);
    {
        var lx = Lexer{ .gpa = std.testing.allocator, .source =
            \\"""x
        , .cfg = cfg };
        try std.testing.expect(isTripleClose(&lx, '"'));
        // Wrong quote char never closes.
        try std.testing.expect(!isTripleClose(&lx, '\''));
    }
    {
        var lx = Lexer{ .gpa = std.testing.allocator, .source =
            \\""x
        , .cfg = cfg };
        try std.testing.expect(!isTripleClose(&lx, '"'));
    }
    {
        var lx = Lexer{ .gpa = std.testing.allocator, .source =
            \\'''
        , .cfg = cfg };
        try std.testing.expect(isTripleClose(&lx, '\''));
    }
}

test "isRustCharLiteral distinguishes char literals from lifetimes" {
    const cfg = language.configFor(.rust);
    // 'x' -> closing quote at offset 2 -> char literal.
    {
        var lx = Lexer{ .gpa = std.testing.allocator, .source =
            \\'x'
        , .cfg = cfg };
        try std.testing.expect(isRustCharLiteral(&lx));
    }
    // '\n' -> escape at offset 1 -> char literal.
    {
        var lx = Lexer{ .gpa = std.testing.allocator, .source =
            \\'\n'
        , .cfg = cfg };
        try std.testing.expect(isRustCharLiteral(&lx));
    }
    // 'ab -> no closing quote at offset 2 -> lifetime, not a char literal.
    {
        var lx = Lexer{ .gpa = std.testing.allocator, .source =
            \\'ab
        , .cfg = cfg };
        try std.testing.expect(!isRustCharLiteral(&lx));
    }
    // 'static -> lifetime.
    {
        var lx = Lexer{ .gpa = std.testing.allocator, .source =
            \\'static
        , .cfg = cfg };
        try std.testing.expect(!isRustCharLiteral(&lx));
    }
}

test "detectPyFString matches f/F prefixes and 2-char raw-f combos only" {
    const cfg = language.configFor(.python);
    const Case = struct { src: []const u8, quote: u8, prefix: u32 };
    const yes = [_]Case{
        .{ .src = "f\"x\"", .quote = '"', .prefix = 1 },
        .{ .src = "F'x'", .quote = '\'', .prefix = 1 },
        .{ .src = "rf\"x\"", .quote = '"', .prefix = 2 },
        .{ .src = "fr'x'", .quote = '\'', .prefix = 2 },
        .{ .src = "Rf\"x\"", .quote = '"', .prefix = 2 },
        .{ .src = "fR\"x\"", .quote = '"', .prefix = 2 },
    };
    for (yes) |cse| {
        var lx = Lexer{ .gpa = std.testing.allocator, .source = cse.src, .cfg = cfg };
        const got = detectPyFString(&lx);
        try std.testing.expect(got != null);
        try std.testing.expectEqual(cse.quote, got.?.quote);
        try std.testing.expectEqual(cse.prefix, got.?.prefix_len);
    }
    // Non-f strings and non-strings never match.
    const no = [_][]const u8{ "r\"x\"", "b\"x\"", "\"x\"", "foo", "f x", "rr\"x\"" };
    for (no) |src| {
        var lx = Lexer{ .gpa = std.testing.allocator, .source = src, .cfg = cfg };
        try std.testing.expect(detectPyFString(&lx) == null);
    }
}

// ---- tokenize: structural basics -----------------------------------

test "empty source yields only an eof token at offset 0" {
    const gpa = std.testing.allocator;
    var toks = try lexAll(gpa, "", .zig);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), toks.items.len);
    try std.testing.expectEqual(TokenKind.eof, toks.items[0].kind);
    try std.testing.expectEqual(@as(u32, 0), toks.items[0].start);
}

test "whitespace-only source yields only an eof token" {
    const gpa = std.testing.allocator;
    var toks = try lexAll(gpa, "  \n\t\r  \n", .zig);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), toks.items.len);
    try std.testing.expectEqual(TokenKind.eof, toks.items[0].kind);
}

test "tokenize always appends a trailing eof token last" {
    const gpa = std.testing.allocator;
    var toks = try lexAll(gpa, "const x = 1;", .zig);
    defer toks.deinit(gpa);
    try std.testing.expect(toks.items.len > 1);
    try std.testing.expectEqual(TokenKind.eof, toks.items[toks.items.len - 1].kind);
    // Exactly one eof, and it is last.
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .eof));
}

test "Token.text returns the exact source slice" {
    const gpa = std.testing.allocator;
    const src = "abc + def";
    var toks = try lexAll(gpa, src, .zig);
    defer toks.deinit(gpa);
    const id = firstOfKind(toks.items, .identifier).?;
    try std.testing.expectEqualStrings("abc", id.text(src));
    try std.testing.expect(hasIdent(toks.items, src, "def"));
    try std.testing.expect(hasPunct(toks.items, src, '+'));
}

test "line and column are tracked across newlines and within a line" {
    const gpa = std.testing.allocator;
    const src = "const x\ny\nzz";
    var toks = try lexAll(gpa, src, .zig);
    defer toks.deinit(gpa);
    // `const` starts line 1 col 0; `x` is on line 1 at col 6.
    try std.testing.expectEqual(@as(u32, 1), toks.items[0].line);
    try std.testing.expectEqual(@as(u32, 0), toks.items[0].col);
    try std.testing.expectEqual(@as(u32, 6), toks.items[1].col);
    try std.testing.expectEqual(@as(u32, 1), toks.items[1].line);
    // `y` -> line 2 col 0; `zz` -> line 3 col 0.
    var saw_y = false;
    var saw_zz = false;
    for (toks.items) |t| {
        if (t.kind != .identifier) continue;
        if (std.mem.eql(u8, t.text(src), "y")) {
            saw_y = true;
            try std.testing.expectEqual(@as(u32, 2), t.line);
            try std.testing.expectEqual(@as(u32, 0), t.col);
        }
        if (std.mem.eql(u8, t.text(src), "zz")) {
            saw_zz = true;
            try std.testing.expectEqual(@as(u32, 3), t.line);
        }
    }
    try std.testing.expect(saw_y and saw_zz);
}

// ---- numbers -------------------------------------------------------

test "numbers with underscore digit separators are a single token" {
    const gpa = std.testing.allocator;
    const src = "const n = 1_000_000;";
    var toks = try lexAll(gpa, src, .zig);
    defer toks.deinit(gpa);
    const num = firstOfKind(toks.items, .number).?;
    try std.testing.expectEqualStrings("1_000_000", num.text(src));
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .number));
}

test "hex, float and alnum-suffixed numbers are single number tokens" {
    const gpa = std.testing.allocator;
    // Hex + underscore, float, and a Rust-style typed literal all stay one token.
    const src = "let a = 0xDEAD_BEEF; let b = 3.14; let c = 1000u32;";
    var toks = try lexAll(gpa, src, .rust);
    defer toks.deinit(gpa);
    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(gpa);
    for (toks.items) |t| {
        if (t.kind == .number) try texts.append(gpa, t.text(src));
    }
    try std.testing.expectEqual(@as(usize, 3), texts.items.len);
    try std.testing.expectEqualStrings("0xDEAD_BEEF", texts.items[0]);
    try std.testing.expectEqualStrings("3.14", texts.items[1]);
    try std.testing.expectEqualStrings("1000u32", texts.items[2]);
}

// ---- comments ------------------------------------------------------

test "zig line comment: plain vs doc (/// and //!) is_doc flag" {
    const gpa = std.testing.allocator;
    const src =
        \\// plain comment ghostA
        \\/// doc comment ghostB
        \\//! module doc ghostC
        \\const real = 1;
    ;
    var toks = try lexAll(gpa, src, .zig);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), countKind(toks.items, .comment));
    var plain_doc = true;
    var slashes_doc = false;
    var bang_doc = false;
    for (toks.items) |t| {
        if (t.kind != .comment) continue;
        const txt = t.text(src);
        if (std.mem.indexOf(u8, txt, "ghostA") != null) plain_doc = t.is_doc;
        if (std.mem.indexOf(u8, txt, "ghostB") != null) slashes_doc = t.is_doc;
        if (std.mem.indexOf(u8, txt, "ghostC") != null) bang_doc = t.is_doc;
    }
    try std.testing.expect(!plain_doc); // `//` is not a doc comment
    try std.testing.expect(slashes_doc); // `///` is
    try std.testing.expect(bang_doc); // `//!` is
    // Comment contents never surface as identifiers.
    try std.testing.expect(!hasIdent(toks.items, src, "ghostA"));
    try std.testing.expect(hasIdent(toks.items, src, "real"));
}

test "python # line comment hides its contents" {
    const gpa = std.testing.allocator;
    const src =
        \\# def hidden(): pass
        \\value = 1
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .comment));
    try std.testing.expect(!hasIdent(toks.items, src, "hidden"));
    try std.testing.expect(hasIdent(toks.items, src, "value"));
    // A python # comment is never a doc comment via the lexer.
    try std.testing.expect(!firstOfKind(toks.items, .comment).?.is_doc);
}

test "C block comment: /** is doc, /* is not, contents hidden" {
    const gpa = std.testing.allocator;
    const src =
        \\/** doc block ghostDoc */
        \\/* plain block ghostPlain */
        \\int real;
    ;
    var toks = try lexAll(gpa, src, .c);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), countKind(toks.items, .comment));
    for (toks.items) |t| {
        if (t.kind != .comment) continue;
        const txt = t.text(src);
        if (std.mem.indexOf(u8, txt, "ghostDoc") != null) try std.testing.expect(t.is_doc);
        if (std.mem.indexOf(u8, txt, "ghostPlain") != null) try std.testing.expect(!t.is_doc);
    }
    try std.testing.expect(!hasIdent(toks.items, src, "ghostDoc"));
    try std.testing.expect(hasIdent(toks.items, src, "real"));
}

test "multi-line block comment is one token and hides interior code" {
    const gpa = std.testing.allocator;
    const src =
        \\int before;
        \\/* line one
        \\   int hidden;
        \\   line three */
        \\int after;
    ;
    var toks = try lexAll(gpa, src, .c);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .comment));
    try std.testing.expect(hasIdent(toks.items, src, "before"));
    try std.testing.expect(hasIdent(toks.items, src, "after"));
    try std.testing.expect(!hasIdent(toks.items, src, "hidden"));
}

test "unterminated block comment runs to EOF without crashing" {
    const gpa = std.testing.allocator;
    const src =
        \\int a; /* never closed int b;
    ;
    var toks = try lexAll(gpa, src, .c);
    defer toks.deinit(gpa);
    try std.testing.expect(hasIdent(toks.items, src, "a"));
    // Everything after the unterminated opener is swallowed by the comment.
    try std.testing.expect(!hasIdent(toks.items, src, "b"));
    const cmt = firstOfKind(toks.items, .comment).?;
    try std.testing.expectEqual(@as(u32, @intCast(src.len)), cmt.end);
}

test "lua: --[[ block ]] is preferred over -- line comment" {
    const gpa = std.testing.allocator;
    const src =
        \\--[[ block with function ghostBlock
        \\ still in block ]]
        \\-- line function ghostLine
        \\function shown() end
    ;
    var toks = try lexAll(gpa, src, .lua);
    defer toks.deinit(gpa);
    // one block comment + one line comment.
    try std.testing.expectEqual(@as(usize, 2), countKind(toks.items, .comment));
    try std.testing.expect(!hasIdent(toks.items, src, "ghostBlock"));
    try std.testing.expect(!hasIdent(toks.items, src, "ghostLine"));
    try std.testing.expect(hasIdent(toks.items, src, "shown"));
    // lua doc_style is none -> no comment is ever a doc comment.
    for (toks.items) |t| {
        if (t.kind == .comment) try std.testing.expect(!t.is_doc);
    }
}

// ---- strings -------------------------------------------------------

test "plain double-quoted string is one opaque token; escapes stay inside" {
    const gpa = std.testing.allocator;
    const src =
        \\const char *s = "a\"b\"c"; int after;
    ;
    var toks = try lexAll(gpa, src, .c);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    // Escaped quotes do not terminate the string, so b/c never surface.
    try std.testing.expect(!hasIdent(toks.items, src, "b"));
    try std.testing.expect(!hasIdent(toks.items, src, "c"));
    try std.testing.expect(hasIdent(toks.items, src, "after"));
}

test "single-quoted string in value position hides its contents" {
    const gpa = std.testing.allocator;
    const src =
        \\name = 'hidden_word'
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    try std.testing.expect(!hasIdent(toks.items, src, "hidden_word"));
    try std.testing.expect(hasIdent(toks.items, src, "name"));
}

test "python triple-quoted string spans lines as one token" {
    const gpa = std.testing.allocator;
    const src =
        \\doc = """
        \\def hidden(): pass
        \\class AlsoHidden: ...
        \\"""
        \\value = 1
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    try std.testing.expect(!hasIdent(toks.items, src, "hidden"));
    try std.testing.expect(!hasIdent(toks.items, src, "AlsoHidden"));
    try std.testing.expect(hasIdent(toks.items, src, "value"));
}

test "triple-single-quoted string with interior single quotes stays one token" {
    const gpa = std.testing.allocator;
    const src =
        \\doc = '''it's a 'quoted' thing with fn ghost'''
        \\value = 1
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    try std.testing.expect(!hasIdent(toks.items, src, "ghost"));
    try std.testing.expect(hasIdent(toks.items, src, "value"));
}

test "unterminated triple-quoted string runs to EOF without crashing" {
    const gpa = std.testing.allocator;
    const src =
        \\doc = """never closed def ghost(): pass
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    const s = firstOfKind(toks.items, .string).?;
    try std.testing.expectEqual(@as(u32, @intCast(src.len)), s.end);
    try std.testing.expect(!hasIdent(toks.items, src, "ghost"));
}

test "go backtick raw string is one token and interpolation is not code" {
    const gpa = std.testing.allocator;
    const src =
        \\const s = `raw with func ghostGo and ${notCode}`
        \\func realGo() {}
    ;
    var toks = try lexAll(gpa, src, .go);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    try std.testing.expect(!hasIdent(toks.items, src, "ghostGo"));
    try std.testing.expect(!hasIdent(toks.items, src, "notCode"));
    try std.testing.expect(hasIdent(toks.items, src, "realGo"));
}

test "JS backtick template literal is one string; ${} is not tokenized as code" {
    const gpa = std.testing.allocator;
    const src =
        \\const s = `hello ${userName} world`;
        \\function afterTpl() {}
    ;
    var toks = try lexAll(gpa, src, .typescript);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    // JS template interpolation is (deliberately) NOT split into code tokens.
    try std.testing.expect(!hasIdent(toks.items, src, "userName"));
    try std.testing.expect(hasIdent(toks.items, src, "afterTpl"));
}

// ---- zig line strings ----------------------------------------------

test "zig line string swallows quotes and code-shaped text on the line" {
    const gpa = std.testing.allocator;
    const src =
        \\const s =
        \\    \\ "not a string" and 'x' fn ghost()
        \\;
        \\pub fn survive() void {}
    ;
    var toks = try lexAll(gpa, src, .zig);
    defer toks.deinit(gpa);
    // The `\\...` line lexes as exactly one string token; the quotes inside do
    // NOT open real string literals.
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    try std.testing.expect(!hasIdent(toks.items, src, "ghost"));
    try std.testing.expect(!hasIdent(toks.items, src, "not"));
    try std.testing.expect(hasIdent(toks.items, src, "survive"));
    try std.testing.expect(hasIdent(toks.items, src, "s"));
}

// ---- python f-strings ----------------------------------------------

test "f-string literal chunks are strings and holes are code" {
    const gpa = std.testing.allocator;
    const src =
        \\msg = f"pre {value} post"
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    // "pre " and " post" become two separate string chunks; `value` is code.
    try std.testing.expectEqual(@as(usize, 2), countKind(toks.items, .string));
    try std.testing.expect(hasIdent(toks.items, src, "value"));
    try std.testing.expect(hasIdent(toks.items, src, "msg"));
}

test "f-string escaped braces {{ }} are literal, not interpolation holes" {
    const gpa = std.testing.allocator;
    const src =
        \\s = f"{{not_a_hole}} {real_var}"
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expect(!hasIdent(toks.items, src, "not_a_hole"));
    try std.testing.expect(hasIdent(toks.items, src, "real_var"));
}

test "f-string format spec has nested braces; both names surface" {
    const gpa = std.testing.allocator;
    const src =
        \\s = f"{val:>{width}}"
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expect(hasIdent(toks.items, src, "val"));
    try std.testing.expect(hasIdent(toks.items, src, "width"));
}

test "nested f-string inside a hole tokenizes the inner name" {
    const gpa = std.testing.allocator;
    const src =
        \\s = f"{f'{inner_name}'}"
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expect(hasIdent(toks.items, src, "inner_name"));
}

test "raw f-string (rf prefix) still interpolates" {
    const gpa = std.testing.allocator;
    const src =
        \\p = rf"\d+ {captured}"
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expect(hasIdent(toks.items, src, "captured"));
    try std.testing.expect(hasIdent(toks.items, src, "p"));
}

test "triple-quoted f-string interpolates across lines" {
    const gpa = std.testing.allocator;
    const src =
        \\s = f"""
        \\head {compute(y)} tail
        \\"""
        \\value = 1
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expect(hasIdent(toks.items, src, "compute"));
    try std.testing.expect(hasIdent(toks.items, src, "y"));
    try std.testing.expect(hasIdent(toks.items, src, "value"));
}

test "empty f-string does not crash and produces no code tokens" {
    const gpa = std.testing.allocator;
    const src =
        \\s = f"" + after
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    try std.testing.expect(hasIdent(toks.items, src, "after"));
    try std.testing.expect(hasIdent(toks.items, src, "s"));
    // No identifier came from inside the (empty) f-string.
    try std.testing.expect(countKind(toks.items, .string) >= 1);
}

test "f-string interpolation keeps the token stream sorted by start offset" {
    const gpa = std.testing.allocator;
    const src =
        \\m = f"a {x} b {g(y)} c"
    ;
    var toks = try lexAll(gpa, src, .python);
    defer toks.deinit(gpa);
    var last: u32 = 0;
    for (toks.items) |t| {
        try std.testing.expect(t.start >= last);
        last = t.start;
    }
    try std.testing.expect(hasIdent(toks.items, src, "g"));
    try std.testing.expect(hasIdent(toks.items, src, "y"));
}

// ---- char literals & language-specific quote guards ----------------

test "C++ digit separator emits number, punct, number" {
    const gpa = std.testing.allocator;
    const src =
        \\int budget() { return 1'000; }
    ;
    var toks = try lexAll(gpa, src, .cpp);
    defer toks.deinit(gpa);
    // 1'000 -> number("1"), punct("'"), number("000"); no string opened.
    try std.testing.expectEqual(@as(usize, 0), countKind(toks.items, .string));
    try std.testing.expect(hasPunct(toks.items, src, '\''));
    try std.testing.expect(countKind(toks.items, .number) >= 2);
}

test "C char literal (no number before) stays a string and hides its char" {
    const gpa = std.testing.allocator;
    const src =
        \\char c = 'a'; int after;
    ;
    var toks = try lexAll(gpa, src, .c);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    try std.testing.expect(!hasIdent(toks.items, src, "a"));
    try std.testing.expect(hasIdent(toks.items, src, "after"));
}

test "C++ u8 char prefix keeps the char literal intact" {
    const gpa = std.testing.allocator;
    // Previous token before the quote is the identifier `u8`, not a number,
    // so the digit-separator guard does not fire and 'x' is a char literal.
    const src =
        \\char cc = u8'x'; int fnAfter(int q) { return q; }
    ;
    var toks = try lexAll(gpa, src, .cpp);
    defer toks.deinit(gpa);
    try std.testing.expect(!hasIdent(toks.items, src, "x"));
    try std.testing.expect(hasIdent(toks.items, src, "fnAfter"));
    try std.testing.expect(countKind(toks.items, .string) >= 1);
}

test "rust lifetimes do not open strings; names around them survive" {
    const gpa = std.testing.allocator;
    const src =
        \\fn longest<'a>(x: &'a str) -> &'a str { x }
        \\fn afterFn() {}
    ;
    var toks = try lexAll(gpa, src, .rust);
    defer toks.deinit(gpa);
    // Lifetimes are punct + ident, never strings.
    try std.testing.expectEqual(@as(usize, 0), countKind(toks.items, .string));
    try std.testing.expect(hasIdent(toks.items, src, "longest"));
    try std.testing.expect(hasIdent(toks.items, src, "str"));
    try std.testing.expect(hasIdent(toks.items, src, "afterFn"));
    // The lifetime name `a` surfaces as a normal identifier.
    try std.testing.expect(hasIdent(toks.items, src, "a"));
}

test "rust char literal is a string; code after it survives" {
    const gpa = std.testing.allocator;
    const src =
        \\fn f() { let c = 'x'; let n = '\n'; bar(); }
    ;
    var toks = try lexAll(gpa, src, .rust);
    defer toks.deinit(gpa);
    // Two char literals -> two string tokens; the inner chars do not leak.
    try std.testing.expectEqual(@as(usize, 2), countKind(toks.items, .string));
    try std.testing.expect(!hasIdent(toks.items, src, "x"));
    try std.testing.expect(hasIdent(toks.items, src, "bar"));
}

test "JSX prose apostrophe becomes punct; word halves both surface" {
    const gpa = std.testing.allocator;
    const src =
        \\function V() { return <p>you'll and don't end</p>; }
        \\function afterProse() { return realCall(); }
    ;
    var toks = try lexAll(gpa, src, .tsx);
    defer toks.deinit(gpa);
    // No string swallows the rest of the file.
    try std.testing.expect(hasIdent(toks.items, src, "realCall"));
    try std.testing.expect(hasIdent(toks.items, src, "afterProse"));
    // The apostrophe is emitted as punct, so `you` and `ll` both surface.
    try std.testing.expect(hasIdent(toks.items, src, "you"));
    try std.testing.expect(hasIdent(toks.items, src, "ll"));
    try std.testing.expect(hasPunct(toks.items, src, '\''));
}

test "real single-quoted JS value string is still a string" {
    const gpa = std.testing.allocator;
    const src =
        \\const mode = 'production_mode';
    ;
    var toks = try lexAll(gpa, src, .javascript);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), countKind(toks.items, .string));
    try std.testing.expect(!hasIdent(toks.items, src, "production_mode"));
    try std.testing.expect(hasIdent(toks.items, src, "mode"));
}

// ---- zig @"..." identifiers & @builtins ----------------------------

test "zig @-builtin lexes as a single identifier token" {
    const gpa = std.testing.allocator;
    const src =
        \\const std = @import("x");
    ;
    var toks = try lexAll(gpa, src, .zig);
    defer toks.deinit(gpa);
    try std.testing.expect(hasIdent(toks.items, src, "@import"));
}

test "zig @\"quoted identifier\" spans the quotes as one identifier" {
    const gpa = std.testing.allocator;
    const src =
        \\const @"has space" = 5;
        \\pub fn realFn() void {}
    ;
    var toks = try lexAll(gpa, src, .zig);
    defer toks.deinit(gpa);
    var found = false;
    for (toks.items) |t| {
        if (t.kind == .identifier and std.mem.eql(u8, t.text(src), "@\"has space\"")) found = true;
    }
    try std.testing.expect(found);
    // The interior words are not separate identifiers, and it is NOT a string.
    try std.testing.expect(!hasIdent(toks.items, src, "has"));
    try std.testing.expect(!hasIdent(toks.items, src, "space"));
    try std.testing.expectEqual(@as(usize, 0), countKind(toks.items, .string));
    try std.testing.expect(hasIdent(toks.items, src, "realFn"));
}

// ---- unknown language (no comment/string config) -------------------

test "unknown language: no string delims means quotes are punct and names leak" {
    const gpa = std.testing.allocator;
    const src =
        \\"hello" world
    ;
    var toks = try lexAll(gpa, src, .unknown);
    defer toks.deinit(gpa);
    // Nothing is a string or comment; `hello` surfaces as an identifier.
    try std.testing.expectEqual(@as(usize, 0), countKind(toks.items, .string));
    try std.testing.expectEqual(@as(usize, 0), countKind(toks.items, .comment));
    try std.testing.expect(hasIdent(toks.items, src, "hello"));
    try std.testing.expect(hasIdent(toks.items, src, "world"));
}

test "unknown language: // is not a comment marker" {
    const gpa = std.testing.allocator;
    const src =
        \\// notacomment here
    ;
    var toks = try lexAll(gpa, src, .unknown);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countKind(toks.items, .comment));
    try std.testing.expect(hasIdent(toks.items, src, "notacomment"));
}

// ---- single-char punctuation & division vs comment -----------------

test "zig single slash is punct division, not a comment" {
    const gpa = std.testing.allocator;
    const src = "const q = a / b;";
    var toks = try lexAll(gpa, src, .zig);
    defer toks.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), countKind(toks.items, .comment));
    try std.testing.expect(hasPunct(toks.items, src, '/'));
    try std.testing.expect(hasIdent(toks.items, src, "a"));
    try std.testing.expect(hasIdent(toks.items, src, "b"));
}
