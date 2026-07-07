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

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const Symbol = model.Symbol;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;
const Options = query.Options;

const max_sig_len: usize = 160;

/// Outline: array of files, each with its visible symbols.
pub fn outline(w: *Writer, idx: *const Index, path_filter: []const u8, opts: Options) !void {
    var shown: u32 = 0;
    var first_file = true;
    try w.writeByte('[');
    for (idx.graph.files) |file| {
        if (!query.matchesFilter(file.path, path_filter)) continue;
        if (shown >= opts.limit) break;
        const wrote = try outlineFile(w, idx, file, opts, &shown, !first_file);
        if (wrote) first_file = false;
    }
    try w.writeByte(']');
    try w.writeByte('\n');
}

fn outlineFile(w: *Writer, idx: *const Index, file: model.SourceFile, opts: Options, shown: *u32, sep: bool) !bool {
    std.debug.assert(file.sym_start <= file.sym_end);
    var wrote_any = false;
    var i = file.sym_start;
    while (i < file.sym_end and shown.* < opts.limit) : (i += 1) {
        const sym = idx.graph.symbols[i];
        if (sym.kind == .import) continue;
        if (!sym.kind.isTopLevelInteresting() and sym.parent == invalid) continue;
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

/// Definition(s) of `name`: a JSON array of symbol objects.
pub fn showDef(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !void {
    var buf: [64]SymbolId = undefined;
    const ids = query.resolveIds(idx, name, &buf);
    try symbolArray(w, idx, ids, opts.verbosity);
}

/// Substring search: a JSON array of matching symbol objects.
pub fn search(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    std.debug.assert(pattern.len > 0);
    var shown: u32 = 0;
    try w.writeByte('[');
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (!query.kindAllowed(sym.kind, opts.kinds)) continue;
        if (std.mem.indexOf(u8, sym.name, pattern) == null) continue;
        if (shown != 0) try w.writeByte(',');
        try symbolObject(w, idx, sym, opts.verbosity);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    try w.writeAll("]\n");
}

/// `search --refs --json`: array of `{name, file, line, in, qualifier?, target?}`
/// reference objects (use sites), mirroring the text usages listing.
pub fn searchRefs(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    std.debug.assert(pattern.len > 0);
    const pat = query.RefPattern.parse(pattern);
    var shown: u32 = 0;
    try w.writeByte('[');
    outer: for (idx.graph.symbols) |sym| {
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
pub fn strings(w: *Writer, idx: *const Index, pattern: []const u8, opts: Options) !void {
    std.debug.assert(pattern.len > 0);
    var toks: std.ArrayList(lexer.Token) = .empty;
    defer toks.deinit(idx.gpa);
    var shown: u32 = 0;
    try w.writeByte('[');
    outer: for (idx.graph.files) |file| {
        toks.clearRetainingCapacity();
        lexer.tokenize(idx.gpa, file.text, language.configFor(file.language), &toks) catch continue;
        for (toks.items) |t| {
            if (t.kind != .string) continue;
            const s = t.text(file.text);
            if (std.mem.indexOf(u8, s, pattern) == null) continue;
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
}

/// Call-graph walk: a JSON array of tree roots (callees or callers).
pub fn walk(w: *Writer, idx: *const Index, name: []const u8, incoming: bool, opts: Options) !void {
    var buf: [64]SymbolId = undefined;
    const ids = query.resolveIds(idx, name, &buf);
    var visited = std.AutoHashMap(SymbolId, void).init(idx.gpa);
    defer visited.deinit();
    try w.writeByte('[');
    for (ids, 0..) |id, k| {
        if (k != 0) try w.writeByte(',');
        visited.clearRetainingCapacity();
        try walkNode(w, idx, id, incoming, opts, 0, 0, 1, &.{}, true, &visited);
    }
    try w.writeAll("]\n");
}

fn walkNode(
    w: *Writer,
    idx: *const Index,
    id: SymbolId,
    incoming: bool,
    opts: Options,
    depth: u32,
    site: u32,
    sites: u32,
    lines: []const u32,
    exact: bool,
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
    if (site != 0 and !exact) try w.writeAll(",\"exact\":false");
    if (depth >= opts.depth) return try w.writeByte('}');
    if ((try visited.getOrPut(id)).found_existing) {
        try w.writeAll(",\"recursion\":true}");
        return;
    }
    if (incoming) {
        try walkCallers(w, idx, id, opts, depth, visited);
    } else {
        try walkCallees(w, idx, id, opts, depth, visited);
    }
    try w.writeByte('}');
}

fn walkCallees(
    w: *Writer,
    idx: *const Index,
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
            try walkNode(w, idx, ref.target, false, opts, depth + 1, ref.line, ref.count, ref.lines, ref.exact, visited);
            wrote += 1;
        } else if (ref.kind == .call or ref.kind == .route_call) {
            ext += 1;
        }
    }
    try w.writeByte(']');
    if (ext != 0) try writeExternals(w, sym, opts.strict);
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
        if (wrote != 0) try w.writeByte(',');
        try query.callSiteLines(idx, cid, id, &lines);
        try walkNode(w, idx, cid, true, opts, depth + 1, query.callSiteLine(idx, cid, id), query.callSiteCount(idx, cid, id), lines.items, query.hasExactEdge(idx, cid, id), visited);
        wrote += 1;
    }
    try w.writeByte(']');
}

/// Hot: array of `{...symbol, fan_in, fan_in_exact, fan_in_test, fan_out, fan_out_exact}`
/// ranked by connectivity. `*_exact` exclude heuristic `?` edges; `fan_in_test`
/// is the share of callers in test files; `--strict` drops entries whose
/// connectivity is entirely heuristic.
pub fn hot(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    const ranked = try query.collectHot(idx, filter);
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
}

/// Routes: array of `{route, file, line, handler, callers}` objects.
pub fn listRoutes(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    var shown: u32 = 0;
    try w.writeByte('[');
    for (idx.graph.symbols) |sym| {
        if (sym.kind != .route) continue;
        if (filter.len != 0 and std.mem.indexOf(u8, sym.name, filter) == null) continue;
        if (shown != 0) try w.writeByte(',');
        try routeObject(w, idx, sym);
        shown += 1;
        if (shown >= opts.limit) break;
    }
    try w.writeAll("]\n");
}

fn routeObject(w: *Writer, idx: *const Index, route: Symbol) !void {
    try w.writeAll("{\"route\":");
    try writeString(w, route.name);
    try w.print(",\"file\":", .{});
    try writeString(w, idx.graph.files[route.file].path);
    try w.print(",\"line\":{d},\"handler\":", .{route.line});
    var handler: SymbolId = invalid;
    for (route.refs) |ref| {
        if (ref.kind == .call and ref.target != invalid) handler = ref.target;
    }
    if (handler == invalid) {
        try w.writeAll("null");
    } else {
        try symbolObject(w, idx, idx.graph.symbols[handler], .names);
    }
    try w.writeAll(",\"callers\":[");
    for (idx.callersOf(route.id), 0..) |cid, k| {
        if (k != 0) try w.writeByte(',');
        try symbolObject(w, idx, idx.graph.symbols[cid], .names);
    }
    try w.writeAll("]}");
}

/// Diff: array of `{file, symbols:[{...symbol, callers:[...]}]}` — changed symbols
/// and their direct callers (blast radius) per file.
pub fn diff(w: *Writer, idx: *const Index, changes: []const gitdiff.FileChange, opts: Options) !void {
    _ = opts;
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
}

/// Events: array of `{key, sites:[{role, verb, file, line, in}]}` grouped by key.
pub fn events(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
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

/// Neighbors: `{symbol, callees:[...], callers:[...]}` per resolved id.
pub fn neighbors(w: *Writer, idx: *const Index, name: []const u8, opts: Options) !void {
    var buf: [64]SymbolId = undefined;
    const ids = query.resolveIds(idx, name, &buf);
    try w.writeByte('[');
    for (ids, 0..) |id, k| {
        if (k != 0) try w.writeByte(',');
        const sym = idx.graph.symbols[id];
        try nodeHead(w, idx, sym);
        try w.writeAll(",\"callees\":[");
        try calleeArray(w, idx, sym, opts.strict);
        try w.writeAll("],\"callers\":[");
        for (idx.callersOf(id), 0..) |cid, j| {
            if (j != 0) try w.writeByte(',');
            try nodeHead(w, idx, idx.graph.symbols[cid]);
            const site = query.callSiteLine(idx, cid, id);
            if (site != 0) try w.print(",\"site\":{d}", .{site});
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]\n");
}

fn calleeArray(w: *Writer, idx: *const Index, sym: Symbol, strict: bool) !void {
    var wrote: u32 = 0;
    for (sym.refs) |ref| {
        if (ref.target == invalid or (strict and !ref.exact)) continue;
        if (wrote != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[ref.target]);
        if (ref.line != 0) try w.print(",\"site\":{d}", .{ref.line});
        try w.writeByte('}');
        wrote += 1;
    }
}

/// Unused: a JSON array of zero-caller function/method symbols.
pub fn unused(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    var refs = try query.buildReferencedNames(idx);
    defer refs.deinit();
    var shown: u32 = 0;
    try w.writeByte('[');
    for (idx.graph.symbols) |sym| {
        if (!query.isDeadCandidate(idx, sym, filter, &refs)) continue;
        if (!query.deadCandidateShown(sym, opts, &refs)) continue;
        if (shown != 0) try w.writeByte(',');
        // A name used only from tests is a real cleanup target — flag it so JSON
        // consumers can separate it from truly-unreferenced code.
        try symbolObjectExtra(w, idx, sym, opts.verbosity, refs.tests.contains(sym.name));
        shown += 1;
        if (shown >= opts.limit) break;
    }
    try w.writeAll("]\n");
}

/// Imports: `{file, imports:[{target, binding}]}` per in-scope file.
/// Index coverage manifest: `{file, lang, symbols}` per indexed file.
pub fn listFiles(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
    _ = opts;
    var first = true;
    try w.writeByte('[');
    for (idx.graph.files) |file| {
        if (!query.matchesFilter(file.path, filter)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"file\":");
        try writeString(w, file.path);
        try w.print(",\"lang\":\"{s}\",\"symbols\":{d}}}", .{ file.language.tag(), query.fileSymbolCount(idx, file) });
    }
    try w.writeAll("]\n");
}

pub fn listImports(w: *Writer, idx: *const Index, filter: []const u8, opts: Options) !void {
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
}

/// Importers: `{file, importers:[path...]}` per file matching `path`.
pub fn listImporters(w: *Writer, idx: *const Index, path: []const u8, opts: Options) !void {
    _ = opts;
    var first = true;
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
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]\n");
}

fn fileImports(idx: *const Index, src: model.FileId, target: model.FileId) bool {
    for (idx.importsOf(src)) |imp| if (imp.target == target) return true;
    return false;
}

/// Path: a JSON array of the symbols on the shortest call path (empty if none).
pub fn shortestPath(w: *Writer, idx: *const Index, from_name: []const u8, to_name: []const u8, opts: Options) !void {
    _ = opts;
    var fbuf: [64]SymbolId = undefined;
    var tbuf: [64]SymbolId = undefined;
    const chain = query.shortestPathIds(idx, from_name, to_name, &fbuf, &tbuf) catch {
        try w.writeAll("[]\n");
        return;
    };
    defer idx.gpa.free(chain);
    try w.writeByte('[');
    for (chain, 0..) |id, k| {
        if (k != 0) try w.writeByte(',');
        try nodeHead(w, idx, idx.graph.symbols[id]);
        try w.writeByte('}');
    }
    try w.writeAll("]\n");
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
    try nodeHead(w, idx, sym);
    if (sym.parent != invalid) {
        try w.writeAll(",\"parent\":");
        try writeString(w, idx.graph.symbols[sym.parent].name);
    }
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
    try walk(&aw.writer, &idx, "run", false, .{ .depth = 2, .verbosity = .doc, .format = .json });
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
    try showDef(&daw.writer, &idx, "add", .{ .verbosity = .doc, .format = .json });
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
        try showDef(&aw.writer, &idx, "value", .{ .format = .json });
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
        try strings(&aw.writer, &idx, "/api/health", .{ .format = .json });
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
