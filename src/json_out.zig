//! JSON rendering of query results for stable, programmatic consumption
//! (tooling, MCP servers, editors). Human/agent-facing output stays in
//! `render.zig`; this module mirrors the same verbs with a machine schema.
//!
//! Every list-like verb emits a JSON array; `calls`/`callers` emit an array of
//! call-tree roots. Strings are escaped; there is no partial/looking output —
//! either a complete document is written or an error propagates.

const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");
const render = @import("render.zig");
const query = @import("query.zig");
const lexer = @import("lexer.zig");
const language = @import("language.zig");
const gitdiff = @import("gitdiff.zig");
const impls_mod = @import("impls.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const Symbol = model.Symbol;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;
const Options = query.Options;

const max_sig_len: usize = 160;

/// Outline: array of files, each with its visible symbols. Returns whether any
/// symbol was written.
pub fn outline(w: *Writer, idx: *const Index, path_filter: []const u8, opts: Options) !bool {
    var shown: u32 = 0;
    var first_file = true;
    try w.writeByte('[');
    for (idx.graph.files) |file| {
        if (!query.matchesFilter(file.path, path_filter)) continue;
        if (opts.no_recurse and !query.inDirNonRecursive(file.path, path_filter)) continue;
        if (shown >= opts.limit) break;
        const wrote = try outlineFile(w, idx, file, opts, &shown, !first_file);
        if (wrote) first_file = false;
    }
    try w.writeByte(']');
    try w.writeByte('\n');
    return shown > 0;
}

fn outlineFile(w: *Writer, idx: *const Index, file: model.SourceFile, opts: Options, shown: *u32, sep: bool) !bool {
    std.debug.assert(file.sym_start <= file.sym_end);
    var wrote_any = false;
    var i = file.sym_start;
    while (i < file.sym_end and shown.* < opts.limit) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import) continue;
        if (!sym.kind.isTopLevelInteresting() and sym.parent == invalid) continue;
        if (!query.inTestScope(opts.tests, query.isTestSymbol(idx, sym))) continue;
        if (!query.kindAllowed(sym.kind, opts.kinds)) continue;
        if (!query.visAllowed(sym, opts.visibility)) continue;
        if (!wrote_any) {
            if (sep) try w.writeByte(',');
            try w.print("{{\"path\":", .{});
            try writeString(w, file.path);
            try w.print(",\"lang\":\"{s}\",\"symbols\":[", .{file.language.tag()});
        } else {
            try w.writeByte(',');
        }
        try symbolObject(w, idx, sym, opts.verbosity);
        wrote_any = true;
        shown.* += 1;
    }
    if (wrote_any) try w.writeAll("]}");
    return wrote_any;
}

/// Definition(s) of `name`: a JSON array of symbol objects. Returns whether the
/// name resolved to at least one definition.
pub fn showDef(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !bool {
    var buf: [64]SymbolId = undefined;
    const ids = query.resolveIds(idx, name, &buf);
    var visible: [64]SymbolId = undefined;
    var count: usize = 0;
    for (ids) |id| {
        if (!query.visAllowed(idx.graph.symbols[id], opts.visibility)) continue;
        visible[count] = id;
        count += 1;
    }
    try symbolArray(w, idx, visible[0..count], opts.verbosity);
    return count > 0;
}

/// Substring search: a JSON array of matching symbol objects. Returns whether
/// any symbol matched.
pub fn search(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(pattern.len > 0);
    var shown: u32 = 0;
    try w.writeByte('[');
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (!query.kindAllowed(sym.kind, opts.kinds)) continue;
        if (!query.visAllowed(sym, opts.visibility)) continue;
        if (!query.inTestScope(opts.tests, query.isTestSymbol(idx, sym))) continue;
        if (opts.exact) {
            if (!std.mem.eql(u8, sym.name, pattern)) continue;
        } else if (!query.matchesName(pattern, sym.name)) continue;
        if (shown != 0) try w.writeByte(',');
        try symbolObject(w, idx, sym, opts.verbosity);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    try w.writeAll("]\n");
    return shown > 0;
}

/// `search --refs --json`: array of `{name, file, line, in, qualifier?, target?}`
/// reference objects (use sites), mirroring the text usages listing. Returns
/// whether any reference matched.
pub fn searchRefs(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(pattern.len > 0);
    var pat = query.RefPattern.parse(pattern);
    pat.exact = opts.exact;
    var shown: u32 = 0;
    try w.writeByte('[');
    outer: for (idx.graph.symbols) |sym| {
        // Test scope applies to the referencing symbol (mirrors the text path).
        if (!query.inTestScope(opts.tests, query.isTestSymbol(idx, sym))) continue;
        for (sym.refs) |ref| {
            if (!pat.matches(ref)) continue;
            // One object per distinct use-site line (mirrors the text renderer).
            if (ref.lines.len > 1) {
                for (ref.lines) |ln| {
                    if (shown != 0) try w.writeByte(',');
                    try refObject(w, idx, sym, ref, ln);
                    shown += 1;
                    if (shown >= opts.limit) break :outer;
                }
            } else {
                if (shown != 0) try w.writeByte(',');
                try refObject(w, idx, sym, ref, ref.line);
                shown += 1;
                if (shown >= opts.limit) break :outer;
            }
        }
    }
    try w.writeAll("]\n");
    return shown > 0;
}

fn refObject(w: *Writer, idx: *const Index, sym: Symbol, ref: model.Reference, line: u32) !void {
    try w.writeAll("{\"name\":");
    try writeString(w, ref.name);
    try w.writeAll(",\"file\":");
    try writeString(w, idx.graph.files[sym.file].path);
    try w.print(",\"line\":{d},\"in\":", .{line});
    try writeString(w, sym.name);
    if (ref.qualifier.len != 0) {
        try w.writeAll(",\"qualifier\":");
        try writeString(w, ref.qualifier);
    }
    if (ref.target != invalid) {
        try w.writeAll(",\"target\":");
        try writeString(w, idx.graph.files[idx.graph.symbols[ref.target].file].path);
    }
    try w.writeByte('}');
}

/// `strings --json`: array of `{file, line, text}` string-literal matches.
/// Returns whether any literal matched.
pub fn strings(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(pattern.len > 0);
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(idx.gpa);
    const is_glob = query.isGlobPattern(pattern);
    const pat = try query.wrapStringPattern(idx.gpa, pattern);
    defer if (is_glob) idx.gpa.free(pat);
    var shown: u32 = 0;
    try w.writeByte('[');
    outer: for (idx.graph.files) |file| {
        toks.clearRetainingCapacity();
        lexer.tokenize(idx.gpa, file.text, language.configFor(file.language), &toks) catch continue;
        for (toks.items) |t| {
            if (t.kind != .string) continue;
            const s = t.text(file.text);
            if (!query.matchesString(pat, is_glob, s)) continue;
            if (shown != 0) try w.writeByte(',');
            try w.writeAll("{\"file\":");
            try writeString(w, file.path);
            try w.print(",\"line\":{d},\"text\":", .{t.line});
            try writeCollapsedString(w, s, 200);
            try w.writeByte('}');
            shown += 1;
            if (shown >= opts.limit) break :outer;
        }
    }
    try w.writeAll("]\n");
    return shown > 0;
}

/// Call-graph walk: a JSON array of tree roots (callees or callers). Returns
/// whether `name` resolved to at least one root.
pub fn walk(w: *Writer, idx: *const Index, name: []const u8, incoming: bool, opts: Options) !bool {
    var buf: [64]SymbolId = undefined;
    const ids = query.resolveIds(idx, name, &buf);
    var impl_graph: ?impls_mod.Graph = if (opts.impls) try impls_mod.build(idx.gpa, idx) else null;
    defer if (impl_graph) |*graph| graph.deinit();
    var visited = std.AutoHashMap(SymbolId, void).init(idx.gpa);
    defer visited.deinit();
    try w.writeByte('[');
    for (ids, 0..) |id, k| {
        if (k != 0) try w.writeByte(',');
        visited.clearRetainingCapacity();
        try walkNode(w, idx, if (impl_graph) |*g| g else null, id, incoming, opts, 0, 0, 1, &.{}, true, false, &visited);
    }
    try w.writeAll("]\n");
    return ids.len > 0;
}

fn walkNode(
    w: *Writer,
    idx: *const Index,
    impl_graph: ?*const impls_mod.Graph,
    id: SymbolId,
    incoming: bool,
    opts: Options,
    depth: u32,
    site: u32,
    sites: u32,
    lines: []const u32,
    exact: bool,
    implementation_edge: bool,
    visited: *std.AutoHashMap(SymbolId, void),
) anyerror!void {
    std.debug.assert(id < idx.graph.symbols.len);
    try nodeHead(w, idx, idx.graph.symbols[id]);
    // The call-site line of the edge to this node's parent (0 = root/no edge).
    if (site != 0) try w.print(",\"site\":{d}", .{site});
    // Number of call sites this edge represents (omitted when 1).
    if (site != 0 and sites > 1) try w.print(",\"sites\":{d}", .{sites});
    // Every distinct call-site line, when the edge spans more than one.
    if (site != 0 and lines.len > 1) {
        try w.writeAll(",\"lines\":[");
        for (lines, 0..) |ln, k| {
            if (k != 0) try w.writeByte(',');
            try w.print("{d}", .{ln});
        }
        try w.writeByte(']');
    }
    // Only heuristic (name-match) edges are annotated; absence means confident.
    if ((site != 0 or implementation_edge) and !exact) try w.writeAll(",\"exact\":false");
    if (implementation_edge) try w.writeAll(",\"edge\":\"impl\"");
    if (depth >= opts.depth) {
        if (impl_graph) |graph| try implLeafArray(w, idx, graph, id, incoming, opts.strict);
        return try w.writeByte('}');
    }
    if ((try visited.getOrPut(id)).found_existing) {
        try w.writeAll(",\"recursion\":true}");
        return;
    }
    if (incoming) {
        try walkCallers(w, idx, impl_graph, id, opts, depth, visited);
    } else {
        try walkCallees(w, idx, impl_graph, id, opts, depth, visited);
    }
    try w.writeByte('}');
}

fn walkCallees(
    w: *Writer,
    idx: *const Index,
    impl_graph: ?*const impls_mod.Graph,
    id: SymbolId,
    opts: Options,
    depth: u32,
    visited: *std.AutoHashMap(SymbolId, void),
) !void {
    const sym = idx.graph.symbols[id];
    try w.writeAll(",\"callees\":[");
    var wrote: u32 = 0;
    var ext: u32 = 0;
    for (sym.refs) |ref| {
        // Every resolved edge is a callee; bare var/const/field reads are hidden
        // unless `--refs` is set (see query.isDataReadEdge). Only unresolved
        // *calls* become externals (see query.walkCallees).
        if (ref.target != invalid and (!opts.strict or ref.exact)) {
            if (!opts.refs and query.isDataReadEdge(idx, ref)) continue;
            if (wrote != 0) try w.writeByte(',');
            try walkNode(w, idx, impl_graph, ref.target, false, opts, depth + 1, ref.line, ref.count, ref.lines, ref.exact, false, visited);
            wrote += 1;
        } else if (ref.kind == .call or ref.kind == .route_call) {
            ext += 1;
        }
    }
    if (impl_graph) |graph| {
        for (graph.edges) |edge| {
            if (edge.port_method != id or (opts.strict and !edge.exact)) continue;
            if (wrote != 0) try w.writeByte(',');
            try walkNode(w, idx, impl_graph, edge.implementation_method, false, opts, depth + 1, 0, 1, &.{}, edge.exact, true, visited);
            wrote += 1;
        }
    }
    try w.writeByte(']');
    if (ext != 0) try writeExternals(w, sym, opts.strict);
}

fn implLeafArray(w: *Writer, idx: *const Index, graph: *const impls_mod.Graph, id: SymbolId, incoming: bool, strict: bool) !void {
    var first = true;
    for (graph.edges) |edge| {
        if (strict and !edge.exact) continue;
        var target: SymbolId = invalid;
        if (edge.port_method == id) target = edge.implementation_method;
        if (incoming and edge.implementation_method == id) target = edge.port_method;
        if (target == invalid) continue;
        if (first) try w.writeAll(",\"implementations\":[") else try w.writeByte(',');
        first = false;
        try nodeHead(w, idx, idx.graph.symbols[target]);
        try w.writeAll(",\"edge\":\"impl\"");
        if (!edge.exact) try w.writeAll(",\"exact\":false");
        try w.writeByte('}');
    }
    if (!first) try w.writeByte(']');
}

fn writeExternals(w: *Writer, sym: Symbol, strict: bool) !void {
    try w.writeAll(",\"ext\":[");
    var wrote: u32 = 0;
    for (sym.refs) |ref| {
        if (ref.kind != .call and ref.kind != .route_call) continue;
        if (ref.target != invalid and (!strict or ref.exact)) continue;
        if (wrote != 0) try w.writeByte(',');
        try writeString(w, ref.name);
        wrote += 1;
    }
    try w.writeByte(']');
}

fn walkCallers(
    w: *Writer,
    idx: *const Index,
    impl_graph: ?*const impls_mod.Graph,
    id: SymbolId,
    opts: Options,
    depth: u32,
    visited: *std.AutoHashMap(SymbolId, void),
) !void {
    try w.writeAll(",\"callers\":[");
    var wrote: u32 = 0;
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    for (idx.callersOf(id)) |cid| {
        if (opts.strict and !query.hasExactEdge(idx, cid, id)) continue;
        if (!query.inTestScope(opts.tests, query.isTestSymbol(idx, idx.graph.symbols[cid]))) continue;
        if (wrote != 0) try w.writeByte(',');
        try query.callSiteLines(idx, cid, id, &lines);
        try walkNode(w, idx, impl_graph, cid, true, opts, depth + 1, query.callSiteLine(idx, cid, id), query.callSiteCount(idx, cid, id), lines.items, query.hasExactEdge(idx, cid, id), false, visited);
        wrote += 1;
    }
    if (impl_graph) |graph| {
        for (graph.edges) |edge| {
            if (opts.strict and !edge.exact) continue;
            const target = if (edge.port_method == id)
                edge.implementation_method
            else if (edge.implementation_method == id)
                edge.port_method
            else
                continue;
            if (wrote != 0) try w.writeByte(',');
            try walkNode(w, idx, impl_graph, target, true, opts, depth + 1, 0, 1, &.{}, edge.exact, true, visited);
            wrote += 1;
        }
    }
    try w.writeByte(']');
}

/// Hot: array of `{...symbol, fan_in, fan_in_exact, fan_in_test, fan_out, fan_out_exact}`
/// ranked by connectivity. `*_exact` exclude heuristic `?` edges; `fan_in_test`
/// is the share of callers in test files; `--strict` drops entries whose
/// connectivity is entirely heuristic.
pub fn hot(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    const ranked = try query.collectHot(idx, filter, opts.tests);
    defer idx.gpa.free(ranked);
    const limit = query.hotLimit(opts);
    try w.writeByte('[');
    var shown: u32 = 0;
    for (ranked) |e| {
        if (opts.strict and e.fan_in_exact == 0 and e.fan_out_exact == 0) continue;
        if (shown >= limit) break;
        if (shown != 0) try w.writeByte(',');
        shown += 1;
        const sym = idx.graph.symbols[e.id];
        try nodeHead(w, idx, sym);
        try w.writeAll(",\"sig\":");
        try writeCollapsedString(w, sym.signature(idx.graph.files[sym.file].text), max_sig_len);
        try w.print(",\"fan_in\":{d},\"fan_in_exact\":{d},\"fan_in_test\":{d},\"fan_out\":{d},\"fan_out_exact\":{d}}}", .{
            e.fan_in, e.fan_in_exact, e.fan_in_test, e.fan_out, e.fan_out_exact,
        });
    }
    try w.writeAll("]\n");
    return shown > 0;
}

/// Protocol conformance matrix. Structural relationships carry exact=false.
pub fn conforms(w: *Writer, idx: *const Index, selector: []const u8, opts: Options) !bool {
    var buf: [64]SymbolId = undefined;
    const ids = query.resolveIds(idx, selector, &buf);
    var graph = try impls_mod.build(idx.gpa, idx);
    defer graph.deinit();
    var shown: u32 = 0;
    try w.writeByte('[');
    for (ids) |id| {
        var port = idx.graph.symbols[id];
        if (port.kind == .method and port.parent != invalid) port = idx.graph.symbols[port.parent];
        if (!impls_mod.isPort(idx, port)) continue;
        if (shown != 0) try w.writeByte(',');
        try conformanceObject(w, idx, &graph, port, opts.strict);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (shown == 0 and !opts.strict and try siblingConformanceObject(w, idx, ids)) shown = 1;
    try w.writeAll("]\n");
    return shown > 0;
}

fn siblingConformanceObject(w: *Writer, idx: *const Index, ids: []const SymbolId) !bool {
    var parents: [64]SymbolId = undefined;
    const count = query.collectConformanceParents(idx, ids, &parents);
    if (count < 2) return false;
    try w.writeAll("{\"siblings\":[");
    for (parents[0..count], 0..) |parent, k| {
        if (k != 0) try w.writeByte(',');
        try symbolObject(w, idx, idx.graph.symbols[parent], .names);
    }
    try w.writeAll("],\"members\":[");
    var names = std.StringHashMap(void).init(idx.gpa);
    defer names.deinit();
    var first = true;
    for (idx.graph.symbols) |expected| {
        if (expected.kind != .method or !query.contains(parents[0..count], expected.parent)) continue;
        if (query.idsContainMethods(idx, ids) and !query.contains(ids, expected.id)) continue;
        if ((try names.getOrPut(expected.name)).found_existing) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try siblingMemberObject(w, idx, parents[0..count], expected);
    }
    try w.writeAll("]}");
    return true;
}

fn siblingMemberObject(w: *Writer, idx: *const Index, parents: []const SymbolId, expected: Symbol) !void {
    try w.writeAll("{\"expected\":");
    try symbolObject(w, idx, expected, .sig);
    try w.writeAll(",\"implementations\":[");
    for (parents, 0..) |parent, k| {
        if (k != 0) try w.writeByte(',');
        const actual_id = impls_mod.methodOf(idx, parent, expected.name);
        const actual = if (actual_id) |id| idx.graph.symbols[id] else null;
        try w.writeAll("{\"verdict\":");
        try writeString(w, @tagName(query.conformanceVerdict(idx, expected, actual)));
        try w.writeAll(",\"symbol\":");
        if (actual) |sym| try symbolObject(w, idx, sym, .sig) else try w.writeAll("null");
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn conformanceObject(w: *Writer, idx: *const Index, graph: *const impls_mod.Graph, port: Symbol, strict: bool) !void {
    try w.writeAll("{\"protocol\":");
    try symbolObject(w, idx, port, .names);
    try w.writeAll(",\"members\":[");
    var first_method = true;
    for (idx.graph.symbols) |expected| {
        if (expected.parent != port.id or expected.kind != .method) continue;
        if (!first_method) try w.writeByte(',');
        first_method = false;
        try conformanceMember(w, idx, graph, port.id, expected, strict);
    }
    try w.writeAll("]}");
}

fn conformanceMember(w: *Writer, idx: *const Index, graph: *const impls_mod.Graph, port: SymbolId, expected: Symbol, strict: bool) !void {
    try w.writeAll("{\"expected\":");
    try symbolObject(w, idx, expected, .sig);
    try w.writeAll(",\"implementations\":[");
    var first = true;
    for (graph.relations) |rel| {
        if (rel.port != port or (strict and !rel.exact)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        const actual_id = impls_mod.methodOf(idx, rel.implementation, expected.name);
        try w.writeAll("{\"verdict\":");
        const actual = if (actual_id) |aid| idx.graph.symbols[aid] else null;
        try writeString(w, @tagName(query.conformanceVerdict(idx, expected, actual)));
        try w.print(",\"exact\":{},\"symbol\":", .{rel.exact});
        if (actual) |sym| try symbolObject(w, idx, sym, .sig) else try w.writeAll("null");
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// Routes: route coverage views, or unresolved client calls with --orphan-calls.
pub fn listRoutes(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    if (opts.routes_orphan_calls) return orphanRouteCalls(w, idx, filter, opts);
    var shown: u32 = 0;
    try w.writeByte('[');
    for (idx.graph.symbols) |route| {
        if (route.kind != .route) continue;
        if (!query.routeMatches(idx, route, filter, opts.routes_handler)) continue;
        if (opts.routes_unhit and idx.callersOf(route.id).len != 0) continue;
        if (shown != 0) try w.writeByte(',');
        try routeObject(w, idx, route, opts.routes_clients, opts.routes_unhit);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    try w.writeAll("]\n");
    return shown > 0;
}

fn routeObject(w: *Writer, idx: *const Index, route: Symbol, clients_only: bool, unhit: bool) !void {
    try w.writeAll("{\"route\":");
    try writeString(w, route.name);
    try w.writeAll(",\"file\":");
    try writeString(w, idx.graph.files[route.file].path);
    try w.print(",\"line\":{d},\"handler\":", .{route.line});
    if (clients_only or query.routeHandler(idx, route) == null) {
        try w.writeAll("null");
    } else {
        try symbolObject(w, idx, query.routeHandler(idx, route).?, .names);
    }
    try w.writeAll(",\"clients\":[");
    for (idx.callersOf(route.id), 0..) |cid, k| {
        if (k != 0) try w.writeByte(',');
        const client = idx.graph.symbols[cid];
        try w.writeAll("{\"lang\":");
        try writeString(w, idx.graph.files[client.file].language.tag());
        try w.writeAll(",\"symbol\":");
        try symbolObject(w, idx, client, .names);
        try w.print(",\"site\":{d}}}", .{query.callSiteLine(idx, cid, route.id)});
    }
    try w.writeAll("],\"callers\":[");
    for (idx.callersOf(route.id), 0..) |cid, k| {
        if (k != 0) try w.writeByte(',');
        try symbolObject(w, idx, idx.graph.symbols[cid], .names);
    }
    try w.print("],\"unhit\":{}}}", .{unhit});
}

fn orphanRouteCalls(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    var shown: u32 = 0;
    try w.writeByte('[');
    outer: for (idx.graph.symbols) |owner| {
        for (owner.refs) |ref| {
            if (ref.kind != .route_call or ref.target != invalid) continue;
            if (!query.matchesName(filter, ref.name)) continue;
            if (shown != 0) try w.writeByte(',');
            try w.writeAll("{\"route_call\":");
            try writeString(w, ref.name);
            try w.writeAll(",\"lang\":");
            try writeString(w, idx.graph.files[owner.file].language.tag());
            try w.writeAll(",\"symbol\":");
            try symbolObject(w, idx, owner, .names);
            try w.print(",\"site\":{d},\"matched\":false}}", .{ref.line});
            shown += 1;
            if (shown >= opts.limit) break :outer;
        }
    }
    try w.writeAll("]\n");
    return shown > 0;
}

/// Diff: array of `{file, symbols:[{...symbol, callers:[...]}]}` — changed symbols
/// and their direct callers (blast radius) per file. Returns whether any changed
/// symbol was reported.
pub fn diff(w: *Writer, idx: *const Index, changes: []const gitdiff.FileChange, opts: Options) !bool {
    _ = opts;
    var any_symbol = false;
    try w.writeByte('[');
    var first_file = true;
    for (changes) |change| {
        const file = query.findDiffFile(idx, change.path) orelse continue;
        var opened = false;
        var i = file.sym_start;
        while (i < file.sym_end) : (i += 1) {
            const sym = idx.graph.symbols[i];
            if (sym.kind == .import) continue;
            if (!query.symbolTouched(sym, idx.graph.files[sym.file].text, change.ranges)) continue;
            if (!opened) {
                if (!first_file) try w.writeByte(',');
                first_file = false;
                try w.writeAll("{\"file\":");
                try writeString(w, change.path);
                try w.writeAll(",\"symbols\":[");
                opened = true;
            } else {
                try w.writeByte(',');
            }
            any_symbol = true;
            try nodeHead(w, idx, sym);
            try w.writeAll(",\"callers\":[");
            for (idx.callersOf(sym.id), 0..) |cid, k| {
                if (k != 0) try w.writeByte(',');
                try symbolObject(w, idx, idx.graph.symbols[cid], .names);
            }
            try w.writeAll("]}");
        }
        if (opened) try w.writeAll("]}");
    }
    try w.writeAll("]\n");
    return any_symbol;
}

/// Events: array of `{key, sites:[{role, verb, file, line, in}]}` grouped by
/// key. Returns whether any key group was written.
pub fn events(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    const sites = try query.collectEvents(idx, filter);
    defer idx.gpa.free(sites);
    try w.writeByte('[');
    var shown_keys: u32 = 0;
    var i: usize = 0;
    while (i < sites.len) {
        const key = sites[i].ref.key;
        if (shown_keys != 0) try w.writeByte(',');
        try w.writeAll("{\"key\":");
        try writeString(w, key);
        try w.writeAll(",\"sites\":[");
        var first = true;
        while (i < sites.len and std.mem.eql(u8, sites[i].ref.key, key)) : (i += 1) {
            if (!first) try w.writeByte(',');
            first = false;
            try eventSiteObject(w, idx, sites[i]);
        }
        try w.writeAll("]}");
        shown_keys += 1;
        if (shown_keys >= opts.limit) break;
    }
    try w.writeAll("]\n");
    return shown_keys > 0;
}

fn eventSiteObject(w: *Writer, idx: *const Index, site: query.EventSite) !void {
    const file = idx.graph.files[site.file];
    try w.writeAll("{\"role\":");
    try writeString(w, if (site.ref.role == .handler) "handler" else "emitter");
    try w.writeAll(",\"verb\":");
    try writeString(w, site.ref.verb);
    try w.writeAll(",\"file\":");
    try writeString(w, file.path);
    try w.print(",\"line\":{d}", .{site.ref.line});
    const owner = query.enclosingSymbolName(idx, file, site.ref.offset);
    if (owner.len != 0) {
        try w.writeAll(",\"in\":");
        try writeString(w, owner);
    }
    try w.writeByte('}');
}

/// Neighbors: `{symbol, callees:[...], callers:[...]}` per resolved id. Returns
/// whether `name` resolved to at least one symbol.
pub fn neighbors(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !bool {
    var buf: [64]SymbolId = undefined;
    const ids = query.resolveIds(idx, name, &buf);
    var impl_graph: ?impls_mod.Graph = if (opts.impls) try impls_mod.build(idx.gpa, idx) else null;
    defer if (impl_graph) |*graph| graph.deinit();
    try w.writeByte('[');
    for (ids, 0..) |id, k| {
        if (k != 0) try w.writeByte(',');
        const sym = idx.graph.symbols[id];
        try nodeHead(w, idx, sym);
        try w.writeAll(",\"callees\":[");
        try calleeArray(w, idx, if (impl_graph) |*g| g else null, sym, opts.strict);
        try w.writeAll("],\"callers\":[");
        var wrote: usize = 0;
        for (idx.callersOf(id)) |cid| {
            if (opts.strict and !query.hasExactEdge(idx, cid, id)) continue;
            if (wrote != 0) try w.writeByte(',');
            try nodeHead(w, idx, idx.graph.symbols[cid]);
            const site = query.callSiteLine(idx, cid, id);
            if (site != 0) try w.print(",\"site\":{d}", .{site});
            try w.writeByte('}');
            wrote += 1;
        }
        if (impl_graph) |*graph| {
            for (graph.edges) |edge| {
                if (opts.strict and !edge.exact) continue;
                const target = if (edge.port_method == id)
                    edge.implementation_method
                else if (edge.implementation_method == id)
                    edge.port_method
                else
                    continue;
                if (wrote != 0) try w.writeByte(',');
                try implNode(w, idx, target, edge.exact);
                wrote += 1;
            }
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]\n");
    return ids.len > 0;
}

fn calleeArray(w: *Writer, idx: *const Index, graph: ?*const impls_mod.Graph, sym: Symbol, strict: bool) !void {
    var wrote: u32 = 0;
    for (sym.refs) |ref| {
        if (ref.target == invalid or (strict and !ref.exact)) continue;
        if (wrote != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[ref.target]);
        if (ref.line != 0) try w.print(",\"site\":{d}", .{ref.line});
        try w.writeByte('}');
        wrote += 1;
    }
    if (graph) |impl_graph| {
        for (impl_graph.edges) |edge| {
            if (edge.port_method != sym.id or (strict and !edge.exact)) continue;
            if (wrote != 0) try w.writeByte(',');
            try implNode(w, idx, edge.implementation_method, edge.exact);
            wrote += 1;
        }
    }
}

fn implNode(w: *Writer, idx: *const Index, id: SymbolId, exact: bool) !void {
    try nodeHead(w, idx, idx.graph.symbols[id]);
    try w.writeAll(",\"edge\":\"impl\"");
    if (!exact) try w.writeAll(",\"exact\":false");
    try w.writeByte('}');
}

/// Unused: a JSON array of zero-caller function/method symbols. Returns
/// whether any candidate was reported.
pub fn unused(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    var refs = try query.buildReferencedNames(idx);
    defer refs.deinit();
    if (opts.unused_follow_imports) refs.scope = try query.buildCollisionScope(idx);
    var shown: u32 = 0;
    try w.writeByte('[');
    for (idx.graph.symbols) |sym| {
        if (!try query.isDeadCandidateScoped(idx, sym, filter, &refs, opts.tests)) continue;
        if (!query.deadCandidateShown(idx, sym, opts, &refs)) continue;
        if (shown != 0) try w.writeByte(',');
        // A name used only from tests is a real cleanup target — flag it so JSON
        // consumers can separate it from truly-unreferenced code.
        try symbolObjectExtra(w, idx, sym, opts.verbosity, refs.testsContains(query.familyOf(idx, sym), sym.name));
        shown += 1;
        if (shown >= opts.limit) break;
    }
    try w.writeAll("]\n");
    return shown > 0;
}

/// Imports: `{file, imports:[{target, binding}]}` per in-scope file.
/// Index coverage manifest: `{file, lang, symbols}` per indexed file. Returns
/// whether any file matched.
pub fn listFiles(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    var first = true;
    try w.writeByte('[');
    for (idx.graph.files) |file| {
        if (!query.matchesFilter(file.path, filter)) continue;
        if (opts.no_recurse and !query.inDirNonRecursive(file.path, filter)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"file\":");
        try writeString(w, file.path);
        try w.print(",\"lang\":\"{s}\",\"symbols\":{d}}}", .{ file.language.tag(), query.fileSymbolCount(idx, file) });
    }
    try w.writeAll("]\n");
    return !first;
}

/// Returns whether any file with fn/method symbols matched (i.e. the coverage
/// report is non-empty).
pub fn coverage(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    _ = opts;
    const reached = try query.testReachable(idx, idx.gpa);
    defer idx.gpa.free(reached);
    var total: u32 = 0;
    var covered: u32 = 0;
    var first = true;
    try w.writeAll("{\"files\":[");
    for (idx.graph.files) |file| {
        if (!query.matchesFilter(file.path, filter)) continue;
        var ft: u32 = 0;
        var fc: u32 = 0;
        var i = file.sym_start;
        while (i < file.sym_end) : (i += 1) {
            const sym = idx.graph.symbols[i];
            if (sym.kind != .function and sym.kind != .method) continue;
            if (query.isTestSymbol(idx, sym)) continue;
            ft += 1;
            if (reached[sym.id]) fc += 1;
        }
        if (ft == 0) continue;
        total += ft;
        covered += fc;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"file\":");
        try writeString(w, file.path);
        try w.print(",\"covered\":{d},\"total\":{d},\"percent\":{d:.1}}}", .{ fc, ft, covPct(fc, ft) });
    }
    try w.print("],\"covered\":{d},\"total\":{d},\"percent\":{d:.1}}}\n", .{ covered, total, covPct(covered, total) });
    return !first;
}

fn covPct(num: u32, den: u32) f64 {
    if (den == 0) return 100.0;
    return 100.0 * @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

/// Returns whether any in-scope file had imports to report.
pub fn listImports(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    _ = opts;
    var first = true;
    try w.writeByte('[');
    for (idx.graph.files) |file| {
        const imps = idx.importsOf(file.id);
        if (imps.len == 0 or !query.matchesFilter(file.path, filter)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"file\":");
        try writeString(w, file.path);
        try w.writeAll(",\"imports\":[");
        for (imps, 0..) |imp, k| {
            if (k != 0) try w.writeByte(',');
            try w.writeAll("{\"target\":");
            try writeString(w, idx.graph.files[imp.target].path);
            try w.writeAll(",\"binding\":");
            try writeString(w, imp.binding);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]\n");
    return !first;
}

/// Importers: `{file, importers:[path...]}` per file matching `path`. Returns
/// whether any importer was actually found (mirrors the text renderer, which
/// counts a target with zero importers as nothing found).
pub fn listImporters(w: *Writer, idx: *const Index, path: []const u8, opts: Options) !bool {
    _ = opts;
    var first = true;
    var any_importer = false;
    try w.writeByte('[');
    for (idx.graph.files) |target| {
        if (!query.matchesFilter(target.path, path)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"file\":");
        try writeString(w, target.path);
        try w.writeAll(",\"importers\":[");
        var wrote: u32 = 0;
        for (idx.graph.files) |src| {
            if (!fileImports(idx, src.id, target.id)) continue;
            if (wrote != 0) try w.writeByte(',');
            try writeString(w, src.path);
            wrote += 1;
            any_importer = true;
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]\n");
    return any_importer;
}

fn fileImports(idx: *const Index, src: model.FileId, target: model.FileId) bool {
    for (idx.importsOf(src)) |imp| if (imp.target == target) return true;
    return false;
}

/// Path: a JSON array of the symbols on the shortest call path (empty if
/// none). Returns whether a path was found.
pub fn shortestPath(w: *Writer, idx: *const Index, from_name: []const u8, to_name: []const u8, opts: Options) !bool {
    var fbuf: [64]SymbolId = undefined;
    var tbuf: [64]SymbolId = undefined;
    const chain = query.shortestPathIdsWithOptions(idx, from_name, to_name, &fbuf, &tbuf, opts) catch {
        try w.writeAll("[]\n");
        return false;
    };
    defer idx.gpa.free(chain);
    try w.writeByte('[');
    for (chain, 0..) |id, k| {
        if (k != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[id]);
        try w.writeByte('}');
    }
    try w.writeAll("]\n");
    return chain.len > 0;
}

// ---------------------------------------------------------------------------
// Shared object writers
// ---------------------------------------------------------------------------

fn symbolArray(w: *Writer, idx: *const Index, ids: []const SymbolId, v: render.Verbosity) !void {
    try w.writeByte('[');
    for (ids, 0..) |id, k| {
        if (k != 0) try w.writeByte(',');
        try symbolObject(w, idx, idx.graph.symbols[id], v);
    }
    try w.writeAll("]\n");
}

/// A symbol node header (id/kind/name/file/line) without the closing brace, so
/// callers can append tree fields (callees/callers/recursion).
fn nodeHead(w: *Writer, idx: *const Index, sym: Symbol) !void {
    try w.print("{{\"id\":{d},\"kind\":\"{s}\",\"name\":", .{ sym.id, sym.kind.tag() });
    try writeString(w, sym.name);
    // The enclosing symbol's name (a method's class / a Go method's receiver
    // type), so class-scoped analysis never needs line-range bookkeeping.
    if (sym.parent != invalid) {
        try w.writeAll(",\"parent\":");
        try writeString(w, idx.graph.symbols[sym.parent].name);
    }
    try w.print(",\"file\":", .{});
    try writeString(w, idx.graph.files[sym.file].path);
    const source = idx.graph.files[sym.file].text;
    try w.print(",\"line\":{d},\"line_end\":{d}", .{ sym.line, sym.endLine(source) });
    try writeModifiers(w, sym);
}

/// Emit `,"modifiers":[...]` (accessor/dispatch/async) when any are set; the
/// `kind` field stays the base kind so consumers can rely on it.
fn writeModifiers(w: *Writer, sym: Symbol) !void {
    const m = sym.modifiers;
    if (!m.any()) return;
    try w.writeAll(",\"modifiers\":[");
    var first = true;
    if (m.is_static) try modItem(w, &first, "static");
    if (m.is_async) try modItem(w, &first, "async");
    if (m.getter) try modItem(w, &first, "getter");
    if (m.setter) try modItem(w, &first, "setter");
    if (m.classmethod) try modItem(w, &first, "classmethod");
    if (m.abstract) try modItem(w, &first, "abstract");
    try w.writeByte(']');
}

fn modItem(w: *Writer, first: *bool, name: []const u8) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeByte('"');
    try w.writeAll(name);
    try w.writeByte('"');
}

/// A full symbol object; fields grow with verbosity (sig, then doc, then body).
fn symbolObject(w: *Writer, idx: *const Index, sym: Symbol, v: render.Verbosity) !void {
    return symbolObjectExtra(w, idx, sym, v, false);
}

fn symbolObjectExtra(w: *Writer, idx: *const Index, sym: Symbol, v: render.Verbosity, test_only: bool) !void {
    try nodeHead(w, idx, sym); // includes "parent" when the symbol has one
    try w.print(",\"exported\":{}", .{sym.exported});
    const source = idx.graph.files[sym.file].text;
    if (v != .names) {
        try w.writeAll(",\"sig\":");
        try writeCollapsedString(w, sym.signature(source), max_sig_len);
    }
    if (v == .doc or v == .full) {
        const doc = render.stripDoc(sym.doc);
        if (doc.len != 0) {
            try w.writeAll(",\"doc\":");
            try writeCollapsedString(w, doc, 400);
        }
    }
    if (v == .full) {
        try w.writeAll(",\"body\":");
        try writeString(w, sym.body(source));
    }
    if (test_only) try w.writeAll(",\"test_only\":true");
    try w.writeByte('}');
}

// ---------------------------------------------------------------------------
// JSON string escaping
// ---------------------------------------------------------------------------

/// Write `s` as a quoted, escaped JSON string.
fn writeString(w: *Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| try writeEscaped(w, c);
    try w.writeByte('"');
}

/// Write `text` as a JSON string with interior whitespace collapsed to single
/// spaces and length capped (mirrors the compact text renderer).
fn writeCollapsedString(w: *Writer, text: []const u8, cap: usize) !void {
    try w.writeByte('"');
    var written: usize = 0;
    var prev_space = false;
    for (text) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            prev_space = written != 0;
            continue;
        }
        if (prev_space and written < cap) {
            try w.writeByte(' ');
            written += 1;
        }
        prev_space = false;
        if (written >= cap) break;
        try writeEscaped(w, c);
        written += 1;
    }
    try w.writeByte('"');
}

fn writeEscaped(w: *Writer, c: u8) !void {
    switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    }
}

test "json output is well-formed and escapes control characters" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "u.zig", .data = 
        \\/// Adds two numbers "safely".
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\pub fn run() i32 {
        \\    return add(1, 2);
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // Render `calls run --json -v doc` into a growable buffer and check shape.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try walk(&aw.writer, &idx, "run", false, .{ .depth = 2, .verbosity = .doc, .format = .json });
    const out = aw.written();

    try testing.expect(out.len > 2);
    try testing.expectEqual(@as(u8, '['), out[0]);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"run\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"callees\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"add\"") != null);
    try testing.expect(balancedBrackets(out));

    // `def add --json -v doc` carries the doc; its embedded quotes must be
    // escaped so the document stays well-formed.
    var dbuf: std.ArrayList(u8) = .empty;
    defer dbuf.deinit(testing.allocator);
    var daw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &dbuf);
    defer daw.deinit();
    _ = try showDef(&daw.writer, &idx, "add", .{ .verbosity = .doc, .format = .json });
    const def_out = daw.written();
    try testing.expect(std.mem.indexOf(u8, def_out, "\\\"safely\\\"") != null);
    try testing.expect(balancedBrackets(def_out));
}

test "json carries modifiers and the strings verb is well-formed" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.ts", .data =
        \\export class Store {
        \\  get value(): number { return 1; }
        \\  async load() { return fetch("/api/health"); }
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // `def value -j`: kind stays "method"; modifiers carries "getter".
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "value", .{ .format = .json });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"method\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "\"modifiers\":[\"getter\"]") != null);
        try testing.expect(balancedBrackets(out));
    }
    { // `strings /api -j`: a `{file,line,text}` array.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try strings(&aw.writer, &idx, "/api/health", .{ .format = .json });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "\"text\":\"\\\"/api/health\\\"\"") != null);
        try testing.expect(balancedBrackets(out));
    }
}

/// Cheap structural check: every `[`/`{` is closed, ignoring string contents.
fn balancedBrackets(s: []const u8) bool {
    var depth: i32 = 0;
    var in_str = false;
    var escaped = false;
    for (s) |c| {
        if (in_str) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            else => {},
        }
        if (depth < 0) return false;
    }
    return depth == 0 and !in_str;
}


// ===========================================================================
// Appended tests: JSON rendering of every verb, escaping, and structural checks.
// ===========================================================================

/// A fresh growable JSON writer. `fromArrayList` empties the (empty) list and
/// takes ownership, so the returned Allocating owns its own buffer.
fn tjWriter() std.Io.Writer.Allocating {
    var buf: std.ArrayList(u8) = .empty;
    return std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buf);
}

/// Build an index rooted at `tmp`'s scratch directory (non-cached).
fn tjBuild(tmp: *std.testing.TmpDir) !Index {
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    return index_mod.build(std.testing.allocator, std.testing.io, root, false);
}

/// Parse `s` as a JSON document, proving it is well-formed. Caller must
/// `.deinit()` the returned value.
fn tjParse(s: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, s, .{});
}

// --- pure string escaping -------------------------------------------------

test "writeString quotes and escapes specials, control chars, and passes printables" {
    var b: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    // quote, backslash, newline, tab, cr, control 0x01, control 0x1f, plain 'x'.
    try writeString(&w, "a\"b\\c\nd\te\rf\x01g\x1fx");
    const out = w.buffered();
    try std.testing.expectEqualStrings(
        "\"a\\\"b\\\\c\\nd\\te\\rf\\u0001g\\u001fx\"",
        out,
    );
}

test "writeEscaped maps each special byte and leaves printable ASCII intact" {
    const testing = std.testing;
    const Case = struct { in: u8, want: []const u8 };
    const cases = [_]Case{
        .{ .in = '"', .want = "\\\"" },
        .{ .in = '\\', .want = "\\\\" },
        .{ .in = '\n', .want = "\\n" },
        .{ .in = '\r', .want = "\\r" },
        .{ .in = '\t', .want = "\\t" },
        .{ .in = 0, .want = "\\u0000" },
        .{ .in = 8, .want = "\\u0008" },
        .{ .in = 11, .want = "\\u000b" },
        .{ .in = 12, .want = "\\u000c" },
        .{ .in = 31, .want = "\\u001f" },
        .{ .in = 'A', .want = "A" },
        .{ .in = ' ', .want = " " },
        .{ .in = '~', .want = "~" },
    };
    for (cases) |c| {
        var b: [16]u8 = undefined;
        var w = std.Io.Writer.fixed(&b);
        try writeEscaped(&w, c.in);
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "writeCollapsedString collapses interior whitespace and trims edges" {
    var b: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    try writeCollapsedString(&w, "  fn   foo (a,\n\tb)  ", 200);
    // Leading/trailing runs are dropped; interior runs collapse to one space.
    try std.testing.expectEqualStrings("\"fn foo (a, b)\"", w.buffered());
}

test "writeCollapsedString caps the length and never emits a trailing space" {
    var b: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    // 8 non-space chars requested via cap; the run after is dropped, no trailing gap.
    try writeCollapsedString(&w, "abcdefghijkl   more", 8);
    try std.testing.expectEqualStrings("\"abcdefgh\"", w.buffered());
}

test "writeCollapsedString escapes embedded quotes" {
    var b: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&b);
    try writeCollapsedString(&w, "say \"hi\"", 200);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", w.buffered());
}

// --- balancedBrackets -----------------------------------------------------

test "balancedBrackets accepts balanced and rejects malformed input" {
    const testing = std.testing;
    try testing.expect(balancedBrackets("[]"));
    try testing.expect(balancedBrackets("{}"));
    try testing.expect(balancedBrackets("[{\"a\":[1,2]},{}]"));
    // Brackets inside a string literal are ignored.
    try testing.expect(balancedBrackets("{\"k\":\"][}{\"}"));
    // An escaped quote does not end the string early.
    try testing.expect(balancedBrackets("{\"k\":\"a\\\"b\"}"));
    // Extra closer, missing closer, and an unterminated string all fail.
    try testing.expect(!balancedBrackets("[]]"));
    try testing.expect(!balancedBrackets("[{}"));
    try testing.expect(!balancedBrackets("{\"k\":\"unterminated}"));
    try testing.expect(!balancedBrackets("}{"));
}

// --- outline --------------------------------------------------------------

test "outline json is a well-formed array of files carrying symbol fields" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "o.zig", .data =
        \\pub fn foo() void {}
        \\fn bar() void {}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try outline(&aw.writer, &idx, "", .{ .format = .json });
    const out = aw.written();

    var p = try tjParse(out);
    defer p.deinit();
    try testing.expect(p.value == .array);
    const files = p.value.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    const f0 = files[0].object;
    try testing.expect(std.mem.endsWith(u8, f0.get("path").?.string, "o.zig"));
    try testing.expectEqualStrings("zig", f0.get("lang").?.string);
    const syms = f0.get("symbols").?.array.items;
    try testing.expectEqual(@as(usize, 2), syms.len);
    const s0 = syms[0].object;
    try testing.expectEqualStrings("fn", s0.get("kind").?.string);
    try testing.expectEqualStrings("foo", s0.get("name").?.string);
    try testing.expectEqual(@as(i64, 1), s0.get("line").?.integer);
    try testing.expect(s0.get("line_end").?.integer >= s0.get("line").?.integer);
    try testing.expectEqual(true, s0.get("exported").?.bool);
    // Default verbosity is `sig`, so a signature string is present.
    try testing.expect(s0.get("sig").?.string.len > 0);
    // `bar` is not exported.
    try testing.expectEqual(false, syms[1].object.get("exported").?.bool);
    try testing.expect(balancedBrackets(out));
}

test "outline json verbosity adds sig, then doc, then body" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "v.zig", .data =
        \\/// A documented helper.
        \\pub fn helper() u32 {
        \\    return 42;
        \\}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    const V = struct {
        fn field(verb: render.Verbosity, idxp: *const Index, key: []const u8) !bool {
            var aw = tjWriter();
            defer aw.deinit();
            _ = try outline(&aw.writer, idxp, "", .{ .format = .json, .verbosity = verb });
            var p = try tjParse(aw.written());
            defer p.deinit();
            const sym = p.value.array.items[0].object.get("symbols").?.array.items[0].object;
            return sym.get(key) != null;
        }
    };
    // names: no sig/doc/body. sig: sig only. doc: sig+doc. full: sig+doc+body.
    try testing.expect(!try V.field(.names, &idx, "sig"));
    try testing.expect(try V.field(.sig, &idx, "sig"));
    try testing.expect(!try V.field(.sig, &idx, "doc"));
    try testing.expect(try V.field(.doc, &idx, "doc"));
    try testing.expect(!try V.field(.doc, &idx, "body"));
    try testing.expect(try V.field(.full, &idx, "body"));
    try testing.expect(try V.field(.full, &idx, "doc"));
}

test "outline json empties on a non-matching filter and truncates at the limit" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn one() void {}
        \\pub fn two() void {}
        \\pub fn three() void {}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    { // filter matches no file → empty array.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "nosuchpath", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 0), p.value.array.items.len);
    }
    { // limit caps the total symbols shown.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "", .{ .format = .json, .limit = 2 });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 2), p.value.array.items[0].object.get("symbols").?.array.items.len);
    }
}

// --- def / search ---------------------------------------------------------

test "def json returns symbol objects with parent and exported fields" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "c.ts", .data =
        \\export class Box {
        \\  open() { return 1; }
        \\}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try showDef(&aw.writer, &idx, "open", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expect(p.value == .array);
    const obj = p.value.array.items[0].object;
    try testing.expectEqualStrings("open", obj.get("name").?.string);
    // The method's parent class is recorded.
    try testing.expectEqualStrings("Box", obj.get("parent").?.string);
    try testing.expect(obj.get("exported") != null);
}

test "def json for an unknown name is an empty array" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "e.zig", .data =
        \\pub fn present() void {}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try showDef(&aw.writer, &idx, "absent_symbol", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.value.array.items.len);
}

test "search json matches substrings, honors kinds, truncates, and empties" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.zig", .data =
        \\pub fn loadUser() void {}
        \\pub fn loadThing() void {}
        \\pub const LoadCount = 3;
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    { // substring "load" matches both fns (case-sensitive → not the const).
        var aw = tjWriter();
        defer aw.deinit();
        _ = try search(&aw.writer, &idx, "load", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 2), p.value.array.items.len);
    }
    { // kinds filter restricted to const → only LoadCount.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try search(&aw.writer, &idx, "Load", .{ .format = .json, .kinds = "const" });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
        try testing.expectEqualStrings("LoadCount", p.value.array.items[0].object.get("name").?.string);
    }
    { // limit truncates.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try search(&aw.writer, &idx, "load", .{ .format = .json, .limit = 1 });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
    }
    { // no match → empty array.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try search(&aw.writer, &idx, "zzznope", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 0), p.value.array.items.len);
    }
}

test "search --refs json emits reference objects with the resolved target" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "r.zig", .data =
        \\pub fn add(a: i32, b: i32) i32 { return a + b; }
        \\pub fn run() i32 { return add(1, 2); }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try searchRefs(&aw.writer, &idx, "add", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expect(p.value.array.items.len >= 1);
    // Find the use-site inside `run`.
    var found = false;
    for (p.value.array.items) |item| {
        const o = item.object;
        if (!std.mem.eql(u8, o.get("name").?.string, "add")) continue;
        if (!std.mem.eql(u8, o.get("in").?.string, "run")) continue;
        found = true;
        try testing.expect(o.get("line").?.integer >= 1);
        // The reference resolves to add's file.
        try testing.expect(std.mem.endsWith(u8, o.get("target").?.string, "r.zig"));
    }
    try testing.expect(found);
}

test "strings json emits file/line/text with a collapsed, escaped literal" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t.zig", .data =
        \\pub const msg = "hello    spaced   world";
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try strings(&aw.writer, &idx, "hello", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
    const o = p.value.array.items[0].object;
    try testing.expect(std.mem.endsWith(u8, o.get("file").?.string, "t.zig"));
    try testing.expect(o.get("line").?.integer >= 1);
    // Interior whitespace runs collapsed to single spaces; the surrounding
    // source quotes survive as literal characters of the token.
    try testing.expect(std.mem.indexOf(u8, o.get("text").?.string, "hello spaced world") != null);
}

// --- calls / callers (walk) ----------------------------------------------

test "calls json nests callees and marks a mutual-recursion cycle" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Mutual recursion: ping -> pong -> ping, where the third node revisits ping.
    try tmp.dir.writeFile(io, .{ .sub_path = "rec.zig", .data =
        \\pub fn ping() void { pong(); }
        \\pub fn pong() void { ping(); }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try walk(&aw.writer, &idx, "ping", false, .{ .format = .json, .depth = 4 });
    const out = aw.written();
    var p = try tjParse(out);
    defer p.deinit();
    const root = p.value.array.items[0].object;
    try testing.expectEqualStrings("ping", root.get("name").?.string);
    const callees = root.get("callees").?.array.items;
    try testing.expectEqual(@as(usize, 1), callees.len);
    try testing.expectEqualStrings("pong", callees[0].object.get("name").?.string);
    // Every callee edge carries the call-site line.
    try testing.expect(callees[0].object.get("site").?.integer >= 1);
    // The cycle closes when ping is revisited, marked recursion:true.
    try testing.expect(std.mem.indexOf(u8, out, "\"recursion\":true") != null);
}

test "calls json lists unresolved calls under ext" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x.zig", .data =
        \\pub fn caller() void { someMissingExternal(); }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try walk(&aw.writer, &idx, "caller", false, .{ .format = .json, .depth = 2 });
    var p = try tjParse(aw.written());
    defer p.deinit();
    const root = p.value.array.items[0].object;
    // No resolved callees, but the unresolved call surfaces in ext.
    try testing.expectEqual(@as(usize, 0), root.get("callees").?.array.items.len);
    const ext = root.get("ext").?.array.items;
    try testing.expectEqual(@as(usize, 1), ext.len);
    try testing.expectEqualStrings("someMissingExternal", ext[0].string);
}

test "calls json aggregates multiple call sites with sites and lines" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub fn target() void {}
        \\pub fn multi() void {
        \\    target();
        \\    target();
        \\}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try walk(&aw.writer, &idx, "multi", false, .{ .format = .json, .depth = 2 });
    var p = try tjParse(aw.written());
    defer p.deinit();
    const callees = p.value.array.items[0].object.get("callees").?.array.items;
    try testing.expectEqual(@as(usize, 1), callees.len);
    const edge = callees[0].object;
    try testing.expectEqualStrings("target", edge.get("name").?.string);
    // Two call sites → sites:2 and a lines array spanning both.
    try testing.expectEqual(@as(i64, 2), edge.get("sites").?.integer);
    const lines = edge.get("lines").?.array.items;
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqual(@as(i64, 3), lines[0].integer);
    try testing.expectEqual(@as(i64, 4), lines[1].integer);
}

test "callers json nests incoming edges with a call-site line" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zig", .data =
        \\pub fn leaf() void {}
        \\pub fn mid() void { leaf(); }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try walk(&aw.writer, &idx, "leaf", true, .{ .format = .json, .depth = 2 });
    var p = try tjParse(aw.written());
    defer p.deinit();
    const root = p.value.array.items[0].object;
    try testing.expectEqualStrings("leaf", root.get("name").?.string);
    const callers = root.get("callers").?.array.items;
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqualStrings("mid", callers[0].object.get("name").?.string);
    try testing.expect(callers[0].object.get("site").?.integer >= 1);
}

test "calls json flags a heuristic edge with exact:false; strict drops it" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `self.planning.create_run(1)` resolves only heuristically (untyped receiver).
    try tmp.dir.writeFile(io, .{ .sub_path = "svc.py", .data =
        \\class PlanningService:
        \\    def create_run(self, x):
        \\        return x
        \\
        \\class Handler:
        \\    def __init__(self):
        \\        self.planning = PlanningService()
        \\    def handle(self):
        \\        return self.planning.create_run(1)
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    { // Default walk annotates the heuristic edge with exact:false.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "handle", false, .{ .format = .json, .depth = 2 });
        const out = aw.written();
        var p = try tjParse(out);
        defer p.deinit();
        try testing.expect(std.mem.indexOf(u8, out, "\"exact\":false") != null);
    }
    { // Strict follows only exact edges → the heuristic callee is gone.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "handle", false, .{ .format = .json, .depth = 2, .strict = true });
        const out = aw.written();
        var p = try tjParse(out);
        defer p.deinit();
        try testing.expectEqual(@as(usize, 0), p.value.array.items[0].object.get("callees").?.array.items.len);
    }
}

// --- hot ------------------------------------------------------------------

test "hot json ranks by fan-in and carries the fan counters plus a sig" {
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
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try hot(&aw.writer, &idx, "", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    const items = p.value.array.items;
    try testing.expect(items.len >= 1);
    const top = items[0].object;
    try testing.expectEqualStrings("shared", top.get("name").?.string);
    try testing.expectEqual(@as(i64, 3), top.get("fan_in").?.integer);
    try testing.expectEqual(@as(i64, 3), top.get("fan_in_exact").?.integer);
    try testing.expectEqual(@as(i64, 0), top.get("fan_in_test").?.integer);
    try testing.expectEqual(@as(i64, 0), top.get("fan_out").?.integer);
    try testing.expectEqual(@as(i64, 0), top.get("fan_out_exact").?.integer);
    try testing.expect(top.get("sig").?.string.len > 0);
}

test "hot json strict drops an entry whose connectivity is entirely heuristic" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "svc.py", .data =
        \\class PlanningService:
        \\    def create_run(self, x):
        \\        return x
        \\
        \\class Handler:
        \\    def __init__(self):
        \\        self.planning = PlanningService()
        \\    def handle(self):
        \\        return self.planning.create_run(1)
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try hot(&aw.writer, &idx, "", .{ .format = .json, .strict = true });
    const out = aw.written();
    var p = try tjParse(out);
    defer p.deinit();
    // create_run's only fan-in is heuristic → strict omits it entirely.
    try testing.expect(std.mem.indexOf(u8, out, "create_run") == null);
}

// --- routes ---------------------------------------------------------------

test "routes json links a handler object and null for an inline arrow" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "routes.js", .data =
        \\const router = express.Router();
        \\router.get('/items', listItems);
        \\router.delete('/items/:id', (req, res) => { return del(); });
        \\function listItems(req, res) { return 1; }
        \\function del() { return 2; }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try listRoutes(&aw.writer, &idx, "", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    var saw_get = false;
    var saw_delete = false;
    for (p.value.array.items) |item| {
        const o = item.object;
        const route = o.get("route").?.string;
        try testing.expect(std.mem.endsWith(u8, o.get("file").?.string, "routes.js"));
        try testing.expect(o.get("line").?.integer >= 1);
        try testing.expect(o.get("callers") != null);
        if (std.mem.eql(u8, route, "GET /items")) {
            saw_get = true;
            // Its handler is the resolved listItems symbol object.
            try testing.expectEqualStrings("listItems", o.get("handler").?.object.get("name").?.string);
        } else if (std.mem.eql(u8, route, "DELETE /items/:id")) {
            saw_delete = true;
            // The inline arrow leaves no handler → null.
            try testing.expect(o.get("handler").? == .null);
        }
    }
    try testing.expect(saw_get and saw_delete);
}

// --- diff -----------------------------------------------------------------

test "diff json reports changed symbols and their callers (blast radius)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "d.zig", .data =
        \\pub fn helper() u32 {
        \\    return 1;
        \\}
        \\pub fn run() u32 {
        \\    return helper();
        \\}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    // Synthetic hunk touching helper's body (line 2), bypassing git.
    var ranges = [_]gitdiff.Range{.{ .lo = 2, .hi = 2 }};
    var changes = [_]gitdiff.FileChange{.{ .path = "d.zig", .ranges = &ranges }};

    var aw = tjWriter();
    defer aw.deinit();
    _ = try diff(&aw.writer, &idx, &changes, .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
    const file_obj = p.value.array.items[0].object;
    try testing.expectEqualStrings("d.zig", file_obj.get("file").?.string);
    const syms = file_obj.get("symbols").?.array.items;
    try testing.expectEqual(@as(usize, 1), syms.len);
    const changed = syms[0].object;
    try testing.expectEqualStrings("helper", changed.get("name").?.string);
    // run calls helper → run is the caller in the blast radius.
    const callers = changed.get("callers").?.array.items;
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqualStrings("run", callers[0].object.get("name").?.string);
}

test "diff json is an empty array when no changed file is indexed" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "d.zig", .data =
        \\pub fn only() void {}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var ranges = [_]gitdiff.Range{.{ .lo = 1, .hi = 1 }};
    var changes = [_]gitdiff.FileChange{.{ .path = "not_indexed.zig", .ranges = &ranges }};

    var aw = tjWriter();
    defer aw.deinit();
    _ = try diff(&aw.writer, &idx, &changes, .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.value.array.items.len);
}

// --- events ---------------------------------------------------------------

test "events json groups a key with role/verb/file/line/in site objects" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bus.py", .data =
        \\@register("start")
        \\def handle_start(msg):
        \\    return 1
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function go() {
        \\    socket.send("start");
        \\}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try events(&aw.writer, &idx, "", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
    const grp = p.value.array.items[0].object;
    try testing.expectEqualStrings("start", grp.get("key").?.string);
    const sites = grp.get("sites").?.array.items;
    try testing.expectEqual(@as(usize, 2), sites.len);
    var saw_handler = false;
    var saw_emitter = false;
    for (sites) |s| {
        const o = s.object;
        const role = o.get("role").?.string;
        try testing.expect(o.get("verb").?.string.len > 0);
        try testing.expect(o.get("line").?.integer >= 1);
        if (std.mem.eql(u8, role, "handler")) {
            saw_handler = true;
            // The decorator binds to its enclosing function.
            try testing.expectEqualStrings("handle_start", o.get("in").?.string);
        } else if (std.mem.eql(u8, role, "emitter")) {
            saw_emitter = true;
            try testing.expect(std.mem.endsWith(u8, o.get("file").?.string, "client.ts"));
        }
    }
    try testing.expect(saw_handler and saw_emitter);
}

test "events json honors the filter and limit" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data =
        \\function f() {
        \\    bus.on("alpha");
        \\    bus.emit("alpha");
        \\    bus.on("beta");
        \\    bus.emit("beta");
        \\}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    { // filter narrows to a single key.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try events(&aw.writer, &idx, "alpha", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
        try testing.expectEqualStrings("alpha", p.value.array.items[0].object.get("key").?.string);
    }
    { // limit caps the number of key groups.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try events(&aw.writer, &idx, "", .{ .format = .json, .limit = 1 });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
    }
}

// --- neighbors ------------------------------------------------------------

test "neighbors json splits callees and callers with call-site lines" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "n.zig", .data =
        \\pub fn leaf() void {}
        \\pub fn mid() void { leaf(); }
        \\pub fn top() void { mid(); }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try neighbors(&aw.writer, &idx, "mid", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    const o = p.value.array.items[0].object;
    try testing.expectEqualStrings("mid", o.get("name").?.string);
    const callees = o.get("callees").?.array.items;
    try testing.expectEqual(@as(usize, 1), callees.len);
    try testing.expectEqualStrings("leaf", callees[0].object.get("name").?.string);
    try testing.expect(callees[0].object.get("site").?.integer >= 1);
    const callers = o.get("callers").?.array.items;
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqualStrings("top", callers[0].object.get("name").?.string);
    try testing.expect(callers[0].object.get("site").?.integer >= 1);
}

// --- unused ---------------------------------------------------------------

test "unused json flags a test-only symbol with test_only:true" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.py", .data =
        \\def prod_used():
        \\    return 1
        \\def helper_tested_only():
        \\    return 2
        \\def truly_dead():
        \\    return 3
        \\def entry():
        \\    return prod_used()
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "test_lib.py", .data =
        \\from lib import helper_tested_only
        \\def test_it():
        \\    assert helper_tested_only() == 2
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    // `--no-tests` is the production-focused view where a test-only-used symbol
    // surfaces (and carries test_only:true).
    _ = try unused(&aw.writer, &idx, "", .{ .format = .json, .tests = .without });
    var p = try tjParse(aw.written());
    defer p.deinit();
    var test_only_flagged = false;
    var dead_plain = false;
    var found_prod = false;
    for (p.value.array.items) |item| {
        const o = item.object;
        const name = o.get("name").?.string;
        if (std.mem.eql(u8, name, "prod_used")) found_prod = true;
        if (std.mem.eql(u8, name, "helper_tested_only")) {
            test_only_flagged = o.get("test_only") != null and o.get("test_only").?.bool;
        }
        if (std.mem.eql(u8, name, "truly_dead")) {
            // A truly-dead symbol carries no test_only annotation.
            dead_plain = o.get("test_only") == null;
        }
    }
    try testing.expect(test_only_flagged);
    try testing.expect(dead_plain);
    // A production-used symbol is not reported at all.
    try testing.expect(!found_prod);
}

// --- files / imports / importers -----------------------------------------

test "files json lists file, lang, and symbol count per indexed file" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.zig", .data =
        \\pub fn one() void {}
        \\pub fn two() void {}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try listFiles(&aw.writer, &idx, "", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
    const o = p.value.array.items[0].object;
    try testing.expect(std.mem.endsWith(u8, o.get("file").?.string, "f.zig"));
    try testing.expectEqualStrings("zig", o.get("lang").?.string);
    try testing.expect(o.get("symbols").?.integer >= 2);
}

test "imports and importers json describe the file dependency edges" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "core.zig", .data =
        \\pub fn shared() void {}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.zig", .data =
        \\const core = @import("core.zig");
        \\pub fn use() void { core.shared(); }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    { // imports: app.zig imports core.zig under the binding `core`.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try listImports(&aw.writer, &idx, "app.zig", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
        const o = p.value.array.items[0].object;
        try testing.expect(std.mem.endsWith(u8, o.get("file").?.string, "app.zig"));
        const imps = o.get("imports").?.array.items;
        try testing.expect(imps.len >= 1);
        try testing.expect(std.mem.endsWith(u8, imps[0].object.get("target").?.string, "core.zig"));
        try testing.expectEqualStrings("core", imps[0].object.get("binding").?.string);
    }
    { // importers: core.zig is imported by app.zig.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try listImporters(&aw.writer, &idx, "core.zig", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 1), p.value.array.items.len);
        const o = p.value.array.items[0].object;
        try testing.expect(std.mem.endsWith(u8, o.get("file").?.string, "core.zig"));
        const users = o.get("importers").?.array.items;
        try testing.expectEqual(@as(usize, 1), users.len);
        try testing.expect(std.mem.endsWith(u8, users[0].string, "app.zig"));
    }
}

// --- path -----------------------------------------------------------------

test "path json returns the chain of symbols and empties when none exists" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "p.zig", .data =
        \\pub fn dst() void {}
        \\pub fn src() void { dst(); }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    { // src → dst is one hop.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try shortestPath(&aw.writer, &idx, "src", "dst", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        const chain = p.value.array.items;
        try testing.expectEqual(@as(usize, 2), chain.len);
        try testing.expectEqualStrings("src", chain[0].object.get("name").?.string);
        try testing.expectEqualStrings("dst", chain[1].object.get("name").?.string);
    }
    { // dst → src has no call path → empty array.
        var aw = tjWriter();
        defer aw.deinit();
        _ = try shortestPath(&aw.writer, &idx, "dst", "src", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqual(@as(usize, 0), p.value.array.items.len);
    }
}

// --- modifiers ------------------------------------------------------------

test "json modifiers array carries static, classmethod, and abstract" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "mods.py", .data =
        \\class C:
        \\    @staticmethod
        \\    def s():
        \\        return 1
        \\    @classmethod
        \\    def c(cls):
        \\        return 2
        \\    @abstractmethod
        \\    def a(self):
        \\        ...
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    const M = struct {
        fn has(idxp: *const Index, name: []const u8, mod: []const u8) !bool {
            var aw = tjWriter();
            defer aw.deinit();
            _ = try showDef(&aw.writer, idxp, name, .{ .format = .json });
            var p = try tjParse(aw.written());
            defer p.deinit();
            const mods = p.value.array.items[0].object.get("modifiers") orelse return false;
            for (mods.array.items) |m| if (std.mem.eql(u8, m.string, mod)) return true;
            return false;
        }
    };
    try testing.expect(try M.has(&idx, "s", "static"));
    try testing.expect(try M.has(&idx, "c", "classmethod"));
    try testing.expect(try M.has(&idx, "a", "abstract"));
    // The base kind is unaffected by the modifier annotation.
    {
        var aw = tjWriter();
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "s", .{ .format = .json });
        var p = try tjParse(aw.written());
        defer p.deinit();
        try testing.expectEqualStrings("method", p.value.array.items[0].object.get("kind").?.string);
    }
}

// --- full-body verbosity escaping -----------------------------------------

test "def json at full verbosity embeds an escaped body and stays well-formed" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "q.zig", .data =
        \\pub fn quoter() []const u8 {
        \\    return "he said \"hi\"";
        \\}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try showDef(&aw.writer, &idx, "quoter", .{ .format = .json, .verbosity = .full });
    const out = aw.written();
    var p = try tjParse(out);
    defer p.deinit();
    const o = p.value.array.items[0].object;
    // The body round-trips through the JSON parser: its literal quote characters
    // survive intact, proving writeString's escaping was reversible.
    const body = o.get("body").?.string;
    try testing.expect(std.mem.indexOf(u8, body, "he said") != null);
    try testing.expect(std.mem.indexOfScalar(u8, body, '"') != null);
    // The raw JSON escaped the interior quote as \" (a backslash then a quote).
    try testing.expect(std.mem.indexOf(u8, out, "\\\"hi") != null);
    try testing.expect(balancedBrackets(out));
}
