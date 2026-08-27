//! Accuracy benchmark: score NavGraph's index against hand-verified golden
//! corpora, one per supported language.
//!
//! Golden files (`tests/golden/<lang>.json`) record the definitions and
//! reference edges a correct indexer must produce for a `testenv/` fixture
//! tree. This tool indexes each tree, extracts the same two sets, and reports
//! precision/recall per language plus every miss, phantom and mismatch with a
//! `file:line` a fixer can act on.
//!
//! It deliberately links the graph engine instead of shelling out to the CLI:
//! the JSON surfaces drop kinds (`graph -j` keeps only callable/type nodes), so
//! measuring through them would silently exempt the very constructs — closures
//! bound to variables, fields, constants — the corpora exist to stress.
//!
//! Modes:
//!   accuracy-bench <repo-root>                     score every golden vs floors
//!   accuracy-bench <repo-root> --update-floors     rewrite floors from the run
//!   accuracy-bench <repo-root> --propose <root>    emit a golden skeleton
//!
//! `--propose` reports what the indexer currently sees. That is an authoring
//! aid, never ground truth: every entry is hand-checked against the source (and
//! a reference language server where one exists) before it enters a golden file.

const std = @import("std");
const navgraph = @import("NavGraph");
const model = navgraph.model;
const index_mod = navgraph.index;

const BenchError = error{ UsageError, GoldenInvalid, BelowFloor };

const golden_dir_path = "tests/golden";
const floors_file = "floors.json";

/// A definition as both sides of the comparison spell it.
const Def = struct {
    file: []const u8,
    name: []const u8,
    qualified: []const u8,
    kind: []const u8,
    line: u32,
    parent: ?[]const u8,
};

/// A reference edge, keyed `file:qualified` on both ends. `lines` holds every
/// distinct 1-based line the reference occurs on, ascending.
const Edge = struct {
    from: []const u8,
    to: []const u8,
    exact: bool,
    lines: []const u32,
};

const GoldenDef = struct {
    file: []const u8,
    name: []const u8,
    qualified: []const u8,
    kind: []const u8,
    line: u32,
    parent: ?[]const u8 = null,
};

const GoldenEdge = struct {
    from: []const u8,
    to: []const u8,
    exact: bool,
    lines: []const u32,
    verified: []const u8,
};

const Golden = struct {
    language: []const u8,
    root: []const u8,
    /// Free-form authoring notes; ignored by scoring.
    notes: ?[]const u8 = null,
    definitions: []const GoldenDef,
    edges: []const GoldenEdge,
};

/// Recorded per-language minimum, in basis points (0..10000). The gate is
/// ratchet-only: `--update-floors` may raise a floor, never silently lower one.
const Floor = struct {
    language: []const u8,
    def_precision_bp: u32,
    def_recall_bp: u32,
    edge_precision_bp: u32,
    edge_recall_bp: u32,
    exact_agreement_bp: u32,
};

const Floors = struct { floors: []const Floor };

/// Truncating precision/recall in basis points. Both-empty scores a perfect
/// 10000 (nothing expected, nothing produced); a non-empty denominator with no
/// matches scores 0.
fn ratioBp(matched: usize, total: usize) u32 {
    if (total == 0) return 10000;
    return @intCast(matched * 10000 / total);
}

fn fmtBp(bp: u32) struct { whole: u32, frac: u32 } {
    return .{ .whole = bp / 100, .frac = bp % 100 };
}

const Score = struct {
    matched: usize = 0,
    actual: usize = 0,
    expected: usize = 0,

    fn precisionBp(self: Score) u32 {
        return ratioBp(self.matched, self.actual);
    }
    fn recallBp(self: Score) u32 {
        return ratioBp(self.matched, self.expected);
    }
};

const LanguageResult = struct {
    language: []const u8,
    root: []const u8,
    defs: Score,
    edges: Score,
    /// Of the matched edges, how many agree with the golden `exact` flag.
    exact_agree: usize,
    findings: []const Finding,

    fn exactAgreementBp(self: LanguageResult) u32 {
        return ratioBp(self.exact_agree, self.edges.matched);
    }
};

const FindingKind = enum {
    def_missing,
    def_phantom,
    def_mismatch,
    edge_missing,
    edge_phantom,
    edge_exactness,
};

const Finding = struct {
    kind: FindingKind,
    /// `file:line` of the item, or of the golden item when it is missing.
    site: []const u8,
    detail: []const u8,

    fn label(self: Finding) []const u8 {
        return switch (self.kind) {
            .def_missing => "MISS  def   ",
            .def_phantom => "PHANTOM def ",
            .def_mismatch => "MISBOUND def",
            .edge_missing => "MISS  edge  ",
            .edge_phantom => "PHANTOM edge",
            .edge_exactness => "EXACTNESS   ",
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args) catch {
        std.debug.print(
            "usage: accuracy-bench <repo-root> [--update-floors] [--propose <fixture-root>] [-j]\n",
            .{},
        );
        return BenchError.UsageError;
    };

    var repo = try std.Io.Dir.cwd().openDir(io, opts.repo_root, .{ .iterate = true });
    defer repo.close(io);

    if (opts.propose) |fixture_root| {
        try propose(gpa, arena, io, out, opts.repo_root, fixture_root);
        try out.flush();
        return;
    }

    const results = try scoreAll(gpa, arena, io, repo, opts.repo_root);

    if (opts.update_floors) {
        try writeFloors(arena, io, repo, results);
        try report(out, results, null, opts.json);
        try out.flush();
        return;
    }

    const floors = try loadFloors(arena, io, repo);
    try report(out, results, floors, opts.json);
    try out.flush();
    if (violations(results, floors) != 0) return BenchError.BelowFloor;
}

const Options = struct {
    repo_root: []const u8,
    update_floors: bool = false,
    propose: ?[]const u8 = null,
    json: bool = false,
};

fn parseArgs(args: []const []const u8) !Options {
    if (args.len < 2) return BenchError.UsageError;
    var opts = Options{ .repo_root = args[1] };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--update-floors")) {
            opts.update_floors = true;
        } else if (std.mem.eql(u8, a, "-j") or std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, a, "--propose")) {
            i += 1;
            if (i >= args.len) return BenchError.UsageError;
            opts.propose = args[i];
        } else return BenchError.UsageError;
    }
    return opts;
}

// ---------------------------------------------------------------------------
// Extraction: Index -> (definitions, edges)
// ---------------------------------------------------------------------------

/// Kinds excluded from the definition set. Imports are bindings, not
/// definitions; routes and router mounts are derived routing artifacts owned by
/// the `routes` command; a module/namespace declaration is a scoping directive
/// rather than something a reader navigates to (its name still shows up in the
/// qualified name of anything it actually contains).
fn isScoredDefKind(kind: model.SymbolKind) bool {
    return switch (kind) {
        .import, .route, .route_mount, .module => false,
        else => true,
    };
}

/// Reference kinds that become scored edges: a call and a type use are the two
/// forms of "this definition depends on that definition". Plain reads and
/// module imports are file/value-level and are not part of the symbol graph.
fn isScoredRefKind(kind: model.RefKind) bool {
    return switch (kind) {
        .call, .type_use => true,
        .read, .import, .route_call => false,
    };
}

const Extracted = struct {
    defs: []Def,
    edges: []Edge,
};

/// Dotted name of `sym` within its file: every enclosing symbol, outermost
/// first, joined with `.`.
fn qualifiedName(arena: std.mem.Allocator, graph: model.Graph, sym: model.Symbol) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    try parts.append(arena, sym.name);
    var p = sym.parent;
    var guard: usize = 0;
    while (p != model.invalid_symbol) {
        // Parent chains are acyclic by construction; bound the walk so a future
        // parser bug degrades into a truncated name instead of a hang.
        guard += 1;
        if (guard > 64) break;
        const parent = graph.symbols[p];
        try parts.append(arena, parent.name);
        p = parent.parent;
    }
    std.mem.reverse([]const u8, parts.items);
    return std.mem.join(arena, ".", parts.items);
}

fn extract(gpa: std.mem.Allocator, arena: std.mem.Allocator, idx: *const index_mod.Index) !Extracted {
    const graph = idx.graph;

    // Per-symbol keys, indexed by SymbolId, so an edge endpoint is one lookup.
    const keys = try arena.alloc(?[]const u8, graph.symbols.len);
    @memset(keys, null);
    const quals = try arena.alloc([]const u8, graph.symbols.len);

    var defs: std.ArrayList(Def) = .empty;
    defer defs.deinit(gpa);
    for (graph.symbols) |sym| {
        const qual = try qualifiedName(arena, graph, sym);
        quals[sym.id] = qual;
        const file = graph.files[sym.file].path;
        keys[sym.id] = try std.fmt.allocPrint(arena, "{s}:{s}", .{ file, qual });
        if (!isScoredDefKind(sym.kind)) continue;
        const parent: ?[]const u8 = if (sym.parent == model.invalid_symbol)
            null
        else
            try qualifiedName(arena, graph, graph.symbols[sym.parent]);
        try defs.append(gpa, .{
            .file = file,
            .name = sym.name,
            .qualified = qual,
            .kind = sym.kind.tag(),
            .line = sym.line,
            .parent = parent,
        });
    }

    // Edges are deduped per (from, to): a caller hitting the same target on
    // several lines is one dependency with several sites. The merged edge is
    // exact only when every contributing reference resolved exactly, matching
    // what `--strict` traversal would be willing to follow.
    var edge_at = std.StringHashMap(usize).init(gpa);
    defer edge_at.deinit();
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var lines_of: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (lines_of.items) |*l| l.deinit(gpa);
        lines_of.deinit(gpa);
    }

    for (graph.symbols) |sym| {
        if (!isScoredDefKind(sym.kind)) continue;
        for (sym.refs) |ref| {
            if (ref.target == model.invalid_symbol) continue;
            if (!isScoredRefKind(ref.kind)) continue;
            const target = graph.symbols[ref.target];
            if (!isScoredDefKind(target.kind)) continue;
            const from = keys[sym.id].?;
            const to = keys[ref.target].?;
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ from, to });
            const slot = try edge_at.getOrPut(key);
            if (!slot.found_existing) {
                slot.value_ptr.* = edges.items.len;
                try edges.append(gpa, .{ .from = from, .to = to, .exact = ref.exact, .lines = &.{} });
                try lines_of.append(gpa, .empty);
            }
            const at = slot.value_ptr.*;
            edges.items[at].exact = edges.items[at].exact and ref.exact;
            try addLine(gpa, &lines_of.items[at], ref.line);
            for (ref.lines) |l| try addLine(gpa, &lines_of.items[at], l);
        }
    }

    for (edges.items, lines_of.items) |*e, *l| {
        std.mem.sort(u32, l.items, {}, ascU32);
        e.lines = try arena.dupe(u32, l.items);
    }

    const out_defs = try arena.dupe(Def, defs.items);
    const out_edges = try arena.dupe(Edge, edges.items);
    std.mem.sort(Def, out_defs, {}, defLess);
    std.mem.sort(Edge, out_edges, {}, edgeLess);
    return .{ .defs = out_defs, .edges = out_edges };
}

fn addLine(gpa: std.mem.Allocator, list: *std.ArrayList(u32), line: u32) !void {
    for (list.items) |existing| if (existing == line) return;
    try list.append(gpa, line);
}

fn ascU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

fn defLess(_: void, a: Def, b: Def) bool {
    const by_file = std.mem.order(u8, a.file, b.file);
    if (by_file != .eq) return by_file == .lt;
    if (a.line != b.line) return a.line < b.line;
    const by_qual = std.mem.order(u8, a.qualified, b.qualified);
    if (by_qual != .eq) return by_qual == .lt;
    return std.mem.order(u8, a.kind, b.kind) == .lt;
}

fn edgeLess(_: void, a: Edge, b: Edge) bool {
    const by_from = std.mem.order(u8, a.from, b.from);
    if (by_from != .eq) return by_from == .lt;
    return std.mem.order(u8, a.to, b.to) == .lt;
}

// ---------------------------------------------------------------------------
// Scoring
// ---------------------------------------------------------------------------

/// Match golden definitions against extracted ones. Definitions are bucketed by
/// `file:qualified` because overloads legitimately share that key; within a
/// bucket a pair matches only when kind AND line agree. Leftovers on both sides
/// of a non-empty bucket are reported as a mismatch (the fixer's most useful
/// signal) while still counting as one miss and one phantom.
fn scoreDefs(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    golden: []const GoldenDef,
    actual: []const Def,
    findings: *std.ArrayList(Finding),
) !Score {
    var buckets = std.StringHashMap(Bucket).init(gpa);
    defer {
        var it = buckets.valueIterator();
        while (it.next()) |b| b.deinit(gpa);
        buckets.deinit();
    }

    for (golden, 0..) |g, i| {
        const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ g.file, g.qualified });
        const slot = try buckets.getOrPut(key);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        try slot.value_ptr.expected.append(gpa, i);
    }
    for (actual, 0..) |a, i| {
        const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ a.file, a.qualified });
        const slot = try buckets.getOrPut(key);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        try slot.value_ptr.produced.append(gpa, i);
    }

    var score = Score{ .actual = actual.len, .expected = golden.len };
    // Deterministic order: walk the sorted inputs, visiting each bucket once.
    var done = std.StringHashMap(void).init(gpa);
    defer done.deinit();
    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(gpa);
    for (golden) |g| try pushKeyOnce(gpa, arena, &done, &order, g.file, g.qualified);
    for (actual) |a| try pushKeyOnce(gpa, arena, &done, &order, a.file, a.qualified);

    for (order.items) |key| {
        const b = buckets.getPtr(key).?;
        var taken = try gpa.alloc(bool, b.produced.items.len);
        defer gpa.free(taken);
        @memset(taken, false);
        var unmatched_expected: std.ArrayList(usize) = .empty;
        defer unmatched_expected.deinit(gpa);

        for (b.expected.items) |gi| {
            const g = golden[gi];
            var hit = false;
            for (b.produced.items, 0..) |ai, slot| {
                if (taken[slot]) continue;
                const a = actual[ai];
                if (a.line != g.line) continue;
                if (!std.mem.eql(u8, a.kind, g.kind)) continue;
                taken[slot] = true;
                hit = true;
                score.matched += 1;
                break;
            }
            if (!hit) try unmatched_expected.append(gpa, gi);
        }

        var leftover_produced: std.ArrayList(usize) = .empty;
        defer leftover_produced.deinit(gpa);
        for (b.produced.items, 0..) |ai, slot| {
            if (!taken[slot]) try leftover_produced.append(gpa, ai);
        }

        // Pair leftovers positionally so a wrong line/kind reads as one
        // misbinding rather than an unrelated miss plus an unrelated phantom.
        // What is left over after the pairing is a plain miss or phantom.
        const paired = @min(unmatched_expected.items.len, leftover_produced.items.len);
        for (unmatched_expected.items[0..paired], leftover_produced.items[0..paired]) |gi, ai| {
            const g = golden[gi];
            const a = actual[ai];
            try findings.append(gpa, .{
                .kind = .def_mismatch,
                .site = try std.fmt.allocPrint(arena, "{s}:{d}", .{ g.file, g.line }),
                .detail = try std.fmt.allocPrint(
                    arena,
                    "{s}: expected {s} at line {d}, got {s} at line {d}",
                    .{ g.qualified, g.kind, g.line, a.kind, a.line },
                ),
            });
        }
        for (unmatched_expected.items[paired..]) |gi| {
            const g = golden[gi];
            try findings.append(gpa, .{
                .kind = .def_missing,
                .site = try std.fmt.allocPrint(arena, "{s}:{d}", .{ g.file, g.line }),
                .detail = try std.fmt.allocPrint(arena, "{s} ({s})", .{ g.qualified, g.kind }),
            });
        }
        for (leftover_produced.items[paired..]) |ai| {
            const a = actual[ai];
            try findings.append(gpa, .{
                .kind = .def_phantom,
                .site = try std.fmt.allocPrint(arena, "{s}:{d}", .{ a.file, a.line }),
                .detail = try std.fmt.allocPrint(arena, "{s} ({s})", .{ a.qualified, a.kind }),
            });
        }
    }
    return score;
}

const Bucket = struct {
    expected: std.ArrayList(usize) = .empty,
    produced: std.ArrayList(usize) = .empty,

    fn deinit(self: *Bucket, gpa: std.mem.Allocator) void {
        self.expected.deinit(gpa);
        self.produced.deinit(gpa);
    }
};

fn pushKeyOnce(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    done: *std.StringHashMap(void),
    order: *std.ArrayList([]const u8),
    file: []const u8,
    qualified: []const u8,
) !void {
    const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ file, qualified });
    if ((try done.getOrPut(key)).found_existing) return;
    try order.append(gpa, key);
}

/// Match edges on (from, to). Matched edges additionally contribute to the
/// exact-flag agreement rate; a disagreement is reported but still a match,
/// because the endpoints are right and only the confidence bit is wrong.
fn scoreEdges(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    golden: []const GoldenEdge,
    actual: []const Edge,
    findings: *std.ArrayList(Finding),
    exact_agree: *usize,
) !Score {
    var produced = std.StringHashMap(usize).init(gpa);
    defer produced.deinit();
    for (actual, 0..) |a, i| {
        try produced.put(try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ a.from, a.to }), i);
    }
    var expected = std.StringHashMap(void).init(gpa);
    defer expected.deinit();

    var score = Score{ .actual = actual.len, .expected = golden.len };
    for (golden) |g| {
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ g.from, g.to });
        try expected.put(key, {});
        const hit = produced.get(key) orelse {
            try findings.append(gpa, .{
                .kind = .edge_missing,
                .site = try edgeSite(arena, g.from, g.lines),
                .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ g.from, g.to }),
            });
            continue;
        };
        score.matched += 1;
        const a = actual[hit];
        if (a.exact == g.exact) {
            exact_agree.* += 1;
        } else {
            try findings.append(gpa, .{
                .kind = .edge_exactness,
                .site = try edgeSite(arena, a.from, a.lines),
                .detail = try std.fmt.allocPrint(
                    arena,
                    "{s} -> {s}: expected exact={}, got exact={}",
                    .{ g.from, g.to, g.exact, a.exact },
                ),
            });
        }
    }
    for (actual) |a| {
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ a.from, a.to });
        if (expected.contains(key)) continue;
        try findings.append(gpa, .{
            .kind = .edge_phantom,
            .site = try edgeSite(arena, a.from, a.lines),
            .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ a.from, a.to }),
        });
    }
    return score;
}

/// `file:line` for an edge: the owning file of `from` plus its first call site.
fn edgeSite(arena: std.mem.Allocator, from: []const u8, lines: []const u32) ![]const u8 {
    const file = from[0 .. std.mem.indexOfScalar(u8, from, ':') orelse from.len];
    const line: u32 = if (lines.len == 0) 0 else lines[0];
    return std.fmt.allocPrint(arena, "{s}:{d}", .{ file, line });
}

// ---------------------------------------------------------------------------
// Golden / floors IO
// ---------------------------------------------------------------------------

fn scoreAll(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    repo: std.Io.Dir,
    repo_root: []const u8,
) ![]LanguageResult {
    const names = try goldenFileNames(gpa, arena, io, repo);
    if (names.len == 0) {
        std.debug.print("accuracy-bench: no golden files under {s}\n", .{golden_dir_path});
        return BenchError.GoldenInvalid;
    }
    var results: std.ArrayList(LanguageResult) = .empty;
    defer results.deinit(gpa);
    for (names) |name| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ golden_dir_path, name });
        const text = try repo.readFileAlloc(io, path, arena, .unlimited);
        const parsed = std.json.parseFromSliceLeaky(Golden, arena, text, .{
            .allocate = .alloc_always,
        }) catch |err| {
            std.debug.print("accuracy-bench: {s}: invalid golden JSON ({s})\n", .{ path, @errorName(err) });
            return BenchError.GoldenInvalid;
        };
        try validateGolden(path, parsed);
        try results.append(gpa, try scoreOne(gpa, arena, io, repo_root, parsed));
    }
    return arena.dupe(LanguageResult, results.items);
}

/// Structural invariants a hand-authored golden must satisfy. Catching these
/// here keeps a typo from silently deflating a language's measured recall.
fn validateGolden(path: []const u8, g: Golden) !void {
    for (g.definitions) |d| {
        const expected_qualified = if (d.parent) |p|
            !std.mem.eql(u8, p, "") and
                std.mem.startsWith(u8, d.qualified, p) and
                d.qualified.len == p.len + 1 + d.name.len and
                d.qualified[p.len] == '.' and
                std.mem.endsWith(u8, d.qualified, d.name)
        else
            std.mem.eql(u8, d.qualified, d.name);
        if (!expected_qualified) {
            std.debug.print(
                "accuracy-bench: {s}: definition {s} in {s}: qualified/parent/name disagree\n",
                .{ path, d.qualified, d.file },
            );
            return BenchError.GoldenInvalid;
        }
        if (d.line == 0) {
            std.debug.print("accuracy-bench: {s}: definition {s} has line 0\n", .{ path, d.qualified });
            return BenchError.GoldenInvalid;
        }
    }
    for (g.edges) |e| {
        if (!std.mem.eql(u8, e.verified, "lsp") and !std.mem.eql(u8, e.verified, "manual")) {
            std.debug.print(
                "accuracy-bench: {s}: edge {s} -> {s}: verified must be \"lsp\" or \"manual\"\n",
                .{ path, e.from, e.to },
            );
            return BenchError.GoldenInvalid;
        }
        if (std.mem.indexOfScalar(u8, e.from, ':') == null or std.mem.indexOfScalar(u8, e.to, ':') == null) {
            std.debug.print(
                "accuracy-bench: {s}: edge endpoints must be file:qualified ({s} -> {s})\n",
                .{ path, e.from, e.to },
            );
            return BenchError.GoldenInvalid;
        }
    }
}

fn scoreOne(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    g: Golden,
) !LanguageResult {
    const root = try std.fs.path.join(arena, &.{ repo_root, g.root });
    // Never read or write `.navgraph/cache`: the benchmark must measure this
    // build's parser, and it must not mutate the checked-in fixture trees.
    var idx = try index_mod.build(gpa, io, root, false);
    defer idx.deinit();
    const got = try extract(gpa, arena, &idx);

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);
    const defs = try scoreDefs(gpa, arena, g.definitions, got.defs, &findings);
    var exact_agree: usize = 0;
    const edges = try scoreEdges(gpa, arena, g.edges, got.edges, &findings, &exact_agree);

    return .{
        .language = g.language,
        .root = g.root,
        .defs = defs,
        .edges = edges,
        .exact_agree = exact_agree,
        .findings = try arena.dupe(Finding, findings.items),
    };
}

fn goldenFileNames(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    repo: std.Io.Dir,
) ![][]const u8 {
    var dir = try repo.openDir(io, golden_dir_path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.eql(u8, entry.name, floors_file)) continue;
        try names.append(gpa, try arena.dupe(u8, entry.name));
    }
    const out = try arena.dupe([]const u8, names.items);
    std.mem.sort([]const u8, out, {}, strLess);
    return out;
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn loadFloors(arena: std.mem.Allocator, io: std.Io, repo: std.Io.Dir) !Floors {
    const path = golden_dir_path ++ "/" ++ floors_file;
    const text = repo.readFileAlloc(io, path, arena, .unlimited) catch |err| {
        std.debug.print("accuracy-bench: cannot read {s} ({s})\n", .{ path, @errorName(err) });
        return BenchError.GoldenInvalid;
    };
    return std.json.parseFromSliceLeaky(Floors, arena, text, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("accuracy-bench: {s}: invalid floors JSON ({s})\n", .{ path, @errorName(err) });
        return BenchError.GoldenInvalid;
    };
}

fn writeFloors(arena: std.mem.Allocator, io: std.Io, repo: std.Io.Dir, results: []const LanguageResult) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    var w: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    defer buf = w.toArrayList();
    const o = &w.writer;
    try o.writeAll("{\n  \"floors\": [\n");
    for (results, 0..) |r, i| {
        if (i != 0) try o.writeAll(",\n");
        try o.print(
            "    {{ \"language\": \"{s}\", \"def_precision_bp\": {d}, \"def_recall_bp\": {d}, " ++
                "\"edge_precision_bp\": {d}, \"edge_recall_bp\": {d}, \"exact_agreement_bp\": {d} }}",
            .{
                r.language,
                r.defs.precisionBp(),
                r.defs.recallBp(),
                r.edges.precisionBp(),
                r.edges.recallBp(),
                r.exactAgreementBp(),
            },
        );
    }
    try o.writeAll("\n  ]\n}\n");
    try repo.writeFile(io, .{ .sub_path = golden_dir_path ++ "/" ++ floors_file, .data = w.written() });
}

fn floorFor(floors: Floors, language: []const u8) ?Floor {
    for (floors.floors) |f| {
        if (std.mem.eql(u8, f.language, language)) return f;
    }
    return null;
}

fn violations(results: []const LanguageResult, floors: Floors) usize {
    var n: usize = 0;
    for (results) |r| {
        const f = floorFor(floors, r.language) orelse {
            n += 1;
            continue;
        };
        if (r.defs.precisionBp() < f.def_precision_bp) n += 1;
        if (r.defs.recallBp() < f.def_recall_bp) n += 1;
        if (r.edges.precisionBp() < f.edge_precision_bp) n += 1;
        if (r.edges.recallBp() < f.edge_recall_bp) n += 1;
        if (r.exactAgreementBp() < f.exact_agreement_bp) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

fn report(out: *std.Io.Writer, results: []const LanguageResult, floors: ?Floors, json: bool) !void {
    if (json) return reportJson(out, results, floors);

    try out.writeAll("language      defs  P /  R   (match/got/want)   edges  P /  R   (match/got/want)  exact\n");
    var total = LanguageResult{
        .language = "TOTAL",
        .root = "",
        .defs = .{},
        .edges = .{},
        .exact_agree = 0,
        .findings = &.{},
    };
    for (results) |r| {
        try reportRow(out, r);
        total.defs.matched += r.defs.matched;
        total.defs.actual += r.defs.actual;
        total.defs.expected += r.defs.expected;
        total.edges.matched += r.edges.matched;
        total.edges.actual += r.edges.actual;
        total.edges.expected += r.edges.expected;
        total.exact_agree += r.exact_agree;
    }
    try out.writeAll("\n");
    try reportRow(out, total);

    for (results) |r| {
        if (r.findings.len == 0) continue;
        try out.print("\n--- {s} ({s}): {d} finding(s)\n", .{ r.language, r.root, r.findings.len });
        for (r.findings) |f| {
            try out.print("  {s} {s}/{s}  {s}\n", .{ f.label(), r.root, f.site, f.detail });
        }
    }

    if (floors) |fl| try reportFloors(out, results, fl);
}

fn reportRow(out: *std.Io.Writer, r: LanguageResult) !void {
    const dp = fmtBp(r.defs.precisionBp());
    const dr = fmtBp(r.defs.recallBp());
    const ep = fmtBp(r.edges.precisionBp());
    const er = fmtBp(r.edges.recallBp());
    const ex = fmtBp(r.exactAgreementBp());
    try out.print(
        "{s: <12}  {d: >3}.{d:0>2}/{d: >3}.{d:0>2}  ({d: >4}/{d: >4}/{d: >4})   {d: >3}.{d:0>2}/{d: >3}.{d:0>2}  ({d: >4}/{d: >4}/{d: >4})  {d: >3}.{d:0>2}\n",
        .{
            r.language,
            dp.whole,     dp.frac, dr.whole, dr.frac,
            r.defs.matched, r.defs.actual, r.defs.expected,
            ep.whole,     ep.frac, er.whole, er.frac,
            r.edges.matched, r.edges.actual, r.edges.expected,
            ex.whole,     ex.frac,
        },
    );
}

fn reportFloors(out: *std.Io.Writer, results: []const LanguageResult, floors: Floors) !void {
    const n = violations(results, floors);
    if (n == 0) {
        try out.writeAll("\naccuracy-bench: every language at or above its recorded floor\n");
        return;
    }
    try out.print("\naccuracy-bench: {d} floor violation(s)\n", .{n});
    for (results) |r| {
        const f = floorFor(floors, r.language) orelse {
            try out.print("  {s}: no floor recorded in {s}\n", .{ r.language, floors_file });
            continue;
        };
        try reportFloorMetric(out, r.language, "def precision", r.defs.precisionBp(), f.def_precision_bp);
        try reportFloorMetric(out, r.language, "def recall", r.defs.recallBp(), f.def_recall_bp);
        try reportFloorMetric(out, r.language, "edge precision", r.edges.precisionBp(), f.edge_precision_bp);
        try reportFloorMetric(out, r.language, "edge recall", r.edges.recallBp(), f.edge_recall_bp);
        try reportFloorMetric(out, r.language, "exact agreement", r.exactAgreementBp(), f.exact_agreement_bp);
    }
}

fn reportFloorMetric(out: *std.Io.Writer, lang: []const u8, metric: []const u8, got: u32, floor: u32) !void {
    if (got >= floor) return;
    const g = fmtBp(got);
    const f = fmtBp(floor);
    try out.print(
        "  {s}: {s} {d}.{d:0>2}% below floor {d}.{d:0>2}%\n",
        .{ lang, metric, g.whole, g.frac, f.whole, f.frac },
    );
}

fn reportJson(out: *std.Io.Writer, results: []const LanguageResult, floors: ?Floors) !void {
    try out.writeAll("{\"languages\":[");
    for (results, 0..) |r, i| {
        if (i != 0) try out.writeByte(',');
        try out.writeAll("{\"language\":");
        try jsonString(out, r.language);
        try out.writeAll(",\"root\":");
        try jsonString(out, r.root);
        try out.print(
            ",\"definitions\":{{\"matched\":{d},\"produced\":{d},\"expected\":{d},\"precision_bp\":{d},\"recall_bp\":{d}}}",
            .{ r.defs.matched, r.defs.actual, r.defs.expected, r.defs.precisionBp(), r.defs.recallBp() },
        );
        try out.print(
            ",\"edges\":{{\"matched\":{d},\"produced\":{d},\"expected\":{d},\"precision_bp\":{d},\"recall_bp\":{d},\"exact_agreement_bp\":{d}}}",
            .{ r.edges.matched, r.edges.actual, r.edges.expected, r.edges.precisionBp(), r.edges.recallBp(), r.exactAgreementBp() },
        );
        try out.writeAll(",\"findings\":[");
        for (r.findings, 0..) |f, k| {
            if (k != 0) try out.writeByte(',');
            try out.writeAll("{\"kind\":");
            try jsonString(out, @tagName(f.kind));
            try out.writeAll(",\"site\":");
            try jsonString(out, f.site);
            try out.writeAll(",\"detail\":");
            try jsonString(out, f.detail);
            try out.writeByte('}');
        }
        try out.writeAll("]}");
    }
    try out.writeAll("]");
    if (floors) |fl| try out.print(",\"violations\":{d}", .{violations(results, fl)});
    try out.writeAll("}\n");
}

// ---------------------------------------------------------------------------
// Golden proposal (authoring aid)
// ---------------------------------------------------------------------------

fn propose(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    repo_root: []const u8,
    fixture_root: []const u8,
) !void {
    const root = try std.fs.path.join(arena, &.{ repo_root, fixture_root });
    var idx = try index_mod.build(gpa, io, root, false);
    defer idx.deinit();
    const got = try extract(gpa, arena, &idx);

    try out.writeAll("{\n  \"language\": \"TODO\",\n  \"root\": ");
    try jsonString(out, fixture_root);
    try out.writeAll(",\n  \"definitions\": [\n");
    for (got.defs, 0..) |d, i| {
        if (i != 0) try out.writeAll(",\n");
        try out.writeAll("    { \"file\": ");
        try jsonString(out, d.file);
        try out.writeAll(", \"name\": ");
        try jsonString(out, d.name);
        try out.writeAll(", \"qualified\": ");
        try jsonString(out, d.qualified);
        try out.writeAll(", \"kind\": ");
        try jsonString(out, d.kind);
        try out.print(", \"line\": {d}, \"parent\": ", .{d.line});
        if (d.parent) |p| try jsonString(out, p) else try out.writeAll("null");
        try out.writeAll(" }");
    }
    try out.writeAll("\n  ],\n  \"edges\": [\n");
    for (got.edges, 0..) |e, i| {
        if (i != 0) try out.writeAll(",\n");
        try out.writeAll("    { \"from\": ");
        try jsonString(out, e.from);
        try out.writeAll(", \"to\": ");
        try jsonString(out, e.to);
        try out.print(", \"exact\": {}, \"lines\": [", .{e.exact});
        for (e.lines, 0..) |l, k| {
            if (k != 0) try out.writeByte(',');
            try out.print("{d}", .{l});
        }
        try out.writeAll("], \"verified\": \"manual\" }");
    }
    try out.writeAll("\n  ]\n}\n");
}

fn jsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

test "ratioBp truncates and treats an empty expectation as perfect" {
    try std.testing.expectEqual(@as(u32, 10000), ratioBp(0, 0));
    try std.testing.expectEqual(@as(u32, 0), ratioBp(0, 7));
    try std.testing.expectEqual(@as(u32, 6666), ratioBp(2, 3));
}
