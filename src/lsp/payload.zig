//! The editor protocol's JSON shapes.
//!
//! Every navgraph payload is written through here, so the contract in
//! `docs/lsp.md` has exactly one implementation. The shapes deliberately differ
//! from the CLI's `-j` output (they carry `qualified`, `uri`, `endLine` and
//! fan-in/out counts an editor needs), but the underlying values come from the
//! same graph accessors the CLI uses.
//!
//! Convention, per the contract: navgraph symbol `line`/`endLine` stay 1-based
//! as the CLI prints them; LSP `Location`/`Range` values are 0-based.

const std = @import("std");
const model = @import("../model.zig");
const query = @import("../query.zig");
const render = @import("../render.zig");
const overlay = @import("overlay.zig");
const position = @import("position.zig");
const session_mod = @import("session.zig");

const Writer = std.Io.Writer;
const Symbol = model.Symbol;
const SymbolId = model.SymbolId;

/// What every payload writer needs: the live graph and the negotiated position
/// encoding.
pub const Ctx = struct {
    session: *session_mod.Session,
    encoding: position.Encoding,

    pub fn index(self: Ctx) *const @import("../index.zig").Index {
        return &self.session.idx;
    }
};

pub fn writeString(w: *Writer, s: []const u8) !void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// Write `text` as a JSON string with runs of whitespace collapsed to one space
/// and the ends trimmed — a multi-line signature reads as one line in an editor.
pub fn writeCollapsed(w: *Writer, text: []const u8) !void {
    try w.writeByte('"');
    var wrote = false;
    var gap = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            gap = wrote;
            continue;
        }
        if (gap) try w.writeByte(' ');
        gap = false;
        wrote = true;
        try writeEscaped(w, c);
    }
    try w.writeByte('"');
}

fn writeEscaped(w: *Writer, c: u8) !void {
    switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    }
}

// ---------------------------------------------------------------------------
// Symbol
// ---------------------------------------------------------------------------

/// `Parent.name` when the symbol is nested, else `name`. This is the form
/// `query.resolveIds` accepts, so a `qualified` value round-trips as a `Target`.
pub fn writeQualified(w: *Writer, ctx: Ctx, sym: Symbol) !void {
    const idx = ctx.index();
    if (sym.parent == model.invalid_symbol) return writeString(w, sym.name);
    try w.writeByte('"');
    try writeStringBody(w, idx.graph.symbols[sym.parent].name);
    try w.writeByte('.');
    try writeStringBody(w, sym.name);
    try w.writeByte('"');
}

fn writeStringBody(w: *Writer, s: []const u8) !void {
    for (s) |c| try writeEscaped(w, c);
}

/// The contract's `Symbol` object.
pub fn writeSymbol(w: *Writer, ctx: Ctx, sym: Symbol) !void {
    const idx = ctx.index();
    const file = idx.graph.files[sym.file];
    try w.print("{{\"id\":{d},\"name\":", .{sym.id});
    try writeString(w, sym.name);
    try w.writeAll(",\"qualified\":");
    try writeQualified(w, ctx, sym);
    try w.print(",\"kind\":\"{s}\",\"file\":", .{sym.kind.tag()});
    try writeString(w, file.path);
    try w.writeAll(",\"uri\":\"");
    try overlay.writeUriIn(w, ctx.session.root_abs, file.path);
    try w.print("\",\"line\":{d},\"endLine\":{d},\"sig\":", .{ sym.line, sym.endLine(file.text) });
    try writeCollapsed(w, sym.signature(file.text));
    const doc = render.stripDoc(sym.doc);
    if (doc.len != 0) {
        try w.writeAll(",\"doc\":");
        try writeString(w, doc);
    }
    try w.print(",\"language\":\"{s}\",\"callers\":{d},\"callees\":{d},\"exported\":{},\"test\":{}}}", .{
        file.language.tag(),
        idx.callersOf(sym.id).len,
        query.fanOut(sym),
        sym.exported,
        query.isTestSymbol(idx, sym),
    });
}

pub fn writeSymbolId(w: *Writer, ctx: Ctx, id: SymbolId) !void {
    try writeSymbol(w, ctx, ctx.index().graph.symbols[id]);
}

/// A JSON array of symbols.
pub fn writeSymbolArray(w: *Writer, ctx: Ctx, ids: []const SymbolId) !void {
    try w.writeByte('[');
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try writeSymbolId(w, ctx, id);
    }
    try w.writeByte(']');
}

// ---------------------------------------------------------------------------
// LSP Location / Range
// ---------------------------------------------------------------------------

/// A 0-based LSP range covering `name` on 1-based `line`. When the name is not
/// found on that line the range collapses at column 0.
pub fn writeNameRange(w: *Writer, text: []const u8, line_1based: u32, name: []const u8, enc: position.Encoding) !void {
    const line0 = if (line_1based == 0) 0 else line_1based - 1;
    const found = position.columnOfName(text, line_1based, name, enc);
    const col = found orelse 0;
    const width: u32 = if (found == null) 0 else position.byteToColumn(name, enc);
    try w.print(
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ line0, col, line0, col + width },
    );
}

/// An LSP `Location` pointing at `name` on 1-based `line` of `file`.
pub fn writeLocation(w: *Writer, ctx: Ctx, file: model.SourceFile, line: u32, name: []const u8) !void {
    try w.writeAll("{\"uri\":\"");
    try overlay.writeUriIn(w, ctx.session.root_abs, file.path);
    try w.writeAll("\",\"range\":");
    try writeNameRange(w, file.text, line, name, ctx.encoding);
    try w.writeByte('}');
}

/// The `Location` of a symbol's own definition (its name line).
pub fn writeSymbolLocation(w: *Writer, ctx: Ctx, sym: Symbol) !void {
    try writeLocation(w, ctx, ctx.index().graph.files[sym.file], sym.line, sym.name);
}

// ---------------------------------------------------------------------------
// Node / Edge
// ---------------------------------------------------------------------------

pub fn writeLines(w: *Writer, lines: []const u32) !void {
    try w.writeByte('[');
    for (lines, 0..) |ln, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{d}", .{ln});
    }
    try w.writeByte(']');
}

/// The contract's `Edge` object.
pub fn writeEdge(w: *Writer, from: SymbolId, to: SymbolId, exact: bool, lines: []const u32) !void {
    try w.print("{{\"from\":{d},\"to\":{d},\"exact\":{},\"lines\":", .{ from, to, exact });
    try writeLines(w, lines);
    try w.writeByte('}');
}

/// Unresolved call targets of `sym` — the contract's `Node.ext`.
pub fn writeExternals(w: *Writer, sym: Symbol, strict: bool) !void {
    try w.writeByte('[');
    var wrote: u32 = 0;
    for (sym.refs) |ref| {
        if (ref.kind != .call and ref.kind != .route_call) continue;
        if (ref.target != model.invalid_symbol and (!strict or ref.exact)) continue;
        if (wrote != 0) try w.writeByte(',');
        try writeString(w, ref.name);
        wrote += 1;
    }
    try w.writeByte(']');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "writeCollapsed folds whitespace runs and trims the ends" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeCollapsed(&aw.writer, "  pub fn f(\n    a: u32,\n) void  ");
    try testing.expectEqualStrings("\"pub fn f( a: u32, ) void\"", aw.written());
}

test "writeCollapsed escapes quotes, backslashes and control bytes" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeCollapsed(&aw.writer, "a\"b\\c\x01d");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\u0001d\"", aw.written());
}

test "writeLines and writeEdge render the contract's edge shape" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeEdge(&aw.writer, 1, 2, true, &.{ 4, 9 });
    try testing.expectEqualStrings("{\"from\":1,\"to\":2,\"exact\":true,\"lines\":[4,9]}", aw.written());
    aw.clearRetainingCapacity();
    try writeEdge(&aw.writer, 0, 3, false, &.{});
    try testing.expectEqualStrings("{\"from\":0,\"to\":3,\"exact\":false,\"lines\":[]}", aw.written());
}

test "writeNameRange spans the name and collapses when it is absent" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeNameRange(&aw.writer, "fn alpha() void {}\n", 1, "alpha", .utf8);
    try testing.expectEqualStrings(
        "{\"start\":{\"line\":0,\"character\":3},\"end\":{\"line\":0,\"character\":8}}",
        aw.written(),
    );
    aw.clearRetainingCapacity();
    try writeNameRange(&aw.writer, "fn alpha() void {}\n", 1, "missing", .utf8);
    try testing.expectEqualStrings(
        "{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}",
        aw.written(),
    );
}
