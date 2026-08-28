//! Query adapters: turn an editor request into an answer from the live graph.
//!
//! Nothing here re-implements navgraph's semantics. Name resolution, edge
//! confidence, call-site lines, test classification and dead-read filtering all
//! come from `query.zig`; this module only walks and serializes.

const std = @import("std");
const index_mod = @import("../index.zig");
const model = @import("../model.zig");
const query = @import("../query.zig");
const render = @import("../render.zig");
const gitdiff = @import("../gitdiff.zig");
const viz = @import("../viz.zig");
const hierarchy = @import("../hierarchy.zig");
const impls = @import("../impls.zig");
const fswrite = @import("fswrite.zig");
const overlay = @import("overlay.zig");
const payload = @import("payload.zig");
const position = @import("position.zig");
const search = @import("search.zig");
const session_mod = @import("session.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const Symbol = model.Symbol;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;
const Ctx = payload.Ctx;

/// `GitFailed`: a `{ref}` target's `git diff` did not run, or produced a patch
/// the parser cannot use. Either way it is a real failure, never reported to
/// the editor as "nothing changed"; the cause travels in `detail.*`.
pub const Error = error{ SymbolNotFound, FileNotIndexed, GitFailed } || std.mem.Allocator.Error;

/// The contract's `Scope`, defaulted from `initializationOptions`.
pub const Scope = struct {
    strict: bool,
    tests: query.TestScope,

    pub fn fromConfig(cfg: session_mod.Config) Scope {
        return .{ .strict = cfg.strict, .tests = cfg.tests };
    }

    pub fn admits(self: Scope, idx: *const Index, sym: Symbol) bool {
        return switch (self.tests) {
            .with => true,
            .without => !query.isTestSymbol(idx, sym),
            .only => query.isTestSymbol(idx, sym),
        };
    }
};

// ---------------------------------------------------------------------------
// Position → symbol
// ---------------------------------------------------------------------------

/// The innermost definition whose span contains `offset`, or null.
pub fn enclosingSymbol(idx: *const Index, file: model.SourceFile, offset: usize) ?Symbol {
    var best: ?Symbol = null;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (offset < sym.span_start or offset >= sym.span_end) continue;
        const span = sym.span_end - sym.span_start;
        if (best == null or span < best.?.span_end - best.?.span_start) best = sym;
    }
    return best;
}

/// What sits under a cursor: the word, the definition it denotes, the definition
/// containing it, and the same-named definitions that were not chosen.
pub const Located = struct {
    word: []const u8,
    symbol: SymbolId,
    enclosing: SymbolId,
    /// Same-name definitions other than `symbol`, in graph order.
    candidates: []const SymbolId,
    /// Byte range of `word` in its file's text (`symbolAt.range`).
    start: usize,
    end: usize,
};

/// Resolve the identifier at `offset` in `path`.
///
/// Resolution order is the graph's own: if the cursor sits on a definition's
/// name, that definition wins; otherwise the enclosing body's already-resolved
/// reference for that name on that line wins (receiver- and import-aware, exact
/// edges preferred); only then does it fall back to a name lookup.
pub fn locate(
    gpa: std.mem.Allocator,
    ctx: Ctx,
    path: []const u8,
    offset: usize,
) Error!?Located {
    const idx = ctx.index();
    const file_id = fileIdOf(idx, path) orelse return null;
    const file = idx.graph.files[file_id];
    const ident = position.identifierAt(file.text, offset) orelse return null;

    const enclosing = enclosingSymbol(idx, file, ident.start);
    const enclosing_id = if (enclosing) |e| e.id else invalid;
    const line = position.positionAt(file.text, ident.start, .utf8).line + 1;

    var chosen: SymbolId = invalid;
    // The cursor is on a definition's own name.
    if (enclosing) |e| {
        if (std.mem.eql(u8, e.name, ident.name) and ident.start < e.sig_end) chosen = e.id;
    }
    if (chosen == invalid) chosen = referencedTarget(enclosing, ident.name, ident.qualifier, line);
    if (chosen == invalid) chosen = byName(idx, file_id, ident.name);

    var others: std.ArrayList(SymbolId) = .empty;
    errdefer others.deinit(gpa);
    for (idx.lookup(ident.name)) |id| {
        if (id != chosen) try others.append(gpa, id);
    }
    return .{
        .word = ident.name,
        .symbol = chosen,
        .enclosing = enclosing_id,
        .candidates = try others.toOwnedSlice(gpa),
        .start = ident.start,
        .end = ident.end,
    };
}

/// The enclosing chain of `id`, outermost first, innermost (`id` itself)
/// last — `symbolAt.breadcrumbs` / `navgraph/where.breadcrumbs`. Empty when
/// `id` is `invalid_symbol`.
pub fn breadcrumbChain(idx: *const Index, gpa: std.mem.Allocator, id: SymbolId) ![]const SymbolId {
    var chain: std.ArrayList(SymbolId) = .empty;
    errdefer chain.deinit(gpa);
    var cur = id;
    while (cur != invalid) {
        try chain.append(gpa, cur);
        cur = idx.graph.symbols[cur].parent;
    }
    std.mem.reverse(SymbolId, chain.items);
    return chain.toOwnedSlice(gpa);
}

/// `navgraph/where`: the symbol enclosing 1-based `line` of `path` (stack
/// traces and diff hunks are 1-based, unlike an LSP position) and its
/// breadcrumb chain. `enclosing` is `null` — never an error — for a line with
/// no enclosing definition (file scope, or a file outside the index).
pub fn writeWhere(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, path: []const u8, line: u32) !void {
    const idx = ctx.index();
    const file_id = fileIdOf(idx, path) orelse {
        try w.writeAll("{\"enclosing\":null,\"breadcrumbs\":[],\"file\":");
        try payload.writeString(w, path);
        try w.writeByte('}');
        return;
    };
    const file = idx.graph.files[file_id];
    const offset = position.lineStart(file.text, if (line == 0) 0 else line - 1) orelse file.text.len;
    const enclosing = enclosingSymbol(idx, file, offset);
    const enclosing_id = if (enclosing) |e| e.id else invalid;

    try w.writeAll("{\"enclosing\":");
    if (enclosing) |e| try payload.writeSymbol(w, ctx, e) else try w.writeAll("null");
    try w.writeAll(",\"breadcrumbs\":");
    const chain = try breadcrumbChain(idx, gpa, enclosing_id);
    defer gpa.free(chain);
    try payload.writeSymbolArray(w, ctx, chain);
    try w.writeAll(",\"file\":");
    try payload.writeString(w, file.path);
    try w.writeByte('}');
}

/// The already-resolved target of a reference to `name` from `from`'s body.
/// Prefers a reference on the cursor's own line and a matching receiver, so a
/// name used several times in one body resolves at the right site.
fn referencedTarget(from: ?Symbol, name: []const u8, qualifier: []const u8, line: u32) SymbolId {
    const sym = from orelse return invalid;
    var fallback: SymbolId = invalid;
    for (sym.refs) |ref| {
        if (!std.mem.eql(u8, ref.name, name)) continue;
        if (ref.target == invalid) continue;
        if (fallback == invalid) fallback = ref.target;
        if (qualifier.len != 0 and !std.mem.eql(u8, ref.qualifier, qualifier)) continue;
        if (refOnLine(ref, line)) return ref.target;
    }
    return fallback;
}

fn refOnLine(ref: model.Reference, line: u32) bool {
    if (ref.line == line) return true;
    for (ref.lines) |ln| if (ln == line) return true;
    return false;
}

/// Fall back to a name lookup, preferring a definition in the cursor's own file.
fn byName(idx: *const Index, file_id: model.FileId, name: []const u8) SymbolId {
    const ids = idx.lookup(name);
    if (ids.len == 0) return invalid;
    for (ids) |id| if (idx.graph.symbols[id].file == file_id) return id;
    return ids[0];
}

pub fn fileIdOf(idx: *const Index, path: []const u8) ?model.FileId {
    for (idx.graph.files) |f| {
        if (std.mem.eql(u8, f.path, path)) return f.id;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

/// The contract's `Target`, plus the `file` and `ref` forms `blast` accepts.
pub const Target = union(enum) {
    /// A cursor: a root-relative path and a byte offset into its text.
    at: struct { path: []const u8, offset: usize },
    /// `name` or `Parent.name`, resolved like every CLI name argument.
    symbol: []const u8,
    /// Every definition in one file.
    file: []const u8,
    /// Every definition changed since a git ref, plus every unsaved edit.
    git_ref: []const u8,

    /// A human description for the `symbol not found` error.
    pub fn describe(self: Target) []const u8 {
        return switch (self) {
            .at => |a| a.path,
            .symbol => |s| s,
            .file => |f| f,
            .git_ref => |r| r,
        };
    }
};

/// Resolve a target to the definitions it names. Never returns an empty slice —
/// a target that resolves to nothing is `error.SymbolNotFound`, which the
/// dispatcher turns into the contract's `-32001`. A `{ref}` target that git
/// rejects (a bad ref, no git tree, git unavailable) is `error.GitFailed`,
/// with `detail.*` set to the cause.
pub fn resolveTarget(
    gpa: std.mem.Allocator,
    ctx: Ctx,
    target: Target,
    detail: *?[]const u8,
) Error![]SymbolId {
    var out: std.ArrayList(SymbolId) = .empty;
    errdefer out.deinit(gpa);
    switch (target) {
        .at => |a| {
            const located = (try locate(gpa, ctx, a.path, a.offset)) orelse return error.SymbolNotFound;
            defer gpa.free(located.candidates);
            if (located.symbol == invalid) return error.SymbolNotFound;
            try out.append(gpa, located.symbol);
        },
        .symbol => |name| {
            var buf: [64]SymbolId = undefined;
            for (query.resolveIds(ctx.index(), name, &buf)) |id| try out.append(gpa, id);
        },
        .file => |path| try fileDefinitions(gpa, ctx.index(), path, &out),
        .git_ref => |spec| try changedSince(gpa, ctx, spec, &out, detail),
    }
    if (out.items.len == 0) return error.SymbolNotFound;
    return out.toOwnedSlice(gpa);
}

fn fileDefinitions(
    gpa: std.mem.Allocator,
    idx: *const Index,
    path: []const u8,
    out: *std.ArrayList(SymbolId),
) Error!void {
    const file_id = fileIdOf(idx, path) orelse return error.FileNotIndexed;
    const file = idx.graph.files[file_id];
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        if (!reportable(idx.graph.symbols[i].kind)) continue;
        try out.append(gpa, i);
    }
}

/// Whether a symbol is a definition the protocol reports. Import records and
/// router-mount directives are index bookkeeping the CLI hides too.
fn reportable(kind: model.SymbolKind) bool {
    return kind != .import and kind != .route_mount;
}

/// The first line of `text`, capped at `max_len` bytes. A non-git root makes
/// `git diff --no-index` write its whole ~5 KB usage dump to stderr; relaying
/// that verbatim into a JSON-RPC error an editor pops up is a bad experience
/// for one useful line, so keep the diagnostic and drop the manual (merge-gate
/// review F3).
fn firstLineCapped(text: []const u8, max_len: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \n\r\t");
    const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return trimmed[0..@min(line_end, max_len)];
}

/// Definitions touched since `spec` (`navgraph diff`'s rule) plus every
/// definition in a file whose unsaved buffer differs from the copy on disk.
/// A git failure — a bad ref, no git tree, git unavailable — is
/// `error.GitFailed` with `detail.*` set to the cause, distinct from a clean
/// tree (no error, an empty `out`): a failed lookup must never look like a
/// routine "nothing changed" answer (coldstart review F2).
fn changedSince(
    gpa: std.mem.Allocator,
    ctx: Ctx,
    spec: []const u8,
    out: *std.ArrayList(SymbolId),
    detail: *?[]const u8,
) Error!void {
    const s = ctx.session;
    const idx = &s.idx;
    const ref = if (spec.len != 0) spec else "HEAD";

    const result = query.runGitDiff(gpa, s.io, s.root_path, ref) catch |err| {
        detail.* = try std.fmt.allocPrint(gpa, "git diff {s} failed: {s}", .{ ref, @errorName(err) });
        return error.GitFailed;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        detail.* = try std.fmt.allocPrint(gpa, "git diff {s} failed: {s}", .{
            ref, firstLineCapped(result.stderr, 300),
        });
        return error.GitFailed;
    }
    const changes = gitdiff.parse(gpa, result.stdout) catch |err| {
        detail.* = try std.fmt.allocPrint(gpa, "git diff {s} produced an unusable patch: {s}", .{ ref, @errorName(err) });
        return error.GitFailed;
    };
    defer gitdiff.freeChanges(gpa, changes);
    for (changes) |change| {
        const file = query.findDiffFile(idx, change.path) orelse continue;
        var i = file.sym_start;
        while (i < file.sym_end) : (i += 1) {
            const sym = idx.graph.symbols[i];
            if (!reportable(sym.kind)) continue;
            if (query.symbolTouched(sym, file.text, change.ranges)) try out.append(gpa, sym.id);
        }
    }

    for (s.overlays.docs.keys(), s.overlays.docs.values()) |path, text| {
        if (!try overlayDiffers(gpa, s, path, text)) continue;
        const file_id = fileIdOf(idx, path) orelse continue;
        const file = idx.graph.files[file_id];
        var i = file.sym_start;
        while (i < file.sym_end) : (i += 1) {
            const sym = idx.graph.symbols[i];
            if (!reportable(sym.kind)) continue;
            if (!contains(out.items, sym.id)) try out.append(gpa, sym.id);
        }
    }
}

fn overlayDiffers(
    gpa: std.mem.Allocator,
    s: *session_mod.Session,
    path: []const u8,
    text: []const u8,
) !bool {
    const on_disk = s.root_dir.readFileAlloc(s.io, path, gpa, .limited(8 * 1024 * 1024)) catch return true;
    defer gpa.free(on_disk);
    return !std.mem.eql(u8, on_disk, text);
}

fn contains(ids: []const SymbolId, id: SymbolId) bool {
    return std.mem.indexOfScalar(SymbolId, ids, id) != null;
}

// ---------------------------------------------------------------------------
// Blast radius
// ---------------------------------------------------------------------------

pub const Direction = enum { callers, callees };

pub const BlastOptions = struct {
    depth: u32,
    direction: Direction,
    limit: u32,
    scope: Scope,
};

const BlastNode = struct {
    id: SymbolId,
    depth: u32,
    exact: bool,
    via: std.ArrayList(SymbolId),
};

const BlastEdge = struct {
    from: SymbolId,
    to: SymbolId,
    exact: bool,
    lines: []const u32,
};

const BlastResult = struct {
    nodes: std.ArrayList(BlastNode),
    edges: std.ArrayList(BlastEdge),
    truncated: bool,

    fn deinit(self: *BlastResult, gpa: std.mem.Allocator) void {
        for (self.nodes.items) |*n| n.via.deinit(gpa);
        self.nodes.deinit(gpa);
        for (self.edges.items) |e| gpa.free(e.lines);
        self.edges.deinit(gpa);
    }
};

/// Walk the graph from `roots` — the shared BFS behind `writeBlast` and
/// `writeImpact`, which each format the result into a different envelope.
/// Each symbol appears once, at the shallowest depth it was reached; `via`
/// records the depth-1 neighbours it was reached through. Edges are always
/// caller→callee whichever direction the walk ran.
fn computeBlast(
    gpa: std.mem.Allocator,
    ctx: Ctx,
    roots: []const SymbolId,
    opts: BlastOptions,
) !BlastResult {
    const idx = ctx.index();
    var nodes: std.ArrayList(BlastNode) = .empty;
    errdefer {
        for (nodes.items) |*n| n.via.deinit(gpa);
        nodes.deinit(gpa);
    }
    var seen: std.AutoHashMapUnmanaged(SymbolId, usize) = .empty;
    defer seen.deinit(gpa);
    var edges: std.ArrayList(BlastEdge) = .empty;
    errdefer {
        for (edges.items) |e| gpa.free(e.lines);
        edges.deinit(gpa);
    }
    var edge_seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer edge_seen.deinit(gpa);
    // `query.callSiteLines` grows its output with the index's own allocator, so
    // this scratch list must be freed with that one, not the request arena.
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);

    var truncated = false;
    for (roots) |id| {
        if (seen.contains(id)) continue;
        if (nodes.items.len >= opts.limit) {
            truncated = true;
            break;
        }
        try seen.put(gpa, id, nodes.items.len);
        try nodes.append(gpa, .{ .id = id, .depth = 0, .exact = true, .via = .empty });
    }

    // Breadth-first: `nodes` doubles as the queue, so a node is expanded once.
    var cursor: usize = 0;
    while (cursor < nodes.items.len) : (cursor += 1) {
        const depth = nodes.items[cursor].depth;
        const from_id = nodes.items[cursor].id;
        if (depth >= opts.depth) continue;
        var neighbours = Neighbours.init(idx, from_id, opts.direction, false);
        while (neighbours.next()) |n| {
            const sym = idx.graph.symbols[n.id];
            if (opts.scope.strict and !n.exact) continue;
            if (!opts.scope.admits(idx, sym)) continue;

            const gop = try seen.getOrPut(gpa, n.id);
            if (!gop.found_existing) {
                if (nodes.items.len >= opts.limit) {
                    truncated = true;
                    _ = seen.remove(n.id);
                    continue;
                }
                gop.value_ptr.* = nodes.items.len;
                try nodes.append(gpa, .{ .id = n.id, .depth = depth + 1, .exact = n.exact, .via = .empty });
            }
            const slot = &nodes.items[gop.value_ptr.*];
            if (slot.depth == depth + 1 and !contains(slot.via.items, from_id)) {
                try slot.via.append(gpa, from_id);
                if (n.exact) slot.exact = true;
            }
            // One edge per pair: a target called on several lines yields several
            // references, but `callSiteLines` already unions every call site.
            const caller = if (opts.direction == .callers) n.id else from_id;
            const callee = if (opts.direction == .callers) from_id else n.id;
            const pair = (@as(u64, caller) << 32) | callee;
            if ((try edge_seen.getOrPut(gpa, pair)).found_existing) continue;
            try query.callSiteLines(idx, caller, callee, &lines);
            try edges.append(gpa, .{
                .from = caller,
                .to = callee,
                .exact = n.exact,
                .lines = try gpa.dupe(u32, lines.items),
            });
        }
    }

    return .{ .nodes = nodes, .edges = edges, .truncated = truncated };
}

fn writeBlastNodesAndEdges(w: *Writer, ctx: Ctx, result: BlastResult) !void {
    try w.writeAll("\"nodes\":[");
    for (result.nodes.items, 0..) |n, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try payload.writeSymbolId(w, ctx, n.id);
        try w.print(",\"depth\":{d},\"via\":", .{n.depth});
        try payload.writeLines(w, n.via.items);
        try w.print(",\"exact\":{}}}", .{n.exact});
    }
    try w.writeAll("],\"edges\":[");
    for (result.edges.items, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try payload.writeEdge(w, e.from, e.to, e.exact, e.lines);
    }
    try w.writeByte(']');
}

/// Write the contract's blast result: `computeBlast`'s walk from `roots`.
pub fn writeBlast(
    w: *Writer,
    gpa: std.mem.Allocator,
    ctx: Ctx,
    roots: []const SymbolId,
    opts: BlastOptions,
) !void {
    var result = try computeBlast(gpa, ctx, roots, opts);
    defer result.deinit(gpa);

    try w.writeAll("{\"roots\":");
    try payload.writeSymbolArray(w, ctx, roots);
    try w.writeByte(',');
    try writeBlastNodesAndEdges(w, ctx, result);
    try w.writeAll(",\"summary\":");
    try writeBlastSummary(w, gpa, ctx, result.nodes.items, result.truncated);
    try w.writeByte('}');
}

fn writeBlastSummary(
    w: *Writer,
    gpa: std.mem.Allocator,
    ctx: Ctx,
    nodes: []const BlastNode,
    truncated: bool,
) !void {
    const idx = ctx.index();
    var max_depth: u32 = 0;
    var tests: u32 = 0;
    for (nodes) |n| {
        max_depth = @max(max_depth, n.depth);
        if (query.isTestSymbol(idx, idx.graph.symbols[n.id])) tests += 1;
    }

    const by_depth = try gpa.alloc(u32, max_depth + 1);
    defer gpa.free(by_depth);
    @memset(by_depth, 0);

    var by_file: std.StringArrayHashMapUnmanaged(u32) = .empty;
    defer by_file.deinit(gpa);
    for (nodes) |n| {
        by_depth[n.depth] += 1;
        const path = idx.graph.files[idx.graph.symbols[n.id].file].path;
        const gop = try by_file.getOrPut(gpa, path);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    const FileCount = struct { path: []const u8, count: u32 };
    const ranked = try gpa.alloc(FileCount, by_file.count());
    defer gpa.free(ranked);
    for (by_file.keys(), by_file.values(), ranked) |k, v, *r| r.* = .{ .path = k, .count = v };
    std.mem.sort(FileCount, ranked, {}, struct {
        fn lt(_: void, a: FileCount, b: FileCount) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);

    try w.print("{{\"symbols\":{d},\"files\":{d},\"tests\":{d},\"maxDepth\":{d},\"truncated\":{},\"byDepth\":[", .{
        nodes.len, ranked.len, tests, max_depth, truncated,
    });
    for (by_depth, 0..) |c, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{d}", .{c});
    }
    try w.writeAll("],\"byFile\":[");
    for (ranked, 0..) |r, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"file\":");
        try payload.writeString(w, r.path);
        try w.print(",\"count\":{d}}}", .{r.count});
    }
    try w.writeAll("]}");
}

// ---------------------------------------------------------------------------
// Tests (inverted coverage)
// ---------------------------------------------------------------------------

pub const TestsForOptions = struct {
    limit: u32 = 200,
};

const ReachNode = struct { id: SymbolId, depth: u32, via: std.ArrayList(SymbolId) };

/// Whether `from` references `to` through an exact call/route_call edge — the
/// same executable-edge criterion `query.testReachable` walks forward from
/// tests; `navgraph/tests` walks it backward from one target.
fn executableEdge(idx: *const Index, from: SymbolId, to: SymbolId) bool {
    for (idx.graph.symbols[from].refs) |ref| {
        if (ref.target == to and ref.exact and (ref.kind == .call or ref.kind == .route_call)) return true;
    }
    return false;
}

/// `navgraph/tests`: every test symbol from which `target` is reachable
/// through an exact call/route_call edge — `query.coverage`'s forward walk
/// from every test, inverted and rooted at one target. `target` itself is
/// never listed even when it is a test (a test does not cover itself).
/// The shared reverse walk behind `writeTestsFor` and `navgraph/context`'s
/// `tests` field: every symbol (test or not) reachable backward from `target`
/// through an exact call/route_call edge, each at its shallowest depth.
/// `nodes[0]` is always `target` itself, at depth 0. Caller frees with
/// `freeReachNodes`.
fn reachingWalk(gpa: std.mem.Allocator, idx: *const Index, target: SymbolId) !std.ArrayList(ReachNode) {
    var nodes: std.ArrayList(ReachNode) = .empty;
    errdefer {
        for (nodes.items) |*n| n.via.deinit(gpa);
        nodes.deinit(gpa);
    }
    var seen: std.AutoHashMapUnmanaged(SymbolId, usize) = .empty;
    defer seen.deinit(gpa);
    try seen.put(gpa, target, 0);
    try nodes.append(gpa, .{ .id = target, .depth = 0, .via = .empty });

    var cursor: usize = 0;
    while (cursor < nodes.items.len) : (cursor += 1) {
        const from_id = nodes.items[cursor].id;
        const depth = nodes.items[cursor].depth;
        for (idx.callersOf(from_id)) |cid| {
            if (!executableEdge(idx, cid, from_id)) continue;
            const gop = try seen.getOrPut(gpa, cid);
            if (!gop.found_existing) {
                gop.value_ptr.* = nodes.items.len;
                try nodes.append(gpa, .{ .id = cid, .depth = depth + 1, .via = .empty });
            }
            const slot = &nodes.items[gop.value_ptr.*];
            if (slot.depth == depth + 1 and !contains(slot.via.items, from_id)) {
                try slot.via.append(gpa, from_id);
            }
        }
    }
    return nodes;
}

fn freeReachNodes(gpa: std.mem.Allocator, nodes: *std.ArrayList(ReachNode)) void {
    for (nodes.items) |*n| n.via.deinit(gpa);
    nodes.deinit(gpa);
}

pub fn writeTestsFor(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, target: SymbolId, opts: TestsForOptions) !void {
    const idx = ctx.index();
    var nodes = try reachingWalk(gpa, idx, target);
    defer freeReachNodes(gpa, &nodes);

    var count: u32 = 0;
    var max_depth: u32 = 0;
    for (nodes.items[1..]) |n| {
        if (!query.isTestSymbol(idx, idx.graph.symbols[n.id])) continue;
        count += 1;
        max_depth = @max(max_depth, n.depth);
    }

    try w.writeAll("{\"symbol\":");
    try payload.writeSymbolId(w, ctx, target);
    try w.writeAll(",\"tests\":[");
    var shown: u32 = 0;
    var truncated = false;
    for (nodes.items[1..]) |n| {
        if (!query.isTestSymbol(idx, idx.graph.symbols[n.id])) continue;
        if (shown >= opts.limit) {
            truncated = true;
            continue;
        }
        if (shown != 0) try w.writeByte(',');
        shown += 1;
        try w.writeAll("{\"symbol\":");
        try payload.writeSymbolId(w, ctx, n.id);
        try w.print(",\"depth\":{d},\"via\":", .{n.depth});
        try payload.writeLines(w, n.via.items);
        try w.writeByte('}');
    }
    try w.print("],\"summary\":{{\"count\":{d},\"maxDepth\":{d},\"truncated\":{}}}}}", .{ count, max_depth, truncated });
}

// ---------------------------------------------------------------------------
// Context (one-call symbol briefing for an editing agent)
// ---------------------------------------------------------------------------

pub const ContextOptions = struct {
    /// Rough token budget; sections drop in order (bodies, tests, types,
    /// callees — callers never drop) until the estimate fits, or nothing is
    /// left to drop.
    budget: u32 = 2000,
};

/// A rough tokens-from-characters estimate (~4 chars/token), the same order
/// of magnitude every major tokenizer lands near for source code. Exactness
/// is not the point — it only has to shrink monotonically as sections drop.
fn estimateTokens(chars: usize) u32 {
    return @intCast((chars + 3) / 4);
}

fn sigCharsSum(idx: *const Index, ids: []const SymbolId) usize {
    var total: usize = 0;
    for (ids) |id| {
        const sym = idx.graph.symbols[id];
        total += sym.signature(idx.graph.files[sym.file].text).len;
    }
    return total;
}

/// `navgraph/context`: everything an editing agent typically needs about one
/// symbol in a single call — definition, callers/callees, related types, and
/// covering tests — trimmed to `opts.budget` tokens by dropping, in order,
/// the body (falling back to the signature alone), then tests, then types,
/// then callees; callers are never dropped. `types` is best-effort: a
/// container's declared supertypes, or (for a function/method) the resolved
/// types of its own typed bindings — the same name-based binding scan
/// `navgraph/types`'s `users` uses, so it shares that scan's limitations.
pub fn writeContext(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, id: SymbolId, opts: ContextOptions) !void {
    const idx = ctx.index();
    const sym = idx.graph.symbols[id];
    const file = idx.graph.files[sym.file];
    const sig = sym.signature(file.text);
    const body_text = sym.body(file.text);
    const doc = render.stripDoc(sym.doc);
    const callers = idx.callersOf(id);

    var callees: std.ArrayList(SymbolId) = .empty;
    defer callees.deinit(gpa);
    {
        var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
        defer seen.deinit(gpa);
        var it = Neighbours.init(idx, id, .callees, false);
        while (it.next()) |n| {
            if ((try seen.getOrPut(gpa, n.id)).found_existing) continue;
            try callees.append(gpa, n.id);
        }
    }

    var types: std.ArrayList(SymbolId) = .empty;
    defer types.deinit(gpa);
    {
        var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
        defer seen.deinit(gpa);
        if (impls.isContainer(sym)) {
            var hgraph = try hierarchy.build(gpa, idx);
            defer hgraph.deinit();
            for (hgraph.edges) |e| {
                if (e.subtype != id or e.supertype == invalid) continue;
                if ((try seen.getOrPut(gpa, e.supertype)).found_existing) continue;
                try types.append(gpa, e.supertype);
            }
        } else {
            var buf: [16]SymbolId = undefined;
            for (sym.bindings) |b| {
                const ids = query.resolveIds(idx, b.type_name, &buf);
                if (ids.len != 1) continue;
                if ((try seen.getOrPut(gpa, ids[0])).found_existing) continue;
                try types.append(gpa, ids[0]);
            }
        }
    }

    var reach = try reachingWalk(gpa, idx, id);
    defer freeReachNodes(gpa, &reach);
    var tests_list: std.ArrayList(SymbolId) = .empty;
    defer tests_list.deinit(gpa);
    for (reach.items[1..]) |n| {
        if (query.isTestSymbol(idx, idx.graph.symbols[n.id])) try tests_list.append(gpa, n.id);
    }

    // Level 0 keeps everything; each higher level drops one more section, in
    // the contract's stated order. Stop at the first level that fits, or the
    // last level if none does.
    var level: u32 = 0;
    var chars: usize = 0;
    while (true) : (level += 1) {
        const with_body = level < 1;
        const with_tests = level < 2;
        const with_types = level < 3;
        const with_callees = level < 4;
        chars = doc.len + (if (with_body) body_text.len else sig.len) + sigCharsSum(idx, callers);
        if (with_callees) chars += sigCharsSum(idx, callees.items);
        if (with_types) chars += sigCharsSum(idx, types.items);
        if (with_tests) chars += sigCharsSum(idx, tests_list.items);
        if (estimateTokens(chars) <= opts.budget or level >= 4) break;
    }
    const with_body = level < 1;
    const with_tests = level < 2;
    const with_types = level < 3;
    const with_callees = level < 4;

    try w.writeAll("{\"symbol\":");
    try payload.writeSymbolId(w, ctx, id);
    try w.writeAll(",\"definition\":{\"text\":");
    try payload.writeString(w, if (with_body) body_text else sig);
    try w.writeAll(",\"range\":");
    try payload.writeDefRange(w, ctx, sym);
    try w.writeAll("},\"signature\":");
    try payload.writeCollapsed(w, sig);
    if (doc.len != 0) {
        try w.writeAll(",\"doc\":");
        try payload.writeString(w, doc);
    }
    try w.writeAll(",\"callers\":");
    try payload.writeSymbolArray(w, ctx, callers);
    try w.writeAll(",\"callees\":");
    try payload.writeSymbolArray(w, ctx, if (with_callees) callees.items else &.{});
    try w.writeAll(",\"types\":");
    try payload.writeSymbolArray(w, ctx, if (with_types) types.items else &.{});
    try w.writeAll(",\"tests\":");
    try payload.writeSymbolArray(w, ctx, if (with_tests) tests_list.items else &.{});
    try w.print(",\"truncated\":{},\"tokensEstimate\":{d}}}", .{ level > 0, estimateTokens(chars) });
}

/// Iterate a symbol's graph neighbours in one direction, applying the same
/// dead-read filter the CLI's call tree uses.
const Neighbours = struct {
    idx: *const Index,
    id: SymbolId,
    direction: Direction,
    refs: []const model.Reference,
    callers: []const SymbolId,
    i: usize,
    /// Whether a plain data-read callee edge (a module `var`/`const`/field)
    /// is yielded, or silently skipped like the CLI's non-`-r` walks do.
    include_data_reads: bool,

    const Item = struct { id: SymbolId, exact: bool };

    fn init(idx: *const Index, id: SymbolId, direction: Direction, include_data_reads: bool) Neighbours {
        return .{
            .idx = idx,
            .id = id,
            .direction = direction,
            .refs = idx.graph.symbols[id].refs,
            .callers = idx.callersOf(id),
            .i = 0,
            .include_data_reads = include_data_reads,
        };
    }

    fn next(self: *Neighbours) ?Item {
        switch (self.direction) {
            .callers => {
                if (self.i >= self.callers.len) return null;
                const cid = self.callers[self.i];
                self.i += 1;
                return .{ .id = cid, .exact = query.hasExactEdge(self.idx, cid, self.id) };
            },
            .callees => while (self.i < self.refs.len) {
                const ref = self.refs[self.i];
                self.i += 1;
                if (ref.target == invalid) continue;
                if (!self.include_data_reads and query.isDataReadEdge(self.idx, ref)) continue;
                return .{ .id = ref.target, .exact = ref.exact };
            },
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Call trees (callers / calls)
// ---------------------------------------------------------------------------

pub const TreeOptions = struct {
    depth: u32,
    direction: Direction,
    /// Include plain data reads (module `var`/`const`/field) as callee edges.
    refs: bool,
    scope: Scope,
};

/// Write the contract's `Node` tree rooted at `id`, mirroring the CLI's
/// `callers`/`calls -j` shape.
pub fn writeTree(
    w: *Writer,
    gpa: std.mem.Allocator,
    ctx: Ctx,
    id: SymbolId,
    opts: TreeOptions,
) !void {
    var visited: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
    defer visited.deinit(gpa);
    // Freed with the index's allocator: `query.callSiteLines` grows it with that.
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(ctx.index().gpa);
    try writeNode(w, gpa, ctx, id, 0, true, &.{}, opts, &visited, &lines);
}

fn writeNode(
    w: *Writer,
    gpa: std.mem.Allocator,
    ctx: Ctx,
    id: SymbolId,
    depth: u32,
    exact: bool,
    lines: []const u32,
    opts: TreeOptions,
    visited: *std.AutoHashMapUnmanaged(SymbolId, void),
    scratch: *std.ArrayList(u32),
) anyerror!void {
    const idx = ctx.index();
    try w.writeAll("{\"symbol\":");
    try payload.writeSymbolId(w, ctx, id);
    try w.print(",\"exact\":{},\"lines\":", .{exact});
    try payload.writeLines(w, lines);

    const recursion = (try visited.getOrPut(gpa, id)).found_existing;
    if (depth >= opts.depth or recursion) {
        try w.writeAll(",\"children\":[],\"ext\":");
        try payload.writeExternals(w, idx.graph.symbols[id], opts.scope.strict);
        try w.print(",\"recursion\":{}}}", .{recursion});
        return;
    }

    try w.writeAll(",\"children\":[");
    var wrote: u32 = 0;
    var it = Neighbours.init(idx, id, opts.direction, false);
    while (it.next()) |n| {
        if (opts.direction == .callees and !opts.refs and dataRead(idx, id, n.id)) continue;
        if (opts.scope.strict and !n.exact) continue;
        if (!opts.scope.admits(idx, idx.graph.symbols[n.id])) continue;
        const caller = if (opts.direction == .callers) n.id else id;
        const callee = if (opts.direction == .callers) id else n.id;
        try query.callSiteLines(idx, caller, callee, scratch);
        const child_lines = try gpa.dupe(u32, scratch.items);
        defer gpa.free(child_lines);
        if (wrote != 0) try w.writeByte(',');
        try writeNode(w, gpa, ctx, n.id, depth + 1, n.exact, child_lines, opts, visited, scratch);
        wrote += 1;
    }
    try w.writeAll("],\"ext\":");
    try payload.writeExternals(w, idx.graph.symbols[id], opts.scope.strict);
    try w.writeAll(",\"recursion\":false}");
}

/// Whether every edge from `from` to `to` is a plain data read.
fn dataRead(idx: *const Index, from: SymbolId, to: SymbolId) bool {
    for (idx.graph.symbols[from].refs) |ref| {
        if (ref.target != to) continue;
        if (!query.isDataReadEdge(idx, ref)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Call hierarchy / type hierarchy
// ---------------------------------------------------------------------------

/// `CallHierarchyItem` / `TypeHierarchyItem` — the two contract shapes are
/// identical apart from `data.exact`, which only a call-hierarchy edge carries
/// (a type-hierarchy edge has no separate confidence bit to report). `exact`
/// null omits the field.
fn writeHierarchyItem(w: *Writer, ctx: Ctx, sym: Symbol, exact: ?bool) !void {
    const idx = ctx.index();
    const file = idx.graph.files[sym.file];
    try w.writeAll("{\"name\":");
    try payload.writeString(w, sym.name);
    try w.print(",\"kind\":{d},\"uri\":\"", .{lspSymbolKind(sym.kind)});
    try overlay.writeUriIn(w, ctx.session.root_abs, file.path);
    try w.writeAll("\",\"range\":");
    try payload.writeDefRange(w, ctx, sym);
    try w.writeAll(",\"selectionRange\":");
    try payload.writeNameRange(w, file.text, sym.line, sym.name, ctx.encoding);
    try w.print(",\"data\":{{\"id\":{d},\"qualified\":", .{sym.id});
    try payload.writeQualified(w, ctx, sym);
    try w.writeAll(",\"file\":");
    try payload.writeString(w, file.path);
    if (exact) |e| try w.print(",\"exact\":{}", .{e});
    try w.writeAll("}}");
}

/// Re-resolve a hierarchy item's `data` (`{id, qualified, file}`) back to a
/// symbol, by `qualified`+`file` rather than trusting `id` across a possible
/// re-index (ids are only stable within one generation). `id` is carried for a
/// client's own bookkeeping, not read here.
pub fn resolveHierarchyItemData(idx: *const Index, qualified: []const u8, file: []const u8) ?SymbolId {
    var buf: [64]SymbolId = undefined;
    for (query.resolveIds(idx, qualified, &buf)) |id| {
        if (std.mem.eql(u8, idx.graph.files[idx.graph.symbols[id].file].path, file)) return id;
    }
    return null;
}

/// `prepareCallHierarchy` / `prepareTypeHierarchy` — the single resolved item
/// at a cursor, or an empty array when nothing resolves there.
pub fn writePrepareHierarchy(w: *Writer, ctx: Ctx, id: SymbolId) !void {
    if (id == invalid) return w.writeAll("[]");
    try w.writeByte('[');
    try writeHierarchyItem(w, ctx, ctx.index().graph.symbols[id], null);
    try w.writeByte(']');
}

/// `callHierarchy/incomingCalls`: every distinct caller of `id`, with the
/// lines in the CALLER's file where it references `id` (`fromRanges`).
pub fn writeIncomingCalls(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, id: SymbolId, scope: Scope) !void {
    const idx = ctx.index();
    const target = idx.graph.symbols[id];
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
    defer seen.deinit(gpa);

    try w.writeByte('[');
    var wrote: u32 = 0;
    for (idx.callersOf(id)) |cid| {
        if ((try seen.getOrPut(gpa, cid)).found_existing) continue;
        const csym = idx.graph.symbols[cid];
        const exact = query.hasExactEdge(idx, cid, id);
        if (scope.strict and !exact) continue;
        if (!scope.admits(idx, csym)) continue;
        try query.callSiteLines(idx, cid, id, &lines);
        if (lines.items.len == 0) continue;
        if (wrote != 0) try w.writeByte(',');
        wrote += 1;
        try w.writeAll("{\"from\":");
        try writeHierarchyItem(w, ctx, csym, exact);
        try w.writeAll(",\"fromRanges\":[");
        const caller_text = idx.graph.files[csym.file].text;
        for (lines.items, 0..) |line, i| {
            if (i != 0) try w.writeByte(',');
            try payload.writeNameRange(w, caller_text, line, target.name, ctx.encoding);
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// `callHierarchy/outgoingCalls`: every distinct callee `id` resolves to, with
/// the lines in `id`'s OWN file where it references that callee.
pub fn writeOutgoingCalls(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, id: SymbolId, scope: Scope) !void {
    const idx = ctx.index();
    const from_text = idx.graph.files[idx.graph.symbols[id].file].text;
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
    defer seen.deinit(gpa);

    try w.writeByte('[');
    var wrote: u32 = 0;
    var it = Neighbours.init(idx, id, .callees, false);
    while (it.next()) |n| {
        if ((try seen.getOrPut(gpa, n.id)).found_existing) continue;
        const tsym = idx.graph.symbols[n.id];
        if (scope.strict and !n.exact) continue;
        if (!scope.admits(idx, tsym)) continue;
        try query.callSiteLines(idx, id, n.id, &lines);
        if (lines.items.len == 0) continue;
        if (wrote != 0) try w.writeByte(',');
        wrote += 1;
        try w.writeAll("{\"to\":");
        try writeHierarchyItem(w, ctx, tsym, n.exact);
        try w.writeAll(",\"fromRanges\":[");
        for (lines.items, 0..) |line, i| {
            if (i != 0) try w.writeByte(',');
            try payload.writeNameRange(w, from_text, line, tsym.name, ctx.encoding);
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// `typeHierarchy/supertypes` / `subtypes`: one hop of the base/impl table
/// (`hierarchy.zig`'s `extends`/`implements`/`includes`/`impl-for` edges),
/// matching how an editor expands the tree one level per request.
pub fn writeTypeRelatives(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, id: SymbolId, up: bool, scope: Scope) !void {
    const idx = ctx.index();
    var graph = try hierarchy.build(gpa, idx);
    defer graph.deinit();
    var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
    defer seen.deinit(gpa);

    try w.writeByte('[');
    var wrote: u32 = 0;
    for (graph.edges) |e| {
        const other = if (up) e.supertype else e.subtype;
        const anchor = if (up) e.subtype else e.supertype;
        if (anchor != id or other == invalid) continue;
        if ((try seen.getOrPut(gpa, other)).found_existing) continue;
        const sym = idx.graph.symbols[other];
        if (!scope.admits(idx, sym)) continue;
        if (wrote != 0) try w.writeByte(',');
        wrote += 1;
        try writeHierarchyItem(w, ctx, sym, null);
    }
    try w.writeByte(']');
}

// ---------------------------------------------------------------------------
// implementation / typeDefinition / documentHighlight / codeLens
// ---------------------------------------------------------------------------

/// `textDocument/implementation`: implementors of an interface/trait/protocol
/// MEMBER (`impls.zig`'s method-level edges) or of a TYPE (`impls.zig`'s
/// structural/nominal port relations, unioned with `hierarchy.zig`'s
/// keyword-declared subtypes of an interface — duck-typed Python and
/// keyword-typed Java/TS/C#/Go/Ruby both surface here).
pub fn writeImplementation(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, id: SymbolId, scope: Scope) !void {
    const idx = ctx.index();
    const sym = idx.graph.symbols[id];
    var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
    defer seen.deinit(gpa);
    try w.writeByte('[');
    var wrote: u32 = 0;

    if (sym.kind == .method) {
        var graph = try impls.build(gpa, idx);
        defer graph.deinit();
        for (graph.edges) |e| {
            if (e.port_method != id) continue;
            if ((try seen.getOrPut(gpa, e.implementation_method)).found_existing) continue;
            const impl_sym = idx.graph.symbols[e.implementation_method];
            if (!scope.admits(idx, impl_sym)) continue;
            if (wrote != 0) try w.writeByte(',');
            wrote += 1;
            try payload.writeSymbolLocation(w, ctx, impl_sym);
        }
    } else if (impls.isContainer(sym)) {
        var pgraph = try impls.build(gpa, idx);
        defer pgraph.deinit();
        for (pgraph.relations) |r| {
            if (r.port != id) continue;
            if ((try seen.getOrPut(gpa, r.implementation)).found_existing) continue;
            const impl_sym = idx.graph.symbols[r.implementation];
            if (!scope.admits(idx, impl_sym)) continue;
            if (wrote != 0) try w.writeByte(',');
            wrote += 1;
            try payload.writeSymbolLocation(w, ctx, impl_sym);
        }
        if (sym.kind == .interface) {
            var hgraph = try hierarchy.build(gpa, idx);
            defer hgraph.deinit();
            for (hgraph.edges) |e| {
                if (e.supertype != id) continue;
                if ((try seen.getOrPut(gpa, e.subtype)).found_existing) continue;
                const sub_sym = idx.graph.symbols[e.subtype];
                if (!scope.admits(idx, sub_sym)) continue;
                if (wrote != 0) try w.writeByte(',');
                wrote += 1;
                try payload.writeSymbolLocation(w, ctx, sub_sym);
            }
        }
    }
    try w.writeByte(']');
}

pub const TypesOptions = struct {
    limit: u32 = 200,
    scope: Scope,
};

fn writeTypeUser(w: *Writer, ctx: Ctx, id: SymbolId, kind: []const u8) !void {
    try w.writeAll("{\"symbol\":");
    try payload.writeSymbolId(w, ctx, id);
    try w.print(",\"kind\":\"{s}\"}}", .{kind});
}

/// `navgraph/types`: "who uses type T" — the base/impl table (supertypes,
/// subtypes, implementors, same data `typeHierarchy`/`implementation` walk)
/// plus a unified `users` list combining the subtype ("extends") and
/// implementor ("implements") edges with typed param/local bindings whose
/// `Binding.type_name` names this type (matched by name, like
/// `query.typeConsumerBinding` — the same name-not-id limitation that walk
/// already carries). Field/return/annotation/generic uses are not yet
/// extracted by any language backend, so they are simply absent, never an
/// error (the contract's documented best-effort clause).
pub fn writeTypes(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, id: SymbolId, opts: TypesOptions) !void {
    const idx = ctx.index();
    const sym = idx.graph.symbols[id];

    try w.writeAll("{\"symbol\":");
    try payload.writeSymbolId(w, ctx, id);
    var hgraph = try hierarchy.build(gpa, idx);
    defer hgraph.deinit();
    var truncated = false;
    try w.writeAll(",\"supertypes\":[");
    {
        var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
        defer seen.deinit(gpa);
        var shown: u32 = 0;
        for (hgraph.edges) |e| {
            if (e.subtype != id or e.supertype == invalid) continue;
            if ((try seen.getOrPut(gpa, e.supertype)).found_existing) continue;
            const super = idx.graph.symbols[e.supertype];
            if (!opts.scope.admits(idx, super)) continue;
            if (shown >= opts.limit) {
                truncated = true;
                continue;
            }
            if (shown != 0) try w.writeByte(',');
            shown += 1;
            try payload.writeSymbolId(w, ctx, e.supertype);
        }
    }
    try w.writeAll("],\"subtypes\":[");
    {
        var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
        defer seen.deinit(gpa);
        var shown: u32 = 0;
        for (hgraph.edges) |e| {
            if (e.supertype != id or e.subtype == invalid) continue;
            if ((try seen.getOrPut(gpa, e.subtype)).found_existing) continue;
            const sub = idx.graph.symbols[e.subtype];
            if (!opts.scope.admits(idx, sub)) continue;
            if (shown >= opts.limit) {
                truncated = true;
                continue;
            }
            if (shown != 0) try w.writeByte(',');
            shown += 1;
            try payload.writeSymbolId(w, ctx, e.subtype);
        }
    }
    try w.writeAll("],\"implementors\":[");
    var pgraph = try impls.build(gpa, idx);
    defer pgraph.deinit();
    {
        var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
        defer seen.deinit(gpa);
        var shown: u32 = 0;
        for (pgraph.relations) |r| {
            if (r.port != id) continue;
            if ((try seen.getOrPut(gpa, r.implementation)).found_existing) continue;
            const impl_sym = idx.graph.symbols[r.implementation];
            if (!opts.scope.admits(idx, impl_sym)) continue;
            if (shown >= opts.limit) {
                truncated = true;
                continue;
            }
            if (shown != 0) try w.writeByte(',');
            shown += 1;
            try payload.writeSymbolId(w, ctx, r.implementation);
        }
    }
    try w.writeAll("],\"users\":[");
    var shown: u32 = 0;
    var seen: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
    defer seen.deinit(gpa);
    // Implementors labeled first: a keyword-typed language (Java/TS/C#/Go/Ruby)
    // records an `implements I` relation in BOTH tables (impls, plus a generic
    // base-table edge), so whichever pass claims the id first wins the `seen`
    // dedup — implements is the more specific, correct label (coldstart F3).
    for (pgraph.relations) |r| {
        if (r.port != id) continue;
        if ((try seen.getOrPut(gpa, r.implementation)).found_existing) continue;
        if (!opts.scope.admits(idx, idx.graph.symbols[r.implementation])) continue;
        if (shown >= opts.limit) {
            truncated = true;
            continue;
        }
        if (shown != 0) try w.writeByte(',');
        shown += 1;
        try writeTypeUser(w, ctx, r.implementation, "implements");
    }
    for (hgraph.edges) |e| {
        if (e.supertype != id or e.subtype == invalid) continue;
        if ((try seen.getOrPut(gpa, e.subtype)).found_existing) continue;
        if (!opts.scope.admits(idx, idx.graph.symbols[e.subtype])) continue;
        if (shown >= opts.limit) {
            truncated = true;
            continue;
        }
        if (shown != 0) try w.writeByte(',');
        shown += 1;
        try writeTypeUser(w, ctx, e.subtype, "extends");
    }
    for (idx.graph.symbols) |owner| {
        for (owner.bindings) |b| {
            if (!std.mem.eql(u8, b.type_name, sym.name)) continue;
            if ((try seen.getOrPut(gpa, owner.id)).found_existing) continue;
            if (!opts.scope.admits(idx, owner)) continue;
            if (shown >= opts.limit) {
                truncated = true;
                continue;
            }
            if (shown != 0) try w.writeByte(',');
            shown += 1;
            const kind: []const u8 = if (b.is_param) "param" else "local";
            try writeTypeUser(w, ctx, owner.id, kind);
            break;
        }
    }
    try w.print("],\"truncated\":{}}}", .{truncated});
}

/// `textDocument/typeDefinition`: the declared type of the identifier at
/// `offset`, from the enclosing body's own `Binding` table (`name: TypeName`
/// local/parameter declarations). Empty — never an error — when no binding is
/// recorded for that name; a language/position this doesn't cover is a
/// routine "not recorded", not a failure.
pub fn writeTypeDefinition(w: *Writer, ctx: Ctx, path: []const u8, offset: usize) !void {
    const idx = ctx.index();
    const file_id = fileIdOf(idx, path) orelse return w.writeAll("[]");
    const file = idx.graph.files[file_id];
    const ident = position.identifierAt(file.text, offset) orelse return w.writeAll("[]");
    const enclosing = enclosingSymbol(idx, file, ident.start);

    try w.writeByte('[');
    var wrote: u32 = 0;
    if (enclosing) |e| {
        for (e.bindings) |b| {
            if (!std.mem.eql(u8, b.name, ident.name)) continue;
            var buf: [16]SymbolId = undefined;
            const ids = query.resolveIds(idx, b.type_name, &buf);
            if (ids.len != 0) {
                try payload.writeSymbolLocation(w, ctx, idx.graph.symbols[ids[0]]);
                wrote += 1;
            }
            break;
        }
    }
    try w.writeByte(']');
}

/// `textDocument/documentHighlight`: every reference site of the symbol under
/// `offset`, restricted to `path`'s own file — the declaration (kind `Text`)
/// plus every resolved read/write use (kind `Read`/`Write`).
pub fn writeDocumentHighlight(w: *Writer, gpa: std.mem.Allocator, ctx: Ctx, path: []const u8, offset: usize) !void {
    const idx = ctx.index();
    const file_id = fileIdOf(idx, path) orelse return w.writeAll("[]");
    const file = idx.graph.files[file_id];
    // `locate`'s candidates must come from the per-request arena, not the
    // long-lived session allocator — every other call site does this; this
    // one leaked `Located.candidates` on every request (coldstart F2).
    const located = (try locate(gpa, ctx, path, offset)) orelse return w.writeAll("[]");
    if (located.symbol == invalid) return w.writeAll("[]");
    const target = idx.graph.symbols[located.symbol];

    try w.writeByte('[');
    var wrote: u32 = 0;
    if (target.file == file_id) {
        try w.writeAll("{\"range\":");
        try payload.writeNameRange(w, file.text, target.line, target.name, ctx.encoding);
        try w.writeAll(",\"kind\":1}");
        wrote += 1;
    }
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const owner = idx.graph.symbols[i];
        for (owner.refs) |ref| {
            if (ref.target != located.symbol) continue;
            const site_lines: []const u32 = if (ref.lines.len != 0) ref.lines else &.{ref.line};
            for (site_lines) |line| {
                if (wrote != 0) try w.writeByte(',');
                try w.writeAll("{\"range\":");
                try payload.writeNameRange(w, file.text, line, target.name, ctx.encoding);
                try w.print(",\"kind\":{d}}}", .{@as(u8, if (ref.write) 3 else 2)});
                wrote += 1;
            }
        }
    }
    try w.writeByte(']');
}

/// `textDocument/codeLens`: one lens per definition with a call-graph
/// presence, `"N callers · M callees"` driving `navgraph.blast` on that symbol.
pub fn writeCodeLens(w: *Writer, ctx: Ctx, file: model.SourceFile) !void {
    const idx = ctx.index();
    try w.writeByte('[');
    var wrote: u32 = 0;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (!isLensTarget(sym.kind)) continue;
        if (wrote != 0) try w.writeByte(',');
        wrote += 1;
        try w.writeAll("{\"range\":");
        try payload.writeDefRange(w, ctx, sym);
        try w.print(",\"command\":{{\"title\":\"{d} callers \xc2\xb7 {d} callees\",\"command\":\"navgraph.blast\",\"arguments\":[{{\"symbol\":\"", .{
            idx.callersOf(sym.id).len, query.fanOut(sym),
        });
        try payload.writeQualifiedAtFileBody(w, ctx, sym);
        // Closes: the symbol string+object, the arguments array, the command
        // object, then the lens item itself (`{"range":...,"command":{...}}`).
        try w.writeAll("\"}]}}");
    }
    try w.writeByte(']');
}

fn isLensTarget(kind: model.SymbolKind) bool {
    return switch (kind) {
        .function, .method, .class, .@"struct", .@"enum", .interface, .type, .route, .test_case => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Hover
// ---------------------------------------------------------------------------

/// Markdown hover text: `kind name`, the fenced signature, the source range, the
/// fan-in/out counts, then the doc comment.
pub fn writeHoverMarkdown(w: *Writer, ctx: Ctx, sym: Symbol) !void {
    const idx = ctx.index();
    const file = idx.graph.files[sym.file];
    try w.print("{s} `{s}`\n\n```{s}\n{s}\n```\n\n`{s}:{d}-{d}`\n\n← {d} callers → {d} callees", .{
        sym.kind.tag(),
        sym.name,
        file.language.tag(),
        sym.signature(file.text),
        file.path,
        sym.line,
        sym.endLine(file.text),
        idx.callersOf(sym.id).len,
        query.fanOut(sym),
    });
    const doc = render.stripDoc(sym.doc);
    if (doc.len != 0) try w.print("\n\n{s}", .{doc});
}

// ---------------------------------------------------------------------------
// Document symbols
// ---------------------------------------------------------------------------

/// Nested LSP `DocumentSymbol[]` for one file: `range` spans the definition,
/// `selectionRange` covers the name.
pub fn writeDocumentSymbols(w: *Writer, ctx: Ctx, file: model.SourceFile) !void {
    try writeChildSymbols(w, ctx, file, invalid);
}

fn writeChildSymbols(w: *Writer, ctx: Ctx, file: model.SourceFile, parent: SymbolId) anyerror!void {
    const idx = ctx.index();
    try w.writeByte('[');
    var wrote: u32 = 0;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.parent != parent or !reportable(sym.kind)) continue;
        if (wrote != 0) try w.writeByte(',');
        wrote += 1;
        try w.writeAll("{\"name\":");
        try payload.writeString(w, sym.name);
        try w.writeAll(",\"detail\":");
        try payload.writeCollapsed(w, sym.signature(file.text));
        try w.print(",\"kind\":{d},\"range\":", .{lspSymbolKind(sym.kind)});
        try payload.writeDefRange(w, ctx, sym);
        try w.writeAll(",\"selectionRange\":");
        try payload.writeNameRange(w, file.text, sym.line, sym.name, ctx.encoding);
        try w.writeAll(",\"children\":");
        try writeChildSymbols(w, ctx, file, sym.id);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// The LSP `SymbolKind` enum value closest to a navgraph kind.
pub fn lspSymbolKind(kind: model.SymbolKind) u8 {
    return switch (kind) {
        .function => 12,
        .method => 6,
        .class => 5,
        .@"struct" => 23,
        .@"enum" => 10,
        .interface => 11,
        .type => 26,
        .variable => 13,
        .constant => 14,
        .field => 8,
        .macro => 12,
        .module => 2,
        .import => 2,
        .route => 12,
        .route_mount => 2,
        .test_case => 12,
        .unknown => 13,
    };
}

// ---------------------------------------------------------------------------
// Grep
// ---------------------------------------------------------------------------

pub const GrepOptions = struct {
    limit: u32,
    include: []const []const u8,
};

pub const GrepError = error{RegexTooComplex} || std.mem.Allocator.Error || Writer.Error;

/// Search the in-memory sources (overlays included, since the index holds the
/// overlay text) and write the contract's grep result.
pub fn writeGrep(
    w: *Writer,
    ctx: Ctx,
    pattern: *const search.Pattern,
    opts: GrepOptions,
) GrepError!void {
    const idx = ctx.index();
    var total: u32 = 0;
    var shown: u32 = 0;
    try w.writeAll("{\"items\":[");
    for (idx.graph.files) |file| {
        if (!search.included(opts.include, file.path)) continue;
        var line_no: u32 = 0;
        var it = std.mem.splitScalar(u8, file.text, '\n');
        while (it.next()) |raw| {
            line_no += 1;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const m = (pattern.find(line) catch return error.RegexTooComplex) orelse continue;
            total += 1;
            if (shown >= opts.limit) continue;
            if (shown != 0) try w.writeByte(',');
            shown += 1;
            try writeGrepItem(w, ctx, file, line_no, line, m.start);
        }
    }
    try w.print("],\"total\":{d},\"truncated\":{}}}", .{ total, total > shown });
}

fn writeGrepItem(
    w: *Writer,
    ctx: Ctx,
    file: model.SourceFile,
    line_no: u32,
    line: []const u8,
    match_start: usize,
) !void {
    const line_start = position.lineStart(file.text, line_no - 1) orelse 0;
    try w.writeAll("{\"file\":");
    try payload.writeString(w, file.path);
    try w.writeAll(",\"uri\":\"");
    try overlay.writeUriIn(w, ctx.session.root_abs, file.path);
    try w.print("\",\"line\":{d},\"character\":{d},\"text\":", .{
        line_no,
        position.byteToColumn(line[0..match_start], ctx.encoding),
    });
    try payload.writeString(w, line);
    try w.writeAll(",\"enclosing\":");
    if (enclosingSymbol(ctx.index(), file, line_start + match_start)) |sym| {
        try payload.writeSymbol(w, ctx, sym);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte('}');
}

// ---------------------------------------------------------------------------
// Neighbors
// ---------------------------------------------------------------------------

/// Write `{items:[{symbol, callees:[{symbol,exact,lines}], callers:[...]}]}`,
/// one entry per id in `ids` — mirrors the CLI's `neighbors -j`, which answers
/// for every resolution of a name, not just the first (coldstart review F3).
/// Filtered through `Scope` like every other navgraph/* walk (blast, callers,
/// calls), for a consistent contract.
pub fn writeNeighbors(w: *Writer, ctx: Ctx, ids: []const SymbolId, scope: Scope) !void {
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(ctx.index().gpa);
    try w.writeAll("{\"items\":[");
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try payload.writeSymbolId(w, ctx, id);
        try w.writeAll(",\"callees\":");
        try writeNeighborSide(w, ctx, id, .callees, scope, &lines);
        try w.writeAll(",\"callers\":");
        try writeNeighborSide(w, ctx, id, .callers, scope, &lines);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn writeNeighborSide(
    w: *Writer,
    ctx: Ctx,
    id: SymbolId,
    direction: Direction,
    scope: Scope,
    lines: *std.ArrayList(u32),
) !void {
    const idx = ctx.index();
    try w.writeByte('[');
    // Unlike the tree walks (`blast`/`callers`/`calls`), always include
    // data-read callees: the CLI's `neighbors -j` does not filter them, and
    // `navgraph/neighbors` has no `refs` param to ask for them (F14).
    var it = Neighbours.init(idx, id, direction, true);
    var wrote: u32 = 0;
    while (it.next()) |n| {
        if (scope.strict and !n.exact) continue;
        if (!scope.admits(idx, idx.graph.symbols[n.id])) continue;
        const caller = if (direction == .callers) n.id else id;
        const callee = if (direction == .callers) id else n.id;
        try query.callSiteLines(idx, caller, callee, lines);
        if (wrote != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try payload.writeSymbolId(w, ctx, n.id);
        try w.print(",\"exact\":{},\"lines\":", .{n.exact});
        try payload.writeLines(w, lines.items);
        try w.writeByte('}');
        wrote += 1;
    }
    try w.writeByte(']');
}

// ---------------------------------------------------------------------------
// Shortest path
// ---------------------------------------------------------------------------

/// Write `{path:Symbol[]}`, the shortest call path from `from_name` to
/// `to_name` (empty when either name is unknown or no path exists).
pub fn writePath(w: *Writer, ctx: Ctx, from_name: []const u8, to_name: []const u8) !void {
    const idx = ctx.index();
    var fbuf: [64]SymbolId = undefined;
    var tbuf: [64]SymbolId = undefined;
    const from_ids = query.resolveIds(idx, from_name, &fbuf);
    const to_ids = query.resolveIds(idx, to_name, &tbuf);
    // A path is authoritative only between unique endpoints, so an ambiguous
    // name yields no path. Say which name, and offer the candidates: reporting
    // it as "no path" would be a wrong answer, not a missing one.
    if (from_ids.len > 1 or to_ids.len > 1) {
        try w.writeAll("{\"path\":[],\"ambiguousFrom\":");
        try payload.writeSymbolArray(w, ctx, if (from_ids.len > 1) from_ids else &.{});
        try w.writeAll(",\"ambiguousTo\":");
        try payload.writeSymbolArray(w, ctx, if (to_ids.len > 1) to_ids else &.{});
        try w.writeByte('}');
        return;
    }
    const chain = try query.shortestPathIds(idx, from_name, to_name, &fbuf, &tbuf);
    defer idx.gpa.free(chain);
    try w.writeAll("{\"path\":");
    try payload.writeSymbolArray(w, ctx, chain);
    try w.writeAll(",\"ambiguousFrom\":[],\"ambiguousTo\":[]}");
}

// ---------------------------------------------------------------------------
// Outline
// ---------------------------------------------------------------------------

pub const OutlineOptions = struct {
    /// Comma-separated kind tags (`fn,struct`); empty admits every kind.
    kinds: []const u8 = "",
    limit: u32 = 300,
    scope: Scope,
};

/// Write `{files:[{file,lang,symbols:Symbol[]}]}` for every file whose path
/// matches `path_filter`, in indexing order.
pub fn writeOutline(w: *Writer, ctx: Ctx, path_filter: []const u8, opts: OutlineOptions) !void {
    const idx = ctx.index();
    var shown: u32 = 0;
    var total: u32 = 0;
    var first_file = true;
    try w.writeAll("{\"files\":[");
    for (idx.graph.files) |file| {
        if (!query.matchesFilter(file.path, path_filter)) continue;
        if (try writeOutlineFile(w, ctx, file, opts, &shown, &total, !first_file)) first_file = false;
    }
    try w.print("],\"truncated\":{}}}", .{total > shown});
}

/// Writes up to `opts.limit` symbols (via `shown`) but keeps counting past it
/// (via `total`) so the caller can report `truncated`.
fn writeOutlineFile(
    w: *Writer,
    ctx: Ctx,
    file: model.SourceFile,
    opts: OutlineOptions,
    shown: *u32,
    total: *u32,
    sep: bool,
) !bool {
    const idx = ctx.index();
    var wrote_any = false;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import) continue;
        if (!sym.kind.isTopLevelInteresting() and sym.parent == invalid) continue;
        if (opts.kinds.len != 0 and !query.kindAllowed(sym.kind, opts.kinds)) continue;
        if (!opts.scope.admits(idx, sym)) continue;
        total.* += 1;
        if (shown.* >= opts.limit) continue;
        if (!wrote_any) {
            if (sep) try w.writeByte(',');
            try w.writeAll("{\"file\":");
            try payload.writeString(w, file.path);
            try w.print(",\"lang\":\"{s}\",\"symbols\":[", .{file.language.tag()});
        } else {
            try w.writeByte(',');
        }
        try payload.writeSymbolId(w, ctx, sym.id);
        wrote_any = true;
        shown.* += 1;
    }
    if (wrote_any) try w.writeAll("]}");
    return wrote_any;
}

// ---------------------------------------------------------------------------
// Hot
// ---------------------------------------------------------------------------

pub const HotOptions = struct {
    limit: u32 = 25,
    scope: Scope,
};

/// Write `{items:[{symbol,fanIn,fanInExact,fanInTest,fanOut,fanOutExact}]}`
/// ranked by connectivity, over `query.collectHot`.
pub fn writeHot(w: *Writer, ctx: Ctx, path_filter: []const u8, opts: HotOptions) !void {
    const idx = ctx.index();
    const ranked = try query.collectHot(idx, path_filter, opts.scope.tests);
    defer idx.gpa.free(ranked);
    // Same final ordering as the CLI's `hot -j`: collectHot's tie-break is by
    // symbol id, sortHot's is by path then line. The golden parity test pins it.
    query.sortHot(idx, ranked, .default);
    try w.writeAll("{\"items\":[");
    var shown: u32 = 0;
    var total: u32 = 0;
    for (ranked) |e| {
        if (opts.scope.strict and e.fan_in_exact == 0 and e.fan_out_exact == 0) continue;
        total += 1;
        if (shown >= opts.limit) continue;
        if (shown != 0) try w.writeByte(',');
        shown += 1;
        try w.writeAll("{\"symbol\":");
        try payload.writeSymbolId(w, ctx, e.id);
        try w.print(",\"fanIn\":{d},\"fanInExact\":{d},\"fanInTest\":{d},\"fanOut\":{d},\"fanOutExact\":{d}}}", .{
            e.fan_in, e.fan_in_exact, e.fan_in_test, e.fan_out, e.fan_out_exact,
        });
    }
    try w.print("],\"truncated\":{}}}", .{total > shown});
}

// ---------------------------------------------------------------------------
// Unused
// ---------------------------------------------------------------------------

pub const UnusedOptions = struct {
    /// Drop exported symbols: they may be public API rather than dead code.
    noPublic: bool = false,
    /// Disambiguate same-name symbols by import reachability instead of the
    /// (safe) family-wide name tally.
    followImports: bool = false,
    limit: u32 = 300,
    scope: Scope,
};

/// Write `{items:[{symbol,testOnly}]}`: zero-caller definitions nothing calls
/// or uses, over the CLI's own dead-code candidate logic.
pub fn writeUnused(w: *Writer, ctx: Ctx, path_filter: []const u8, opts: UnusedOptions) !void {
    const idx = ctx.index();
    var refs = try query.buildReferencedNames(idx);
    defer refs.deinit();
    if (opts.followImports) refs.scope = try query.buildCollisionScope(idx);
    const cli_opts: query.Options = .{ .unused_skip_exported = opts.noPublic };

    try w.writeAll("{\"items\":[");
    var shown: u32 = 0;
    var total: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (!try query.isDeadCandidateScoped(idx, sym, path_filter, &refs, opts.scope.tests)) continue;
        if (!query.deadCandidateShown(idx, sym, cli_opts, &refs)) continue;
        total += 1;
        if (shown >= opts.limit) continue;
        if (shown != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try payload.writeSymbolId(w, ctx, sym.id);
        try w.print(",\"testOnly\":{}}}", .{refs.testsContains(query.familyOf(idx, sym), sym.name)});
        shown += 1;
    }
    try w.print("],\"truncated\":{}}}", .{total > shown});
}

// ---------------------------------------------------------------------------
// Diff
// ---------------------------------------------------------------------------

pub const DiffOptions = struct {
    depth: u32 = 1,
    direction: Direction = .callers,
    limit: u32 = 500,
    scope: Scope,
};

/// Write `{ref, blast:{...}}`: the definitions changed since `ref` (git ref,
/// default HEAD) plus every definition in a file whose unsaved buffer differs
/// from disk, wrapped as a `navgraph/blast` walk from those roots. Unlike
/// `resolveTarget`'s `{ref}` form (used by `navgraph/blast` itself), an empty
/// change set is not an error here — "nothing changed" is a routine answer,
/// not a failed lookup.
pub fn writeDiff(
    w: *Writer,
    gpa: std.mem.Allocator,
    ctx: Ctx,
    ref: []const u8,
    opts: DiffOptions,
    detail: *?[]const u8,
) !void {
    var roots: std.ArrayList(SymbolId) = .empty;
    defer roots.deinit(gpa);
    try changedSince(gpa, ctx, ref, &roots, detail);

    try w.writeAll("{\"ref\":");
    try payload.writeString(w, ref);
    try w.writeAll(",\"blast\":");
    try writeBlast(w, gpa, ctx, roots.items, .{
        .depth = opts.depth,
        .direction = opts.direction,
        .limit = opts.limit,
        .scope = opts.scope,
    });
    try w.writeByte('}');
}

// ---------------------------------------------------------------------------
// Impact (working-change blast, grouped by hunk)
// ---------------------------------------------------------------------------

pub const ImpactOptions = struct {
    depth: u32,
    direction: Direction,
    limit: u32,
    scope: Scope,
};

const ImpactHunk = struct { file: model.FileId, lo: u32, hi: u32 };

/// An explicit hunk a client already knows about, bypassing overlay
/// comparison entirely.
pub const ImpactRange = struct { lo: u32, hi: u32 };

/// One hunk from an overlay that differs from disk: the common-prefix/suffix
/// trim `index.computeEdit` already computes for the reparse seam, reused
/// here as a single approximate hunk per changed file (multiple disjoint
/// edits in one buffer collapse into the span between the first and last).
/// On disk read failure (a new, untracked, overlay-only file) `disk` is
/// empty, so the whole overlay becomes one hunk — not a special case.
fn appendOverlayHunk(
    gpa: std.mem.Allocator,
    s: *session_mod.Session,
    path: []const u8,
    overlay_text: []const u8,
    fid: model.FileId,
    hunks: *std.ArrayList(ImpactHunk),
) !void {
    var disk: []const u8 = &.{};
    var owned = false;
    if (s.root_dir.readFileAlloc(s.io, path, gpa, .limited(8 * 1024 * 1024))) |bytes| {
        disk = bytes;
        owned = true;
    } else |_| {}
    defer if (owned) gpa.free(disk);
    const edit = index_mod.computeEdit(disk, overlay_text) orelse return;
    try hunks.append(gpa, .{ .file = fid, .lo = edit.start_point.row + 1, .hi = edit.new_end_point.row + 1 });
}

/// A stable id for the whole set of hunks (file + line range each), so a
/// client can tell "this is still the same working change" apart from a new
/// one. Deliberately keyed on shape (file, range), not deep content bytes —
/// per-symbol staleness is `Symbol.contentHash`'s job, not this one's.
fn changeId(idx: *const Index, hunks: []const ImpactHunk) u64 {
    var hasher = std.hash.Wyhash.init(0x4e_47_43_48_41_4e_47_45); // "NGCHANGE"
    for (hunks) |h| {
        hasher.update(idx.graph.files[h.file].path);
        hasher.update(std.mem.asBytes(&h.lo));
        hasher.update(std.mem.asBytes(&h.hi));
    }
    return hasher.final();
}

/// `navgraph/impact`: the blast radius of the current WORKING CHANGE (overlay
/// vs disk) or, when `ref` is given, of disk vs that git ref — grouped by
/// changed hunk. `uri_path` narrows either mode to one document; `range`
/// (meaningful only with `uri_path`, and only outside `ref` mode) lets a
/// client hand navgraph a hunk it already knows about instead of requiring an
/// overlay to already differ from disk. No hunks -> the documented zero
/// result (`roots`/`nodes`/`edges` empty, a zeroed `summary`), not an error.
pub fn writeImpact(
    w: *Writer,
    gpa: std.mem.Allocator,
    ctx: Ctx,
    ref: ?[]const u8,
    uri_path: ?[]const u8,
    range: ?ImpactRange,
    opts: ImpactOptions,
    detail: *?[]const u8,
) !void {
    const idx = ctx.index();
    const s = ctx.session;

    var hunks: std.ArrayList(ImpactHunk) = .empty;
    defer hunks.deinit(gpa);

    if (ref) |ref_spec| {
        const spec = if (ref_spec.len != 0) ref_spec else "HEAD";
        const result = query.runGitDiff(gpa, s.io, s.root_path, spec) catch |err| {
            detail.* = try std.fmt.allocPrint(gpa, "git diff {s} failed: {s}", .{ spec, @errorName(err) });
            return error.GitFailed;
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            detail.* = try std.fmt.allocPrint(gpa, "git diff {s} failed: {s}", .{ spec, firstLineCapped(result.stderr, 300) });
            return error.GitFailed;
        }
        const changes = gitdiff.parse(gpa, result.stdout) catch |err| {
            detail.* = try std.fmt.allocPrint(gpa, "git diff {s} produced an unusable patch: {s}", .{ spec, @errorName(err) });
            return error.GitFailed;
        };
        defer gitdiff.freeChanges(gpa, changes);
        for (changes) |change| {
            if (uri_path) |only| if (!std.mem.eql(u8, change.path, only)) continue;
            const file = query.findDiffFile(idx, change.path) orelse continue;
            const fid = fileIdOf(idx, file.path) orelse continue;
            for (change.ranges) |r| {
                const lo = if (r.empty and r.lo == 0) @as(u32, 1) else r.lo;
                const hi = if (r.empty and r.hi == 0) @as(u32, 1) else r.hi;
                try hunks.append(gpa, .{ .file = fid, .lo = lo, .hi = hi });
            }
        }
    } else if (range) |rg| {
        if (uri_path) |path| if (fileIdOf(idx, path)) |fid| {
            try hunks.append(gpa, .{ .file = fid, .lo = rg.lo, .hi = rg.hi });
        };
    } else if (uri_path) |path| {
        if (s.overlays.docs.get(path)) |overlay_text| if (fileIdOf(idx, path)) |fid| {
            try appendOverlayHunk(gpa, s, path, overlay_text, fid, &hunks);
        };
    } else {
        for (s.overlays.docs.keys(), s.overlays.docs.values()) |path, overlay_text| {
            const fid = fileIdOf(idx, path) orelse continue;
            try appendOverlayHunk(gpa, s, path, overlay_text, fid, &hunks);
        }
    }

    var roots: std.ArrayList(SymbolId) = .empty;
    defer roots.deinit(gpa);
    var hunk_roots: std.ArrayList([]const SymbolId) = .empty;
    defer {
        for (hunk_roots.items) |hr| gpa.free(hr);
        hunk_roots.deinit(gpa);
    }
    for (hunks.items) |h| {
        const file = idx.graph.files[h.file];
        var one: std.ArrayList(SymbolId) = .empty;
        defer one.deinit(gpa);
        var i = file.sym_start;
        while (i < file.sym_end) : (i += 1) {
            const sym = idx.graph.symbols[i];
            if (!reportable(sym.kind)) continue;
            if (!query.symbolTouched(sym, file.text, &.{.{ .lo = h.lo, .hi = h.hi }})) continue;
            try one.append(gpa, sym.id);
            if (!contains(roots.items, sym.id)) try roots.append(gpa, sym.id);
        }
        try hunk_roots.append(gpa, try one.toOwnedSlice(gpa));
    }

    var result = try computeBlast(gpa, ctx, roots.items, .{
        .depth = opts.depth,
        .direction = opts.direction,
        .limit = opts.limit,
        .scope = opts.scope,
    });
    defer result.deinit(gpa);

    try w.writeAll("{\"roots\":");
    try payload.writeSymbolArray(w, ctx, roots.items);
    try w.writeByte(',');
    try writeBlastNodesAndEdges(w, ctx, result);
    try w.writeAll(",\"summary\":");
    try writeBlastSummary(w, gpa, ctx, result.nodes.items, result.truncated);
    try w.writeAll(",\"hunks\":[");
    for (hunks.items, hunk_roots.items, 0..) |h, hr, i| {
        if (i != 0) try w.writeByte(',');
        const file = idx.graph.files[h.file];
        try w.writeAll("{\"uri\":\"");
        try overlay.writeUriIn(w, ctx.session.root_abs, file.path);
        try w.writeAll("\",\"range\":");
        try payload.writeLineRange(w, file.text, h.lo, h.hi, ctx.encoding);
        try w.writeAll(",\"roots\":");
        try payload.writeSymbolArray(w, ctx, hr);
        try w.writeByte('}');
    }
    try w.print("],\"changeId\":\"{x:0>16}\"}}", .{changeId(idx, hunks.items)});
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/// Write `{items:[{symbol,handler,callers:Symbol[]}]}` for every `route`
/// symbol whose name contains `filter`.
pub fn writeRoutes(w: *Writer, ctx: Ctx, filter: []const u8, limit: u32) !void {
    const idx = ctx.index();
    try w.writeAll("{\"items\":[");
    var shown: u32 = 0;
    var total: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (sym.kind != .route) continue;
        if (filter.len != 0 and std.mem.indexOf(u8, sym.name, filter) == null) continue;
        total += 1;
        if (shown >= limit) continue;
        if (shown != 0) try w.writeByte(',');
        try writeRouteItem(w, ctx, sym);
        shown += 1;
    }
    try w.print("],\"truncated\":{}}}", .{total > shown});
}

fn writeRouteItem(w: *Writer, ctx: Ctx, route: Symbol) !void {
    const idx = ctx.index();
    try w.writeAll("{\"symbol\":");
    try payload.writeSymbolId(w, ctx, route.id);
    try w.writeAll(",\"handler\":");
    var handler: SymbolId = invalid;
    for (route.refs) |ref| {
        if (ref.kind == .call and ref.target != invalid) handler = ref.target;
    }
    if (handler == invalid) {
        try w.writeAll("null");
    } else {
        try payload.writeSymbolId(w, ctx, handler);
    }
    try w.writeAll(",\"callers\":[");
    for (idx.callersOf(route.id), 0..) |cid, k| {
        if (k != 0) try w.writeByte(',');
        try payload.writeSymbolId(w, ctx, cid);
    }
    try w.writeAll("]}");
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// Write `{groups:[{key,sites:[{role,verb,file,uri,line,in?}]}]}`, linking
/// message-bus handlers (register/on) to emitters (send/emit) by string key.
pub fn writeEvents(w: *Writer, ctx: Ctx, filter: []const u8, limit: u32) !void {
    const idx = ctx.index();
    const sites = try query.collectEvents(idx, filter);
    defer idx.gpa.free(sites);

    try w.writeAll("{\"groups\":[");
    var shown_keys: u32 = 0;
    var i: usize = 0;
    while (i < sites.len and shown_keys < limit) {
        const key = sites[i].ref.key;
        if (shown_keys != 0) try w.writeByte(',');
        try w.writeAll("{\"key\":");
        try payload.writeString(w, key);
        try w.writeAll(",\"sites\":[");
        var first = true;
        while (i < sites.len and std.mem.eql(u8, sites[i].ref.key, key)) : (i += 1) {
            if (!first) try w.writeByte(',');
            first = false;
            try writeEventSite(w, ctx, sites[i]);
        }
        try w.writeAll("]}");
        shown_keys += 1;
    }
    try w.print("],\"truncated\":{}}}", .{i < sites.len});
}

fn writeEventSite(w: *Writer, ctx: Ctx, site: query.EventSite) !void {
    const idx = ctx.index();
    const file = idx.graph.files[site.file];
    try w.writeAll("{\"role\":\"");
    try w.writeAll(if (site.ref.role == .handler) "handler" else "emitter");
    try w.writeAll("\",\"verb\":");
    try payload.writeString(w, site.ref.verb);
    try w.writeAll(",\"file\":");
    try payload.writeString(w, file.path);
    try w.writeAll(",\"uri\":\"");
    try overlay.writeUriIn(w, ctx.session.root_abs, file.path);
    try w.print("\",\"line\":{d}", .{site.ref.line});
    const owner = query.enclosingSymbolName(idx, file, site.ref.offset);
    if (owner.len != 0) {
        try w.writeAll(",\"in\":");
        try payload.writeString(w, owner);
    }
    try w.writeByte('}');
}

// ---------------------------------------------------------------------------
// Imports / importers
// ---------------------------------------------------------------------------

/// Write `{files:[{file,uri,imports:[{target,targetUri,binding}]}]}`: the
/// local modules each in-scope file imports (resolved edges only). `limit`
/// caps the number of *files* listed — unlike every other list method, this
/// one had no cap at all, so an empty filter on a large tree serialized every
/// import edge in the graph into one response (coldstart review F13).
pub fn writeImports(w: *Writer, ctx: Ctx, filter: []const u8, limit: u32) !void {
    const idx = ctx.index();
    try w.writeAll("{\"files\":[");
    var first = true;
    var shown: u32 = 0;
    var total: u32 = 0;
    for (idx.graph.files) |file| {
        const imps = idx.importsOf(file.id);
        if (imps.len == 0 or !query.matchesFilter(file.path, filter)) continue;
        total += 1;
        if (shown >= limit) continue;
        shown += 1;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"file\":");
        try payload.writeString(w, file.path);
        try w.writeAll(",\"uri\":\"");
        try overlay.writeUriIn(w, ctx.session.root_abs, file.path);
        try w.writeAll("\",\"imports\":[");
        for (imps, 0..) |imp, k| {
            if (k != 0) try w.writeByte(',');
            const target = idx.graph.files[imp.target];
            try w.writeAll("{\"target\":");
            try payload.writeString(w, target.path);
            try w.writeAll(",\"targetUri\":\"");
            try overlay.writeUriIn(w, ctx.session.root_abs, target.path);
            try w.writeAll("\",\"binding\":");
            try payload.writeString(w, imp.binding);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.print("],\"truncated\":{}}}", .{total > shown});
}

/// Write `{files:[{file,uri,importers:[{file,uri}]}]}`: files that import
/// the file(s) matching `path` — reverse dependencies.
///
/// Builds one reverse-import index in a single pass over every file's
/// (already-resolved) import list, rather than rescanning every file's
/// imports for every matching target — O(files) instead of O(files) per
/// target, which was quadratic in file count for a broad filter (F13). Not
/// cached across requests: `index.zig` (generation lifecycle, cache
/// invalidation) is out of scope for this change.
pub fn writeImporters(w: *Writer, ctx: Ctx, path: []const u8, limit: u32) !void {
    const idx = ctx.index();
    const gpa = idx.gpa;

    var importers_of: std.AutoHashMapUnmanaged(model.FileId, std.ArrayList(model.FileId)) = .empty;
    defer {
        var it = importers_of.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        importers_of.deinit(gpa);
    }
    for (idx.graph.files) |src| {
        for (idx.importsOf(src.id)) |imp| {
            const gop = try importers_of.getOrPut(gpa, imp.target);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const list = gop.value_ptr;
            // A file that imports the same target under two bindings (two
            // edges, one src) must still appear once, matching the old
            // per-target `fileImportsFile` bool check.
            if (list.items.len == 0 or list.items[list.items.len - 1] != src.id) {
                try list.append(gpa, src.id);
            }
        }
    }

    try w.writeAll("{\"files\":[");
    var first = true;
    var shown: u32 = 0;
    var total: u32 = 0;
    for (idx.graph.files) |target| {
        if (!query.matchesFilter(target.path, path)) continue;
        total += 1;
        if (shown >= limit) continue;
        shown += 1;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"file\":");
        try payload.writeString(w, target.path);
        try w.writeAll(",\"uri\":\"");
        try overlay.writeUriIn(w, ctx.session.root_abs, target.path);
        try w.writeAll("\",\"importers\":[");
        if (importers_of.get(target.id)) |list| {
            for (list.items, 0..) |src_id, k| {
                if (k != 0) try w.writeByte(',');
                const src = idx.graph.files[src_id];
                try w.writeAll("{\"file\":");
                try payload.writeString(w, src.path);
                try w.writeAll(",\"uri\":\"");
                try overlay.writeUriIn(w, ctx.session.root_abs, src.path);
                try w.writeAll("\"}");
            }
        }
        try w.writeAll("]}");
    }
    try w.print("],\"truncated\":{}}}", .{total > shown});
}

// ---------------------------------------------------------------------------
// Graph
// ---------------------------------------------------------------------------

/// Render the interactive HTML graph (over `viz.graph`) and write it to
/// `.navgraph/graph-<hash>.html` under the served root — `<hash>` identifies
/// the *view* (the filter and test scope), not the content, so re-requesting
/// the same view overwrites its one file in place rather than accumulating a
/// new one per edit (coldstart review F7). The write goes through
/// `fswrite.writeGuarded`: an atomic rename that never follows a symlink an
/// untrusted repo may have planted at the (predictable) path (F1). Writes
/// `{path}`, root-relative. On a write failure, `detail.*` names the cause
/// for the caller to surface (F11).
pub fn writeGraphFile(
    w: *Writer,
    gpa: std.mem.Allocator,
    ctx: Ctx,
    path_filter: []const u8,
    scope: Scope,
    detail: *?[]const u8,
) !void {
    const s = ctx.session;
    var html: Writer.Allocating = .init(gpa);
    defer html.deinit();
    // The page itself has nowhere to say it was capped, so the node counts ride
    // back on the response instead of a capped subgraph passing for the graph.
    const cut = try viz.graph(&html.writer, ctx.index(), path_filter, .{ .tests = scope.tests });
    const bytes = html.written();

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(path_filter);
    hasher.update(&.{@intFromEnum(scope.tests)});
    const rel = try std.fmt.allocPrint(gpa, ".navgraph/graph-{x:0>16}.html", .{hasher.final()});
    defer gpa.free(rel);

    try fswrite.writeGuarded(gpa, s.io, s.root_dir, rel, bytes, detail);

    try w.writeAll("{\"path\":");
    try payload.writeString(w, rel);
    try w.print(",\"nodes\":{d},\"nodesTotal\":{d},\"truncated\":{}}}", .{ cut.shown, cut.total, cut.any() });
}
