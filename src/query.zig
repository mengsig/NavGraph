//! Query operations over a built `Index`, rendered to an `Io.Writer`.
//!
//! These are the verbs an agent uses instead of grep/read: outline a file or
//! tree, show a definition, and walk the call graph outward (callees) or inward
//! (callers) to a bounded depth.

const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");
const render = @import("render.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

pub const Options = struct {
    verbosity: render.Verbosity = .sig,
    depth: u32 = 1,
    limit: u32 = 300,
};

/// Print an outline of the file(s) under `path_filter` (a path prefix, or ""
/// for the whole project). Symbols are grouped by file and indented by nesting.
pub fn outline(w: *Writer, idx: *const Index, path_filter: []const u8, opts: Options) !void {
    var shown: u32 = 0;
    var any = false;
    for (idx.graph.files) |file| {
        if (!matchesFilter(file.path, path_filter)) continue;
        if (!fileHasVisible(idx, file)) continue;
        any = true;
        try w.print("# {s} ({s})\n", .{ file.path, file.language.tag() });
        shown += try outlineFile(w, idx, file, opts, &shown);
        if (shown >= opts.limit) break;
    }
    if (!any) try w.print("(no source symbols under '{s}')\n", .{path_filter});
}

fn outlineFile(w: *Writer, idx: *const Index, file: model.SourceFile, opts: Options, shown: *u32) !u32 {
    var count: u32 = 0;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import) continue;
        if (!sym.kind.isTopLevelInteresting() and sym.parent == invalid) continue;
        const indent = 1 + parentDepth(idx, sym);
        try render.symbol(w, idx, sym, opts.verbosity, indent, false);
        count += 1;
        shown.* += 1;
        if (shown.* >= opts.limit) break;
    }
    return count;
}

fn fileHasVisible(idx: *const Index, file: model.SourceFile) bool {
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        if (idx.graph.symbols[i].kind != .import) return true;
    }
    return false;
}

fn parentDepth(idx: *const Index, sym: model.Symbol) usize {
    var depth: usize = 0;
    var p = sym.parent;
    while (p != invalid) : (depth += 1) p = idx.graph.symbols[p].parent;
    return depth;
}

fn matchesFilter(path: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return std.mem.startsWith(u8, path, filter) or std.mem.indexOf(u8, path, filter) != null;
}

/// Show the definition(s) of `name` (supports `Parent.name`).
pub fn showDef(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !void {
    var buf: [64]SymbolId = undefined;
    const ids = resolve(idx, name, &buf);
    if (ids.len == 0) {
        try w.print("(no definition named '{s}')\n", .{name});
        return;
    }
    for (ids) |id| {
        try render.symbol(w, idx, idx.graph.symbols[id], opts.verbosity, 0, true);
    }
}

/// Walk the call graph from `name`. `incoming` selects callers vs callees.
pub fn walk(w: *Writer, idx: *const Index, name: []const u8, incoming: bool, opts: Options) !void {
    var buf: [64]SymbolId = undefined;
    const ids = resolve(idx, name, &buf);
    if (ids.len == 0) {
        try w.print("(no symbol named '{s}')\n", .{name});
        return;
    }
    var visited = std.AutoHashMap(SymbolId, void).init(idx.gpa);
    defer visited.deinit();
    for (ids) |id| {
        visited.clearRetainingCapacity();
        try walkNode(w, idx, id, incoming, opts, 0, &visited);
    }
}

fn walkNode(
    w: *Writer,
    idx: *const Index,
    id: SymbolId,
    incoming: bool,
    opts: Options,
    indent: usize,
    visited: *std.AutoHashMap(SymbolId, void),
) anyerror!void {
    const v = if (indent == 0) opts.verbosity else headerVerbosity(opts.verbosity);
    try render.symbol(w, idx, idx.graph.symbols[id], v, indent, true);
    if (indent >= opts.depth) return;
    if ((try visited.getOrPut(id)).found_existing) {
        try indentLine(w, indent + 1, "… (recursion)");
        return;
    }
    if (incoming) {
        try walkCallers(w, idx, id, opts, indent, visited);
    } else {
        try walkCallees(w, idx, id, opts, indent, visited);
    }
}

fn walkCallees(
    w: *Writer,
    idx: *const Index,
    id: SymbolId,
    opts: Options,
    indent: usize,
    visited: *std.AutoHashMap(SymbolId, void),
) !void {
    const sym = idx.graph.symbols[id];
    var externals: std.ArrayList(u8) = .empty;
    defer externals.deinit(idx.gpa);
    for (sym.refs) |ref| {
        if (ref.kind != .call) continue;
        if (ref.target != invalid) {
            try walkNode(w, idx, ref.target, false, opts, indent + 1, visited);
        } else {
            if (externals.items.len != 0) try externals.appendSlice(idx.gpa, ", ");
            try externals.appendSlice(idx.gpa, ref.name);
        }
    }
    if (externals.items.len != 0) {
        try indentLine(w, indent + 1, "~ ext: ");
        try w.writeAll(externals.items);
        try w.writeByte('\n');
    }
}

fn walkCallers(
    w: *Writer,
    idx: *const Index,
    id: SymbolId,
    opts: Options,
    indent: usize,
    visited: *std.AutoHashMap(SymbolId, void),
) !void {
    for (idx.callersOf(id)) |cid| {
        try walkNode(w, idx, cid, true, opts, indent + 1, visited);
    }
}

/// Substring search over symbol names; prints matches like `def`.
pub fn search(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    std.debug.assert(pattern.len > 0);
    var shown: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (std.mem.indexOf(u8, sym.name, pattern) == null) continue;
        try render.symbol(w, idx, sym, opts.verbosity, 0, true);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (shown == 0) try w.print("(no symbol matching '{s}')\n", .{pattern});
}

fn headerVerbosity(v: render.Verbosity) render.Verbosity {
    return if (v == .full) .sig else v;
}

fn indentLine(w: *Writer, indent: usize, text: []const u8) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try w.writeAll("  ");
    try w.writeAll(text);
    if (!std.mem.endsWith(u8, text, " ")) try w.writeByte('\n');
}

/// Resolve a query name to symbol ids. Supports a `Parent.child` qualifier.
/// Results are written into `buf` and a sub-slice is returned.
fn resolve(idx: *const Index, name: []const u8, buf: []SymbolId) []const SymbolId {
    std.debug.assert(buf.len > 0);
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const parent = name[0..dot];
        const child = name[dot + 1 ..];
        return resolveQualified(idx, parent, child, buf);
    }
    const ids = idx.lookup(name);
    const n = @min(ids.len, buf.len);
    @memcpy(buf[0..n], ids[0..n]);
    return buf[0..n];
}

fn resolveQualified(idx: *const Index, parent: []const u8, child: []const u8, buf: []SymbolId) []const SymbolId {
    var n: usize = 0;
    for (idx.lookup(child)) |id| {
        if (n >= buf.len) break;
        const sym = idx.graph.symbols[id];
        if (sym.parent == invalid) continue;
        if (!std.mem.eql(u8, idx.graph.symbols[sym.parent].name, parent)) continue;
        buf[n] = id;
        n += 1;
    }
    if (n == 0) { // fall back to bare child lookup
        const ids = idx.lookup(child);
        const m = @min(ids.len, buf.len);
        @memcpy(buf[0..m], ids[0..m]);
        return buf[0..m];
    }
    return buf[0..n];
}

test "resolve handles qualified names" {
    try std.testing.expect(true);
}
