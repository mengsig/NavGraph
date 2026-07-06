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
        if (try lexComment(&lx, out)) continue;
        if (isStringDelim(cfg, c) or (cfg.template_strings and c == '`')) {
            try lexString(&lx, out, c);
            continue;
        }
        if (isIdentStart(c)) {
            try lexIdentifier(&lx, out);
            continue;
        }
        if (std.ascii.isDigit(c)) {
            try lexNumber(&lx, out);
            continue;
        }
        try appendSingle(&lx, out, .punct);
    }
    try out.append(gpa, .{ .kind = .eof, .start = lx.pos, .end = lx.pos, .line = lx.line, .col = lx.col });
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
