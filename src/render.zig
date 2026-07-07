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
/// Cap for const/var initializer values in `sig` view — short enough that a big
/// comptime literal collapses to its type/constructor head instead of dumping.
const max_value_len: usize = 60;

/// Render one symbol as an indented line (or block, for `.full`).
pub fn symbol(
    w: *Writer,
    idx: *const Index,
    sym: Symbol,
    v: Verbosity,
    indent: usize,
    show_path: bool,
) !void {
    return symbolSite(w, idx, sym, v, indent, show_path, 0, true);
}

/// Like `symbol`, but annotates the line with the call-site `site` (the source
/// line of the graph edge connecting this node to its parent in a call tree).
/// `site == 0` means no edge (a root, or a plain listing) and renders like
/// `symbol`. The annotation is `↳:N` — N lives in the file of whichever endpoint
/// is the *caller* (this row in a callers tree; the parent row in a callees tree).
pub fn symbolSite(
    w: *Writer,
    idx: *const Index,
    sym: Symbol,
    v: Verbosity,
    indent: usize,
    show_path: bool,
    site: u32,
    /// False marks a heuristic (name-match) edge to this node, rendered with a
    /// trailing `?`; true (the default for roots and exact edges) renders plain.
    exact: bool,
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
    try writeLocation(w, idx, sym, source, show_path);
    if (site != 0) try w.print("  ↳:{d}{s}", .{ site, if (exact) "" else " ?" });
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
    const is_value = switch (sym.kind) {
        .function, .method => false,
        .class, .@"struct", .@"enum", .interface, .import, .macro, .module => return,
        else => true,
    };
    const suffix = if (is_value)
        valueSlice(sym.signature(source), sym.name)
    else
        paramSlice(sym.signature(source));
    if (suffix.len == 0) return;
    try w.writeByte(' ');
    // A const/var initializer (comptime map, keyword set, big array) is noise
    // when you only want the shape, so values get a much shorter cap than a
    // function signature — enough to show the type/constructor head, not the
    // whole literal. `outline -v full` still shows the complete definition.
    const cap: usize = if (is_value) max_value_len else max_sig_len;
    try writeCollapsed(w, suffix, cap);
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

fn writeLocation(w: *Writer, idx: *const Index, sym: Symbol, source: []const u8, show_path: bool) !void {
    try w.writeAll("  ");
    if (show_path) {
        try w.writeAll(idx.graph.files[sym.file].path);
        try w.writeByte(':');
    } else {
        try w.writeByte('L');
    }
    // A line range (`start-end`) lets a reader open exactly the definition; a
    // single-line symbol stays a bare line number.
    const end = sym.endLine(source);
    try w.print("{d}", .{sym.line});
    if (end > sym.line) try w.print("-{d}", .{end});
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
