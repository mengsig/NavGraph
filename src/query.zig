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

/// Default result cap (also a sentinel: `limit == default_limit` means "the user
/// did not pass -l", which `hot` uses to pick its own shorter default).
pub const default_limit: u32 = 300;
/// `hot`'s brief default when no explicit `-l` was given.
pub const hot_default: u32 = 25;

/// The effective cap for `hot`: its own short default unless `-l` was given.
pub fn hotLimit(opts: Options) u32 {
    return if (opts.limit == default_limit) hot_default else opts.limit;
}

pub const Options = struct {
    verbosity: render.Verbosity = .sig,
    depth: u32 = 1,
    limit: u32 = default_limit,
    /// Follow only high-confidence (type/self-bound or unambiguous) edges.
    strict: bool = false,
    format: OutputFormat = .text,
    /// `search`: match reference/use sites (usages), not just definition names.
    refs: bool = false,
    /// Restrict `outline`/`search` to symbols whose kind tag is in this
    /// comma-separated set (e.g. "fn,method"). Empty means all kinds.
    kinds: []const u8 = "",
};

/// Whether `kind` passes the (comma-separated) `--kind` filter. Empty filter
/// matches everything. Matches against the short tag (`fn`, `struct`, `route`…)
/// and also accepts `function`/`func` as aliases for `fn`.
pub fn kindAllowed(kind: model.SymbolKind, filter: []const u8) bool {
    if (filter.len == 0) return true;
    const tag = kind.tag();
    var it = std.mem.tokenizeScalar(u8, filter, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " ");
        if (std.mem.eql(u8, t, tag)) return true;
        if (kind == .function and (std.mem.eql(u8, t, "function") or std.mem.eql(u8, t, "func"))) return true;
        if (kind == .constant and std.mem.eql(u8, t, "constant")) return true;
        if (kind == .variable and std.mem.eql(u8, t, "variable")) return true;
    }
    return false;
}

/// The line where symbol `from` references symbol `to` (its earliest such
/// reference), or 0 if none. Used to annotate a call-graph edge with its real
/// call-site line rather than the caller's own definition line.
pub fn callSiteLine(idx: *const Index, from: SymbolId, to: SymbolId) u32 {
    var best: u32 = 0;
    for (idx.graph.symbols[from].refs) |ref| {
        if (ref.target != to) continue;
        if (best == 0 or ref.line < best) best = ref.line;
    }
    return best;
}

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
    try truncationNote(w, opts, shown);
}

/// Warn when output was capped by `-l`, so a truncated result is never mistaken
/// for the complete set. Printed to the same stream as the results.
fn truncationNote(w: *Writer, opts: Options, shown: u32) !void {
    if (shown >= opts.limit) {
        try w.print("… (stopped at -l {d}; more results may exist — raise -l to see them)\n", .{opts.limit});
    }
}

fn outlineFile(w: *Writer, idx: *const Index, file: model.SourceFile, opts: Options, shown: *u32) !u32 {
    var count: u32 = 0;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import) continue;
        if (!sym.kind.isTopLevelInteresting() and sym.parent == invalid) continue;
        if (!kindAllowed(sym.kind, opts.kinds)) continue;
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
        try walkNode(w, idx, id, incoming, opts, 0, 0, true, &visited);
    }
}

fn walkNode(
    w: *Writer,
    idx: *const Index,
    id: SymbolId,
    incoming: bool,
    opts: Options,
    indent: usize,
    site: u32,
    exact: bool,
    visited: *std.AutoHashMap(SymbolId, void),
) anyerror!void {
    const v = if (indent == 0) opts.verbosity else headerVerbosity(opts.verbosity);
    try render.symbolSite(w, idx, idx.graph.symbols[id], v, indent, true, site, exact);
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
        // Follow every *resolved* edge (call, use, type-use), so the callee tree
        // is symmetric with the callers index (which counts all resolved refs).
        // Only unresolved *calls* are surfaced as externals; unresolved reads of
        // stdlib/locals would be noise.
        if (ref.target != invalid and (!opts.strict or ref.exact)) {
            // The edge (this symbol → callee) lives at ref.line in this file.
            try walkNode(w, idx, ref.target, false, opts, indent + 1, ref.line, ref.exact, visited);
        } else if (ref.kind == .call or ref.kind == .route_call) {
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
        // The edge (caller → this symbol) lives at its call site in the caller.
        try walkNode(w, idx, cid, true, opts, indent + 1, callSiteLine(idx, cid, id), hasExactEdge(idx, cid, id), visited);
    }
}

/// True when `from` references `to` via a high-confidence (exact) edge.
pub fn hasExactEdge(idx: *const Index, from: SymbolId, to: SymbolId) bool {
    for (idx.graph.symbols[from].refs) |ref| {
        if (ref.target == to and ref.exact) return true;
    }
    return false;
}

/// Substring search over symbol names; prints matches like `def`. With
/// `--refs`, searches *use sites* (references) instead — a resolved-graph grep
/// that answers "where is this used", which name-only search cannot.
pub fn search(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    std.debug.assert(pattern.len > 0);
    if (opts.refs) return searchRefs(w, idx, pattern, opts);
    if (opts.format == .json) return json_out.search(w, idx, pattern, opts);
    var shown: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (!kindAllowed(sym.kind, opts.kinds)) continue;
        if (std.mem.indexOf(u8, sym.name, pattern) == null) continue;
        try render.symbol(w, idx, sym, opts.verbosity, 0, true);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (shown == 0) try w.print("(no symbol matching '{s}')\n", .{pattern});
    try truncationNote(w, opts, shown);
}

/// List every reference (use site) whose name contains `pattern`, grouped by the
/// enclosing symbol, with the call-site line and whether it resolved. This is the
/// "find usages" verb — structured, comment/string-free, resolution-aware.
fn searchRefs(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.searchRefs(w, idx, pattern, opts);
    var shown: u32 = 0;
    for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            if (std.mem.indexOf(u8, ref.name, pattern) == null) continue;
            try w.print("{s}:{d}  {s}", .{ idx.graph.files[sym.file].path, ref.line, ref.name });
            if (ref.qualifier.len != 0) try w.print(" (on {s})", .{ref.qualifier});
            try w.print("  in {s}", .{sym.name});
            if (ref.target != invalid) {
                try w.print("  → {s}", .{idx.graph.files[idx.graph.symbols[ref.target].file].path});
            } else if (ref.kind == .call or ref.kind == .route_call) {
                try w.writeAll("  → ~ext");
            }
            try w.writeByte('\n');
            shown += 1;
            if (shown >= opts.limit) break;
        }
        if (shown >= opts.limit) break;
    }
    if (shown == 0) try w.print("(no reference matching '{s}')\n", .{pattern});
    try truncationNote(w, opts, shown);
}

/// The number of distinct resolved callees (outgoing edges) of `sym`.
fn fanOut(sym: model.Symbol) u32 {
    var out: u32 = 0;
    for (sym.refs) |ref| {
        if (ref.target != invalid) out += 1;
    }
    return out;
}

/// Rank functions/methods by connectivity (callers = fan-in, callees = fan-out)
/// and list the busiest — the load-bearing symbols an agent should read first to
/// understand a repo, and where changes ripple widest. Ranked by fan-in, then
/// fan-out. Honors an optional path `filter` and `-l` for the count.
pub fn hot(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.hot(w, idx, filter, opts);
    const ranked = try collectHot(idx, filter);
    defer idx.gpa.free(ranked);
    // `hot` is an orientation view — a short ranked list is the point, so it
    // caps at a small default (raise `-l` for more) via the limit sentinel.
    const cap = @min(ranked.len, hotLimit(opts));
    if (cap == 0) {
        try w.print("(no functions under '{s}')\n", .{filter});
        return;
    }
    for (ranked[0..cap]) |e| {
        const sym = idx.graph.symbols[e.id];
        try render.symbol(w, idx, sym, headerVerbosity(opts.verbosity), 0, true);
        // Trim the trailing newline render wrote, then append the fan counts.
        // (render always ends the line; we add the score as a suffix line note.)
        try w.print("    ←{d} callers  →{d} callees\n", .{ e.fan_in, e.fan_out });
    }
    if (ranked.len > cap) {
        try w.print("… ({d} more; raise -l to see them)\n", .{ranked.len - cap});
    }
}

pub const HotEntry = struct { id: SymbolId, fan_in: u32, fan_out: u32 };

/// Collect callable symbols under `filter`, sorted by fan-in then fan-out
/// (descending). Caller frees the returned slice.
pub fn collectHot(idx: *const Index, filter: []const u8) ![]HotEntry {
    var list: std.ArrayList(HotEntry) = .empty;
    errdefer list.deinit(idx.gpa);
    for (idx.graph.symbols) |sym| {
        if (sym.kind != .function and sym.kind != .method) continue;
        if (!matchesFilter(idx.graph.files[sym.file].path, filter)) continue;
        const fan_in: u32 = @intCast(idx.callersOf(sym.id).len);
        const fan_out = fanOut(sym);
        if (fan_in == 0 and fan_out == 0) continue; // isolated: not informative
        try list.append(idx.gpa, .{ .id = sym.id, .fan_in = fan_in, .fan_out = fan_out });
    }
    const items = try list.toOwnedSlice(idx.gpa);
    std.mem.sort(HotEntry, items, {}, hotLessThan);
    return items;
}

/// Descending order: higher fan-in first, then higher fan-out, then stable by id.
fn hotLessThan(_: void, a: HotEntry, b: HotEntry) bool {
    if (a.fan_in != b.fan_in) return a.fan_in > b.fan_in;
    if (a.fan_out != b.fan_out) return a.fan_out > b.fan_out;
    return a.id < b.id;
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
    try truncationNote(w, opts, shown);
}

fn routeRelations(w: *Writer, idx: *const Index, route: model.Symbol) !void {
    for (route.refs) |ref| {
        if (ref.kind == .call and ref.target != invalid) {
            try render.symbol(w, idx, idx.graph.symbols[ref.target], .sig, 1, true);
        }
    }
    for (idx.callersOf(route.id)) |cid| {
        // A route↔client link is a path match (its own resolver), not a name
        // guess, so it is always rendered as confident.
        try render.symbolSite(w, idx, idx.graph.symbols[cid], .sig, 1, true, callSiteLine(idx, cid, route.id), true);
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
            try render.symbolSite(w, idx, idx.graph.symbols[cid], headerVerbosity(opts.verbosity), 2, true, callSiteLine(idx, cid, id), hasExactEdge(idx, cid, id));
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
        if (ref.target != invalid and (!opts.strict or ref.exact)) {
            try render.symbolSite(w, idx, idx.graph.symbols[ref.target], headerVerbosity(opts.verbosity), indent, true, ref.line, ref.exact);
        } else if (ref.kind == .call or ref.kind == .route_call) {
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
    try truncationNote(w, opts, shown);
}

/// A symbol worth reporting as possibly-unused: a callable, in-scope of the
/// filter, with zero callers and not an obvious entry point.
pub fn isDeadCandidate(idx: *const Index, sym: model.Symbol, filter: []const u8) bool {
    if (sym.kind != .function and sym.kind != .method) return false;
    if (idx.callersOf(sym.id).len != 0) return false;
    if (std.mem.eql(u8, sym.name, "main")) return false;
    // Framework/entry-point callables are invoked implicitly, never by name, so
    // they always look "dead": dunder methods (`__init__`, `__call__`), pytest
    // test functions, and everything in test/conftest files (tests + fixtures).
    if (isDunder(sym.name)) return false;
    if (std.mem.startsWith(u8, sym.name, "test_")) return false;
    const path = idx.graph.files[sym.file].path;
    if (isTestPath(path)) return false;
    return matchesFilter(path, filter);
}

/// A `__dunder__` name (implicitly invoked by the language/runtime).
fn isDunder(name: []const u8) bool {
    return name.len >= 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
}

/// Whether `path` is a test/fixture module (pytest, jest): its functions are
/// invoked by the framework, not referenced by name.
fn isTestPath(path: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |s| path[s + 1 ..] else path;
    if (std.mem.eql(u8, base, "conftest.py")) return true;
    if (std.mem.startsWith(u8, base, "test_")) return true;
    inline for (.{ "_test.py", ".test.ts", ".test.tsx", ".test.js", ".spec.ts", ".spec.tsx", ".spec.js" }) |suf| {
        if (std.mem.endsWith(u8, base, suf)) return true;
    }
    return false;
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
            // Any resolved dependency edge is a valid path hop (symmetric with the
            // callers index), not just `.call`/`.route_call`.
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

/// Resolve a query name to symbol ids. Supports a `Parent.child` qualifier and a
/// trailing `@path` selector (`build@build.zig`, `parse@parser`) that keeps only
/// matches whose file path contains the given substring — the way to
/// disambiguate same-named symbols across files. Results are written into `buf`.
pub fn resolveIds(idx: *const Index, name: []const u8, buf: []SymbolId) []const SymbolId {
    std.debug.assert(buf.len > 0);
    var nm = name;
    var path_sel: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, name, '@')) |at| {
        nm = name[0..at];
        path_sel = name[at + 1 ..];
    }
    const ids = resolveBare(idx, nm, buf);
    if (path_sel.len == 0) return ids;
    // Compact in place to the ids whose file path contains the selector.
    var n: usize = 0;
    for (ids) |id| {
        if (std.mem.indexOf(u8, idx.graph.files[idx.graph.symbols[id].file].path, path_sel) != null) {
            buf[n] = id;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Resolve `name` (optionally `Parent.child`) without a path selector.
fn resolveBare(idx: *const Index, name: []const u8, buf: []SymbolId) []const SymbolId {
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

test "calls shows resolved non-call use edges, symmetric with callers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub const LIMIT: u32 = 10;
        \\pub fn helper() u32 {
        \\    return 1;
        \\}
        \\pub fn run() u32 {
        \\    return helper() + LIMIT;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // `run` calls `helper` and reads `LIMIT`; `calls run` must show BOTH.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try walk(&aw.writer, &idx, "run", false, .{ .depth = 1 });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "helper") != null);
    try testing.expect(std.mem.indexOf(u8, out, "LIMIT") != null);

    // Symmetry: `LIMIT`'s callers include `run`.
    const limit_id = idx.lookup("LIMIT")[0];
    try testing.expectEqual(idx.lookup("run")[0], idx.callersOf(limit_id)[0]);
}

test "kindAllowed matches tags, aliases, and empty-is-all" {
    try std.testing.expect(kindAllowed(.function, ""));
    try std.testing.expect(kindAllowed(.function, "fn"));
    try std.testing.expect(kindAllowed(.function, "function"));
    try std.testing.expect(kindAllowed(.function, "struct,fn,enum"));
    try std.testing.expect(kindAllowed(.@"struct", "struct"));
    try std.testing.expect(!kindAllowed(.function, "struct"));
    try std.testing.expect(!kindAllowed(.method, "fn"));
    try std.testing.expect(kindAllowed(.method, "method"));
    // Whitespace around a comma token is tolerated.
    try std.testing.expect(kindAllowed(.@"enum", "fn, enum"));
}

test "call-site line annotation, usages search, and @path disambiguation" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub fn helper() u32 {
        \\    return 1;
        \\}
        \\pub fn run() u32 {
        \\    const a = helper();
        \\    return a;
        \\}
    });
    // A second file with a same-named `run` to exercise the `@path` selector.
    try tmp.dir.writeFile(io, .{ .sub_path = "other.zig", .data =
        \\pub fn run() void {}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // `callers helper` must annotate the caller with the call-site line (5), not
    // just the caller's own definition line (4).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        try walk(&aw.writer, &idx, "helper", true, .{ .depth = 1 });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "↳:5") != null);
    }

    // `search helper --refs` lists the use site at line 5 inside `run`.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        try search(&aw.writer, &idx, "helper", .{ .refs = true });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "m.zig:5") != null);
        try testing.expect(std.mem.indexOf(u8, out, "in run") != null);
    }

    // `run@other` resolves to exactly the `run` in other.zig.
    {
        var rbuf: [8]SymbolId = undefined;
        const ids = resolveIds(&idx, "run@other", &rbuf);
        try testing.expectEqual(@as(usize, 1), ids.len);
        try testing.expectEqualStrings("other.zig", idx.graph.files[idx.graph.symbols[ids[0]].file].path);
        // Bare `run` finds both.
        var abuf: [8]SymbolId = undefined;
        const all = resolveIds(&idx, "run", &abuf);
        try testing.expectEqual(@as(usize, 2), all.len);
    }
}

test "heuristic (ambiguous name-match) edges are marked with `?`; strict drops them" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Two same-named `target`s in different files make a bare call ambiguous, so
    // resolution falls back to a heuristic guess (exact = false).
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn target() u32 {
        \\    return 1;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub fn target() u32 {
        \\    return 2;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "caller.zig", .data =
        \\pub fn run() u32 {
        \\    return target();
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // Default `calls run` marks the ambiguous callee edge with `?`.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        try walk(&aw.writer, &idx, "run", false, .{ .depth = 1 });
        try testing.expect(std.mem.indexOf(u8, aw.written(), " ?") != null);
    }
    // `--strict` follows only confident edges, so the guess is dropped entirely
    // (no callee line, hence no `?`).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        try walk(&aw.writer, &idx, "run", false, .{ .depth = 1, .strict = true });
        try testing.expect(std.mem.indexOf(u8, aw.written(), " ?") == null);
    }
}

test "end line is correct despite a leading comment or template prefix" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A C function preceded by a doc comment, and a C++ template function whose
    // `template<...>` prefix sits on the line above the name — both used to make
    // endLine overshoot (it was measured as an offset from the name line).
    try tmp.dir.writeFile(io, .{ .sub_path = "a.hpp", .data =
        \\/* leading doc comment on its own line */
        \\int plain(int x) {
        \\    return x + 1;
        \\}
        \\
        \\template <typename T>
        \\T max_of(T a, T b) {
        \\    return a > b ? a : b;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // plain: name on line 2, closing brace on line 4.
    const plain = idx.graph.symbols[idx.lookup("plain")[0]];
    try testing.expectEqual(@as(u32, 2), plain.line);
    try testing.expectEqual(@as(u32, 4), plain.endLine(idx.graph.files[plain.file].text));
    // max_of: name on line 7 (after the template line), closing brace on line 9.
    const max_of = idx.graph.symbols[idx.lookup("max_of")[0]];
    try testing.expectEqual(@as(u32, 7), max_of.line);
    try testing.expectEqual(@as(u32, 9), max_of.endLine(idx.graph.files[max_of.file].text));
}

test "hot ranks the most-called function first" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "h.zig", .data =
        \\pub fn shared() void {}
        \\pub fn a() void { shared(); }
        \\pub fn b() void { shared(); }
        \\pub fn c() void { shared(); a(); }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    const ranked = try collectHot(&idx, "");
    defer idx.gpa.free(ranked);
    try testing.expect(ranked.len >= 2);
    // `shared` has 3 callers (a, b, c) — the most, so it ranks first.
    try testing.expectEqualStrings("shared", idx.graph.symbols[ranked[0].id].name);
    try testing.expectEqual(@as(u32, 3), ranked[0].fan_in);

    // Text output leads with `shared` and shows its fan counts.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try hot(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "shared") != null);
    try testing.expect(std.mem.indexOf(u8, out, "←3 callers") != null);
}

test "line range renders end line for a multi-line definition" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "r.zig", .data =
        \\pub fn multi() void {
        \\    var x: u32 = 0;
        \\    x += 1;
        \\}
        \\pub const single = 1;
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try outline(&aw.writer, &idx, "", .{});
    const out = aw.written();
    // `multi` spans lines 1–4 (outline uses `L<start>-<end>` for nested rows);
    // `single` is a one-liner rendered without a range suffix.
    try testing.expect(std.mem.indexOf(u8, out, "L1-4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "multi") != null);
    // The one-liner ends at its own line with no range suffix.
    try testing.expect(std.mem.indexOf(u8, out, "single") != null);
    try testing.expect(std.mem.indexOf(u8, out, "L5") != null);
    try testing.expect(std.mem.indexOf(u8, out, "L5-") == null);
}

test "dead-code filter skips dunders, tests and fixtures" {
    try std.testing.expect(isDunder("__init__"));
    try std.testing.expect(isDunder("__call__"));
    try std.testing.expect(!isDunder("__"));
    try std.testing.expect(!isDunder("run"));
    try std.testing.expect(!isDunder("_private"));

    try std.testing.expect(isTestPath("tests/test_ship.py"));
    try std.testing.expect(isTestPath("a/b/conftest.py"));
    try std.testing.expect(isTestPath("src/ship_test.py"));
    try std.testing.expect(isTestPath("web/App.test.tsx"));
    try std.testing.expect(!isTestPath("src/ship.py"));
    try std.testing.expect(!isTestPath("src/latest.py"));
}
