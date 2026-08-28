//! Phase 3 agent workflows: set reachability, affected-test selection,
//! documentation/comment queries, and safe mechanical refactor planning.

const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");
const query = @import("query.zig");
const render = @import("render.zig");
const json_out = @import("json_out.zig");
const gitdiff = @import("gitdiff.zig");
const impls_mod = @import("impls.zig");
const lexer = @import("lexer.zig");
const language = @import("language.zig");
const gitutil = @import("gitutil.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

const Page = struct {
    skipped: u32,
    emitted: u32 = 0,
    estimated_bytes: u32 = 0,

    fn accepts(self: *Page, ordinal: u32, estimate: u32, opts: query.Options) bool {
        std.debug.assert(estimate > 0);
        std.debug.assert(ordinal >= self.skipped or self.emitted == 0);
        if (ordinal < self.skipped) return false;
        if (self.emitted >= opts.limit) return false;
        if (opts.max_nodes != 0 and self.emitted >= opts.max_nodes) return false;
        if (opts.budget != 0 and self.emitted != 0 and self.estimated_bytes + estimate > opts.budget) return false;
        self.emitted += 1;
        self.estimated_bytes +|= estimate;
        return true;
    }
};

pub fn reaches(w: *Writer, idx: *const Index, selectors: []const u8, opts: query.Options) !bool {
    std.debug.assert(selectors.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const roots = try resolveRoots(idx, selectors);
    defer idx.gpa.free(roots);
    if (roots.len == 0) {
        try noResults(w, opts, "symbols", selectors);
        return false;
    }
    const ids = if (opts.from_tests)
        try reverseReachable(idx, roots, opts, true)
    else
        try forwardReachable(idx, roots, opts);
    defer idx.gpa.free(ids);
    return renderSymbolSet(w, idx, if (opts.from_tests) "tests" else "reachable", selectors, ids, opts);
}

pub fn affected(w: *Writer, io: std.Io, idx: *const Index, root: []const u8, positional: []const u8, opts: query.Options) !bool {
    return affectedAt(w, io, idx, .{ .path = root }, positional, opts);
}

pub fn affectedAt(w: *Writer, io: std.Io, idx: *const Index, root: gitutil.Root, positional: []const u8, opts: query.Options) !bool {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    const since = if (opts.since.len != 0) opts.since else if (positional.len != 0) positional else "HEAD";
    const changed = try changedSymbols(w, io, idx, root, since, opts.format);
    if (changed == null) return false;
    defer idx.gpa.free(changed.?);
    if (changed.?.len == 0) {
        try noResults(w, opts, "changed symbols", since);
        return false;
    }
    const tests = try reverseReachable(idx, changed.?, opts, true);
    defer idx.gpa.free(tests);
    return renderSymbolSet(w, idx, "affected_tests", since, tests, opts);
}

fn changedSymbols(w: *Writer, io: std.Io, idx: *const Index, root: gitutil.Root, since: []const u8, format: query.OutputFormat) !?[]SymbolId {
    std.debug.assert(since.len > 0);
    const result = query.runGitDiffAt(idx.gpa, io, root, since) catch |err| {
        const msg = try std.fmt.allocPrint(idx.gpa, "could not run git diff ({s})", .{@errorName(err)});
        defer idx.gpa.free(msg);
        try query.emitError(w, format, msg);
        return null;
    };
    defer idx.gpa.free(result.stdout);
    defer idx.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        const msg = try std.fmt.allocPrint(idx.gpa, "git diff {s} failed: {s}", .{ since, std.mem.trim(u8, result.stderr, " \n\r\t") });
        defer idx.gpa.free(msg);
        try query.emitError(w, format, msg);
        return null;
    }
    const changes = try gitdiff.parse(idx.gpa, result.stdout);
    defer gitdiff.freeChanges(idx.gpa, changes);
    return try collectChanged(idx, changes);
}

fn collectChanged(idx: *const Index, changes: []const gitdiff.FileChange) ![]SymbolId {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var ids: std.ArrayList(SymbolId) = .empty;
    defer ids.deinit(idx.gpa);
    for (changes) |change| {
        const file = query.findDiffFile(idx, change.path) orelse continue;
        var touched_reportable = false;
        var id = file.sym_start;
        while (id < file.sym_end) : (id += 1) {
            const sym = idx.graph.symbols[id];
            if (!query.symbolTouched(sym, file.text, change.ranges)) continue;
            if (sym.kind == .import or sym.kind == .route_mount) continue;
            try appendUnique(idx.gpa, &ids, sym.id);
            touched_reportable = true;
        }
        if (!touched_reportable) {
            id = file.sym_start;
            while (id < file.sym_end) : (id += 1) {
                const kind = idx.graph.symbols[id].kind;
                if (kind == .import or kind == .route_mount) continue;
                try appendUnique(idx.gpa, &ids, id);
            }
        }
    }
    return ids.toOwnedSlice(idx.gpa);
}

fn resolveRoots(idx: *const Index, selectors: []const u8) ![]SymbolId {
    std.debug.assert(selectors.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var out: std.ArrayList(SymbolId) = .empty;
    defer out.deinit(idx.gpa);
    const buf = try idx.gpa.alloc(SymbolId, @max(idx.graph.symbols.len, 1));
    defer idx.gpa.free(buf);
    var it = std.mem.tokenizeScalar(u8, selectors, ',');
    while (it.next()) |raw| {
        const selector = std.mem.trim(u8, raw, " \t\r\n");
        if (selector.len == 0) continue;
        for (query.resolveIds(idx, selector, buf)) |id| try appendUnique(idx.gpa, &out, id);
    }
    return out.toOwnedSlice(idx.gpa);
}

fn forwardReachable(idx: *const Index, roots: []const SymbolId, opts: query.Options) ![]SymbolId {
    std.debug.assert(roots.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const visited = try idx.gpa.alloc(bool, idx.graph.symbols.len);
    defer idx.gpa.free(visited);
    @memset(visited, false);
    var queue: std.ArrayList(SymbolId) = .empty;
    defer queue.deinit(idx.gpa);
    for (roots) |id| try enqueue(idx.gpa, &queue, visited, id);
    var impl_graph: ?impls_mod.Graph = if (opts.impls) try impls_mod.build(idx.gpa, idx) else null;
    defer if (impl_graph) |*graph| graph.deinit();
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const id = queue.items[head];
        for (idx.graph.symbols[id].refs) |ref| {
            if (ref.target == invalid or (opts.strict and !ref.exact)) continue;
            try enqueue(idx.gpa, &queue, visited, ref.target);
        }
        if (impl_graph) |graph| try enqueueImplPeers(idx.gpa, &queue, visited, graph, id, opts.strict);
    }
    return filteredSorted(idx, visited, false, opts.tests);
}

fn reverseReachable(idx: *const Index, targets: []const SymbolId, opts: query.Options, tests_only: bool) ![]SymbolId {
    std.debug.assert(targets.len > 0);
    std.debug.assert(idx.callers.len == idx.graph.symbols.len);
    const visited = try idx.gpa.alloc(bool, idx.graph.symbols.len);
    defer idx.gpa.free(visited);
    @memset(visited, false);
    var queue: std.ArrayList(SymbolId) = .empty;
    defer queue.deinit(idx.gpa);
    for (targets) |id| try enqueue(idx.gpa, &queue, visited, id);
    var impl_graph: ?impls_mod.Graph = if (opts.impls) try impls_mod.build(idx.gpa, idx) else null;
    defer if (impl_graph) |*graph| graph.deinit();
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const id = queue.items[head];
        for (idx.callersOf(id)) |caller| {
            if (opts.strict and !query.hasExactEdge(idx, caller, id)) continue;
            try enqueue(idx.gpa, &queue, visited, caller);
        }
        if (impl_graph) |graph| try enqueueImplPeers(idx.gpa, &queue, visited, graph, id, opts.strict);
    }
    return filteredSorted(idx, visited, tests_only, opts.tests);
}

fn enqueueImplPeers(
    gpa: std.mem.Allocator,
    queue: *std.ArrayList(SymbolId),
    visited: []bool,
    graph: impls_mod.Graph,
    id: SymbolId,
    strict: bool,
) !void {
    std.debug.assert(id < visited.len);
    std.debug.assert(queue.items.len <= visited.len);
    for (graph.edges) |edge| {
        if (strict and !edge.exact) continue;
        if (edge.port_method == id) try enqueue(gpa, queue, visited, edge.implementation_method);
        if (edge.implementation_method == id) try enqueue(gpa, queue, visited, edge.port_method);
    }
}

fn enqueue(gpa: std.mem.Allocator, queue: *std.ArrayList(SymbolId), visited: []bool, id: SymbolId) !void {
    std.debug.assert(id < visited.len);
    std.debug.assert(queue.items.len <= visited.len);
    if (visited[id]) return;
    visited[id] = true;
    try queue.append(gpa, id);
}

fn filteredSorted(idx: *const Index, visited: []const bool, tests_only: bool, scope: query.TestScope) ![]SymbolId {
    std.debug.assert(visited.len == idx.graph.symbols.len);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var ids: std.ArrayList(SymbolId) = .empty;
    defer ids.deinit(idx.gpa);
    for (visited, 0..) |seen, raw_id| {
        if (!seen) continue;
        const sym = idx.graph.symbols[raw_id];
        const is_test = query.isTestSymbol(idx, sym);
        if (tests_only and !is_test) continue;
        if (!tests_only and !scopeAllows(scope, is_test)) continue;
        try ids.append(idx.gpa, @intCast(raw_id));
    }
    std.sort.block(SymbolId, ids.items, idx, symbolLessThan);
    return ids.toOwnedSlice(idx.gpa);
}

fn scopeAllows(scope: query.TestScope, is_test: bool) bool {
    return switch (scope) {
        .with => true,
        .without => !is_test,
        .only => is_test,
    };
}

fn symbolLessThan(idx: *const Index, a: SymbolId, b: SymbolId) bool {
    const sa = idx.graph.symbols[a];
    const sb = idx.graph.symbols[b];
    const pa = idx.graph.files[sa.file].path;
    const pb = idx.graph.files[sb.file].path;
    const order = std.mem.order(u8, pa, pb);
    if (order != .eq) return order == .lt;
    if (sa.line != sb.line) return sa.line < sb.line;
    return a < b;
}

fn renderSymbolSet(w: *Writer, idx: *const Index, label: []const u8, selector: []const u8, ids: []const SymbolId, opts: query.Options) !bool {
    std.debug.assert(label.len > 0);
    std.debug.assert(selector.len > 0);
    if (opts.format == .jsonl) return symbolSetJsonl(w, idx, label, selector, ids, opts);
    if (opts.format == .json) return symbolSetJson(w, idx, label, selector, ids, opts);
    if (ids.len == 0) {
        try w.print("(no {s} for {s})\n", .{ label, selector });
        return false;
    }
    var page = Page{ .skipped = opts.after };
    for (ids, 0..) |id, ordinal| {
        const sym = idx.graph.symbols[id];
        const estimate: u32 = @intCast(@min(@as(usize, std.math.maxInt(u32)), 48 + sym.name.len + idx.graph.files[sym.file].path.len));
        if (!page.accepts(@intCast(ordinal), estimate, opts)) continue;
        try render.symbol(w, idx, sym, if (opts.summary) .names else opts.verbosity, 0, true);
    }
    try compactNote(w, ids.len, page, opts);
    return page.emitted != 0;
}

fn symbolSetJson(w: *Writer, idx: *const Index, label: []const u8, selector: []const u8, ids: []const SymbolId, opts: query.Options) !bool {
    std.debug.assert(label.len > 0);
    std.debug.assert(selector.len > 0);
    try w.writeAll("{\"kind\":");
    try json_out.writeString(w, label);
    try w.writeAll(",\"selector\":");
    try json_out.writeString(w, selector);
    try w.writeAll(",\"results\":[");
    var page = Page{ .skipped = 0 };
    for (ids, 0..) |id, ordinal| {
        if (!page.accepts(@intCast(ordinal), 96, opts)) continue;
        if (page.emitted > 1) try w.writeByte(',');
        try json_out.symbolObject(w, idx, idx.graph.symbols[id], opts.verbosity);
    }
    try w.print("],\"count\":{},\"total\":{},\"truncated\":{}", .{ page.emitted, ids.len, page.emitted < ids.len });
    try w.writeAll("}\n");
    return page.emitted != 0;
}

fn symbolSetJsonl(w: *Writer, idx: *const Index, label: []const u8, selector: []const u8, ids: []const SymbolId, opts: query.Options) !bool {
    std.debug.assert(label.len > 0);
    std.debug.assert(selector.len > 0);
    var page = Page{ .skipped = opts.after };
    var last = opts.after;
    for (ids, 0..) |id, ordinal| {
        if (!page.accepts(@intCast(ordinal), 96, opts)) continue;
        last = @intCast(ordinal + 1);
        try w.print("{{\"cursor\":\"v1:{}\",\"item\":", .{last});
        try json_out.symbolObject(w, idx, idx.graph.symbols[id], opts.verbosity);
        try w.writeAll("}\n");
    }
    const has_more = last < ids.len;
    try w.print("{{\"page\":{{\"kind\":", .{});
    try json_out.writeString(w, label);
    try w.writeAll(",\"selector\":");
    try json_out.writeString(w, selector);
    try w.print(",\"count\":{},\"total\":{},\"has_more\":{},\"next\":", .{ page.emitted, ids.len, has_more });
    if (has_more) try w.print("\"v1:{}\"", .{last}) else try w.writeAll("null");
    try w.writeAll("}}\n");
    return page.emitted != 0;
}

fn compactNote(w: *Writer, total: usize, page: Page, opts: query.Options) !void {
    const consumed: usize = @as(usize, page.skipped) + page.emitted;
    if (consumed >= total) return;
    const reason = if (opts.max_nodes != 0 and page.emitted >= opts.max_nodes)
        "max-nodes"
    else if (opts.budget != 0)
        "budget"
    else
        "limit";
    try w.print("… {} nodes elided ({s}; {} shown)\n", .{ total - consumed, reason, page.emitted });
}

fn noResults(w: *Writer, opts: query.Options, kind: []const u8, selector: []const u8) !void {
    std.debug.assert(kind.len > 0);
    std.debug.assert(selector.len > 0);
    if (opts.format == .json) {
        try w.print("{{\"kind\":", .{});
        try json_out.writeString(w, kind);
        try w.writeAll(",\"selector\":");
        try json_out.writeString(w, selector);
        try w.writeAll(",\"results\":[],\"count\":0,\"total\":0,\"truncated\":false}\n");
    } else if (opts.format == .jsonl) {
        try w.writeAll("{\"page\":{\"count\":0,\"total\":0,\"has_more\":false,\"next\":null}}\n");
    } else {
        try w.print("(no {s} for {s})\n", .{ kind, selector });
    }
}

fn appendUnique(gpa: std.mem.Allocator, ids: *std.ArrayList(SymbolId), id: SymbolId) !void {
    for (ids.items) |existing| if (existing == id) return;
    try ids.append(gpa, id);
}

pub fn docs(w: *Writer, idx: *const Index, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const ids = try resolveRoots(idx, selector);
    defer idx.gpa.free(ids);
    if (opts.format != .text) return docsJson(w, idx, selector, ids);
    var shown: u32 = 0;
    for (ids) |id| {
        const sym = idx.graph.symbols[id];
        const doc = render.stripDoc(sym.doc);
        if (doc.len == 0) continue;
        if (shown != 0) try w.writeByte('\n');
        try render.symbol(w, idx, sym, .names, 0, true);
        try w.writeAll(doc);
        if (doc[doc.len - 1] != '\n') try w.writeByte('\n');
        shown += 1;
    }
    if (shown == 0) try w.print("(no indexed documentation for {s})\n", .{selector});
    return shown != 0;
}

fn docsJson(w: *Writer, idx: *const Index, selector: []const u8, ids: []const SymbolId) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(ids.len <= idx.graph.symbols.len);
    try w.writeByte('[');
    var shown: u32 = 0;
    for (ids) |id| {
        if (idx.graph.symbols[id].doc.len == 0) continue;
        if (shown != 0) try w.writeByte(',');
        try json_out.symbolObject(w, idx, idx.graph.symbols[id], .doc);
        shown += 1;
    }
    try w.writeAll("]\n");
    return shown != 0;
}

const TodoSite = struct { file: model.FileId, line: u32, marker: []const u8, text: []const u8 };

pub fn todos(w: *Writer, idx: *const Index, filter: []const u8, opts: query.Options) !bool {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(opts.limit > 0);
    const sites = try collectTodos(idx, filter);
    defer idx.gpa.free(sites);
    if (opts.format == .jsonl) return todosJsonl(w, idx, sites, opts);
    if (opts.format == .json) return todosJson(w, idx, sites, opts);
    var page = Page{ .skipped = 0 };
    for (sites, 0..) |site, ordinal| {
        if (!page.accepts(@intCast(ordinal), @intCast(@min(site.text.len + 40, std.math.maxInt(u32))), opts)) continue;
        try w.print("{s}:{}  {s}  {s}\n", .{ idx.graph.files[site.file].path, site.line, site.marker, site.text });
    }
    if (page.emitted == 0) try w.writeAll("(no TODO/FIXME/HACK comments)\n");
    try compactNote(w, sites.len, page, opts);
    return page.emitted != 0;
}

fn collectTodos(idx: *const Index, filter: []const u8) ![]TodoSite {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var sites: std.ArrayList(TodoSite) = .empty;
    defer sites.deinit(idx.gpa);
    for (idx.graph.files) |file| {
        if (filter.len != 0 and !query.matchesFilter(file.path, filter)) continue;
        var toks: std.ArrayList(lexer.Token) = .empty;
        defer toks.deinit(idx.gpa);
        try lexer.tokenize(idx.gpa, file.text, language.configFor(file.language), &toks);
        for (toks.items) |tok| {
            if (tok.kind != .comment) continue;
            const raw = tok.text(file.text);
            var offset: usize = 0;
            while (nextTodo(raw, offset)) |match| {
                const line = tok.line + @as(u32, @intCast(std.mem.count(u8, raw[0..match.at], "\n")));
                const snippet = commentLine(raw, match.at);
                try sites.append(idx.gpa, .{ .file = file.id, .line = line, .marker = match.marker, .text = snippet });
                offset = match.at + match.marker.len;
            }
        }
    }
    std.sort.block(TodoSite, sites.items, idx, todoLessThan);
    return sites.toOwnedSlice(idx.gpa);
}

const TodoMatch = struct { at: usize, marker: []const u8 };

fn nextTodo(text: []const u8, from: usize) ?TodoMatch {
    if (from >= text.len) return null;
    var best: ?TodoMatch = null;
    for ([_][]const u8{ "TODO", "FIXME", "HACK" }) |marker| {
        var cursor = from;
        while (std.mem.indexOf(u8, text[cursor..], marker)) |rel| {
            const at = cursor + rel;
            if (todoBoundary(text, at, marker.len)) {
                const candidate = TodoMatch{ .at = at, .marker = marker };
                if (best == null or candidate.at < best.?.at) best = candidate;
                break;
            }
            cursor = at + marker.len;
            if (cursor >= text.len) break;
        }
    }
    return best;
}

fn todoBoundary(text: []const u8, at: usize, len: usize) bool {
    std.debug.assert(at + len <= text.len);
    std.debug.assert(len > 0);
    const before_word = at != 0 and (std.ascii.isAlphanumeric(text[at - 1]) or text[at - 1] == '_');
    const after = at + len;
    const after_word = after < text.len and (std.ascii.isAlphanumeric(text[after]) or text[after] == '_');
    return !before_word and !after_word;
}

fn commentLine(raw: []const u8, at: usize) []const u8 {
    std.debug.assert(at < raw.len);
    std.debug.assert(raw.len > 0);
    const lo = if (std.mem.lastIndexOfScalar(u8, raw[0..at], '\n')) |p| p + 1 else 0;
    const hi = if (std.mem.indexOfScalar(u8, raw[at..], '\n')) |p| at + p else raw.len;
    return std.mem.trim(u8, raw[lo..hi], " \t\r/*#-!");
}

fn todoLessThan(idx: *const Index, a: TodoSite, b: TodoSite) bool {
    const order = std.mem.order(u8, idx.graph.files[a.file].path, idx.graph.files[b.file].path);
    if (order != .eq) return order == .lt;
    if (a.line != b.line) return a.line < b.line;
    return std.mem.lessThan(u8, a.marker, b.marker);
}

fn todosJson(w: *Writer, idx: *const Index, sites: []const TodoSite, opts: query.Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(sites.len <= std.math.maxInt(u32));
    try w.writeByte('[');
    var page = Page{ .skipped = 0 };
    for (sites, 0..) |site, ordinal| {
        if (!page.accepts(@intCast(ordinal), 96, opts)) continue;
        if (page.emitted > 1) try w.writeByte(',');
        try todoObject(w, idx, site);
    }
    try w.writeAll("]\n");
    return page.emitted != 0;
}

fn todosJsonl(w: *Writer, idx: *const Index, sites: []const TodoSite, opts: query.Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(sites.len <= std.math.maxInt(u32));
    var page = Page{ .skipped = opts.after };
    var last = opts.after;
    for (sites, 0..) |site, ordinal| {
        if (!page.accepts(@intCast(ordinal), 96, opts)) continue;
        last = @intCast(ordinal + 1);
        try w.print("{{\"cursor\":\"v1:{}\",\"item\":", .{last});
        try todoObject(w, idx, site);
        try w.writeAll("}\n");
    }
    try w.print("{{\"page\":{{\"count\":{},\"total\":{},\"has_more\":{},\"next\":", .{ page.emitted, sites.len, last < sites.len });
    if (last < sites.len) try w.print("\"v1:{}\"", .{last}) else try w.writeAll("null");
    try w.writeAll("}}\n");
    return page.emitted != 0;
}

fn todoObject(w: *Writer, idx: *const Index, site: TodoSite) !void {
    std.debug.assert(site.file < idx.graph.files.len);
    std.debug.assert(site.line > 0);
    try w.writeAll("{\"file\":");
    try json_out.writeString(w, idx.graph.files[site.file].path);
    try w.print(",\"line\":{},\"marker\":", .{site.line});
    try json_out.writeString(w, site.marker);
    try w.writeAll(",\"text\":");
    try json_out.writeString(w, site.text);
    try w.writeByte('}');
}

const EditKind = enum { definition, reference };

const EditSite = struct {
    file: model.FileId,
    start: u32,
    end: u32,
    line: u32,
    owner: SymbolId,
    kind: EditKind,
};

const RenamePlan = struct {
    gpa: std.mem.Allocator,
    target: SymbolId,
    sites: []EditSite,
    collisions: []SymbolId,
    review_sites: u32,

    fn deinit(self: *RenamePlan) void {
        self.gpa.free(self.sites);
        self.gpa.free(self.collisions);
        self.* = undefined;
    }

    fn safe(self: RenamePlan) bool {
        return self.sites.len > 0 and self.collisions.len == 0 and self.review_sites == 0;
    }
};

pub fn edits(w: *Writer, idx: *const Index, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const target = try resolveRenameTarget(w, idx, selector, opts) orelse return false;
    var plan = try buildRenamePlan(idx, target, "");
    defer plan.deinit();
    if (opts.format == .jsonl) return editSitesJsonl(w, idx, plan, opts);
    if (opts.format == .json) return editSitesJson(w, idx, plan);
    try renderEditSites(w, idx, plan);
    return plan.sites.len != 0;
}

pub fn rename(w: *Writer, io: std.Io, idx: *const Index, root: []const u8, selector: []const u8, new_name: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(new_name.len > 0);
    if (!validIdentifier(new_name)) {
        try w.print("navgraph: invalid rename target '{s}' (expected an identifier)\n", .{new_name});
        return false;
    }
    const target = try resolveRenameTarget(w, idx, selector, opts) orelse return false;
    if (std.mem.eql(u8, idx.graph.symbols[target].name, new_name)) {
        try w.print("navgraph: '{s}' already has that name\n", .{selector});
        return false;
    }
    var plan = try buildRenamePlan(idx, target, new_name);
    defer plan.deinit();
    if (opts.format == .json or opts.format == .jsonl) {
        const applied = !opts.preview and plan.safe();
        if (applied) try applyRename(io, idx, root, plan.sites, new_name);
        return renameJson(w, idx, plan, new_name, opts.preview, applied);
    }
    try renderRenameWarnings(w, idx, plan, new_name);
    if (opts.preview or !plan.safe()) {
        try renderPatch(w, idx, plan.sites, new_name);
        return plan.safe();
    }
    try applyRename(io, idx, root, plan.sites, new_name);
    try w.print("renamed {s} → {s} at {} sites across {} files\n", .{ selector, new_name, plan.sites.len, distinctFileCount(plan.sites) });
    return true;
}

fn resolveRenameTarget(w: *Writer, idx: *const Index, selector: []const u8, opts: query.Options) !?SymbolId {
    std.debug.assert(selector.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    if (std.mem.indexOfAny(u8, selector, "*,") != null) {
        try w.writeAll("navgraph: rename requires one non-glob selector; pin with Parent.name or name@path\n");
        return null;
    }
    const ids = try resolveRoots(idx, selector);
    defer idx.gpa.free(ids);
    if (ids.len != 1 or !renameSelectorExact(idx, selector, if (ids.len == 1) ids[0] else invalid)) {
        if (opts.format == .json or opts.format == .jsonl) try w.writeAll("{\"error\":\"ambiguous_selector\"}\n") else try w.print("navgraph: rename selector '{s}' resolves to {} definitions; pin with Parent.name or name@path\n", .{ selector, ids.len });
        return null;
    }
    return ids[0];
}

fn renameSelectorExact(idx: *const Index, selector: []const u8, id: SymbolId) bool {
    if (id == invalid) return false;
    const bare = if (std.mem.lastIndexOfScalar(u8, selector, '@')) |at| selector[0..at] else selector;
    const dot = std.mem.lastIndexOfScalar(u8, bare, '.') orelse return true;
    const sym = idx.graph.symbols[id];
    if (sym.parent == invalid) return false;
    return std.mem.eql(u8, idx.graph.symbols[sym.parent].name, bare[0..dot]) and
        std.mem.eql(u8, sym.name, bare[dot + 1 ..]);
}

fn buildRenamePlan(idx: *const Index, target: SymbolId, new_name: []const u8) !RenamePlan {
    std.debug.assert(target < idx.graph.symbols.len);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var targets: std.ArrayList(SymbolId) = .empty;
    defer targets.deinit(idx.gpa);
    try targets.append(idx.gpa, target);
    try addExactImplementationPeers(idx, &targets);
    var sites: std.ArrayList(EditSite) = .empty;
    defer sites.deinit(idx.gpa);
    for (targets.items) |id| if (try definitionSite(idx, id)) |site| try appendEdit(idx.gpa, &sites, site);
    var review_sites: u32 = 0;
    for (idx.graph.symbols) |owner| collectReferenceSites(idx, owner, targets.items, &sites, &review_sites) catch |err| return err;
    std.sort.block(EditSite, sites.items, idx, editLessThan);
    const collisions = if (new_name.len == 0) try idx.gpa.alloc(SymbolId, 0) else try collectRenameCollisions(idx, targets.items, sites.items, new_name);
    return .{ .gpa = idx.gpa, .target = target, .sites = try sites.toOwnedSlice(idx.gpa), .collisions = collisions, .review_sites = review_sites };
}

fn addExactImplementationPeers(idx: *const Index, targets: *std.ArrayList(SymbolId)) !void {
    std.debug.assert(targets.items.len > 0);
    std.debug.assert(targets.items.len <= idx.graph.symbols.len);
    if (idx.graph.symbols[targets.items[0]].kind != .method) return;
    var graph = try impls_mod.build(idx.gpa, idx);
    defer graph.deinit();
    var cursor: usize = 0;
    while (cursor < targets.items.len) : (cursor += 1) {
        const id = targets.items[cursor];
        for (graph.edges) |edge| {
            if (!edge.exact) continue;
            if (edge.port_method == id) try appendUnique(idx.gpa, targets, edge.implementation_method);
            if (edge.implementation_method == id) try appendUnique(idx.gpa, targets, edge.port_method);
        }
    }
}

fn definitionSite(idx: *const Index, id: SymbolId) !?EditSite {
    std.debug.assert(id < idx.graph.symbols.len);
    const sym = idx.graph.symbols[id];
    const file = idx.graph.files[sym.file];
    std.debug.assert(sym.span_start <= sym.sig_end and sym.sig_end <= file.text.len);
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(idx.gpa);
    try lexer.tokenize(idx.gpa, file.text, language.configFor(file.language), &toks);
    for (toks.items) |tok| {
        if (tok.start < sym.span_start or tok.end > sym.sig_end or tok.kind != .identifier) continue;
        if (!std.mem.eql(u8, tok.text(file.text), sym.name)) continue;
        return .{ .file = sym.file, .start = tok.start, .end = tok.end, .line = tok.line, .owner = id, .kind = .definition };
    }
    return null;
}

fn collectReferenceSites(idx: *const Index, owner: model.Symbol, targets: []const SymbolId, sites: *std.ArrayList(EditSite), review_sites: *u32) !void {
    std.debug.assert(owner.id < idx.graph.symbols.len);
    std.debug.assert(targets.len > 0);
    const source = idx.graph.files[owner.file].text;
    for (owner.refs) |ref| {
        if (!idIn(targets, ref.target)) continue;
        if (!ref.exact) {
            review_sites.* +|= @intCast(@max(ref.offsets.len, 1));
            continue;
        }
        for (ref.offsets) |offset| {
            const end = offset + @as(u32, @intCast(ref.name.len));
            if (end > source.len or !std.mem.eql(u8, source[offset..end], ref.name)) {
                review_sites.* +|= 1;
                continue;
            }
            try appendEdit(idx.gpa, sites, .{ .file = owner.file, .start = offset, .end = end, .line = lineAt(source, offset), .owner = owner.id, .kind = .reference });
        }
    }
}

fn collectRenameCollisions(idx: *const Index, targets: []const SymbolId, sites: []const EditSite, new_name: []const u8) ![]SymbolId {
    std.debug.assert(targets.len > 0);
    std.debug.assert(new_name.len > 0);
    var collisions: std.ArrayList(SymbolId) = .empty;
    defer collisions.deinit(idx.gpa);
    for (targets) |target| {
        const sym = idx.graph.symbols[target];
        for (idx.lookup(new_name)) |other_id| {
            if (idIn(targets, other_id)) continue;
            const other = idx.graph.symbols[other_id];
            const same_scope = if (sym.parent != invalid) other.parent == sym.parent else other.parent == invalid and other.file == sym.file;
            if (same_scope) try appendUnique(idx.gpa, &collisions, other_id);
        }
    }
    for (sites) |site| {
        if (site.kind != .reference) continue;
        for (idx.graph.symbols[site.owner].bindings) |binding| {
            if (std.mem.eql(u8, binding.name, new_name)) try appendUnique(idx.gpa, &collisions, site.owner);
        }
    }
    return collisions.toOwnedSlice(idx.gpa);
}

fn appendEdit(gpa: std.mem.Allocator, sites: *std.ArrayList(EditSite), site: EditSite) !void {
    std.debug.assert(site.start < site.end);
    std.debug.assert(site.line > 0);
    for (sites.items) |existing| if (existing.file == site.file and existing.start == site.start) return;
    try sites.append(gpa, site);
}

fn idIn(ids: []const SymbolId, id: SymbolId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

fn editLessThan(idx: *const Index, a: EditSite, b: EditSite) bool {
    const order = std.mem.order(u8, idx.graph.files[a.file].path, idx.graph.files[b.file].path);
    if (order != .eq) return order == .lt;
    if (a.start != b.start) return a.start < b.start;
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

fn lineAt(source: []const u8, offset: u32) u32 {
    std.debug.assert(offset < source.len);
    std.debug.assert(source.len <= std.math.maxInt(u32));
    return 1 + @as(u32, @intCast(std.mem.count(u8, source[0..offset], "\n")));
}

fn validIdentifier(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn renderEditSites(w: *Writer, idx: *const Index, plan: RenamePlan) !void {
    std.debug.assert(plan.target < idx.graph.symbols.len);
    std.debug.assert(plan.sites.len > 0 or plan.review_sites > 0);
    for (plan.sites) |site| {
        const owner = idx.graph.symbols[site.owner];
        try w.print("{s}:{}:{}  {s}", .{ idx.graph.files[site.file].path, site.line, columnAt(idx.graph.files[site.file].text, site.start), @tagName(site.kind) });
        if (site.kind == .reference) try w.print("  in {s}", .{owner.name});
        try w.writeByte('\n');
    }
    if (plan.review_sites != 0) try w.print("! {} heuristic/unrecoverable sites require review\n", .{plan.review_sites});
}

fn columnAt(source: []const u8, offset: u32) u32 {
    std.debug.assert(offset < source.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |at| at + 1 else 0;
    return @intCast(offset - line_start + 1);
}

fn renderRenameWarnings(w: *Writer, idx: *const Index, plan: RenamePlan, new_name: []const u8) !void {
    std.debug.assert(new_name.len > 0);
    std.debug.assert(plan.target < idx.graph.symbols.len);
    for (plan.collisions) |id| {
        const sym = idx.graph.symbols[id];
        try w.print("! collision: {s} already exists at {s}:{}\n", .{ new_name, idx.graph.files[sym.file].path, sym.line });
    }
    if (plan.review_sites != 0) try w.print("! unsafe: {} heuristic/unrecoverable references require review\n", .{plan.review_sites});
    if (!plan.safe()) try w.writeAll("! rename not applied; resolve collisions/review sites first\n");
}

fn renderPatch(w: *Writer, idx: *const Index, sites: []const EditSite, new_name: []const u8) !void {
    std.debug.assert(new_name.len > 0);
    std.debug.assert(sites.len > 0);
    var start: usize = 0;
    while (start < sites.len) {
        const file_id = sites[start].file;
        var end = start + 1;
        while (end < sites.len and sites[end].file == file_id) : (end += 1) {}
        try renderFilePatch(w, idx.graph.files[file_id], sites[start..end], new_name);
        start = end;
    }
}

fn renderFilePatch(w: *Writer, file: model.SourceFile, sites: []const EditSite, new_name: []const u8) !void {
    std.debug.assert(sites.len > 0);
    std.debug.assert(new_name.len > 0);
    try w.print("--- a/{s}\n+++ b/{s}\n", .{ file.path, file.path });
    var cursor: usize = 0;
    while (cursor < sites.len) {
        const line = sites[cursor].line;
        var end = cursor + 1;
        while (end < sites.len and sites[end].line == line) : (end += 1) {}
        const bounds = lineBounds(file.text, sites[cursor].start);
        const replacement = try replaceRange(file.text[bounds.lo..bounds.hi], sites[cursor..end], bounds.lo, new_name, std.heap.page_allocator);
        defer std.heap.page_allocator.free(replacement);
        try w.print("@@ -{},1 +{},1 @@\n-{s}\n+{s}\n", .{ line, line, file.text[bounds.lo..bounds.hi], replacement });
        cursor = end;
    }
}

const Bounds = struct { lo: u32, hi: u32 };

fn lineBounds(source: []const u8, offset: u32) Bounds {
    std.debug.assert(offset < source.len);
    const lo: u32 = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |at| @intCast(at + 1) else 0;
    const hi: u32 = if (std.mem.indexOfScalar(u8, source[offset..], '\n')) |at| offset + @as(u32, @intCast(at)) else @intCast(source.len);
    return .{ .lo = lo, .hi = hi };
}

fn replaceRange(source: []const u8, sites: []const EditSite, base: u32, new_name: []const u8, gpa: std.mem.Allocator) ![]u8 {
    std.debug.assert(sites.len > 0);
    std.debug.assert(new_name.len > 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var cursor: u32 = 0;
    for (sites) |site| {
        const lo = site.start - base;
        const hi = site.end - base;
        std.debug.assert(cursor <= lo and hi <= source.len);
        try out.appendSlice(gpa, source[cursor..lo]);
        try out.appendSlice(gpa, new_name);
        cursor = hi;
    }
    try out.appendSlice(gpa, source[cursor..]);
    return out.toOwnedSlice(gpa);
}

fn applyRename(io: std.Io, idx: *const Index, root: []const u8, sites: []const EditSite, new_name: []const u8) !void {
    std.debug.assert(root.len > 0);
    std.debug.assert(sites.len > 0);
    var dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch |err| dir: {
        if (err != error.NotDir) return err;
        const parent = std.fs.path.dirname(root) orelse ".";
        break :dir try std.Io.Dir.cwd().openDir(io, parent, .{});
    };
    defer dir.close(io);
    var start: usize = 0;
    while (start < sites.len) {
        const file = idx.graph.files[sites[start].file];
        var end = start + 1;
        while (end < sites.len and sites[end].file == file.id) : (end += 1) {}
        const replacement = try replaceRange(file.text, sites[start..end], 0, new_name, idx.gpa);
        defer idx.gpa.free(replacement);
        try dir.writeFile(io, .{ .sub_path = file.path, .data = replacement });
        start = end;
    }
}

fn distinctFileCount(sites: []const EditSite) usize {
    if (sites.len == 0) return 0;
    var count: usize = 1;
    for (sites[1..], 1..) |site, i| if (site.file != sites[i - 1].file) {
        count += 1;
    };
    return count;
}

fn editSitesJson(w: *Writer, idx: *const Index, plan: RenamePlan) !bool {
    std.debug.assert(plan.target < idx.graph.symbols.len);
    std.debug.assert(plan.sites.len > 0 or plan.review_sites > 0);
    try w.writeAll("{\"target\":");
    try json_out.symbolObject(w, idx, idx.graph.symbols[plan.target], .names);
    try w.writeAll(",\"sites\":[");
    for (plan.sites, 0..) |site, i| {
        if (i != 0) try w.writeByte(',');
        try editSiteObject(w, idx, site);
    }
    try w.print("],\"review_sites\":{}}}\n", .{plan.review_sites});
    return plan.sites.len != 0;
}

fn editSitesJsonl(w: *Writer, idx: *const Index, plan: RenamePlan, opts: query.Options) !bool {
    std.debug.assert(plan.target < idx.graph.symbols.len);
    std.debug.assert(opts.limit > 0);
    var page = Page{ .skipped = opts.after };
    var last = opts.after;
    for (plan.sites, 0..) |site, ordinal| {
        if (!page.accepts(@intCast(ordinal), 96, opts)) continue;
        last = @intCast(ordinal + 1);
        try w.print("{{\"cursor\":\"v1:{}\",\"item\":", .{last});
        try editSiteObject(w, idx, site);
        try w.writeAll("}\n");
    }
    try w.print("{{\"page\":{{\"count\":{},\"total\":{},\"has_more\":{},\"next\":", .{ page.emitted, plan.sites.len, last < plan.sites.len });
    if (last < plan.sites.len) try w.print("\"v1:{}\"", .{last}) else try w.writeAll("null");
    try w.writeAll("}}\n");
    return page.emitted != 0;
}

fn editSiteObject(w: *Writer, idx: *const Index, site: EditSite) !void {
    std.debug.assert(site.file < idx.graph.files.len);
    std.debug.assert(site.owner < idx.graph.symbols.len);
    try w.writeAll("{\"file\":");
    try json_out.writeString(w, idx.graph.files[site.file].path);
    try w.print(",\"line\":{},\"column\":{},\"start\":{},\"end\":{},\"kind\":", .{ site.line, columnAt(idx.graph.files[site.file].text, site.start), site.start, site.end });
    try json_out.writeString(w, @tagName(site.kind));
    try w.writeAll(",\"in\":");
    try json_out.writeString(w, idx.graph.symbols[site.owner].name);
    // `RenamePlan.sites` contains only definition spans and references proven
    // exact by the resolver. Heuristic/unrecoverable occurrences are excluded
    // and counted separately as `review_sites`; make that split explicit on
    // every returned span so an editing agent never has to infer safety.
    try w.writeAll(",\"exact\":true,\"editable\":true,\"provenance\":");
    try json_out.writeString(w, if (site.kind == .definition) "indexed_definition" else "resolved_reference");
    try w.writeByte('}');
}

fn renameJson(w: *Writer, idx: *const Index, plan: RenamePlan, new_name: []const u8, preview: bool, applied: bool) !bool {
    std.debug.assert(new_name.len > 0);
    std.debug.assert(plan.target < idx.graph.symbols.len);
    try w.writeAll("{\"target\":");
    try json_out.symbolObject(w, idx, idx.graph.symbols[plan.target], .names);
    try w.writeAll(",\"new_name\":");
    try json_out.writeString(w, new_name);
    try w.print(",\"preview\":{},\"applied\":{},\"safe\":{},\"review_sites\":{},\"collisions\":[", .{ preview, applied, plan.safe(), plan.review_sites });
    for (plan.collisions, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try json_out.symbolObject(w, idx, idx.graph.symbols[id], .names);
    }
    try w.writeAll("],\"edits\":[");
    for (plan.sites, 0..) |site, i| {
        if (i != 0) try w.writeByte(',');
        try editSiteObject(w, idx, site);
    }
    try w.writeAll("]}\n");
    return plan.safe();
}

test "todo marker matching chooses the earliest marker" {
    const testing = std.testing;
    const hit = nextTodo("// HACK then TODO", 0).?;
    try testing.expectEqualStrings("HACK", hit.marker);
    try testing.expectEqual(@as(usize, 3), hit.at);
    try testing.expect(nextTodo("// TODOO myHACKish", 0) == null);
    try testing.expectEqual(@as(usize, 10), nextTodo("// TODOO; TODO: valid", 0).?.at);
}

test "comment line isolates the marker line" {
    const testing = std.testing;
    const raw = "/* first\n * TODO repair this\n */";
    const at = std.mem.indexOf(u8, raw, "TODO").?;
    try testing.expectEqualStrings("TODO repair this", commentLine(raw, at));
    try testing.expect(at < raw.len);
}
