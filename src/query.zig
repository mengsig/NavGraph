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
    /// `unused`: drop exported symbols (they may be public API, not dead code).
    unused_skip_exported: bool = false,
    /// `unused`: drop symbols referenced only from tests (they are used — by
    /// tests). Passing both `unused_skip_*` flags leaves only the symbols
    /// referenced nowhere: the "actually unused" set.
    unused_skip_test_only: bool = false,
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
pub fn outline(w: *Writer, idx: *const Index, path_filter: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.outline(w, idx, path_filter, opts);
    var shown: u32 = 0;
    var any = false;
    var summarized: u32 = 0;
    for (idx.graph.files) |file| {
        if (!matchesFilter(file.path, path_filter)) continue;
        if (!fileHasVisible(idx, file)) continue;
        any = true;
        try w.print("# {s} ({s})\n", .{ file.path, file.language.tag() });
        // Once the symbol budget is spent, keep naming every remaining file (with
        // its symbol count) instead of dropping it off the tail — so an agent
        // never mistakes a truncated-away file for a nonexistent one. Truncation
        // is per-file, not whole-files-vanish.
        if (shown >= opts.limit) {
            const n = visibleSymbolCount(idx, file, opts);
            try w.print("  … {d} symbol{s} here (raise -l to list)\n", .{ n, if (n == 1) "" else "s" });
            summarized += 1;
            continue;
        }
        shown += try outlineFile(w, idx, file, opts, &shown);
    }
    if (!any) {
        try w.print("(no source symbols under '{s}')\n", .{path_filter});
        try skippedNote(w, idx);
    }
    if (shown >= opts.limit) {
        if (summarized > 0) {
            try w.print("… (listed {d} symbols; {d} more file(s) named but not expanded — raise -l)\n", .{ opts.limit, summarized });
        } else {
            try w.print("… (stopped at -l {d}; raise -l to see more)\n", .{opts.limit});
        }
    }
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
        try w.print("{s}/", .{d});
    }
    try w.writeAll("; index one with `-C <dir>`)\n");
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
        count += 1;
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

/// The index's coverage manifest: every indexed file with its language and
/// symbol count. Lets an agent verify what NavGraph actually parsed — a file
/// that's absent (in an ignored dir) or shows 0 symbols is visible here, so a
/// "not found" from another verb can be diagnosed instead of trusted blindly.
pub fn listFiles(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.listFiles(w, idx, filter, opts);
    var any = false;
    var shown: u32 = 0;
    for (idx.graph.files) |file| {
        if (!matchesFilter(file.path, filter)) continue;
        any = true;
        const n = fileSymbolCount(idx, file);
        try w.print("{s}  ({s}, {d} symbol{s})\n", .{ file.path, file.language.tag(), n, if (n == 1) "" else "s" });
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (!any) {
        try w.print("(no indexed files under '{s}')\n", .{filter});
        try skippedNote(w, idx);
    }
    try truncationNote(w, opts, shown);
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

/// Print raw, numbered source lines of `spec` — a `path` or `path:A-B` range.
/// The escape hatch for text NavGraph can't attribute to a symbol: module-scope
/// statements, config, comments, an arbitrary line. Bytes come from the in-memory
/// index when the file is indexed, else are read from disk relative to `root`, so
/// config files and files under ignored dirs are reachable too.
pub fn readLines(w: *Writer, io: std.Io, idx: *const Index, root: []const u8, spec: []const u8, opts: Options) !void {
    _ = opts;
    var path = spec;
    // Empty `ranges` means the whole file; one or more means `file:A-B,C-D` — a
    // batched read that pulls several disjoint slices in one call (a symbol and
    // its neighbours, a definition and its use, etc.) instead of N invocations.
    var ranges_buf: [16]LineRange = undefined;
    var ranges: []const LineRange = &.{};
    if (std.mem.lastIndexOfScalar(u8, spec, ':')) |c| {
        if (parseRanges(spec[c + 1 ..], &ranges_buf)) |rs| {
            path = spec[0..c];
            ranges = rs;
        }
    }
    var owned: ?[]u8 = null;
    defer if (owned) |b| idx.gpa.free(b);
    const text = indexedText(idx, path) orelse blk: {
        var rd = std.Io.Dir.cwd().openDir(io, root, .{}) catch {
            try w.print("(cannot open root '{s}')\n", .{root});
            return;
        };
        defer rd.close(io);
        const bytes = rd.readFileAlloc(io, path, idx.gpa, .limited(max_read_bytes)) catch {
            try w.print("(no such file: '{s}' — give a path relative to the repo root; `navgraph files` lists them)\n", .{path});
            return;
        };
        owned = bytes;
        break :blk bytes;
    };
    try printNumbered(w, path, text, ranges);
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

const LineRange = struct { lo: usize, hi: usize };

/// Parse a `read` range suffix: `A-B`, `A-` (A to end), or `A` (single line).
/// Returns null on anything unparseable so a genuine `:` in a path is left alone.
fn parseLineRange(s: []const u8) ?LineRange {
    if (s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, s, '-')) |d| {
        const lo = std.fmt.parseInt(usize, s[0..d], 10) catch return null;
        const rest = s[d + 1 ..];
        const hi = if (rest.len == 0) std.math.maxInt(usize) else std.fmt.parseInt(usize, rest, 10) catch return null;
        if (lo == 0 or hi < lo) return null;
        return .{ .lo = lo, .hi = hi };
    }
    const only = std.fmt.parseInt(usize, s, 10) catch return null;
    if (only == 0) return null;
    return .{ .lo = only, .hi = only };
}

/// Parse a comma-separated list of ranges (`A-B,C-D,E`) into `buf`. Returns null
/// if empty, over-long, or any part is unparseable — so a lone `:` in a path (or
/// a non-range suffix) leaves the whole spec treated as a path.
fn parseRanges(s: []const u8, buf: []LineRange) ?[]const LineRange {
    if (s.len == 0) return null;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (n >= buf.len) return null;
        buf[n] = parseLineRange(part) orelse return null;
        n += 1;
    }
    return if (n == 0) null else buf[0..n];
}

/// The number of lines in `text` (a trailing newline is not counted as a line).
fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var total: usize = 1;
    for (text) |ch| {
        if (ch == '\n') total += 1;
    }
    if (text[text.len - 1] == '\n') total -= 1;
    return total;
}

/// Emit `text`'s lines in `[lo, hi]` as `N\t<line>` (single pass from the top).
fn emitRange(w: *Writer, text: []const u8, lo: usize, hi: usize) !void {
    var start: usize = 0;
    var line_no: usize = 1;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        if (line_no >= lo and line_no <= hi) try w.print("{d}\t{s}\n", .{ line_no, text[start..nl] });
        if (line_no >= hi) break;
        start = nl + 1;
        line_no += 1;
    }
}

/// Emit `text` for `ranges` (empty = whole file) as numbered lines under a header
/// naming the file and line count. Disjoint ranges are separated by a `⋯` gap
/// marker so it's clear lines were skipped between them.
fn printNumbered(w: *Writer, path: []const u8, text: []const u8, ranges: []const LineRange) !void {
    const total = lineCount(text);
    if (ranges.len == 0) {
        try w.print("# {s} ({d} line{s})\n", .{ path, total, if (total == 1) "" else "s" });
        try emitRange(w, text, 1, std.math.maxInt(usize));
        return;
    }
    if (ranges.len == 1 and ranges[0].hi != std.math.maxInt(usize)) {
        const r = ranges[0];
        try w.print("# {s} (lines {d}-{d} of {d})\n", .{ path, r.lo, @min(r.hi, total), total });
    } else {
        try w.print("# {s} ({d} line{s})\n", .{ path, total, if (total == 1) "" else "s" });
    }
    var prev_hi: usize = 0;
    for (ranges) |r| {
        if (r.lo > total) {
            try w.print("(no such line: {d}; file has {d})\n", .{ r.lo, total });
            continue;
        }
        if (prev_hi != 0 and r.lo > prev_hi + 1) try w.writeAll("  ⋯\n");
        try emitRange(w, text, r.lo, r.hi);
        prev_hi = @min(r.hi, total);
    }
}

/// Search the *contents of string literals* across every indexed file for
/// `pattern` (substring), printing `path:line: <literal>`. The escape hatch the
/// symbol graph can't cover: URL/route literals, log and error messages, regex
/// sources, config keys, feature-flag names — the text a trial kept dropping to
/// `read`/grep for. Language-agnostic: it re-lexes each file with the shared
/// tokenizer and matches only `.string` tokens, so a hit is never an identifier
/// that merely shares the text (stricter than a raw grep).
pub fn strings(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    std.debug.assert(pattern.len > 0);
    if (opts.format == .json) return json_out.strings(w, idx, pattern, opts);
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(idx.gpa);
    var shown: u32 = 0;
    outer: for (idx.graph.files) |file| {
        toks.clearRetainingCapacity();
        lexer.tokenize(idx.gpa, file.text, language.configFor(file.language), &toks) catch continue;
        for (toks.items) |t| {
            if (t.kind != .string) continue;
            const s = t.text(file.text);
            if (std.mem.indexOf(u8, s, pattern) == null) continue;
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
        try skippedNote(w, idx);
        return;
    }
    var visited = std.AutoHashMap(SymbolId, void).init(idx.gpa);
    defer visited.deinit();
    var heuristic: usize = 0;
    for (ids) |id| {
        visited.clearRetainingCapacity();
        try walkNode(w, idx, id, incoming, opts, 0, 0, 1, &.{}, true, &visited, &heuristic);
    }
    // If any ambiguous name-match (`?`) edges were shown, tell the agent how to
    // drop them rather than making it discover `-s` on its own. Only when they
    // are actually present and not already filtered.
    if (heuristic > 0 and !opts.strict) {
        try w.print("({d} heuristic `?` edge{s} shown — re-run with -s to drop them)\n", .{
            heuristic, if (heuristic == 1) "" else "s",
        });
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
    sites: u32,
    lines: []const u32,
    exact: bool,
    visited: *std.AutoHashMap(SymbolId, void),
    heuristic: *usize,
) anyerror!void {
    const v = if (indent == 0) opts.verbosity else headerVerbosity(opts.verbosity);
    try render.symbolSite(w, idx, idx.graph.symbols[id], v, indent, true, site, sites, lines, exact);
    if (indent > 0 and !exact) heuristic.* += 1;
    if (indent >= opts.depth) return;
    if ((try visited.getOrPut(id)).found_existing) {
        try indentLine(w, indent + 1, "… (recursion)");
        return;
    }
    if (incoming) {
        try walkCallers(w, idx, id, opts, indent, visited, heuristic);
    } else {
        try walkCallees(w, idx, id, opts, indent, visited, heuristic);
    }
}

/// A callee edge that is a plain *data read* of a value symbol (a module `var`,
/// a `const`, a `field`) rather than a call or a type dependency. These are noise
/// in a "what does this do / blast radius" callee tree — `calls`/`neighbors` hide
/// them by default and surface them only with `--refs`. Reading a *function* (a
/// callback passed by name) is a real dependency and stays. The graph itself is
/// unchanged — `callers`/`hot`/`unused` still count every resolved reference.
pub fn isDataReadEdge(idx: *const Index, ref: model.Reference) bool {
    if (ref.kind != .read) return false;
    return switch (idx.graph.symbols[ref.target].kind) {
        .variable, .constant, .field => true,
        else => false,
    };
}

fn walkCallees(
    w: *Writer,
    idx: *const Index,
    id: SymbolId,
    opts: Options,
    indent: usize,
    visited: *std.AutoHashMap(SymbolId, void),
    heuristic: *usize,
) !void {
    const sym = idx.graph.symbols[id];
    var externals: std.ArrayList(u8) = .empty;
    defer externals.deinit(idx.gpa);
    for (sym.refs) |ref| {
        // Follow every *resolved* edge (call, use, type-use). Bare data reads of
        // a var/const/field are dependency noise, hidden unless `--refs` asks for
        // them. Only unresolved *calls* are surfaced as externals; unresolved
        // reads of stdlib/locals would be noise.
        if (ref.target != invalid and (!opts.strict or ref.exact)) {
            if (!opts.refs and isDataReadEdge(idx, ref)) continue;
            // The edge (this symbol → callee) lives at ref.line in this file.
            try walkNode(w, idx, ref.target, false, opts, indent + 1, ref.line, ref.count, ref.lines, ref.exact, visited, heuristic);
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
    heuristic: *usize,
) !void {
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    for (idx.callersOf(id)) |cid| {
        if (opts.strict and !hasExactEdge(idx, cid, id)) continue;
        // The edge (caller → this symbol) lives at its call site(s) in the caller.
        try callSiteLines(idx, cid, id, &lines);
        try walkNode(w, idx, cid, true, opts, indent + 1, callSiteLine(idx, cid, id), callSiteCount(idx, cid, id), lines.items, hasExactEdge(idx, cid, id), visited, heuristic);
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
    if (shown == 0) {
        try w.print("(no symbol matching '{s}')\n", .{pattern});
        try skippedNote(w, idx);
    }
    try truncationNote(w, opts, shown);
}

/// List every reference (use site) whose name contains `pattern`, grouped by the
/// enclosing symbol, with the call-site line and whether it resolved. This is the
/// "find usages" verb — structured, comment/string-free, resolution-aware.
fn searchRefs(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.searchRefs(w, idx, pattern, opts);
    var shown: u32 = 0;
    outer: for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            if (std.mem.indexOf(u8, ref.name, pattern) == null) continue;
            // One row per *distinct* use-site line. A name referenced on several
            // lines within one caller is deduped into a single ref carrying a
            // `lines` list — expand it so every site is listed, not just the
            // first (the "found only one of its reads" recall gap a trial hit).
            if (ref.lines.len > 1) {
                for (ref.lines) |ln| {
                    try printRefRow(w, idx, sym, ref, ln);
                    shown += 1;
                    if (shown >= opts.limit) break :outer;
                }
            } else {
                try printRefRow(w, idx, sym, ref, ref.line);
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
}

/// Print one `search --refs` row: `path:line  name [(on recv)]  in owner [→ …]`.
fn printRefRow(w: *Writer, idx: *const Index, sym: model.Symbol, ref: model.Reference, line: u32) !void {
    try w.print("{s}:{d}  {s}", .{ idx.graph.files[sym.file].path, line, ref.name });
    if (ref.qualifier.len != 0) try w.print(" (on {s})", .{ref.qualifier});
    try w.print("  in {s}", .{sym.name});
    if (ref.target != invalid) {
        try w.print("  → {s}", .{idx.graph.files[idx.graph.symbols[ref.target].file].path});
    } else if (ref.kind == .call or ref.kind == .route_call) {
        try w.writeAll("  → ~ext");
    }
    try w.writeByte('\n');
}

/// The number of distinct resolved callees (outgoing edges) of `sym`.
fn fanOut(sym: model.Symbol) u32 {
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
pub fn hot(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    if (opts.format == .json) return json_out.hot(w, idx, filter, opts);
    const ranked = try collectHot(idx, filter);
    defer idx.gpa.free(ranked);
    // `hot` is an orientation view — a short ranked list is the point, so it
    // caps at a small default (raise `-l` for more) via the limit sentinel.
    const limit = hotLimit(opts);
    var shown: u32 = 0;
    var eligible: u32 = 0;
    for (ranked) |e| {
        // `--strict` ranks and reports on exact edges only, and hides a symbol
        // whose connectivity is entirely heuristic (a name-collision artifact).
        if (opts.strict and e.fan_in_exact == 0 and e.fan_out_exact == 0) continue;
        eligible += 1;
        if (shown >= limit) continue;
        shown += 1;
        const sym = idx.graph.symbols[e.id];
        try render.symbol(w, idx, sym, headerVerbosity(opts.verbosity), 0, true);
        try printHotCounts(w, e, opts.strict);
    }
    if (shown == 0) {
        try w.print("(no functions under '{s}')\n", .{filter});
        try skippedNote(w, idx);
        return;
    }
    if (eligible > shown) {
        try w.print("… ({d} more; raise -l to see them)\n", .{eligible - shown});
    }
}

/// Fan-in/out suffix for a `hot` row. Default surfaces the heuristic share as a
/// `(N ?)` qualifier so an inflated count is never shown bare; `--strict` prints
/// the exact-only counts.
fn printHotCounts(w: *Writer, e: HotEntry, strict: bool) !void {
    if (strict) {
        try w.print("    ←{d} callers  →{d} callees\n", .{ e.fan_in_exact, e.fan_out_exact });
        return;
    }
    try w.print("    ←{d} callers", .{e.fan_in});
    if (e.fan_in > e.fan_in_exact) try w.print(" ({d} ?)", .{e.fan_in - e.fan_in_exact});
    try w.print("  →{d} callees", .{e.fan_out});
    if (e.fan_out > e.fan_out_exact) try w.print(" ({d} ?)", .{e.fan_out - e.fan_out_exact});
    try w.writeByte('\n');
}

pub const HotEntry = struct {
    id: SymbolId,
    fan_in: u32,
    fan_in_exact: u32,
    fan_out: u32,
    fan_out_exact: u32,
};

/// Collect callable symbols under `filter`, sorted by *exact* fan-in then exact
/// fan-out (descending), so heuristic name-collision edges can't float a symbol
/// to the top. Ties fall back to total fan-in/out. Caller frees the slice.
pub fn collectHot(idx: *const Index, filter: []const u8) ![]HotEntry {
    // Exact incoming-edge count per symbol (heuristic `?` edges excluded), so a
    // symbol's rank reflects edges we can actually stand behind.
    var exact_in = try idx.gpa.alloc(u32, idx.graph.symbols.len);
    defer idx.gpa.free(exact_in);
    @memset(exact_in, 0);
    for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            if (ref.target != invalid and ref.exact) exact_in[ref.target] += 1;
        }
    }
    var list: std.ArrayList(HotEntry) = .empty;
    errdefer list.deinit(idx.gpa);
    for (idx.graph.symbols) |sym| {
        if (sym.kind != .function and sym.kind != .method) continue;
        if (!matchesFilter(idx.graph.files[sym.file].path, filter)) continue;
        const fan_in: u32 = @intCast(idx.callersOf(sym.id).len);
        const fan_out = fanOut(sym);
        if (fan_in == 0 and fan_out == 0) continue; // isolated: not informative
        try list.append(idx.gpa, .{
            .id = sym.id,
            .fan_in = fan_in,
            .fan_in_exact = exact_in[sym.id],
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
fn hotLessThan(_: void, a: HotEntry, b: HotEntry) bool {
    if (a.fan_in_exact != b.fan_in_exact) return a.fan_in_exact > b.fan_in_exact;
    if (a.fan_out_exact != b.fan_out_exact) return a.fan_out_exact > b.fan_out_exact;
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
    if (!any) {
        try w.print("(no routes under '{s}')\n", .{filter});
        try skippedNote(w, idx);
    }
    try truncationNote(w, opts, shown);
}

fn routeRelations(w: *Writer, idx: *const Index, route: model.Symbol) !void {
    for (route.refs) |ref| {
        if (ref.kind == .call and ref.target != invalid) {
            try render.symbol(w, idx, idx.graph.symbols[ref.target], .sig, 1, true);
        }
    }
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);
    for (idx.callersOf(route.id)) |cid| {
        // A route↔client link is a path match (its own resolver), not a name
        // guess, so it is always rendered as confident.
        try callSiteLines(idx, cid, route.id, &lines);
        try render.symbolSite(w, idx, idx.graph.symbols[cid], .sig, 1, true, callSiteLine(idx, cid, route.id), callSiteCount(idx, cid, route.id), lines.items, true);
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
        try skippedNote(w, idx);
        return;
    }
    for (ids) |id| {
        try render.symbol(w, idx, idx.graph.symbols[id], opts.verbosity, 0, true);
        try w.writeAll("  ↓ calls\n");
        try renderCallees(w, idx, id, opts, 2);
        try w.writeAll("  ↑ callers\n");
        var lines: std.ArrayList(u32) = .empty;
        defer lines.deinit(idx.gpa);
        for (idx.callersOf(id)) |cid| {
            try callSiteLines(idx, cid, id, &lines);
            try render.symbolSite(w, idx, idx.graph.symbols[cid], headerVerbosity(opts.verbosity), 2, true, callSiteLine(idx, cid, id), callSiteCount(idx, cid, id), lines.items, hasExactEdge(idx, cid, id));
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
            if (!opts.refs and isDataReadEdge(idx, ref)) continue;
            try render.symbolSite(w, idx, idx.graph.symbols[ref.target], headerVerbosity(opts.verbosity), indent, true, ref.line, ref.count, ref.lines, ref.exact);
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
    var refs = try buildReferencedNames(idx);
    defer refs.deinit();
    var shown: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (!isDeadCandidate(idx, sym, filter, &refs)) continue;
        if (!deadCandidateShown(sym, opts, &refs)) continue;
        try render.symbol(w, idx, sym, opts.verbosity, 0, true);
        // A name reached only from tests is a genuine cleanup target (no
        // application caller) — flag it as such; otherwise note public API.
        if (refs.tests.contains(sym.name)) {
            try w.writeAll("  (only used by tests)\n");
        } else if (sym.exported) {
            try w.writeAll("  (exported — may be public API)\n");
        } else {
            try w.writeByte('\n');
        }
        shown += 1;
        if (shown >= opts.limit) break;
    }
    if (shown == 0) {
        try w.print("(no unused functions under '{s}')\n", .{filter});
        try skippedNote(w, idx);
    }
    try truncationNote(w, opts, shown);
}

/// Names that are used *somewhere* in the repo, decided by a repo-wide
/// identifier-token count rather than the resolved call graph. A name counts as
/// used when its identifier appears more times across all files than the number
/// of definitions carrying that name — i.e. it appears somewhere beyond its own
/// declaration(s).
///
/// This is deliberately independent of body-scoping: it re-lexes every file and
/// tallies identifier tokens, so a use inside a Zig `test {}` block, a JS
/// module-scope statement, JSX (`<App/>`), an import, or a body NavGraph parses
/// only partially still counts. `unused` relies on this to avoid reporting live
/// code as dead — the false positive that makes the whole verb untrustworthy.
/// It ignores comments and strings (the lexer classifies those separately), so
/// it is stricter than a raw `grep`. Caller owns the returned map.
/// Where a name is used, split by production vs test code. `prod` holds names
/// used somewhere outside test files; `tests` holds names *used* (not just
/// imported) inside test files. `unused` treats a name absent from `prod` as
/// dead, and annotates it "(only used by tests)" when it is in `tests` — the
/// "no application caller" definition a dead-code audit actually wants.
pub const RefSets = struct {
    prod: std.StringHashMap(void),
    tests: std.StringHashMap(void),
    pub fn deinit(self: *RefSets) void {
        self.prod.deinit();
        self.tests.deinit();
    }
};

pub fn buildReferencedNames(idx: *const Index) !RefSets {
    const gpa = idx.gpa;
    // Definition count per name in *non-test* files (a name's own declaration
    // isn't a use): a name defined N times needs N+1 production occurrences to
    // count as used in production.
    var def_counts = std.StringHashMap(u32).init(gpa);
    defer def_counts.deinit();
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (isTestPath(idx.graph.files[sym.file].path)) continue;
        const gop = try def_counts.getOrPut(sym.name);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
    }

    // Identifier-token occurrences, tallied into production vs test buckets.
    var occ_prod = std.StringHashMap(u32).init(gpa);
    defer occ_prod.deinit();
    var occ_test = std.StringHashMap(u32).init(gpa);
    defer occ_test.deinit();
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(gpa);
    for (idx.graph.files) |file| {
        toks.clearRetainingCapacity();
        lexer.tokenize(gpa, file.text, language.configFor(file.language), &toks) catch continue;
        try tallyUses(toks.items, file.text, file.language, &occ_prod, &occ_test, isTestPath(file.path));
    }

    var prod = std.StringHashMap(void).init(gpa);
    errdefer prod.deinit();
    var pit = occ_prod.iterator();
    while (pit.next()) |e| {
        const defs = def_counts.get(e.key_ptr.*) orelse 0;
        if (e.value_ptr.* > defs) try prod.put(e.key_ptr.*, {});
    }
    var tests = std.StringHashMap(void).init(gpa);
    errdefer tests.deinit();
    var tit = occ_test.keyIterator();
    while (tit.next()) |k| try tests.put(k.*, {});
    return .{ .prod = prod, .tests = tests };
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
        const name = t.text(text);
        if (name.len >= 2) try bumpOccurrence(bucket, name);
        i += 1;
    }
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

/// A symbol worth reporting as possibly-unused: a callable, in-scope of the
/// filter, not an obvious entry point, and not used by any *production* code.
/// A test-only-used function still qualifies (it's a real cleanup target) — the
/// caller distinguishes it via `refs.tests`. `refs` is `buildReferencedNames`.
pub fn isDeadCandidate(
    idx: *const Index,
    sym: model.Symbol,
    filter: []const u8,
    refs: *const RefSets,
) bool {
    if (sym.kind != .function and sym.kind != .method) return false;
    if (std.mem.eql(u8, sym.name, "main")) return false;
    // Framework/entry-point callables are invoked implicitly, never by name, so
    // they always look "dead": dunder methods (`__init__`, `__call__`), a JS/TS
    // `constructor` (invoked by `new`), pytest test functions, and everything in
    // test/conftest files (tests + fixtures).
    if (isDunder(sym.name)) return false;
    if (std.mem.eql(u8, sym.name, "constructor")) return false;
    if (std.mem.startsWith(u8, sym.name, "test_")) return false;
    // A decorated definition is wired in by the decorator, not called by name
    // (`@field_validator`, `@app.on_event`, `@pytest.fixture`, `@abstractmethod`).
    // Treat it like a route handler: invoked, just not by a visible call site.
    if (precededByDecorator(idx, sym)) return false;
    // Used by production code (any non-test file) → live. Reporting a live symbol
    // as dead is the false positive that costs trust. A name used *only* from
    // tests is NOT excluded here — it surfaces as a cleanup candidate, annotated.
    if (refs.prod.contains(sym.name)) return false;
    const path = idx.graph.files[sym.file].path;
    if (isTestPath(path)) return false;
    return matchesFilter(path, filter);
}

/// Apply the `unused` visibility filters to a symbol already known to be a dead
/// candidate. `unused_skip_test_only` drops names referenced only from tests (a
/// real use, just not production); `unused_skip_exported` drops exported symbols
/// (possible public API). With both set, only symbols referenced nowhere survive
/// — the "actually unused" set. `refs` is `buildReferencedNames`.
pub fn deadCandidateShown(sym: model.Symbol, opts: Options, refs: *const RefSets) bool {
    std.debug.assert(sym.kind == .function or sym.kind == .method);
    std.debug.assert(sym.name.len != 0);
    if (opts.unused_skip_test_only and refs.tests.contains(sym.name)) return false;
    if (opts.unused_skip_exported and sym.exported) return false;
    return true;
}

/// A `__dunder__` name (implicitly invoked by the language/runtime).
fn isDunder(name: []const u8) bool {
    return name.len >= 4 and std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__");
}

/// True when the line immediately above `sym`'s definition is a decorator
/// (`@…`) — a cheap signal that the symbol is framework-invoked rather than
/// called by name. Handles the common single-line decorator; a decorator whose
/// closing `)` sits on its own line just above the def is not detected.
fn precededByDecorator(idx: *const Index, sym: model.Symbol) bool {
    const text = idx.graph.files[sym.file].text;
    if (sym.span_start == 0 or sym.span_start > text.len) return false;
    // Start of the definition's own line.
    var ls = sym.span_start;
    while (ls > 0 and text[ls - 1] != '\n') ls -= 1;
    if (ls == 0) return false;
    // The previous line is text[ps .. ls-1] (ls-1 is its terminating '\n').
    var ps = ls - 1;
    while (ps > 0 and text[ps - 1] != '\n') ps -= 1;
    var i = ps;
    while (i + 1 < ls and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i < ls and text[i] == '@';
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
    inline for (.{ "tests", "test", "__tests__", "__mocks__", "spec", "e2e" }) |d| {
        if (std.mem.eql(u8, comp, d)) return true;
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

    // `orphan` is called by nobody and named nowhere → dead candidate; `gamma`
    // is called → not.
    var ref_names = try buildReferencedNames(&idx);
    defer ref_names.deinit();
    const orphan = idx.graph.symbols[idx.lookup("orphan")[0]];
    const gamma = idx.graph.symbols[idx.lookup("gamma")[0]];
    try testing.expect(isDeadCandidate(&idx, orphan, "", &ref_names));
    try testing.expect(!isDeadCandidate(&idx, gamma, "", &ref_names));
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
        try walk(&aw.writer, &idx, "run", false, .{ .depth = 1 });
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
        try walk(&aw.writer, &idx, "run", false, .{ .depth = 1, .refs = true });
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
        try walk(&aw.writer, &idx, "run", false, .{ .depth = 1, .strict = true });
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
    try testing.expect(!isDeadCandidate(&idx, create_run, "", &ref_names));
    try testing.expect(idx.callersOf(create_run.id).len > 0);

    // Its fan-in is entirely heuristic: total > 0, exact == 0.
    const ranked = try collectHot(&idx, "");
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
        try hot(&aw.writer, &idx, "", .{});
        try testing.expect(std.mem.indexOf(u8, aw.written(), "?)") != null);
    }
    // `--strict` drops a symbol whose connectivity is entirely heuristic.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        try hot(&aw.writer, &idx, "", .{ .strict = true });
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
    try unused(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "reallyDead") != null);
    try testing.expect(std.mem.indexOf(u8, out, "afterProse") == null);
    try testing.expect(std.mem.indexOf(u8, out, "tmpl") == null);
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
    try unused(&aw.writer, &idx, "", .{});
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
    try unused(&aw.writer, &idx, "", .{});
    const out = aw.written();
    // Used in production → not reported.
    try testing.expect(std.mem.indexOf(u8, out, "prod_used") == null);
    // Reached only by a test → reported, and flagged as such.
    try testing.expect(std.mem.indexOf(u8, out, "helper_tested_only") != null);
    try testing.expect(std.mem.indexOf(u8, out, "only used by tests") != null);
    // Referenced nowhere → reported (plainly, no test annotation of its own).
    try testing.expect(std.mem.indexOf(u8, out, "truly_dead") != null);
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
    try unused(&aw.writer, &idx, "", .{});
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
    try walk(&aw.writer, &idx, "helper", true, .{ .depth = 1 });
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
    try walk(&aw.writer, &idx, "helper", true, .{ .depth = 1 });
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
        try readLines(&aw.writer, io, &idx, root, "m.py:2-3", .{});
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
        try readLines(&aw.writer, io, &idx, root, "conf.json", .{});
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
    try listFiles(&aw.writer, &idx, "", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "a.py") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2 symbols") != null);
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
        try showDef(&aw.writer, &idx, "value", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "get Store.value") != null);
        try testing.expect(std.mem.indexOf(u8, out, "method Store.value") == null);
    }
    { // `async` prefixes the tag for both a method and a free function.
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        try showDef(&aw.writer, &idx, "load", .{});
        try showDef(&aw.writer, &idx, "boot", .{});
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
        try strings(&aw.writer, &idx, "/api/health", .{});
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "svc.py:3") != null);
        try testing.expect(std.mem.indexOf(u8, out, "client.ts:1") != null);
    }
    { // `LOG_MSG` is an identifier, not a literal — no match (stricter than grep).
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
        defer aw.deinit();
        try strings(&aw.writer, &idx, "LOG_MSG", .{});
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
    try search(&aw.writer, &idx, "helper", .{ .refs = true });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "m.zig:5") != null);
    try testing.expect(std.mem.indexOf(u8, out, "m.zig:6") != null);
    try testing.expect(std.mem.indexOf(u8, out, "m.zig:7") != null);
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
        try showDef(&aw.writer, &idx, "handler", .{ .verbosity = .full });
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
        try showDef(&aw.writer, &idx, "GP_GROUPS", .{ .verbosity = .full });
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
    try readLines(&aw.writer, io, &idx, root, "m.py:1,4-5", .{});
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "1\tdef a():") != null);
    try testing.expect(std.mem.indexOf(u8, out, "4\t    z = 3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "5\t    w = 4") != null);
    // Lines outside the requested ranges are absent, and the gap is marked.
    try testing.expect(std.mem.indexOf(u8, out, "y = 2") == null);
    try testing.expect(std.mem.indexOf(u8, out, "⋯") != null);
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
    try unused(&aw.writer, &idx, "", .{});
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
