//! Tokenizer for the tiny reverse-polish stack VM.
//!
//! The lexer turns a byte slice into a flat stream of `Token`s. It is a plain
//! hand-written scanner: no allocation, no lookahead beyond one byte.

const std = @import("std");

/// The lexical category of a `Token`.
pub const TokenKind = enum {
    number,
    plus,
    minus,
    star,
    slash,
    eof,

    /// Human-readable spelling of this kind, for diagnostics.
    pub fn name(self: TokenKind) []const u8 {
        return switch (self) {
            .number => "number",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .eof => "eof",
        };
    }
};

/// A single lexical token with its (optional) integer payload.
pub const Token = struct {
    kind: TokenKind,
    value: i64 = 0,
};

/// A hand-written scanner over an immutable byte slice.
pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    /// Produce the next token and advance past it.
    pub fn next(self: *Lexer) Token {
        self.skipSpaces();
        if (self.pos >= self.src.len) return .{ .kind = .eof };
        const c = self.src[self.pos];
        if (c >= '0' and c <= '9') return self.readNumber();
        self.pos += 1;
        return .{ .kind = symbolKind(c) };
    }

    /// Look at the current byte without consuming it (0 at end of input).
    pub fn peek(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn skipSpaces(self: *Lexer) void {
        while (self.pos < self.src.len and self.src[self.pos] == ' ') self.pos += 1;
    }

    fn readNumber(self: *Lexer) Token {
        var v: i64 = 0;
        while (self.peek() >= '0' and self.peek() <= '9') {
            v = v * 10 + @as(i64, self.src[self.pos] - '0');
            self.pos += 1;
        }
        return .{ .kind = .number, .value = v };
    }
};

fn symbolKind(c: u8) TokenKind {
    return switch (c) {
        '+' => .plus,
        '-' => .minus,
        '*' => .star,
        else => .slash,
    };
}

/// Tokenize `src` into `out`, returning the number of tokens written (including
/// the trailing `eof`). Stops early if `out` fills up.
pub fn tokenize(src: []const u8, out: []Token) usize {
    var lx = Lexer{ .src = src };
    var n: usize = 0;
    while (n < out.len) {
        const t = lx.next();
        out[n] = t;
        n += 1;
        if (t.kind == .eof) break;
    }
    return n;
}

/// Rewind a lexer back to the start of its source. Handy for a second pass,
/// though nothing needs it yet.
pub fn rewind(lx: *Lexer) void {
    lx.pos = 0;
}
