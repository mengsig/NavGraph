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

/// `InvalidGitPath`: git reported a diff path the parser cannot use — a real
/// failure, never reported to the editor as "nothing changed".
pub const Error = error{ SymbolNotFound, FileNotIndexed, InvalidGitPath } || std.mem.Allocator.Error;

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
    };
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
/// dispatcher turns into the contract's `-32001`.
pub fn resolveTarget(
    gpa: std.mem.Allocator,
    ctx: Ctx,
    target: Target,
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
        .git_ref => |spec| try changedSince(gpa, ctx, spec, &out),
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

/// Definitions touched since `spec` (`navgraph diff`'s rule) plus every
/// definition in a file whose unsaved buffer differs from the copy on disk.
fn changedSince(
    gpa: std.mem.Allocator,
    ctx: Ctx,
    spec: []const u8,
    out: *std.ArrayList(SymbolId),
) Error!void {
    const s = ctx.session;
    const idx = &s.idx;
    const ref = if (spec.len != 0) spec else "HEAD";

    if (query.runGitDiff(gpa, s.io, s.root_path, ref)) |result| {
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) {
            const changes = try gitdiff.parse(gpa, result.stdout);
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
        }
    } else |_| {
        // Not a git tree, or git is unavailable: the unsaved-buffer half of the
        // answer still stands, so this is not a failure of the request.
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

/// Walk the graph from `roots` and write the contract's blast result.
///
/// Each symbol appears once, at the shallowest depth it was reached; `via`
/// records the depth-1 neighbours it was reached through. Edges are always
/// written caller→callee whichever direction the walk ran.
pub fn writeBlast(
    w: *Writer,
    gpa: std.mem.Allocator,
    ctx: Ctx,
    roots: []const SymbolId,
    opts: BlastOptions,
) !void {
    const idx = ctx.index();
    var nodes: std.ArrayList(BlastNode) = .empty;
    var seen: std.AutoHashMapUnmanaged(SymbolId, usize) = .empty;
    var edges: std.ArrayList(BlastEdge) = .empty;
    var edge_seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    // `query.callSiteLines` grows its output with the index's own allocator, so
    // this scratch list must be freed with that one, not the request arena.
    var lines: std.ArrayList(u32) = .empty;
    defer {
        for (nodes.items) |*n| n.via.deinit(gpa);
        nodes.deinit(gpa);
        seen.deinit(gpa);
        for (edges.items) |e| gpa.free(e.lines);
        edges.deinit(gpa);
        edge_seen.deinit(gpa);
        lines.deinit(idx.gpa);
    }

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
        var neighbours = Neighbours.init(idx, from_id, opts.direction);
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

    try w.writeAll("{\"roots\":");
    try payload.writeSymbolArray(w, ctx, roots);
    try w.writeAll(",\"nodes\":[");
    for (nodes.items, 0..) |n, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try payload.writeSymbolId(w, ctx, n.id);
        try w.print(",\"depth\":{d},\"via\":", .{n.depth});
        try payload.writeLines(w, n.via.items);
        try w.print(",\"exact\":{}}}", .{n.exact});
    }
    try w.writeAll("],\"edges\":[");
    for (edges.items, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try payload.writeEdge(w, e.from, e.to, e.exact, e.lines);
    }
    try w.writeAll("],\"summary\":");
    try writeBlastSummary(w, gpa, ctx, nodes.items, truncated);
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

/// Iterate a symbol's graph neighbours in one direction, applying the same
/// dead-read filter the CLI's call tree uses.
const Neighbours = struct {
    idx: *const Index,
    id: SymbolId,
    direction: Direction,
    refs: []const model.Reference,
    callers: []const SymbolId,
    i: usize,

    const Item = struct { id: SymbolId, exact: bool };

    fn init(idx: *const Index, id: SymbolId, direction: Direction) Neighbours {
        return .{
            .idx = idx,
            .id = id,
            .direction = direction,
            .refs = idx.graph.symbols[id].refs,
            .callers = idx.callersOf(id),
            .i = 0,
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
                if (query.isDataReadEdge(self.idx, ref)) continue;
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
    var it = Neighbours.init(idx, id, opts.direction);
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
        const end_line = sym.endLine(file.text) - 1;
        const end_col = position.byteToColumn(position.lineSlice(file.text, end_line) orelse "", ctx.encoding);
        try w.print(
            "{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
            .{ sym.line - 1, end_line, end_col },
        );
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
