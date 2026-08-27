//! LSP positions (0-based line + character) ↔ byte offsets, and the identifier
//! under a position.
//!
//! LSP measures `character` in code units of the negotiated position encoding:
//! UTF-16 by default, UTF-8 when the client offers it. Everything navgraph
//! stores is byte-offset based, so both directions convert here and nowhere
//! else. Symbol lines in navgraph payloads stay 1-based (matching the CLI);
//! only LSP `Position`/`Range` values are 0-based.

const std = @import("std");
const lexer = @import("../lexer.zig");

pub const Encoding = enum {
    utf8,
    utf16,

    /// The value negotiated back to the client in `initialize`.
    pub fn name(self: Encoding) []const u8 {
        return switch (self) {
            .utf8 => "utf-8",
            .utf16 => "utf-16",
        };
    }
};

pub const Position = struct { line: u32, character: u32 };

/// Byte range of one line, excluding its terminator.
pub fn lineSlice(text: []const u8, line: u32) ?[]const u8 {
    const start = lineStart(text, line) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return std.mem.trimEnd(u8, text[start..end], "\r");
}

/// Byte offset where 0-based `line` begins, or null when the text has no such
/// line. A trailing newline does *not* create a final empty line here; callers
/// that clamp out-of-range positions handle that.
pub fn lineStart(text: []const u8, line: u32) ?usize {
    if (line == 0) return 0;
    var seen: u32 = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '\n')) |nl| {
        seen += 1;
        i = nl + 1;
        if (seen == line) return i;
    }
    return null;
}

/// Byte offset of an LSP position. `character` is clamped to the end of the
/// line (clients legitimately send a column past the end after an edit), and a
/// line past the end of the text clamps to `text.len`.
pub fn offsetAt(text: []const u8, pos: Position, enc: Encoding) usize {
    const start = lineStart(text, pos.line) orelse return text.len;
    const line = lineSlice(text, pos.line).?;
    return start + columnToByte(line, pos.character, enc);
}

/// Byte offset within `line` for a `character` measured in `enc` code units.
/// Clamps to `line.len`; a character landing inside a multi-byte sequence (a
/// UTF-16 column splitting a surrogate pair) snaps to that sequence's start.
pub fn columnToByte(line: []const u8, character: u32, enc: Encoding) usize {
    if (enc == .utf8) return @min(character, line.len);
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        const cp_bytes = @min(sequenceLength(line[i]), line.len - i);
        const width = utf16Units(line[i..][0..cp_bytes]);
        if (units + width > character) return i;
        units += width;
        i += cp_bytes;
    }
    return line.len;
}

/// The LSP position of a byte offset. The inverse of `offsetAt`.
pub fn positionAt(text: []const u8, offset: usize, enc: Encoding) Position {
    const at = @min(offset, text.len);
    var line: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '\n')) |nl| {
        if (nl >= at) break;
        line += 1;
        start = nl + 1;
        i = nl + 1;
    }
    return .{ .line = line, .character = byteToColumn(text[start..at], enc) };
}

/// Width of `bytes` in `enc` code units.
pub fn byteToColumn(bytes: []const u8, enc: Encoding) u32 {
    if (enc == .utf8) return @intCast(bytes.len);
    var units: u32 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = @min(sequenceLength(bytes[i]), bytes.len - i);
        units += utf16Units(bytes[i..][0..len]);
        i += len;
    }
    return units;
}

/// Byte length of the UTF-8 sequence starting with `first`. A malformed lead
/// byte counts as one byte so conversion always advances.
fn sequenceLength(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

/// UTF-16 code units for one UTF-8 sequence: 2 for astral code points (a
/// surrogate pair), else 1. Malformed bytes count as 1.
fn utf16Units(seq: []const u8) u32 {
    return if (seq.len == 4) 2 else 1;
}

// ---------------------------------------------------------------------------
// Identifier extraction
// ---------------------------------------------------------------------------

/// The identifier under a byte offset, with the receiver it is accessed through.
pub const Ident = struct {
    /// The identifier text (a slice of the source).
    name: []const u8,
    /// Receiver of a member access `recv.name`, else "". Mirrors
    /// `model.Reference.qualifier`, which is how the graph scopes resolution.
    qualifier: []const u8,
    /// Byte range of `name` in the source.
    start: usize,
    end: usize,
};

/// Extract the identifier containing (or immediately before) `offset`.
///
/// Cursor placement matches editor convention: a cursor sitting just past the
/// last character of a word still selects that word. Returns null when the
/// offset is not on an identifier.
pub fn identifierAt(text: []const u8, offset: usize) ?Ident {
    if (text.len == 0) return null;
    var at = @min(offset, text.len);
    // A cursor just past a word (or at end of text) still names that word.
    if ((at == text.len or !lexer.isIdentCont(text[at])) and at > 0 and lexer.isIdentCont(text[at - 1])) {
        at -= 1;
    }
    if (at >= text.len or !lexer.isIdentCont(text[at])) return null;

    var start = at;
    while (start > 0 and lexer.isIdentCont(text[start - 1])) start -= 1;
    var end = at + 1;
    while (end < text.len and lexer.isIdentCont(text[end])) end += 1;
    if (!lexer.isIdentStart(text[start])) return null; // a bare number

    return .{
        .name = text[start..end],
        .qualifier = qualifierBefore(text, start),
        .start = start,
        .end = end,
    };
}

/// The receiver of a member access ending at `start` (`recv.name`), else "".
/// Whitespace between the receiver, the dot and the name is tolerated, as is a
/// Rust/C++ `::` separator.
fn qualifierBefore(text: []const u8, start: usize) []const u8 {
    var i = start;
    while (i > 0 and isSpace(text[i - 1])) i -= 1;
    if (i == 0 or text[i - 1] != '.') {
        if (i >= 2 and text[i - 1] == ':' and text[i - 2] == ':') {
            i -= 2;
        } else return "";
    } else i -= 1;
    while (i > 0 and isSpace(text[i - 1])) i -= 1;
    const q_end = i;
    while (i > 0 and lexer.isIdentCont(text[i - 1])) i -= 1;
    if (i == q_end) return "";
    return text[i..q_end];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// The 0-based `enc` column where `name` occurs on 1-based `line`, or 0 when it
/// is not found. Used to point a `Location` at the name rather than the margin.
pub fn columnOfName(text: []const u8, line_1based: u32, name: []const u8, enc: Encoding) u32 {
    if (line_1based == 0 or name.len == 0) return 0;
    const line = lineSlice(text, line_1based - 1) orelse return 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, name)) |at| {
        const before_ok = at == 0 or !lexer.isIdentCont(line[at - 1]);
        const after = at + name.len;
        const after_ok = after >= line.len or !lexer.isIdentCont(line[after]);
        if (before_ok and after_ok) return byteToColumn(line[0..at], enc);
        from = at + 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lineStart and lineSlice locate 0-based lines and strip CR" {
    const text = "one\r\ntwo\nthree";
    try testing.expectEqual(@as(usize, 0), lineStart(text, 0).?);
    try testing.expectEqual(@as(usize, 5), lineStart(text, 1).?);
    try testing.expectEqual(@as(usize, 9), lineStart(text, 2).?);
    try testing.expect(lineStart(text, 3) == null);
    try testing.expectEqualStrings("one", lineSlice(text, 0).?);
    try testing.expectEqualStrings("two", lineSlice(text, 1).?);
    try testing.expectEqualStrings("three", lineSlice(text, 2).?);
}

test "offsetAt and positionAt round-trip on ASCII" {
    const text = "abc\ndefgh\nij";
    for ([_]Position{
        .{ .line = 0, .character = 0 },
        .{ .line = 0, .character = 3 },
        .{ .line = 1, .character = 2 },
        .{ .line = 2, .character = 1 },
    }) |p| {
        const off = offsetAt(text, p, .utf8);
        const back = positionAt(text, off, .utf8);
        try testing.expectEqual(p.line, back.line);
        try testing.expectEqual(p.character, back.character);
    }
    try testing.expectEqual(@as(usize, 6), offsetAt(text, .{ .line = 1, .character = 2 }, .utf8));
}

test "offsetAt clamps a character past the end of the line and a line past the end" {
    const text = "abc\ndef";
    try testing.expectEqual(@as(usize, 3), offsetAt(text, .{ .line = 0, .character = 99 }, .utf8));
    try testing.expectEqual(text.len, offsetAt(text, .{ .line = 9, .character = 0 }, .utf8));
}

test "utf-16 columns count code units, not bytes, on a multibyte line" {
    // "héllo" — é is 2 UTF-8 bytes, 1 UTF-16 unit.
    const text = "h\u{e9}llo world";
    try testing.expectEqual(@as(usize, 6), offsetAt(text, .{ .line = 0, .character = 5 }, .utf16));
    try testing.expectEqual(@as(usize, 5), offsetAt(text, .{ .line = 0, .character = 5 }, .utf8));
    try testing.expectEqual(@as(u32, 5), positionAt(text, 6, .utf16).character);
    try testing.expectEqual(@as(u32, 6), positionAt(text, 6, .utf8).character);
}

test "utf-16 counts an astral code point as a surrogate pair" {
    // "a😀b": the emoji is 4 UTF-8 bytes and 2 UTF-16 units.
    const text = "a\u{1F600}b";
    try testing.expectEqual(@as(u32, 3), byteToColumn(text[0..5], .utf16));
    try testing.expectEqual(@as(u32, 5), byteToColumn(text[0..5], .utf8));
    // Character 3 (just past the pair) is byte 5.
    try testing.expectEqual(@as(usize, 5), offsetAt(text, .{ .line = 0, .character = 3 }, .utf16));
    // A character landing mid-pair snaps to the sequence start.
    try testing.expectEqual(@as(usize, 1), offsetAt(text, .{ .line = 0, .character = 2 }, .utf16));
}

test "positionAt on a later line measures the column from that line's start" {
    const text = "one\nh\u{e9}llo";
    const p = positionAt(text, text.len, .utf16);
    try testing.expectEqual(@as(u32, 1), p.line);
    try testing.expectEqual(@as(u32, 5), p.character);
}

test "identifierAt finds the word under and just past the cursor" {
    const text = "fn resolveOne(x) {}";
    const mid = identifierAt(text, 6).?;
    try testing.expectEqualStrings("resolveOne", mid.name);
    try testing.expectEqualStrings("", mid.qualifier);
    try testing.expectEqual(@as(usize, 3), mid.start);
    try testing.expectEqual(@as(usize, 13), mid.end);
    // Cursor at the first byte, and just past the last byte, both select it.
    try testing.expectEqualStrings("resolveOne", identifierAt(text, 3).?.name);
    try testing.expectEqualStrings("resolveOne", identifierAt(text, 13).?.name);
}

test "identifierAt returns null off an identifier and on a bare number" {
    try testing.expect(identifierAt("a + b", 2) == null);
    try testing.expect(identifierAt("  ", 1) == null);
    try testing.expect(identifierAt("", 0) == null);
    try testing.expect(identifierAt("x = 1234;", 6) == null);
}

test "identifierAt reports the receiver of a member access" {
    try testing.expectEqualStrings("self", identifierAt("self.render();", 7).?.qualifier);
    try testing.expectEqualStrings("idx", identifierAt("idx . lookup(n)", 8).?.qualifier);
    try testing.expectEqualStrings("Type", identifierAt("Type::make()", 8).?.qualifier);
    // A dot with no identifier before it is not a receiver.
    try testing.expectEqualStrings("", identifierAt("().field", 4).?.qualifier);
}

test "identifierAt selects the last word of a dotted chain, not the whole chain" {
    const got = identifierAt("a.b.method(x)", 5).?;
    try testing.expectEqualStrings("method", got.name);
    try testing.expectEqualStrings("b", got.qualifier);
}

test "columnOfName finds a whole-word occurrence in the negotiated encoding" {
    const text = "const x = 1;\n    h\u{e9}llo(run);\n";
    try testing.expectEqual(@as(u32, 6), columnOfName(text, 1, "x", .utf8));
    // `run` sits after a 2-byte é on line 2.
    try testing.expectEqual(@as(u32, 10), columnOfName(text, 2, "run", .utf16));
    try testing.expectEqual(@as(u32, 11), columnOfName(text, 2, "run", .utf8));
    // Not found, or a substring of a longer word, falls back to column 0.
    try testing.expectEqual(@as(u32, 0), columnOfName(text, 1, "nope", .utf8));
    try testing.expectEqual(@as(u32, 0), columnOfName(text, 2, "ell", .utf8));
    try testing.expectEqual(@as(u32, 0), columnOfName(text, 0, "x", .utf8));
}
