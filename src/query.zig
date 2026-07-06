//! Query operations over a built `Index`, rendered to an `Io.Writer`.
//!
//! These are the verbs an agent uses instead of grep/read: outline a file or
//! tree, show a definition, and walk the call graph outward (callees) or inward
//! (callers) to a bounded depth.

const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");
const render = @import("render.zig");
const json_out = @import("json_out.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

/// Output encoding: compact text for agents, or JSON for tooling/MCP.
pub const OutputFormat = enum { text, json };

pub const Options = struct {
    verbosity: render.Verbosity = .sig,
    depth: u32 = 1,
    limit: u32 = 300,
    /// Follow only high-confidence (type/self-bound or unambiguous) edges.
    strict: bool = false,
    format: OutputFormat = .text,
};

/// Print an outline of the file(s) under `path_filter` (a path prefix, or ""
/// for the whole project). Symbols are grouped by file and indented by nesting.
pub fn outline(w: *Writer, idx: *const Index, path_filter: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.outline(w, idx, path_filter, opts);
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

pub fn matchesFilter(path: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    return std.mem.startsWith(u8, path, filter) or std.mem.indexOf(u8, path, filter) != null;
}

/// Show the definition(s) of `name` (supports `Parent.name`).
pub fn showDef(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.showDef(w, idx, name, opts);
    var buf: [64]SymbolId = undefined;
    const ids = resolveIds(idx, name, &buf);
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
    if (opts.format == .json) return json_out.walk(w, idx, name, incoming, opts);
    var buf: [64]SymbolId = undefined;
    const ids = resolveIds(idx, name, &buf);
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
        if (ref.kind != .call and ref.kind != .route_call) continue;
        const followed = ref.target != invalid and (!opts.strict or ref.exact);
        if (followed) {
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
        if (opts.strict and !hasExactEdge(idx, cid, id)) continue;
        try walkNode(w, idx, cid, true, opts, indent + 1, visited);
    }
}

/// True when `from` references `to` via a high-confidence (exact) edge.
pub fn hasExactEdge(idx: *const Index, from: SymbolId, to: SymbolId) bool {
    for (idx.graph.symbols[from].refs) |ref| {
        if (ref.target == to and ref.exact) return true;
    }
    return false;
}

/// Substring search over symbol names; prints matches like `def`.
pub fn search(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    std.debug.assert(pattern.len > 0);
    if (opts.format == .json) return json_out.search(w, idx, pattern, opts);
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

/// List HTTP route definitions and, under each, its handler (callee) and the
/// client call sites that hit it (callers) — the API surface across languages.
pub fn listRoutes(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.listRoutes(w, idx, filter, opts);
    var any = false;
    var shown: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (sym.kind != .route) continue;
        if (filter.len != 0 and std.mem.indexOf(u8, sym.name, filter) == null) continue;
        any = true;
        try render.symbol(w, idx, sym, opts.verbosity, 0, true);
        try routeRelations(w, idx, sym);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (!any) try w.print("(no routes under '{s}')\n", .{filter});
}

fn routeRelations(w: *Writer, idx: *const Index, route: model.Symbol) !void {
    for (route.refs) |ref| {
        if (ref.kind == .call and ref.target != invalid) {
            try render.symbol(w, idx, idx.graph.symbols[ref.target], .sig, 1, true);
        }
    }
    for (idx.callersOf(route.id)) |cid| {
        try render.symbol(w, idx, idx.graph.symbols[cid], .sig, 1, true);
    }
}

/// Show `name`'s callees and callers together (each one level deep) — a quick
/// "what's around this symbol" view without choosing a direction.
pub fn neighbors(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.neighbors(w, idx, name, opts);
    var buf: [64]SymbolId = undefined;
    const ids = resolveIds(idx, name, &buf);
    if (ids.len == 0) {
        try w.print("(no symbol named '{s}')\n", .{name});
        return;
    }
    for (ids) |id| {
        try render.symbol(w, idx, idx.graph.symbols[id], opts.verbosity, 0, true);
        try w.writeAll("  ↓ calls\n");
        try renderCallees(w, idx, id, opts, 2);
        try w.writeAll("  ↑ callers\n");
        for (idx.callersOf(id)) |cid| {
            try render.symbol(w, idx, idx.graph.symbols[cid], headerVerbosity(opts.verbosity), 2, true);
        }
    }
}

/// Render the resolved callees of `id` at `indent`, listing unresolved names on
/// a trailing `~ ext:` line (mirrors the `calls` tree's leaf formatting).
fn renderCallees(w: *Writer, idx: *const Index, id: SymbolId, opts: Options, indent: usize) !void {
    const sym = idx.graph.symbols[id];
    var externals: std.ArrayList(u8) = .empty;
    defer externals.deinit(idx.gpa);
    for (sym.refs) |ref| {
        if (ref.kind != .call and ref.kind != .route_call) continue;
        if (ref.target != invalid and (!opts.strict or ref.exact)) {
            try render.symbol(w, idx, idx.graph.symbols[ref.target], headerVerbosity(opts.verbosity), indent, true);
        } else {
            if (externals.items.len != 0) try externals.appendSlice(idx.gpa, ", ");
            try externals.appendSlice(idx.gpa, ref.name);
        }
    }
    if (externals.items.len != 0) {
        try indentLine(w, indent, "~ ext: ");
        try w.writeAll(externals.items);
        try w.writeByte('\n');
    }
}

/// List functions/methods that have no callers — candidate dead code. Exported
/// symbols may legitimately be external API, so they are marked, not hidden.
pub fn unused(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.unused(w, idx, filter, opts);
    var shown: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (!isDeadCandidate(idx, sym, filter)) continue;
        try render.symbol(w, idx, sym, opts.verbosity, 0, true);
        if (sym.exported) try w.writeAll("  (exported — may be public API)\n") else try w.writeByte('\n');
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (shown == 0) try w.print("(no unused functions under '{s}')\n", .{filter});
}

/// A symbol worth reporting as possibly-unused: a callable, in-scope of the
/// filter, with zero callers and not an obvious entry point.
pub fn isDeadCandidate(idx: *const Index, sym: model.Symbol, filter: []const u8) bool {
    if (sym.kind != .function and sym.kind != .method) return false;
    if (idx.callersOf(sym.id).len != 0) return false;
    if (std.mem.eql(u8, sym.name, "main")) return false;
    return matchesFilter(idx.graph.files[sym.file].path, filter);
}

/// List, per in-scope file, the local modules it imports (resolved edges only).
pub fn listImports(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.listImports(w, idx, filter, opts);
    var any = false;
    for (idx.graph.files) |file| {
        const imps = idx.importsOf(file.id);
        if (imps.len == 0 or !matchesFilter(file.path, filter)) continue;
        any = true;
        try w.print("# {s}\n", .{file.path});
        for (imps) |imp| {
            try w.print("  → {s}", .{idx.graph.files[imp.target].path});
            if (imp.binding.len != 0) try w.print("  ({s})", .{imp.binding});
            try w.writeByte('\n');
        }
    }
    if (!any) try w.print("(no local imports under '{s}')\n", .{filter});
}

/// List files that import the file(s) matching `path` — reverse dependencies.
pub fn listImporters(w: *Writer, idx: *const Index, path: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.listImporters(w, idx, path, opts);
    var any = false;
    for (idx.graph.files) |target| {
        if (!matchesFilter(target.path, path)) continue;
        var printed_header = false;
        for (idx.graph.files) |src| {
            if (!fileImports(idx, src.id, target.id)) continue;
            if (!printed_header) {
                try w.print("# {s} ← imported by\n", .{target.path});
                printed_header = true;
                any = true;
            }
            try w.print("  {s}\n", .{src.path});
        }
    }
    if (!any) try w.print("(no importers of '{s}')\n", .{path});
}

fn fileImports(idx: *const Index, src: model.FileId, target: model.FileId) bool {
    for (idx.importsOf(src)) |imp| if (imp.target == target) return true;
    return false;
}

/// Print the shortest call path from `from_name` to `to_name` (BFS over call
/// edges), or a "no path" note. Renders the chain as an indented cascade.
pub fn shortestPath(w: *Writer, idx: *const Index, from_name: []const u8, to_name: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.shortestPath(w, idx, from_name, to_name, opts);
    var fbuf: [64]SymbolId = undefined;
    var tbuf: [64]SymbolId = undefined;
    const chain = try shortestPathIds(idx, from_name, to_name, &fbuf, &tbuf);
    defer idx.gpa.free(chain);
    if (chain.len == 0) {
        try w.print("(no call path from '{s}' to '{s}')\n", .{ from_name, to_name });
        return;
    }
    for (chain, 0..) |id, indent| {
        const v = if (indent == 0) opts.verbosity else headerVerbosity(opts.verbosity);
        try render.symbol(w, idx, idx.graph.symbols[id], v, indent, true);
    }
}

/// The shortest call path from `from_name` to `to_name` as source→…→target
/// symbol ids (gpa-owned; caller frees). Empty when either name is unknown or
/// no path exists. `fbuf`/`tbuf` are scratch for name resolution.
pub fn shortestPathIds(
    idx: *const Index,
    from_name: []const u8,
    to_name: []const u8,
    fbuf: []SymbolId,
    tbuf: []SymbolId,
) ![]SymbolId {
    const from_ids = resolveIds(idx, from_name, fbuf);
    const to_ids = resolveIds(idx, to_name, tbuf);
    if (from_ids.len == 0 or to_ids.len == 0) return idx.gpa.alloc(SymbolId, 0);
    const prev = try bfsPrev(idx, from_ids, to_ids, false);
    defer idx.gpa.free(prev);
    const end = firstReached(prev, to_ids) orelse return idx.gpa.alloc(SymbolId, 0);
    return reconstruct(idx.gpa, prev, end);
}

/// Walk `prev` from `end` back to its source, returning the path source-first.
fn reconstruct(gpa: std.mem.Allocator, prev: []const SymbolId, end: SymbolId) ![]SymbolId {
    var chain: std.ArrayList(SymbolId) = .empty;
    defer chain.deinit(gpa);
    var cur = end;
    while (true) {
        try chain.append(gpa, cur);
        if (prev[cur] == cur) break; // reached a source
        cur = prev[cur];
    }
    std.mem.reverse(SymbolId, chain.items);
    return chain.toOwnedSlice(gpa);
}

/// BFS from all `from_ids` over call edges; returns a `prev` array where
/// `prev[n]` is the predecessor of `n` (self for sources, `invalid` if unseen).
fn bfsPrev(idx: *const Index, from_ids: []const SymbolId, to_ids: []const SymbolId, strict: bool) ![]SymbolId {
    const n = idx.graph.symbols.len;
    var prev = try idx.gpa.alloc(SymbolId, n);
    errdefer idx.gpa.free(prev);
    @memset(prev, invalid);
    var queue = std.array_list.Managed(SymbolId).init(idx.gpa);
    defer queue.deinit();
    for (from_ids) |s| {
        prev[s] = s; // sources mark themselves as seen
        try queue.append(s);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (contains(to_ids, cur) and !contains(from_ids, cur)) break;
        for (idx.graph.symbols[cur].refs) |ref| {
            if (ref.kind != .call and ref.kind != .route_call) continue;
            if (ref.target == invalid or (strict and !ref.exact)) continue;
            if (prev[ref.target] != invalid) continue;
            prev[ref.target] = cur;
            try queue.append(ref.target);
        }
    }
    return prev;
}

fn firstReached(prev: []const SymbolId, to_ids: []const SymbolId) ?SymbolId {
    for (to_ids) |t| if (prev[t] != invalid) return t;
    return null;
}

fn contains(ids: []const SymbolId, id: SymbolId) bool {
    for (ids) |x| if (x == id) return true;
    return false;
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
pub fn resolveIds(idx: *const Index, name: []const u8, buf: []SymbolId) []const SymbolId {
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

test "shortest path and dead-code detection over a call chain" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "chain.zig", .data = 
        \\pub fn alpha() void {
        \\    beta();
        \\}
        \\pub fn beta() void {
        \\    gamma();
        \\}
        \\pub fn gamma() void {}
        \\pub fn orphan() void {}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // alpha -> beta -> gamma is the shortest path.
    var fbuf: [8]SymbolId = undefined;
    var tbuf: [8]SymbolId = undefined;
    const chain = try shortestPathIds(&idx, "alpha", "gamma", &fbuf, &tbuf);
    defer testing.allocator.free(chain);
    try testing.expectEqual(@as(usize, 3), chain.len);
    try testing.expectEqual(idx.lookup("alpha")[0], chain[0]);
    try testing.expectEqual(idx.lookup("gamma")[0], chain[2]);

    // No reverse path gamma -> alpha.
    const none = try shortestPathIds(&idx, "gamma", "alpha", &fbuf, &tbuf);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // `orphan` is called by nobody → dead candidate; `gamma` is called → not.
    const orphan = idx.graph.symbols[idx.lookup("orphan")[0]];
    const gamma = idx.graph.symbols[idx.lookup("gamma")[0]];
    try testing.expect(isDeadCandidate(&idx, orphan, ""));
    try testing.expect(!isDeadCandidate(&idx, gamma, ""));
}
