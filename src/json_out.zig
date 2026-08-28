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

pub fn outlineJsonl(w: *Writer, idx: *const Index, path_filter: []const u8, opts: Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var ids: std.ArrayList(SymbolId) = .empty;
    defer ids.deinit(idx.gpa);
    for (idx.graph.symbols) |sym| {
        const file = idx.graph.files[sym.file];
        if (!query.matchesFilter(file.path, path_filter)) continue;
        if (opts.no_recurse and !query.inDirNonRecursive(file.path, path_filter)) continue;
        if (sym.kind == .import or (!sym.kind.isTopLevelInteresting() and sym.parent == invalid)) continue;
        if (!query.kindAllowed(sym.kind, opts.kinds) or !query.visAllowed(sym, opts.visibility)) continue;
        if (!query.inTestScope(opts.tests, query.isTestSymbol(idx, sym))) continue;
        try ids.append(idx.gpa, sym.id);
    }
    var page = JsonlPage{ .after = opts.after, .limit = opts.limit };
    for (ids.items, 0..) |id, ordinal| {
        if (!page.accepts(@intCast(ordinal))) continue;
        try jsonlHead(w, page.last);
        try symbolObject(w, idx, idx.graph.symbols[id], opts.verbosity);
        try w.writeAll("}\n");
    }
    try jsonlFinish(w, page, ids.items.len);
    return page.emitted != 0;
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
pub fn rankedDefinitions(w: *Writer, idx: *const Index, ranked: []const query.RankedSym, opts: Options) !bool {
    std.debug.assert(opts.sort != .default);
    std.debug.assert(ranked.len <= idx.graph.symbols.len);
    const shown: usize = @min(ranked.len, opts.limit);
    try w.writeByte('[');
    for (ranked[0..shown], 0..) |entry, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"sort\":\"{s}\",\"rank\":{d},\"symbol\":", .{ @tagName(opts.sort), entry.metric });
        try symbolObject(w, idx, idx.graph.symbols[entry.id], opts.verbosity);
        try w.writeByte('}');
    }
    try w.writeAll("]\n");
    return shown > 0;
}

const JsonlPage = struct {
    after: u32,
    limit: u32,
    emitted: u32 = 0,
    last: u32 = 0,

    fn accepts(self: *JsonlPage, ordinal: u32) bool {
        std.debug.assert(self.limit > 0);
        std.debug.assert(ordinal < std.math.maxInt(u32));
        if (ordinal < self.after or self.emitted >= self.limit) return false;
        self.emitted += 1;
        self.last = ordinal + 1;
        return true;
    }
};

fn jsonlHead(w: *Writer, cursor: u32) !void {
    std.debug.assert(cursor > 0);
    std.debug.assert(cursor <= std.math.maxInt(u32));
    try w.print("{{\"cursor\":\"v1:{}\",\"item\":", .{cursor});
}

fn jsonlFinish(w: *Writer, page: JsonlPage, total: usize) !void {
    std.debug.assert(page.limit > 0);
    std.debug.assert(total <= std.math.maxInt(u32));
    const consumed = if (page.emitted == 0) page.after else page.last;
    const has_more = consumed < total;
    try w.print("{{\"page\":{{\"count\":{},\"total\":{},\"has_more\":{},\"next\":", .{ page.emitted, total, has_more });
    if (has_more) try w.print("\"v1:{}\"", .{consumed}) else try w.writeAll("null");
    try w.writeAll("}}\n");
}

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

pub fn searchJsonl(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(opts.limit > 0);
    var ids: std.ArrayList(SymbolId) = .empty;
    defer ids.deinit(idx.gpa);
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import or !query.kindAllowed(sym.kind, opts.kinds)) continue;
        if (!query.visAllowed(sym, opts.visibility)) continue;
        if (!query.inTestScope(opts.tests, query.isTestSymbol(idx, sym))) continue;
        if (opts.exact and !std.mem.eql(u8, sym.name, pattern)) continue;
        if (!opts.exact and !query.matchesName(pattern, sym.name)) continue;
        try ids.append(idx.gpa, sym.id);
    }
    var page = JsonlPage{ .after = opts.after, .limit = opts.limit };
    for (ids.items, 0..) |id, ordinal| {
        if (!page.accepts(@intCast(ordinal))) continue;
        try jsonlHead(w, page.last);
        try symbolObject(w, idx, idx.graph.symbols[id], opts.verbosity);
        try w.writeAll("}\n");
    }
    try jsonlFinish(w, page, ids.items.len);
    return page.emitted != 0;
}

pub fn rankedDefinitionsJsonl(w: *Writer, idx: *const Index, ranked: []const query.RankedSym, opts: Options) !bool {
    std.debug.assert(opts.sort != .default);
    std.debug.assert(opts.limit > 0);
    var page = JsonlPage{ .after = opts.after, .limit = opts.limit };
    for (ranked, 0..) |entry, ordinal| {
        if (!page.accepts(@intCast(ordinal))) continue;
        try jsonlHead(w, page.last);
        try w.print("{{\"sort\":\"{s}\",\"rank\":{},\"symbol\":", .{ @tagName(opts.sort), entry.metric });
        try symbolObject(w, idx, idx.graph.symbols[entry.id], opts.verbosity);
        try w.writeAll("}}\n");
    }
    try jsonlFinish(w, page, ranked.len);
    return page.emitted != 0;
}

/// `search --refs --json`: array of `{name, file, line, in, qualifier?, target?}`
/// reference objects (use sites), mirroring the text usages listing. Returns
/// whether any reference matched.
pub fn collisions(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const ids = try query.collectCollisionSymbols(idx, pattern, opts);
    defer idx.gpa.free(ids);
    var groups: u32 = 0;
    var i: usize = 0;
    try w.writeByte('[');
    while (i < ids.len and groups < opts.limit) {
        var end = i + 1;
        const name = idx.graph.symbols[ids[i]].name;
        while (end < ids.len and std.mem.eql(u8, idx.graph.symbols[ids[end]].name, name)) end += 1;
        if (end - i > 1) {
            if (groups != 0) try w.writeByte(',');
            groups += 1;
            try w.writeAll("{\"name\":");
            try writeString(w, name);
            try w.print(",\"count\":{d},\"definitions\":[", .{end - i});
            for (ids[i..end], 0..) |id, member_i| {
                if (member_i != 0) try w.writeByte(',');
                try symbolObject(w, idx, idx.graph.symbols[id], opts.verbosity);
            }
            try w.writeAll("]}");
        }
        i = end;
    }
    try w.writeAll("]\n");
    return groups > 0;
}

pub fn rankedSearchRefs(w: *Writer, idx: *const Index, sites: []const query.RankedRefSite, opts: Options) !bool {
    std.debug.assert(opts.sort != .default and opts.sort != .line);
    std.debug.assert(sites.len <= opts.limit or opts.limit > 0);
    const shown: usize = @min(sites.len, opts.limit);
    try w.writeByte('[');
    for (sites[0..shown], 0..) |site, i| {
        if (i != 0) try w.writeByte(',');
        const owner = idx.graph.symbols[site.owner];
        try w.print("{{\"sort\":\"{s}\",\"rank\":{d},\"reference\":", .{ @tagName(opts.sort), site.metric });
        try refObject(w, idx, owner, owner.refs[site.ref_index], site.line);
        try w.writeByte('}');
    }
    try w.writeAll("]\n");
    return shown > 0;
}

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
            if (!pat.matches(ref) or !query.refSelected(idx, sym, ref, opts)) continue;
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

const FlatRef = struct { owner: SymbolId, ref_index: u32, line: u32 };

pub fn searchRefsJsonl(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(opts.limit > 0);
    var pat = query.RefPattern.parse(pattern);
    pat.exact = opts.exact;
    var sites: std.ArrayList(FlatRef) = .empty;
    defer sites.deinit(idx.gpa);
    for (idx.graph.symbols) |owner| {
        if (!query.inTestScope(opts.tests, query.isTestSymbol(idx, owner))) continue;
        for (owner.refs, 0..) |ref, ref_index| {
            if (!pat.matches(ref) or !query.refSelected(idx, owner, ref, opts)) continue;
            if (ref.lines.len > 1) {
                for (ref.lines) |line| try sites.append(idx.gpa, .{ .owner = owner.id, .ref_index = @intCast(ref_index), .line = line });
            } else try sites.append(idx.gpa, .{ .owner = owner.id, .ref_index = @intCast(ref_index), .line = ref.line });
        }
    }
    var page = JsonlPage{ .after = opts.after, .limit = opts.limit };
    for (sites.items, 0..) |site, ordinal| {
        if (!page.accepts(@intCast(ordinal))) continue;
        const owner = idx.graph.symbols[site.owner];
        try jsonlHead(w, page.last);
        try refObject(w, idx, owner, owner.refs[site.ref_index], site.line);
        try w.writeAll("}\n");
    }
    try jsonlFinish(w, page, sites.items.len);
    return page.emitted != 0;
}

pub fn rankedSearchRefsJsonl(w: *Writer, idx: *const Index, sites: []const query.RankedRefSite, opts: Options) !bool {
    std.debug.assert(opts.sort != .default and opts.sort != .line);
    std.debug.assert(opts.limit > 0);
    var page = JsonlPage{ .after = opts.after, .limit = opts.limit };
    for (sites, 0..) |site, ordinal| {
        if (!page.accepts(@intCast(ordinal))) continue;
        const owner = idx.graph.symbols[site.owner];
        try jsonlHead(w, page.last);
        try w.print("{{\"sort\":\"{s}\",\"rank\":{},\"reference\":", .{ @tagName(opts.sort), site.metric });
        try refObject(w, idx, owner, owner.refs[site.ref_index], site.line);
        try w.writeAll("}}\n");
    }
    try jsonlFinish(w, page, sites.len);
    return page.emitted != 0;
}

fn refObject(w: *Writer, idx: *const Index, sym: Symbol, ref: model.Reference, line: u32) !void {
    try w.writeAll("{\"name\":");
    try writeString(w, ref.name);
    try w.writeAll(",\"file\":");
    try writeString(w, idx.graph.files[sym.file].path);
    try w.print(",\"line\":{d},\"mode\":\"{s}\",\"in\":", .{ line, if (ref.write) "write" else "read" });
    try writeString(w, sym.name);
    if (ref.qualifier.len != 0) {
        try w.writeAll(",\"qualifier\":");
        try writeString(w, ref.qualifier);
    }
    try writeResolutionFields(w, ref);
    if (ref.target != invalid) {
        try w.writeAll(",\"target\":");
        try writeString(w, idx.graph.files[idx.graph.symbols[ref.target].file].path);
        try w.print(",\"exact\":{}", .{ref.exact});
    } else if (query.referenceIsLocal(sym, ref)) {
        try w.writeAll(",\"resolved\":false,\"resolution\":\"local\"");
    } else if (query.referenceNeedsDiagnostic(sym, ref)) {
        const class = query.referenceDiagnosticClass(idx, sym, ref).?;
        try w.writeAll(",\"resolved\":false,\"resolution\":");
        try writeString(w, @tagName(class));
        try w.writeAll(",\"diagnostic\":\"unresolved_reference\"");
    } else {
        try w.writeAll(",\"resolved\":false,\"resolution\":\"external_or_unmodeled\"");
    }
    try writeParseHealthField(w, "owner_parse_health", idx.graph.files[sym.file].parse_health);
    try w.writeByte('}');
}

fn writeResolutionFields(w: *Writer, ref: model.Reference) !void {
    try w.writeAll(",\"resolution_status\":");
    try writeString(w, @tagName(ref.resolution_status));
    try w.writeAll(",\"resolution_reason\":");
    try writeString(w, @tagName(ref.resolution_reason));
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

const JsonBudget = struct {
    nodes: u32 = 0,
    estimated_bytes: u32 = 0,
    pruned: u32 = 0,

    fn take(self: *JsonBudget, idx: *const Index, id: SymbolId, opts: Options) bool {
        std.debug.assert(id < idx.graph.symbols.len);
        std.debug.assert(opts.limit > 0);
        const sym = idx.graph.symbols[id];
        const estimate: u32 = @intCast(@min(@as(usize, std.math.maxInt(u32)), 64 + sym.name.len + idx.graph.files[sym.file].path.len));
        if (self.nodes >= opts.limit or
            (opts.max_nodes != 0 and self.nodes >= opts.max_nodes) or
            (opts.budget != 0 and self.nodes != 0 and self.estimated_bytes + estimate > opts.budget))
        {
            self.pruned +|= 1;
            return false;
        }
        self.nodes +|= 1;
        self.estimated_bytes +|= estimate;
        return true;
    }
};

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
    var budget: JsonBudget = .{};
    var roots_written: u32 = 0;
    for (ids) |id| {
        if (!budget.take(idx, id, opts)) continue;
        if (roots_written != 0) try w.writeByte(',');
        roots_written += 1;
        visited.clearRetainingCapacity();
        try walkNode(w, idx, if (impl_graph) |*g| g else null, id, incoming, opts, 0, 0, 1, &.{}, true, null, false, &visited, &budget);
    }
    if (budget.pruned != 0) {
        if (roots_written != 0) try w.writeByte(',');
        try w.print("{{\"truncated\":true,\"pruned\":{},\"nodes\":{}}}", .{ budget.pruned, budget.nodes });
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
    edge_ref: ?model.Reference,
    implementation_edge: bool,
    visited: *std.AutoHashMap(SymbolId, void),
    budget: *JsonBudget,
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
    if (edge_ref) |ref| try writeResolutionFields(w, ref);
    if (implementation_edge) try w.writeAll(",\"edge\":\"impl\"");
    if (depth >= opts.depth) {
        if (impl_graph) |graph| try implLeafArray(w, idx, graph, id, incoming, opts.strict, opts, budget);
        return try w.writeByte('}');
    }
    if ((try visited.getOrPut(id)).found_existing) {
        try w.writeAll(",\"recursion\":true}");
        return;
    }
    if (incoming) {
        try walkCallers(w, idx, impl_graph, id, opts, depth, visited, budget);
    } else {
        try walkCallees(w, idx, impl_graph, id, opts, depth, visited, budget);
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
    budget: *JsonBudget,
) !void {
    const sym = idx.graph.symbols[id];
    try w.writeAll(",\"callees\":[");
    var wrote: u32 = 0;
    var ext: u32 = 0;
    var ordered_refs: ?[]model.Reference = null;
    defer if (ordered_refs) |refs| idx.gpa.free(refs);
    if (query.compactEnabled(opts)) ordered_refs = try query.orderedRefs(idx.gpa, idx, sym.refs);
    const refs = ordered_refs orelse sym.refs;
    for (refs) |ref| {
        // Every resolved edge is a callee; bare var/const/field reads are hidden
        // unless `--refs` is set (see query.isDataReadEdge). Only unresolved
        // *calls* become externals (see query.walkCallees).
        if (ref.target != invalid and (!opts.strict or ref.exact)) {
            if (!opts.refs and query.isDataReadEdge(idx, ref)) continue;
            if (!budget.take(idx, ref.target, opts)) continue;
            if (wrote != 0) try w.writeByte(',');
            try walkNode(w, idx, impl_graph, ref.target, false, opts, depth + 1, ref.line, ref.count, ref.lines, ref.exact, ref, false, visited, budget);
            wrote += 1;
        } else if (ref.target == invalid and (ref.kind == .call or ref.kind == .route_call)) {
            ext += 1;
        }
    }
    if (impl_graph) |graph| {
        for (graph.edges) |edge| {
            if (edge.port_method != id or (opts.strict and !edge.exact)) continue;
            if (!budget.take(idx, edge.implementation_method, opts)) continue;
            if (wrote != 0) try w.writeByte(',');
            try walkNode(w, idx, impl_graph, edge.implementation_method, false, opts, depth + 1, 0, 1, &.{}, edge.exact, null, true, visited, budget);
            wrote += 1;
        }
    }
    try w.writeByte(']');
    if (ext != 0) try writeExternals(w, sym);
}

fn implLeafArray(w: *Writer, idx: *const Index, graph: *const impls_mod.Graph, id: SymbolId, incoming: bool, strict: bool, opts: Options, budget: *JsonBudget) !void {
    var first = true;
    for (graph.edges) |edge| {
        if (strict and !edge.exact) continue;
        var target: SymbolId = invalid;
        if (edge.port_method == id) target = edge.implementation_method;
        if (incoming and edge.implementation_method == id) target = edge.port_method;
        if (target == invalid or !budget.take(idx, target, opts)) continue;
        if (first) try w.writeAll(",\"implementations\":[") else try w.writeByte(',');
        first = false;
        try nodeHead(w, idx, idx.graph.symbols[target]);
        try w.writeAll(",\"edge\":\"impl\"");
        if (!edge.exact) try w.writeAll(",\"exact\":false");
        try w.writeByte('}');
    }
    if (!first) try w.writeByte(']');
}

fn writeExternals(w: *Writer, sym: Symbol) !void {
    try w.writeAll(",\"ext\":[");
    var wrote: u32 = 0;
    for (sym.refs) |ref| {
        if (ref.kind != .call and ref.kind != .route_call) continue;
        if (ref.target != invalid) continue;
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
    budget: *JsonBudget,
) !void {
    try w.writeAll(",\"callers\":[");
    var wrote: u32 = 0;
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    var ordered_callers: ?[]SymbolId = null;
    defer if (ordered_callers) |callers_slice| idx.gpa.free(callers_slice);
    if (query.compactEnabled(opts)) ordered_callers = try query.orderedCallers(idx.gpa, idx, idx.callersOf(id));
    const callers_slice = ordered_callers orelse idx.callersOf(id);
    for (callers_slice) |cid| {
        if (opts.strict and !query.hasExactEdge(idx, cid, id)) continue;
        if (!query.inTestScope(opts.tests, query.isTestSymbol(idx, idx.graph.symbols[cid]))) continue;
        if (!budget.take(idx, cid, opts)) continue;
        if (wrote != 0) try w.writeByte(',');
        try query.callSiteLines(idx, cid, id, &lines);
        const edge_ref = referenceTo(idx, cid, id);
        try walkNode(w, idx, impl_graph, cid, true, opts, depth + 1, query.callSiteLine(idx, cid, id), query.callSiteCount(idx, cid, id), lines.items, query.hasExactEdge(idx, cid, id), edge_ref, false, visited, budget);
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
            if (!budget.take(idx, target, opts)) continue;
            if (wrote != 0) try w.writeByte(',');
            try walkNode(w, idx, impl_graph, target, true, opts, depth + 1, 0, 1, &.{}, edge.exact, null, true, visited, budget);
            wrote += 1;
        }
    }
    try w.writeByte(']');
}

/// The representative reference behind a reverse edge. Prefer an exact site so
/// its provenance agrees with the compatibility semantics of `hasExactEdge`.
fn referenceTo(idx: *const Index, owner: SymbolId, target: SymbolId) ?model.Reference {
    var first: ?model.Reference = null;
    for (idx.graph.symbols[owner].refs) |ref| {
        if (ref.target != target) continue;
        if (ref.exact) return ref;
        if (first == null) first = ref;
    }
    return first;
}

/// Hot: array of `{...symbol, fan_in, fan_in_exact, fan_in_test, fan_out, fan_out_exact}`
/// ranked by connectivity. `*_exact` exclude heuristic `?` edges; `fan_in_test`
/// is the share of callers in test files; `--strict` drops entries whose
/// connectivity is entirely heuristic.
pub fn flow(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !bool {
    std.debug.assert(name.len > 0);
    if (idx.graph.symbols.len == 0) return flowMissing(w, idx, name, opts);
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const ids = query.resolveIds(idx, name, storage);
    if (ids.len == 0) return flowMissing(w, idx, name, opts);
    if (opts.flow_to.len != 0) return flowPath(w, idx, name, ids, opts);
    const totals = query.flowCounts(idx, ids, opts);
    try w.writeAll("{\"symbol\":");
    try nodeHead(w, idx, idx.graph.symbols[ids[0]]);
    try w.writeByte('}');
    if (ids.len > 1) try flowCandidates(w, idx, ids);
    try w.writeAll(",\"producers\":[");
    var emitted: FlowEmitState = .{};
    try flowInitializerSites(w, idx, ids, opts, &emitted);
    try flowSites(w, idx, ids, opts, true, &emitted);
    try w.writeAll("],\"consumers\":[");
    try flowSites(w, idx, ids, opts, false, &emitted);
    if (!opts.writers and !opts.unread) try typeConsumerSites(w, idx, ids, opts, &emitted);
    const total = totals.producers + totals.consumers;
    try w.print("],\"counts\":{{\"producers\":{d},\"consumers\":{d}}},", .{ totals.producers, totals.consumers });
    try w.print("\"emitted\":{{\"producers\":{d},\"consumers\":{d}}},\"truncated\":{s}}}\n", .{
        emitted.producers, emitted.consumers, if (emitted.shown < total) "true" else "false",
    });
    return total > 0;
}

fn flowMissing(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(opts.limit > 0);
    if (opts.flow_to.len == 0) {
        try w.writeAll("{\"match_count\":0,\"candidates\":[],\"producers\":[],\"consumers\":[],");
        try w.writeAll("\"counts\":{\"producers\":0,\"consumers\":0},\"emitted\":{\"producers\":0,\"consumers\":0},\"truncated\":false}\n");
        return false;
    }
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const sinks: []const SymbolId = if (storage.len == 0) &.{} else query.resolveIds(idx, opts.flow_to, storage);
    try w.writeAll("{\"source\":");
    try flowEndpoint(w, idx, name, &.{});
    try w.writeAll(",\"sink\":");
    try flowEndpoint(w, idx, opts.flow_to, sinks);
    try w.writeAll(",\"path\":[]}\n");
    return false;
}

fn flowPath(w: *Writer, idx: *const Index, name: []const u8, ids: []const SymbolId, opts: Options) !bool {
    std.debug.assert(ids.len > 0);
    std.debug.assert(opts.flow_to.len > 0);
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const sinks = query.resolveIds(idx, opts.flow_to, storage);
    const chain = if (sinks.len == 0)
        try idx.gpa.alloc(SymbolId, 0)
    else
        try query.flowPathBetweenIds(idx, ids, sinks, opts);
    defer idx.gpa.free(chain);
    try w.writeAll("{\"source\":");
    try flowEndpoint(w, idx, name, ids);
    try w.writeAll(",\"sink\":");
    try flowEndpoint(w, idx, opts.flow_to, sinks);
    try w.writeAll(",\"path\":[");
    for (chain, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[id]);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
    return chain.len > 0;
}

fn flowEndpoint(w: *Writer, idx: *const Index, selector: []const u8, ids: []const SymbolId) !void {
    std.debug.assert(selector.len > 0);
    std.debug.assert(ids.len <= idx.graph.symbols.len);
    try w.writeAll("{\"selector\":");
    try writeString(w, selector);
    try w.print(",\"match_count\":{d},\"candidates\":[", .{ids.len});
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[id]);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn flowCandidates(w: *Writer, idx: *const Index, ids: []const SymbolId) !void {
    std.debug.assert(ids.len > 1);
    std.debug.assert(ids[0] < idx.graph.symbols.len);
    try w.print(",\"match_count\":{d},\"candidates\":[", .{ids.len});
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[id]);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

const FlowEmitState = struct { shown: u32 = 0, producers: u32 = 0, consumers: u32 = 0 };

fn flowInitializerSites(w: *Writer, idx: *const Index, ids: []const SymbolId, opts: Options, state: *FlowEmitState) !void {
    std.debug.assert(ids.len > 0);
    std.debug.assert(state.shown == state.producers + state.consumers);
    for (ids) |id| {
        if (state.shown >= opts.limit) return;
        if (!query.flowInitializerSelected(idx, id, opts)) continue;
        if (state.producers != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[id]);
        try w.writeAll(",\"mode\":\"initializer\"}");
        state.producers += 1;
        state.shown += 1;
    }
}

fn flowSites(w: *Writer, idx: *const Index, ids: []const SymbolId, opts: Options, write: bool, state: *FlowEmitState) !void {
    std.debug.assert(ids.len > 0);
    std.debug.assert(state.shown == state.producers + state.consumers);
    const group_count = if (write) &state.producers else &state.consumers;
    for (idx.graph.symbols) |owner| for (owner.refs) |ref| {
        const producer = query.flowProducer(idx, ids, ref);
        if (producer != write or !idIn(ids, ref.target) or !query.flowRefSelected(idx, owner, ref, producer, opts)) continue;
        const lines = if (ref.lines.len > 1) ref.lines else &[_]u32{ref.line};
        for (lines) |line| {
            if (state.shown >= opts.limit) return;
            if (group_count.* != 0) try w.writeByte(',');
            var directed = ref;
            directed.write = write;
            try refObject(w, idx, owner, directed, line);
            group_count.* += 1;
            state.shown += 1;
        }
    };
}

fn typeConsumerSites(w: *Writer, idx: *const Index, ids: []const SymbolId, opts: Options, state: *FlowEmitState) !void {
    const target = query.flowTypeTarget(idx, ids) orelse return;
    std.debug.assert(target < idx.graph.symbols.len);
    std.debug.assert(state.shown == state.producers + state.consumers);
    for (idx.graph.symbols) |owner| {
        if (state.shown >= opts.limit) return;
        const consumer = query.typeConsumerBinding(idx, ids, owner) orelse continue;
        if (state.consumers != 0) try w.writeByte(',');
        const ref: model.Reference = .{
            .name = idx.graph.symbols[target].name,
            .qualifier = consumer.binding,
            .line = consumer.line,
            .kind = .type_use,
            .target = target,
            .exact = true,
            .resolution_status = .exact,
            .resolution_reason = .typed_receiver,
        };
        try refObject(w, idx, owner, ref, consumer.line);
        state.consumers += 1;
        state.shown += 1;
    }
}

fn idIn(ids: []const SymbolId, target: SymbolId) bool {
    for (ids) |id| if (id == target) return true;
    return false;
}

pub fn hot(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    const ranked = try query.collectHot(idx, filter, opts.tests);
    defer idx.gpa.free(ranked);
    query.sortHot(idx, ranked, opts.sort);
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
        const sort = if (opts.sort == .default) query.SortKey.fan_in_exact else opts.sort;
        try w.print(",\"fan_in\":{d},\"fan_in_exact\":{d},\"fan_in_test\":{d},\"fan_out\":{d},\"fan_out_exact\":{d},\"sort\":\"{s}\",\"rank\":{d}}}", .{
            e.fan_in, e.fan_in_exact, e.fan_in_test, e.fan_out, e.fan_out_exact, @tagName(sort), query.hotMetric(idx, e, sort),
        });
    }
    try w.writeAll("]\n");
    return shown > 0;
}

pub fn hotJsonl(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const ranked = try query.collectHot(idx, filter, opts.tests);
    defer idx.gpa.free(ranked);
    query.sortHot(idx, ranked, opts.sort);
    var total: usize = 0;
    for (ranked) |entry| {
        if (opts.strict and entry.fan_in_exact == 0 and entry.fan_out_exact == 0) continue;
        total += 1;
    }
    var page = JsonlPage{ .after = opts.after, .limit = opts.limit };
    var ordinal: u32 = 0;
    for (ranked) |entry| {
        if (opts.strict and entry.fan_in_exact == 0 and entry.fan_out_exact == 0) continue;
        defer ordinal += 1;
        if (!page.accepts(ordinal)) continue;
        const sort = if (opts.sort == .default) query.SortKey.fan_in_exact else opts.sort;
        try jsonlHead(w, page.last);
        try w.print("{{\"sort\":\"{s}\",\"rank\":{},\"symbol\":", .{ @tagName(sort), query.hotMetric(idx, entry, sort) });
        try symbolObject(w, idx, idx.graph.symbols[entry.id], opts.verbosity);
        try w.writeAll("}}\n");
    }
    try jsonlFinish(w, page, total);
    return page.emitted != 0;
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
    if (shown == 0 and try siblingConformanceObject(w, idx, ids, opts.limit)) shown = 1;
    try w.writeAll("]\n");
    return shown > 0;
}

fn siblingConformanceObject(w: *Writer, idx: *const Index, ids: []const SymbolId, limit: u32) !bool {
    std.debug.assert(ids.len <= idx.graph.symbols.len);
    std.debug.assert(limit > 0);
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
    var shown: u32 = 0;
    for (idx.graph.symbols) |expected| {
        if (shown >= limit) break;
        if (expected.kind != .method or !query.contains(parents[0..count], expected.parent)) continue;
        if (query.idsContainMethods(idx, ids) and !query.contains(ids, expected.id)) continue;
        if ((try names.getOrPut(expected.name)).found_existing) continue;
        if (!first) try w.writeByte(',');
        first = false;
        shown += 1;
        try siblingMemberObject(w, idx, parents[0..count], expected);
    }
    try w.writeAll("]}");
    return true;
}

fn siblingMemberObject(w: *Writer, idx: *const Index, parents: []const SymbolId, expected: Symbol) !void {
    std.debug.assert(expected.kind == .method);
    std.debug.assert(expected.parent != invalid);
    try w.writeAll("{\"expected\":");
    try symbolObject(w, idx, expected, .sig);
    try w.writeAll(",\"implementations\":[");
    var written: u32 = 0;
    for (parents) |parent| {
        if (parent == expected.parent) continue;
        if (written != 0) try w.writeByte(',');
        written += 1;
        const actual_id = impls_mod.methodOf(idx, parent, expected.name);
        const actual = if (actual_id) |id| idx.graph.symbols[id] else null;
        try w.writeAll("{\"parent\":");
        try symbolObject(w, idx, idx.graph.symbols[parent], .names);
        try w.writeAll(",\"verdict\":");
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

/// Diff: default output is an array of changed symbols and direct callers. With
/// `--exact-source`, the same semantic files are wrapped with post-image byte
/// ranges and the exact raw git patch (including deletions and non-symbol edits).
pub fn diff(
    w: *Writer,
    idx: *const Index,
    changes: []const gitdiff.FileChange,
    patch: []const u8,
    opts: Options,
) !bool {
    if (opts.exact_source) try w.writeAll("{\"files\":");
    const any_symbol = try writeDiffFiles(w, idx, changes, opts);
    if (opts.exact_source) {
        try w.writeAll(",\"patch\":");
        try writeString(w, patch);
        try w.writeAll("}\n");
        return any_symbol or patch.len != 0;
    }
    try w.writeByte('\n');
    return any_symbol;
}

fn writeDiffFiles(w: *Writer, idx: *const Index, changes: []const gitdiff.FileChange, opts: Options) !bool {
    std.debug.assert(opts.limit > 0);
    var any_symbol = false;
    var first_file = true;
    var shown: u32 = 0;
    try w.writeByte('[');
    for (changes) |change| {
        const file = query.findDiffFile(idx, change.path) orelse continue;
        if (!opts.exact_source and !diffFileTouched(idx, file, change.ranges)) continue;
        if (!first_file) try w.writeByte(',');
        first_file = false;
        try w.writeAll("{\"file\":");
        try writeString(w, change.path);
        if (opts.exact_source) try writeChangedRanges(w, file, change.ranges);
        try w.writeAll(",\"symbols\":[");
        var first_symbol = true;
        var i = file.sym_start;
        while (i < file.sym_end and shown < opts.limit) : (i += 1) {
            const sym = idx.graph.symbols[i];
            if (sym.kind == .import or !query.symbolTouched(sym, file.text, change.ranges)) continue;
            if (!first_symbol) try w.writeByte(',');
            first_symbol = false;
            any_symbol = true;
            shown += 1;
            try writeDiffSymbol(w, idx, sym, opts.exact_source);
        }
        try w.writeAll("]}");
        if (shown >= opts.limit and !opts.exact_source) break;
    }
    try w.writeByte(']');
    return any_symbol;
}

fn diffFileTouched(idx: *const Index, file: model.SourceFile, ranges: []const gitdiff.Range) bool {
    std.debug.assert(file.sym_start <= file.sym_end);
    std.debug.assert(file.sym_end <= idx.graph.symbols.len);
    for (idx.graph.symbols[file.sym_start..file.sym_end]) |sym| {
        if (sym.kind != .import and query.symbolTouched(sym, file.text, ranges)) return true;
    }
    return false;
}

fn writeChangedRanges(w: *Writer, file: model.SourceFile, ranges: []const gitdiff.Range) !void {
    try w.writeAll(",\"changes\":[");
    for (ranges, 0..) |range, i| {
        if (i != 0) try w.writeByte(',');
        const mapped = query.sourceRange(file.text, range);
        try w.print("{{\"line\":{},\"line_end\":{},\"start\":{},\"end\":{},\"empty\":{},\"source\":", .{
            mapped.line, mapped.line_end, mapped.start, mapped.end, mapped.empty,
        });
        try writeString(w, mapped.text);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

fn writeDiffSymbol(w: *Writer, idx: *const Index, sym: Symbol, exact_source: bool) !void {
    std.debug.assert(sym.id < idx.graph.symbols.len);
    try nodeHead(w, idx, sym);
    try w.writeAll(",\"callers\":[");
    var seen = std.AutoHashMap(SymbolId, void).init(idx.gpa);
    defer seen.deinit();
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    var first = true;
    for (idx.callersOf(sym.id)) |cid| {
        std.debug.assert(cid < idx.graph.symbols.len);
        if ((try seen.getOrPut(cid)).found_existing) continue;
        if (!first) try w.writeByte(',');
        first = false;
        const caller = idx.graph.symbols[cid];
        if (!exact_source) {
            try symbolObject(w, idx, caller, .names);
            continue;
        }
        try query.callSiteLines(idx, cid, sym.id, &lines);
        std.debug.assert(lines.items.len > 0);
        try nodeHead(w, idx, caller);
        try w.print(",\"site\":{},\"site_count\":{}", .{ lines.items[0], query.callSiteCount(idx, cid, sym.id) });
        if (lines.items.len > 1) {
            try w.writeAll(",\"lines\":[");
            for (lines.items, 0..) |line, i| {
                if (i != 0) try w.writeByte(',');
                try w.print("{}", .{line});
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
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
    var budget: JsonBudget = .{};
    var roots_written: u32 = 0;
    for (ids) |id| {
        if (!budget.take(idx, id, opts)) continue;
        if (roots_written != 0) try w.writeByte(',');
        roots_written += 1;
        const sym = idx.graph.symbols[id];
        try nodeHead(w, idx, sym);
        try w.writeAll(",\"callees\":[");
        try calleeArray(w, idx, if (impl_graph) |*g| g else null, sym, opts, &budget);
        try w.writeAll("],\"callers\":[");
        var wrote: usize = 0;
        var ordered_callers: ?[]SymbolId = null;
        defer if (ordered_callers) |callers_slice| idx.gpa.free(callers_slice);
        if (query.compactEnabled(opts)) ordered_callers = try query.orderedCallers(idx.gpa, idx, idx.callersOf(id));
        const callers_slice = ordered_callers orelse idx.callersOf(id);
        for (callers_slice) |cid| {
            if (opts.strict and !query.hasExactEdge(idx, cid, id)) continue;
            if (!budget.take(idx, cid, opts)) continue;
            if (wrote != 0) try w.writeByte(',');
            try nodeHead(w, idx, idx.graph.symbols[cid]);
            const site = query.callSiteLine(idx, cid, id);
            if (site != 0) try w.print(",\"site\":{d}", .{site});
            if (!query.hasExactEdge(idx, cid, id)) try w.writeAll(",\"exact\":false");
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
                if (!budget.take(idx, target, opts)) continue;
                if (wrote != 0) try w.writeByte(',');
                try implNode(w, idx, target, edge.exact);
                wrote += 1;
            }
        }
        try w.writeAll("]}");
    }
    if (budget.pruned != 0) {
        if (roots_written != 0) try w.writeByte(',');
        try w.print("{{\"truncated\":true,\"pruned\":{},\"nodes\":{}}}", .{ budget.pruned, budget.nodes });
    }
    try w.writeAll("]\n");
    return budget.nodes != 0;
}

fn calleeArray(w: *Writer, idx: *const Index, graph: ?*const impls_mod.Graph, sym: Symbol, opts: Options, budget: *JsonBudget) !void {
    var wrote: u32 = 0;
    var ordered_refs: ?[]model.Reference = null;
    defer if (ordered_refs) |refs| idx.gpa.free(refs);
    if (query.compactEnabled(opts)) ordered_refs = try query.orderedRefs(idx.gpa, idx, sym.refs);
    const refs = ordered_refs orelse sym.refs;
    for (refs) |ref| {
        if (ref.target == invalid or (opts.strict and !ref.exact)) continue;
        if (!opts.refs and query.isDataReadEdge(idx, ref)) continue;
        if (!budget.take(idx, ref.target, opts)) continue;
        if (wrote != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[ref.target]);
        if (ref.line != 0) try w.print(",\"site\":{d}", .{ref.line});
        if (!ref.exact) try w.writeAll(",\"exact\":false");
        try writeResolutionFields(w, ref);
        try w.writeByte('}');
        wrote += 1;
    }
    if (graph) |impl_graph| {
        for (impl_graph.edges) |edge| {
            if (edge.port_method != sym.id or (opts.strict and !edge.exact)) continue;
            if (!budget.take(idx, edge.implementation_method, opts)) continue;
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

/// Default is the bounded summary (`statusCompact`); `--full` opts into the
/// item-level freshness/parse/resolution dump (eval finding 3: `-j` status
/// was ~3x the human format and cost 5.5k-16k tokens as an agent's first call).
pub fn status(
    w: *Writer,
    idx: *const Index,
    filter: []const u8,
    report: query.StatusReport,
    opts: Options,
) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(report.scope_files <= idx.graph.files.len);
    if (!opts.status_full) return statusCompact(w, idx, filter, report, opts);
    try w.writeAll("{\"root\":");
    try writeString(w, idx.root);
    try w.print(",\"snapshot\":{{\"files\":{},\"symbols\":{}}}", .{ idx.graph.files.len, idx.graph.symbols.len });
    try w.writeAll(",\"scope\":{\"filter\":");
    try writeString(w, filter);
    try w.print(",\"files\":{},\"symbols\":{}}}", .{ report.scope_files, report.scope_symbols });
    try writeLanguageBreakdown(w, idx, filter, opts);
    try writeBackendBreakdown(w, idx, filter, opts);
    try writeCacheSnapshot(w, idx);
    try writeFreshness(w, idx, report);
    try writeSkippedStatus(w, idx, filter, report);
    try writeParseStatus(w, idx, filter, report, opts);
    try writeUnresolvedStatus(w, idx, filter, report, opts);
    try w.writeAll("}\n");
    return true;
}

/// Bounded default: project counts, per-language/backend breakdown, cache
/// state, and headline counts only — no per-file/per-reference item arrays.
fn statusCompact(
    w: *Writer,
    idx: *const Index,
    filter: []const u8,
    report: query.StatusReport,
    opts: Options,
) !bool {
    try w.writeAll("{\"root\":");
    try writeString(w, idx.root);
    try w.print(",\"snapshot\":{{\"files\":{},\"symbols\":{}}}", .{ idx.graph.files.len, idx.graph.symbols.len });
    try w.writeAll(",\"scope\":{\"filter\":");
    try writeString(w, filter);
    try w.print(",\"files\":{},\"symbols\":{}}}", .{ report.scope_files, report.scope_symbols });
    try writeLanguageBreakdown(w, idx, filter, opts);
    try writeBackendBreakdown(w, idx, filter, opts);
    try writeCacheSnapshot(w, idx);
    const freshness_current = report.root_error.len == 0 and report.changes.len == 0;
    try w.print(",\"freshness\":{{\"current\":{},\"changed_files\":{}", .{ freshness_current, report.changes.len });
    if (report.root_error.len != 0) {
        try w.writeAll(",\"root_error\":");
        try writeString(w, report.root_error);
    }
    try w.writeByte('}');
    try w.print(",\"parse_health\":{{\"count\":{}}}", .{report.parse_warnings});
    try w.print(",\"unresolved_references\":{{\"count\":{},\"categories\":{{\"likely_local\":{},\"external_or_unmodeled\":{}}}}}", .{
        report.unresolved_refs, report.likely_local_refs, report.external_or_unmodeled_refs,
    });
    try w.print(",\"skipped\":{{\"count\":{}}}", .{report.skipped});
    try w.writeAll("}\n");
    return true;
}

fn writeLanguageBreakdown(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    const counts = query.statusLanguageCounts(idx, filter, opts);
    try w.writeAll(",\"languages\":{");
    var first = true;
    // Index by f.value (the enum's actual tag), not declaration ordinal —
    // counts is filled via @intFromEnum and the two diverge if a tag is pinned.
    inline for (@typeInfo(language.Language).@"enum".fields) |f| {
        if (counts[f.value] != 0) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{s}\":{d}", .{ (@as(language.Language, @enumFromInt(f.value))).tag(), counts[f.value] });
        }
    }
    try w.writeByte('}');
}

fn writeBackendBreakdown(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    const counts = query.statusBackendCounts(idx, filter, opts);
    try w.writeAll(",\"backend\":{");
    var first = true;
    inline for (@typeInfo(model.Backend).@"enum".fields) |f| {
        if (counts[f.value] != 0) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{s}\":{d}", .{ f.name, counts[f.value] });
        }
    }
    try w.writeByte('}');
}

/// Default (bounded) page is just the one summary row. `--full` pages the
/// item-level freshness/skipped/parse-health/unresolved-reference rows too
/// (eval finding 3: `--jsonl` status dumped every row regardless of scale).
pub fn statusJsonl(
    w: *Writer,
    idx: *const Index,
    filter: []const u8,
    report: query.StatusReport,
    opts: Options,
) !bool {
    std.debug.assert(opts.limit > 0);
    const item_total: usize = if (opts.status_full) report.changes.len + report.skipped + report.parse_warnings + report.unresolved_refs else 0;
    const total: usize = 1 + item_total;
    var page = JsonlPage{ .after = opts.after, .limit = opts.limit };
    var ordinal: u32 = 0;
    if (page.accepts(ordinal)) {
        try jsonlHead(w, page.last);
        try statusSummaryItem(w, idx, filter, report, opts);
        try w.writeAll("}\n");
    }
    ordinal += 1;
    if (opts.status_full) {
        for (report.changes) |change| {
            if (page.accepts(ordinal)) {
                try jsonlHead(w, page.last);
                try statusChangeObject(w, idx, change);
                try w.writeAll("}\n");
            }
            ordinal += 1;
        }
        for (idx.skipped_dirs) |path| {
            if (filter.len != 0 and !query.matchesFilter(path, filter)) continue;
            if (page.accepts(ordinal)) {
                try jsonlHead(w, page.last);
                try w.writeAll("{\"kind\":\"skipped\",\"path\":");
                try writeString(w, path);
                try w.writeAll("}}\n");
            }
            ordinal += 1;
        }
        ordinal = try statusJsonlHealth(w, idx, filter, opts, &page, ordinal);
        ordinal = try statusJsonlUnresolved(w, idx, filter, opts, &page, ordinal);
    }
    std.debug.assert(ordinal == total);
    try jsonlFinish(w, page, total);
    return page.emitted != 0;
}

fn statusSummaryItem(w: *Writer, idx: *const Index, filter: []const u8, report: query.StatusReport, opts: Options) !void {
    try w.writeAll("{\"kind\":\"summary\",\"root\":");
    try writeString(w, idx.root);
    try w.print(",\"files\":{},\"symbols\":{},\"scope_files\":{},\"scope_symbols\":{}", .{
        idx.graph.files.len, idx.graph.symbols.len, report.scope_files, report.scope_symbols,
    });
    if (filter.len != 0) {
        try w.writeAll(",\"filter\":");
        try writeString(w, filter);
    }
    try writeLanguageBreakdown(w, idx, filter, opts);
    try writeBackendBreakdown(w, idx, filter, opts);
    try writeCacheSnapshot(w, idx);
    const freshness_current = report.root_error.len == 0 and report.changes.len == 0;
    try w.print(",\"freshness_current\":{},\"parse_warnings\":{},\"unresolved_references\":{},\"changed_files\":{},\"skipped\":{}", .{
        freshness_current, report.parse_warnings, report.unresolved_refs, report.changes.len, report.skipped,
    });
    if (report.root_error.len != 0) {
        try w.writeAll(",\"root_error\":");
        try writeString(w, report.root_error);
    }
    try w.writeByte('}');
}

fn writeCacheSnapshot(w: *Writer, idx: *const Index) !void {
    const state = idx.cache_snapshot;
    try w.print(",\"cache\":{{\"enabled\":{},\"loaded\":{},\"loaded_entries\":{},\"hits\":{},\"rewrite\":\"{s}\"}}", .{
        state.enabled, state.loaded, state.loaded_entries, state.hits, @tagName(state.rewrite),
    });
}

fn writeFreshness(w: *Writer, idx: *const Index, report: query.StatusReport) !void {
    const current = report.root_error.len == 0 and report.changes.len == 0;
    try w.print(",\"freshness\":{{\"current\":{},\"changes\":[", .{current});
    for (report.changes, 0..) |change, i| {
        if (i != 0) try w.writeByte(',');
        try statusChangeObject(w, idx, change);
    }
    try w.writeByte(']');
    if (report.root_error.len != 0) {
        try w.writeAll(",\"root_error\":");
        try writeString(w, report.root_error);
    }
    try w.writeByte('}');
}

fn statusChangeObject(w: *Writer, idx: *const Index, change: query.StatusChange) !void {
    std.debug.assert(change.file < idx.graph.files.len);
    try w.writeAll("{\"kind\":\"freshness\",\"file\":");
    try writeString(w, idx.graph.files[change.file].path);
    try w.print(",\"state\":\"{s}\"", .{@tagName(change.kind)});
    if (change.error_name.len != 0) {
        try w.writeAll(",\"error\":");
        try writeString(w, change.error_name);
    }
    try w.writeByte('}');
}

fn writeSkippedStatus(w: *Writer, idx: *const Index, filter: []const u8, report: query.StatusReport) !void {
    try w.print(",\"skipped\":{{\"count\":{},\"paths\":[", .{report.skipped});
    var first = true;
    for (idx.skipped_dirs) |path| {
        if (filter.len != 0 and !query.matchesFilter(path, filter)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try writeString(w, path);
    }
    try w.writeAll("]}");
}

fn writeParseStatus(w: *Writer, idx: *const Index, filter: []const u8, report: query.StatusReport, opts: Options) !void {
    try w.print(",\"parse_health\":{{\"count\":{},\"items\":[", .{report.parse_warnings});
    var first = true;
    for (idx.graph.files) |file| {
        if (!query.statusFileSelected(file, filter, opts) or !file.parse_health.hasDiagnostic()) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try parseHealthObject(w, file);
    }
    try w.writeAll("]}");
}

fn writeUnresolvedStatus(
    w: *Writer,
    idx: *const Index,
    filter: []const u8,
    report: query.StatusReport,
    opts: Options,
) !void {
    try w.print(",\"unresolved_references\":{{\"count\":{},\"scope\":\"call_type_import_edges\",\"categories\":{{\"likely_local\":{},\"external_or_unmodeled\":{}}},\"items\":[", .{
        report.unresolved_refs,
        report.likely_local_refs,
        report.external_or_unmodeled_refs,
    });
    var shown: u32 = 0;
    inline for (.{ query.ReferenceDiagnosticClass.likely_local, query.ReferenceDiagnosticClass.external_or_unmodeled }) |wanted| {
        outer: for (idx.graph.symbols) |sym| {
            const file = idx.graph.files[sym.file];
            if (!query.statusFileSelected(file, filter, opts)) continue;
            for (sym.refs) |ref| {
                if (query.referenceDiagnosticClass(idx, sym, ref) != wanted) continue;
                if (shown != 0) try w.writeByte(',');
                try unresolvedObject(w, idx, sym, ref);
                shown += 1;
                if (shown >= opts.limit) break :outer;
            }
        }
        if (shown >= opts.limit) break;
    }
    try w.print("],\"shown\":{},\"truncated\":{}}}", .{ shown, shown < report.unresolved_refs });
}

fn statusJsonlHealth(w: *Writer, idx: *const Index, filter: []const u8, opts: Options, page: *JsonlPage, start: u32) !u32 {
    var ordinal = start;
    for (idx.graph.files) |file| {
        if (!query.statusFileSelected(file, filter, opts) or !file.parse_health.hasDiagnostic()) continue;
        if (page.accepts(ordinal)) {
            try jsonlHead(w, page.last);
            try parseHealthObject(w, file);
            try w.writeAll("}\n");
        }
        ordinal += 1;
    }
    return ordinal;
}

fn statusJsonlUnresolved(w: *Writer, idx: *const Index, filter: []const u8, opts: Options, page: *JsonlPage, start: u32) !u32 {
    var ordinal = start;
    inline for (.{ query.ReferenceDiagnosticClass.likely_local, query.ReferenceDiagnosticClass.external_or_unmodeled }) |wanted| {
        for (idx.graph.symbols) |sym| {
            const file = idx.graph.files[sym.file];
            if (!query.statusFileSelected(file, filter, opts)) continue;
            for (sym.refs) |ref| {
                if (query.referenceDiagnosticClass(idx, sym, ref) != wanted) continue;
                if (page.accepts(ordinal)) {
                    try jsonlHead(w, page.last);
                    try unresolvedObject(w, idx, sym, ref);
                    try w.writeAll("}\n");
                }
                ordinal += 1;
            }
        }
    }
    return ordinal;
}

fn parseHealthObject(w: *Writer, file: model.SourceFile) !void {
    std.debug.assert(file.parse_health.hasDiagnostic());
    try w.writeAll("{\"kind\":\"parse_health\",\"file\":");
    try writeString(w, file.path);
    if (file.parse_health.desync_from) |from| {
        std.debug.assert(file.parse_health.desync_to >= from);
        try w.print(",\"diagnostic\":\"tokenizer_desync\",\"from_line\":{},\"to_line\":{}", .{ from, file.parse_health.desync_to });
    }
    // F5: a silent tree-sitter -> heuristic substitution used to be invisible
    // on every structured surface — stderr-only, per coldstart F13.
    if (file.parse_health.tree_sitter_fallback) try w.writeAll(",\"tree_sitter_fallback\":true");
    try w.writeAll("}");
}

fn unresolvedObject(w: *Writer, idx: *const Index, sym: Symbol, ref: model.Reference) !void {
    const file = idx.graph.files[sym.file];
    const class = query.referenceDiagnosticClass(idx, sym, ref).?;
    try w.writeAll("{\"kind\":\"unresolved_reference\",\"resolution\":");
    try writeString(w, @tagName(class));
    try w.writeAll(",\"name\":");
    try writeString(w, ref.name);
    try w.print(",\"reference_kind\":\"{s}\",\"mode\":\"{s}\",\"file\":", .{ @tagName(ref.kind), if (ref.write) "write" else "read" });
    try writeString(w, file.path);
    try w.print(",\"line\":{},\"in\":", .{ref.line});
    try writeString(w, sym.name);
    if (ref.qualifier.len != 0) {
        try w.writeAll(",\"qualifier\":");
        try writeString(w, ref.qualifier);
    }
    if (!file.parse_health.reliable()) try w.writeAll(",\"parse_unreliable\":true");
    try w.writeByte('}');
}

pub fn readError(w: *Writer, code: []const u8, message: []const u8, value: []const u8) !void {
    std.debug.assert(code.len > 0);
    std.debug.assert(message.len > 0);
    std.debug.assert(value.len > 0);
    try w.writeAll("{\"error\":");
    try writeString(w, code);
    try w.writeAll(",\"message\":");
    try writeString(w, message);
    try w.writeAll(",\"value\":");
    try writeString(w, value);
    try w.writeAll("}\n");
}

pub fn sourceLines(w: *Writer, path: []const u8, text: []const u8, ranges: []const query.LineRange, page: query.ReadPage) !bool {
    std.debug.assert(path.len > 0);
    for (ranges) |range| std.debug.assert(range.lo > 0 and range.hi >= range.lo);
    for (page.ranges) |range| std.debug.assert(range.lo > 0 and range.hi >= range.lo);
    const total = query.lineCount(text);
    try w.writeAll("{\"file\":");
    try writeString(w, path);
    try w.print(",\"total_lines\":{d},\"ranges\":[", .{total});
    for (ranges, 0..) |range, position| {
        if (position != 0) try w.writeByte(',');
        try w.print("{{\"start\":{d},\"end\":", .{range.lo});
        if (range.hi == std.math.maxInt(usize)) try w.writeAll("null") else try w.print("{d}", .{range.hi});
        try w.writeByte('}');
    }
    try w.print("],\"offset\":{d},\"limit\":{d},\"budget\":{d},\"estimated_bytes\":{d},\"selected\":{d},\"shown\":{d},\"truncated\":{s},\"next\":", .{
        page.offset,
        page.limit,
        page.budget,
        page.estimated_bytes,
        page.selected,
        page.shown,
        if (page.truncated) "true" else "false",
    });
    if (page.next) |next| {
        try w.print("\"v1:{d}\"", .{next});
    } else {
        try w.writeAll("null");
    }
    if (page.selected == 0) {
        for (ranges) |range| {
            if (range.lo <= total) continue;
            try w.print(",\"selection_error\":{{\"code\":\"no_such_line\",\"requested\":{d},\"total_lines\":{d}}}", .{ range.lo, total });
            break;
        }
    }
    try w.writeAll(",\"lines\":[");
    // `sourceLineObjects` historically treats an empty range list as "all
    // lines" for standalone callers. In a paged read, however, an empty page
    // means the requested selection was past EOF (or its cursor is exhausted),
    // never "expand to the whole file".
    const emitted = if (page.ranges.len == 0) 0 else try sourceLineObjects(w, text, page.ranges);
    std.debug.assert(emitted == page.shown);
    try w.writeAll("]}\n");
    return emitted != 0;
}

fn sourceLineObjects(w: *Writer, text: []const u8, ranges: []const query.LineRange) !u32 {
    var start: usize = 0;
    var line: usize = 1;
    var emitted: u32 = 0;
    while (start < text.len) : (line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (sourceLineSelected(line, ranges)) {
            if (emitted != 0) try w.writeByte(',');
            try w.print("{{\"line\":{d},\"text\":", .{line});
            try writeString(w, text[start..newline]);
            try w.writeByte('}');
            emitted += 1;
        }
        start = newline + 1;
    }
    return emitted;
}

fn sourceLineSelected(line: usize, ranges: []const query.LineRange) bool {
    if (ranges.len == 0) return true;
    for (ranges) |range| if (line >= range.lo and line <= range.hi) return true;
    return false;
}

/// Imports: `{file, imports:[{target, binding}]}` per in-scope file.
/// Index coverage manifest: `{file, lang, symbols}` per indexed file. Returns
/// whether any file matched.
pub fn listFiles(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.files.len <= std.math.maxInt(model.FileId));
    const ranked = try query.collectFiles(idx, filter, opts);
    defer idx.gpa.free(ranked);
    const shown = @min(ranked.len, @as(usize, opts.limit));
    try w.writeByte('[');
    for (ranked[0..shown], 0..) |entry, position| {
        if (position != 0) try w.writeByte(',');
        const file = idx.graph.files[entry.id];
        try w.writeAll("{\"file\":");
        try writeString(w, file.path);
        try w.print(",\"lang\":\"{s}\",\"symbols\":{d}", .{ file.language.tag(), entry.count });
        try writeParseHealthField(w, "parse_health", file.parse_health);
        try w.writeByte('}');
    }
    try w.writeAll("]\n");
    return ranked.len != 0;
}

/// Returns whether any file with fn/method symbols matched (i.e. the coverage
/// report is non-empty).
pub fn coverage(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const reached = try query.testReachable(idx, idx.gpa);
    defer idx.gpa.free(reached);
    var total: u32 = 0;
    var covered: u32 = 0;
    var total_files: u32 = 0;
    var emitted: u32 = 0;
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
        total_files += 1;
        total += ft;
        covered += fc;
        if (emitted >= opts.limit) continue;
        if (emitted != 0) try w.writeByte(',');
        emitted += 1;
        try w.writeAll("{\"file\":");
        try writeString(w, file.path);
        try w.print(",\"covered\":{d},\"total\":{d},\"percent\":{d:.1}}}", .{ fc, ft, covPct(fc, ft) });
    }
    try w.print("],\"covered\":{d},\"total\":{d},\"percent\":{d:.1},\"file_count\":{d},\"emitted\":{d},\"truncated\":{}}}\n", .{
        covered, total, covPct(covered, total), total_files, emitted, emitted < total_files,
    });
    return total_files != 0;
}

fn covPct(num: u32, den: u32) f64 {
    if (den == 0) return 0.0;
    return 100.0 * @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

/// Returns whether any in-scope file had imports to report.
pub fn listImports(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    var first = true;
    var shown: u32 = 0;
    try w.writeByte('[');
    for (idx.graph.files) |file| {
        const imps = idx.importsOf(file.id);
        if (imps.len == 0 or !query.matchesFilter(file.path, filter)) continue;
        // `-l` caps emitted entries. The payload stays a bare array: a
        // truncation envelope would be a breaking shape change for clients.
        if (query.listCap(opts)) |cap| if (shown >= cap) break;
        shown += 1;
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
    var first = true;
    var any_importer = false;
    var shown: u32 = 0;
    try w.writeByte('[');
    for (idx.graph.files) |target| {
        if (!query.matchesFilter(target.path, path)) continue;
        const importers = countImporters(idx, target.id);
        // `-l` counts files that actually have importers, exactly as the text
        // renderer does: a target with none is nothing found in either output.
        if (importers != 0) {
            if (query.listCap(opts)) |cap| if (shown >= cap) continue;
            shown += 1;
            any_importer = true;
        }
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
        }
        std.debug.assert(wrote == importers);
        try w.writeAll("]}");
    }
    try w.writeAll("]\n");
    return any_importer;
}

fn countImporters(idx: *const Index, target: model.FileId) u32 {
    var n: u32 = 0;
    for (idx.graph.files) |src| {
        if (fileImports(idx, src.id, target)) n += 1;
    }
    return n;
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
    const from_ids = query.resolveIds(idx, from_name, &fbuf);
    const to_ids = query.resolveIds(idx, to_name, &tbuf);
    if (from_ids.len > 1 or to_ids.len > 1) {
        try writeAmbiguousPath(w, idx, from_name, to_name, from_ids, to_ids, fbuf.len, tbuf.len);
        return false;
    }
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

fn writeAmbiguousPath(
    w: *Writer,
    idx: *const Index,
    from_name: []const u8,
    to_name: []const u8,
    from_ids: []const SymbolId,
    to_ids: []const SymbolId,
    from_capacity: usize,
    to_capacity: usize,
) !void {
    try w.writeAll("{\"ambiguous\":true,\"traversed\":false,\"from\":");
    try writePathEndpoint(w, idx, from_name, from_ids, from_capacity);
    try w.writeAll(",\"to\":");
    try writePathEndpoint(w, idx, to_name, to_ids, to_capacity);
    try w.writeAll(",\"candidates\":[");
    const candidates = if (from_ids.len > 1) from_ids else to_ids;
    for (candidates[0..@min(candidates.len, 12)], 0..) |candidate, i| {
        if (i != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[candidate]);
        try w.writeAll(",\"selector\":");
        try writePinnedPathSelector(w, idx, candidate);
        try w.writeByte('}');
    }
    try w.writeAll("],\"suggested_calls\":[");
    if (candidates.len != 0) {
        try w.writeAll("{\"command\":\"path\",\"from\":");
        if (from_ids.len > 1) try writePinnedPathSelector(w, idx, candidates[0]) else try writeString(w, from_name);
        try w.writeAll(",\"to\":");
        if (to_ids.len > 1) try writePinnedPathSelector(w, idx, candidates[0]) else try writeString(w, to_name);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
}

fn writePathEndpoint(w: *Writer, idx: *const Index, selector: []const u8, ids: []const SymbolId, capacity: usize) !void {
    _ = idx;
    try w.writeAll("{\"selector\":");
    try writeString(w, selector);
    try w.print(",\"matches\":{},\"truncated\":{}}}", .{ ids.len, ids.len == capacity });
}

fn writePinnedPathSelector(w: *Writer, idx: *const Index, id: SymbolId) !void {
    const sym = idx.graph.symbols[id];
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(idx.gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(idx.gpa, &buf);
    defer aw.deinit();
    if (sym.parent != invalid) {
        try aw.writer.writeAll(idx.graph.symbols[sym.parent].name);
        try aw.writer.writeByte('.');
    }
    try aw.writer.writeAll(sym.name);
    try aw.writer.writeByte('@');
    try aw.writer.writeAll(idx.graph.files[sym.file].path);
    try writeString(w, aw.written());
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
    const file = idx.graph.files[sym.file];
    try w.print(",\"line\":{d},\"line_end\":{d}", .{ sym.line, sym.endLine(file.text) });
    try writeParseHealthField(w, "parse_health", file.parse_health);
    try writeModifiers(w, sym);
}

/// Emit a named parse-health field whenever there is something to report: a
/// tokenizer desync, a silent tree-sitter -> heuristic substitution (F5), or
/// both.
fn writeParseHealthField(w: *Writer, name: []const u8, health: model.ParseHealth) !void {
    if (!health.hasDiagnostic()) return;
    std.debug.assert(name.len > 0);
    try w.writeAll(",\"");
    try w.writeAll(name);
    try w.writeAll("\":{");
    if (health.desync_from) |from| {
        std.debug.assert(health.desync_to >= from);
        try w.print("\"kind\":\"tokenizer_desync\",\"from_line\":{},\"to_line\":{}", .{ from, health.desync_to });
        if (health.tree_sitter_fallback) try w.writeByte(',');
    }
    if (health.tree_sitter_fallback) try w.writeAll("\"tree_sitter_fallback\":true");
    try w.writeAll("}");
}

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
pub fn symbolObject(w: *Writer, idx: *const Index, sym: Symbol, v: render.Verbosity) !void {
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
pub fn writeString(w: *Writer, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) i += try writeUtf8Unit(w, s[i..]);
    try w.writeByte('"');
}

/// Write `text` as a JSON string with interior whitespace collapsed to single
/// spaces and length capped (mirrors the compact text renderer).
fn writeCollapsedString(w: *Writer, text: []const u8, cap: usize) !void {
    try w.writeByte('"');
    var written: usize = 0;
    var prev_space = false;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            prev_space = written != 0;
            i += 1;
            continue;
        }
        if (prev_space and written < cap) {
            try w.writeByte(' ');
            written += 1;
        }
        prev_space = false;
        // Cap counts whole code points; the boundary check happens before a unit
        // is written so a multi-byte UTF-8 character is never split (which would
        // otherwise produce invalid JSON).
        if (written >= cap) break;
        i += try writeUtf8Unit(w, text[i..]);
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

/// Write one UTF-8 unit starting at `s[0]` as JSON-safe output and return the
/// number of input bytes consumed. ASCII bytes are escaped (control chars, quote,
/// backslash); a valid multi-byte UTF-8 sequence is emitted verbatim (valid UTF-8
/// is valid JSON); anything else becomes U+FFFD so the emitted JSON is always
/// well-formed UTF-8, even when the source contains raw non-UTF-8 bytes.
///
/// Validation goes through `std.unicode`, not a lead-byte/continuation-bit check:
/// that check admits overlong encodings (`E0 80 8E`), surrogate halves
/// (`ED A0 80`) and code points above U+10FFFF (`F4 A2 B6 AA`), each of which a
/// strict decoder (Python `json`, `vim.json.decode`, Go `encoding/json`) rejects
/// — taking the whole document down over one stray byte.
fn writeUtf8Unit(w: *Writer, s: []const u8) !usize {
    const c = s[0];
    if (c < 0x80) {
        try writeEscaped(w, c);
        return 1;
    }
    const replacement = "\xEF\xBF\xBD"; // U+FFFD REPLACEMENT CHARACTER
    const len: usize = std.unicode.utf8ByteSequenceLength(c) catch {
        try w.writeAll(replacement);
        return 1;
    };
    if (len <= s.len) {
        const decoded: ?u21 = switch (len) {
            2 => std.unicode.utf8Decode2(s[0..2].*) catch null,
            3 => std.unicode.utf8Decode3(s[0..3].*) catch null,
            4 => std.unicode.utf8Decode4(s[0..4].*) catch null,
            else => null,
        };
        if (decoded != null) {
            try w.writeAll(s[0..len]);
            return len;
        }
    }
    try w.writeAll(replacement);
    return 1;
}

test "writeUtf8Unit replaces overlong, surrogate and out-of-range sequences" {
    // Regression: the hand-rolled lead-byte/continuation check emitted these
    // three classes verbatim, so one stray byte made the whole -j document
    // undecodable to a strict JSON reader.
    const testing = std.testing;
    const cases = [_][]const u8{
        "\xe0\x80\x8e", // overlong: 3 bytes encoding U+000E
        "\xed\xa0\x80", // surrogate half U+D800
        "\xf4\xa2\xb6\xaa", // above U+10FFFF
        "\xc0\xaf", // overlong 2-byte slash
        "\xf8\x88\x80\x80", // 5-byte lead, not UTF-8 at all
        "\x80", // bare continuation byte
        "\xe2\x9c", // truncated 3-byte sequence
    };
    for (cases) |bytes| {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var consumed: usize = 0;
        while (consumed < bytes.len) consumed += try writeUtf8Unit(&aw.writer, bytes[consumed..]);
        try testing.expect(std.unicode.utf8ValidateSlice(aw.written()));
        // Nothing from the invalid input survives as raw bytes.
        try testing.expect(std.mem.indexOf(u8, aw.written(), bytes) == null);
    }

    // Valid sequences of every length are still emitted verbatim.
    const valid = "a\xc3\xa9\xe2\x9c\x93\xf0\x9f\x8e\x89";
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var consumed: usize = 0;
    while (consumed < valid.len) consumed += try writeUtf8Unit(&aw.writer, valid[consumed..]);
    try testing.expectEqualStrings(valid, aw.written());
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
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
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
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
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
    return index_mod.build(std.testing.allocator, std.testing.io, root, false, .auto);
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

test "outline json honors the tests scope like the text path (F8)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t.zig", .data =
        \\pub fn real() void {}
        \\
        \\test "a check" {}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    const V = struct {
        fn names(idxp: *const Index, scope: query.TestScope) ![]const []const u8 {
            var aw = tjWriter();
            defer aw.deinit();
            _ = try outline(&aw.writer, idxp, "", .{ .format = .json, .tests = scope });
            var p = try tjParse(aw.written());
            defer p.deinit();
            var out: std.ArrayList([]const u8) = .empty;
            if (p.value.array.items.len == 0) return out.toOwnedSlice(testing.allocator);
            for (p.value.array.items[0].object.get("symbols").?.array.items) |s| {
                try out.append(testing.allocator, try testing.allocator.dupe(u8, s.object.get("name").?.string));
            }
            return out.toOwnedSlice(testing.allocator);
        }
    };

    const with = try V.names(&idx, .with);
    defer {
        for (with) |n| testing.allocator.free(n);
        testing.allocator.free(with);
    }
    try testing.expectEqual(@as(usize, 2), with.len);

    const without = try V.names(&idx, .without);
    defer {
        for (without) |n| testing.allocator.free(n);
        testing.allocator.free(without);
    }
    try testing.expectEqual(@as(usize, 1), without.len);
    try testing.expectEqualStrings("real", without[0]);

    const only = try V.names(&idx, .only);
    defer {
        for (only) |n| testing.allocator.free(n);
        testing.allocator.free(only);
    }
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings("a check", only[0]);
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
        try testing.expectEqualStrings("exact", o.get("resolution_status").?.string);
        try testing.expectEqualStrings("same_file_fallback", o.get("resolution_reason").?.string);
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
    try testing.expectEqualStrings("exact", callees[0].object.get("resolution_status").?.string);
    try testing.expectEqualStrings("same_file_fallback", callees[0].object.get("resolution_reason").?.string);
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
    try testing.expectEqualStrings("exact", callers[0].object.get("resolution_status").?.string);
    try testing.expectEqualStrings("same_file_fallback", callers[0].object.get("resolution_reason").?.string);
}

test "calls json flags a heuristic edge with exact:false; strict drops it" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `planning` arrives as a parameter, so nothing declares its type and
    // `self.planning.create_run(1)` resolves only by the global-name heuristic.
    try tmp.dir.writeFile(io, .{ .sub_path = "svc.py", .data =
        \\class PlanningService:
        \\    def create_run(self, x):
        \\        return x
        \\
        \\class Handler:
        \\    def __init__(self, planning):
        \\        self.planning = planning
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
        const callee = p.value.array.items[0].object.get("callees").?.array.items[0].object;
        try testing.expectEqualStrings("heuristic", callee.get("resolution_status").?.string);
        try testing.expectEqualStrings("same_file_fallback", callee.get("resolution_reason").?.string);
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
        \\    def __init__(self, planning):
        \\        self.planning = planning
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
    _ = try diff(&aw.writer, &idx, &changes, "", .{ .format = .json });
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

test "diff exact-source json includes byte ranges, caller sites, and raw patch" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "d.zig", .data =
        \\pub fn helper() u32 {
        \\    return 2;
        \\}
        \\pub fn run() u32 {
        \\    const first = helper();
        \\    return first + helper();
        \\}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();
    var ranges = [_]gitdiff.Range{.{ .lo = 2, .hi = 2 }};
    var changes = [_]gitdiff.FileChange{.{ .path = "d.zig", .ranges = &ranges }};
    const patch = "@@ -2 +2 @@\n-    return 1;\n+    return 2;\n";

    var aw = tjWriter();
    defer aw.deinit();
    try testing.expect(try diff(&aw.writer, &idx, &changes, patch, .{ .format = .json, .exact_source = true }));
    var parsed = try tjParse(aw.written());
    defer parsed.deinit();
    try testing.expectEqualStrings(patch, parsed.value.object.get("patch").?.string);
    const file = parsed.value.object.get("files").?.array.items[0].object;
    const change = file.get("changes").?.array.items[0].object;
    try testing.expectEqualStrings("    return 2;", change.get("source").?.string);
    try testing.expect(change.get("start").?.integer < change.get("end").?.integer);
    try testing.expect(!change.get("empty").?.bool);
    const callers = file.get("symbols").?.array.items[0].object.get("callers").?.array.items;
    try testing.expectEqual(@as(usize, 1), callers.len);
    const caller = callers[0].object;
    try testing.expectEqual(@as(i64, 5), caller.get("site").?.integer);
    try testing.expectEqual(@as(i64, 2), caller.get("site_count").?.integer);
    try testing.expectEqual(@as(usize, 2), caller.get("lines").?.array.items.len);
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
    _ = try diff(&aw.writer, &idx, &changes, "", .{ .format = .json });
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
    try testing.expectEqualStrings("exact", callees[0].object.get("resolution_status").?.string);
    try testing.expectEqualStrings("same_file_fallback", callees[0].object.get("resolution_reason").?.string);
    const callers = o.get("callers").?.array.items;
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqualStrings("top", callers[0].object.get("name").?.string);
    try testing.expect(callers[0].object.get("site").?.integer >= 1);

    var bounded = tjWriter();
    defer bounded.deinit();
    _ = try neighbors(&bounded.writer, &idx, "mid", .{ .format = .json, .max_nodes = 2 });
    var bounded_json = try tjParse(bounded.written());
    defer bounded_json.deinit();
    try testing.expectEqual(@as(usize, 2), bounded_json.value.array.items.len);
    const truncated = bounded_json.value.array.items[1].object;
    try testing.expect(truncated.get("truncated").?.bool);
    try testing.expectEqual(@as(i64, 2), truncated.get("nodes").?.integer);
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

test "flow json reports ambiguous candidates and definition initializers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data =
        \\VALUE = 1
        \\def read_value(): return VALUE
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.py", .data = "VALUE = 2\n" });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try flow(&aw.writer, &idx, "VALUE", .{ .format = .json, .limit = 1 });
    var p = try tjParse(aw.written());
    defer p.deinit();
    const object = p.value.object;
    try testing.expectEqual(@as(i64, 2), object.get("match_count").?.integer);
    try testing.expectEqual(@as(usize, 2), object.get("candidates").?.array.items.len);
    const producers = object.get("producers").?.array.items;
    try testing.expectEqual(@as(usize, 1), producers.len);
    try testing.expectEqualStrings("initializer", producers[0].object.get("mode").?.string);
    try testing.expectEqual(@as(usize, 0), object.get("consumers").?.array.items.len);
    try testing.expectEqual(@as(i64, 2), object.get("counts").?.object.get("producers").?.integer);
    try testing.expectEqual(@as(i64, 1), object.get("counts").?.object.get("consumers").?.integer);
    try testing.expectEqual(@as(i64, 1), object.get("emitted").?.object.get("producers").?.integer);
    try testing.expect(object.get("truncated").?.bool);
}

test "flow json --to reports all ambiguous endpoints" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const body =
        \\VALUE = 0
        \\def forward():
        \\    sink()
        \\    return VALUE
        \\def sink(): pass
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = body });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.py", .data = body });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try flow(&aw.writer, &idx, "VALUE", .{ .format = .json, .flow_to = "sink" });
    var p = try tjParse(aw.written());
    defer p.deinit();
    const object = p.value.object;
    try testing.expectEqual(@as(i64, 2), object.get("source").?.object.get("match_count").?.integer);
    try testing.expectEqual(@as(i64, 2), object.get("sink").?.object.get("match_count").?.integer);
    try testing.expectEqual(@as(usize, 2), object.get("source").?.object.get("candidates").?.array.items.len);
    try testing.expect(object.get("path").? == .array);
    try testing.expect(object.get("path").?.array.items.len > 0);
}

test "flow json resolves and reports more than 64 definitions" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var n: usize = 0;
    while (n < 65) : (n += 1) {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "f{d}.py", .{n});
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "VALUE = 1\n" });
    }
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try flow(&aw.writer, &idx, "VALUE", .{ .format = .json });
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expectEqual(@as(i64, 65), p.value.object.get("match_count").?.integer);
    try testing.expectEqual(@as(usize, 65), p.value.object.get("candidates").?.array.items.len);

    aw.clearRetainingCapacity();
    _ = try flow(&aw.writer, &idx, "VALUE@f64.py", .{ .format = .json });
    var pinned = try tjParse(aw.written());
    defer pinned.deinit();
    try testing.expect(pinned.value.object.get("match_count") == null);
    try testing.expectEqual(@as(i64, 1), pinned.value.object.get("counts").?.object.get("producers").?.integer);
}

test "sibling conformance json attributes every verdict to its parent" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "siblings.py", .data =
        \\class AlphaRequest:
        \\    def run(self, value: str): return value
        \\    def stop(self): return None
        \\class BetaRequest:
        \\    pass
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try conforms(&aw.writer, &idx, "*Request", .{ .format = .json, .strict = true, .limit = 1 });
    var p = try tjParse(aw.written());
    defer p.deinit();
    const members = p.value.array.items[0].object.get("members").?.array.items;
    try testing.expectEqual(@as(usize, 1), members.len);
    const implementations = members[0].object.get("implementations").?.array.items;
    try testing.expectEqual(@as(usize, 1), implementations.len);
    const verdict = implementations[0].object;
    try testing.expectEqualStrings("BetaRequest", verdict.get("parent").?.object.get("name").?.string);
    try testing.expectEqualStrings("missing", verdict.get("verdict").?.string);
    try testing.expect(verdict.get("symbol").? == .null);
}

test "conformance json handles an empty index" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    try testing.expect(!try conforms(&aw.writer, &idx, "Missing", .{ .format = .json }));
    var p = try tjParse(aw.written());
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.value.array.items.len);

    aw.clearRetainingCapacity();
    try testing.expect(!try flow(&aw.writer, &idx, "VALUE", .{ .format = .json }));
    var missing = try tjParse(aw.written());
    defer missing.deinit();
    try testing.expectEqual(@as(i64, 0), missing.value.object.get("match_count").?.integer);
    try testing.expectEqual(@as(i64, 0), missing.value.object.get("counts").?.object.get("producers").?.integer);

    aw.clearRetainingCapacity();
    try testing.expect(!try flow(&aw.writer, &idx, "VALUE", .{ .format = .json, .flow_to = "sink" }));
    var path = try tjParse(aw.written());
    defer path.deinit();
    try testing.expectEqual(@as(i64, 0), path.value.object.get("source").?.object.get("match_count").?.integer);
    try testing.expect(path.value.object.get("path").? == .array);
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

test "importers -l counts the same files in json as in text" {
    // Regression (F8): the json renderer counted the cap over every matched
    // target, the text one over targets that actually have importers, so the
    // two disagreed on what `-l N` shows.
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn a() void {}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub fn b() void {}
    });
    // Only a.zig and b.zig have importers; user.zig has none.
    try tmp.dir.writeFile(io, .{ .sub_path = "user.zig", .data =
        \\const a = @import("a.zig");
        \\const b = @import("b.zig");
        \\pub fn use() void { a.a(); b.b(); }
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    _ = try listImporters(&aw.writer, &idx, ".zig", .{ .format = .json, .limit = 1, .limit_set = true });
    var p = try tjParse(aw.written());
    defer p.deinit();

    var with_importers: usize = 0;
    for (p.value.array.items) |entry| {
        if (entry.object.get("importers").?.array.items.len != 0) with_importers += 1;
    }
    try testing.expectEqual(@as(usize, 1), with_importers);
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

test "path json returns candidates instead of traversing an ambiguous endpoint" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn start() void { dst(); }
        \\pub fn dst() void {}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub fn start() void {}
    });
    var idx = try tjBuild(&tmp);
    defer idx.deinit();

    var aw = tjWriter();
    defer aw.deinit();
    try testing.expect(!try shortestPath(&aw.writer, &idx, "start", "dst", .{ .format = .json }));
    var parsed = try tjParse(aw.written());
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expect(object.get("ambiguous").?.bool);
    try testing.expect(!object.get("traversed").?.bool);
    try testing.expectEqual(@as(usize, 2), object.get("candidates").?.array.items.len);
    const suggested = object.get("suggested_calls").?.array.items[0].object;
    const pinned = suggested.get("from").?.string;
    var ids: [4]SymbolId = undefined;
    try testing.expectEqual(@as(usize, 1), query.resolveIds(&idx, pinned, &ids).len);
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

test "source read json is valid, bounded, and carries a continuation cursor" {
    const testing = std.testing;
    const text = "one\ntwo \"quoted\"\nthree\\slash\nfour\nfive\n";
    const requested = [_]query.LineRange{.{ .lo = 1, .hi = 5 }};
    var page_ranges: [query.max_read_ranges]query.LineRange = undefined;

    var aw = tjWriter();
    defer aw.deinit();
    const first = query.sourcePage(text, &requested, .{ .limit = 2 }, &page_ranges);
    try testing.expect(try sourceLines(&aw.writer, "sample.txt", text, &requested, first));
    var parsed = try tjParse(aw.written());
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("sample.txt", root.get("file").?.string);
    try testing.expectEqual(@as(i64, 5), root.get("total_lines").?.integer);
    try testing.expectEqual(@as(i64, 5), root.get("selected").?.integer);
    try testing.expectEqual(@as(i64, 2), root.get("shown").?.integer);
    try testing.expect(root.get("truncated").?.bool);
    try testing.expectEqualStrings("v1:2", root.get("next").?.string);
    try testing.expectEqual(@as(usize, 2), root.get("lines").?.array.items.len);
    try testing.expectEqualStrings("two \"quoted\"", root.get("lines").?.array.items[1].object.get("text").?.string);

    aw.clearRetainingCapacity();
    const second = query.sourcePage(text, &requested, .{ .limit = 2, .after = 2, .after_set = true }, &page_ranges);
    try testing.expect(try sourceLines(&aw.writer, "sample.txt", text, &requested, second));
    var parsed_second = try tjParse(aw.written());
    defer parsed_second.deinit();
    const second_root = parsed_second.value.object;
    try testing.expectEqual(@as(i64, 2), second_root.get("offset").?.integer);
    try testing.expectEqualStrings("v1:4", second_root.get("next").?.string);
    try testing.expectEqual(@as(i64, 3), second_root.get("lines").?.array.items[0].object.get("line").?.integer);
}

test "source read json validation errors have stable code message and value" {
    const testing = std.testing;
    var aw = tjWriter();
    defer aw.deinit();
    try readError(&aw.writer, "descending_range", "range end must not precede its start", "100-50");
    var parsed = try tjParse(aw.written());
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("descending_range", root.get("error").?.string);
    try testing.expectEqualStrings("range end must not precede its start", root.get("message").?.string);
    try testing.expectEqualStrings("100-50", root.get("value").?.string);
}
