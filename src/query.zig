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
const lexer = @import("lexer.zig");
const language = @import("language.zig");
const events_mod = @import("events.zig");
const gitdiff = @import("gitdiff.zig");
const gitutil = @import("gitutil.zig");
const cache = @import("cache.zig");
const gitignore = @import("gitignore.zig");
const impls_mod = @import("impls.zig");
const workspace_path = @import("workspace_path.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

/// Output encoding: compact text for agents, or JSON for tooling/MCP.
pub const OutputFormat = enum { text, json, jsonl };

/// `files` ordering: `path` (discovery order, the default) or `symbols`
/// (descending symbol count — biggest files first, the "where's the bulk" view).
pub const SortKey = enum {
    default,
    line,
    name,
    span,
    callers,
    callees,
    fan_in,
    fan_in_exact,
    fan_out,
    fan_out_exact,

    pub fn parse(s: []const u8) ?SortKey {
        inline for (std.meta.fields(SortKey)) |field| {
            if (field.value != @intFromEnum(SortKey.default) and std.mem.eql(u8, s, field.name))
                return @enumFromInt(field.value);
        }
        return null;
    }
};

pub const FileSort = enum {
    path,
    symbols,

    pub fn parse(s: []const u8) ?FileSort {
        if (std.mem.eql(u8, s, "path") or std.mem.eql(u8, s, "name")) return .path;
        if (std.mem.eql(u8, s, "symbols") or std.mem.eql(u8, s, "size")) return .symbols;
        return null;
    }
};

pub const ChurnSort = enum {
    commits,
    lines,

    pub fn parse(s: []const u8) ?ChurnSort {
        if (std.mem.eql(u8, s, "commits") or std.mem.eql(u8, s, "changes")) return .commits;
        if (std.mem.eql(u8, s, "lines") or std.mem.eql(u8, s, "churn")) return .lines;
        return null;
    }
};

/// Unified test-scope selector shared by every verb: whether test code (Zig
/// `test` blocks, `test_*` functions, files under a test dir) is in view.
///   `with`    — production + tests (the default)
///   `without` — production only (alias `--no-tests`)
///   `only`    — tests only (alias `--tests-only`)
pub const TestScope = enum {
    with,
    without,
    only,

    pub fn parse(s: []const u8) ?TestScope {
        if (eqAny(s, &.{ "with", "both", "all" })) return .with;
        if (eqAny(s, &.{ "without", "no", "none", "exclude", "prod" })) return .without;
        if (eqAny(s, &.{ "only", "tests", "test" })) return .only;
        return null;
    }

    fn eqAny(s: []const u8, opts: []const []const u8) bool {
        for (opts) |o| if (std.mem.eql(u8, s, o)) return true;
        return false;
    }
};

pub const Vis = enum {
    all,
    public,
    private,

    pub fn parse(s: []const u8) ?Vis {
        if (std.mem.eql(u8, s, "all")) return .all;
        if (std.mem.eql(u8, s, "public")) return .public;
        if (std.mem.eql(u8, s, "private")) return .private;
        return null;
    }
};

/// Default result cap when the caller asked for none.
pub const default_limit: u32 = 300;
/// `hot`'s brief default when no explicit `-l` was given.
pub const hot_default: u32 = 25;

/// The effective cap for `hot`: its own short default unless `-l` was given.
pub fn hotLimit(opts: Options) u32 {
    return if (opts.limit_set) opts.limit else hot_default;
}

fn compactCap(opts: Options, base: u32, estimated_node_bytes: u32) u32 {
    std.debug.assert(base > 0);
    std.debug.assert(estimated_node_bytes > 0);
    var cap = base;
    if (opts.max_nodes != 0) cap = @min(cap, opts.max_nodes);
    if (opts.budget != 0) cap = @min(cap, @max(@as(u32, 1), opts.budget / estimated_node_bytes));
    return cap;
}

fn compactOptions(opts: Options, estimated_node_bytes: u32) Options {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(estimated_node_bytes > 0);
    var bounded = opts;
    bounded.limit = compactCap(opts, opts.limit, estimated_node_bytes);
    if (bounded.summary) bounded.verbosity = .names;
    return bounded;
}

pub const Options = struct {
    verbosity: render.Verbosity = .sig,
    depth: u32 = 1,
    limit: u32 = default_limit,
    /// Whether `limit` was asked for rather than defaulted. Lists that had no
    /// cap before `-l` was declared on them consult it, as does `hot`'s shorter
    /// default — an explicit `-l 300` must not read as "unset".
    limit_set: bool = false,
    /// Traversal compaction: exact node cap, approximate output-byte budget,
    /// and compact rendering for retained/pruned branches.
    max_nodes: u32 = 0,
    budget: u32 = 0,
    summary: bool = false,
    /// Stable JSONL page offset, decoded from `v1:<ordinal>`.
    after: u32 = 0,
    /// Distinguishes an explicit `--after v1:0` from the default first page.
    after_set: bool = false,
    /// Follow only edges that the active analysis classifies as exact.
    strict: bool = false,
    format: OutputFormat = .text,
    /// `search`: match reference/use sites (usages), not just definition names.
    refs: bool = false,
    /// Restrict `outline`/`search` to symbols whose kind tag is in this
    /// comma-separated set (e.g. "fn,method"). Empty means all kinds.
    kinds: []const u8 = "",
    /// `unused --no-public`: drop exported symbols (they may be public API, not
    /// dead code). The test axis (whether test usage counts / test code is in
    /// scope) is the unified `tests` selector above, not a separate flag.
    unused_skip_exported: bool = false,
    /// `unused`: disambiguate same-named symbols by import reachability instead of
    /// the (safe) family-wide name tally. Surfaces dead code masked by a used
    /// same-name twin in another package, at the cost of depending on import
    /// resolution — an unresolved import can hide a real use (false positive).
    unused_follow_imports: bool = false,
    /// `files`: result ordering (discovery order or descending symbol count).
    file_sort: FileSort = .path,
    /// Ranking for outline/search/hot. `.default` preserves existing output.
    sort: SortKey = .default,
    churn_sort: ChurnSort = .commits,
    history_last: u32 = 10,
    history_last_set: bool = false,
    /// Directional reference filtering and flow type scope.
    writers: bool = false,
    readers: bool = false,
    unread: bool = false,
    on_type: []const u8 = "",
    flow_to: []const u8 = "",
    /// Duplicate-name aggregation controls.
    duplicates: bool = false,
    collision_members: bool = false,
    /// Unified test-scope selector: include test code (default), exclude it
    /// (`--no-tests`), or restrict to it (`--tests-only`). Applies to
    /// `outline`/`search`/`callers`/`hot`.
    tests: TestScope = .with,
    /// `search --exact`: names must equal the pattern (no substring match) —
    /// the way to find refs to `Order` without every `createOrder` hit.
    exact: bool = false,
    /// `outline`/`files --no-recurse`: only files directly in the given
    /// directory, not its subtrees (Go "outline this package", not the world).
    no_recurse: bool = false,
    /// Add inferred protocol/interface implementation edges to graph walks.
    impls: bool = false,
    /// Include per-method override relationships in `hierarchy`.
    hierarchy_overrides: bool = false,
    /// Workflow, history, and safe-refactor selectors.
    from_tests: bool = false,
    since: []const u8 = "",
    preview: bool = false,
    /// `diff`: include current-source byte ranges and the exact raw git patch.
    exact_source: bool = false,
    /// Visibility scope for definition listings.
    visibility: Vis = .all,
    /// Alternate HTTP route views and handler selection.
    routes_clients: bool = false,
    routes_unhit: bool = false,
    routes_orphan_calls: bool = false,
    routes_handler: []const u8 = "",
};

/// Whether `sym` is test code: a Zig `test` block, a symbol in a test file/dir,
/// or a `test_*` function (pytest). Drives the `--tests` scope selector and the
/// `coverage` seed set.
pub fn isTestSymbol(idx: *const Index, sym: model.Symbol) bool {
    if (sym.kind == .test_case) return true;
    const file = idx.graph.files[sym.file];
    if (isTestPath(file.path)) return true;
    if (file.language == .python and std.mem.startsWith(u8, sym.name, "test_")) return true;
    return false;
}

/// Apply the `--tests` scope selector to a symbol's test-ness.
pub fn inTestScope(scope: TestScope, is_test: bool) bool {
    return switch (scope) {
        .with => true,
        .without => !is_test,
        .only => is_test,
    };
}

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
        if (kind == .interface and std.mem.eql(u8, t, "interface")) return true;
        if (kind == .constant and std.mem.eql(u8, t, "constant")) return true;
        if (kind == .variable and std.mem.eql(u8, t, "variable")) return true;
        if (kind == .module and std.mem.eql(u8, t, "module")) return true;
    }
    return false;
}

pub fn visAllowed(sym: model.Symbol, vis: Vis) bool {
    const public = sym.name.len > 0 and sym.name[0] != '_' and sym.exported;
    return switch (vis) {
        .all => true,
        .public => public,
        .private => !public,
    };
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

/// The number of call sites from `from` to `to` (summed over its references, so
/// a caller that invokes the target several times reports the true multiplicity
/// rather than collapsing to a single edge). Rendered as `↳:N ×C` when > 1.
pub fn callSiteCount(idx: *const Index, from: SymbolId, to: SymbolId) u32 {
    var total: u32 = 0;
    for (idx.graph.symbols[from].refs) |ref| {
        if (ref.target == to) total += ref.count;
    }
    return total;
}

/// Collect the distinct call-site lines from `from` to `to` into `out` (sorted
/// ascending, deduplicated). Combines every matching reference — a target reached
/// through more than one receiver (e.g. `a.run()` and `b.run()`) contributes each
/// of its lines — so `callers` shows all sites, not just the earliest. `out` is
/// cleared first; the caller owns its storage.
pub fn callSiteLines(idx: *const Index, from: SymbolId, to: SymbolId, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    for (idx.graph.symbols[from].refs) |ref| {
        if (ref.target != to) continue;
        if (ref.lines.len > 1) {
            try out.appendSlice(idx.gpa, ref.lines);
        } else {
            try out.append(idx.gpa, ref.line);
        }
    }
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    // Dedup in place (lines from distinct receivers can coincide).
    var w: usize = 0;
    for (out.items) |ln| {
        if (w == 0 or out.items[w - 1] != ln) {
            out.items[w] = ln;
            w += 1;
        }
    }
    out.shrinkRetainingCapacity(w);
}

/// Print an outline of the file(s) under `path_filter` (a path prefix, or ""
/// for the whole project). Symbols are grouped by file and indented by nesting.
/// Returns whether any symbol was printed.
pub fn outline(w: *Writer, idx: *const Index, path_filter: []const u8, opts: Options) !bool {
    const effective = compactOptions(opts, 96);
    if (effective.sort != .default and effective.sort != .line) return rankedDefinitions(w, idx, path_filter, "", effective, true);
    if (effective.format == .jsonl) return json_out.outlineJsonl(w, idx, path_filter, effective);
    if (effective.format == .json) return json_out.outline(w, idx, path_filter, effective);
    var shown: u32 = 0;
    var any = false;
    var summarized: u32 = 0;
    for (idx.graph.files) |file| {
        if (!matchesFilter(file.path, path_filter)) continue;
        if (effective.no_recurse and !inDirNonRecursive(file.path, path_filter)) continue;
        // Skip a file with nothing to show under the active kind/test-scope
        // filters, so `--tests only`/`--no-tests` never print an empty header.
        if (visibleSymbolCount(idx, file, effective) == 0) continue;
        any = true;
        try w.print("# {s} ({s})\n", .{ file.path, file.language.tag() });
        // Once the symbol budget is spent, keep naming every remaining file (with
        // its symbol count) instead of dropping it off the tail — so an agent
        // never mistakes a truncated-away file for a nonexistent one. Truncation
        // is per-file, not whole-files-vanish.
        if (shown >= effective.limit) {
            const n = visibleSymbolCount(idx, file, effective);
            try w.print("  … {d} symbol{s} here (raise -l to list)\n", .{ n, if (n == 1) "" else "s" });
            summarized += 1;
            continue;
        }
        _ = try outlineFile(w, idx, file, effective, &shown);
    }
    if (!any) {
        try w.print("(no source symbols under '{s}')\n", .{path_filter});
        try kindHint(w, idx, path_filter, effective);
        try outlinePathHint(w, idx, path_filter);
        try skippedNote(w, idx);
    }
    if (shown >= effective.limit) {
        const reason = if (opts.max_nodes != 0) "--max-nodes" else if (opts.budget != 0) "--budget" else "-l";
        if (summarized > 0) {
            try w.print("… (listed {d} symbols; {d} more file(s) named but not expanded — raise {s})\n", .{ effective.limit, summarized, reason });
        } else {
            try w.print("… (stopped at {s} {d}; raise it to see more)\n", .{ reason, effective.limit });
        }
    }
    return shown > 0;
}

/// Warn when output was capped by `-l`, so a truncated result is never mistaken
/// for the complete set. Printed to the same stream as the results.
fn truncationNote(w: *Writer, opts: Options, shown: u32) !void {
    if (shown >= opts.limit) {
        try w.print("… (stopped at -l {d}; more results may exist — raise -l to see them)\n", .{opts.limit});
    }
}

/// After an empty result, name the directories the walker pruned so "nothing
/// here" isn't misread as "does not exist" — the code may simply live in a
/// skipped subtree (a fixture/vendor/build dir). Only prints when a dir with the
/// requested content could plausibly be hiding there, i.e. something was skipped.
fn skippedNote(w: *Writer, idx: *const Index) !void {
    if (idx.skipped_dirs.len == 0) return;
    try w.writeAll("  (not indexed — skipped: ");
    for (idx.skipped_dirs, 0..) |d, i| {
        if (i != 0) try w.writeAll(", ");
        // Annotated entries ("x.js (minified)") are files, not pruned dirs.
        if (std.mem.endsWith(u8, d, ")")) {
            try w.print("{s}", .{d});
        } else {
            try w.print("{s}/", .{d});
        }
    }
    try w.writeAll("; index one with `-C <dir>`)\n");
}

fn outlineFile(w: *Writer, idx: *const Index, file: model.SourceFile, opts: Options, shown: *u32) !u32 {
    var count: u32 = 0;
    var i = file.sym_start;
    // At `-v full`, the end line of the last full-body symbol printed: a child
    // whose whole span that source already contains (a dataclass's fields, a
    // class's methods) would print the same text twice — skip it. A `-k` filter
    // that excludes the parent leaves the child as the only copy, which still
    // prints because nothing set `full_span_end` over it.
    var full_span_end: u32 = 0;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import) continue;
        if (!sym.kind.isTopLevelInteresting() and sym.parent == invalid) continue;
        if (!kindAllowed(sym.kind, opts.kinds)) continue;
        if (!visAllowed(sym, opts.visibility)) continue;
        if (!inTestScope(opts.tests, isTestSymbol(idx, sym))) continue;
        if (opts.verbosity == .full) {
            const end = sym.endLine(file.text);
            if (sym.parent != invalid and end <= full_span_end) continue;
            full_span_end = @max(full_span_end, end);
        }
        const indent = 1 + parentDepth(idx, sym);
        try render.symbol(w, idx, sym, opts.verbosity, indent, false);
        count += 1;
        shown.* += 1;
        if (shown.* >= opts.limit) break;
    }
    return count;
}

/// Count the symbols `outlineFile` would print for `file` (same visibility rules)
/// — used to summarize a file whose listing was cut by the `-l` budget without
/// hiding its existence.
fn visibleSymbolCount(idx: *const Index, file: model.SourceFile, opts: Options) u32 {
    var count: u32 = 0;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import) continue;
        if (!sym.kind.isTopLevelInteresting() and sym.parent == invalid) continue;
        if (!kindAllowed(sym.kind, opts.kinds)) continue;
        if (!visAllowed(sym, opts.visibility)) continue;
        if (!inTestScope(opts.tests, isTestSymbol(idx, sym))) continue;
        count += 1;
    }
    return count;
}

fn parentDepth(idx: *const Index, sym: model.Symbol) usize {
    var depth: usize = 0;
    var p = sym.parent;
    while (p != invalid) : (depth += 1) p = idx.graph.symbols[p].parent;
    return depth;
}

pub fn matchesFilter(path: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (isGlobPattern(filter)) {
        // Gitignore-style: a pattern with a `/` globs against the whole
        // relative path (`src/*.py`, `**/api/*.ts`); one without globs against
        // the basename (`*_test.py` matches at any depth).
        if (std.mem.indexOfScalar(u8, filter, '/') != null) return gitignore.glob(filter, path);
        const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
        return gitignore.glob(filter, base);
    }
    return std.mem.startsWith(u8, path, filter) or std.mem.indexOf(u8, path, filter) != null;
}

/// `--no-recurse`: whether `path` sits *directly* in directory `dir` (no
/// intermediate subdirectory) — the "outline this package, not its subpackages"
/// scope. `dir` may carry a trailing `/`.
pub fn inDirNonRecursive(path: []const u8, dir: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const parent = if (slash) |i| path[0..i] else "";
    var d = dir;
    while (d.len != 0 and d[d.len - 1] == '/') d = d[0 .. d.len - 1];
    return std.mem.eql(u8, parent, d);
}

/// Whether `pattern` opts into glob matching. Only `*` triggers glob mode — a
/// lone `?` stays literal because Ruby method names legitimately end in `?`.
pub fn isGlobPattern(pattern: []const u8) bool {
    return std.mem.indexOfScalar(u8, pattern, '*') != null;
}

/// Symbol-name match: whole-name glob when the pattern contains `*`
/// (`Ba*` → `Bays`, `Bananas`; `*_handler` → suffix), else substring.
pub fn matchesName(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return true;
    if (isGlobPattern(pattern)) return gitignore.glob(pattern, name);
    return std.mem.indexOf(u8, name, pattern) != null;
}

/// Exact match, or whole-text glob when the pattern carries a `*`.
fn exactOrGlob(pattern: []const u8, text: []const u8) bool {
    if (isGlobPattern(pattern)) return gitignore.glob(pattern, text);
    return std.mem.eql(u8, pattern, text);
}

/// Match inside a string literal: substring normally; a `*` pattern globs
/// *unanchored* (wrapped in `**` so it can hit mid-literal and cross `/`).
/// `wrapStringPattern` builds the wrapped form once per query.
pub fn matchesString(wrapped_or_plain: []const u8, is_glob: bool, s: []const u8) bool {
    if (is_glob) return gitignore.glob(wrapped_or_plain, s);
    return std.mem.indexOf(u8, s, wrapped_or_plain) != null;
}

/// For a glob `pattern`, return `**pattern**` (gpa-owned); else the pattern
/// itself (borrowed). Pair with `matchesString`.
pub fn wrapStringPattern(gpa: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    if (!isGlobPattern(pattern)) return pattern;
    return std.fmt.allocPrint(gpa, "**{s}**", .{pattern});
}

pub const StatusChangeKind = enum { changed, unavailable };

pub const StatusChange = struct {
    file: model.FileId,
    kind: StatusChangeKind,
    error_name: []const u8 = "",
};

pub const StatusReport = struct {
    changes: []StatusChange,
    root_error: []const u8 = "",
    scope_files: u32 = 0,
    scope_symbols: u32 = 0,
    parse_warnings: u32 = 0,
    unresolved_refs: u32 = 0,
    likely_local_refs: u32 = 0,
    external_or_unmodeled_refs: u32 = 0,
    skipped: u32 = 0,

    pub fn deinit(self: *StatusReport, gpa: std.mem.Allocator) void {
        gpa.free(self.changes);
        self.* = undefined;
    }
};

/// Report the in-memory index snapshot, cache use, filesystem freshness, and
/// diagnostics that can make an apparently missing symbol or edge unreliable.
pub fn status(w: *Writer, io: std.Io, idx: *const Index, filter: []const u8, opts: Options) !bool {
    return statusWithRoot(w, io, idx, filter, opts, null);
}

pub fn statusInRoot(
    w: *Writer,
    io: std.Io,
    idx: *const Index,
    root_dir: std.Io.Dir,
    canonical_root: []const u8,
    single_file_target: ?[]const u8,
    filter: []const u8,
    opts: Options,
) !bool {
    return statusWithRoot(w, io, idx, filter, opts, .{
        .dir = root_dir,
        .canonical = canonical_root,
        .single_file_target = single_file_target,
    });
}

const StatusRoot = struct {
    dir: std.Io.Dir,
    canonical: []const u8,
    single_file_target: ?[]const u8,
};

fn statusWithRoot(w: *Writer, io: std.Io, idx: *const Index, filter: []const u8, opts: Options, bound_root: ?StatusRoot) !bool {
    var report = try collectStatus(idx, io, filter, opts, bound_root);
    defer report.deinit(idx.gpa);
    if (opts.format == .json) return json_out.status(w, idx, filter, report, opts);
    if (opts.format == .jsonl) return json_out.statusJsonl(w, idx, filter, report, opts);
    try renderStatusSummary(w, idx, filter, report);
    try renderStatusFreshness(w, idx, report);
    try renderStatusDiagnostics(w, idx, filter, report, opts);
    return true;
}

fn collectStatus(idx: *const Index, io: std.Io, filter: []const u8, opts: Options, bound_root: ?StatusRoot) !StatusReport {
    std.debug.assert(idx.graph.files.len == idx.file_stats.len);
    std.debug.assert(opts.limit > 0);
    var report = StatusReport{ .changes = &.{} };
    for (idx.graph.files) |file| {
        if (!statusFileSelected(file, filter, opts)) continue;
        report.scope_files += 1;
        report.scope_symbols += file.sym_end - file.sym_start;
        if (!file.parse_health.reliable()) report.parse_warnings += 1;
        const resolution = unresolvedInFile(idx, file);
        report.likely_local_refs += resolution.likely_local;
        report.external_or_unmodeled_refs += resolution.external_or_unmodeled;
        report.unresolved_refs += resolution.likely_local + resolution.external_or_unmodeled;
    }
    for (idx.skipped_dirs) |path| {
        if (filter.len == 0 or matchesFilter(path, filter)) report.skipped += 1;
    }
    report.changes = try collectStatusChanges(idx, io, filter, opts, bound_root, &report.root_error);
    return report;
}

pub fn statusFileSelected(file: model.SourceFile, filter: []const u8, opts: Options) bool {
    if (!matchesFilter(file.path, filter)) return false;
    return !opts.no_recurse or inDirNonRecursive(file.path, filter);
}

const UnresolvedCounts = struct { likely_local: u32 = 0, external_or_unmodeled: u32 = 0 };

fn unresolvedInFile(idx: *const Index, file: model.SourceFile) UnresolvedCounts {
    std.debug.assert(file.sym_start <= file.sym_end);
    std.debug.assert(file.sym_end <= idx.graph.symbols.len);
    var count: UnresolvedCounts = .{};
    for (idx.graph.symbols[file.sym_start..file.sym_end]) |sym| {
        for (sym.refs) |ref| if (referenceNeedsDiagnostic(sym, ref)) {
            switch (referenceDiagnosticClass(idx, sym, ref).?) {
                .likely_local => count.likely_local += 1,
                .external_or_unmodeled => count.external_or_unmodeled += 1,
            }
        };
    }
    return count;
}

/// A bare parameter/local intentionally has no graph target; do not diagnose it
/// as unresolved merely because its value is outside the symbol graph.
pub fn referenceIsLocal(sym: model.Symbol, ref: model.Reference) bool {
    if (ref.qualifier.len != 0) return false;
    for (sym.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, ref.name)) return true;
    }
    return false;
}

pub fn referenceIsUnresolved(sym: model.Symbol, ref: model.Reference) bool {
    return ref.target == invalid and !referenceIsLocal(sym, ref);
}

/// Only unresolved call/type/import edges are graph diagnostics. Plain reads and
/// writes can be external fields, literals, or values NavGraph does not model.
pub fn referenceNeedsDiagnostic(sym: model.Symbol, ref: model.Reference) bool {
    if (!referenceIsUnresolved(sym, ref)) return false;
    return ref.kind != .read;
}

pub const ReferenceDiagnosticClass = enum { likely_local, external_or_unmodeled };

/// Split actionable graph misses from ordinary library/dynamic calls. This is
/// deliberately conservative: a miss is "likely local" only when indexed
/// evidence (same-family candidate, known receiver type, or self dispatch)
/// says NavGraph should plausibly have linked it.
pub fn referenceDiagnosticClass(idx: *const Index, sym: model.Symbol, ref: model.Reference) ?ReferenceDiagnosticClass {
    if (!referenceNeedsDiagnostic(sym, ref)) return null;
    if (std.mem.eql(u8, ref.qualifier, "self") or std.mem.eql(u8, ref.qualifier, "this")) return .likely_local;

    const from_family = idx.graph.files[sym.file].language.family();
    if (ref.qualifier.len != 0) {
        for (sym.bindings) |binding| {
            if (!std.mem.eql(u8, binding.name, ref.qualifier) or binding.type_name.len == 0) continue;
            for (idx.lookup(binding.type_name)) |type_id| {
                const type_sym = idx.graph.symbols[type_id];
                if (diagnosticTypeLike(type_sym.kind) and idx.graph.files[type_sym.file].language.family() == from_family) return .likely_local;
            }
        }
        for (idx.lookup(ref.qualifier)) |type_id| {
            const type_sym = idx.graph.symbols[type_id];
            if (diagnosticTypeLike(type_sym.kind) and idx.graph.files[type_sym.file].language.family() == from_family) return .likely_local;
        }
        return .external_or_unmodeled;
    }

    // Chained/literal member calls can have no identifier receiver in the
    // lightweight reference model (`String(x).replace(...)`, `xs?.slice()`).
    // Their exact offsets still prove the occurrence is dot-qualified. Do not
    // promote those to "likely local" merely because an unrelated workspace
    // method shares the same common builtin name.
    if (receiverlessMemberSyntax(idx.graph.files[sym.file].text, ref)) return .external_or_unmodeled;

    for (idx.lookup(ref.name)) |candidate_id| {
        const candidate = idx.graph.symbols[candidate_id];
        if (idx.graph.files[candidate.file].language.family() != from_family) continue;
        if (candidate.file == sym.file or ref.kind == .type_use or ref.kind == .call) return .likely_local;
    }
    return .external_or_unmodeled;
}

fn receiverlessMemberSyntax(source: []const u8, ref: model.Reference) bool {
    if (ref.offsets.len == 0) return false;
    for (ref.offsets) |raw_offset| {
        var offset: usize = @intCast(raw_offset);
        if (offset > source.len) return false;
        while (offset != 0 and std.ascii.isWhitespace(source[offset - 1])) offset -= 1;
        if (offset == 0 or source[offset - 1] != '.') return false;
    }
    return true;
}

fn diagnosticTypeLike(kind: model.SymbolKind) bool {
    return switch (kind) {
        .class, .@"struct", .@"enum", .interface, .type => true,
        else => false,
    };
}

fn collectStatusChanges(
    idx: *const Index,
    io: std.Io,
    filter: []const u8,
    opts: Options,
    bound_root: ?StatusRoot,
    root_error: *[]const u8,
) ![]StatusChange {
    var changes: std.ArrayList(StatusChange) = .empty;
    errdefer changes.deinit(idx.gpa);
    var owned_dir: ?std.Io.Dir = null;
    const dir = if (bound_root) |root|
        root.dir
    else blk: {
        owned_dir = openSnapshotRoot(io, idx.root) catch |err| {
            root_error.* = @errorName(err);
            return changes.toOwnedSlice(idx.gpa);
        };
        break :blk owned_dir.?;
    };
    defer if (owned_dir) |owned| owned.close(io);
    for (idx.graph.files, idx.file_stats) |file, snapshot| {
        if (!statusFileSelected(file, filter, opts)) continue;
        const current = if (bound_root) |root| current: {
            var opened = (if (root.single_file_target) |target|
                workspace_path.openFileKnownTarget(dir, io, root.canonical, file.path, target)
            else
                workspace_path.openFileKnownRoot(dir, io, root.canonical, file.path)) catch |err| {
                try changes.append(idx.gpa, .{ .file = file.id, .kind = .unavailable, .error_name = @errorName(err) });
                continue;
            };
            defer opened.close(io);
            break :current opened.stat(io) catch |err| {
                try changes.append(idx.gpa, .{ .file = file.id, .kind = .unavailable, .error_name = @errorName(err) });
                continue;
            };
        } else dir.statFile(io, file.path, .{}) catch |err| {
            try changes.append(idx.gpa, .{ .file = file.id, .kind = .unavailable, .error_name = @errorName(err) });
            continue;
        };
        if (statChanged(snapshot, current)) try changes.append(idx.gpa, .{ .file = file.id, .kind = .changed });
    }
    return changes.toOwnedSlice(idx.gpa);
}

fn openSnapshotRoot(io: std.Io, root: []const u8) !std.Io.Dir {
    std.debug.assert(root.len > 0);
    return std.Io.Dir.cwd().openDir(io, root, .{}) catch |err| {
        if (err != error.NotDir) return err;
        const parent = std.fs.path.dirname(root) orelse ".";
        return std.Io.Dir.cwd().openDir(io, parent, .{});
    };
}

fn statChanged(snapshot: cache.FileStat, current: std.Io.File.Stat) bool {
    return snapshot.mtime_ns != current.mtime.nanoseconds or
        snapshot.ctime_ns != current.ctime.nanoseconds or snapshot.size != current.size;
}

fn renderStatusSummary(w: *Writer, idx: *const Index, filter: []const u8, report: StatusReport) !void {
    try w.print("index root: {s}\n", .{idx.root});
    try w.print("snapshot: {d} files, {d} symbols", .{ idx.graph.files.len, idx.graph.symbols.len });
    if (filter.len != 0) try w.print("; scope '{s}': {d} files, {d} symbols", .{ filter, report.scope_files, report.scope_symbols });
    try w.writeByte('\n');
    const state = idx.cache_snapshot;
    if (!state.enabled) {
        try w.writeAll("cache: disabled\n");
    } else {
        try w.print("cache: loaded={}, entries={d}, hits={d}/{d}, rewrite={s}\n", .{
            state.loaded, state.loaded_entries, state.hits, idx.graph.files.len, @tagName(state.rewrite),
        });
    }
}

fn renderStatusFreshness(w: *Writer, idx: *const Index, report: StatusReport) !void {
    if (report.root_error.len != 0) {
        try w.print("freshness: unavailable ({s})\n", .{report.root_error});
        return;
    }
    if (report.changes.len == 0) {
        try w.writeAll("freshness: current\n");
        return;
    }
    try w.print("freshness: {d} indexed file{s} changed since build\n", .{ report.changes.len, if (report.changes.len == 1) "" else "s" });
    for (report.changes) |change| {
        const file = idx.graph.files[change.file];
        if (change.kind == .changed) try w.print("  changed {s}\n", .{file.path}) else try w.print("  unavailable {s} ({s})\n", .{ file.path, change.error_name });
    }
}

fn renderStatusDiagnostics(w: *Writer, idx: *const Index, filter: []const u8, report: StatusReport, opts: Options) !void {
    try w.print("parse health: {d} warning{s}\n", .{ report.parse_warnings, if (report.parse_warnings == 1) "" else "s" });
    for (idx.graph.files) |file| {
        if (!statusFileSelected(file, filter, opts)) continue;
        const from = file.parse_health.desync_from orelse continue;
        try w.print("  {s}:{d}-{d} tokenizer_desync\n", .{ file.path, from, file.parse_health.desync_to });
    }
    try w.print("skipped: {d}\n", .{report.skipped});
    for (idx.skipped_dirs) |path| if (filter.len == 0 or matchesFilter(path, filter)) try w.print("  {s}\n", .{path});
    try renderUnresolvedStatus(w, idx, filter, report, opts);
}

fn renderUnresolvedStatus(w: *Writer, idx: *const Index, filter: []const u8, report: StatusReport, opts: Options) !void {
    try w.print("resolution health: {d} likely-local miss{s}; {d} external/unmodeled edge{s}\n", .{
        report.likely_local_refs,
        if (report.likely_local_refs == 1) "" else "es",
        report.external_or_unmodeled_refs,
        if (report.external_or_unmodeled_refs == 1) "" else "s",
    });
    var shown: u32 = 0;
    inline for (.{ ReferenceDiagnosticClass.likely_local, ReferenceDiagnosticClass.external_or_unmodeled }) |wanted| {
        outer: for (idx.graph.symbols) |sym| {
            const file = idx.graph.files[sym.file];
            if (!statusFileSelected(file, filter, opts)) continue;
            for (sym.refs) |ref| {
                if (referenceDiagnosticClass(idx, sym, ref) != wanted) continue;
                const qualifier = if (ref.qualifier.len == 0) "" else ref.qualifier;
                try w.print("  [{s}] {s}:{d} {s}{s}{s} in {s}", .{
                    if (wanted == .likely_local) "likely-local" else "external",
                    file.path,
                    ref.line,
                    qualifier,
                    if (qualifier.len == 0) "" else ".",
                    ref.name,
                    sym.name,
                });
                if (!file.parse_health.reliable()) try w.writeAll(" (parse unreliable)");
                try w.writeByte('\n');
                shown += 1;
                if (shown >= opts.limit) break :outer;
            }
        }
        if (shown >= opts.limit) break;
    }
    if (shown < report.unresolved_refs) try w.print("  … {d} graph edges elided (-l {d})\n", .{ report.unresolved_refs - shown, opts.limit });
}

/// The index's coverage manifest: every indexed file with its language and
/// symbol count. Lets an agent verify what NavGraph actually parsed — a file
/// that's absent (in an ignored dir) or shows 0 symbols is visible here, so a
/// "not found" from another verb can be diagnosed instead of trusted blindly.
/// Returns whether any indexed file matched `filter`.
pub fn listFiles(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.listFiles(w, idx, filter, opts);
    const ranked = try collectFiles(idx, filter, opts);
    defer idx.gpa.free(ranked);
    if (ranked.len == 0) {
        try w.print("(no indexed files under '{s}')\n", .{filter});
        try skippedNote(w, idx);
        return false;
    }
    const shown = @min(ranked.len, opts.limit);
    for (ranked[0..shown]) |entry| {
        const file = idx.graph.files[entry.id];
        try w.print("{s}  ({s}, {d} symbol{s})\n", .{
            file.path, file.language.tag(), entry.count, if (entry.count == 1) "" else "s",
        });
    }
    try truncationNote(w, opts, @intCast(shown));
    return true;
}

/// Collect in-scope files in the requested stable order. Renderers apply `limit`.
pub const RankedFile = struct { id: model.FileId, count: u32 };

pub fn collectFiles(idx: *const Index, filter: []const u8, opts: Options) ![]RankedFile {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.files.len <= std.math.maxInt(model.FileId));
    var ranked: std.ArrayList(RankedFile) = .empty;
    defer ranked.deinit(idx.gpa);
    for (idx.graph.files) |file| {
        if (!matchesFilter(file.path, filter)) continue;
        if (opts.no_recurse and !inDirNonRecursive(file.path, filter)) continue;
        try ranked.append(idx.gpa, .{ .id = file.id, .count = fileSymbolCount(idx, file) });
    }
    if (opts.file_sort == .symbols) {
        std.mem.sort(RankedFile, ranked.items, idx, rankedFileLessThan);
    } else {
        std.mem.sort(RankedFile, ranked.items, idx, rankedFilePathLessThan);
    }
    return ranked.toOwnedSlice(idx.gpa);
}

/// Descending symbol count, then ascending path for a stable, readable order.
fn rankedFileLessThan(idx: *const Index, a: RankedFile, b: RankedFile) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, idx.graph.files[a.id].path, idx.graph.files[b.id].path);
}

fn rankedFilePathLessThan(idx: *const Index, a: RankedFile, b: RankedFile) bool {
    return std.mem.lessThan(u8, idx.graph.files[a.id].path, idx.graph.files[b.id].path);
}

/// Count non-import symbols in a file (its outline size).
pub fn fileSymbolCount(idx: *const Index, file: model.SourceFile) u32 {
    var n: u32 = 0;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        if (idx.graph.symbols[i].kind != .import) n += 1;
    }
    return n;
}

/// Cap on a `read` from disk (indexed files are already bounded at index time).
const max_read_bytes = 8 * 1024 * 1024;
/// A source request may batch this many user ranges. The bound keeps parsing and
/// continuation metadata small and deterministic for agent callers.
pub const max_read_ranges: usize = 16;
/// `read` always has a byte-shaped safety bound, even when the caller only uses
/// the universal line/result limit. This is an estimate over numbered source
/// rows; `--budget` can request a smaller or larger page explicitly.
pub const default_read_budget: u32 = 64 * 1024;

pub const ReadSpecError = error{
    MalformedRange,
    DescendingRange,
    TooManyRanges,
};

pub const ReadSpec = struct {
    path: []const u8,
    ranges: []const LineRange,
};

/// One bounded page of the normalized source selection. `after` is an ordinal
/// in the selected (not physical-file) lines, so the same cursor works for a
/// whole file and for a batched set of disjoint ranges.
pub const ReadPage = struct {
    ranges: []const LineRange,
    offset: u32,
    limit: u32,
    budget: u32,
    selected: u32,
    shown: u32,
    estimated_bytes: u32,
    truncated: bool,
    next: ?u32,
};

/// Print raw, numbered source lines of `spec` — a `path` or `path:A-B` range.
/// The escape hatch for text NavGraph can't attribute to a symbol: module-scope
/// statements, config, comments, an arbitrary line. Bytes come from the in-memory
/// index when the file is indexed, else are read from disk relative to `root`, so
/// config files and files under ignored dirs are reachable too. Returns whether
/// at least one source line was printed.
pub fn readLines(w: *Writer, io: std.Io, idx: *const Index, root: []const u8, spec: []const u8, opts: Options) !bool {
    return readLinesWithRoot(w, io, idx, .{ .path = root }, spec, opts);
}

pub fn readLinesInRoot(
    w: *Writer,
    io: std.Io,
    idx: *const Index,
    root_dir: std.Io.Dir,
    canonical_root: []const u8,
    single_file: ?[]const u8,
    single_file_target: ?[]const u8,
    spec: []const u8,
    opts: Options,
) !bool {
    return readLinesWithRoot(w, io, idx, .{ .bound = .{
        .dir = root_dir,
        .canonical = canonical_root,
        .single_file = single_file,
        .single_file_target = single_file_target,
    } }, spec, opts);
}

const SourceRoot = union(enum) {
    path: []const u8,
    bound: struct {
        dir: std.Io.Dir,
        canonical: []const u8,
        single_file: ?[]const u8,
        single_file_target: ?[]const u8,
    },
};

fn readLinesWithRoot(w: *Writer, io: std.Io, idx: *const Index, root: SourceRoot, spec: []const u8, opts: Options) !bool {
    std.debug.assert(spec.len > 0);
    // Empty `ranges` means the whole file; one or more means `file:A-B,C-D` — a
    // batched read that pulls several disjoint slices in one call (a symbol and
    // its neighbours, a definition and its use, etc.) instead of N invocations.
    // Range-shaped suffixes are parsed as a typed request: malformed input must
    // never fall through to a misleading `no_such_file` result.
    var ranges_buf: [max_read_ranges]LineRange = undefined;
    const parsed = parseReadSpec(spec, &ranges_buf) catch |err| {
        const value = readRangeSuffix(spec);
        try renderReadError(w, opts.format, readSpecErrorCode(err), readSpecErrorMessage(err), value);
        return false;
    };
    const path = parsed.path;
    const ranges = parsed.ranges;
    workspace_path.validateRelative(path) catch |err| {
        try renderReadContainmentError(w, opts.format, err, path);
        return false;
    };
    if (root == .bound) {
        if (root.bound.single_file) |allowed| {
            if (!std.mem.eql(u8, path, allowed)) {
                try renderReadError(w, opts.format, "path_outside_root", "server is scoped to one source file", path);
                return false;
            }
        }
    }
    var owned: ?[]u8 = null;
    defer if (owned) |b| idx.gpa.free(b);
    const text = indexedText(idx, path) orelse blk: {
        var owned_dir: ?std.Io.Dir = null;
        const rd = switch (root) {
            .path => |root_path| opened: {
                owned_dir = std.Io.Dir.cwd().openDir(io, root_path, .{}) catch {
                    try renderReadError(w, opts.format, "cannot_open_root", "cannot open repository root", root_path);
                    return false;
                };
                break :opened owned_dir.?;
            },
            .bound => |bound| bound.dir,
        };
        defer if (owned_dir) |dir| dir.close(io);
        const bytes = switch (root) {
            .path => workspace_path.readFileAlloc(rd, io, path, idx.gpa, .limited(max_read_bytes)),
            .bound => |bound| if (bound.single_file_target) |target|
                workspace_path.readFileAllocKnownTarget(rd, io, bound.canonical, path, target, idx.gpa, .limited(max_read_bytes))
            else
                workspace_path.readFileAllocKnownRoot(rd, io, bound.canonical, path, idx.gpa, .limited(max_read_bytes)),
        } catch |err| {
            if (isReadContainmentError(err)) {
                try renderReadContainmentError(w, opts.format, err, path);
                return false;
            }
            try renderReadError(w, opts.format, "no_such_file", "give a readable path relative to the repository root", path);
            return false;
        };
        owned = bytes;
        break :blk bytes;
    };
    return renderBoundedSourcePage(w, idx.gpa, path, text, ranges, opts);
}

/// Source-only CLI fast path. Reading an unsupported/config file must not first
/// index every supported file beneath `root` (or emit unrelated parse-health
/// warnings). Long-lived sessions still use `readLines` so indexed text can be
/// served from their coherent snapshot; one-shot `read` goes straight to disk.
pub fn readLinesStandalone(
    w: *Writer,
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    spec: []const u8,
    opts: Options,
) !bool {
    std.debug.assert(root.len > 0);
    std.debug.assert(spec.len > 0);
    var ranges_buf: [max_read_ranges]LineRange = undefined;
    const parsed = parseReadSpec(spec, &ranges_buf) catch |err| {
        const value = readRangeSuffix(spec);
        try renderReadError(w, opts.format, readSpecErrorCode(err), readSpecErrorMessage(err), value);
        return false;
    };
    workspace_path.validateRelative(parsed.path) catch |err| {
        try renderReadContainmentError(w, opts.format, err, parsed.path);
        return false;
    };
    var rd = std.Io.Dir.cwd().openDir(io, root, .{}) catch {
        try renderReadError(w, opts.format, "cannot_open_root", "cannot open repository root", root);
        return false;
    };
    defer rd.close(io);
    const text = workspace_path.readFileAlloc(rd, io, parsed.path, allocator, .limited(max_read_bytes)) catch |err| {
        if (isReadContainmentError(err)) {
            try renderReadContainmentError(w, opts.format, err, parsed.path);
            return false;
        }
        try renderReadError(w, opts.format, "no_such_file", "give a readable path relative to the repository root", parsed.path);
        return false;
    };
    defer allocator.free(text);
    return renderBoundedSourcePage(w, allocator, parsed.path, text, parsed.ranges, opts);
}

fn isReadContainmentError(err: anyerror) bool {
    return err == error.EmptyPath or err == error.AbsolutePath or err == error.ParentTraversal or err == error.OutsideRoot;
}

fn renderReadContainmentError(w: *Writer, format: OutputFormat, err: anyerror, path: []const u8) !void {
    const message = switch (err) {
        error.AbsolutePath => "absolute source paths are outside the repository authority boundary",
        error.ParentTraversal => "source paths containing '..' are outside the repository authority boundary",
        error.OutsideRoot => "source path resolves through a symlink outside the repository root",
        error.EmptyPath => "source path must not be empty",
        else => unreachable,
    };
    try renderReadError(w, format, "path_outside_root", message, path);
}

fn renderReadError(w: *Writer, format: OutputFormat, code: []const u8, message: []const u8, value: []const u8) !void {
    if (format == .json) {
        try json_out.readError(w, code, message, value);
    } else {
        try w.print("(read error [{s}]: {s}; got '{s}')\n", .{ code, message, value });
    }
}

fn sourcePageForLineCap(text: []const u8, ranges: []const LineRange, opts: Options, line_cap: u32, buf: []LineRange) ReadPage {
    std.debug.assert(line_cap > 0);
    var scan_opts = opts;
    scan_opts.limit = line_cap;
    // Serialized-size enforcement happens after rendering. Disable the row
    // estimate while choosing a candidate so it cannot leave usable budget idle.
    scan_opts.budget = std.math.maxInt(u32);
    var page = sourcePage(text, ranges, scan_opts, buf);
    page.limit = opts.limit;
    page.budget = if (opts.budget == 0) default_read_budget else opts.budget;
    return page;
}

fn renderSourcePageBuffered(
    aw: *std.Io.Writer.Allocating,
    path: []const u8,
    text: []const u8,
    ranges: []const LineRange,
    page: ReadPage,
    format: OutputFormat,
) !bool {
    aw.clearRetainingCapacity();
    if (format == .json) return json_out.sourceLines(&aw.writer, path, text, ranges, page);
    return printNumbered(&aw.writer, path, text, ranges, page);
}

/// Render to a temporary buffer before committing any bytes. This lets `read`
/// enforce its byte budget over the actual serialized text/JSON (including JSON
/// escaping and continuation metadata), then reduce the line page and re-render
/// without ever leaking a partial or invalid result.
fn renderBoundedSourcePage(
    w: *Writer,
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    ranges: []const LineRange,
    opts: Options,
) !bool {
    const budget = if (opts.budget == 0) default_read_budget else opts.budget;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &bytes);
    defer aw.deinit();
    var page_ranges: [max_read_ranges]LineRange = undefined;

    var page = sourcePageForLineCap(text, ranges, opts, opts.limit, &page_ranges);
    var found = try renderSourcePageBuffered(&aw, path, text, ranges, page, opts.format);
    if (aw.written().len <= budget) {
        try w.writeAll(aw.written());
        return found;
    }

    // Find the largest whole-line prefix whose final encoding fits. The page is
    // monotonic in line count, so a bounded binary search avoids one render per
    // source line while retaining the most useful prefix.
    var best: u32 = 0;
    var low: u32 = 1;
    var high = if (page.shown == 0) @as(u32, 0) else page.shown - 1;
    while (low <= high and high != 0) {
        const middle = low + (high - low) / 2;
        page = sourcePageForLineCap(text, ranges, opts, middle, &page_ranges);
        _ = try renderSourcePageBuffered(&aw, path, text, ranges, page, opts.format);
        if (aw.written().len <= budget) {
            best = middle;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }
    if (best != 0) {
        page = sourcePageForLineCap(text, ranges, opts, best, &page_ranges);
        found = try renderSourcePageBuffered(&aw, path, text, ranges, page, opts.format);
        std.debug.assert(aw.written().len <= budget);
        try w.writeAll(aw.written());
        return found;
    }

    // An individual source row or even the requested path metadata can be larger
    // than the budget. Return a valid, bounded diagnostic; the unchanged cursor
    // tells the caller exactly where a retry with a larger budget resumes.
    try renderReadBudgetTooSmall(w, opts.format, budget, opts.after, aw.written().len);
    return false;
}

fn renderReadBudgetTooSmall(w: *Writer, format: OutputFormat, budget: u32, after: u32, minimum: usize) !void {
    var buf: [256]u8 = undefined;
    const full = if (format == .json)
        try std.fmt.bufPrint(&buf, "{{\"error\":\"budget_too_small\",\"message\":\"budget cannot fit one complete source row\",\"minimum\":{d},\"next\":\"v1:{d}\"}}\n", .{ minimum, after })
    else
        try std.fmt.bufPrint(&buf, "(read error [budget_too_small]: budget cannot fit one complete source row; minimum {d} bytes; retry --budget {d} --after v1:{d})\n", .{ minimum, minimum, after });
    if (full.len <= budget) {
        try w.writeAll(full);
        return;
    }
    const fallbacks: []const []const u8 = if (format == .json)
        &.{ "{\"error\":\"budget_too_small\"}\n", "{}\n", "{}", "0" }
    else
        &.{ "read budget too small\n", "budget\n", "\n" };
    for (fallbacks) |fallback| {
        if (fallback.len <= budget) {
            try w.writeAll(fallback);
            return;
        }
    }
    // A one-byte text budget cannot carry a useful diagnostic; emitting nothing
    // is still preferable to violating the caller's hard ceiling.
}

/// The in-memory text of an indexed file matching `path` (exact, else a unique
/// suffix match), or null if not indexed / ambiguous — the caller falls back to
/// a disk read.
fn indexedText(idx: *const Index, path: []const u8) ?[]const u8 {
    for (idx.graph.files) |file| {
        if (std.mem.eql(u8, file.path, path)) return file.text;
    }
    var match: ?[]const u8 = null;
    for (idx.graph.files) |file| {
        if (std.mem.endsWith(u8, file.path, path) and
            (file.path.len == path.len or file.path[file.path.len - path.len - 1] == '/'))
        {
            if (match != null) return null; // ambiguous suffix
            match = file.text;
        }
    }
    return match;
}

pub const LineRange = struct { lo: usize, hi: usize };

/// Parse a `read` range suffix: `A-B`, `A-` (A to end), or `A` (single line).
fn parseLineRange(s: []const u8) ReadSpecError!LineRange {
    if (s.len == 0) return error.MalformedRange;
    if (std.mem.indexOfScalar(u8, s, '-')) |d| {
        if (d == 0) return error.MalformedRange;
        const lo = std.fmt.parseInt(usize, s[0..d], 10) catch return error.MalformedRange;
        const rest = s[d + 1 ..];
        const hi = if (rest.len == 0) std.math.maxInt(usize) else std.fmt.parseInt(usize, rest, 10) catch return error.MalformedRange;
        if (lo == 0 or hi == 0) return error.MalformedRange;
        if (hi < lo) return error.DescendingRange;
        return .{ .lo = lo, .hi = hi };
    }
    const only = std.fmt.parseInt(usize, s, 10) catch return error.MalformedRange;
    if (only == 0) return error.MalformedRange;
    return .{ .lo = only, .hi = only };
}

/// Parse `path[:ranges]` without confusing an ordinary colon-bearing filename
/// (`notes:archive`) with a line request. A suffix beginning with a digit, `-`,
/// or `,` declares range intent; once declared, validation failures stay typed.
fn parseReadSpec(spec: []const u8, buf: []LineRange) ReadSpecError!ReadSpec {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse
        return .{ .path = spec, .ranges = &.{} };
    const suffix = spec[colon + 1 ..];
    if (!looksLikeRangeSuffix(suffix)) return .{ .path = spec, .ranges = &.{} };
    const parsed = try parseRanges(suffix, buf);
    return .{ .path = spec[0..colon], .ranges = normalizeRanges(parsed) };
}

fn looksLikeRangeSuffix(s: []const u8) bool {
    if (s.len == 0) return false;
    return std.ascii.isDigit(s[0]) or s[0] == '-' or s[0] == ',';
}

fn readRangeSuffix(spec: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return spec;
    return spec[colon + 1 ..];
}

/// Parse a comma-separated list (`A-B,C-D,E`) into `buf` with deterministic
/// failure classes. The caller normalizes the successfully parsed list in place.
fn parseRanges(s: []const u8, buf: []LineRange) ReadSpecError![]LineRange {
    if (s.len == 0) return error.MalformedRange;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (n >= buf.len) return error.TooManyRanges;
        buf[n] = try parseLineRange(part);
        n += 1;
    }
    if (n == 0) return error.MalformedRange;
    return buf[0..n];
}

fn lineRangeLessThan(_: void, a: LineRange, b: LineRange) bool {
    if (a.lo != b.lo) return a.lo < b.lo;
    return a.hi < b.hi;
}

/// Sort and coalesce overlapping or adjacent spans in place. Besides producing
/// compact metadata, this guarantees that neither renderer can duplicate a line.
fn normalizeRanges(ranges: []LineRange) []const LineRange {
    if (ranges.len < 2) return ranges;
    std.mem.sort(LineRange, ranges, {}, lineRangeLessThan);
    var out: usize = 1;
    for (ranges[1..]) |range| {
        const previous = &ranges[out - 1];
        const adjacent = previous.hi != std.math.maxInt(usize) and range.lo == previous.hi + 1;
        if (range.lo <= previous.hi or adjacent) {
            previous.hi = @max(previous.hi, range.hi);
        } else {
            ranges[out] = range;
            out += 1;
        }
    }
    return ranges[0..out];
}

fn readSpecErrorCode(err: ReadSpecError) []const u8 {
    return switch (err) {
        error.MalformedRange => "malformed_range",
        error.DescendingRange => "descending_range",
        error.TooManyRanges => "too_many_ranges",
    };
}

fn readSpecErrorMessage(err: ReadSpecError) []const u8 {
    return switch (err) {
        error.MalformedRange => "expected positive line ranges A, A-B, or A-",
        error.DescendingRange => "range end must not precede its start",
        error.TooManyRanges => "at most 16 source ranges are allowed",
    };
}

/// The number of lines in `text` (a trailing newline is not counted as a line).
pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var total: usize = 1;
    for (text) |ch| {
        if (ch == '\n') total += 1;
    }
    if (text[text.len - 1] == '\n') total -= 1;
    return total;
}

/// Emit `text`'s lines in `[lo, hi]` as `N\t<line>` (single pass from the top).
/// Returns the number of lines emitted.
fn emitRange(w: *Writer, text: []const u8, lo: usize, hi: usize) !usize {
    var start: usize = 0;
    var line_no: usize = 1;
    var emitted: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (line_no >= lo and line_no <= hi) {
            try w.print("{d}\t{s}\n", .{ line_no, text[start..nl] });
            emitted += 1;
        }
        if (line_no >= hi) break;
        start = nl + 1;
        line_no += 1;
    }
    return emitted;
}

fn decimalDigits(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits;
}

fn sourceLineSelected(line: usize, ranges: []const LineRange) bool {
    if (ranges.len == 0) return true;
    for (ranges) |range| {
        if (line < range.lo) return false;
        if (line <= range.hi) return true;
    }
    return false;
}

/// Select the first safe page from a whole-file or explicit-range request.
/// `limit` is exact. The source byte budget uses numbered text-row estimates and
/// always retains one useful row, matching the traversal budget convention.
pub fn sourcePage(text: []const u8, ranges: []const LineRange, opts: Options, buf: []LineRange) ReadPage {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(buf.len >= max_read_ranges);
    const budget = if (opts.budget == 0) default_read_budget else opts.budget;
    var start: usize = 0;
    var line: usize = 1;
    var selected: u32 = 0;
    var shown: u32 = 0;
    var estimated: u32 = 0;
    var page_ranges: usize = 0;
    var page_full = false;
    while (start < text.len) : (line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (sourceLineSelected(line, ranges)) {
            const ordinal = selected;
            selected +|= 1;
            if (ordinal >= opts.after and !page_full and shown < opts.limit) {
                const raw_estimate = text[start..newline].len + decimalDigits(line) + 2;
                const row_estimate: u32 = @intCast(@min(raw_estimate, std.math.maxInt(u32)));
                if (shown == 0 or estimated +| row_estimate <= budget) {
                    if (page_ranges != 0 and buf[page_ranges - 1].hi != std.math.maxInt(usize) and line == buf[page_ranges - 1].hi + 1) {
                        buf[page_ranges - 1].hi = line;
                    } else {
                        std.debug.assert(page_ranges < buf.len);
                        buf[page_ranges] = .{ .lo = line, .hi = line };
                        page_ranges += 1;
                    }
                    shown +|= 1;
                    estimated +|= row_estimate;
                    if (shown == opts.limit) page_full = true;
                } else {
                    // Do not skip an oversized row and take a later, shorter one:
                    // the cursor is a selected-row ordinal and pages are prefixes.
                    page_full = true;
                }
            }
        }
        start = newline + 1;
    }
    const consumed = @as(u64, opts.after) + shown;
    const truncated = consumed < selected;
    return .{
        .ranges = buf[0..page_ranges],
        .offset = opts.after,
        .limit = opts.limit,
        .budget = budget,
        .selected = selected,
        .shown = shown,
        .estimated_bytes = estimated,
        .truncated = truncated,
        .next = if (truncated) @intCast(consumed) else null,
    };
}

/// Emit `text` for `ranges` (empty = whole file) as numbered lines under a header
/// naming the file and line count. Disjoint ranges are separated by a `⋯` gap
/// marker so it's clear lines were skipped between them. Returns whether at
/// least one source line was emitted.
fn printNumbered(w: *Writer, path: []const u8, text: []const u8, ranges: []const LineRange, page: ReadPage) !bool {
    const total = lineCount(text);
    if (ranges.len == 0 or page.truncated or page.offset != 0) {
        try w.print("# {s} ({d} line{s})\n", .{ path, total, if (total == 1) "" else "s" });
    } else if (ranges.len == 1 and ranges[0].hi != std.math.maxInt(usize)) {
        const r = ranges[0];
        try w.print("# {s} (lines {d}-{d} of {d})\n", .{ path, r.lo, @min(r.hi, total), total });
    } else {
        try w.print("# {s} ({d} line{s})\n", .{ path, total, if (total == 1) "" else "s" });
    }
    var prev_hi: usize = 0;
    var emitted: usize = 0;
    for (page.ranges) |r| {
        if (prev_hi != 0 and r.lo > prev_hi + 1) try w.writeAll("  ⋯\n");
        emitted += try emitRange(w, text, r.lo, r.hi);
        prev_hi = @min(r.hi, total);
    }
    if (page.selected == 0) for (ranges) |r| {
        if (r.lo > total) {
            try w.print("(no such line: {d}; file has {d})\n", .{ r.lo, total });
        }
    };
    if (page.truncated) {
        try w.print("# truncated: {d} of {d} selected lines shown (offset {d}); next: --after v1:{d}\n", .{ page.shown, page.selected, page.offset, page.next.? });
    } else if (page.offset != 0) {
        try w.print("# page: {d} selected lines shown at offset {d} of {d}; end of selection\n", .{ page.shown, page.offset, page.selected });
    }
    return emitted > 0;
}

/// Search the *contents of string literals* across every indexed file for
/// `pattern` (substring), printing `path:line: <literal>`. The escape hatch the
/// symbol graph can't cover: URL/route literals, log and error messages, regex
/// sources, config keys, feature-flag names — the text a trial kept dropping to
/// `read`/grep for. Language-agnostic: it re-lexes each file with the shared
/// tokenizer and matches only `.string` tokens, so a hit is never an identifier
/// that merely shares the text (stricter than a raw grep).
/// Returns whether any string literal matched.
pub fn strings(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(pattern.len > 0);
    if (opts.format == .json) return json_out.strings(w, idx, pattern, opts);
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(idx.gpa);
    const is_glob = isGlobPattern(pattern);
    const pat = try wrapStringPattern(idx.gpa, pattern);
    defer if (is_glob) idx.gpa.free(pat);
    var shown: u32 = 0;
    outer: for (idx.graph.files) |file| {
        toks.clearRetainingCapacity();
        lexer.tokenize(idx.gpa, file.text, language.configFor(file.language), &toks) catch continue;
        for (toks.items) |t| {
            if (t.kind != .string) continue;
            const s = t.text(file.text);
            if (!matchesString(pat, is_glob, s)) continue;
            try w.print("{s}:{d}: ", .{ file.path, t.line });
            try render.writeCollapsed(w, s, 200);
            try w.writeByte('\n');
            shown += 1;
            if (shown >= opts.limit) break :outer;
        }
    }
    if (shown == 0) {
        try w.print("(no string literal matching '{s}')\n", .{pattern});
        try skippedNote(w, idx);
    }
    try truncationNote(w, opts, shown);
    return shown > 0;
}

/// Show the definition(s) of `name` (supports `Parent.name`). Returns whether
/// `name` resolved to at least one definition.
pub fn showDef(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.showDef(w, idx, name, opts);
    var buf: [64]SymbolId = undefined;
    const ids = resolveIds(idx, name, &buf);
    if (ids.len == 0) {
        try w.print("(no definition named '{s}')\n", .{name});
        try suggestNear(w, idx, name);
        return false;
    }
    try multiMatchNote(w, name, ids.len, ids.len == buf.len);
    var shown: usize = 0;
    for (ids) |id| {
        const sym = idx.graph.symbols[id];
        if (!visAllowed(sym, opts.visibility)) continue;
        try render.symbol(w, idx, sym, opts.verbosity, 0, true);
        shown += 1;
    }
    if (shown == 0) try w.print("(definition '{s}' hidden by visibility filter)\n", .{name});
    return shown > 0;
}

/// After a not-found, suggest up to 4 near-miss definition names: exact
/// case-insensitive hits first (`context` → `Context`), then case-insensitive
/// substrings, then names within edit distance 2 (`Contxt` → `Context`). Saves
/// the agent a `search` round-trip when the miss was casing or a typo.
fn suggestNear(w: *Writer, idx: *const Index, name: []const u8) !void {
    // Strip pin syntax; suggest on the bare symbol name.
    var nm = name;
    if (std.mem.lastIndexOfScalar(u8, nm, '@')) |at| nm = nm[0..at];
    if (std.mem.lastIndexOfScalar(u8, nm, '.')) |dot| nm = nm[dot + 1 ..];
    if (nm.len < 2 or isGlobPattern(nm)) return;

    // Rank: ci-equal > ci-prefix > ci-substring > edit-distance≤2, and within a
    // tier a SHORTER name wins — `Contex` must suggest `Context`, not the four
    // longest names that happen to contain "contex" (a trial hit exactly that).
    var names: [4][]const u8 = undefined;
    var scores: [4]u8 = .{ 0, 0, 0, 0 };
    for (idx.graph.symbols) |sym| {
        // Imports aren't definitions; test blocks have prose names ("outline
        // lists …") that read as garbage in a did-you-mean list.
        if (sym.kind == .import or sym.kind == .test_case) continue;
        const score: u8 = if (std.ascii.eqlIgnoreCase(sym.name, nm))
            4
        else if (std.ascii.startsWithIgnoreCase(sym.name, nm))
            3
        else if (std.ascii.indexOfIgnoreCase(sym.name, nm) != null)
            2
        else if (withinEditDistance2(nm, sym.name))
            1
        else
            continue;
        // Replace the weakest slot when this hit outranks it; dedupe by name.
        var weakest: usize = 0;
        var dup = false;
        for (0..names.len) |i| {
            if (scores[i] != 0 and std.mem.eql(u8, names[i], sym.name)) {
                dup = true;
                break;
            }
            if (better(scores[weakest], if (scores[weakest] == 0) 0 else names[weakest].len, scores[i], if (scores[i] == 0) 0 else names[i].len))
                weakest = i;
        }
        if (dup) continue;
        if (better(score, sym.name.len, scores[weakest], if (scores[weakest] == 0) 0 else names[weakest].len)) {
            names[weakest] = sym.name;
            scores[weakest] = score;
        }
    }
    // Emit best-first: tier 4 down to 1, shorter names first within a tier
    // (selection sort over 4 slots).
    for (0..names.len) |i| {
        var best = i;
        for (i + 1..names.len) |j| {
            if (better(scores[j], if (scores[j] == 0) 0 else names[j].len, scores[best], if (scores[best] == 0) 0 else names[best].len))
                best = j;
        }
        std.mem.swap(u8, &scores[i], &scores[best]);
        std.mem.swap([]const u8, &names[i], &names[best]);
    }
    var wrote = false;
    for (0..names.len) |i| {
        if (scores[i] == 0) continue;
        try w.writeAll(if (wrote) ", " else "  (did you mean: ");
        try w.print("{s}", .{names[i]});
        wrote = true;
    }
    if (wrote) try w.writeAll("?)\n");
}

/// Suggestion ordering: higher tier wins; within a tier a shorter name wins
/// (closer to what was typed). An empty slot (score 0) always loses.
fn better(score_a: u8, len_a: usize, score_b: u8, len_b: usize) bool {
    if (score_a != score_b) return score_a > score_b;
    if (score_a == 0) return false;
    return len_a < len_b;
}

/// Bounded Levenshtein: true when `a` and `b` are within edit distance 2.
fn withinEditDistance2(a: []const u8, b: []const u8) bool {
    if (a.len > b.len) return withinEditDistance2(b, a);
    if (b.len - a.len > 2) return false;
    if (b.len > 64) return false; // long names: substring checks above suffice
    // Two-row DP with a band; sizes are tiny so brute force is fine.
    var prev: [65]u8 = undefined;
    var cur: [65]u8 = undefined;
    for (0..a.len + 1) |j| prev[j] = @intCast(@min(j, 3));
    for (1..b.len + 1) |i| {
        cur[0] = @intCast(@min(i, 3));
        var row_min: u8 = cur[0];
        for (1..a.len + 1) |j| {
            const cost: u8 = if (a[j - 1] == b[i - 1]) 0 else 1;
            var v = prev[j - 1] + cost; // substitute
            v = @min(v, prev[j] + 1); // delete
            v = @min(v, cur[j - 1] + 1); // insert
            cur[j] = @min(v, 3);
            row_min = @min(row_min, cur[j]);
        }
        if (row_min > 2) return false;
        prev = cur;
    }
    return prev[a.len] <= 2;
}

/// One-line banner when a name resolves to several definitions, so two
/// concatenated bodies are never misread as one and the pin syntax is
/// discoverable at the moment it's needed (a trial misread exactly this).
fn multiMatchNote(w: *Writer, name: []const u8, n: usize, truncated: bool) !void {
    if (n <= 1) return;
    try w.print("({d}{s} definitions match '{s}' — pin one with Parent.name or name@path)\n", .{
        n, if (truncated) "+" else "", name,
    });
}

pub fn compactEnabled(opts: Options) bool {
    return opts.max_nodes != 0 or opts.budget != 0;
}

const EdgePriority = struct { idx: *const Index };

pub fn orderedRefs(gpa: std.mem.Allocator, idx: *const Index, refs: []const model.Reference) ![]model.Reference {
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    std.debug.assert(refs.len <= std.math.maxInt(u32));
    const ordered = try gpa.dupe(model.Reference, refs);
    std.sort.block(model.Reference, ordered, EdgePriority{ .idx = idx }, refPriorityLessThan);
    return ordered;
}

fn refPriorityLessThan(ctx: EdgePriority, a: model.Reference, b: model.Reference) bool {
    const a_resolved = a.target != invalid;
    const b_resolved = b.target != invalid;
    if (a_resolved != b_resolved) return a_resolved;
    if (a.exact != b.exact) return a.exact;
    const a_fan = if (a_resolved) ctx.idx.callersOf(a.target).len else 0;
    const b_fan = if (b_resolved) ctx.idx.callersOf(b.target).len else 0;
    if (a_fan != b_fan) return a_fan > b_fan;
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn orderedCallers(gpa: std.mem.Allocator, idx: *const Index, callers: []const SymbolId) ![]SymbolId {
    std.debug.assert(callers.len <= idx.graph.symbols.len);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const ordered = try gpa.dupe(SymbolId, callers);
    std.sort.block(SymbolId, ordered, idx, callerPriorityLessThan);
    return ordered;
}

fn callerPriorityLessThan(idx: *const Index, a: SymbolId, b: SymbolId) bool {
    const a_fan = idx.callersOf(a).len;
    const b_fan = idx.callersOf(b).len;
    if (a_fan != b_fan) return a_fan > b_fan;
    return a < b;
}

const WalkBudget = struct {
    nodes: u32 = 0,
    estimated_bytes: u32 = 0,
    pruned: u32 = 0,

    fn take(self: *WalkBudget, idx: *const Index, id: SymbolId, opts: Options) bool {
        std.debug.assert(id < idx.graph.symbols.len);
        std.debug.assert(opts.limit > 0);
        const sym = idx.graph.symbols[id];
        const estimate: u32 = @intCast(@min(@as(usize, std.math.maxInt(u32)), 48 + sym.name.len + idx.graph.files[sym.file].path.len));
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

/// Walk the call graph from `name`. `incoming` selects callers vs callees.
/// Returns whether `name` resolved to at least one symbol.
pub fn walk(w: *Writer, idx: *const Index, name: []const u8, incoming: bool, opts: Options) !bool {
    if (opts.format == .json) return json_out.walk(w, idx, name, incoming, opts);
    var buf: [64]SymbolId = undefined;
    const ids = resolveIds(idx, name, &buf);
    if (ids.len == 0) {
        try w.print("(no symbol named '{s}')\n", .{name});
        try suggestNear(w, idx, name);
        try skippedNote(w, idx);
        return false;
    }
    try multiMatchNote(w, name, ids.len, ids.len == buf.len);
    var impl_graph: ?impls_mod.Graph = if (opts.impls) try impls_mod.build(idx.gpa, idx) else null;
    defer if (impl_graph) |*graph| graph.deinit();
    var visited = std.AutoHashMap(SymbolId, void).init(idx.gpa);
    defer visited.deinit();
    var heuristic: usize = 0;
    var budget: WalkBudget = .{};
    for (ids) |id| {
        visited.clearRetainingCapacity();
        try walkNode(w, idx, if (impl_graph) |*g| g else null, id, incoming, opts, 0, 0, 0, 1, &.{}, true, false, &visited, &heuristic, &budget);
    }
    // If any ambiguous name-match (`?`) edges were shown, tell the agent how to
    // drop them rather than making it discover `-s` on its own. Only when they
    // are actually present and not already filtered.
    if (heuristic > 0 and !opts.strict) {
        try w.print("({d} heuristic `?` edge{s} shown — re-run with -s to drop them)\n", .{
            heuristic, if (heuristic == 1) "" else "s",
        });
    }
    if (budget.pruned != 0) try w.print("… {} branch{s} elided (--budget/--max-nodes; {} nodes shown)\n", .{ budget.pruned, if (budget.pruned == 1) "" else "es", budget.nodes });
    return budget.nodes != 0;
}

fn walkNode(
    w: *Writer,
    idx: *const Index,
    impl_graph: ?*const impls_mod.Graph,
    id: SymbolId,
    incoming: bool,
    opts: Options,
    indent: usize,
    /// Edges followed from the root, tracked apart from `indent` so a view that
    /// starts its children indented (neighbors) still honours `-d` from 1.
    depth: usize,
    site: u32,
    sites: u32,
    lines: []const u32,
    exact: bool,
    implementation_edge: bool,
    visited: *std.AutoHashMap(SymbolId, void),
    heuristic: *usize,
    budget: *WalkBudget,
) anyerror!void {
    if (!budget.take(idx, id, opts)) return;
    const v = if (opts.summary) .names else if (indent == 0) opts.verbosity else headerVerbosity(opts.verbosity);
    if (implementation_edge) {
        try renderImplSymbol(w, idx, idx.graph.symbols[id], v, indent, exact);
    } else {
        try render.symbolSite(w, idx, idx.graph.symbols[id], v, indent, true, site, sites, lines, exact);
    }
    if (indent > 0 and !exact) heuristic.* += 1;
    if (depth >= opts.depth) {
        if (impl_graph) |graph| try renderImplLeaves(w, idx, graph, id, incoming, opts, indent, visited, heuristic, budget);
        return;
    }
    if ((try visited.getOrPut(id)).found_existing) {
        try indentLine(w, indent + 1, "… (recursion)");
        return;
    }
    if (incoming) {
        try walkCallers(w, idx, impl_graph, id, opts, indent, depth, visited, heuristic, budget);
    } else {
        try walkCallees(w, idx, impl_graph, id, opts, indent, depth, visited, heuristic, budget);
    }
}

/// A callee edge that is a plain *data read* of a value symbol (a module `var`,
/// a `const`, a `field`) rather than a call or a type dependency. These are noise
/// in a "what does this do / blast radius" callee tree — `calls`/`neighbors` hide
/// them by default and surface them only with `--refs`. Reading a *function* (a
/// callback passed by name) is a real dependency and stays. The graph itself is
/// unchanged — `callers`/`hot`/`unused` still count every resolved reference.
pub fn isDataReadEdge(idx: *const Index, ref: model.Reference) bool {
    if (ref.kind != .read or ref.write) return false;
    return switch (idx.graph.symbols[ref.target].kind) {
        .variable, .constant, .field => true,
        else => false,
    };
}

fn walkCallees(
    w: *Writer,
    idx: *const Index,
    impl_graph: ?*const impls_mod.Graph,
    id: SymbolId,
    opts: Options,
    indent: usize,
    depth: usize,
    visited: *std.AutoHashMap(SymbolId, void),
    heuristic: *usize,
    budget: *WalkBudget,
) !void {
    const sym = idx.graph.symbols[id];
    var externals: std.ArrayList(u8) = .empty;
    defer externals.deinit(idx.gpa);
    var ordered_refs: ?[]model.Reference = null;
    defer if (ordered_refs) |refs| idx.gpa.free(refs);
    if (compactEnabled(opts)) ordered_refs = try orderedRefs(idx.gpa, idx, sym.refs);
    const refs = ordered_refs orelse sym.refs;
    for (refs) |ref| {
        // Follow every *resolved* edge (call, use, type-use). Bare data reads of
        // a var/const/field are dependency noise, hidden unless `--refs` asks for
        // them. Only unresolved *calls* are surfaced as externals; unresolved
        // reads of stdlib/locals would be noise.
        if (ref.target != invalid and (!opts.strict or ref.exact)) {
            if (!opts.refs and isDataReadEdge(idx, ref)) continue;
            // The edge (this symbol → callee) lives at ref.line in this file.
            try walkNode(w, idx, impl_graph, ref.target, false, opts, indent + 1, depth + 1, ref.line, ref.count, ref.lines, ref.exact, false, visited, heuristic, budget);
        } else if (ref.target == invalid and (ref.kind == .call or ref.kind == .route_call)) {
            if (externals.items.len != 0) try externals.appendSlice(idx.gpa, ", ");
            try externals.appendSlice(idx.gpa, ref.name);
        }
    }
    if (impl_graph) |graph| {
        for (graph.edges) |edge| {
            if (edge.port_method != id or (opts.strict and !edge.exact)) continue;
            try walkNode(w, idx, impl_graph, edge.implementation_method, false, opts, indent + 1, depth + 1, 0, 1, &.{}, edge.exact, true, visited, heuristic, budget);
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
    impl_graph: ?*const impls_mod.Graph,
    id: SymbolId,
    opts: Options,
    indent: usize,
    depth: usize,
    visited: *std.AutoHashMap(SymbolId, void),
    heuristic: *usize,
    budget: *WalkBudget,
) !void {
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    var ordered_callers: ?[]SymbolId = null;
    defer if (ordered_callers) |callers_slice| idx.gpa.free(callers_slice);
    if (compactEnabled(opts)) ordered_callers = try orderedCallers(idx.gpa, idx, idx.callersOf(id));
    const callers_slice = ordered_callers orelse idx.callersOf(id);
    for (callers_slice) |cid| {
        if (opts.strict and !hasExactEdge(idx, cid, id)) continue;
        // `--tests only` keeps only test callers ("which tests exercise this");
        // `--no-tests` keeps only production callers.
        if (!inTestScope(opts.tests, isTestSymbol(idx, idx.graph.symbols[cid]))) continue;
        // The edge (caller → this symbol) lives at its call site(s) in the caller.
        try callSiteLines(idx, cid, id, &lines);
        try walkNode(w, idx, impl_graph, cid, true, opts, indent + 1, depth + 1, callSiteLine(idx, cid, id), callSiteCount(idx, cid, id), lines.items, hasExactEdge(idx, cid, id), false, visited, heuristic, budget);
    }
    if (impl_graph) |graph| {
        for (graph.edges) |edge| {
            if (opts.strict and !edge.exact) continue;
            if (edge.port_method == id) {
                try walkNode(w, idx, impl_graph, edge.implementation_method, true, opts, indent + 1, depth + 1, 0, 1, &.{}, edge.exact, true, visited, heuristic, budget);
            } else if (edge.implementation_method == id) {
                try walkNode(w, idx, impl_graph, edge.port_method, true, opts, indent + 1, depth + 1, 0, 1, &.{}, edge.exact, true, visited, heuristic, budget);
            }
        }
    }
}

fn renderImplSymbol(w: *Writer, idx: *const Index, sym: model.Symbol, v: render.Verbosity, indent: usize, exact: bool) !void {
    std.debug.assert(sym.kind == .method);
    std.debug.assert(indent > 0);
    var i: usize = 0;
    while (i < indent) : (i += 1) try w.writeAll("  ");
    try w.writeAll("⇒impl ");
    try render.symbol(w, idx, sym, v, 0, true);
    if (!exact) {
        i = 0;
        while (i < indent + 1) : (i += 1) try w.writeAll("  ");
        try w.writeAll("? structural match\n");
    }
}

fn renderImplLeaves(
    w: *Writer,
    idx: *const Index,
    graph: *const impls_mod.Graph,
    id: SymbolId,
    incoming: bool,
    opts: Options,
    indent: usize,
    visited: *std.AutoHashMap(SymbolId, void),
    heuristic: *usize,
    budget: *WalkBudget,
) !void {
    _ = visited;
    for (graph.edges) |edge| {
        if (opts.strict and !edge.exact) continue;
        var target: SymbolId = invalid;
        if (edge.port_method == id) target = edge.implementation_method;
        if (incoming and edge.implementation_method == id) target = edge.port_method;
        if (target == invalid or !budget.take(idx, target, opts)) continue;
        const v: render.Verbosity = if (opts.summary) .names else headerVerbosity(opts.verbosity);
        try renderImplSymbol(w, idx, idx.graph.symbols[target], v, indent + 1, edge.exact);
        if (!edge.exact) heuristic.* += 1;
    }
}

/// True when `from` references `to` via a high-confidence (exact) edge.
pub fn hasExactEdge(idx: *const Index, from: SymbolId, to: SymbolId) bool {
    for (idx.graph.symbols[from].refs) |ref| {
        if (ref.target == to and ref.exact) return true;
    }
    return false;
}

pub const RankedSym = struct { id: SymbolId, metric: u32 };
const RankContext = struct { idx: *const Index, sort: SortKey };

fn rankedDefinitions(w: *Writer, idx: *const Index, path_filter: []const u8, pattern: []const u8, opts: Options, outline_mode: bool) !bool {
    std.debug.assert(opts.sort != .default);
    std.debug.assert(outline_mode or pattern.len > 0);
    const ranked = try collectRankedDefinitions(idx, path_filter, pattern, opts, outline_mode);
    defer idx.gpa.free(ranked);
    if (opts.format == .jsonl) return json_out.rankedDefinitionsJsonl(w, idx, ranked, opts);
    if (opts.format == .json) return json_out.rankedDefinitions(w, idx, ranked, opts);
    const shown: usize = @min(ranked.len, opts.limit);
    for (ranked[0..shown]) |entry| {
        try render.symbol(w, idx, idx.graph.symbols[entry.id], opts.verbosity, 0, true);
        try printRankBadge(w, opts.sort, entry.metric);
    }
    if (shown == 0) {
        try w.writeAll("(no matching symbols)\n");
        return false;
    }
    if (ranked.len > shown) try w.print("… (stopped at -l {d}; {d} more)\n", .{ opts.limit, ranked.len - shown });
    return true;
}

pub fn collectRankedDefinitions(idx: *const Index, path_filter: []const u8, pattern: []const u8, opts: Options, outline_mode: bool) ![]RankedSym {
    std.debug.assert(opts.sort != .default);
    std.debug.assert(outline_mode or pattern.len > 0);
    var list: std.ArrayList(RankedSym) = .empty;
    errdefer list.deinit(idx.gpa);
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (outline_mode and !sym.kind.isTopLevelInteresting() and sym.parent == invalid) continue;
        const path = idx.graph.files[sym.file].path;
        if (path_filter.len != 0 and !matchesFilter(path, path_filter)) continue;
        if (opts.no_recurse and !inDirNonRecursive(path, path_filter)) continue;
        if (!kindAllowed(sym.kind, opts.kinds) or !visAllowed(sym, opts.visibility)) continue;
        if (!inTestScope(opts.tests, isTestSymbol(idx, sym))) continue;
        if (pattern.len != 0 and !(if (opts.exact) std.mem.eql(u8, sym.name, pattern) else matchesName(pattern, sym.name))) continue;
        try list.append(idx.gpa, .{ .id = sym.id, .metric = rankMetric(idx, sym, opts.sort, opts.tests) });
    }
    const items = try list.toOwnedSlice(idx.gpa);
    std.mem.sort(RankedSym, items, RankContext{ .idx = idx, .sort = opts.sort }, rankedLessThan);
    return items;
}

fn rankMetric(idx: *const Index, sym: model.Symbol, sort: SortKey, scope: TestScope) u32 {
    return switch (sort) {
        .span => sym.endLine(idx.graph.files[sym.file].text) - sym.line + 1,
        .callers, .fan_in_exact => exactCallerCount(idx, sym.id, scope),
        .callees, .fan_out_exact => fanOutExact(sym),
        .fan_in => scopedCallerCount(idx, sym.id, scope),
        .fan_out => fanOut(sym),
        else => 0,
    };
}

fn exactCallerCount(idx: *const Index, target: SymbolId, scope: TestScope) u32 {
    std.debug.assert(target < idx.graph.symbols.len);
    var count: u32 = 0;
    for (idx.graph.symbols) |owner| {
        if (!inTestScope(scope, isTestSymbol(idx, owner))) continue;
        for (owner.refs) |ref| {
            if (ref.target == target and ref.exact) count += 1;
        }
    }
    return count;
}

fn rankedLessThan(ctx: RankContext, a: RankedSym, b: RankedSym) bool {
    const sa = ctx.idx.graph.symbols[a.id];
    const sb = ctx.idx.graph.symbols[b.id];
    if (ctx.sort == .name) {
        const order = std.mem.order(u8, sa.name, sb.name);
        if (order != .eq) return order == .lt;
    } else if (ctx.sort != .line and a.metric != b.metric) return a.metric > b.metric;
    const path_order = std.mem.order(u8, ctx.idx.graph.files[sa.file].path, ctx.idx.graph.files[sb.file].path);
    if (path_order != .eq) return path_order == .lt;
    if (sa.line != sb.line) return sa.line < sb.line;
    return sa.id < sb.id;
}

fn printRankBadge(w: *Writer, sort: SortKey, metric: u32) !void {
    switch (sort) {
        .span => try w.print("    ⟨{d} ln⟩\n", .{metric}),
        .callers => try w.print("    ⟨←{d}⟩\n", .{metric}),
        .callees => try w.print("    ⟨→{d}⟩\n", .{metric}),
        else => {},
    }
}

/// Substring search over symbol names; prints matches like `def`. With
/// `--refs`, searches *use sites* (references) instead — a resolved-graph grep
/// that answers "where is this used", which name-only search cannot.
/// Returns whether any symbol (or, with `--refs`, any reference) matched.
pub fn search(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(pattern.len > 0);
    const effective = compactOptions(opts, 96);
    if (effective.refs) return searchRefs(w, idx, pattern, effective);
    if (effective.duplicates) return collisions(w, idx, pattern, effective);
    if (effective.sort != .default and effective.sort != .line) return rankedDefinitions(w, idx, "", pattern, effective, false);
    if (effective.format == .jsonl) return json_out.searchJsonl(w, idx, pattern, effective);
    if (effective.format == .json) return json_out.search(w, idx, pattern, effective);
    var shown: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (!kindAllowed(sym.kind, effective.kinds)) continue;
        if (!visAllowed(sym, effective.visibility)) continue;
        if (!inTestScope(effective.tests, isTestSymbol(idx, sym))) continue;
        if (effective.exact) {
            if (!std.mem.eql(u8, sym.name, pattern)) continue;
        } else if (!matchesName(pattern, sym.name)) continue;
        try render.symbol(w, idx, sym, effective.verbosity, 0, true);
        shown += 1;
        if (shown >= effective.limit) break;
    }
    if (shown == 0) {
        try w.print("(no symbol matching '{s}')\n", .{pattern});
        try suggestNear(w, idx, pattern);
        try kindHint(w, idx, "", effective);
        // A slash/space never occurs in a symbol name — the query is literal
        // text (a route path, a log message). Point at the right verb.
        if (std.mem.indexOfAny(u8, pattern, "/ ") != null) {
            try w.print("  (symbol names never contain '/' or spaces — try `strings '{s}'` for literal text)\n", .{pattern});
        }
        try skippedNote(w, idx);
    }
    try truncationNote(w, effective, shown);
    return shown > 0;
}

/// When a `-k` filter produced zero results, list the kinds that DO exist in
/// scope — so `-k struct` on a Python repo says "kinds here: class, fn,
/// method…" instead of a bare miss (a trial burned a call on exactly that).
pub fn collisions(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    if (opts.format == .json) return json_out.collisions(w, idx, pattern, opts);
    const ids = try collectCollisionSymbols(idx, pattern, opts);
    defer idx.gpa.free(ids);
    var groups: u32 = 0;
    var i: usize = 0;
    while (i < ids.len and groups < opts.limit) {
        var end = i + 1;
        const name = idx.graph.symbols[ids[i]].name;
        while (end < ids.len and std.mem.eql(u8, idx.graph.symbols[ids[end]].name, name)) end += 1;
        if (end - i > 1) {
            groups += 1;
            try w.print("# {s} ×{d}\n", .{ name, end - i });
            for (ids[i..end]) |id| try render.symbol(w, idx, idx.graph.symbols[id], opts.verbosity, 1, true);
        }
        i = end;
    }
    if (groups == 0) {
        try w.writeAll("(no symbol-name collisions)\n");
        return false;
    }
    return true;
}

pub fn collectCollisionSymbols(idx: *const Index, pattern: []const u8, opts: Options) ![]SymbolId {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var list: std.ArrayList(SymbolId) = .empty;
    errdefer list.deinit(idx.gpa);
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import or sym.kind == .route_mount or (!opts.collision_members and sym.parent != invalid)) continue;
        if (!kindAllowed(sym.kind, opts.kinds) or !visAllowed(sym, opts.visibility)) continue;
        if (!inTestScope(opts.tests, isTestSymbol(idx, sym))) continue;
        if (pattern.len != 0 and !matchesName(pattern, sym.name)) continue;
        try list.append(idx.gpa, sym.id);
    }
    const ids = try list.toOwnedSlice(idx.gpa);
    std.mem.sort(SymbolId, ids, idx, collisionLessThan);
    return ids;
}

fn collisionLessThan(idx: *const Index, a: SymbolId, b: SymbolId) bool {
    const sa = idx.graph.symbols[a];
    const sb = idx.graph.symbols[b];
    const name_order = std.mem.order(u8, sa.name, sb.name);
    if (name_order != .eq) return name_order == .lt;
    const path_order = std.mem.order(u8, idx.graph.files[sa.file].path, idx.graph.files[sb.file].path);
    if (path_order != .eq) return path_order == .lt;
    if (sa.line != sb.line) return sa.line < sb.line;
    return a < b;
}

fn kindHint(w: *Writer, idx: *const Index, path_filter: []const u8, opts: Options) !void {
    if (opts.kinds.len == 0) return;
    var present = std.StaticBitSet(@typeInfo(model.SymbolKind).@"enum".fields.len).initEmpty();
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import or sym.kind == .unknown) continue;
        if (!matchesFilter(idx.graph.files[sym.file].path, path_filter)) continue;
        present.set(@intFromEnum(sym.kind));
    }
    if (present.count() == 0) return;
    try w.print("  (no '{s}' here — kinds present: ", .{opts.kinds});
    var first = true;
    inline for (@typeInfo(model.SymbolKind).@"enum".fields) |f| {
        const k: model.SymbolKind = @enumFromInt(f.value);
        if (present.isSet(f.value)) {
            if (!first) try w.writeAll(", ");
            try w.writeAll(k.tag());
            first = false;
        }
    }
    try w.writeAll(")\n");
}

/// When `outline <arg>` matches no file but `<arg>` names a symbol, say where
/// it lives — the "outline takes a path" trap costs a call otherwise.
fn outlinePathHint(w: *Writer, idx: *const Index, path_filter: []const u8) !void {
    if (path_filter.len == 0 or isGlobPattern(path_filter)) return;
    const ids = idx.lookup(path_filter);
    if (ids.len == 0) return;
    const sym = idx.graph.symbols[ids[0]];
    try w.print("  (outline takes a path; '{s}' is a symbol — try `def {s}` or `outline {s}`)\n", .{
        path_filter, path_filter, idx.graph.files[sym.file].path,
    });
}

/// A `search --refs` query. A bare `name` substring-matches any reference; a
/// dotted `recv.name` pins member-access reads (`self.rows`, `Table.rows`) by
/// exact name on the given receiver, and a leading-dot `.name` matches that
/// attribute on *any* receiver — the way to enumerate every read of a field.
pub const RefPattern = struct {
    /// Receiver to match: null when the pattern has no dot (bare name);
    /// "" matches any receiver (leading-dot form); else an exact receiver.
    qualifier: ?[]const u8,
    name: []const u8,
    /// `--exact`: the bare-name form must equal the pattern, not contain it.
    exact: bool = false,

    pub fn parse(pattern: []const u8) RefPattern {
        if (std.mem.lastIndexOfScalar(u8, pattern, '.')) |dot| {
            return .{ .qualifier = pattern[0..dot], .name = pattern[dot + 1 ..] };
        }
        return .{ .qualifier = null, .name = pattern };
    }

    /// Whether `ref` matches. Bare patterns substring-match the name (glob when
    /// they carry a `*`); qualified patterns require a member access (non-empty
    /// `ref.qualifier`), an exact-or-glob receiver match when one was given, and
    /// an exact-or-glob name (empty name matches every attribute of that
    /// receiver).
    pub fn matches(self: RefPattern, ref: model.Reference) bool {
        const q = self.qualifier orelse
            return if (self.exact) std.mem.eql(u8, ref.name, self.name) else matchesName(self.name, ref.name);
        if (ref.qualifier.len == 0) return false;
        if (q.len != 0 and !partMatches(q, ref.qualifier)) return false;
        return self.name.len == 0 or partMatches(self.name, ref.name);
    }

    const partMatches = exactOrGlob;
};

pub const RankedRefSite = struct { owner: SymbolId, ref_index: u32, line: u32, metric: u32 };
const RefRankContext = struct { idx: *const Index, sort: SortKey };

fn rankedSearchRefs(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(opts.sort != .default and opts.sort != .line);
    const sites = try collectRankedRefs(idx, pattern, opts);
    defer idx.gpa.free(sites);
    if (opts.format == .jsonl) return json_out.rankedSearchRefsJsonl(w, idx, sites, opts);
    if (opts.format == .json) return json_out.rankedSearchRefs(w, idx, sites, opts);
    const shown: usize = @min(sites.len, opts.limit);
    for (sites[0..shown]) |site| {
        const owner = idx.graph.symbols[site.owner];
        try printRefRow(w, idx, owner, owner.refs[site.ref_index], site.line, opts.verbosity);
        try printRankBadge(w, opts.sort, site.metric);
    }
    if (shown == 0) try w.print("(no reference matching '{s}')\n", .{pattern});
    if (sites.len > shown) try w.print("… (stopped at -l {d}; {d} more)\n", .{ opts.limit, sites.len - shown });
    return shown > 0;
}

pub fn collectRankedRefs(idx: *const Index, pattern: []const u8, opts: Options) ![]RankedRefSite {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(opts.sort != .default and opts.sort != .line);
    var pat = RefPattern.parse(pattern);
    pat.exact = opts.exact;
    var list: std.ArrayList(RankedRefSite) = .empty;
    errdefer list.deinit(idx.gpa);
    for (idx.graph.symbols) |owner| {
        if (!inTestScope(opts.tests, isTestSymbol(idx, owner))) continue;
        for (owner.refs, 0..) |ref, ref_index| {
            if (!pat.matches(ref) or !refSelected(idx, owner, ref, opts)) continue;
            const metric = rankMetric(idx, owner, opts.sort, opts.tests);
            if (ref.lines.len > 1) {
                for (ref.lines) |line| try list.append(idx.gpa, .{ .owner = owner.id, .ref_index = @intCast(ref_index), .line = line, .metric = metric });
            } else try list.append(idx.gpa, .{ .owner = owner.id, .ref_index = @intCast(ref_index), .line = ref.line, .metric = metric });
        }
    }
    const sites = try list.toOwnedSlice(idx.gpa);
    std.mem.sort(RankedRefSite, sites, RefRankContext{ .idx = idx, .sort = opts.sort }, rankedRefLessThan);
    return sites;
}

fn rankedRefLessThan(ctx: RefRankContext, a: RankedRefSite, b: RankedRefSite) bool {
    const ao = ctx.idx.graph.symbols[a.owner];
    const bo = ctx.idx.graph.symbols[b.owner];
    if (ctx.sort == .name) {
        const order = std.mem.order(u8, ao.refs[a.ref_index].name, bo.refs[b.ref_index].name);
        if (order != .eq) return order == .lt;
    } else if (a.metric != b.metric) return a.metric > b.metric;
    const path_order = std.mem.order(u8, ctx.idx.graph.files[ao.file].path, ctx.idx.graph.files[bo.file].path);
    if (path_order != .eq) return path_order == .lt;
    if (a.line != b.line) return a.line < b.line;
    return a.owner < b.owner;
}

/// List every reference (use site) whose name contains `pattern`, grouped by the
/// enclosing symbol, with the call-site line and whether it resolved. This is the
/// "find usages" verb — structured, comment/string-free, resolution-aware.
/// `Recv.field`/`.field` patterns pin instance-attribute reads.
fn searchRefs(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !bool {
    if (opts.sort != .default and opts.sort != .line) return rankedSearchRefs(w, idx, pattern, opts);
    if (opts.format == .jsonl) return json_out.searchRefsJsonl(w, idx, pattern, opts);
    if (opts.format == .json) return json_out.searchRefs(w, idx, pattern, opts);
    var pat = RefPattern.parse(pattern);
    pat.exact = opts.exact;
    var shown: u32 = 0;
    outer: for (idx.graph.symbols) |sym| {
        // The test scope applies to the *referencing* symbol: `--no-tests`
        // hides use sites inside tests (the "who uses X in production" view).
        if (!inTestScope(opts.tests, isTestSymbol(idx, sym))) continue;
        for (sym.refs) |ref| {
            if (!pat.matches(ref) or !refSelected(idx, sym, ref, opts)) continue;
            // One row per *distinct* use-site line. A name referenced on several
            // lines within one caller is deduped into a single ref carrying a
            // `lines` list — expand it so every site is listed, not just the
            // first (the "found only one of its reads" recall gap a trial hit).
            if (ref.lines.len > 1) {
                for (ref.lines) |ln| {
                    try printRefRow(w, idx, sym, ref, ln, opts.verbosity);
                    shown += 1;
                    if (shown >= opts.limit) break :outer;
                }
            } else {
                try printRefRow(w, idx, sym, ref, ref.line, opts.verbosity);
                shown += 1;
                if (shown >= opts.limit) break :outer;
            }
        }
    }
    if (shown == 0) {
        try w.print("(no reference matching '{s}')\n", .{pattern});
        try skippedNote(w, idx);
    }
    try truncationNote(w, opts, shown);
    return shown > 0;
}

/// Print one `search --refs` row: `path:line  name [(on recv)]  in owner [→ …]`.
fn printRefRow(w: *Writer, idx: *const Index, sym: model.Symbol, ref: model.Reference, line: u32, verbosity: render.Verbosity) !void {
    const file = idx.graph.files[sym.file];
    try w.print("{s}:{d}  [{c}] {s}", .{ file.path, line, if (ref.write) @as(u8, 'w') else 'r', ref.name });
    if (ref.qualifier.len != 0) try w.print(" (on {s})", .{ref.qualifier});
    try w.print("  in {s}", .{sym.name});
    if (ref.target != invalid) {
        try w.print("  → {s}", .{idx.graph.files[idx.graph.symbols[ref.target].file].path});
        // A heuristic binding (a bare name matched cross-file by name alone) is
        // marked like call-tree edges are, so the arrow can't be misread as a
        // verified cross-file dependency.
        if (!ref.exact) try w.writeAll(" ?");
    } else if (ref.kind == .call or ref.kind == .route_call) {
        try w.writeAll("  → ~ext");
    }
    // The use-site's source text, so "what does this hit look like" doesn't
    // cost a follow-up `read` per row (a trial burned 6 calls on exactly that).
    // `-v names` is the opt-out for a minimal location list.
    if (verbosity != .names) {
        const src_line = render.sourceLine(file.text, line);
        if (src_line.len != 0) {
            try w.writeAll("\n      | ");
            try render.writeCollapsed(w, src_line, 140);
        }
    }
    try w.writeByte('\n');
}

pub fn refSelected(idx: *const Index, owner: model.Symbol, ref: model.Reference, opts: Options) bool {
    std.debug.assert(owner.id < idx.graph.symbols.len);
    std.debug.assert(ref.target == invalid or ref.target < idx.graph.symbols.len);
    if (opts.writers and !ref.write) return false;
    if (opts.readers and ref.write) return false;
    if (opts.unread and (!ref.write or ref.target == invalid or !targetUnread(idx, ref.target))) return false;
    if (opts.on_type.len == 0) return true;
    for (owner.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, ref.qualifier)) continue;
        return matchesName(opts.on_type, binding.type_name);
    }
    return matchesName(opts.on_type, ref.qualifier);
}

fn targetUnread(idx: *const Index, target: SymbolId) bool {
    std.debug.assert(target < idx.graph.symbols.len);
    var wrote = false;
    for (idx.graph.symbols) |owner| {
        for (owner.refs) |ref| {
            if (ref.target != target) continue;
            if (ref.write) wrote = true else return false;
        }
    }
    return wrote;
}

pub fn flow(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !bool {
    std.debug.assert(name.len > 0);
    if (opts.format == .json) return json_out.flow(w, idx, name, opts);
    if (idx.graph.symbols.len == 0) {
        try w.print("(no symbol named '{s}')\n", .{name});
        return false;
    }
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const ids = resolveIds(idx, name, storage);
    if (ids.len == 0) {
        try w.print("(no symbol named '{s}')\n", .{name});
        return false;
    }
    try multiMatchNote(w, name, ids.len, false);
    if (opts.flow_to.len != 0) return flowPath(w, idx, ids, opts.flow_to, opts);
    const counts = flowCounts(idx, ids, opts);
    if (opts.unread and (counts.producers == 0 or counts.consumers != 0)) {
        try w.print("(no unread flow for '{s}')\n", .{name});
        return false;
    }
    try render.symbol(w, idx, idx.graph.symbols[ids[0]], headerVerbosity(opts.verbosity), 0, true);
    try w.print("\nWRITERS ↳:{d}\n", .{counts.producers});
    var shown: u32 = 0;
    try renderFlowInitializers(w, idx, ids, opts, &shown);
    try renderFlowGroup(w, idx, ids, opts, true, &shown);
    try w.print("\nREADERS ↳:{d}\n", .{counts.consumers});
    try renderFlowGroup(w, idx, ids, opts, false, &shown);
    if (!opts.writers and !opts.unread) try renderTypeConsumers(w, idx, ids, opts, &shown);
    const total = counts.producers + counts.consumers;
    if (shown >= opts.limit and total > shown)
        try w.print("… ({d} more; raise -l to see them)\n", .{total - shown});
    return total > 0;
}

pub const FlowCounts = struct { producers: u32 = 0, consumers: u32 = 0 };

pub fn flowCounts(idx: *const Index, ids: []const SymbolId, opts: Options) FlowCounts {
    std.debug.assert(ids.len > 0);
    std.debug.assert(ids[0] < idx.graph.symbols.len);
    var counts: FlowCounts = .{ .producers = flowInitializerCount(idx, ids, opts) };
    for (idx.graph.symbols) |owner| for (owner.refs) |ref| {
        const producer = flowProducer(idx, ids, ref);
        if (!contains(ids, ref.target) or !flowRefSelected(idx, owner, ref, producer, opts)) continue;
        if (producer) counts.producers += siteCount(ref) else counts.consumers += siteCount(ref);
    };
    if (!opts.writers and !opts.unread and flowTypeTarget(idx, ids) != null) {
        for (idx.graph.symbols) |owner| {
            if (typeConsumerBinding(idx, ids, owner) != null) counts.consumers += 1;
        }
    }
    return counts;
}

fn siteCount(ref: model.Reference) u32 {
    return if (ref.lines.len > 1) @intCast(ref.lines.len) else 1;
}

fn renderFlowInitializers(w: *Writer, idx: *const Index, ids: []const SymbolId, opts: Options, shown: *u32) !void {
    std.debug.assert(ids.len > 0);
    std.debug.assert(shown.* <= opts.limit);
    for (ids) |id| {
        if (shown.* >= opts.limit) return;
        if (!flowInitializerSelected(idx, id, opts)) continue;
        const sym = idx.graph.symbols[id];
        const file = idx.graph.files[sym.file];
        try w.print("{s}:{d}  [w:init] {s}  at definition", .{ file.path, sym.line, sym.name });
        if (opts.verbosity != .names) {
            const src_line = render.sourceLine(file.text, sym.line);
            if (src_line.len != 0) {
                try w.writeAll("\n      | ");
                try render.writeCollapsed(w, src_line, 140);
            }
        }
        try w.writeByte('\n');
        shown.* += 1;
    }
}

fn renderFlowGroup(w: *Writer, idx: *const Index, ids: []const SymbolId, opts: Options, write: bool, shown: *u32) !void {
    std.debug.assert(ids.len > 0);
    std.debug.assert(shown.* <= opts.limit);
    for (idx.graph.symbols) |owner| for (owner.refs) |ref| {
        if (shown.* >= opts.limit) return;
        const producer = flowProducer(idx, ids, ref);
        if (producer != write or !contains(ids, ref.target) or !flowRefSelected(idx, owner, ref, producer, opts)) continue;
        if (ref.lines.len > 1) {
            for (ref.lines) |line| {
                if (shown.* >= opts.limit) return;
                var directed = ref;
                directed.write = write;
                try printRefRow(w, idx, owner, directed, line, opts.verbosity);
                shown.* += 1;
            }
        } else {
            var directed = ref;
            directed.write = write;
            try printRefRow(w, idx, owner, directed, ref.line, opts.verbosity);
            shown.* += 1;
        }
    };
}

pub fn flowTypeTarget(idx: *const Index, ids: []const SymbolId) ?SymbolId {
    for (ids) |id| switch (idx.graph.symbols[id].kind) {
        .class, .@"struct", .interface, .type, .@"enum" => return id,
        else => {},
    };
    return null;
}

pub const TypeConsumer = struct { binding: []const u8, line: u32 };

pub fn typeConsumerBinding(idx: *const Index, ids: []const SymbolId, owner: model.Symbol) ?TypeConsumer {
    const target = flowTypeTarget(idx, ids) orelse return null;
    const type_name = idx.graph.symbols[target].name;
    for (owner.bindings) |binding| {
        if (!std.mem.eql(u8, binding.type_name, type_name)) continue;
        for (owner.refs) |ref| {
            if (!ref.write and std.mem.eql(u8, ref.qualifier, binding.name)) return .{ .binding = binding.name, .line = ref.line };
        }
        const signature = owner.signature(idx.graph.files[owner.file].text);
        if (std.mem.indexOf(u8, signature, binding.name) != null and std.mem.indexOf(u8, signature, type_name) != null)
            return .{ .binding = binding.name, .line = owner.line };
    }
    return null;
}

fn renderTypeConsumers(w: *Writer, idx: *const Index, ids: []const SymbolId, opts: Options, shown: *u32) !void {
    const target = flowTypeTarget(idx, ids) orelse return;
    std.debug.assert(target < idx.graph.symbols.len);
    std.debug.assert(shown.* <= opts.limit);
    for (idx.graph.symbols) |owner| {
        if (shown.* >= opts.limit) return;
        const consumer = typeConsumerBinding(idx, ids, owner) orelse continue;
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
        try printRefRow(w, idx, owner, ref, consumer.line, opts.verbosity);
        shown.* += 1;
    }
}

pub fn flowInitializerSelected(idx: *const Index, id: SymbolId, opts: Options) bool {
    std.debug.assert(id < idx.graph.symbols.len);
    const sym = idx.graph.symbols[id];
    std.debug.assert(sym.file < idx.graph.files.len);
    if (sym.parent != invalid or (sym.kind != .constant and sym.kind != .variable)) return false;
    if (opts.readers or opts.on_type.len != 0) return false;
    const signature = sym.signature(idx.graph.files[sym.file].text);
    if (std.mem.indexOfScalar(u8, signature, '=') == null) return false;
    if (!opts.unread) return true;
    for (idx.graph.symbols) |owner| for (owner.refs) |ref| {
        if (ref.target == id and !ref.write) return false;
    };
    return true;
}

fn flowInitializerCount(idx: *const Index, ids: []const SymbolId, opts: Options) u32 {
    std.debug.assert(ids.len > 0);
    std.debug.assert(idx.graph.symbols.len > 0);
    var count: u32 = 0;
    for (ids) |id| if (flowInitializerSelected(idx, id, opts)) {
        count += 1;
    };
    return count;
}

pub fn flowProducer(idx: *const Index, ids: []const SymbolId, ref: model.Reference) bool {
    if (ref.write) return true;
    if (ref.kind != .call or !contains(ids, ref.target)) return false;
    return switch (idx.graph.symbols[ref.target].kind) {
        .class, .@"struct", .interface, .type, .@"enum" => true,
        else => false,
    };
}

pub fn flowRefSelected(idx: *const Index, owner: model.Symbol, ref: model.Reference, producer: bool, opts: Options) bool {
    std.debug.assert(owner.id < idx.graph.symbols.len);
    std.debug.assert(ref.target == invalid or ref.target < idx.graph.symbols.len);
    if (opts.strict and !ref.exact) return false;
    if (opts.writers and !producer) return false;
    if (opts.readers and producer) return false;
    var scoped = opts;
    scoped.writers = false;
    scoped.readers = false;
    return refSelected(idx, owner, ref, scoped);
}

fn flowPath(w: *Writer, idx: *const Index, ids: []const SymbolId, sink: []const u8, opts: Options) !bool {
    std.debug.assert(ids.len > 0);
    std.debug.assert(sink.len > 0);
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const sinks = resolveIds(idx, sink, storage);
    try multiMatchNote(w, sink, sinks.len, false);
    if (sinks.len == 0) {
        try w.print("(no data-flow path to '{s}')\n", .{sink});
        return false;
    }
    const chain = try flowPathBetweenIds(idx, ids, sinks, opts);
    defer idx.gpa.free(chain);
    if (chain.len == 0) {
        try w.print("(no data-flow path to '{s}')\n", .{sink});
        return false;
    }
    for (chain, 0..) |id, indent| try render.symbol(w, idx, idx.graph.symbols[id], headerVerbosity(opts.verbosity), indent, true);
    return true;
}

pub fn flowPathIds(idx: *const Index, ids: []const SymbolId, sink: []const u8, strict: bool) ![]SymbolId {
    std.debug.assert(ids.len > 0);
    std.debug.assert(sink.len > 0);
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const sinks = resolveIds(idx, sink, storage);
    if (sinks.len == 0) return idx.gpa.alloc(SymbolId, 0);
    return flowPathBetweenIds(idx, ids, sinks, .{ .strict = strict });
}

pub fn flowPathBetweenIds(idx: *const Index, ids: []const SymbolId, sinks: []const SymbolId, opts: Options) ![]SymbolId {
    std.debug.assert(ids.len > 0);
    std.debug.assert(sinks.len > 0);
    var sources: std.ArrayList(SymbolId) = .empty;
    defer sources.deinit(idx.gpa);
    const seen = try idx.gpa.alloc(bool, idx.graph.symbols.len);
    defer idx.gpa.free(seen);
    @memset(seen, false);
    for (ids) |id| {
        if (!flowInitializerSelected(idx, id, opts)) continue;
        seen[id] = true;
        try sources.append(idx.gpa, id);
    }
    for (idx.graph.symbols) |owner| for (owner.refs) |ref| {
        const producer = flowProducer(idx, ids, ref);
        if (!contains(ids, ref.target) or !flowRefSelected(idx, owner, ref, producer, opts)) continue;
        if (!producer or seen[owner.id]) continue;
        seen[owner.id] = true;
        try sources.append(idx.gpa, owner.id);
    };
    if (sources.items.len == 0) return idx.gpa.alloc(SymbolId, 0);
    const traversal = try bfsFlow(idx, sources.items, sinks, opts.strict);
    defer idx.gpa.free(traversal.prev);
    const end = traversal.reached orelse return idx.gpa.alloc(SymbolId, 0);
    return reconstruct(idx.gpa, traversal.prev, end);
}

/// The number of distinct resolved callees (outgoing edges) of `sym`.
pub fn fanOut(sym: model.Symbol) u32 {
    var out: u32 = 0;
    for (sym.refs) |ref| {
        if (ref.target != invalid) out += 1;
    }
    return out;
}

/// Outgoing edges that are exact (heuristic `?` edges excluded).
fn fanOutExact(sym: model.Symbol) u32 {
    var out: u32 = 0;
    for (sym.refs) |ref| {
        if (ref.target != invalid and ref.exact) out += 1;
    }
    return out;
}

/// Rank functions/methods by connectivity (callers = fan-in, callees = fan-out)
/// and list the busiest — the load-bearing symbols an agent should read first to
/// understand a repo, and where changes ripple widest. Ranked by fan-in, then
/// fan-out. Honors an optional path `filter` and `-l` for the count.
/// Returns whether any entry was reported.
pub fn hot(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    var effective = opts;
    effective.limit = compactCap(opts, hotLimit(opts), 96);
    if (effective.summary) effective.verbosity = .names;
    if (effective.format == .jsonl) return json_out.hotJsonl(w, idx, filter, effective);
    if (effective.format == .json) return json_out.hot(w, idx, filter, effective);
    const ranked = try collectHot(idx, filter, effective.tests);
    defer idx.gpa.free(ranked);
    sortHot(idx, ranked, effective.sort);
    // `hot` is an orientation view — a short ranked list is the point, so it
    // caps at a small default (raise `-l` for more) via the limit sentinel.
    const limit = effective.limit;
    var shown: u32 = 0;
    var eligible: u32 = 0;
    for (ranked) |e| {
        // `--strict` ranks and reports on exact edges only, and hides a symbol
        // whose connectivity is entirely heuristic (a name-collision artifact).
        if (effective.strict and e.fan_in_exact == 0 and e.fan_out_exact == 0) continue;
        eligible += 1;
        if (shown >= limit) continue;
        shown += 1;
        const sym = idx.graph.symbols[e.id];
        try render.symbol(w, idx, sym, headerVerbosity(effective.verbosity), 0, true);
        try printHotCounts(w, idx, e, effective);
    }
    if (shown == 0) {
        try w.print("(no functions under '{s}')\n", .{filter});
        try skippedNote(w, idx);
        return false;
    }
    if (eligible > shown) {
        try w.print("… ({d} more; raise -l to see them)\n", .{eligible - shown});
    }
    if (effective.tests == .with and hotTestDominated(ranked, effective)) {
        try w.writeAll("hint: test callers dominate this ranking; use --no-tests (-t without) for production fan-in\n");
    }
    return true;
}

fn hotTestDominated(ranked: []const HotEntry, opts: Options) bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(opts.tests == .with);
    var shown: u32 = 0;
    var dominated: u32 = 0;
    for (ranked) |entry| {
        if (opts.strict and entry.fan_in_exact == 0 and entry.fan_out_exact == 0) continue;
        if (shown >= opts.limit) break;
        shown += 1;
        const test_share = @min(entry.fan_in_test, entry.fan_in);
        if (test_share > entry.fan_in - test_share) dominated += 1;
    }
    return shown >= 3 and dominated * 2 >= shown;
}

/// Fan-in/out suffix for a `hot` row. Default surfaces the heuristic share as a
/// `(N ?)` qualifier so an inflated count is never shown bare; `--strict` prints
/// the exact-only counts. A `⟨N test⟩` note splits out test-only callers so a
/// symbol that is load-bearing only in the test harness isn't mistaken for a
/// production hub.
fn printHotCounts(w: *Writer, idx: *const Index, e: HotEntry, opts: Options) !void {
    if (opts.strict) {
        try w.print("    ←{d} callers  →{d} callees", .{ e.fan_in_exact, e.fan_out_exact });
    } else {
        try w.print("    ←{d} callers", .{e.fan_in});
        if (e.fan_in > e.fan_in_exact) try w.print(" ({d} ?)", .{e.fan_in - e.fan_in_exact});
        try printTestShare(w, e.fan_in, e.fan_in_test);
        try w.print("  →{d} callees", .{e.fan_out});
        if (e.fan_out > e.fan_out_exact) try w.print(" ({d} ?)", .{e.fan_out - e.fan_out_exact});
    }
    const key = if (opts.sort == .default) SortKey.fan_in_exact else opts.sort;
    try w.print("  ⟨rank {s}={d}⟩\n", .{ @tagName(key), hotMetric(idx, e, key) });
}

/// Append ` [N prod / M test]` when some callers are tests, so an agent can tell
/// production load-bearing from test-only exercise at a glance. `fan_in` is the
/// caller total the split applies to (clamped so prod can't go negative).
fn printTestShare(w: *Writer, fan_in: u32, fan_in_test: u32) !void {
    if (fan_in_test == 0 or fan_in == 0) return;
    const test_share = @min(fan_in_test, fan_in);
    try w.print(" [{d} prod / {d} test]", .{ fan_in - test_share, test_share });
}

/// Number of a symbol's incoming edges whose caller lives in a test/fixture file.
fn testCallerCount(idx: *const Index, id: SymbolId) u32 {
    var n: u32 = 0;
    for (idx.callersOf(id)) |cid| {
        if (isTestSymbol(idx, idx.graph.symbols[cid])) n += 1;
    }
    return n;
}

/// For a method whose enclosing class inherits from a type not defined in this
/// repo, the first such external base name — e.g. `RawIOBase` for a class
/// declared `class _WindowsConsoleReader(io.RawIOBase)`. Such methods are
/// routinely invoked by the external framework, so "no in-repo caller" is not
/// evidence of death. Returns null when every base is local (or none).
fn externalBaseOf(idx: *const Index, sym: model.Symbol) ?[]const u8 {
    if (sym.kind != .method or sym.parent == invalid) return null;
    return externalBaseOfClass(idx, idx.graph.symbols[sym.parent], 3);
}

/// The first base of `class_sym` (transitively, up to `depth` levels) that has
/// no in-repo definition. A base defined locally is walked into — a class two
/// hops from `io.RawIOBase` is still framework-driven.
fn externalBaseOfClass(idx: *const Index, class_sym: model.Symbol, depth: u32) ?[]const u8 {
    if (depth == 0) return null;
    switch (class_sym.kind) {
        .class, .@"struct", .interface => {},
        else => return null,
    }
    const sig = class_sym.signature(idx.graph.files[class_sym.file].text);
    const n = std.mem.indexOf(u8, sig, class_sym.name) orelse return null;
    const clause = sig[n + class_sym.name.len ..];
    // Python spells its bases in parentheses (`class C(Base):`), but Java/C#
    // records carry a positional parameter list there (`record P(int x)`), which
    // is not an inheritance clause — skip parenthesized groups for those.
    const parens_are_bases = idx.graph.files[class_sym.file].language.family() == .python;
    // Walk identifiers in the base clause; a dotted chain's LAST segment is the
    // type. Skip clause keywords and `kwarg=` labels (Python metaclass=…).
    var i: usize = 0;
    while (i < clause.len) {
        if (clause[i] == '(' and !parens_are_bases) {
            var pd: u32 = 1;
            i += 1;
            while (i < clause.len and pd > 0) : (i += 1) {
                if (clause[i] == '(') pd += 1;
                if (clause[i] == ')') pd -= 1;
            }
            continue;
        }
        if (!isIdentStart(clause[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < clause.len and isIdentChar(clause[i])) i += 1;
        const word = clause[start..i];
        if (i < clause.len and (clause[i] == '=' or clause[i] == '.')) {
            // kwarg label, or a qualifier segment (`io` of `io.RawIOBase`).
            if (clause[i] == '=') { // skip the kwarg's value expression
                while (i < clause.len and clause[i] != ',' and clause[i] != ')') i += 1;
            }
            continue;
        }
        inline for (.{ "extends", "implements", "public", "private", "protected", "virtual", "final", "abstract", "object" }) |kw| {
            if (std.mem.eql(u8, word, kw)) break;
        } else {
            // A local definition that is really the class itself (click's
            // `class TextWrapper(textwrap.TextWrapper)`) does not count as a
            // local base; a genuinely local base is walked transitively.
            var local: ?model.Symbol = null;
            for (idx.lookup(word)) |cid| {
                if (cid != class_sym.id) {
                    local = idx.graph.symbols[cid];
                    break;
                }
            }
            const base = local orelse return word;
            if (externalBaseOfClass(idx, base, depth - 1)) |ext| return ext;
        }
    }
    return null;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Whether `sym`'s body issues at least one HTTP client call (a `route_call`
/// reference) — an `unused` hint that the symbol is a client leg of a
/// `routes` pairing rather than plain dead code.
fn callsRoutes(sym: model.Symbol) bool {
    for (sym.refs) |ref| {
        if (ref.kind == .route_call) return true;
    }
    return false;
}

/// Whether any indexed file (or inline Zig `test` block) is test code — when
/// none is, `--no-tests`/`--tests-only` can't change anything, and saying so
/// beats letting identical outputs read as a tooling bug.
fn indexHasTests(idx: *const Index) bool {
    for (idx.graph.files) |f| {
        if (isTestPath(f.path)) return true;
    }
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .test_case) return true;
    }
    return false;
}

/// A hint that `sym`, though caller-less in the graph, is likely invoked via a
/// mechanism the graph can't see: a name shared by many same-named callables
/// (interface dispatch — Go `Provision`, `sort.Interface`) or a well-known
/// stdlib-interface method name in Go (`MarshalJSON`, `Len/Less/Swap`, …,
/// dispatched structurally/reflectively).
fn interfaceDispatchHint(idx: *const Index, sym: model.Symbol) ?[]const u8 {
    if (sym.kind != .function and sym.kind != .method) return null;
    if (idx.graph.files[sym.file].language == .go and go_interface_names.has(sym.name)) {
        return "commonly satisfies a stdlib interface in Go";
    }
    // Python file/stream protocol methods are duck-typed: an in-repo class can
    // satisfy `io`-style consumers with no inheritance at all, so "no caller"
    // means nothing for these names.
    if (sym.kind == .method and idx.graph.files[sym.file].language.family() == .python and
        py_protocol_names.has(sym.name))
    {
        return "a Python file/stream protocol method (duck-typed)";
    }
    var callables: u32 = 0;
    for (idx.lookup(sym.name)) |cid| {
        const c = idx.graph.symbols[cid];
        if (c.kind == .function or c.kind == .method) callables += 1;
    }
    if (callables > 4) return "many same-named defs — possible interface dispatch";
    return null;
}

const py_protocol_names = std.StaticStringMap(void).initComptime(.{
    .{"read"},       .{"write"},  .{"readinto"}, .{"readline"}, .{"readlines"},
    .{"writelines"}, .{"seek"},   .{"tell"},     .{"flush"},    .{"close"},
    .{"fileno"},     .{"isatty"}, .{"readable"}, .{"writable"}, .{"seekable"},
    .{"truncate"},   .{"detach"},
});

const go_interface_names = std.StaticStringMap(void).initComptime(.{
    .{"MarshalJSON"},   .{"UnmarshalJSON"},   .{"MarshalText"}, .{"UnmarshalText"},
    .{"MarshalBinary"}, .{"UnmarshalBinary"}, .{"String"},      .{"GoString"},
    .{"Error"},         .{"Len"},             .{"Less"},        .{"Swap"},
    .{"ServeHTTP"},     .{"Read"},            .{"Write"},       .{"Close"},
});

/// Caller count with the test scope applied to each *caller* (see collectHot).
fn scopedCallerCount(idx: *const Index, id: SymbolId, scope: TestScope) u32 {
    var n: u32 = 0;
    for (idx.callersOf(id)) |cid| {
        if (inTestScope(scope, isTestSymbol(idx, idx.graph.symbols[cid]))) n += 1;
    }
    return n;
}

pub const HotEntry = struct {
    id: SymbolId,
    fan_in: u32,
    fan_in_exact: u32,
    /// Incoming edges whose caller lives in a test/fixture file. A high test
    /// share means a symbol is exercised, not load-bearing in production.
    fan_in_test: u32,
    fan_out: u32,
    fan_out_exact: u32,
};

/// Collect callable symbols under `filter`, sorted by *exact* fan-in then exact
/// fan-out (descending), so heuristic name-collision edges can't float a symbol
/// to the top. Ties fall back to total fan-in/out. Caller frees the slice.
pub fn collectHot(idx: *const Index, filter: []const u8, scope: TestScope) ![]HotEntry {
    // Exact incoming-edge count per symbol (heuristic `?` edges excluded), so a
    // symbol's rank reflects edges we can actually stand behind. The test scope
    // filters the *edges*, not just the listed symbols: under `--no-tests` a
    // caller in test code contributes nothing, so a production-file helper that
    // only tests call ranks by its true production fan-in (zero) instead of
    // floating to the top on harness traffic.
    var exact_in = try idx.gpa.alloc(u32, idx.graph.symbols.len);
    defer idx.gpa.free(exact_in);
    @memset(exact_in, 0);
    for (idx.graph.symbols) |sym| {
        if (!inTestScope(scope, isTestSymbol(idx, sym))) continue;
        for (sym.refs) |ref| {
            if (ref.target != invalid and ref.exact) exact_in[ref.target] += 1;
        }
    }
    var list: std.ArrayList(HotEntry) = .empty;
    errdefer list.deinit(idx.gpa);
    for (idx.graph.symbols) |sym| {
        if (sym.kind != .function and sym.kind != .method) continue;
        if (!matchesFilter(idx.graph.files[sym.file].path, filter)) continue;
        if (!inTestScope(scope, isTestSymbol(idx, sym))) continue;
        const fan_in = scopedCallerCount(idx, sym.id, scope);
        const fan_out = fanOut(sym);
        if (fan_in == 0 and fan_out == 0) continue; // isolated: not informative
        try list.append(idx.gpa, .{
            .id = sym.id,
            .fan_in = fan_in,
            .fan_in_exact = exact_in[sym.id],
            // The prod/test breakdown only makes sense when both are in view.
            .fan_in_test = if (scope == .with) testCallerCount(idx, sym.id) else 0,
            .fan_out = fan_out,
            .fan_out_exact = fanOutExact(sym),
        });
    }
    const items = try list.toOwnedSlice(idx.gpa);
    std.mem.sort(HotEntry, items, {}, hotLessThan);
    return items;
}

/// Descending: exact fan-in, then exact fan-out, then total fan-in/out, then id.
/// Exact-first keeps a symbol whose fan-in is only heuristic guesses from
/// outranking one with real, verifiable callers.
pub fn hotMetric(idx: *const Index, entry: HotEntry, sort: SortKey) u32 {
    return switch (sort) {
        .fan_in => entry.fan_in,
        .fan_in_exact, .default => entry.fan_in_exact,
        .fan_out => entry.fan_out,
        .fan_out_exact => entry.fan_out_exact,
        .span => blk: {
            const sym = idx.graph.symbols[entry.id];
            break :blk sym.endLine(idx.graph.files[sym.file].text) - sym.line + 1;
        },
        else => entry.fan_in_exact,
    };
}

const HotSortContext = struct { idx: *const Index, sort: SortKey };

pub fn sortHot(idx: *const Index, entries: []HotEntry, requested: SortKey) void {
    std.debug.assert(entries.len <= idx.graph.symbols.len);
    const sort = if (requested == .default) SortKey.fan_in_exact else requested;
    std.mem.sort(HotEntry, entries, HotSortContext{ .idx = idx, .sort = sort }, hotRankLessThan);
}

fn hotRankLessThan(ctx: HotSortContext, a: HotEntry, b: HotEntry) bool {
    const am = hotMetric(ctx.idx, a, ctx.sort);
    const bm = hotMetric(ctx.idx, b, ctx.sort);
    if (am != bm) return am > bm;
    const sa = ctx.idx.graph.symbols[a.id];
    const sb = ctx.idx.graph.symbols[b.id];
    const path_order = std.mem.order(u8, ctx.idx.graph.files[sa.file].path, ctx.idx.graph.files[sb.file].path);
    if (path_order != .eq) return path_order == .lt;
    if (sa.line != sb.line) return sa.line < sb.line;
    return a.id < b.id;
}

fn hotLessThan(_: void, a: HotEntry, b: HotEntry) bool {
    if (a.fan_in_exact != b.fan_in_exact) return a.fan_in_exact > b.fan_in_exact;
    if (a.fan_out_exact != b.fan_out_exact) return a.fan_out_exact > b.fan_out_exact;
    if (a.fan_in != b.fan_in) return a.fan_in > b.fan_in;
    if (a.fan_out != b.fan_out) return a.fan_out > b.fan_out;
    return a.id < b.id;
}

fn pct(num: u32, den: u32) f64 {
    if (den == 0) return 100.0;
    return 100.0 * @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
}

/// Mark every symbol reachable through exact executable edges from a test symbol.
/// Caller owns the returned slice, indexed by `SymbolId`. Backs `coverage`.
pub fn testReachable(idx: *const Index, gpa: std.mem.Allocator) ![]bool {
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    std.debug.assert(idx.callers.len == idx.graph.symbols.len);
    const reached = try gpa.alloc(bool, idx.graph.symbols.len);
    errdefer gpa.free(reached);
    @memset(reached, false);
    var work: std.ArrayList(SymbolId) = .empty;
    defer work.deinit(gpa);
    for (idx.graph.symbols) |sym| {
        if (isTestSymbol(idx, sym) and !reached[sym.id]) {
            reached[sym.id] = true;
            try work.append(gpa, sym.id);
        }
    }
    var wi: usize = 0;
    while (wi < work.items.len) : (wi += 1) {
        for (idx.graph.symbols[work.items[wi]].refs) |ref| {
            const executable = ref.kind == .call or ref.kind == .route_call;
            if (!executable or !ref.exact or ref.target == invalid or reached[ref.target]) continue;
            reached[ref.target] = true;
            try work.append(gpa, ref.target);
        }
    }
    return reached;
}

/// `coverage [path]` — for each file, the fraction of its non-test fn/method
/// symbols reachable through exact call/route-call edges from at least one test.
/// This is a dependency-free, language-agnostic substitute for line coverage
/// DWARF5). Conservative: only resolved edges are followed, so real coverage is
/// at least the number reported.
/// Returns whether any file with fn/method symbols matched (i.e. a non-empty
/// coverage report was printed).
pub fn coverage(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.coverage(w, idx, filter, opts);
    const reached = try testReachable(idx, idx.gpa);
    defer idx.gpa.free(reached);
    var total: u32 = 0;
    var covered: u32 = 0;
    var any = false;
    var shown: u32 = 0;
    for (idx.graph.files) |file| {
        if (!matchesFilter(file.path, filter)) continue;
        var ft: u32 = 0;
        var fc: u32 = 0;
        var i = file.sym_start;
        while (i < file.sym_end) : (i += 1) {
            const sym = idx.graph.symbols[i];
            if (sym.kind != .function and sym.kind != .method) continue;
            if (isTestSymbol(idx, sym)) continue;
            ft += 1;
            if (reached[sym.id]) fc += 1;
        }
        if (ft == 0) continue;
        any = true;
        total += ft;
        covered += fc;
        if (shown < opts.limit) {
            try w.print("  {d:>5.1}%  {s}  ({d}/{d})\n", .{ pct(fc, ft), file.path, fc, ft });
            shown += 1;
        }
    }
    if (!any) {
        try w.print("(no fn/method symbols under '{s}')\n", .{filter});
        try skippedNote(w, idx);
        return false;
    }
    try truncationNote(w, opts, shown);
    try w.print("  overall: {d:.1}%  ({d}/{d} fn/method reachable from a test)\n", .{ pct(covered, total), covered, total });
    return true;
}

pub const ConformanceVerdict = enum { ok, missing, sig_diff, async_diff };

pub fn conformanceVerdict(idx: *const Index, expected: model.Symbol, actual: ?model.Symbol) ConformanceVerdict {
    std.debug.assert(expected.kind == .method);
    std.debug.assert(expected.parent != invalid);
    const implementation = actual orelse return .missing;
    if (expected.modifiers.is_async != implementation.modifiers.is_async) return .async_diff;
    const expected_sig = signatureTail(idx, expected);
    const actual_sig = signatureTail(idx, implementation);
    return if (equalIgnoringWhitespace(expected_sig, actual_sig)) .ok else .sig_diff;
}

fn signatureTail(idx: *const Index, sym: model.Symbol) []const u8 {
    const sig = sym.signature(idx.graph.files[sym.file].text);
    // Anchor at the parameter list that follows the method NAME, so a Go/Rust
    // receiver (`func (s *T) Get(...)`) or leading `func`/`fn` keyword before the
    // name is ignored — otherwise an exact implementation reads as SIG-DIFF.
    const open = methodParamOpen(sig, sym.name) orelse
        (std.mem.indexOfScalar(u8, sig, '(') orelse return sig);
    return trimSigTail(sig[open..]);
}

/// Offset of the `(` that opens the parameter list belonging to method `name`:
/// the first word-bounded occurrence of `name` followed (past an optional
/// generic argument list and whitespace) by `(`. Skips a leading receiver.
fn methodParamOpen(sig: []const u8, name: []const u8) ?usize {
    if (name.len == 0) return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, sig, from, name)) |ni| {
        from = ni + 1;
        const before_ok = ni == 0 or !isIdentByte(sig[ni - 1]);
        var j = ni + name.len;
        const after_ok = j >= sig.len or !isIdentByte(sig[j]);
        if (!before_ok or !after_ok) continue;
        while (j < sig.len and std.ascii.isWhitespace(sig[j])) j += 1;
        if (j < sig.len and sig[j] == '<') { // skip a generic argument list
            var depth: usize = 0;
            while (j < sig.len) : (j += 1) {
                if (sig[j] == '<') depth += 1 else if (sig[j] == '>') {
                    depth -= 1;
                    if (depth == 0) {
                        j += 1;
                        break;
                    }
                }
            }
            while (j < sig.len and std.ascii.isWhitespace(sig[j])) j += 1;
        }
        if (j < sig.len and sig[j] == '(') return j;
    }
    return null;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Trim trailing whitespace and a single `;` (trait / interface method
/// declarations end in `;` while their implementations do not).
fn trimSigTail(s: []const u8) []const u8 {
    var t = s;
    while (t.len > 0 and (std.ascii.isWhitespace(t[t.len - 1]) or t[t.len - 1] == ';')) t = t[0 .. t.len - 1];
    return t;
}

fn equalIgnoringWhitespace(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and std.ascii.isWhitespace(a[ai])) ai += 1;
        while (bi < b.len and std.ascii.isWhitespace(b[bi])) bi += 1;
        if (ai == a.len or bi == b.len) return ai == a.len and bi == b.len;
        if (a[ai] != b[bi]) return false;
        ai += 1;
        bi += 1;
    }
}

/// Compare a protocol/interface's declared methods with every nominal or
/// structural implementation discovered in the project.
pub fn conforms(w: *Writer, idx: *const Index, selector: []const u8, opts: Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(opts.limit > 0);
    if (opts.format == .json) return json_out.conforms(w, idx, selector, opts);
    var ids_buf: [64]SymbolId = undefined;
    const ids = resolveIds(idx, selector, &ids_buf);
    var graph = try impls_mod.build(idx.gpa, idx);
    defer graph.deinit();
    var shown: u32 = 0;
    for (ids) |id| {
        var port = idx.graph.symbols[id];
        if (port.kind == .method and port.parent != invalid) port = idx.graph.symbols[port.parent];
        if (!impls_mod.isPort(idx, port)) continue;
        if (shown != 0) try w.writeByte('\n');
        try renderConformancePort(w, idx, &graph, port, opts);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (shown == 0) shown = if (try renderSiblingConformance(w, idx, ids, opts)) 1 else 0;
    if (shown == 0) try w.print("(no protocol/interface or sibling set matching '{s}')\n", .{selector});
    return shown > 0;
}

fn renderSiblingConformance(w: *Writer, idx: *const Index, ids: []const SymbolId, opts: Options) !bool {
    var parents: [64]SymbolId = undefined;
    const parent_count = collectConformanceParents(idx, ids, &parents);
    if (parent_count < 2) return false;
    try w.print("# sibling conformance · {d} classes\n", .{parent_count});
    // Restrict the compared method set to the explicitly-selected methods only
    // when the selector picked methods and NOT containers. A glob like `*Product`
    // also matches the classes' same-named constructors; without this guard that
    // would collapse the matrix to just the constructor rows and hide the real
    // method divergences (Label/IsSellable).
    const restrict_to_ids = idsContainMethods(idx, ids) and !idsContainContainers(idx, ids);
    var rendered_names = std.StringHashMap(void).init(idx.gpa);
    defer rendered_names.deinit();
    var rendered: u32 = 0;
    for (idx.graph.symbols) |method| {
        if (rendered >= opts.limit) break;
        if (method.kind != .method or !contains(parents[0..parent_count], method.parent)) continue;
        if (restrict_to_ids and !contains(ids, method.id)) continue;
        if ((try rendered_names.getOrPut(method.name)).found_existing) continue;
        try render.symbol(w, idx, method, .sig, 1, true);
        rendered += 1;
        for (parents[0..parent_count]) |parent| {
            if (parent == method.parent) continue; // the header already shows this definition
            const actual_id = impls_mod.methodOf(idx, parent, method.name);
            try renderSiblingCell(w, idx, method, parent, actual_id);
        }
    }
    return rendered > 0;
}

pub fn collectConformanceParents(idx: *const Index, ids: []const SymbolId, out: []SymbolId) usize {
    std.debug.assert(out.len > 0);
    var count: usize = 0;
    for (ids) |id| {
        const sym = idx.graph.symbols[id];
        const parent = if (impls_mod.isContainer(sym)) sym.id else sym.parent;
        if (parent == invalid or contains(out[0..count], parent)) continue;
        if (count == out.len) break;
        out[count] = parent;
        count += 1;
    }
    return count;
}

pub fn idsContainMethods(idx: *const Index, ids: []const SymbolId) bool {
    for (ids) |id| if (idx.graph.symbols[id].kind == .method) return true;
    return false;
}

pub fn idsContainContainers(idx: *const Index, ids: []const SymbolId) bool {
    for (ids) |id| if (impls_mod.isContainer(idx.graph.symbols[id])) return true;
    return false;
}

/// Emit a command-level error respecting the output format, so `-j`/`--jsonl`
/// stay valid JSON instead of leaking raw text (e.g. git usage) to stdout.
pub fn emitError(w: *Writer, format: OutputFormat, message: []const u8) !void {
    switch (format) {
        .json, .jsonl => {
            try w.writeAll("{\"error\":");
            try json_out.writeString(w, message);
            try w.writeAll("}\n");
        },
        .text => try w.print("navgraph: {s}\n", .{message}),
    }
}

fn renderSiblingCell(w: *Writer, idx: *const Index, expected: model.Symbol, parent: SymbolId, actual_id: ?SymbolId) !void {
    std.debug.assert(parent < idx.graph.symbols.len);
    std.debug.assert(expected.parent != invalid);
    const container = idx.graph.symbols[parent];
    const file = idx.graph.files[container.file];
    const actual = if (actual_id) |id| idx.graph.symbols[id] else null;
    const verdict = conformanceVerdict(idx, expected, actual);
    try w.print("    {s:<10} {s}  {s}:{d}", .{ @tagName(verdict), container.name, file.path, container.line });
    if (actual) |sym| {
        try w.writeByte('\n');
        try render.symbol(w, idx, sym, .sig, 2, true);
    } else {
        try w.print(" — no `{s}` member\n", .{expected.name});
    }
}

fn renderConformancePort(w: *Writer, idx: *const Index, graph: *const impls_mod.Graph, port: model.Symbol, opts: Options) !void {
    const methods = impls_mod.methodCount(idx, port.id);
    var implementations: usize = 0;
    for (graph.relations) |rel| {
        if (rel.port == port.id and (!opts.strict or rel.exact)) implementations += 1;
    }
    try w.print("# {s}  {s}:{d}  · {d} member{s} · {d} impl{s}\n", .{
        port.name,       idx.graph.files[port.file].path,       port.line, methods, if (methods == 1) "" else "s",
        implementations, if (implementations == 1) "" else "s",
    });
    for (idx.graph.symbols) |expected| {
        if (expected.parent != port.id or expected.kind != .method) continue;
        try render.symbol(w, idx, expected, .sig, 1, false);
        for (graph.relations) |rel| {
            if (rel.port != port.id or (opts.strict and !rel.exact)) continue;
            const actual_id = impls_mod.methodOf(idx, rel.implementation, expected.name);
            try renderConformanceCell(w, idx, expected, rel, actual_id);
        }
    }
}

fn renderConformanceCell(w: *Writer, idx: *const Index, expected: model.Symbol, rel: impls_mod.Relation, actual_id: ?SymbolId) !void {
    const actual = if (actual_id) |id| idx.graph.symbols[id] else null;
    const verdict = conformanceVerdict(idx, expected, actual);
    const label = switch (verdict) {
        .ok => "OK",
        .missing => "MISSING",
        .sig_diff => "SIG-DIFF",
        .async_diff => "ASYNC-DIFF",
    };
    try w.print("    {s:<10} ", .{label});
    if (actual) |sym| {
        try render.symbol(w, idx, sym, .sig, 0, true);
    } else {
        const implementation = idx.graph.symbols[rel.implementation];
        try w.print("{s}  {s}:{d} — no `{s}` member\n", .{
            implementation.name, idx.graph.files[implementation.file].path, implementation.line, expected.name,
        });
    }
    if (!rel.exact) try w.writeAll("      ? structural match\n");
}

/// List HTTP route definitions with selectable handler/client coverage views.
pub fn listRoutes(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.listRoutes(w, idx, filter, opts);
    if (opts.routes_orphan_calls) return listOrphanRouteCalls(w, idx, filter, opts);
    var shown: u32 = 0;
    for (idx.graph.symbols) |route| {
        if (route.kind != .route) continue;
        if (!routeMatches(idx, route, filter, opts.routes_handler)) continue;
        if (opts.routes_unhit and idx.callersOf(route.id).len != 0) continue;
        try render.symbol(w, idx, route, opts.verbosity, 0, true);
        try routeRelations(w, idx, route, opts.routes_clients);
        if (opts.routes_unhit) try w.writeAll("  (unhit: 0 client calls)\n");
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (shown == 0) {
        try w.print("(no routes under '{s}')\n", .{filter});
        try skippedNote(w, idx);
    }
    try truncationNote(w, opts, shown);
    return shown > 0;
}

pub fn routeHandler(idx: *const Index, route: model.Symbol) ?model.Symbol {
    std.debug.assert(route.kind == .route);
    std.debug.assert(route.id < idx.graph.symbols.len);
    for (route.refs) |ref| {
        if (ref.kind == .call and ref.target != invalid) return idx.graph.symbols[ref.target];
    }
    return null;
}

pub fn routeMatches(idx: *const Index, route: model.Symbol, filter: []const u8, handler_filter: []const u8) bool {
    const handler = routeHandler(idx, route);
    if (handler_filter.len != 0 and (handler == null or !matchesName(handler_filter, handler.?.name))) return false;
    return filter.len == 0 or matchesName(filter, route.name) or (handler != null and matchesName(filter, handler.?.name));
}

fn routeRelations(w: *Writer, idx: *const Index, route: model.Symbol, clients_only: bool) !void {
    if (!clients_only) {
        if (routeHandler(idx, route)) |handler| try render.symbol(w, idx, handler, .sig, 1, true);
    }
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    for (idx.callersOf(route.id)) |cid| {
        const client = idx.graph.symbols[cid];
        try w.print("  [{s}] ", .{idx.graph.files[client.file].language.tag()});
        try callSiteLines(idx, cid, route.id, &lines);
        try render.symbolSite(w, idx, client, .sig, 0, true, callSiteLine(idx, cid, route.id), callSiteCount(idx, cid, route.id), lines.items, hasExactEdge(idx, cid, route.id));
    }
}

fn listOrphanRouteCalls(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    var shown: u32 = 0;
    outer: for (idx.graph.symbols) |owner| {
        for (owner.refs) |ref| {
            if (ref.kind != .route_call or ref.target != invalid) continue;
            if (!matchesName(filter, ref.name)) continue;
            const file = idx.graph.files[owner.file];
            try w.print("orphan {s}\n  [{s}] ", .{ ref.name, file.language.tag() });
            try render.symbolSite(w, idx, owner, .sig, 0, true, ref.line, ref.count, ref.lines, false);
            try w.writeAll("  (no route serves this call)\n");
            shown += 1;
            if (shown >= opts.limit) break :outer;
        }
    }
    if (shown == 0) try w.print("(no orphan route calls matching '{s}')\n", .{filter});
    try truncationNote(w, opts, shown);
    return shown > 0;
}

/// A single event-dispatch site tied to its file (path + enclosing-symbol lookup).
pub const EventSite = struct {
    file: model.FileId,
    ref: events_mod.EventRef,
};

/// Collect every string-keyed dispatch site across the repo (gpa-owned). Each
/// site's `key`/`verb` slices point into the owning file's text (alive for the
/// graph). Caller frees the slice.
pub fn collectEvents(idx: *const Index, filter: []const u8) ![]EventSite {
    var sites: std.ArrayList(EventSite) = .empty;
    errdefer sites.deinit(idx.gpa);
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(idx.gpa);
    var refs: std.ArrayList(events_mod.EventRef) = .empty;
    defer refs.deinit(idx.gpa);
    for (idx.graph.files) |file| {
        toks.clearRetainingCapacity();
        refs.clearRetainingCapacity();
        lexer.tokenize(idx.gpa, file.text, language.configFor(file.language), &toks) catch continue;
        try events_mod.collect(toks.items, file.text, &refs, idx.gpa);
        for (refs.items) |r| {
            if (filter.len != 0 and std.mem.indexOf(u8, r.key, filter) == null) continue;
            try sites.append(idx.gpa, .{ .file = file.id, .ref = r });
        }
    }
    const items = try sites.toOwnedSlice(idx.gpa);
    std.mem.sort(EventSite, items, idx, eventSiteLessThan);
    return items;
}

/// Order sites so paired keys (a handler *and* an emitter) come first — the real
/// dispatch pairs an agent wants — then by key, role (handler before emitter),
/// file and line for a stable read.
fn eventSiteLessThan(idx: *const Index, a: EventSite, b: EventSite) bool {
    if (!std.mem.eql(u8, a.ref.key, b.ref.key)) {
        return std.mem.lessThan(u8, a.ref.key, b.ref.key);
    }
    if (a.ref.role != b.ref.role) return a.ref.role == .handler;
    const pa = idx.graph.files[a.file].path;
    const pb = idx.graph.files[b.file].path;
    if (!std.mem.eql(u8, pa, pb)) return std.mem.lessThan(u8, pa, pb);
    return a.ref.line < b.ref.line;
}

/// Whether the key at `start` has both a handler and an emitter site in the
/// contiguous run of same-key sites beginning there (the list is key-sorted).
fn keyIsPaired(sites: []const EventSite, start: usize) bool {
    var saw_handler = false;
    var saw_emitter = false;
    var i = start;
    while (i < sites.len and std.mem.eql(u8, sites[i].ref.key, sites[start].ref.key)) : (i += 1) {
        switch (sites[i].ref.role) {
            .handler => saw_handler = true,
            .emitter => saw_emitter = true,
        }
    }
    return saw_handler and saw_emitter;
}

/// The name of the innermost symbol in `file` whose span covers byte `offset`,
/// or "" when the site sits at module scope (e.g. a decorator above a def whose
/// span starts at `def`).
pub fn enclosingSymbolName(idx: *const Index, file: model.SourceFile, offset: u32) []const u8 {
    var best: ?model.Symbol = null;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import) continue;
        if (offset < sym.span_start or offset >= sym.span_end) continue;
        if (best == null or sym.span_start > best.?.span_start) best = sym;
    }
    if (best) |s| return s.name;
    // A decorator registration (`@register("x")` above a `def`) sits just before
    // the symbol it decorates, so its offset falls outside every span. Bind it to
    // that immediately-following definition.
    if (lineStartsWithAt(file.text, offset)) {
        if (nextSymbolAfter(idx, file, offset)) |s| return s.name;
    }
    return "";
}

/// Whether the source line containing byte `offset` begins (after leading
/// whitespace) with a decorator `@`.
fn lineStartsWithAt(text: []const u8, offset: u32) bool {
    if (offset > text.len) return false;
    var ls = offset;
    while (ls > 0 and text[ls - 1] != '\n') ls -= 1;
    var p = ls;
    while (p < text.len and (text[p] == ' ' or text[p] == '\t')) p += 1;
    return p < text.len and text[p] == '@';
}

/// The file's non-import symbol whose span begins first at/after `offset` — the
/// definition a decorator above `offset` applies to.
fn nextSymbolAfter(idx: *const Index, file: model.SourceFile, offset: u32) ?model.Symbol {
    var best: ?model.Symbol = null;
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import or sym.span_start < offset) continue;
        if (best == null or sym.span_start < best.?.span_start) best = sym;
    }
    return best;
}

/// List string-keyed message-bus dispatch: each event key with its handler
/// registrations and emitter sites, paired by the shared key. The event-bus
/// analogue of `routes` (which only sees HTTP). Heuristic and token-based.
/// Returns whether any event key group was printed.
pub fn events(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.events(w, idx, filter, opts);
    const sites = try collectEvents(idx, filter);
    defer idx.gpa.free(sites);
    if (sites.len == 0) {
        if (filter.len != 0) {
            try w.print("(no event dispatch matching '{s}')\n", .{filter});
        } else {
            try w.writeAll("(no string-keyed event dispatch found)\n");
        }
        try skippedNote(w, idx);
        return false;
    }
    try emitEventGroups(w, idx, sites, opts);
    return true;
}

/// Render key-sorted sites as `event "key"` groups, paired keys first. Stops once
/// `opts.limit` keys have printed.
fn emitEventGroups(w: *Writer, idx: *const Index, sites: []const EventSite, opts: Options) !void {
    var shown_keys: u32 = 0;
    var i: usize = 0;
    while (i < sites.len) {
        const key = sites[i].ref.key;
        const paired = keyIsPaired(sites, i);
        try w.print("event \"{s}\"{s}\n", .{ key, if (paired) "" else "  (unpaired)" });
        while (i < sites.len and std.mem.eql(u8, sites[i].ref.key, key)) : (i += 1) {
            try printEventSite(w, idx, sites[i]);
        }
        shown_keys += 1;
        if (shown_keys >= opts.limit) break;
    }
    if (i < sites.len) try w.print("… (more; raise -l to see them)\n", .{});
}

/// One dispatch-site row: `⊕ register  path:line  in owner` (handler) or
/// `→ send  path:line  in owner` (emitter).
fn printEventSite(w: *Writer, idx: *const Index, site: EventSite) !void {
    const file = idx.graph.files[site.file];
    const marker = if (site.ref.role == .handler) "⊕" else "→";
    try w.print("  {s} {s}  {s}:{d}", .{ marker, site.ref.verb, file.path, site.ref.line });
    const owner = enclosingSymbolName(idx, file, site.ref.offset);
    if (owner.len != 0) try w.print("  in {s}", .{owner});
    try w.writeByte('\n');
}

/// Show the symbols touched by changes since `ref` (default `HEAD`, i.e. the
/// working tree) and, under each, its direct callers — the blast radius of a
/// change. Runs `git diff` and maps each hunk to the symbol whose span it
/// overlaps, turning a line-oriented diff into a symbol-oriented review.
/// Returns whether at least one changed symbol was reported.
pub fn diff(w: *Writer, io: std.Io, idx: *const Index, root: []const u8, ref: []const u8, opts: Options) !bool {
    return diffAt(w, io, idx, .{ .path = root }, ref, opts);
}

pub fn diffAt(w: *Writer, io: std.Io, idx: *const Index, root: gitutil.Root, ref: []const u8, opts: Options) !bool {
    const spec = if (ref.len != 0) ref else "HEAD";
    const result = runGitDiffAt(idx.gpa, io, root, spec) catch |err| {
        const msg = try std.fmt.allocPrint(idx.gpa, "could not run git diff ({s})", .{@errorName(err)});
        defer idx.gpa.free(msg);
        try emitError(w, opts.format, msg);
        return false;
    };
    defer idx.gpa.free(result.stdout);
    defer idx.gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        const msg = try std.fmt.allocPrint(idx.gpa, "git diff {s} failed: {s}", .{ spec, std.mem.trim(u8, result.stderr, " \n\r\t") });
        defer idx.gpa.free(msg);
        try emitError(w, opts.format, msg);
        return false;
    }
    const patch = try patchWithUntracked(idx.gpa, io, root, idx, result.stdout);
    defer idx.gpa.free(patch);
    const changes = try gitdiff.parse(idx.gpa, patch);
    defer gitdiff.freeChanges(idx.gpa, changes);
    if (opts.format == .json) return json_out.diff(w, idx, changes, patch, opts);
    const found = try renderDiff(w, idx, changes, opts);
    if (!opts.exact_source) return found;
    const source_found = try renderExactSource(w, idx, changes, patch);
    return found or source_found;
}

/// Run `git -C <root> diff --unified=0 --no-color <ref>` and return its result
/// (caller frees stdout/stderr). `--unified=0` keeps hunks tight so a ripple in
/// one function isn't attributed to its neighbor via shared context lines.
pub fn runGitDiff(gpa: std.mem.Allocator, io: std.Io, root: []const u8, ref: []const u8) !std.process.RunResult {
    return runGitDiffAt(gpa, io, .{ .path = root }, ref);
}

pub fn runGitDiffAt(gpa: std.mem.Allocator, io: std.Io, root: gitutil.Root, ref: []const u8) !std.process.RunResult {
    std.debug.assert(ref.len > 0);
    if (!gitutil.validRef(ref)) return error.InvalidGitRef;
    const argv = [_][]const u8{ "git", "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-textconv", "--unified=0", "--no-color", ref, "--" };
    return gitutil.runAt(gpa, io, root, &argv);
}

/// `git diff` intentionally omits untracked files. They are nevertheless part
/// of the live workspace NavGraph indexed and often the most important pending
/// edit. Append canonical no-index patches only for supported, indexed,
/// non-ignored files; the ordinary git-diff parser then treats tracked and new
/// sources through one exact range model.
fn patchWithUntracked(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: gitutil.Root,
    idx: *const Index,
    tracked_patch: []const u8,
) ![]u8 {
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(gpa);
    try combined.appendSlice(gpa, tracked_patch);

    const list_argv = [_][]const u8{ "git", "-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard", "-z", "--" };
    const listed = try gitutil.runAt(gpa, io, root, &list_argv);
    defer gpa.free(listed.stdout);
    defer gpa.free(listed.stderr);
    if (listed.term != .exited or listed.term.exited != 0) return error.GitUntrackedListFailed;

    var paths = std.mem.splitScalar(u8, listed.stdout, 0);
    while (paths.next()) |path| {
        if (path.len == 0 or findDiffFile(idx, path) == null) continue;
        const diff_argv = [_][]const u8{
            "git",           "-c",          "core.quotePath=false", "diff", "--no-index", "--no-ext-diff",
            "--no-textconv", "--unified=0", "--no-color",           "--",   "/dev/null",  path,
        };
        const untracked = try gitutil.runAt(gpa, io, root, &diff_argv);
        defer gpa.free(untracked.stdout);
        defer gpa.free(untracked.stderr);
        if (untracked.term != .exited or (untracked.term.exited != 0 and untracked.term.exited != 1))
            return error.GitUntrackedDiffFailed;
        if (untracked.stdout.len == 0) continue;
        if (combined.items.len != 0 and combined.items[combined.items.len - 1] != '\n') try combined.append(gpa, '\n');
        try combined.appendSlice(gpa, untracked.stdout);
    }
    return combined.toOwnedSlice(gpa);
}

pub const SourceRange = struct {
    line: u32,
    line_end: u32,
    start: u32,
    end: u32,
    text: []const u8,
    empty: bool,
};

/// Map a git hunk's post-image line range to exact bytes in the indexed source.
pub fn sourceRange(text: []const u8, range: gitdiff.Range) SourceRange {
    std.debug.assert(range.lo <= range.hi);
    std.debug.assert(!range.empty or range.lo == range.hi);
    std.debug.assert(text.len <= std.math.maxInt(u32));
    const line = @max(range.lo, 1);
    const line_end = @max(range.hi, line);
    const start = sourceLineStart(text, line);
    if (range.empty) return .{
        .line = range.lo,
        .line_end = range.hi,
        .start = @intCast(start),
        .end = @intCast(start),
        .text = text[start..start],
        .empty = true,
    };
    var end = sourceLineEnd(text, line_end);
    while (end > start and text[end - 1] == '\r') end -= 1;
    std.debug.assert(start <= end and end <= text.len);
    return .{
        .line = range.lo,
        .line_end = range.hi,
        .start = @intCast(start),
        .end = @intCast(end),
        .text = text[start..end],
        .empty = false,
    };
}

fn sourceLineStart(text: []const u8, target: u32) usize {
    std.debug.assert(target > 0);
    var line: u32 = 1;
    var i: usize = 0;
    while (i < text.len and line < target) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    return i;
}

fn sourceLineEnd(text: []const u8, target: u32) usize {
    std.debug.assert(target > 0);
    const start = sourceLineStart(text, target);
    if (start == text.len) return start;
    const tail = text[start..];
    return start + (std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len);
}

fn renderExactSource(
    w: *Writer,
    idx: *const Index,
    changes: []const gitdiff.FileChange,
    patch: []const u8,
) !bool {
    std.debug.assert(idx.graph.files.len == idx.file_stats.len);
    if (patch.len == 0) return false;
    try w.writeAll("\n# exact current-source ranges\n");
    for (changes) |change| {
        const file = findDiffFile(idx, change.path) orelse continue;
        try w.print("## {s}\n", .{change.path});
        for (change.ranges) |range| {
            const mapped = sourceRange(file.text, range);
            try w.print("@@ lines {d}-{d}, bytes {d}-{d}, empty={} @@\n", .{
                mapped.line, mapped.line_end, mapped.start, mapped.end, mapped.empty,
            });
            if (mapped.text.len != 0) {
                try w.writeAll(mapped.text);
                try w.writeByte('\n');
            }
        }
    }
    try w.writeAll("\n# exact git patch\n");
    try w.writeAll(patch);
    if (patch[patch.len - 1] != '\n') try w.writeByte('\n');
    return true;
}

/// Render each changed file, its touched symbols, and their direct callers.
/// Returns whether at least one changed symbol was reported.
pub fn renderDiff(w: *Writer, idx: *const Index, changes: []const gitdiff.FileChange, opts: Options) !bool {
    var any_symbol = false;
    var shown: u32 = 0;
    for (changes) |change| {
        const file = findDiffFile(idx, change.path) orelse continue;
        var printed_header = false;
        var i = file.sym_start;
        while (i < file.sym_end and shown < opts.limit) : (i += 1) {
            const sym = idx.graph.symbols[i];
            if (sym.kind == .import) continue;
            if (!symbolTouched(sym, idx.graph.files[sym.file].text, change.ranges)) continue;
            if (!printed_header) {
                try w.print("# {s}\n", .{change.path});
                printed_header = true;
            }
            any_symbol = true;
            try w.writeAll("~ ");
            try render.symbol(w, idx, sym, headerVerbosity(opts.verbosity), 0, true);
            try renderBlastRadius(w, idx, sym.id);
            shown += 1;
        }
    }
    if (!any_symbol) {
        try w.writeAll("(no changed symbols — the diff is empty or touches only non-symbol lines)\n");
        return false;
    }
    try truncationNote(w, opts, shown);
    return true;
}

/// Print the deduplicated direct callers of a changed symbol (its blast radius),
/// or a leaf note when nothing calls it.
fn renderBlastRadius(w: *Writer, idx: *const Index, id: SymbolId) !void {
    var seen: std.AutoHashMap(SymbolId, void) = .init(idx.gpa);
    defer seen.deinit();
    var count: u32 = 0;
    for (idx.callersOf(id)) |cid| {
        const gop = try seen.getOrPut(cid);
        if (gop.found_existing) continue;
        try render.symbol(w, idx, idx.graph.symbols[cid], .sig, 1, true);
        count += 1;
    }
    if (count == 0) try indentLine(w, 1, "(no callers — leaf or entry point)\n");
}

/// Whether `sym`'s definition span overlaps any changed range (1-based lines).
pub fn symbolTouched(sym: model.Symbol, source: []const u8, ranges: []const gitdiff.Range) bool {
    const lo = sym.line;
    const hi = sym.endLine(source);
    for (ranges) |r| {
        const range_lo = if (r.empty and r.lo == 0) @as(u32, 1) else r.lo;
        const range_hi = if (r.empty and r.hi == 0) @as(u32, 1) else r.hi;
        if (range_lo <= hi and range_hi >= lo) return true;
    }
    return false;
}

/// The indexed file matching a diff path: exact root-relative match first, else a
/// path-suffix match (navgraph indexed a subdirectory of the repo, or vice
/// versa). Null when the changed file isn't indexed (non-source, ignored, …).
pub fn findDiffFile(idx: *const Index, diff_path: []const u8) ?model.SourceFile {
    for (idx.graph.files) |file| {
        if (std.mem.eql(u8, file.path, diff_path)) return file;
    }
    var suffix_match: ?model.SourceFile = null;
    for (idx.graph.files) |file| {
        if (!pathSuffixMatch(file.path, diff_path)) continue;
        if (suffix_match != null) return null;
        suffix_match = file;
    }
    return suffix_match;
}

/// Whether `a` and `b` name the same file via a component-aligned suffix
/// (`src/foo.zig` matches `pkg/src/foo.zig`), guarding against `bar.zig` matching
/// `foobar.zig` by requiring the boundary to fall on a `/`.
fn pathSuffixMatch(a: []const u8, b: []const u8) bool {
    if (std.mem.endsWith(u8, a, b)) return a.len == b.len or a[a.len - b.len - 1] == '/';
    if (std.mem.endsWith(u8, b, a)) return b.len == a.len or b[b.len - a.len - 1] == '/';
    return false;
}

/// Show `name`'s callees and callers together (each one level deep) — a quick
/// "what's around this symbol" view without choosing a direction.
/// Returns whether `name` resolved to at least one symbol.
pub fn neighbors(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.neighbors(w, idx, name, opts);
    var buf: [64]SymbolId = undefined;
    const ids = resolveIds(idx, name, &buf);
    if (ids.len == 0) {
        try w.print("(no symbol named '{s}')\n", .{name});
        try suggestNear(w, idx, name);
        try skippedNote(w, idx);
        return false;
    }
    try multiMatchNote(w, name, ids.len, ids.len == buf.len);
    var impl_graph: ?impls_mod.Graph = if (opts.impls) try impls_mod.build(idx.gpa, idx) else null;
    defer if (impl_graph) |*graph| graph.deinit();
    var budget: WalkBudget = .{};
    var visited: std.AutoHashMap(SymbolId, void) = .init(idx.gpa);
    defer visited.deinit();
    var heuristic: usize = 0;
    for (ids) |id| {
        if (!budget.take(idx, id, opts)) continue;
        const v: render.Verbosity = if (opts.summary) .names else opts.verbosity;
        try render.symbol(w, idx, idx.graph.symbols[id], v, 0, true);
        // Each direction is its own walk from the root, so `-d` counts edges
        // followed while the children stay indented under their heading.
        try w.writeAll("  ↓ calls\n");
        visited.clearRetainingCapacity();
        _ = try visited.getOrPut(id);
        try walkCallees(w, idx, if (impl_graph) |*g| g else null, id, opts, 1, 0, &visited, &heuristic, &budget);
        try w.writeAll("  ↑ callers\n");
        visited.clearRetainingCapacity();
        _ = try visited.getOrPut(id);
        try walkCallers(w, idx, if (impl_graph) |*g| g else null, id, opts, 1, 0, &visited, &heuristic, &budget);
    }
    if (budget.pruned != 0) try w.print("… {} branch{s} elided (--budget/--max-nodes; {} nodes shown)\n", .{ budget.pruned, if (budget.pruned == 1) "" else "es", budget.nodes });
    return budget.nodes != 0;
}

/// List functions/methods that have no callers — candidate dead code. Exported
/// symbols may legitimately be external API, so they are marked, not hidden.
/// Returns whether any unused candidate was reported.
pub fn unused(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.unused(w, idx, filter, opts);
    var refs = try buildReferencedNames(idx);
    defer refs.deinit();
    if (opts.unused_follow_imports) refs.scope = try buildCollisionScope(idx);
    var shown: u32 = 0;
    var hidden_exported: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (!try isDeadCandidateScoped(idx, sym, filter, &refs, opts.tests)) continue;
        if (!deadCandidateShown(idx, sym, opts, &refs)) {
            hidden_exported += 1; // only `--no-public` hides a candidate now
            continue;
        }
        try render.symbol(w, idx, sym, opts.verbosity, 0, true);
        // Under `--no-tests` a name reached only from tests is a genuine cleanup
        // target with no application caller — flag it; otherwise warn when the
        // name smells like interface dispatch (uncounted by the call graph),
        // then note public API.
        if (refs.testsContains(familyOf(idx, sym), sym.name)) {
            const sites = testCallerCount(idx, sym.id);
            if (sites > 0) {
                try w.print("  (only used by tests — {d} test caller{s})\n", .{ sites, if (sites == 1) "" else "s" });
            } else {
                try w.writeAll("  (only used by tests)\n");
            }
        } else if (interfaceDispatchHint(idx, sym)) |hint| {
            try w.print("  ({s} — verify before removing)\n", .{hint});
        } else if (externalBaseOf(idx, sym)) |base| {
            // `_WindowsConsoleReader(io.RawIOBase).readinto` has no in-repo
            // caller because the *stdlib* calls it. Say so instead of letting
            // it read as plain dead code (4 of 5 hits in a Python trial).
            try w.print("  (method of a class extending external '{s}' — may be framework-invoked)\n", .{base});
        } else if (callsRoutes(sym)) {
            // Caller-less but issues HTTP calls: likely a UI/event entry point
            // the in-repo call graph can't see (a trial misread one as dead).
            try w.writeAll("  (calls HTTP routes — may be an entry point wired outside the graph)\n");
        } else if (sym.exported) {
            try w.writeAll("  (exported — may be public API)\n");
        } else {
            try w.writeByte('\n');
        }
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (opts.tests != .with and !indexHasTests(idx)) {
        try w.writeAll("  (note: no test files detected in this index — test-scope flags have nothing to exclude)\n");
    }
    // `-C one-file.go` builds a one-file index: every cross-file caller is out
    // of view, so widely-used symbols read as dead. Say so (a trial was misled).
    if (shown > 0 and idx.graph.files.len == 1) {
        try w.writeAll("  (note: single-file index — callers in other files aren't visible; scope -C to the project to confirm)\n");
    }
    if (shown == 0) {
        try w.print("(no unused functions under '{s}')\n", .{filter});
        // The default (`--tests with`) reports only code used *nowhere*, which is
        // often empty in a well-tested repo. Point at the wider views so an empty
        // result isn't mistaken for a failure.
        if (opts.tests == .with) {
            try w.writeAll("  (default lists only code used nowhere; try --no-tests " ++
                "for code used only by tests, or --tests-only for unused test helpers)\n");
        }
        try skippedNote(w, idx);
    }
    if (hidden_exported > 0) {
        try w.print("  ({d} exported symbol(s) hidden by --no-public — re-run without it to audit public API)\n", .{hidden_exported});
    }
    try truncationNote(w, opts, shown);
    return shown > 0;
}

/// Names used *somewhere*, decided by an identifier-token count rather than the
/// resolved call graph. A name counts as used within a language family when its
/// identifier appears more times across that family's files than the number of
/// definitions carrying it there — i.e. it appears somewhere beyond its own
/// declaration(s). The per-family scope is the fix for the name-collision false
/// negative: a `getOptions` used in a Python backend can no longer mask a dead
/// `getOptions` in a TS frontend, since NavGraph never resolves a reference
/// across families.
///
/// This is deliberately independent of body-scoping: it re-lexes every file and
/// tallies identifier tokens, so a use inside a Zig `test {}` block, a JS
/// module-scope statement, JSX (`<App/>`), an import, or a body NavGraph parses
/// only partially still counts. `unused` relies on this to avoid reporting live
/// code as dead — the false positive that makes the whole verb untrustworthy.
/// It ignores comments and strings (the lexer classifies those separately), so
/// it is stricter than a raw `grep`. Caller owns the returned maps.
/// Usage is split by production vs test code: `prod` holds names used outside
/// test files; `tests` holds names *used* (not just imported) inside test files.
/// `unused` treats a name absent from its family's `prod` as dead, and annotates
/// it "(only used by tests)" when it is in `tests`.
/// Number of language families (buckets the usage tally is scoped by).
const family_count = @typeInfo(language.Family).@"enum".fields.len;

/// Membership is scoped *per language family* because NavGraph only resolves a
/// reference against files in the same family: a `getOptions` used in a Python
/// backend is not a use of a `getOptions` defined in a TS frontend. Scoping the
/// tally by family stops such a cross-family (or cross-package, same-named) twin
/// from masking genuinely-dead code — the name-collision false negative.
pub const RefSets = struct {
    prod: [family_count]std.StringHashMap(void),
    tests: [family_count]std.StringHashMap(void),
    /// Present only under `--follow-imports`: import-reachability data used to
    /// resolve same-name collisions the family-wide tally can't disambiguate.
    scope: ?CollisionScope = null,

    pub fn deinit(self: *RefSets) void {
        for (&self.prod) |*m| m.deinit();
        for (&self.tests) |*m| m.deinit();
        if (self.scope) |*s| s.deinit();
    }

    /// Whether `name` is used by production code within `fam`.
    pub fn prodContains(self: *const RefSets, fam: language.Family, name: []const u8) bool {
        return self.prod[@intFromEnum(fam)].contains(name);
    }

    /// Whether `name` is used by test code within `fam`.
    pub fn testsContains(self: *const RefSets, fam: language.Family, name: []const u8) bool {
        return self.tests[@intFromEnum(fam)].contains(name);
    }
};

/// The language family of the file that defines `sym`.
pub fn familyOf(idx: *const Index, sym: model.Symbol) language.Family {
    return idx.graph.files[sym.file].language.family();
}

pub fn buildReferencedNames(idx: *const Index) !RefSets {
    const gpa = idx.gpa;
    // Per-family definition counts (a name's own declaration isn't a use): a name
    // defined N times in a family needs N+1 occurrences there to count as used.
    var def_counts: [family_count]std.StringHashMap(u32) = undefined;
    for (&def_counts) |*m| m.* = std.StringHashMap(u32).init(gpa);
    defer for (&def_counts) |*m| m.deinit();
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (isTestPath(idx.graph.files[sym.file].path)) continue;
        const gop = try def_counts[@intFromEnum(familyOf(idx, sym))].getOrPut(sym.name);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
    }

    // Per-family identifier-token occurrences, split into production vs test.
    var occ_prod: [family_count]std.StringHashMap(u32) = undefined;
    var occ_test: [family_count]std.StringHashMap(u32) = undefined;
    for (&occ_prod) |*m| m.* = std.StringHashMap(u32).init(gpa);
    for (&occ_test) |*m| m.* = std.StringHashMap(u32).init(gpa);
    defer for (&occ_prod) |*m| m.deinit();
    defer for (&occ_test) |*m| m.deinit();
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(gpa);
    for (idx.graph.files) |file| {
        toks.clearRetainingCapacity();
        lexer.tokenize(gpa, file.text, language.configFor(file.language), &toks) catch continue;
        const fam = @intFromEnum(file.language.family());
        try tallyUses(toks.items, file.text, file.language, &occ_prod[fam], &occ_test[fam], isTestPath(file.path));
    }

    var result: RefSets = .{ .prod = undefined, .tests = undefined };
    for (&result.prod) |*m| m.* = std.StringHashMap(void).init(gpa);
    for (&result.tests) |*m| m.* = std.StringHashMap(void).init(gpa);
    errdefer result.deinit();
    for (0..family_count) |f| {
        var pit = occ_prod[f].iterator();
        while (pit.next()) |e| {
            const defs = def_counts[f].get(e.key_ptr.*) orelse 0;
            if (e.value_ptr.* > defs) try result.prod[f].put(e.key_ptr.*, {});
        }
        var tit = occ_test[f].keyIterator();
        while (tit.next()) |k| try result.tests[f].put(k.*, {});
    }
    return result;
}

/// Import-reachability data for resolving same-name collisions (`--follow-imports`).
/// Because NavGraph's resolver guesses which same-named twin a bare call binds to,
/// the resolved graph can't be trusted for collisions; this reconstructs "is this
/// specific definition used" from import edges + per-file textual use.
pub const CollisionScope = struct {
    /// Names defined more than once within a family (the ambiguous set).
    colliding: [family_count]std.StringHashMap(void),
    /// Per file: the colliding names actually *used* (occurrences beyond the
    /// definitions) in that file. Re-exports are not uses (tallyUses skips them).
    file_uses: []std.StringHashMap(void),
    /// Reverse import edges: `rev_imports[F]` lists the files that import `F`.
    rev_imports: [][]model.FileId,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *CollisionScope) void {
        for (&self.colliding) |*m| m.deinit();
        for (self.file_uses) |*m| m.deinit();
        self.gpa.free(self.file_uses);
        for (self.rev_imports) |list| self.gpa.free(list);
        self.gpa.free(self.rev_imports);
    }

    fn isColliding(self: *const CollisionScope, fam: language.Family, name: []const u8) bool {
        return self.colliding[@intFromEnum(fam)].contains(name);
    }
};

/// Build the `--follow-imports` collision data: which names collide per family,
/// where each colliding name is used, and the reverse import graph.
pub fn buildCollisionScope(idx: *const Index) !CollisionScope {
    const gpa = idx.gpa;
    var colliding: [family_count]std.StringHashMap(void) = undefined;
    for (&colliding) |*m| m.* = std.StringHashMap(void).init(gpa);
    errdefer for (&colliding) |*m| m.deinit();
    try fillColliding(idx, &colliding);

    const file_uses = try buildFileUses(idx, &colliding);
    errdefer {
        for (file_uses) |*m| m.deinit();
        gpa.free(file_uses);
    }
    const rev_imports = try buildReverseImports(idx);
    return .{ .colliding = colliding, .file_uses = file_uses, .rev_imports = rev_imports, .gpa = gpa };
}

/// Mark every name defined ≥2 times (in non-test files) within a family colliding.
fn fillColliding(idx: *const Index, colliding: *[family_count]std.StringHashMap(void)) !void {
    var counts: [family_count]std.StringHashMap(u32) = undefined;
    for (&counts) |*m| m.* = std.StringHashMap(u32).init(idx.gpa);
    defer for (&counts) |*m| m.deinit();
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (isTestPath(idx.graph.files[sym.file].path)) continue;
        const f = @intFromEnum(familyOf(idx, sym));
        const gop = try counts[f].getOrPut(sym.name);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
        if (gop.value_ptr.* == 2) try colliding[f].put(sym.name, {});
    }
}

/// Per file, the set of colliding names *used* there (token occurrences exceed
/// the definitions of that name in the file — a real use, not just the decl).
fn buildFileUses(idx: *const Index, colliding: *const [family_count]std.StringHashMap(void)) ![]std.StringHashMap(void) {
    const gpa = idx.gpa;
    const file_defs = try perFileCollidingDefs(idx, colliding);
    defer {
        for (file_defs) |*m| m.deinit();
        gpa.free(file_defs);
    }
    var uses = try gpa.alloc(std.StringHashMap(void), idx.graph.files.len);
    for (uses) |*m| m.* = std.StringHashMap(void).init(gpa);
    errdefer {
        for (uses) |*m| m.deinit();
        gpa.free(uses);
    }
    var occ = std.StringHashMap(u32).init(gpa);
    defer occ.deinit();
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(gpa);
    for (idx.graph.files) |file| {
        occ.clearRetainingCapacity();
        toks.clearRetainingCapacity();
        lexer.tokenize(gpa, file.text, language.configFor(file.language), &toks) catch continue;
        // Route both buckets to one map: we want total uses per name, prod+test.
        try tallyUses(toks.items, file.text, file.language, &occ, &occ, false);
        const fam = @intFromEnum(file.language.family());
        var it = occ.iterator();
        while (it.next()) |e| {
            if (!colliding[fam].contains(e.key_ptr.*)) continue;
            const defs = file_defs[file.id].get(e.key_ptr.*) orelse 0;
            if (e.value_ptr.* > defs) try uses[file.id].put(e.key_ptr.*, {});
        }
    }
    return uses;
}

/// Per file, the number of definitions of each colliding name (subtracted from
/// occurrences so a name's own declaration doesn't read as a use).
fn perFileCollidingDefs(idx: *const Index, colliding: *const [family_count]std.StringHashMap(void)) ![]std.StringHashMap(u32) {
    const gpa = idx.gpa;
    var defs = try gpa.alloc(std.StringHashMap(u32), idx.graph.files.len);
    for (defs) |*m| m.* = std.StringHashMap(u32).init(gpa);
    errdefer {
        for (defs) |*m| m.deinit();
        gpa.free(defs);
    }
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (!colliding[@intFromEnum(familyOf(idx, sym))].contains(sym.name)) continue;
        const gop = try defs[sym.file].getOrPut(sym.name);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
    }
    return defs;
}

/// Reverse of the import table: `rev[F]` = files that import `F` (gpa-owned).
fn buildReverseImports(idx: *const Index) ![][]model.FileId {
    const gpa = idx.gpa;
    const n = idx.graph.files.len;
    var counts = try gpa.alloc(u32, n);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (idx.graph.files) |file| {
        for (idx.importsOf(file.id)) |imp| counts[imp.target] += 1;
    }
    var rev = try gpa.alloc([]model.FileId, n);
    for (rev, 0..) |*slot, i| slot.* = try gpa.alloc(model.FileId, counts[i]);
    @memset(counts, 0);
    for (idx.graph.files) |file| {
        for (idx.importsOf(file.id)) |imp| {
            rev[imp.target][counts[imp.target]] = file.id;
            counts[imp.target] += 1;
        }
    }
    return rev;
}

/// Whether a colliding symbol is used anywhere it is *reachable* — its own file
/// or any file that (transitively) imports it. Over-approximating reachability
/// (transitive importers) is deliberate: it can only mask dead code, never flag
/// live code, so a missing import edge won't manufacture a false positive here.
fn reachablyUsed(scope: *const CollisionScope, idx: *const Index, sym: model.Symbol) !bool {
    var visited = std.AutoHashMap(model.FileId, void).init(scope.gpa);
    defer visited.deinit();
    var stack: std.ArrayList(model.FileId) = .empty;
    defer stack.deinit(scope.gpa);
    try stack.append(scope.gpa, sym.file);
    while (stack.pop()) |fid| {
        const gop = try visited.getOrPut(fid);
        if (gop.found_existing) continue;
        std.debug.assert(fid < idx.graph.files.len);
        if (scope.file_uses[fid].contains(sym.name)) return true;
        for (scope.rev_imports[fid]) |importer| {
            if (!visited.contains(importer)) try stack.append(scope.gpa, importer);
        }
    }
    return false;
}

fn bumpOccurrence(occ: *std.StringHashMap(u32), name: []const u8) !void {
    const gop = try occ.getOrPut(name);
    gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
}

/// Tally identifier occurrences in one file into the production (`prod`) or test
/// (`tst`) bucket, skipping names that only appear in an import/export
/// *declaration* — an ESM `import {…}`/`export {…}`, a CommonJS
/// `module.exports = {…}` / `exports.x`, or a Python `from x import …`. A merely
/// re-exported or imported name is a mention, not a use; counting it would hide
/// genuinely-dead code (a re-exported function nobody calls). A JS/TS template
/// literal's `${…}` interpolations are scanned so a call used only there still
/// counts.
///
/// `file_is_test` selects the default bucket for the whole file (Python/JS keep
/// tests in separate files, caught by `isTestPath`). Zig is the exception: it
/// keeps tests inline as `test {}` blocks *inside* production files, so an
/// identifier used only from a `test {}` block must still count as test-only, not
/// production. For a Zig file we track brace depth and route identifiers inside a
/// `test {}` block to `tst` regardless of `file_is_test`.
fn tallyUses(
    toks: []const lexer.Token,
    text: []const u8,
    lang: language.Language,
    prod: *std.StringHashMap(u32),
    tst: *std.StringHashMap(u32),
    file_is_test: bool,
) !void {
    const js = switch (lang) {
        .javascript, .typescript, .tsx => true,
        else => false,
    };
    const py = lang == .python;
    const zig = lang == .zig;
    const default_bucket = if (file_is_test) tst else prod;
    // Zig `test {}` tracking: `test_level` is the brace depth at which the active
    // test block opened (-1 = not inside one); `pending_test` marks a seen `test`
    // keyword whose opening `{` hasn't arrived yet (its name tokens count as test).
    var brace_depth: i32 = 0;
    var test_level: i32 = -1;
    var pending_test = false;
    var i: usize = 0;
    while (i < toks.len) {
        const t = toks[i];
        if (zig) {
            if (t.kind == .punct) {
                switch (text[t.start]) {
                    '{' => {
                        brace_depth += 1;
                        if (pending_test) {
                            test_level = brace_depth - 1;
                            pending_test = false;
                        }
                    },
                    '}' => {
                        brace_depth -= 1;
                        if (test_level >= 0 and brace_depth <= test_level) test_level = -1;
                    },
                    else => {},
                }
                i += 1;
                continue;
            }
            if (t.kind == .identifier and test_level < 0 and !pending_test and zigTestBlockStart(toks, text, i)) {
                pending_test = true;
                i += 1;
                continue;
            }
        }
        if (t.kind == .string) {
            const s = t.text(text);
            if (js and s.len != 0 and s[0] == '`') try addTemplateIdents(s, default_bucket);
            i += 1;
            continue;
        }
        if (t.kind != .identifier) {
            i += 1;
            continue;
        }
        const bucket = if (zig and (test_level >= 0 or pending_test)) tst else default_bucket;
        if (js and jsDeclHead(toks, text, i)) {
            i = try scanJsDecl(toks, text, i, bucket);
            continue;
        }
        if (py and (tokIs(toks, text, i, "import") or tokIs(toks, text, i, "from"))) {
            i = try scanPyStmt(toks, text, i, bucket);
            continue;
        }
        // A JS/TS object-literal property key (`{ count: v }`) names a field, not
        // a use of a same-named symbol — don't count it toward "used" (mirrors the
        // parser's edge suppression, so a dead fn isn't masked by an object key).
        if (js and i > 0 and punctIs(toks, text, i + 1, ':') and
            (punctIs(toks, text, i - 1, '{') or punctIs(toks, text, i - 1, ',')))
        {
            i += 1;
            continue;
        }
        // A decorator application lexes as one `@name` token (the lexer treats
        // `@` as an identifier byte for Zig builtins). For decorator languages
        // strip it so `@websocket_handler` counts as a use of `websocket_handler`
        // — otherwise a live decorator function reads as dead.
        const name = decoratorName(t.text(text), zig);
        if (name.len >= 2) try bumpOccurrence(bucket, name);
        i += 1;
    }
}

/// The effective identifier a token references. For non-Zig languages a leading
/// `@` is a decorator/attribute sigil (`@handler`, C# `@class`), not part of the
/// name, so it is stripped. Zig keeps `@` — `@import`/`@fieldParentPtr` are
/// builtins whose whole spelling is the token.
fn decoratorName(tok: []const u8, zig: bool) []const u8 {
    if (zig or tok.len < 2 or tok[0] != '@') return tok;
    return tok[1..];
}

/// True when token `i` begins a Zig `test {}` block: the `test` keyword, an
/// optional name (a `"string"` or an identifier path like `decltest.Foo`), then
/// `{`. Requiring the trailing `{` keeps a stray `test` identifier from being
/// misread as a block start.
fn zigTestBlockStart(toks: []const lexer.Token, text: []const u8, i: usize) bool {
    if (!tokIs(toks, text, i, "test")) return false;
    var j = i + 1;
    if (j < toks.len and toks[j].kind == .string) {
        j += 1;
    } else {
        while (j < toks.len and toks[j].kind == .identifier) {
            j += 1;
            if (!punctIs(toks, text, j, '.')) break;
            j += 1;
        }
    }
    return punctIs(toks, text, j, '{');
}

fn tokIs(toks: []const lexer.Token, text: []const u8, i: usize, kw: []const u8) bool {
    return i < toks.len and toks[i].kind == .identifier and std.mem.eql(u8, toks[i].text(text), kw);
}

fn punctIs(toks: []const lexer.Token, text: []const u8, i: usize, c: u8) bool {
    return i < toks.len and toks[i].kind == .punct and text[toks[i].start] == c;
}

/// Head of a JS/TS import/export declaration whose listed names are mentions, not
/// uses: `import …`, `export {`/`export *`/`export type {`, or CommonJS
/// `module.exports` / `exports.…`. `export function/const/class …` (a definition)
/// is not one — its name is a real symbol handled elsewhere.
fn jsDeclHead(toks: []const lexer.Token, text: []const u8, i: usize) bool {
    if (tokIs(toks, text, i, "import")) return true;
    if (tokIs(toks, text, i, "export")) {
        var j = i + 1;
        if (tokIs(toks, text, j, "type")) j += 1;
        return punctIs(toks, text, j, '{') or punctIs(toks, text, j, '*');
    }
    if (tokIs(toks, text, i, "module") and punctIs(toks, text, i + 1, '.') and tokIs(toks, text, i + 2, "exports")) return true;
    if (tokIs(toks, text, i, "exports") and punctIs(toks, text, i + 1, '.')) return true;
    return false;
}

/// Walk a JS/TS import/export declaration, counting only the *original* name of
/// a rename (`X as Y` — X is used via its alias Y, e.g. `removeRequests as
/// apiRemoveRequests`), and skipping the plain listed names. Returns the index
/// just past the declaration (a closed `{…}` list, a `from "module"` string, or
/// a `;`).
fn scanJsDecl(toks: []const lexer.Token, text: []const u8, start: usize, occ: *std.StringHashMap(u32)) !usize {
    var j = start + 1;
    var depth: i32 = 0;
    var opened = false;
    while (j < toks.len) : (j += 1) {
        const t = toks[j];
        try countIfAlias(toks, text, j, occ);
        if (t.kind == .punct) {
            switch (text[t.start]) {
                '{', '(', '[' => {
                    depth += 1;
                    opened = true;
                },
                '}', ')', ']' => depth -= 1,
                ';' => if (depth <= 0) return j + 1,
                else => {},
            }
        } else if (t.kind == .string and depth <= 0) {
            return j + 1; // the `from "module"` path ends an import / re-export
        }
        if (opened and depth <= 0) return j + 1; // a `{…}` list closed with no trailing `from`
    }
    return j;
}

/// Walk a Python `import …` / `from x import …` statement (respecting a `(`
/// continuation), counting the original name of an `a as b` rename; returns the
/// first token index of the next statement.
fn scanPyStmt(toks: []const lexer.Token, text: []const u8, start: usize, occ: *std.StringHashMap(u32)) !usize {
    var j = start + 1;
    const line = toks[start].line;
    var depth: i32 = 0;
    while (j < toks.len) : (j += 1) {
        const t = toks[j];
        try countIfAlias(toks, text, j, occ);
        if (t.kind == .punct) {
            switch (text[t.start]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                else => {},
            }
        }
        if (depth <= 0 and t.line != line) return j;
    }
    return j;
}

/// If token `j` begins an `IDENT as IDENT` rename, count the first identifier —
/// it's the real definition, used here under an alias.
fn countIfAlias(toks: []const lexer.Token, text: []const u8, j: usize, occ: *std.StringHashMap(u32)) !void {
    if (toks[j].kind != .identifier) return;
    if (!tokIs(toks, text, j + 1, "as")) return;
    if (j + 2 >= toks.len or toks[j + 2].kind != .identifier) return;
    const name = toks[j].text(text);
    if (name.len >= 2) try bumpOccurrence(occ, name);
}

fn isIdentStartByte(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}

fn isIdentContByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// Tally identifier tokens inside a JS/TS template literal's `${…}`
/// interpolations (bracket-balanced) into `occ`, so a name used only from a
/// template still counts as referenced.
fn addTemplateIdents(text: []const u8, occ: *std.StringHashMap(u32)) !void {
    var i: usize = 0;
    while (i + 1 < text.len) {
        if (text[i] != '$' or text[i + 1] != '{') {
            i += 1;
            continue;
        }
        i += 2;
        var depth: usize = 1;
        while (i < text.len and depth > 0) {
            const c = text[i];
            if (c == '{') {
                depth += 1;
                i += 1;
            } else if (c == '}') {
                depth -= 1;
                i += 1;
            } else if (isIdentStartByte(c)) {
                const s = i;
                i += 1;
                while (i < text.len and isIdentContByte(text[i])) i += 1;
                const name = text[s..i];
                if (name.len >= 2) try bumpOccurrence(occ, name);
            } else {
                i += 1;
            }
        }
    }
}

/// Kinds `unused` will report as possible dead code: callables plus type-like
/// definitions (a class/struct/enum/interface/type never referenced anywhere is
/// dead too — instantiation, inheritance and type annotations all count as uses
/// in `buildReferencedNames`, so a truly-unreferenced type is a safe report).
/// Deliberately excludes fields/variables/constants/imports/modules: those are
/// noisier and usually not what a dead-code audit targets.
fn isReportableDeadKind(kind: model.SymbolKind) bool {
    return switch (kind) {
        .function, .method, .class, .@"struct", .@"enum", .interface, .type => true,
        else => false,
    };
}

/// A symbol worth reporting as possibly-unused under the given test `scope`:
///   `with`    — dead in the whole graph (used by neither production nor tests);
///               test code itself is never a candidate (its blocks are entry
///               points). This is `unused`'s default: "what is truly dead".
///   `without` — dead in production only (test usage ignored, so a test-only-used
///               symbol surfaces — annotated by the caller); test code is not a
///               candidate.
///   `only`    — a dead *test helper*: a symbol in test code that nothing calls
///               (test entry points — `test` blocks and `test_*` — are excluded).
/// Always excludes obvious entry points (`main`, dunders, `constructor`, pytest
/// `test_*`, decorated functions/methods). `refs` is `buildReferencedNames`.
pub fn isDeadCandidateScoped(
    idx: *const Index,
    sym: model.Symbol,
    filter: []const u8,
    refs: *const RefSets,
    scope: TestScope,
) !bool {
    if (!isReportableDeadKind(sym.kind)) return false;
    if (std.mem.eql(u8, sym.name, "main")) return false;
    // Framework/entry-point callables are invoked implicitly, never by name:
    // dunder methods (`__init__`), a JS/TS `constructor` (`new`), pytest `test_*`.
    if (isDunder(sym.name)) return false;
    if (std.mem.eql(u8, sym.name, "constructor")) return false;
    if (std.mem.startsWith(u8, sym.name, "test_")) return false;
    // A decorated *function/method* is wired in by the decorator, not called by
    // name (`@app.on_event`, `@pytest.fixture`) — treat it like a route handler.
    // A decorated *class* (`@dataclass`) IS referenced by name, so a dead one is
    // still reported.
    if ((sym.kind == .function or sym.kind == .method) and precededByDecorator(idx, sym)) return false;
    const is_test = isTestSymbol(idx, sym);
    if (scope == .only) {
        // Dead *test* code: a test-scope symbol (helper) that nothing references.
        // Uses the resolved graph — which now counts `test` blocks as callers —
        // rather than the name-tally, whose test bucket includes a symbol's own
        // definition (test-file defs are not subtracted).
        if (!is_test) return false;
        if (idx.callersOf(sym.id).len != 0) return false;
        return matchesFilter(idx.graph.files[sym.file].path, filter);
    }
    // with/without: only production code is a candidate.
    if (is_test) return false;
    // Usage via the safe name-tally: `without` ignores test usage; `with` counts
    // it (a symbol a test uses is not dead). A false "dead" report costs trust.
    const used = switch (scope) {
        .without => try symbolUsed(idx, sym, refs),
        .with => (try symbolUsed(idx, sym, refs)) or refs.testsContains(familyOf(idx, sym), sym.name),
        .only => unreachable,
    };
    if (used) return false;
    return matchesFilter(idx.graph.files[sym.file].path, filter);
}

/// Whether `sym` counts as used. By default this is the safe family-wide name
/// tally. Under `--follow-imports` a *colliding* name (defined more than once in
/// its family, which the tally can't disambiguate) is instead resolved by import
/// reachability, so a dead symbol isn't masked by a used same-name twin.
fn symbolUsed(idx: *const Index, sym: model.Symbol, refs: *const RefSets) !bool {
    const fam = familyOf(idx, sym);
    if (refs.scope) |*scope| {
        if (scope.isColliding(fam, sym.name)) return reachablyUsed(scope, idx, sym);
    }
    return refs.prodContains(fam, sym.name);
}

/// Apply the `unused` visibility filter to a symbol already known to be a dead
/// candidate: `--no-public` (`unused_skip_exported`) drops exported symbols, which
/// may be public API rather than dead. The test axis is handled upstream by the
/// `--tests` scope in `isDeadCandidateScoped`. `refs` is unused here (kept for a
/// stable signature).
pub fn deadCandidateShown(idx: *const Index, sym: model.Symbol, opts: Options, refs: *const RefSets) bool {
    _ = idx;
    _ = refs;
    std.debug.assert(isReportableDeadKind(sym.kind));
    std.debug.assert(sym.name.len != 0);
    return !(opts.unused_skip_exported and sym.exported);
}

/// A `__dunder__` name (implicitly invoked by the language/runtime).
fn isDunder(name: []const u8) bool {
    return name.len >= 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
}

/// Max non-blank lines scanned above a definition when looking for a decorator —
/// enough for a multi-line decorator's argument list without runaway cost.
const decorator_scan_lines = 24;

/// True when a decorator (`@…`) sits just above `sym`'s definition — a cheap
/// signal that the symbol is framework-invoked (a route/handler/fixture) rather
/// than called by name. Scans the contiguous block of non-blank lines
/// immediately above the def, so it catches both the single-line form
/// (`@app.get("/x")`) and a multi-line decorator whose closing `)` sits on its
/// own line above the def. A blank line ends the block (decorators are adjacent
/// to what they decorate), bounding the scan and avoiding a stray `@` far above.
fn precededByDecorator(idx: *const Index, sym: model.Symbol) bool {
    const text = idx.graph.files[sym.file].text;
    if (sym.span_start == 0 or sym.span_start > text.len) return false;
    // Start of the definition's own line.
    var ls = sym.span_start;
    while (ls > 0 and text[ls - 1] != '\n') ls -= 1;
    var scanned: u32 = 0;
    while (ls > 0 and scanned < decorator_scan_lines) : (scanned += 1) {
        // The previous line's terminating '\n' is at ls-1; its content is
        // text[ps .. ls-1].
        var ps = ls - 1;
        while (ps > 0 and text[ps - 1] != '\n') ps -= 1;
        const line = text[ps .. ls - 1];
        // A blank line ends the contiguous block directly above the def.
        if (isBlankLine(line)) return false;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len != 0 and trimmed[0] == '@') return true;
        if (ps == 0) return false;
        ls = ps;
    }
    return false;
}

/// A line containing only whitespace.
fn isBlankLine(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t' and c != '\r') return false;
    return true;
}

/// Whether `path` is a test/fixture module: its functions are invoked by the
/// framework/harness, not referenced by name, so `unused` treats a symbol used
/// only from here as "used only by tests" rather than production-live.
///
/// Recognized across every language — the file conventions (pytest `test_*.py`,
/// jest/vitest `*.test.ts`/`*.spec.tsx`, Zig/C/C++ `*_test.zig`/`*_test.cc`) and
/// the directory conventions (`tests/`, `test/`, `__tests__/`, `spec/`, `e2e/`).
/// The directory check is what stops a test *helper* file with a plain name
/// (`tests/util.py`, `__tests__/render.tsx`) from reading as production and
/// under-reporting the dead code that only its siblings use.
fn isTestPath(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| if (isTestDirName(comp)) return true;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |s| path[s + 1 ..] else path;
    if (std.mem.eql(u8, base, "conftest.py")) return true;
    if (std.mem.startsWith(u8, base, "test_")) return true;
    // Suffix conventions, keyed on the stem so any code extension counts:
    // `foo_test.<ext>`, `foo_spec.<ext>`, `foo.test.<ext>`, `foo.spec.<ext>`.
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
    const stem = base[0..dot];
    inline for (.{ "_test", "_spec", ".test", ".spec" }) |suf| {
        if (std.mem.endsWith(u8, stem, suf)) return true;
    }
    return false;
}

/// A path component that conventionally holds tests/fixtures in any ecosystem.
fn isTestDirName(comp: []const u8) bool {
    inline for (.{ "tests", "test", "__tests__", "__mocks__", "spec", "e2e", "testdata" }) |d| {
        if (std.mem.eql(u8, comp, d)) return true;
    }
    return false;
}

/// List, per in-scope file, the local modules it imports (resolved edges only).
/// Returns whether any in-scope file had imports to report.
/// The `-l` cap for a list that had no limit before it was declared: `null`
/// unless the caller actually asked for one, so default output is unchanged.
pub fn listCap(opts: Options) ?u32 {
    return if (opts.limit_set) opts.limit else null;
}

pub fn listImports(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.listImports(w, idx, filter, opts);
    var any = false;
    var shown: u32 = 0;
    var elided: u32 = 0;
    for (idx.graph.files) |file| {
        const imps = idx.importsOf(file.id);
        if (imps.len == 0 or !matchesFilter(file.path, filter)) continue;
        any = true;
        if (listCap(opts)) |cap| if (shown >= cap) {
            elided += 1;
            continue;
        };
        shown += 1;
        try w.print("# {s}\n", .{file.path});
        for (imps) |imp| {
            try w.print("  → {s}", .{idx.graph.files[imp.target].path});
            if (imp.binding.len != 0) try w.print("  ({s})", .{imp.binding});
            try w.writeByte('\n');
        }
    }
    if (elided != 0) try w.print("… {d} more file{s} elided (-l {d})\n", .{ elided, if (elided == 1) "" else "s", opts.limit });
    if (!any) try w.print("(no local imports under '{s}')\n", .{filter});
    return any;
}

/// List files that import the file(s) matching `path` — reverse dependencies.
/// Returns whether any importer was found.
pub fn listImporters(w: *Writer, idx: *const Index, path: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.listImporters(w, idx, path, opts);
    var any = false;
    var shown: u32 = 0;
    var elided: u32 = 0;
    for (idx.graph.files) |target| {
        if (!matchesFilter(target.path, path)) continue;
        var printed_header = false;
        for (idx.graph.files) |src| {
            if (!fileImports(idx, src.id, target.id)) continue;
            if (!printed_header) {
                any = true;
                if (listCap(opts)) |cap| if (shown >= cap) {
                    elided += 1;
                    break;
                };
                shown += 1;
                try w.print("# {s} ← imported by\n", .{target.path});
                printed_header = true;
            }
            try w.print("  {s}\n", .{src.path});
        }
    }
    if (elided != 0) try w.print("… {d} more file{s} elided (-l {d})\n", .{ elided, if (elided == 1) "" else "s", opts.limit });
    if (!any) try w.print("(no importers of '{s}')\n", .{path});
    return any;
}

fn fileImports(idx: *const Index, src: model.FileId, target: model.FileId) bool {
    for (idx.importsOf(src)) |imp| if (imp.target == target) return true;
    return false;
}

/// Print the shortest call path from `from_name` to `to_name` (BFS over call
/// edges), or a "no path" note. Renders the chain as an indented cascade.
/// Returns whether a call path was found (both names must resolve; false when
/// resolved but disconnected, i.e. "no call path from A to B").
pub fn shortestPath(w: *Writer, idx: *const Index, from_name: []const u8, to_name: []const u8, opts: Options) !bool {
    if (opts.format == .json) return json_out.shortestPath(w, idx, from_name, to_name, opts);
    var fbuf: [64]SymbolId = undefined;
    var tbuf: [64]SymbolId = undefined;
    const from_ids = resolveIds(idx, from_name, &fbuf);
    const to_ids = resolveIds(idx, to_name, &tbuf);
    if (from_ids.len > 1) return renderAmbiguousPathEndpoint(w, idx, "from", from_name, to_name, from_ids, fbuf.len);
    if (to_ids.len > 1) return renderAmbiguousPathEndpoint(w, idx, "to", from_name, to_name, to_ids, tbuf.len);
    const chain = try shortestPathIdsWithOptions(idx, from_name, to_name, &fbuf, &tbuf, opts);
    defer idx.gpa.free(chain);
    if (chain.len == 0) {
        // Distinguish "name unknown" (a lookup miss) from "genuinely no path"
        // (a real negative answer) — an agent acts differently on each.
        var probe: [1]SymbolId = undefined;
        inline for (.{ from_name, to_name }) |nm| {
            if (resolveIds(idx, nm, &probe).len == 0) {
                try w.print("(no symbol named '{s}')\n", .{nm});
                try suggestNear(w, idx, nm);
                return false;
            }
        }
        try w.print("(no call path from '{s}' to '{s}')\n", .{ from_name, to_name });
        return false;
    }
    for (chain, 0..) |id, indent| {
        const v = if (indent == 0) opts.verbosity else headerVerbosity(opts.verbosity);
        try render.symbol(w, idx, idx.graph.symbols[id], v, indent, true);
    }
    return true;
}

/// Refuse to run a semantic BFS from an arbitrary same-named definition.  The
/// candidate list is itself useful discovery output, while each `try` row is a
/// ready-to-call selector that preserves the original opposite endpoint.
fn renderAmbiguousPathEndpoint(
    w: *Writer,
    idx: *const Index,
    endpoint: []const u8,
    from_name: []const u8,
    to_name: []const u8,
    ids: []const SymbolId,
    capacity: usize,
) !bool {
    const selector = if (std.mem.eql(u8, endpoint, "from")) from_name else to_name;
    try w.print("(ambiguous path {s} endpoint '{s}': {d}{s} candidates — pin one; no path was traversed)\n", .{
        endpoint, selector, ids.len, if (ids.len == capacity) "+" else "",
    });
    const shown = @min(ids.len, 12);
    for (ids[0..shown]) |id| {
        try render.symbol(w, idx, idx.graph.symbols[id], .names, 1, true);
        try w.writeAll("    try: navgraph path ");
        if (std.mem.eql(u8, endpoint, "from")) {
            try writePinnedPathSelector(w, idx, id);
            try w.print(" {s}\n", .{to_name});
        } else {
            try w.print("{s} ", .{from_name});
            try writePinnedPathSelector(w, idx, id);
            try w.writeByte('\n');
        }
    }
    if (ids.len > shown) try w.print("  … {d} more candidates\n", .{ids.len - shown});
    return false;
}

fn writePinnedPathSelector(w: *Writer, idx: *const Index, id: SymbolId) !void {
    const sym = idx.graph.symbols[id];
    if (sym.parent != invalid) try w.print("{s}.", .{idx.graph.symbols[sym.parent].name});
    try w.print("{s}@{s}", .{ sym.name, idx.graph.files[sym.file].path });
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
    return shortestPathIdsWithOptions(idx, from_name, to_name, fbuf, tbuf, .{});
}

pub fn shortestPathIdsWithOptions(
    idx: *const Index,
    from_name: []const u8,
    to_name: []const u8,
    fbuf: []SymbolId,
    tbuf: []SymbolId,
    opts: Options,
) ![]SymbolId {
    const from_ids = resolveIds(idx, from_name, fbuf);
    const to_ids = resolveIds(idx, to_name, tbuf);
    // A semantic path is authoritative only when both endpoints are unique.
    // Callers that want discovery receive candidates from the rendering/API
    // layer and retry with Parent.name/name@path; never seed BFS arbitrarily.
    if (from_ids.len != 1 or to_ids.len != 1) return idx.gpa.alloc(SymbolId, 0);
    var impl_graph: ?impls_mod.Graph = if (opts.impls) try impls_mod.build(idx.gpa, idx) else null;
    defer if (impl_graph) |*graph| graph.deinit();
    const prev = try bfsPrev(idx, from_ids, to_ids, opts.strict, if (impl_graph) |*g| g else null);
    defer idx.gpa.free(prev);
    const end = firstReached(prev, to_ids) orelse return idx.gpa.alloc(SymbolId, 0);
    return reconstruct(idx.gpa, prev, end);
}

const FlowSearch = struct { prev: []SymbolId, reached: ?SymbolId };

/// Walk `prev` from `end` back to its source, returning the path source-first.
fn bfsFlow(idx: *const Index, from_ids: []const SymbolId, to_ids: []const SymbolId, strict: bool) !FlowSearch {
    std.debug.assert(from_ids.len > 0);
    std.debug.assert(to_ids.len > 0);
    const n = idx.graph.symbols.len;
    var prev = try idx.gpa.alloc(SymbolId, n);
    errdefer idx.gpa.free(prev);
    @memset(prev, invalid);
    var queue = std.array_list.Managed(SymbolId).init(idx.gpa);
    defer queue.deinit();
    for (from_ids) |source| {
        prev[source] = source;
        try queue.append(source);
    }
    var reached: ?SymbolId = null;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (contains(to_ids, cur) and !contains(from_ids, cur)) {
            reached = cur;
            break;
        }
        for (idx.graph.symbols[cur].refs) |ref| {
            if (ref.target == invalid or (strict and !ref.exact) or prev[ref.target] != invalid) continue;
            prev[ref.target] = cur;
            try queue.append(ref.target);
        }
        const kind = idx.graph.symbols[cur].kind;
        if (kind != .field and kind != .variable and kind != .constant) continue;
        for (idx.graph.symbols) |owner| for (owner.refs) |ref| {
            if (ref.write or ref.target != cur or (strict and !ref.exact) or prev[owner.id] != invalid) continue;
            prev[owner.id] = cur;
            try queue.append(owner.id);
        };
    }
    return .{ .prev = prev, .reached = reached };
}

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
fn bfsPrev(
    idx: *const Index,
    from_ids: []const SymbolId,
    to_ids: []const SymbolId,
    strict: bool,
    impl_graph: ?*const impls_mod.Graph,
) ![]SymbolId {
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
        if (impl_graph) |graph| {
            for (graph.edges) |edge| {
                if (strict and !edge.exact) continue;
                const next = if (edge.port_method == cur)
                    edge.implementation_method
                else if (edge.implementation_method == cur)
                    edge.port_method
                else
                    continue;
                if (prev[next] != invalid) continue;
                prev[next] = cur;
                try queue.append(next);
            }
        }
    }
    return prev;
}

fn firstReached(prev: []const SymbolId, to_ids: []const SymbolId) ?SymbolId {
    for (to_ids) |t| if (prev[t] != invalid) return t;
    return null;
}

pub fn contains(ids: []const SymbolId, id: SymbolId) bool {
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
    if (isGlobPattern(name)) return resolveGlob(idx, name, buf);
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

/// Resolve a glob name (`Ba*`, `parse*Scope`, `Matcher.is*`) by scanning every
/// definition. A dotted glob matches the parent part against the enclosing
/// symbol's name and the child part against the member's own name.
fn resolveGlob(idx: *const Index, pattern: []const u8, buf: []SymbolId) []const SymbolId {
    var parent_pat: ?[]const u8 = null;
    var name_pat = pattern;
    if (std.mem.lastIndexOfScalar(u8, pattern, '.')) |dot| {
        parent_pat = pattern[0..dot];
        name_pat = pattern[dot + 1 ..];
    }
    var n: usize = 0;
    for (idx.graph.symbols) |sym| {
        if (n == buf.len) break;
        if (sym.kind == .import) continue;
        if (!exactOrGlob(name_pat, sym.name)) continue;
        if (parent_pat) |pp| {
            if (sym.parent == invalid) continue;
            if (!exactOrGlob(pp, idx.graph.symbols[sym.parent].name)) continue;
        }
        buf[n] = sym.id;
        n += 1;
    }
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
    // A `Parent.child` selector is an explicit scoping request: if no member
    // named `child` exists directly under a symbol named `parent`, report
    // not-found rather than silently falling back to a bare `child` lookup that
    // would resolve to an unrelated same-named symbol in a different container.
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

    // `orphan` is called by nobody and named nowhere → dead candidate; `gamma`
    // is called → not.
    var ref_names = try buildReferencedNames(&idx);
    defer ref_names.deinit();
    const orphan = idx.graph.symbols[idx.lookup("orphan")[0]];
    const gamma = idx.graph.symbols[idx.lookup("gamma")[0]];
    try testing.expect(try isDeadCandidateScoped(&idx, orphan, "", &ref_names, .without));
    try testing.expect(!try isDeadCandidateScoped(&idx, gamma, "", &ref_names, .without));
}

test "calls hides var/const data reads by default, shows them with --refs; graph stays symmetric" {
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

    // Default `calls run`: the call to `helper` shows; the `LIMIT` const read is
    // dependency noise and is hidden.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "run", false, .{ .depth = 1 });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "helper") != null);
        try testing.expect(std.mem.indexOf(u8, out, "LIMIT") == null);
    }
    // `--refs` opts the data read back in.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "run", false, .{ .depth = 1, .refs = true });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "helper") != null);
        try testing.expect(std.mem.indexOf(u8, out, "LIMIT") != null);
    }

    // The graph is unchanged: `LIMIT`'s callers still include `run` (the edge is
    // only hidden from the default callee *view*, not dropped from the index).
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
    try std.testing.expect(kindAllowed(.module, "module"));
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
        _ = try walk(&aw.writer, &idx, "helper", true, .{ .depth = 1 });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "↳:5") != null);
    }

    // `search helper --refs` lists the use site at line 5 inside `run`.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try search(&aw.writer, &idx, "helper", .{ .refs = true });
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
        _ = try walk(&aw.writer, &idx, "run", false, .{ .depth = 1 });
        try testing.expect(std.mem.indexOf(u8, aw.written(), " ?") != null);
        // A footer nudges the agent to `-s` instead of leaving it to guess.
        try testing.expect(std.mem.indexOf(u8, aw.written(), "re-run with -s") != null);
    }
    // `--strict` follows only confident edges, so the guess is dropped entirely
    // (no callee line, hence no `?`), and no footer is printed.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "run", false, .{ .depth = 1, .strict = true });
        try testing.expect(std.mem.indexOf(u8, aw.written(), " ?") == null);
        try testing.expect(std.mem.indexOf(u8, aw.written(), "re-run with -s") == null);
    }
}

test "OO dispatch stays out of unused; hot reports its heuristic fan-in honestly" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `create_run` is dispatched via a chained, untyped receiver
    // (`self.planning.create_run(...)`) — the OO pattern that made the repo-scale
    // trials flag live methods as dead.
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
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var idbuf: [8]SymbolId = undefined;
    const cr_ids = resolveIds(&idx, "PlanningService.create_run", &idbuf);
    try testing.expectEqual(@as(usize, 1), cr_ids.len);
    const create_run = idx.graph.symbols[cr_ids[0]];

    // The dispatch heuristic gives it a caller, so it is NOT dead code.
    var ref_names = try buildReferencedNames(&idx);
    defer ref_names.deinit();
    try testing.expect(!try isDeadCandidateScoped(&idx, create_run, "", &ref_names, .without));
    try testing.expect(idx.callersOf(create_run.id).len > 0);

    // Its fan-in is entirely heuristic: total > 0, exact == 0.
    const ranked = try collectHot(&idx, "", .with);
    defer idx.gpa.free(ranked);
    var found = false;
    for (ranked) |e| {
        if (e.id != create_run.id) continue;
        found = true;
        try testing.expect(e.fan_in > 0);
        try testing.expectEqual(@as(u32, 0), e.fan_in_exact);
    }
    try testing.expect(found);

    // Default `hot` qualifies the inflated count with `(N ?)`.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try hot(&aw.writer, &idx, "", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "?)") != null);
    }
    // `--strict` drops a symbol whose connectivity is entirely heuristic.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try hot(&aw.writer, &idx, "", .{ .strict = true });
        try testing.expect(std.mem.indexOf(u8, aw.written(), "create_run") == null);
    }
}

test "unused: a helper used only via a template literal or past JSX prose is not dead" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `tmpl` is called only inside a template literal; `afterProse` only after a
    // JSX apostrophe; `reallyDead` nowhere. The first two must stay out of the
    // report (they're live), the third must be in it.
    try tmp.dir.writeFile(io, .{ .sub_path = "View.tsx", .data =
        \\function tmpl(x: string): string { return x; }
        \\function afterProse(): number { return 1; }
        \\function reallyDead(): number { return 0; }
        \\export function View({ n }: { n: string }) {
        \\  return (
        \\    <div>
        \\      <p>you'll see {afterProse()} items, don't fret</p>
        \\      <span>{`label ${tmpl(n)}`}</span>
        \\    </div>
        \\  );
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "reallyDead") != null);
    try testing.expect(std.mem.indexOf(u8, out, "afterProse") == null);
    try testing.expect(std.mem.indexOf(u8, out, "tmpl") == null);
}

test "unused: a class never instantiated is dead; an instantiated one is live" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "models.py", .data =
        \\class UsedThing:
        \\    pass
        \\
        \\class DeadThing:
        \\    pass
        \\
        \\def make():
        \\    return UsedThing()
        \\
        \\print(make())
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "DeadThing") != null);
    try testing.expect(std.mem.indexOf(u8, out, "UsedThing") == null);
}

test "unused: a Java record's positional parameter is not read as an external base" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `record PricedLine(Product product, ...)` carries a positional parameter
    // list, not an inheritance clause. The unused annotator must not mistake the
    // `product` parameter for an external base and label `unitCents` as
    // framework-invoked; it is plain (exported) dead code here.
    try tmp.dir.writeFile(io, .{ .sub_path = "PricedLine.java", .data =
        \\package shop;
        \\public record PricedLine(Product product, int quantity, int totalCents) {
        \\    public int unitCents() { return totalCents / quantity; }
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "unitCents") != null);
    try testing.expect(std.mem.indexOf(u8, out, "framework-invoked") == null);
}

test "unused: a dead symbol is flagged despite a used same-name twin in another language" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A TS frontend `getOptions` nothing calls, and a Python backend `getOptions`
    // that IS used. The tally is scoped per language family, so the used Python
    // twin must not mask the dead TS wrapper (the name-collision false negative).
    try tmp.dir.writeFile(io, .{ .sub_path = "endpoints.ts", .data =
        \\export const getOptions = () => fetch("/options");
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "service.py", .data =
        \\def getOptions():
        \\    return 1
        \\def handler():
        \\    return getOptions()
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var refs = try buildReferencedNames(&idx);
    defer refs.deinit();
    var tbuf: [8]SymbolId = undefined;
    var pbuf: [8]SymbolId = undefined;
    const ts_ids = resolveIds(&idx, "getOptions@endpoints.ts", &tbuf);
    const py_ids = resolveIds(&idx, "getOptions@service.py", &pbuf);
    try testing.expect(ts_ids.len == 1 and py_ids.len == 1);
    // Dead in the JS family, live in the Python family — scoped independently.
    try testing.expect(try isDeadCandidateScoped(&idx, idx.graph.symbols[ts_ids[0]], "", &refs, .without));
    try testing.expect(!try isDeadCandidateScoped(&idx, idx.graph.symbols[py_ids[0]], "", &refs, .without));
}

test "unused --follow-imports flags a same-family dead twin the tally masks" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Two same-family `getOptions`; a consumer imports and uses only b's. The
    // family tally sees the name used and masks both; import reachability must
    // flag a's (unimported) while keeping b's (used via import) live. A barrel
    // re-export exercises transitive reachability (b reached through index.ts).
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data =
        \\export const getOptions = () => 1;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.ts", .data =
        \\export const getOptions = () => 2;
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "index.ts", .data =
        \\export { getOptions } from "./b";
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "consumer.ts", .data =
        \\import { getOptions } from "./index";
        \\export function run() { return getOptions(); }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var abuf: [8]SymbolId = undefined;
    var bbuf: [8]SymbolId = undefined;
    const a_id = resolveIds(&idx, "getOptions@a.ts", &abuf)[0];
    const b_id = resolveIds(&idx, "getOptions@b.ts", &bbuf)[0];

    // Default: family tally masks both (each is "used" because the name is used).
    var refs = try buildReferencedNames(&idx);
    defer refs.deinit();
    try testing.expect(!try isDeadCandidateScoped(&idx, idx.graph.symbols[a_id], "", &refs, .without));
    try testing.expect(!try isDeadCandidateScoped(&idx, idx.graph.symbols[b_id], "", &refs, .without));

    // --follow-imports: a is unreachable (dead), b is used via the barrel (live).
    var scoped = try buildReferencedNames(&idx);
    defer scoped.deinit();
    scoped.scope = try buildCollisionScope(&idx);
    try testing.expect(try isDeadCandidateScoped(&idx, idx.graph.symbols[a_id], "", &scoped, .without));
    try testing.expect(!try isDeadCandidateScoped(&idx, idx.graph.symbols[b_id], "", &scoped, .without));
}

test "unused: a multi-line decorator suppresses a framework-wired handler" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `ws_handler` is never called by name; its multi-line decorator wires it in.
    // `plain_dead` has no decorator and must still surface.
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\@app.websocket(
        \\    "/ws",
        \\)
        \\async def ws_handler():
        \\    return 1
        \\
        \\def plain_dead():
        \\    return 2
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "ws_handler") == null);
    try testing.expect(std.mem.indexOf(u8, out, "plain_dead") != null);
}

test "unused: a decorator function applied as @name is live, not dead" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `register` is applied as `@register` — a use the token `@register` must
    // credit to `register`, not read as a separate name. `orphan` is truly dead.
    try tmp.dir.writeFile(io, .{ .sub_path = "bus.py", .data =
        \\def register(fn):
        \\    return fn
        \\
        \\@register
        \\def handler():
        \\    return 1
        \\
        \\def orphan():
        \\    return 2
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "register") == null);
    try testing.expect(std.mem.indexOf(u8, out, "orphan") != null);
}

test "unused: --no-public reports how many exported symbols it hid" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "api.ts", .data =
        \\export function deadPublic(): number { return 1; }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{ .unused_skip_exported = true });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "deadPublic") == null);
    try testing.expect(std.mem.indexOf(u8, out, "hidden by --no-public") != null);
}

test "unused: a name only re-exported/imported is dead; called or aliased-and-used is live" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.ts", .data =
        \\export function reExportedDead() { return 0; }
        \\export function calledDirectly() { return 1; }
        \\export function renamedLive() { return 2; }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "consumer.ts", .data =
        \\import { calledDirectly, renamedLive as aliasUsed } from "./lib";
        \\export function run() { return calledDirectly() + aliasUsed(); }
    });
    // A barrel that only *re-exports* the name — a mention, not a call.
    try tmp.dir.writeFile(io, .{ .sub_path = "barrel.ts", .data =
        \\export { reExportedDead } from "./lib";
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{});
    const out = aw.written();
    // Only re-exported through a barrel, never called → dead.
    try testing.expect(std.mem.indexOf(u8, out, "reExportedDead") != null);
    // Imported and called → live.
    try testing.expect(std.mem.indexOf(u8, out, "calledDirectly") == null);
    // Imported under an alias that IS called → live.
    try testing.expect(std.mem.indexOf(u8, out, "renamedLive") == null);
}

test "unused: used-only-from-tests is flagged and annotated; production use is not" {
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
    // A test module (basename `test_*`) whose only production reference is a call
    // to `helper_tested_only` — the "no application caller" cleanup target.
    try tmp.dir.writeFile(io, .{ .sub_path = "test_lib.py", .data =
        \\from lib import helper_tested_only
        \\def test_it():
        \\    assert helper_tested_only() == 2
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    // `--no-tests` is the production-focused view: test usage does not count, so a
    // test-only-used symbol surfaces, annotated.
    _ = try unused(&aw.writer, &idx, "", .{ .tests = .without });
    const out = aw.written();
    // Used in production → not reported.
    try testing.expect(std.mem.indexOf(u8, out, "prod_used") == null);
    // Reached only by a test → reported, and flagged as such.
    try testing.expect(std.mem.indexOf(u8, out, "helper_tested_only") != null);
    try testing.expect(std.mem.indexOf(u8, out, "only used by tests") != null);
    // Referenced nowhere → reported (plainly, no test annotation of its own).
    try testing.expect(std.mem.indexOf(u8, out, "truly_dead") != null);
}

test "unused: default (--tests with) treats test usage as real; --tests-only finds dead test code" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.py", .data =
        \\def helper_tested_only():
        \\    return 2
        \\def truly_dead():
        \\    return 3
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "test_lib.py", .data =
        \\from lib import helper_tested_only
        \\def dead_test_helper():
        \\    return 9
        \\def test_it():
        \\    assert helper_tested_only() == 2
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // Default `--tests with`: a symbol used by a test is NOT dead; only truly-dead.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try unused(&aw.writer, &idx, "", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "helper_tested_only") == null); // used by a test
        try testing.expect(std.mem.indexOf(u8, out, "truly_dead") != null); // used nowhere
    }
    // `--tests-only`: report dead code *in test files* (a helper no test calls).
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try unused(&aw.writer, &idx, "", .{ .tests = .only });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "dead_test_helper") != null); // dead test helper
        try testing.expect(std.mem.indexOf(u8, out, "truly_dead") == null); // production, out of test scope
    }
}

test "unused: a Zig fn used only inside an inline test {} block is test-only, not live" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Zig keeps tests inline, so `tested_only` is called only from a `test {}`
    // block *in a production file* — it must still be reported (test-only), not
    // hidden as if the block were production use.
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.zig", .data =
        \\fn prod_used() i32 {
        \\    return 1;
        \\}
        \\fn tested_only() i32 {
        \\    return 2;
        \\}
        \\fn truly_dead() i32 {
        \\    return 3;
        \\}
        \\pub fn entry() i32 {
        \\    return prod_used();
        \\}
        \\test "exercises the helper" {
        \\    _ = tested_only();
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{ .tests = .without });
    const out = aw.written();
    // Called from a production body → live.
    try testing.expect(std.mem.indexOf(u8, out, "prod_used") == null);
    // Called only from the inline `test {}` block → reported and annotated.
    try testing.expect(std.mem.indexOf(u8, out, "tested_only") != null);
    try testing.expect(std.mem.indexOf(u8, out, "only used by tests") != null);
    // Referenced nowhere → reported.
    try testing.expect(std.mem.indexOf(u8, out, "truly_dead") != null);
}

test "callers shows call-site multiplicity (×N) when a caller invokes the target repeatedly" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\def helper(x):
        \\    return x
        \\def dashboard():
        \\    return helper(1) + helper(2) + helper(3)
        \\def once():
        \\    return helper(9)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try walk(&aw.writer, &idx, "helper", true, .{ .depth = 1 });
    const out = aw.written();
    // `dashboard` calls it three times → the edge is annotated ×3, not collapsed
    // to a single call site; `once` (a single call) carries no multiplier.
    try testing.expect(std.mem.indexOf(u8, out, "×3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "once") != null);
}

test "callers lists every distinct call-site line when a caller hits the target on several lines" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `spread` calls `helper` on three *different* lines (4, 5, 6). The edge must
    // list each site — `↳:4,5,6` — not collapse to the first line with a bare ×3,
    // which is the precision a trial's grep agent beat navgraph on.
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\def helper(x):
        \\    return x
        \\def spread():
        \\    a = helper(1)
        \\    b = helper(2)
        \\    c = helper(3)
        \\    return a + b + c
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try walk(&aw.writer, &idx, "helper", true, .{ .depth = 1 });
    const out = aw.written();
    // Every distinct call-site line is shown, in order.
    try testing.expect(std.mem.indexOf(u8, out, "4,5,6") != null);
}

test "read: numbered lines, a range, and a non-indexed file via disk fallback" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\import os
        \\def a():
        \\    return 1
        \\def b():
        \\    return 2
    });
    // A non-indexed config (unknown language) must still be readable from disk.
    try tmp.dir.writeFile(io, .{ .sub_path = "conf.json", .data =
        \\{
        \\  "port": 8080
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // Indexed file, a line range: lines 2-3 numbered, line 1 excluded.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try readLines(&aw.writer, io, &idx, root, "m.py:2-3", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "2\tdef a():") != null);
        try testing.expect(std.mem.indexOf(u8, out, "3\t") != null);
        try testing.expect(std.mem.indexOf(u8, out, "import os") == null);
    }
    { // Non-indexed config: reached through the disk fallback.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try readLines(&aw.writer, io, &idx, root, "conf.json", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "\"port\": 8080") != null);
    }
}

test "files lists indexed files with their symbol counts" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data =
        \\def one():
        \\    return 1
        \\def two():
        \\    return 2
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try listFiles(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "a.py") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2 symbols") != null);
}

test "files --sort symbols ranks the file with more symbols first" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a_small.py", .data =
        \\def only():
        \\    return 1
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "z_big.py", .data =
        \\def a():
        \\    return 1
        \\def b():
        \\    return 2
        \\def c():
        \\    return 3
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try listFiles(&aw.writer, &idx, "", .{ .file_sort = .symbols });
    const out = aw.written();
    const big = std.mem.indexOf(u8, out, "z_big.py") orelse return error.TestUnexpectedResult;
    const small = std.mem.indexOf(u8, out, "a_small.py") orelse return error.TestUnexpectedResult;
    try testing.expect(big < small);

    var path_buf_out: std.ArrayList(u8) = .empty;
    defer path_buf_out.deinit(testing.allocator);
    var path_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &path_buf_out);
    defer path_writer.deinit();
    _ = try listFiles(&path_writer.writer, &idx, "", .{ .file_sort = .path });
    const path_out = path_writer.written();
    const path_big = std.mem.indexOf(u8, path_out, "z_big.py") orelse return error.TestUnexpectedResult;
    const path_small = std.mem.indexOf(u8, path_out, "a_small.py") orelse return error.TestUnexpectedResult;
    try testing.expect(path_small < path_big);
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

test "events pairs a decorator handler with an emitter across files" {
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
        \\    log("a plain message with spaces");
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try events(&aw.writer, &idx, "", .{});
    const out = aw.written();
    // The key groups both sites; the decorator handler binds to its function; the
    // spaced prose message is not treated as an event key.
    try testing.expect(std.mem.indexOf(u8, out, "event \"start\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "in handle_start") != null);
    try testing.expect(std.mem.indexOf(u8, out, "client.ts:2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "plain message") == null);
    try testing.expect(std.mem.indexOf(u8, out, "unpaired") == null);
}

test "diff maps a changed hunk to its symbol and lists the blast radius" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub fn helper() u32 {
        \\    return 1;
        \\}
        \\pub fn run() u32 {
        \\    return helper();
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // A synthetic hunk touching helper's body (line 2) — bypasses git so the test
    // has no external dependency; the git-output parser is covered in gitdiff.zig.
    var ranges = [_]gitdiff.Range{.{ .lo = 2, .hi = 2 }};
    var changes = [_]gitdiff.FileChange{.{ .path = "m.zig", .ranges = &ranges }};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try renderDiff(&aw.writer, &idx, &changes, .{});
    const out = aw.written();
    // helper is the changed symbol; run is its caller (the blast radius).
    try testing.expect(std.mem.indexOf(u8, out, "~ ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "helper") != null);
    try testing.expect(std.mem.indexOf(u8, out, "run") != null);
    // `run` itself (lines 4-6) is not touched, so it is not a top-level `~` entry.
    try testing.expect(std.mem.indexOf(u8, out, "~ pub fn run") == null and
        std.mem.indexOf(u8, out, "~ fn run") == null);
}

test "diff includes untracked supported source and exact new-file patch" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "base.zig", .data = "pub fn base() void {}\n" });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const Git = struct {
        fn ok(allocator: std.mem.Allocator, test_io: std.Io, cwd: []const u8, argv: []const []const u8) !void {
            const result = try gitutil.run(allocator, test_io, cwd, argv);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try testing.expect(result.term == .exited and result.term.exited == 0);
        }
    };
    try Git.ok(testing.allocator, io, root, &.{ "git", "init", "--quiet" });
    try Git.ok(testing.allocator, io, root, &.{ "git", "add", "--", "base.zig" });
    try Git.ok(testing.allocator, io, root, &.{
        "git", "-c", "user.name=NavGraph Test", "-c", "user.email=navgraph@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-verify", "-m", "base",
    });

    // Supported and not ignored: it is in the live index despite being absent
    // from HEAD. The unsupported note must not leak into the source diff.
    try tmp.dir.writeFile(io, .{ .sub_path = "fresh.zig", .data = "pub fn fresh() u32 { return 7; }\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not source\n" });
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try testing.expect(try diff(&aw.writer, io, &idx, root, "HEAD", .{ .exact_source = true }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "fresh") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "+++ b/fresh.zig") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "notes.txt") == null);
}

test "events marks a key with only one side unpaired and honors the filter" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data =
        \\function f() {
        \\    emitter.emit("only_emitted");
        \\    bus.on("paired");
        \\    bus.emit("paired");
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try events(&aw.writer, &idx, "only", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "only_emitted") != null);
    try testing.expect(std.mem.indexOf(u8, out, "unpaired") != null);
    // The filter excludes the paired key.
    try testing.expect(std.mem.indexOf(u8, out, "paired\"") == null);
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

    const ranked = try collectHot(&idx, "", .with);
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
    _ = try hot(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "shared") != null);
    try testing.expect(std.mem.indexOf(u8, out, "←3 callers") != null);
}

test "hot splits test callers from production callers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `shared` is called from one production file and one test file: the split
    // must read `[1 prod / 1 test]` so a test-only hub isn't mistaken for load-bearing.
    try tmp.dir.writeFile(io, .{ .sub_path = "core.zig", .data =
        \\pub fn shared() void {}
        \\pub fn prodCaller() void { shared(); }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "core_test.zig", .data =
        \\const core = @import("core.zig");
        \\pub fn testCaller() void { core.shared(); }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    const ranked = try collectHot(&idx, "", .with);
    defer idx.gpa.free(ranked);
    try testing.expectEqualStrings("shared", idx.graph.symbols[ranked[0].id].name);
    try testing.expectEqual(@as(u32, 1), ranked[0].fan_in_test);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try hot(&aw.writer, &idx, "", .{});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "[1 prod / 1 test]") != null);
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
    _ = try outline(&aw.writer, &idx, "", .{});
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

test "render surfaces accessor/async modifiers in the kind field" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.ts", .data =
        \\export class Store {
        \\  get value() { return 1; }
        \\  async load() { return 2; }
        \\}
        \\export async function boot() { return 3; }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // A getter reads as `get Store.value`, not a bare `method` (the false bug).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "value", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "get Store.value") != null);
        try testing.expect(std.mem.indexOf(u8, out, "method Store.value") == null);
    }
    { // `async` prefixes the tag for both a method and a free function.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "load", .{});
        _ = try showDef(&aw.writer, &idx, "boot", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "async method Store.load") != null);
        try testing.expect(std.mem.indexOf(u8, out, "async fn boot") != null);
    }
}

test "strings finds text inside string literals, never bare identifiers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "svc.py", .data =
        \\LOG_MSG = "gp data has not updated"
        \\def ping():
        \\    return "/api/health"
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\const URL = "/api/health";
        \\function log() { return "boot ok"; }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // The URL literal is found in both languages, with file:line.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try strings(&aw.writer, &idx, "/api/health", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "svc.py:3") != null);
        try testing.expect(std.mem.indexOf(u8, out, "client.ts:1") != null);
    }
    { // `LOG_MSG` is an identifier, not a literal — no match (stricter than grep).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try strings(&aw.writer, &idx, "LOG_MSG", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no string literal") != null);
    }
}

test "search --refs lists every distinct use-site line of a name" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // `helper` is used on three distinct lines inside one caller; all three sites
    // must be listed, not collapsed to the first (the recall gap a trial hit).
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub fn helper() u32 {
        \\    return 1;
        \\}
        \\pub fn run() u32 {
        \\    const a = helper();
        \\    const b = helper();
        \\    return a + b + helper();
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try search(&aw.writer, &idx, "helper", .{ .refs = true });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "m.zig:5") != null);
    try testing.expect(std.mem.indexOf(u8, out, "m.zig:6") != null);
    try testing.expect(std.mem.indexOf(u8, out, "m.zig:7") != null);
}

test "search --refs pins instance-attribute reads by receiver" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Two same-named fields on different receivers: `self.rows` must pin only the
    // instance reads, not `df.rows` — the attribute-tracking gap a trial hit.
    try tmp.dir.writeFile(io, .{ .sub_path = "t.py", .data =
        \\class Table:
        \\    def first(self):
        \\        return self.rows[0]
        \\    def count(self):
        \\        return len(self.rows)
        \\def external(df):
        \\    return df.rows
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try search(&aw.writer, &idx, "self.rows", .{ .refs = true });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "t.py:3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "t.py:5") != null);
    // `external`'s `df.rows` read (line 7) must be excluded by the receiver pin.
    try testing.expect(std.mem.indexOf(u8, out, "in external") == null);

    // The leading-dot form matches the attribute on any receiver.
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(testing.allocator);
    var aw2: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf2);
    defer aw2.deinit();
    _ = try search(&aw2.writer, &idx, ".rows", .{ .refs = true });
    try testing.expect(std.mem.indexOf(u8, aw2.written(), "in external") != null);
}

test "def -v full includes leading decorators and multi-line python literals" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\import functools
        \\GP_GROUPS = [
        \\    "stations",
        \\    "visual",
        \\]
        \\@functools.lru_cache
        \\@app.get("/x")
        \\def handler():
        \\    return GP_GROUPS
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // The handler's decorators are part of its `-v full` (a paste-ready target).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "handler", .{ .verbosity = .full });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "@functools.lru_cache") != null);
        try testing.expect(std.mem.indexOf(u8, out, "@app.get(\"/x\")") != null);
        try testing.expect(std.mem.indexOf(u8, out, "def handler") != null);
    }
    { // The list literal's contents are shown, not truncated at line 1.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "GP_GROUPS", .{ .verbosity = .full });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "stations") != null);
        try testing.expect(std.mem.indexOf(u8, out, "visual") != null);
    }
}

test "read: multiple comma-separated ranges with a gap marker" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\def a():
        \\    x = 1
        \\    y = 2
        \\    z = 3
        \\    w = 4
        \\    return x
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try readLines(&aw.writer, io, &idx, root, "m.py:1,4-5", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "1\tdef a():") != null);
    try testing.expect(std.mem.indexOf(u8, out, "4\t    z = 3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "5\t    w = 4") != null);
    // Lines outside the requested ranges are absent, and the gap is marked.
    try testing.expect(std.mem.indexOf(u8, out, "y = 2") == null);
    try testing.expect(std.mem.indexOf(u8, out, "⋯") != null);
}

test "read spec keeps colon filenames distinct and normalizes declared ranges" {
    var buf: [max_read_ranges]LineRange = undefined;

    const filename = try parseReadSpec("notes:archive", &buf);
    try std.testing.expectEqualStrings("notes:archive", filename.path);
    try std.testing.expectEqual(@as(usize, 0), filename.ranges.len);

    const parsed = try parseReadSpec("m.py:12,8-10,2-5,4-8", &buf);
    try std.testing.expectEqualStrings("m.py", parsed.path);
    try std.testing.expectEqual(@as(usize, 2), parsed.ranges.len);
    try std.testing.expectEqual(LineRange{ .lo = 2, .hi = 10 }, parsed.ranges[0]);
    try std.testing.expectEqual(LineRange{ .lo = 12, .hi = 12 }, parsed.ranges[1]);

    try std.testing.expectError(error.DescendingRange, parseReadSpec("m.py:100-50", &buf));
    try std.testing.expectError(error.MalformedRange, parseReadSpec("m.py:2-x", &buf));
    try std.testing.expectError(error.TooManyRanges, parseReadSpec("m.py:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17", &buf));
    try std.testing.expectEqualStrings("descending_range", readSpecErrorCode(error.DescendingRange));
    try std.testing.expectEqualStrings("range end must not precede its start", readSpecErrorMessage(error.DescendingRange));
}

test "read merges overlapping ranges and never emits duplicate lines" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\one = 1
        \\two = 2
        \\three = 3
        \\four = 4
        \\five = 5
        \\six = 6
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try testing.expect(try readLines(&aw.writer, io, &idx, root, "m.py:4-6,2-4,1-2", .{}));
    const out = aw.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "1\tone = 1\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "2\ttwo = 2\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "3\tthree = 3\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "4\tfour = 4\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "5\tfive = 5\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "6\tsix = 6\n"));
}

test "read pages whole files and explicit selections with a selected-line cursor" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "page.py", .data =
        \\one = 1  # source paging fixture row
        \\two = 2  # source paging fixture row
        \\three = 3  # source paging fixture row
        \\four = 4  # source paging fixture row
        \\five = 5  # source paging fixture row
        \\six = 6  # source paging fixture row
        \\seven = 7  # source paging fixture row
        \\eight = 8  # source paging fixture row
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try readLines(&aw.writer, io, &idx, root, "page.py", .{ .limit = 3 }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "1\tone = 1") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "3\tthree = 3") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "4\tfour = 4") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "truncated: 3 of 8") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "next: --after v1:3") != null);

    aw.clearRetainingCapacity();
    try testing.expect(try readLines(&aw.writer, io, &idx, root, "page.py", .{ .limit = 3, .after = 3, .after_set = true }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "3\tthree = 3") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "4\tfour = 4") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "6\tsix = 6") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "next: --after v1:6") != null);

    // The cursor is an ordinal in the normalized selection: offset 2 begins at
    // physical line 6 for the disjoint selection 2-3,6-8.
    aw.clearRetainingCapacity();
    try testing.expect(try readLines(&aw.writer, io, &idx, root, "page.py:6-8,2-3", .{ .limit = 2, .after = 2, .after_set = true }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "3\tthree = 3") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "6\tsix = 6") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "7\tseven = 7") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "next: --after v1:4") != null);

    aw.clearRetainingCapacity();
    try testing.expect(try readLines(&aw.writer, io, &idx, root, "page.py", .{ .limit = 8, .budget = 160 }));
    try testing.expect(aw.written().len <= 160);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "1\tone = 1") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "2\ttwo = 2") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "next: --after v1:1") != null);

    aw.clearRetainingCapacity();
    try testing.expect(try readLines(&aw.writer, io, &idx, root, "page.py", .{ .limit = 8, .budget = 400, .format = .json }));
    try testing.expect(aw.written().len <= 400);
    var json_page = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer json_page.deinit();
    try testing.expect(json_page.value.object.get("truncated").?.bool);
    try testing.expect(json_page.value.object.get("next").? == .string);
    const json_lines = json_page.value.object.get("lines").?.array.items;
    try testing.expect(json_lines.len > 0 and json_lines.len < 8);

    // Even a budget too small for one complete JSON source row returns a valid
    // bounded JSON diagnostic rather than a chopped envelope.
    aw.clearRetainingCapacity();
    try testing.expect(!try readLines(&aw.writer, io, &idx, root, "page.py", .{ .limit = 8, .budget = 64, .format = .json }));
    try testing.expect(aw.written().len <= 64);
    var budget_error = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer budget_error.deinit();
    try testing.expectEqualStrings("budget_too_small", budget_error.value.object.get("error").?.string);
}

test "read whole-file default returns the first 300-line page" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    var source_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &source);
    defer source_writer.deinit();
    for (1..306) |line| try source_writer.writer.print("line {d}\n", .{line});
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = source_writer.written() });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try testing.expect(try readLines(&aw.writer, io, &idx, root, "large.txt", .{}));
    try testing.expectEqual(@as(usize, 300), std.mem.count(u8, aw.written(), "\tline "));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "300\tline 300") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "301\tline 301") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "next: --after v1:300") != null);
}

test "read validation errors are typed in text and do not probe fake filenames" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data = "value = 1\n" });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(!try readLines(&aw.writer, io, &idx, root, "m.py:100-50", .{}));
    try testing.expectEqualStrings("(read error [descending_range]: range end must not precede its start; got '100-50')\n", aw.written());

    aw.clearRetainingCapacity();
    try testing.expect(!try readLines(&aw.writer, io, &idx, root, "m.py:1-x", .{}));
    try testing.expectEqualStrings("(read error [malformed_range]: expected positive line ranges A, A-B, or A-; got '1-x')\n", aw.written());

    aw.clearRetainingCapacity();
    try testing.expect(!try readLines(&aw.writer, io, &idx, root, "m.py:1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17", .{}));
    try testing.expectEqualStrings("(read error [too_many_ranges]: at most 16 source ranges are allowed; got '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17')\n", aw.written());
}

test "unused: a prod fn used only from a tests/ directory is test-only (dir scope)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.py", .data =
        \\def prod_fn():
        \\    return 1
        \\def helper_target():
        \\    return 2
        \\def entry():
        \\    return prod_fn()
    });
    // A test *helper* with a plain filename, recognized as test scope only via
    // its `tests/` directory — before dir-based scope this would have counted as
    // production and hidden `helper_target` from the dead-code report.
    try tmp.dir.createDirPath(io, "tests");
    try tmp.dir.writeFile(io, .{ .sub_path = "tests/support.py", .data =
        \\from lib import helper_target
        \\def exercise():
        \\    return helper_target()
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try unused(&aw.writer, &idx, "", .{ .tests = .without });
    const out = aw.written();
    // Used only from a tests/ helper → reported and flagged.
    try testing.expect(std.mem.indexOf(u8, out, "helper_target") != null);
    try testing.expect(std.mem.indexOf(u8, out, "only used by tests") != null);
    // Used by production → not reported.
    try testing.expect(std.mem.indexOf(u8, out, "prod_fn") == null);
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
    // Directory-based test layouts (any language), even with a plain filename.
    try std.testing.expect(isTestPath("tests/util.py"));
    try std.testing.expect(isTestPath("web/__tests__/render.tsx"));
    try std.testing.expect(isTestPath("app/e2e/flow.ts"));
    try std.testing.expect(isTestPath("pkg/spec/parser.js"));
    // More suffix conventions across languages.
    try std.testing.expect(isTestPath("src/parser_test.zig"));
    try std.testing.expect(isTestPath("core/widget_test.cc"));
    // A prod dir/name that merely contains "test" is not a test path.
    try std.testing.expect(!isTestPath("src/test_utils/format.py"));
    try std.testing.expect(!isTestPath("src/contest.py"));
}

// ============================================================================
// APPENDED TESTS — verb coverage: pure helpers, outline/listFiles/readLines,
// showDef/walk/search not-found + selectors, neighbors, routes, imports,
// shortestPath, hot limits. (No overlap with the existing test blocks.)
// ============================================================================

test "matchesFilter: empty matches all, prefix and substring hit, mismatch misses" {
    try std.testing.expect(matchesFilter("src/api.zig", "")); // empty filter → all
    try std.testing.expect(matchesFilter("src/api.zig", "src/")); // prefix
    try std.testing.expect(matchesFilter("src/api.zig", "api")); // interior substring
    try std.testing.expect(matchesFilter("src/api.zig", ".zig")); // suffix (as substring)
    try std.testing.expect(!matchesFilter("src/api.zig", "queue")); // absent
    try std.testing.expect(!matchesFilter("a", "abc")); // filter longer than path
}

test "matchesFilter: glob patterns — basename without slash, whole path with slash" {
    // No `/` in the pattern → glob against the basename, at any depth.
    try std.testing.expect(matchesFilter("src/api_test.zig", "*_test.zig"));
    try std.testing.expect(matchesFilter("deep/nested/api_test.zig", "*_test.zig"));
    try std.testing.expect(!matchesFilter("src/api.zig", "*_test.zig"));
    // A `/` in the pattern → glob against the whole relative path.
    try std.testing.expect(matchesFilter("src/api.zig", "src/*.zig"));
    try std.testing.expect(!matchesFilter("src/sub/api.zig", "src/*.zig")); // `*` stays in one segment
    try std.testing.expect(matchesFilter("src/sub/api.zig", "src/**/*.zig")); // `**` crosses
    try std.testing.expect(!matchesFilter("lib/api.zig", "src/*.zig"));
}

test "matchesName: substring without star, whole-name glob with star" {
    try std.testing.expect(matchesName("solve", "resolveIds")); // substring
    try std.testing.expect(!matchesName("resolve*", "chooseTarget"));
    try std.testing.expect(matchesName("resolve*", "resolveIds")); // prefix glob
    try std.testing.expect(matchesName("*Ids", "resolveIds")); // suffix glob
    try std.testing.expect(matchesName("re*Ids", "resolveIds")); // interior glob
    try std.testing.expect(!matchesName("solve*", "resolveIds")); // glob is anchored
    try std.testing.expect(matchesName("empty?", "empty?")); // lone `?` stays literal (Ruby)
    try std.testing.expect(!matchesName("empty?", "emptyX"));
}

test "parseLineRange: single, A-B, open-ended A-, and rejected forms" {
    // Single line.
    const one = try parseLineRange("7");
    try std.testing.expectEqual(@as(usize, 7), one.lo);
    try std.testing.expectEqual(@as(usize, 7), one.hi);
    // Bounded range.
    const rng = try parseLineRange("3-9");
    try std.testing.expectEqual(@as(usize, 3), rng.lo);
    try std.testing.expectEqual(@as(usize, 9), rng.hi);
    // Open-ended tail: A- means A to end (hi == maxInt).
    const tail = try parseLineRange("4-");
    try std.testing.expectEqual(@as(usize, 4), tail.lo);
    try std.testing.expectEqual(std.math.maxInt(usize), tail.hi);
    // Rejections retain a stable failure class instead of becoming filenames.
    try std.testing.expectError(error.MalformedRange, parseLineRange(""));
    try std.testing.expectError(error.MalformedRange, parseLineRange("0"));
    try std.testing.expectError(error.DescendingRange, parseLineRange("5-2"));
    try std.testing.expectError(error.MalformedRange, parseLineRange("abc"));
    try std.testing.expectError(error.MalformedRange, parseLineRange("2-x"));
    try std.testing.expectError(error.MalformedRange, parseLineRange("0-3"));
}

test "parseRanges: single, comma list, empty, overflow, and a bad member" {
    var buf: [4]LineRange = undefined;
    // Single member.
    const single = try parseRanges("5", &buf);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqual(@as(usize, 5), single[0].lo);
    // Comma-separated members, in order.
    const list = try parseRanges("1,4-6,9", &buf);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(usize, 1), list[0].lo);
    try std.testing.expectEqual(@as(usize, 4), list[1].lo);
    try std.testing.expectEqual(@as(usize, 6), list[1].hi);
    try std.testing.expectEqual(@as(usize, 9), list[2].lo);
    // Empty and malformed members have a deterministic validation error.
    try std.testing.expectError(error.MalformedRange, parseRanges("", &buf));
    // Any unparseable member poisons the whole spec.
    try std.testing.expectError(error.MalformedRange, parseRanges("1,bad,3", &buf));
    // More members than the buffer holds gets its own failure class.
    var tiny: [2]LineRange = undefined;
    try std.testing.expectError(error.TooManyRanges, parseRanges("1,2,3", &tiny));
}

test "hotLimit: short default only when -l was omitted, else the given cap" {
    // No -l: the brief hot_default.
    try std.testing.expectEqual(hot_default, hotLimit(.{}));
    try std.testing.expectEqual(hot_default, hotLimit(.{ .limit = default_limit }));
    // An explicit -l overrides, even to a value below the default — and an
    // explicit `-l 300` is a cap of 300, not the "unset" reading (F8).
    try std.testing.expectEqual(@as(u32, 5), hotLimit(.{ .limit = 5, .limit_set = true }));
    try std.testing.expectEqual(@as(u32, 1000), hotLimit(.{ .limit = 1000, .limit_set = true }));
    try std.testing.expectEqual(default_limit, hotLimit(.{ .limit = default_limit, .limit_set = true }));
}

test "FileSort.parse: canonical names, aliases, and unknown rejection" {
    try std.testing.expectEqual(FileSort.path, FileSort.parse("path").?);
    try std.testing.expectEqual(FileSort.path, FileSort.parse("name").?); // alias
    try std.testing.expectEqual(FileSort.symbols, FileSort.parse("symbols").?);
    try std.testing.expectEqual(FileSort.symbols, FileSort.parse("size").?); // alias
    try std.testing.expect(FileSort.parse("count") == null);
    try std.testing.expect(FileSort.parse("") == null);
}

test "outline -k restricts to the requested kind, both sides of the branch" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "w.zig", .data =
        \\pub const Widget = struct {
        \\    x: u32,
        \\};
        \\pub fn build() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // No filter: both the struct and the fn appear.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "struct Widget") != null);
        try testing.expect(std.mem.indexOf(u8, out, "fn build") != null);
    }
    { // -k fn: only the function; the struct is filtered out.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "", .{ .kinds = "fn" });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "fn build") != null);
        try testing.expect(std.mem.indexOf(u8, out, "Widget") == null);
    }
    { // -k struct: only the struct; the function is filtered out.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "", .{ .kinds = "struct" });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "struct Widget") != null);
        try testing.expect(std.mem.indexOf(u8, out, "build") == null);
    }
}

test "outline -v names drops the signature that the default sig view shows" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // Default sig view carries the parameter list.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "", .{ .verbosity = .sig });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "fn add") != null);
        try testing.expect(std.mem.indexOf(u8, out, "(a: u32") != null);
    }
    { // names view: the name is present, the signature is not.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "", .{ .verbosity = .names });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "fn add") != null);
        try testing.expect(std.mem.indexOf(u8, out, "(a: u32") == null);
    }
}

test "outline truncates per-file and names the unexpanded overflow files under -l" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Two files, each with symbols; a tiny budget forces per-file truncation and
    // the "more file(s) named but not expanded" summary on the second file.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn a1() void {}
        \\pub fn a2() void {}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub fn b1() void {}
        \\pub fn b2() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // limit 1 across two files: first file expands one symbol, second is named-only.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "", .{ .limit = 1 });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "symbol") != null and
            std.mem.indexOf(u8, out, "here (raise -l to list)") != null);
        try testing.expect(std.mem.indexOf(u8, out, "more file(s) named but not expanded") != null);
    }
    { // A single-file scope hits the plain "stopped at -l" footer instead.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "a.zig", .{ .limit = 1 });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "stopped at -l 1") != null);
        try testing.expect(std.mem.indexOf(u8, out, "more file(s) named") == null);
    }
    { // The global limit counts rendered symbols once across file boundaries.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try outline(&aw.writer, &idx, "", .{ .limit = 3 });
        const out = aw.written();
        try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "() void"));
        try testing.expect(std.mem.indexOf(u8, out, "stopped at -l 3") != null);
    }
}

test "outline path filter with no match reports an explicit empty result" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "only.zig", .data =
        \\pub fn present() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try outline(&aw.writer, &idx, "does_not_exist", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "no source symbols under 'does_not_exist'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "present") == null);
}

test "outline --format json is well-formed and carries path/lang/symbols" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "j.zig", .data =
        \\pub fn one() void {}
        \\pub fn two() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try outline(&aw.writer, &idx, "", .{ .format = .json });
    const out = aw.written();

    // Parse to prove it is a valid JSON document, then assert on the schema.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const file_obj = parsed.value.array.items[0];
    try testing.expect(file_obj == .object);
    try testing.expectEqualStrings("j.zig", file_obj.object.get("path").?.string);
    try testing.expectEqualStrings("zig", file_obj.object.get("lang").?.string);
    const syms = file_obj.object.get("symbols").?;
    try testing.expect(syms == .array);
    try testing.expectEqual(@as(usize, 2), syms.array.items.len);
}

test "listFiles: default order filters by path and reports an empty scope" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.py", .data =
        \\def only():
        \\    return 1
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "drop.py", .data =
        \\def other():
        \\    return 2
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // Filter narrows to the matching file only.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try listFiles(&aw.writer, &idx, "keep", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "keep.py") != null);
        try testing.expect(std.mem.indexOf(u8, out, "drop.py") == null);
        try testing.expect(std.mem.indexOf(u8, out, "1 symbol)") != null); // singular
    }
    { // No file matches → the explicit not-found note, naming the filter.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try listFiles(&aw.writer, &idx, "nowhere", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no indexed files under 'nowhere'") != null);
    }
}

test "read: out-of-range line noted; open-ended A- tail runs to EOF" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\a = 1
        \\b = 2
        \\c = 3
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // A range whose start is past EOF is flagged, not silently empty.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try readLines(&aw.writer, io, &idx, root, "m.py:10-20", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no such line: 10; file has 3") != null);
    }
    { // JSON keeps the empty selection typed; it must never reinterpret an
        // empty page range as the whole file and then fail its byte budget.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try readLines(&aw.writer, io, &idx, root, "m.py:10-20", .{ .format = .json });
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try testing.expectEqual(@as(i64, 0), object.get("selected").?.integer);
        try testing.expectEqual(@as(i64, 0), object.get("shown").?.integer);
        try testing.expectEqual(@as(usize, 0), object.get("lines").?.array.items.len);
        try testing.expect(object.get("error") == null);
        const selection_error = object.get("selection_error").?.object;
        try testing.expectEqualStrings("no_such_line", selection_error.get("code").?.string);
        try testing.expectEqual(@as(i64, 10), selection_error.get("requested").?.integer);
    }
    { // Open-ended `2-` emits from line 2 through the last line, dropping line 1.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try readLines(&aw.writer, io, &idx, root, "m.py:2-", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "2\tb = 2") != null);
        try testing.expect(std.mem.indexOf(u8, out, "3\tc = 3") != null);
        try testing.expect(std.mem.indexOf(u8, out, "a = 1") == null);
    }
}

test "showDef: unknown name is reported; @path selects one of several twins" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "left.zig", .data =
        \\pub fn dup() u32 {
        \\    return 1;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "right.zig", .data =
        \\pub fn dup() u32 {
        \\    return 2;
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // Missing name → the explicit not-found sentence.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "ghost", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no definition named 'ghost'") != null);
    }
    { // Bare name shows both twins (each with its own file path).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "dup", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "left.zig") != null);
        try testing.expect(std.mem.indexOf(u8, out, "right.zig") != null);
    }
    { // The @path selector narrows to exactly one file.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try showDef(&aw.writer, &idx, "dup@right", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "right.zig") != null);
        try testing.expect(std.mem.indexOf(u8, out, "left.zig") == null);
    }
}

test "walk: unknown symbol reported; callees followed to depth 2" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "chain.zig", .data =
        \\pub fn leaf() void {}
        \\pub fn mid() void {
        \\    leaf();
        \\}
        \\pub fn top() void {
        \\    mid();
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // Unknown name → the (no symbol named …) note.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "absent", false, .{ .depth = 1 });
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no symbol named 'absent'") != null);
    }
    { // depth 1 from top reaches mid but not the transitively-called leaf.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "top", false, .{ .depth = 1 });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "mid") != null);
        try testing.expect(std.mem.indexOf(u8, out, "leaf") == null);
    }
    { // depth 2 descends one more hop and reaches leaf.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "top", false, .{ .depth = 2 });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "mid") != null);
        try testing.expect(std.mem.indexOf(u8, out, "leaf") != null);
    }
}

test "search: matches names, honors -k, and reports no match" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.zig", .data =
        \\pub const Config = struct {
        \\    n: u32,
        \\};
        \\pub fn configure() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // A substring pattern matches both the struct and the fn by name.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try search(&aw.writer, &idx, "onfig", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "Config") != null);
        try testing.expect(std.mem.indexOf(u8, out, "configure") != null);
    }
    { // -k struct narrows the same query to just the struct.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try search(&aw.writer, &idx, "onfig", .{ .kinds = "struct" });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "Config") != null);
        try testing.expect(std.mem.indexOf(u8, out, "configure") == null);
    }
    { // No name contains the pattern → the not-found note.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try search(&aw.writer, &idx, "zzzz", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no symbol matching 'zzzz'") != null);
    }
}

test "neighbors: shows both callees and callers, and reports a missing symbol" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "n.zig", .data =
        \\pub fn leaf() void {}
        \\pub fn mid() void {
        \\    leaf();
        \\}
        \\pub fn top() void {
        \\    mid();
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // mid sits between top (caller) and leaf (callee): both directions listed.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try neighbors(&aw.writer, &idx, "mid", .{});
        const out = aw.written();
        const calls_hdr = std.mem.indexOf(u8, out, "↓ calls").?;
        const callers_hdr = std.mem.indexOf(u8, out, "↑ callers").?;
        try testing.expect(calls_hdr < callers_hdr); // callees section precedes callers
        // leaf shows under callees; top shows under callers.
        const leaf_at = std.mem.indexOf(u8, out, "leaf").?;
        const top_at = std.mem.indexOf(u8, out, "top").?;
        try testing.expect(leaf_at > calls_hdr and leaf_at < callers_hdr);
        try testing.expect(top_at > callers_hdr);
    }
    { // Missing name → the shared not-found note.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try neighbors(&aw.writer, &idx, "nobody", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no symbol named 'nobody'") != null);
    }
}

test "routes: a route renders with its handler callee and its client caller" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A FastAPI-style decorator route with a handler, plus a TS client that fetches
    // the same path — the cross-language route↔client link.
    try tmp.dir.writeFile(io, .{ .sub_path = "api.py", .data =
        \\app = FastAPI()
        \\@app.get("/orders")
        \\def list_orders():
        \\    return []
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function loadOrders() {
        \\  return fetch("/orders");
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try listRoutes(&aw.writer, &idx, "", .{});
    const out = aw.written();
    // The route symbol (METHOD path), its handler callee, and the client caller.
    try testing.expect(std.mem.indexOf(u8, out, "GET /orders") != null);
    try testing.expect(std.mem.indexOf(u8, out, "list_orders") != null);
    try testing.expect(std.mem.indexOf(u8, out, "loadOrders") != null);
}

test "phase 1 route views select clients, unhit routes, handlers, and orphan calls" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "api.py", .data =
        \\@app.get("/hit")
        \\def hit_handler(): return 1
        \\@app.post("/idle")
        \\def idle_handler(): return 2
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function loadHit() { return fetch("/hit"); }
        \\function loadMissing() { return fetch("/missing"); }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    _ = try listRoutes(&aw.writer, &idx, "", .{ .routes_clients = true });
    try testing.expect(std.mem.indexOf(u8, aw.written(), "[ts]") != null);
    aw.clearRetainingCapacity();
    _ = try listRoutes(&aw.writer, &idx, "", .{ .routes_unhit = true });
    try testing.expect(std.mem.indexOf(u8, aw.written(), "POST /idle") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "GET /hit") == null);
    aw.clearRetainingCapacity();
    _ = try listRoutes(&aw.writer, &idx, "", .{ .routes_handler = "hit_*" });
    try testing.expect(std.mem.indexOf(u8, aw.written(), "GET /hit") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "POST /idle") == null);
    aw.clearRetainingCapacity();
    _ = try listRoutes(&aw.writer, &idx, "", .{ .routes_orphan_calls = true });
    try testing.expect(std.mem.indexOf(u8, aw.written(), "GET /missing") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "loadMissing") != null);
}

test "routes: a filter that matches no route reports an empty scope" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "api.py", .data =
        \\@app.get("/health")
        \\def health():
        \\    return 1
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // The filter matches the one route by its name substring.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try listRoutes(&aw.writer, &idx, "health", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "GET /health") != null);
    }
    { // A non-matching filter → the not-found note.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try listRoutes(&aw.writer, &idx, "billing", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no routes under 'billing'") != null);
    }
}

test "phase 1 protocol walks and conformance share inferred implementation edges" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ports.py", .data =
        \\from typing import Protocol
        \\class Runner(Protocol):
        \\    def run(self, value: str) -> str: ...
        \\class FastRunner:
        \\    def run(self, value: str) -> str: return value
        \\class AlphaRunner:
        \\    def run(self, value: str) -> str: return value
        \\class BetaRunner:
        \\    def run(self, value: int) -> str: return str(value)
        \\class GammaRunner:
        \\    pass
        \\def execute(runner: Runner) -> str:
        \\    return runner.run("x")
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try testing.expect(try walk(&aw.writer, &idx, "execute", false, .{ .impls = true }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "⇒impl") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "FastRunner.run") != null);

    aw.clearRetainingCapacity();
    try testing.expect(try conforms(&aw.writer, &idx, "Runner", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "FastRunner.run") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "OK") != null);

    aw.clearRetainingCapacity();
    try testing.expect(try conforms(&aw.writer, &idx, "*aRunner", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "sibling conformance") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "sig_diff") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "missing    GammaRunner") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "ports.py:") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, aw.written(), "AlphaRunner.run"));

    aw.clearRetainingCapacity();
    try testing.expect(try conforms(&aw.writer, &idx, "*aRunner", .{ .strict = true }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "missing    GammaRunner") != null);

    aw.clearRetainingCapacity();
    try testing.expect(try shortestPath(&aw.writer, &idx, "execute", "FastRunner.run", .{ .impls = true }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "FastRunner.run") != null);
}

test "events filters DOM noise and links Kafka topic aliases" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pipeline.py", .data =
        \\topics = [config.detections_topic]
        \\def consume():
        \\    consumer.subscribe(topics)
        \\    map.on("mousemove", draw)
        \\def publish(payload):
        \\    producer.produce(config.detections_topic, payload)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try events(&aw.writer, &idx, "", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "event \"detections_topic\"") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "(unpaired)") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "mousemove") == null);
}

test "phase 1 visibility filters outline and search consistently" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "visibility.py", .data =
        \\def visible(): return 1
        \\def _hidden(): return 2
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    _ = try outline(&aw.writer, &idx, "visibility.py", .{ .visibility = .public });
    try testing.expect(std.mem.indexOf(u8, aw.written(), "visible") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "_hidden") == null);
    aw.clearRetainingCapacity();
    _ = try search(&aw.writer, &idx, "hidden", .{ .visibility = .private });
    try testing.expect(std.mem.indexOf(u8, aw.written(), "_hidden") != null);
}

test "imports: listImports shows a local import with its binding; empty scope noted" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.zig", .data =
        \\pub fn f() void {}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "user.zig", .data =
        \\const dep = @import("dep.zig");
        \\pub fn g() void {
        \\    dep.f();
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // user.zig → dep.zig, bound as `dep`.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try listImports(&aw.writer, &idx, "user", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "user.zig") != null);
        try testing.expect(std.mem.indexOf(u8, out, "→ dep.zig") != null);
        try testing.expect(std.mem.indexOf(u8, out, "(dep)") != null);
    }
    { // dep.zig has no local imports of its own → empty note under that scope.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try listImports(&aw.writer, &idx, "dep.zig", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no local imports under 'dep.zig'") != null);
    }
}

test "imports: listImporters lists reverse deps and reports none for a leaf" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dep.zig", .data =
        \\pub fn f() void {}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "user.zig", .data =
        \\const dep = @import("dep.zig");
        \\pub fn g() void {
        \\    dep.f();
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // dep.zig is imported by user.zig.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try listImporters(&aw.writer, &idx, "dep.zig", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "dep.zig ← imported by") != null);
        try testing.expect(std.mem.indexOf(u8, out, "user.zig") != null);
    }
    { // user.zig imports others but nobody imports it → no importers.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try listImporters(&aw.writer, &idx, "user.zig", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no importers of 'user.zig'") != null);
    }
}

test "shortestPath renders the chain, a same-node path, and a no-path note" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "p.zig", .data =
        \\pub fn alpha() void {
        \\    beta();
        \\}
        \\pub fn beta() void {
        \\    gamma();
        \\}
        \\pub fn gamma() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // A reachable target renders the full alpha→beta→gamma cascade.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try shortestPath(&aw.writer, &idx, "alpha", "gamma", .{});
        const out = aw.written();
        const a = std.mem.indexOf(u8, out, "alpha").?;
        const b = std.mem.indexOf(u8, out, "beta").?;
        const g = std.mem.indexOf(u8, out, "gamma").?;
        try testing.expect(a < b and b < g); // rendered source-first
    }
    { // Same node: the path is the single node, nothing else on the way.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try shortestPath(&aw.writer, &idx, "alpha", "alpha", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "alpha") != null);
        try testing.expect(std.mem.indexOf(u8, out, "beta") == null);
    }
    { // No backward edge gamma→alpha → the explicit no-path note.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try shortestPath(&aw.writer, &idx, "gamma", "alpha", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no call path from 'gamma' to 'alpha'") != null);
    }
}

test "shortestPath abstains on ambiguous endpoints and offers unique pins" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn start() void { target(); }
        \\pub fn target() void {}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub fn start() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try testing.expect(!try shortestPath(&aw.writer, &idx, "start", "target", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "ambiguous path from endpoint") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "no path was traversed") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "start@a.zig") != null);

    buf.clearRetainingCapacity();
    try testing.expect(try shortestPath(&aw.writer, &idx, "start@a.zig", "target", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "target") != null);
}

test "hot: caps at -l with an overflow note, and scopes by file-path filter" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "core.zig", .data =
        \\pub fn shared() void {}
        \\pub fn a() void { shared(); }
        \\pub fn b() void { shared(); a(); }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.zig", .data =
        \\pub fn helper() void {}
        \\pub fn caller() void { helper(); }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    { // -l 1 shows only the top-ranked function and notes the rest.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try hot(&aw.writer, &idx, "", .{ .limit = 1, .limit_set = true });
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "shared") != null); // rank 1
        try testing.expect(std.mem.indexOf(u8, out, "more; raise -l to see them") != null);
    }
    { // The filter is a file-path scope: only core.zig functions survive.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try hot(&aw.writer, &idx, "core", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "shared") != null);
        try testing.expect(std.mem.indexOf(u8, out, "helper") == null);
    }
    { // A filter matching no file → the empty note naming it.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try hot(&aw.writer, &idx, "missing", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "no functions under 'missing'") != null);
    }
}

test "hot hints when test callers dominate the visible ranking" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "core.py", .data =
        \\def h1(): return 1
        \\def h2(): return 2
        \\def h3(): return 3
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "checks.py", .data =
        \\def test_a(): h1(); h2(); h3()
        \\def test_b(): h1(); h2(); h3()
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try hot(&aw.writer, &idx, "", .{ .limit = 3 }));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "use --no-tests") != null);
    aw.clearRetainingCapacity();
    _ = try hot(&aw.writer, &idx, "", .{ .limit = 3, .tests = .without });
    try testing.expect(std.mem.indexOf(u8, aw.written(), "use --no-tests") == null);
}

test "phase 2 flow classifies constructor, member, and augmented accesses" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.py", .data =
        \\class Record:
        \\    value = 0
        \\def make():
        \\    item = Record(value=1)
        \\    item.value += 2
        \\def use(item: Record):
        \\    return item.value
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try testing.expect(try flow(&aw.writer, &idx, "Record.value", .{}));
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "WRITERS ↳:2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "READERS ↳:2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[w] value (on Record)") != null);

    var type_buf: std.ArrayList(u8) = .empty;
    defer type_buf.deinit(testing.allocator);
    var type_aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &type_buf);
    defer type_aw.deinit();
    try testing.expect(try flow(&type_aw.writer, &idx, "Record", .{}));
    try testing.expect(std.mem.indexOf(u8, type_aw.written(), "WRITERS ↳:1") != null);
    try testing.expect(std.mem.indexOf(u8, type_aw.written(), "READERS ↳:2") != null);
}

test "flow reports ambiguous definitions and counts module initializers as writers" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.py", .data =
        \\DEFAULT_AUDIENCE = "alpha"
        \\def read_a(): return DEFAULT_AUDIENCE
        \\def sink(): pass
    });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.py", .data =
        \\DEFAULT_AUDIENCE = "beta"
        \\def sink(): pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try flow(&aw.writer, &idx, "DEFAULT_AUDIENCE", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "2 definitions match") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "WRITERS ↳:2") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, aw.written(), "[w:init]"));

    aw.clearRetainingCapacity();
    try testing.expect(try flow(&aw.writer, &idx, "DEFAULT_AUDIENCE@a.py", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "definitions match") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "WRITERS ↳:1") != null);

    aw.clearRetainingCapacity();
    try testing.expect(!try flow(&aw.writer, &idx, "DEFAULT_AUDIENCE", .{ .flow_to = "sink" }));
    try testing.expect(std.mem.count(u8, aw.written(), "2 definitions match") == 2);
}

test "flow --to starts at an initializer and follows readers to the sink" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "path.py", .data =
        \\VALUE = 1
        \\def forward():
        \\    sink()
        \\    return VALUE
        \\def sink(): pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();

    const value_ids = idx.lookup("VALUE");
    const chain = try flowPathIds(&idx, value_ids, "sink", false);
    defer testing.allocator.free(chain);
    try testing.expectEqual(@as(usize, 3), chain.len);
    try testing.expectEqual(value_ids[0], chain[0]);
    try testing.expectEqualStrings("sink", idx.graph.symbols[chain[2]].name);

    const owner = idx.graph.symbols[idx.lookup("forward")[0]];
    const heuristic: model.Reference = .{ .name = "VALUE", .line = owner.line, .kind = .read, .target = value_ids[0], .exact = false };
    try testing.expect(flowRefSelected(&idx, owner, heuristic, false, .{}));
    try testing.expect(!flowRefSelected(&idx, owner, heuristic, false, .{ .strict = true }));
}

test "flow handles an empty index" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(!try flow(&aw.writer, &idx, "VALUE", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "no symbol named 'VALUE'") != null);
    aw.clearRetainingCapacity();
    try testing.expect(!try conforms(&aw.writer, &idx, "Port", .{}));
    try testing.expect(std.mem.indexOf(u8, aw.written(), "no protocol/interface") != null);
}

test "flow --to ignores writes to unrelated values" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "paths.py", .data =
        \\VALUE = 0
        \\def make(): return 1
        \\def write_value():
        \\    VALUE = make()
        \\def unrelated():
        \\    other = make()
        \\    sink()
        \\def sink(): pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();

    const value_ids = idx.lookup("VALUE");
    const chain = try flowPathIds(&idx, value_ids, "sink", false);
    defer testing.allocator.free(chain);
    try testing.expectEqual(@as(usize, 0), chain.len);
}

test "phase 2 span ranking is global and biggest first" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "rank.py", .data =
        \\def small(): return 1
        \\def large():
        \\    x = 1
        \\    y = 2
        \\    return x + y
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();
    const ranked = try collectRankedDefinitions(&idx, "", "", .{ .sort = .span, .kinds = "fn" }, true);
    defer testing.allocator.free(ranked);
    try testing.expect(ranked.len >= 2);
    try testing.expectEqualStrings("large", idx.graph.symbols[ranked[0].id].name);
    try testing.expect(ranked[0].metric > ranked[1].metric);
}

test "phase 2 collisions groups duplicate top-level names deterministically" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.py", .data = "class Store:\n    pass\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.py", .data = "class Store:\n    pass\nclass Unique:\n    pass\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mounts.py", .data =
        \\app.include_router(one.router, prefix="/api")
        \\app.include_router(two.router, prefix="/api")
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, testing.io, root, false);
    defer idx.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try testing.expect(try collisions(&aw.writer, &idx, "", .{}));
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "# Store ×2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# Unique") == null);
    try testing.expect(std.mem.indexOf(u8, out, "# /api") == null);
}

test "TestScope.parse accepts aliases and rejects garbage" {
    try std.testing.expectEqual(TestScope.with, TestScope.parse("with").?);
    try std.testing.expectEqual(TestScope.with, TestScope.parse("both").?);
    try std.testing.expectEqual(TestScope.without, TestScope.parse("no").?);
    try std.testing.expectEqual(TestScope.only, TestScope.parse("only").?);
    try std.testing.expect(TestScope.parse("bogus") == null);
}

test "test-awareness: Zig test block is a caller; --tests scope + coverage" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub fn used() u32 { return 1; }
        \\pub fn coveredNever() u32 { return 2; }
        \\test "exercises used" {
        \\    _ = used();
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    // The `test` block is a first-class symbol and a caller of `used`.
    const used = idx.lookup("used")[0];
    const test_sym = idx.graph.symbols[idx.lookup("exercises used")[0]];
    try testing.expectEqual(model.SymbolKind.test_case, test_sym.kind);
    try testing.expect(isTestSymbol(&idx, test_sym));
    try testing.expect(!isTestSymbol(&idx, idx.graph.symbols[used]));
    try testing.expectEqual(test_sym.id, idx.callersOf(used)[0]);

    // `callers used --tests-only` shows the test; `--no-tests` shows nothing.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "used", true, .{ .tests = .only });
        try testing.expect(std.mem.indexOf(u8, aw.written(), "exercises used") != null);
    }
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try walk(&aw.writer, &idx, "used", true, .{ .tests = .without });
        try testing.expect(std.mem.indexOf(u8, aw.written(), "exercises used") == null);
    }

    // coverage: `used` is reachable from the test, `coveredNever` is not → 50%.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        _ = try coverage(&aw.writer, &idx, "", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "50.0%") != null);
    }
}

test "unused: a JS object-literal key does not mask a dead function (tally scope)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data =
        \\function tallyThing() { return 0; }
        \\export function h(res) { res.json({ tallyThing: 1 }); }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var refs = try buildReferencedNames(&idx);
    defer refs.deinit();
    // `{ tallyThing: 1 }` is an object key, not a call — so tallyThing is dead.
    const dead = idx.graph.symbols[idx.lookup("tallyThing")[0]];
    try testing.expect(try isDeadCandidateScoped(&idx, dead, "", &refs, .without));
}

test "unused: a dead @dataclass class is reported (decorated classes are not framework-wired)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\from dataclasses import dataclass
        \\@dataclass
        \\class DeadRow:
        \\    x: int
        \\@dataclass
        \\class LiveRow:
        \\    y: int
        \\def use():
        \\    return LiveRow(1)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var refs = try buildReferencedNames(&idx);
    defer refs.deinit();
    const dead = idx.graph.symbols[idx.lookup("DeadRow")[0]];
    const live = idx.graph.symbols[idx.lookup("LiveRow")[0]];
    try testing.expect(try isDeadCandidateScoped(&idx, dead, "", &refs, .without)); // dead dataclass surfaces
    try testing.expect(!try isDeadCandidateScoped(&idx, live, "", &refs, .without)); // used one does not
}

test "status exposes changed files, parse health, and unresolved diagnostics" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.js", .data =
        \\class LocalThing { run() { this.missingMember(); } }
        \\class OtherThing { slice() { return 1; } }
        \\function caller(localValue) { const assigned = localValue; missingCall(); return "x".slice(); }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.js", .data =
        \\function beforeBad() { return 1; }
        \\const bad = "never closed
        \\function hidden() { return 2; }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.js", .data = "function caller(localValue) { missingCall(); anotherMissing(); return localValue; }\n" });

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(testing.allocator);
    var json_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &json_buf);
    defer json_writer.deinit();
    try testing.expect(try status(&json_writer.writer, io, &idx, "", .{ .format = .json, .limit = 4 }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_writer.written(), .{});
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    try testing.expect(!root_obj.get("freshness").?.object.get("current").?.bool);
    try testing.expectEqual(@as(usize, 1), root_obj.get("freshness").?.object.get("changes").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), root_obj.get("parse_health").?.object.get("count").?.integer);
    const resolution = root_obj.get("unresolved_references").?.object;
    try testing.expectEqual(@as(i64, 3), resolution.get("count").?.integer);
    try testing.expectEqual(@as(i64, 1), resolution.get("categories").?.object.get("likely_local").?.integer);
    try testing.expectEqual(@as(i64, 2), resolution.get("categories").?.object.get("external_or_unmodeled").?.integer);
    try testing.expectEqualStrings("likely_local", resolution.get("items").?.array.items[0].object.get("resolution").?.string);

    var local_buf: std.ArrayList(u8) = .empty;
    defer local_buf.deinit(testing.allocator);
    var local_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &local_buf);
    defer local_writer.deinit();
    _ = try search(&local_writer.writer, &idx, "localValue", .{ .format = .json, .refs = true, .exact = true });
    try testing.expect(std.mem.indexOf(u8, local_writer.written(), "\"resolution\":\"local\"") != null);
    try testing.expect(std.mem.indexOf(u8, local_writer.written(), "unresolved_reference") == null);

    var ref_buf: std.ArrayList(u8) = .empty;
    defer ref_buf.deinit(testing.allocator);
    var ref_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &ref_buf);
    defer ref_writer.deinit();
    _ = try search(&ref_writer.writer, &idx, "missingCall", .{ .format = .json, .refs = true, .exact = true });
    try testing.expect(std.mem.indexOf(u8, ref_writer.written(), "\"diagnostic\":\"unresolved_reference\"") != null);

    var def_buf: std.ArrayList(u8) = .empty;
    defer def_buf.deinit(testing.allocator);
    var def_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &def_buf);
    defer def_writer.deinit();
    _ = try showDef(&def_writer.writer, &idx, "beforeBad", .{ .format = .json });
    try testing.expect(std.mem.indexOf(u8, def_writer.written(), "\"parse_health\"") != null);

    var jsonl_buf: std.ArrayList(u8) = .empty;
    defer jsonl_buf.deinit(testing.allocator);
    var jsonl_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &jsonl_buf);
    defer jsonl_writer.deinit();
    _ = try status(&jsonl_writer.writer, io, &idx, "", .{ .format = .jsonl, .limit = 2 });
    var lines = std.mem.tokenizeScalar(u8, jsonl_writer.written(), '\n');
    var line_count: u32 = 0;
    while (lines.next()) |line| {
        var row = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer row.deinit();
        try testing.expect(row.value == .object);
        line_count += 1;
    }
    try testing.expectEqual(@as(u32, 3), line_count);
    try testing.expect(std.mem.indexOf(u8, jsonl_writer.written(), "\"cache\":") != null);
    try testing.expect(std.mem.indexOf(u8, jsonl_writer.written(), "\"freshness_current\":false") != null);
}

test "sourceRange maps post-image lines to exact indexed bytes" {
    const text = "one\ntwo\nthree\nfour\n";
    const mapped = sourceRange(text, .{ .lo = 2, .hi = 3 });
    try std.testing.expectEqual(@as(u32, 4), mapped.start);
    try std.testing.expectEqual(@as(u32, 13), mapped.end);
    try std.testing.expectEqualStrings("two\nthree", mapped.text);

    const deletion_anchor = sourceRange(text, .{ .lo = 0, .hi = 0, .empty = true });
    try std.testing.expectEqual(@as(u32, 0), deletion_anchor.start);
    try std.testing.expectEqual(deletion_anchor.start, deletion_anchor.end);
    try std.testing.expect(deletion_anchor.empty);
    try std.testing.expectEqualStrings("", deletion_anchor.text);
}
