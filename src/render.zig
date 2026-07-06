//! Compressed, token-frugal rendering of symbols to an `Io.Writer`.
//!
//! The output is designed to be read by an agent: dense, one line per symbol at
//! low verbosity, with signatures collapsed to a single line and locations as
//! `path:line`. Higher verbosity adds docs, then full source.

const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const Symbol = model.Symbol;

pub const Verbosity = enum {
    /// kind + name only.
    names,
    /// kind + collapsed signature (default).
    sig,
    /// signature + first doc line.
    doc,
    /// full source of the definition.
    full,

    pub fn parse(s: []const u8) ?Verbosity {
        const map = .{
            .{ "names", Verbosity.names }, .{ "name", Verbosity.names },
            .{ "sig", Verbosity.sig },     .{ "signature", Verbosity.sig },
            .{ "doc", Verbosity.doc },     .{ "docs", Verbosity.doc },
            .{ "full", Verbosity.full },   .{ "body", Verbosity.full },
        };
        inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
        return null;
    }
};

const max_sig_len: usize = 160;

/// Render one symbol as an indented line (or block, for `.full`).
pub fn symbol(
    w: *Writer,
    idx: *const Index,
    sym: Symbol,
    v: Verbosity,
    indent: usize,
    show_path: bool,
) !void {
    try writeIndent(w, indent);
    try w.writeAll(sym.kind.tag());
    try w.writeByte(' ');
    try writeQualifiedName(w, idx, sym);

    const source = idx.graph.files[sym.file].text;
    switch (v) {
        .names => {},
        .sig, .doc => try writeSigSuffix(w, sym, source),
        .full => {},
    }
    try writeLocation(w, idx, sym, show_path);
    try w.writeByte('\n');

    if (v == .doc) try writeDocLine(w, sym, indent);
    if (v == .full) try writeFullBody(w, sym, source, indent);
}

fn writeIndent(w: *Writer, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try w.writeAll("  ");
}

fn writeQualifiedName(w: *Writer, idx: *const Index, sym: Symbol) !void {
    if (sym.parent != model.invalid_symbol) {
        const parent = idx.graph.symbols[sym.parent];
        try w.writeAll(parent.name);
        try w.writeByte('.');
    }
    try w.writeAll(sym.name);
}

/// Append the collapsed signature after the name, minus the redundant name/kind.
fn writeSigSuffix(w: *Writer, sym: Symbol, source: []const u8) !void {
    const suffix = switch (sym.kind) {
        .function, .method => paramSlice(sym.signature(source)),
        .class, .@"struct", .@"enum", .interface, .import, .macro, .module => "",
        else => valueSlice(sym.signature(source), sym.name),
    };
    if (suffix.len == 0) return;
    try w.writeByte(' ');
    try writeCollapsed(w, suffix, max_sig_len);
}

/// The parameter/return portion of a function signature (from the first `(`).
fn paramSlice(sig: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, sig, '(')) |p| return sig[p..];
    return "";
}

/// For a const/var/type, the value/type portion after the name.
fn valueSlice(sig: []const u8, name: []const u8) []const u8 {
    const n = std.mem.indexOf(u8, sig, name) orelse return "";
    var rest = std.mem.trim(u8, sig[n + name.len ..], " \t\r\n:=;");
    if (rest.len != 0 and rest[rest.len - 1] == ';') rest = rest[0 .. rest.len - 1];
    return rest;
}

fn writeLocation(w: *Writer, idx: *const Index, sym: Symbol, show_path: bool) !void {
    try w.writeAll("  ");
    if (show_path) {
        try w.writeAll(idx.graph.files[sym.file].path);
        try w.writeByte(':');
    } else {
        try w.writeByte('L');
    }
    try w.print("{d}", .{sym.line});
}

/// Collapse runs of whitespace to single spaces, capping length with an ellipsis.
pub fn writeCollapsed(w: *Writer, text: []const u8, cap: usize) !void {
    var written: usize = 0;
    var prev_space = false;
    for (text) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            if (prev_space or written == 0) continue;
            prev_space = true;
            continue;
        }
        if (prev_space) {
            try w.writeByte(' ');
            written += 1;
            prev_space = false;
        }
        if (written >= cap) {
            try w.writeAll("…");
            return;
        }
        try w.writeByte(c);
        written += 1;
    }
}

fn writeDocLine(w: *Writer, sym: Symbol, indent: usize) !void {
    const stripped = stripDoc(sym.doc);
    const line = firstLine(stripped);
    if (line.len == 0) return;
    try writeIndent(w, indent + 1);
    try w.writeAll("» ");
    try writeCollapsed(w, line, 200);
    try w.writeByte('\n');
}

fn writeFullBody(w: *Writer, sym: Symbol, source: []const u8, indent: usize) !void {
    _ = indent;
    try w.writeAll(sym.body(source));
    try w.writeByte('\n');
}

/// Strip leading comment/docstring markers from a raw doc slice.
pub fn stripDoc(doc: []const u8) []const u8 {
    var s = std.mem.trim(u8, doc, " \t\r\n");
    if (std.mem.startsWith(u8, s, "\"\"\"")) s = std.mem.trim(u8, s, "\"");
    if (std.mem.startsWith(u8, s, "'''")) s = std.mem.trim(u8, s, "'");
    if (std.mem.startsWith(u8, s, "/**")) s = std.mem.trim(u8, s[3..], " \t\r\n*/");
    return s;
}

fn firstLine(s: []const u8) []const u8 {
    var line = s;
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| line = s[0..nl];
    // Drop a leading `///`, `//`, `#`, `*` marker.
    line = std.mem.trimStart(u8, line, "/#* \t");
    return std.mem.trim(u8, line, " \t\r");
}
