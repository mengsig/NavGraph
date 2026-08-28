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
//!   accuracy-bench <repo-root>                          score every golden vs floors
//!   accuracy-bench <repo-root> -j | --json              same, as one JSON object on stdout
//!   accuracy-bench <repo-root> --update-floors          rewrite floors from the run (ratchet-only)
//!   accuracy-bench <repo-root> --update-floors \
//!     --lower-floors --reason "<why>"                   accept a measured drop, with a reason
//!   accuracy-bench <repo-root> --propose <root>         emit a golden skeleton
//!   accuracy-bench <repo-root> --render-doc-table       docs/accuracy.md's measured table
//!   accuracy-bench <repo-root> --check-doc-table        fail when that table is stale
//!
//! `--propose` reports what the indexer currently sees. That is an authoring
//! aid, never ground truth: every entry is hand-checked against the source (and
//! a reference language server where one exists) before it enters a golden file.

const std = @import("std");
const navgraph = @import("NavGraph");
const model = navgraph.model;
const index_mod = navgraph.index;

const BenchError = error{ UsageError, GoldenInvalid, BelowFloor, DocTableStale };

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
/// distinct 1-based line the reference occurs on, ascending. `from_line` and
/// `to_line` are the endpoints' own declaration lines - not scored directly,
/// but what disambiguates two produced edges that share a `file:qualified`
/// pair (an overload set, or a field and its generated accessor).
const Edge = struct {
    from: []const u8,
    to: []const u8,
    exact: bool,
    lines: []const u32,
    from_line: u32,
    to_line: u32,
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
    /// Required whenever `from`'s (or `to`'s) `file:qualified` key is shared
    /// by more than one definition in this golden - an overload set, or a
    /// field and the accessor it generates - so the edge names exactly one
    /// of them instead of scoring as a match against any.
    from_line: ?u32 = null,
    to_line: ?u32 = null,
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
    /// Defaulted so a floors.json recorded before call-site scoring existed
    /// still parses; the next --update-floors fills in a real measurement.
    site_recall_bp: u32 = 0,
    /// Same defaulting reason: recorded starting the round site precision was
    /// added as a floored metric (F13) rather than left measured-and-discarded.
    site_precision_bp: u32 = 0,
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
    /// Call-site recall over every golden edge, matched or not: `expected`
    /// is every golden edge's `lines` total (a missed edge contributes its
    /// full count as unmatched sites), `matched` how many of them a produced
    /// edge also names, `actual` the produced total for matched edges only.
    /// Floored two ways: recall (`matched`/`expected`, sixth metric,
    /// `site_recall_bp`) and precision (`matched`/`actual`, seventh,
    /// `site_precision_bp` - a produced call site with no golden match is a
    /// phantom the same way an unmatched def or edge is).
    sites: Score = .{},
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
    edge_site_missing,
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
            .edge_site_missing => "MISS  site  ",
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
            "usage: accuracy-bench <repo-root> [--update-floors [--lower-floors --reason \"<why>\"]] " ++
                "[--propose <fixture-root>] [--render-doc-table | --check-doc-table] [-j]\n",
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

    // The floors and the doc table grade the shipped configuration, where
    // python/typescript/tsx are tree-sitter-owned. A `-Dtree-sitter=none` build
    // indexes them with the heuristic scanner — a different indexer, not a
    // regression — so it is reported and left ungraded rather than failed.
    const graded = opts.update_floors or opts.check_doc_table or !opts.render_doc_table;
    if (graded and !navgraph.ts_backend.any_grammar) {
        try out.print(
            "accuracy-bench: not graded — this build links no grammar (-Dtree-sitter=none) " ++
                "and tests/golden/floors.json records the default -Dtree-sitter=all build.\n",
            .{},
        );
        try out.flush();
        return;
    }

    const results = try scoreAll(gpa, arena, io, repo, opts.repo_root);

    if (opts.render_doc_table) {
        try renderDocTable(out, results);
        try out.flush();
        return;
    }
    if (opts.check_doc_table) {
        defer out.flush() catch {};
        return checkDocTable(arena, io, repo, out, results);
    }

    if (opts.update_floors) {
        try writeFloors(gpa, arena, io, repo, results, opts.lower_floors, opts.reason);
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
    /// Accept a re-record that measures below a language's recorded floor.
    /// Only meaningful with `update_floors`, and only together with `reason`.
    lower_floors: bool = false,
    reason: ?[]const u8 = null,
    propose: ?[]const u8 = null,
    json: bool = false,
    render_doc_table: bool = false,
    check_doc_table: bool = false,
};

fn parseArgs(args: []const []const u8) !Options {
    if (args.len < 2) return BenchError.UsageError;
    var opts = Options{ .repo_root = args[1] };
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--update-floors")) {
            opts.update_floors = true;
        } else if (std.mem.eql(u8, a, "--lower-floors")) {
            opts.lower_floors = true;
        } else if (std.mem.eql(u8, a, "--reason")) {
            i += 1;
            if (i >= args.len) return BenchError.UsageError;
            opts.reason = args[i];
        } else if (std.mem.eql(u8, a, "-j") or std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, a, "--propose")) {
            i += 1;
            if (i >= args.len) return BenchError.UsageError;
            opts.propose = args[i];
        } else if (std.mem.eql(u8, a, "--render-doc-table")) {
            opts.render_doc_table = true;
        } else if (std.mem.eql(u8, a, "--check-doc-table")) {
            opts.check_doc_table = true;
        } else return BenchError.UsageError;
    }
    // --lower-floors always needs its reason printed, and only makes sense
    // alongside the re-record it would otherwise silently affect. An empty
    // reason would print nothing useful, so it doesn't count as one.
    if (opts.lower_floors and (opts.reason == null or opts.reason.?.len == 0 or !opts.update_floors)) return BenchError.UsageError;
    if (opts.reason != null and !opts.lower_floors) return BenchError.UsageError;
    if (opts.render_doc_table and opts.check_doc_table) return BenchError.UsageError;
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

    // Edges are deduped per (from symbol, to symbol) - not per (from, to)
    // string pair: two overloads (or a field and its generated accessor)
    // share a `file:qualified` key but are different definitions, so a call
    // into each stays a distinct edge even though their .from/.to strings
    // match. A caller hitting the SAME target symbol on several lines is
    // still one dependency with several sites. The merged edge is exact only
    // when every contributing reference resolved exactly, matching what
    // `--strict` traversal would be willing to follow.
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
            const key = try std.fmt.allocPrint(arena, "{d}\x00{d}", .{ sym.id, ref.target });
            const slot = try edge_at.getOrPut(key);
            if (!slot.found_existing) {
                slot.value_ptr.* = edges.items.len;
                try edges.append(gpa, .{
                    .from = from,
                    .to = to,
                    .exact = ref.exact,
                    .lines = &.{},
                    .from_line = sym.line,
                    .to_line = target.line,
                });
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
    const by_to = std.mem.order(u8, a.to, b.to);
    if (by_to != .eq) return by_to == .lt;
    // Same (from, to) string pair: an overload set or a field/accessor
    // pair. Break the tie by the endpoints' own declaration lines so the
    // ordering (report, JSON, --propose output) is deterministic.
    if (a.from_line != b.from_line) return a.from_line < b.from_line;
    return a.to_line < b.to_line;
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
/// because the endpoints are right and only the confidence bit is wrong. Every
/// golden edge, matched or not, contributes its `lines` to call-site recall:
/// `lines` is hand-verified ground truth, so a matched edge missing one of
/// its golden lines is a real, distinct miss (reported but - like exactness -
/// not disqualifying the edge match), and a missed edge is a miss on every
/// one of its sites (otherwise the metric would only ever measure edges edge
/// recall already found).
fn scoreEdges(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    golden: []const GoldenEdge,
    actual: []const Edge,
    findings: *std.ArrayList(Finding),
    exact_agree: *usize,
    sites: *Score,
) !Score {
    // Grouped by the (from, to) string pair: usually one produced edge, but
    // more than one when the pair names an overload set or a field/accessor
    // pair - each a distinct definition sharing that `file:qualified` key.
    var produced = std.StringHashMap(std.ArrayList(usize)).init(gpa);
    defer {
        var it = produced.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        produced.deinit();
    }
    for (actual, 0..) |a, i| {
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ a.from, a.to });
        const slot = try produced.getOrPut(key);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(gpa, i);
    }
    // Tracked per produced edge (not per string pair) so a phantom overload
    // sibling of a correctly-matched edge is still reported as a phantom.
    const matched_actual = try gpa.alloc(bool, actual.len);
    defer gpa.free(matched_actual);
    @memset(matched_actual, false);

    var score = Score{ .actual = actual.len, .expected = golden.len };
    for (golden) |g| {
        // Every golden call site counts toward the denominator whether or not
        // the edge itself matched - otherwise site recall only ever measures
        // edges edge recall already found, and reads 100% while whole
        // multi-site edges are still missing.
        sites.expected += g.lines.len;
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ g.from, g.to });
        const candidates: []const usize = if (produced.get(key)) |l| l.items else &.{};
        const hit = pickCandidate(actual, candidates, g) orelse {
            try findings.append(gpa, .{
                .kind = .edge_missing,
                .site = try edgeSite(arena, g.from, g.lines),
                .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ g.from, g.to }),
            });
            continue;
        };
        matched_actual[hit] = true;
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

        sites.actual += a.lines.len;
        var site_hit: usize = 0;
        for (g.lines) |gl| {
            for (a.lines) |al| {
                if (gl == al) {
                    site_hit += 1;
                    break;
                }
            }
        }
        sites.matched += site_hit;
        if (site_hit != g.lines.len) {
            try findings.append(gpa, .{
                .kind = .edge_site_missing,
                .site = try edgeSite(arena, g.from, g.lines),
                .detail = try std.fmt.allocPrint(
                    arena,
                    "{s} -> {s}: {d}/{d} golden call sites matched",
                    .{ g.from, g.to, site_hit, g.lines.len },
                ),
            });
        }
    }
    for (actual, 0..) |a, i| {
        if (matched_actual[i]) continue;
        try findings.append(gpa, .{
            .kind = .edge_phantom,
            .site = try edgeSite(arena, a.from, a.lines),
            .detail = try std.fmt.allocPrint(arena, "{s} -> {s}", .{ a.from, a.to }),
        });
    }
    return score;
}

/// Which produced edge a golden edge names, among candidates sharing its
/// (from, to) string pair. A single candidate is unambiguous; more than one
/// (an overload set or a field/accessor pair) requires `from_line`/`to_line`
/// to pick the right definition - absent both, the first candidate is taken,
/// which only happens when the golden's own definitions did not in fact
/// share the name (validateGolden requires the line whenever they do).
fn pickCandidate(actual: []const Edge, candidates: []const usize, g: GoldenEdge) ?usize {
    if (candidates.len == 0) return null;
    for (candidates) |i| {
        const a = actual[i];
        if (g.from_line) |fl| if (a.from_line != fl) continue;
        if (g.to_line) |tl| if (a.to_line != tl) continue;
        return i;
    }
    return null;
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
        try validateGolden(gpa, arena, path, parsed);
        try results.append(gpa, try scoreOne(gpa, arena, io, repo_root, parsed));
    }
    return arena.dupe(LanguageResult, results.items);
}

/// Structural invariants a hand-authored golden must satisfy. Catching these
/// here keeps a typo from silently deflating a language's measured recall.
fn validateGolden(gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, g: Golden) !void {
    var declared = std.StringHashMap(void).init(gpa);
    defer declared.deinit();
    // How many definitions share a `file:qualified` key - an overload set,
    // or a field and the accessor it generates - and at which lines, so an
    // edge naming one of them can be required to say (and checked to say
    // correctly) which.
    var name_count = std.StringHashMap(usize).init(gpa);
    defer name_count.deinit();
    var def_at_line = std.StringHashMap(void).init(gpa);
    defer def_at_line.deinit();
    for (g.definitions) |d| {
        const name_key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ d.file, d.qualified });
        try declared.put(name_key, {});
        const slot = try name_count.getOrPut(name_key);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += 1;
        try def_at_line.put(try std.fmt.allocPrint(arena, "{s}#{d}", .{ name_key, d.line }), {});
    }
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
        // Both ends of an edge must be definitions the same golden declares:
        // a reference to something that is not a definition has no edge.
        if (!declared.contains(e.from) or !declared.contains(e.to)) {
            std.debug.print(
                "accuracy-bench: {s}: edge endpoint is not a definition in this golden ({s} -> {s})\n",
                .{ path, e.from, e.to },
            );
            return BenchError.GoldenInvalid;
        }
        try requireLineWhenAmbiguous(path, name_count, e, e.from, e.from_line, "from");
        try requireLineWhenAmbiguous(path, name_count, e, e.to, e.to_line, "to");
        if (e.from_line) |l| try requireLineIsADefinition(arena, path, def_at_line, e.from, l);
        if (e.to_line) |l| try requireLineIsADefinition(arena, path, def_at_line, e.to, l);
        try requireLinesAscendingUnique(path, e);
    }
    try requireEdgesDistinguishable(gpa, arena, path, g.edges);
}

/// `lines` is ground truth for call-site scoring; a stray duplicate or an
/// out-of-order pair inflates the site counts (`extract` always emits it
/// sorted and deduped, so a golden that doesn't match can't be honest).
fn requireLinesAscendingUnique(path: []const u8, e: GoldenEdge) !void {
    var i: usize = 1;
    while (i < e.lines.len) : (i += 1) {
        if (e.lines[i] <= e.lines[i - 1]) {
            std.debug.print(
                "accuracy-bench: {s}: edge {s} -> {s}: lines must be strictly ascending and deduplicated (got {d}, {d})\n",
                .{ path, e.from, e.to, e.lines[i - 1], e.lines[i] },
            );
            return BenchError.GoldenInvalid;
        }
    }
}

/// Two golden edges sharing a (from, to) string pair are either the same
/// overload/accessor pair's siblings - each naming which definition via
/// from_line/to_line - or an accidental duplicate. A silent duplicate is
/// dangerous precisely because it looks like a legitimate sibling: it
/// inflates edge precision, recall, exact agreement AND site recall at once,
/// and `--update-floors` would ratchet the inflated numbers in permanently.
fn requireEdgesDistinguishable(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    path: []const u8,
    edges: []const GoldenEdge,
) !void {
    var groups = std.StringHashMap(std.ArrayList(usize)).init(gpa);
    defer {
        var it = groups.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        groups.deinit();
    }
    for (edges, 0..) |e, i| {
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ e.from, e.to });
        const slot = try groups.getOrPut(key);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(gpa, i);
    }
    var it = groups.valueIterator();
    while (it.next()) |group| {
        if (group.items.len < 2) continue;
        for (group.items) |gi| {
            const e = edges[gi];
            if (e.from_line == null and e.to_line == null) {
                std.debug.print(
                    "accuracy-bench: {s}: edge {s} -> {s} repeats ({d} entries share this pair); " ++
                        "set from_line or to_line on each to say which definition it names\n",
                    .{ path, e.from, e.to, group.items.len },
                );
                return BenchError.GoldenInvalid;
            }
        }
        for (group.items, 0..) |gi, pos| {
            for (group.items[pos + 1 ..]) |gj| {
                const a = edges[gi];
                const b = edges[gj];
                if (a.exact == b.exact and a.from_line == b.from_line and a.to_line == b.to_line and
                    std.mem.eql(u32, a.lines, b.lines))
                {
                    std.debug.print(
                        "accuracy-bench: {s}: edge {s} -> {s}: duplicate entry (same from/to/lines/exact)\n",
                        .{ path, a.from, a.to },
                    );
                    return BenchError.GoldenInvalid;
                }
            }
        }
    }
}

/// `endpoint`'s `file:qualified` key names more than one definition (an
/// overload set, or a field and its generated accessor) only when `line` is
/// set to say which.
fn requireLineWhenAmbiguous(
    path: []const u8,
    name_count: std.StringHashMap(usize),
    e: GoldenEdge,
    endpoint: []const u8,
    line: ?u32,
    which: []const u8,
) !void {
    const n = name_count.get(endpoint) orelse 0;
    if (n <= 1 or line != null) return;
    std.debug.print(
        "accuracy-bench: {s}: edge {s} -> {s}: {s} endpoint is ambiguous ({d} definitions share `{s}`); set {s}_line\n",
        .{ path, e.from, e.to, which, n, endpoint, which },
    );
    return BenchError.GoldenInvalid;
}

fn requireLineIsADefinition(
    arena: std.mem.Allocator,
    path: []const u8,
    def_at_line: std.StringHashMap(void),
    endpoint: []const u8,
    line: u32,
) !void {
    const key = try std.fmt.allocPrint(arena, "{s}#{d}", .{ endpoint, line });
    if (def_at_line.contains(key)) return;
    std.debug.print(
        "accuracy-bench: {s}: edge endpoint {s} has no definition at line {d}\n",
        .{ path, endpoint, line },
    );
    return BenchError.GoldenInvalid;
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
    var idx = try index_mod.build(gpa, io, root, false, .auto);
    defer idx.deinit();
    const got = try extract(gpa, arena, &idx);

    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(gpa);
    const defs = try scoreDefs(gpa, arena, g.definitions, got.defs, &findings);
    var exact_agree: usize = 0;
    var sites: Score = .{};
    const edges = try scoreEdges(gpa, arena, g.edges, got.edges, &findings, &exact_agree, &sites);

    return .{
        .language = g.language,
        .root = g.root,
        .defs = defs,
        .edges = edges,
        .exact_agree = exact_agree,
        .sites = sites,
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

/// One metric's ratchet outcome: the measurement fell below the prior floor.
/// Recorded whether or not the drop was accepted, so it is always visible.
const FloorDrop = struct {
    language: []const u8,
    metric: []const u8,
    existing_bp: u32,
    measured_bp: u32,
};

/// Never returns below `existing_bp` unless `allow_lower`; either way, a drop
/// is appended to `drops` so it cannot pass through silently.
fn ratchetMetric(
    gpa: std.mem.Allocator,
    drops: *std.ArrayList(FloorDrop),
    language: []const u8,
    metric: []const u8,
    existing_bp: u32,
    measured_bp: u32,
    allow_lower: bool,
) !u32 {
    if (measured_bp >= existing_bp) return measured_bp;
    try drops.append(gpa, .{ .language = language, .metric = metric, .existing_bp = existing_bp, .measured_bp = measured_bp });
    return if (allow_lower) measured_bp else existing_bp;
}

/// Re-record floors from `results`. Ratchet-only by default: each metric
/// takes the max of its prior recorded floor and this measurement, and a
/// metric that would have dropped is kept at its prior value and reported
/// rather than silently overwritten. `allow_lower` (paired with `reason`)
/// accepts a drop instead, and reports it with the reason.
fn writeFloors(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    repo: std.Io.Dir,
    results: []const LanguageResult,
    allow_lower: bool,
    reason: ?[]const u8,
) !void {
    // A first `--update-floors` run (or a floors.json wiped by hand) has
    // nothing to ratchet against; treat every metric as a fresh floor.
    const prior = loadFloors(arena, io, repo) catch Floors{ .floors = &.{} };
    warnDroppedLanguages(prior, results);

    var drops: std.ArrayList(FloorDrop) = .empty;
    defer drops.deinit(gpa);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    var w: std.Io.Writer.Allocating = .fromArrayList(arena, &buf);
    defer buf = w.toArrayList();
    const o = &w.writer;
    try o.writeAll("{\n  \"floors\": [\n");
    for (results, 0..) |r, i| {
        if (i != 0) try o.writeAll(",\n");
        const measured = Floor{
            .language = r.language,
            .def_precision_bp = r.defs.precisionBp(),
            .def_recall_bp = r.defs.recallBp(),
            .edge_precision_bp = r.edges.precisionBp(),
            .edge_recall_bp = r.edges.recallBp(),
            .exact_agreement_bp = r.exactAgreementBp(),
            .site_recall_bp = r.sites.recallBp(),
            .site_precision_bp = r.sites.precisionBp(),
        };
        const merged = if (floorFor(prior, r.language)) |existing| Floor{
            .language = r.language,
            .def_precision_bp = try ratchetMetric(gpa, &drops, r.language, "def precision", existing.def_precision_bp, measured.def_precision_bp, allow_lower),
            .def_recall_bp = try ratchetMetric(gpa, &drops, r.language, "def recall", existing.def_recall_bp, measured.def_recall_bp, allow_lower),
            .edge_precision_bp = try ratchetMetric(gpa, &drops, r.language, "edge precision", existing.edge_precision_bp, measured.edge_precision_bp, allow_lower),
            .edge_recall_bp = try ratchetMetric(gpa, &drops, r.language, "edge recall", existing.edge_recall_bp, measured.edge_recall_bp, allow_lower),
            .exact_agreement_bp = try ratchetMetric(gpa, &drops, r.language, "exact agreement", existing.exact_agreement_bp, measured.exact_agreement_bp, allow_lower),
            .site_recall_bp = try ratchetMetric(gpa, &drops, r.language, "site recall", existing.site_recall_bp, measured.site_recall_bp, allow_lower),
            .site_precision_bp = try ratchetMetric(gpa, &drops, r.language, "site precision", existing.site_precision_bp, measured.site_precision_bp, allow_lower),
        } else measured;
        try o.print(
            "    {{ \"language\": \"{s}\", \"def_precision_bp\": {d}, \"def_recall_bp\": {d}, " ++
                "\"edge_precision_bp\": {d}, \"edge_recall_bp\": {d}, \"exact_agreement_bp\": {d}, " ++
                "\"site_recall_bp\": {d}, \"site_precision_bp\": {d} }}",
            .{
                merged.language,
                merged.def_precision_bp,
                merged.def_recall_bp,
                merged.edge_precision_bp,
                merged.edge_recall_bp,
                merged.exact_agreement_bp,
                merged.site_recall_bp,
                merged.site_precision_bp,
            },
        );
    }
    try o.writeAll("\n  ]\n}\n");
    try repo.writeFile(io, .{ .sub_path = golden_dir_path ++ "/" ++ floors_file, .data = w.written() });

    if (drops.items.len == 0) return;
    if (allow_lower) {
        std.debug.print("accuracy-bench: lowered {d} floor(s) (--reason: {s})\n", .{ drops.items.len, reason.? });
    } else {
        std.debug.print(
            "accuracy-bench: kept {d} floor(s) at their recorded value; the measurement regressed " ++
                "and --lower-floors was not passed\n",
            .{drops.items.len},
        );
    }
    for (drops.items) |d| {
        const e = fmtBp(d.existing_bp);
        const m = fmtBp(d.measured_bp);
        std.debug.print(
            "  {s} {s}: {d}.{d:0>2}% -> {d}.{d:0>2}%\n",
            .{ d.language, d.metric, e.whole, e.frac, m.whole, m.frac },
        );
    }
}

/// `writeFloors` only ever writes an entry for a language in `results`
/// (today's golden files), so renaming or deleting a golden silently drops
/// its recorded floor on the next re-record - unlike every other kind of
/// drop, `ratchetMetric` never sees it. Surfaced here instead.
fn warnDroppedLanguages(prior: Floors, results: []const LanguageResult) void {
    for (prior.floors) |f| {
        for (results) |r| {
            if (std.mem.eql(u8, r.language, f.language)) break;
        } else {
            std.debug.print(
                "accuracy-bench: {s} had a recorded floor but no golden file today; its floor was dropped\n",
                .{f.language},
            );
        }
    }
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
        if (r.sites.recallBp() < f.site_recall_bp) n += 1;
        if (r.sites.precisionBp() < f.site_precision_bp) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

fn report(out: *std.Io.Writer, results: []const LanguageResult, floors: ?Floors, json: bool) !void {
    if (json) return reportJson(out, results, floors);

    try out.writeAll("language      defs  P /  R   (match/got/want)   edges  P /  R   (match/got/want)  exact  site P /  R  (match/got/want)\n");
    var total = LanguageResult{
        .language = "TOTAL",
        .root = "",
        .defs = .{},
        .edges = .{},
        .exact_agree = 0,
        .sites = .{},
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
        total.sites.matched += r.sites.matched;
        total.sites.actual += r.sites.actual;
        total.sites.expected += r.sites.expected;
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
    const sp = fmtBp(r.sites.precisionBp());
    const sr = fmtBp(r.sites.recallBp());
    try out.print(
        "{s: <12}  {d: >3}.{d:0>2}/{d: >3}.{d:0>2}  ({d: >4}/{d: >4}/{d: >4})   {d: >3}.{d:0>2}/{d: >3}.{d:0>2}  ({d: >4}/{d: >4}/{d: >4})  {d: >3}.{d:0>2}  {d: >3}.{d:0>2}/{d: >3}.{d:0>2}  ({d: >4}/{d: >4}/{d: >4})\n",
        .{
            r.language,
            dp.whole,
            dp.frac,
            dr.whole,
            dr.frac,
            r.defs.matched,
            r.defs.actual,
            r.defs.expected,
            ep.whole,
            ep.frac,
            er.whole,
            er.frac,
            r.edges.matched,
            r.edges.actual,
            r.edges.expected,
            ex.whole,
            ex.frac,
            sp.whole,
            sp.frac,
            sr.whole,
            sr.frac,
            r.sites.matched,
            r.sites.actual,
            r.sites.expected,
        },
    );
}

// ---------------------------------------------------------------------------
// docs/accuracy.md's measured table
// ---------------------------------------------------------------------------

const doc_path = "docs/accuracy.md";
const doc_table_open = "<!-- accuracy-table:after-wave-1 -->";
const doc_table_close = "<!-- /accuracy-table:after-wave-1 -->";

/// The "After the wave" table in `docs/accuracy.md`, rendered from THIS run.
/// The doc used to be retyped by hand and went stale by two commits; it is now
/// generated, and `--check-doc-table` fails the suite when the file drifts.
fn renderDocTable(out: *std.Io.Writer, results: []const LanguageResult) !void {
    try out.writeAll("| language | def P | def R | defs | edge P | edge R | edges | exact agree | site P | site R | sites |\n");
    try out.writeAll("|---|---|---|---|---|---|---|---|---|---|---|\n");
    var total = LanguageResult{
        .language = "all",
        .root = "",
        .defs = .{},
        .edges = .{},
        .exact_agree = 0,
        .sites = .{},
        .findings = &.{},
    };
    for (results) |r| {
        try renderDocRow(out, r, false);
        total.defs.matched += r.defs.matched;
        total.defs.actual += r.defs.actual;
        total.defs.expected += r.defs.expected;
        total.edges.matched += r.edges.matched;
        total.edges.actual += r.edges.actual;
        total.edges.expected += r.edges.expected;
        total.exact_agree += r.exact_agree;
        total.sites.matched += r.sites.matched;
        total.sites.actual += r.sites.actual;
        total.sites.expected += r.sites.expected;
    }
    try renderDocRow(out, total, true);
}

/// One markdown row. The aggregate row bolds its seven percentages, matching
/// the surrounding tables in the document.
fn renderDocRow(out: *std.Io.Writer, r: LanguageResult, aggregate: bool) !void {
    try out.print("| {s} |", .{if (aggregate) "**all**" else r.language});
    try renderDocPct(out, r.defs.precisionBp(), aggregate);
    try renderDocPct(out, r.defs.recallBp(), aggregate);
    try renderDocCounts(out, r.defs);
    try renderDocPct(out, r.edges.precisionBp(), aggregate);
    try renderDocPct(out, r.edges.recallBp(), aggregate);
    try renderDocCounts(out, r.edges);
    try renderDocPct(out, r.exactAgreementBp(), aggregate);
    try renderDocPct(out, r.sites.precisionBp(), aggregate);
    try renderDocPct(out, r.sites.recallBp(), aggregate);
    try renderDocCounts(out, r.sites);
    try out.writeAll("\n");
}

fn renderDocPct(out: *std.Io.Writer, bp: u32, bold: bool) !void {
    const v = fmtBp(bp);
    const b = if (bold) "**" else "";
    try out.print(" {s}{d}.{d:0>2}{s} |", .{ b, v.whole, v.frac, b });
}

fn renderDocCounts(out: *std.Io.Writer, s: Score) !void {
    try out.print(" {d}/{d}/{d} |", .{ s.matched, s.actual, s.expected });
}

/// Body between the generated-table markers, or null when a marker is absent.
fn docTableBody(text: []const u8) ?[]const u8 {
    const open = std.mem.indexOf(u8, text, doc_table_open) orelse return null;
    const body_start = open + doc_table_open.len;
    const close = std.mem.indexOfPos(u8, text, body_start, doc_table_close) orelse return null;
    return std.mem.trim(u8, text[body_start..close], "\n");
}

/// Fail when `docs/accuracy.md`'s generated table no longer matches the run.
fn checkDocTable(arena: std.mem.Allocator, io: std.Io, repo: std.Io.Dir, out: *std.Io.Writer, results: []const LanguageResult) !void {
    const text = repo.readFileAlloc(io, doc_path, arena, .unlimited) catch |err| {
        std.debug.print("accuracy-bench: cannot read {s} ({s})\n", .{ doc_path, @errorName(err) });
        return BenchError.DocTableStale;
    };
    const found = docTableBody(text) orelse {
        std.debug.print(
            "accuracy-bench: {s} has no `{s}` ... `{s}` block to check\n",
            .{ doc_path, doc_table_open, doc_table_close },
        );
        return BenchError.DocTableStale;
    };

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(arena);
    var buf: std.Io.Writer.Allocating = .fromArrayList(arena, &rendered);
    try renderDocTable(&buf.writer, results);
    rendered = buf.toArrayList();
    const want = std.mem.trim(u8, rendered.items, "\n");

    if (std.mem.eql(u8, found, want)) {
        try out.print("accuracy-bench: {s}'s measured table matches this run\n", .{doc_path});
        return;
    }
    std.debug.print(
        "accuracy-bench: {s}'s measured table is stale. Regenerate it:\n" ++
            "  zig build bench -- --render-doc-table\n\nrecorded:\n{s}\n\nmeasured:\n{s}\n",
        .{ doc_path, found, want },
    );
    return BenchError.DocTableStale;
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
        try reportFloorMetric(out, r.language, "site recall", r.sites.recallBp(), f.site_recall_bp);
        try reportFloorMetric(out, r.language, "site precision", r.sites.precisionBp(), f.site_precision_bp);
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
        try out.print(
            ",\"sites\":{{\"matched\":{d},\"produced\":{d},\"expected\":{d},\"recall_bp\":{d},\"precision_bp\":{d}}}",
            .{ r.sites.matched, r.sites.actual, r.sites.expected, r.sites.recallBp(), r.sites.precisionBp() },
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
    var idx = try index_mod.build(gpa, io, root, false, .auto);
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
        // Always emitted, not just when the endpoint is ambiguous today: a
        // proposal that omits them is rejected outright the moment the
        // author's edit makes the endpoint share a key with another
        // definition, and there's no way to tell from `extract`'s output
        // alone which endpoints are safe to drop it from.
        try out.print("], \"from_line\": {d}, \"to_line\": {d}, \"verified\": \"manual\" }}", .{ e.from_line, e.to_line });
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

test "ratchetMetric: a raised floor survives, a regression is kept unless allowed" {
    const gpa = std.testing.allocator;
    var drops: std.ArrayList(FloorDrop) = .empty;
    defer drops.deinit(gpa);

    // A wave that measures higher: the raised value is recorded, no drop.
    try std.testing.expectEqual(@as(u32, 9500), try ratchetMetric(gpa, &drops, "go", "def recall", 9000, 9500, false));
    try std.testing.expectEqual(@as(usize, 0), drops.items.len);

    // Re-recording with that raised floor as the new prior: it survives a
    // run that measures the same value again (the exact bug in the report -
    // `--update-floors` used to overwrite unconditionally and erase this).
    try std.testing.expectEqual(@as(u32, 9500), try ratchetMetric(gpa, &drops, "go", "def recall", 9500, 9500, false));
    try std.testing.expectEqual(@as(usize, 0), drops.items.len);

    // A regression without --lower-floors: the prior (higher) floor is kept,
    // and the drop is recorded so it is never silent.
    try std.testing.expectEqual(@as(u32, 9500), try ratchetMetric(gpa, &drops, "go", "def recall", 9500, 9000, false));
    try std.testing.expectEqual(@as(usize, 1), drops.items.len);
    try std.testing.expectEqual(@as(u32, 9500), drops.items[0].existing_bp);
    try std.testing.expectEqual(@as(u32, 9000), drops.items[0].measured_bp);

    // The same regression with allow_lower: the measured (lower) value wins,
    // and it is still recorded as a drop (the reason gets printed for it).
    try std.testing.expectEqual(@as(u32, 9000), try ratchetMetric(gpa, &drops, "go", "def recall", 9500, 9000, true));
    try std.testing.expectEqual(@as(usize, 2), drops.items.len);
}

test "violations: a regression in any one of the seven metrics fails the gate" {
    const floor = Floor{
        .language = "go",
        .def_precision_bp = 9000,
        .def_recall_bp = 9000,
        .edge_precision_bp = 9000,
        .edge_recall_bp = 9000,
        .exact_agreement_bp = 9000,
        .site_recall_bp = 9000,
        .site_precision_bp = 9000,
    };
    const floors = Floors{ .floors = &.{floor} };

    const at_floor = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 90, .actual = 100, .expected = 100 },
        .edges = .{ .matched = 90, .actual = 100, .expected = 100 },
        .exact_agree = 81, // 81/90 = 9000bp
        .sites = .{ .matched = 90, .actual = 100, .expected = 100 },
        .findings = &.{},
    };
    try std.testing.expectEqual(@as(usize, 0), violations(&.{at_floor}, floors));

    const def_precision_regressed = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 89, .actual = 100, .expected = 89 }, // P 8900, R 10000
        .edges = .{ .matched = 100, .actual = 100, .expected = 100 },
        .exact_agree = 100,
        .sites = .{ .matched = 90, .actual = 100, .expected = 100 },
        .findings = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), violations(&.{def_precision_regressed}, floors));

    const def_recall_regressed = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 89, .actual = 89, .expected = 100 }, // P 10000, R 8900
        .edges = .{ .matched = 100, .actual = 100, .expected = 100 },
        .exact_agree = 100,
        .sites = .{ .matched = 90, .actual = 100, .expected = 100 },
        .findings = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), violations(&.{def_recall_regressed}, floors));

    const edge_precision_regressed = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 100, .actual = 100, .expected = 100 },
        .edges = .{ .matched = 89, .actual = 100, .expected = 89 }, // P 8900, R 10000
        .exact_agree = 89,
        .sites = .{ .matched = 90, .actual = 100, .expected = 100 },
        .findings = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), violations(&.{edge_precision_regressed}, floors));

    const edge_recall_regressed = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 100, .actual = 100, .expected = 100 },
        .edges = .{ .matched = 89, .actual = 89, .expected = 100 }, // P 10000, R 8900
        .exact_agree = 89,
        .sites = .{ .matched = 90, .actual = 100, .expected = 100 },
        .findings = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), violations(&.{edge_recall_regressed}, floors));

    const exact_agreement_regressed = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 100, .actual = 100, .expected = 100 },
        .edges = .{ .matched = 100, .actual = 100, .expected = 100 },
        .exact_agree = 89, // 89/100 = 8900bp
        .sites = .{ .matched = 90, .actual = 100, .expected = 100 },
        .findings = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), violations(&.{exact_agreement_regressed}, floors));

    const site_recall_regressed = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 100, .actual = 100, .expected = 100 },
        .edges = .{ .matched = 100, .actual = 100, .expected = 100 },
        .exact_agree = 100,
        .sites = .{ .matched = 89, .actual = 89, .expected = 100 }, // P 10000, R 8900
        .findings = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), violations(&.{site_recall_regressed}, floors));

    const site_precision_regressed = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 100, .actual = 100, .expected = 100 },
        .edges = .{ .matched = 100, .actual = 100, .expected = 100 },
        .exact_agree = 100,
        .sites = .{ .matched = 89, .actual = 100, .expected = 89 }, // P 8900, R 10000
        .findings = &.{},
    };
    try std.testing.expectEqual(@as(usize, 1), violations(&.{site_precision_regressed}, floors));
}

test "pickCandidate: a single candidate is unambiguous; several need from_line/to_line" {
    const actual = [_]Edge{
        .{ .from = "f:A.m", .to = "f:B.m", .exact = true, .lines = &.{1}, .from_line = 10, .to_line = 20 },
        .{ .from = "f:A.m", .to = "f:B.m", .exact = true, .lines = &.{2}, .from_line = 15, .to_line = 20 },
    };
    const both = [_]usize{ 0, 1 };
    const one = [_]usize{0};

    // One candidate is taken even with no disambiguator set on the golden edge.
    try std.testing.expectEqual(@as(?usize, 0), pickCandidate(
        &actual,
        &one,
        .{ .from = "f:A.m", .to = "f:B.m", .exact = true, .lines = &.{1}, .verified = "manual" },
    ));

    // Two candidates: from_line picks the matching one.
    try std.testing.expectEqual(@as(?usize, 0), pickCandidate(
        &actual,
        &both,
        .{ .from = "f:A.m", .to = "f:B.m", .exact = true, .lines = &.{1}, .verified = "manual", .from_line = 10 },
    ));
    try std.testing.expectEqual(@as(?usize, 1), pickCandidate(
        &actual,
        &both,
        .{ .from = "f:A.m", .to = "f:B.m", .exact = true, .lines = &.{2}, .verified = "manual", .from_line = 15 },
    ));

    // No candidates at all.
    try std.testing.expectEqual(@as(?usize, null), pickCandidate(
        &actual,
        &.{},
        .{ .from = "f:A.m", .to = "f:B.m", .exact = true, .lines = &.{1}, .verified = "manual" },
    ));

    // A from_line naming no produced definition matches nothing - never a
    // wrong pick.
    try std.testing.expectEqual(@as(?usize, null), pickCandidate(
        &actual,
        &both,
        .{ .from = "f:A.m", .to = "f:B.m", .exact = true, .lines = &.{1}, .verified = "manual", .from_line = 999 },
    ));
}

test "validateGolden rejects a duplicate edge row and an unsorted lines array" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const defs = [_]GoldenDef{
        .{ .file = "a.go", .name = "A", .qualified = "A", .kind = "fn", .line = 1 },
        .{ .file = "a.go", .name = "B", .qualified = "B", .kind = "fn", .line = 2 },
    };

    // A plain copy-paste duplicate: same from/to/lines/exact, no from_line/to_line
    // to even claim it's an overload sibling.
    {
        const edges = [_]GoldenEdge{
            .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{1}, .verified = "manual" },
            .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{1}, .verified = "manual" },
        };
        const g = Golden{ .language = "go", .root = ".", .definitions = &defs, .edges = &edges };
        try testing.expectError(BenchError.GoldenInvalid, validateGolden(gpa, arena, "test.json", g));
    }

    // Out-of-order lines.
    {
        const edges = [_]GoldenEdge{
            .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{ 2, 1 }, .verified = "manual" },
        };
        const g = Golden{ .language = "go", .root = ".", .definitions = &defs, .edges = &edges };
        try testing.expectError(BenchError.GoldenInvalid, validateGolden(gpa, arena, "test.json", g));
    }

    // Duplicate lines.
    {
        const edges = [_]GoldenEdge{
            .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{ 1, 1 }, .verified = "manual" },
        };
        const g = Golden{ .language = "go", .root = ".", .definitions = &defs, .edges = &edges };
        try testing.expectError(BenchError.GoldenInvalid, validateGolden(gpa, arena, "test.json", g));
    }

    // A single, unambiguous edge with an ascending lines array is valid.
    {
        const edges = [_]GoldenEdge{
            .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{ 1, 2 }, .verified = "manual" },
        };
        const g = Golden{ .language = "go", .root = ".", .definitions = &defs, .edges = &edges };
        try validateGolden(gpa, arena, "test.json", g);
    }
}

test "validateGolden allows repeated (from, to) pairs distinguished by from_line/to_line" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two overloads of B sharing a file:qualified key, called from two sites.
    const defs = [_]GoldenDef{
        .{ .file = "a.go", .name = "A", .qualified = "A", .kind = "fn", .line = 1 },
        .{ .file = "a.go", .name = "B", .qualified = "B", .kind = "fn", .line = 10 },
        .{ .file = "a.go", .name = "B", .qualified = "B", .kind = "fn", .line = 20 },
    };
    const edges = [_]GoldenEdge{
        .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{2}, .verified = "manual", .to_line = 10 },
        .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{3}, .verified = "manual", .to_line = 20 },
    };
    const g = Golden{ .language = "go", .root = ".", .definitions = &defs, .edges = &edges };
    try validateGolden(gpa, arena, "test.json", g);

    // The same pair, but neither entry says which B it names - rejected even
    // though the two rows differ (this is exactly what a careless duplicate
    // of an unambiguous edge looks like once it's no longer identical).
    const undisambiguated = [_]GoldenEdge{
        .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{2}, .verified = "manual", .to_line = 10 },
        .{ .from = "a.go:A", .to = "a.go:B", .exact = true, .lines = &.{3}, .verified = "manual" },
    };
    const g2 = Golden{ .language = "go", .root = ".", .definitions = &defs, .edges = &undisambiguated };
    try testing.expectError(BenchError.GoldenInvalid, validateGolden(gpa, arena, "test.json", g2));
}

test "writeFloors round-trips through the file and the ratchet governs re-recording" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, golden_dir_path);

    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 90, .actual = 100, .expected = 100 },
        .edges = .{ .matched = 90, .actual = 100, .expected = 100 },
        .exact_agree = 81,
        .sites = .{ .matched = 90, .actual = 100, .expected = 100 },
        .findings = &.{},
    };

    // First record: no prior floors.json, so every metric is a fresh floor.
    try writeFloors(gpa, arena, io, tmp.dir, &.{result}, false, null);
    var floors = try loadFloors(arena, io, tmp.dir);
    try testing.expectEqual(@as(usize, 1), floors.floors.len);
    try testing.expectEqualStrings("go", floors.floors[0].language);
    try testing.expectEqual(@as(u32, 9000), floors.floors[0].def_precision_bp);
    try testing.expectEqual(@as(u32, 9000), floors.floors[0].site_recall_bp);
    try testing.expectEqual(@as(u32, 9000), floors.floors[0].site_precision_bp);

    // A regression without --lower-floors is kept at the recorded value.
    const regressed = LanguageResult{
        .language = "go",
        .root = "",
        .defs = .{ .matched = 50, .actual = 100, .expected = 100 },
        .edges = result.edges,
        .exact_agree = result.exact_agree,
        .sites = result.sites,
        .findings = &.{},
    };
    try writeFloors(gpa, arena, io, tmp.dir, &.{regressed}, false, null);
    floors = try loadFloors(arena, io, tmp.dir);
    try testing.expectEqual(@as(u32, 9000), floors.floors[0].def_precision_bp);

    // The same regression with --lower-floors accepts the drop.
    try writeFloors(gpa, arena, io, tmp.dir, &.{regressed}, true, "test drop");
    floors = try loadFloors(arena, io, tmp.dir);
    try testing.expectEqual(@as(u32, 5000), floors.floors[0].def_precision_bp);
}

test "docTableBody finds the generated block, and reports its absence rather than passing" {
    const testing = std.testing;
    const doc =
        "intro\n\n" ++ doc_table_open ++ "\n| a | b |\n|---|---|\n" ++ doc_table_close ++ "\n\ntail\n";
    try testing.expectEqualStrings("| a | b |\n|---|---|", docTableBody(doc).?);

    // A document with no block (or a truncated one) must not read as a match.
    try testing.expect(docTableBody("no markers here") == null);
    try testing.expect(docTableBody("intro\n" ++ doc_table_open ++ "\n| a |\n") == null);
}

test "renderDocTable bolds only the aggregate row and totals every column" {
    const testing = std.testing;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer buf = w.toArrayList();

    try renderDocTable(&w.writer, &.{
        .{
            .language = "lang_a",
            .root = "",
            .defs = .{ .matched = 1, .actual = 2, .expected = 4 },
            .edges = .{ .matched = 1, .actual = 1, .expected = 2 },
            .exact_agree = 1,
            .sites = .{ .matched = 3, .actual = 4, .expected = 6 },
            .findings = &.{},
        },
        .{
            .language = "lang_b",
            .root = "",
            .defs = .{ .matched = 3, .actual = 6, .expected = 4 },
            .edges = .{ .matched = 1, .actual = 3, .expected = 2 },
            .exact_agree = 0,
            .sites = .{ .matched = 1, .actual = 4, .expected = 2 },
            .findings = &.{},
        },
    });

    const out = w.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "| lang_a | 50.00 | 25.00 | 1/2/4 |") != null);
    // Aggregate: defs 4/8/8 -> 50.00 P, 50.00 R; exact 1 of 2 matched edges.
    try testing.expect(std.mem.indexOf(u8, out, "| **all** | **50.00** | **50.00** | 4/8/8 |") != null);
    try testing.expect(std.mem.indexOf(u8, out, "| **50.00** | **50.00** | 4/8/8 | **50.00** | **50.00** | 2/4/4 | **50.00** |") != null);
}
