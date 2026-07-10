const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");
const query = @import("query.zig");
const render = @import("render.zig");
const json_out = @import("json_out.zig");
const hierarchy_mod = @import("hierarchy.zig");
const scan = @import("exception_scan.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

const PathEdge = struct {
    caller: SymbolId,
    callee: SymbolId,
    offset: u32,
    exact: bool,
};

pub const Finding = struct {
    root: SymbolId,
    origin: scan.RaiseSite,
    handler: ?scan.CatchSite,
    path: []SymbolId,
    exact: bool,
};

pub const Trace = struct {
    gpa: std.mem.Allocator,
    findings: []Finding,
    truncated: bool,

    pub fn deinit(self: *Trace) void {
        std.debug.assert(self.findings.len <= std.math.maxInt(u32));
        for (self.findings) |finding| self.gpa.free(finding.path);
        self.gpa.free(self.findings);
        self.* = undefined;
    }
};

pub fn raises(w: *Writer, idx: *const Index, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(opts.limit > 0);
    if (idx.graph.symbols.len == 0) return noRaises(w, selector, opts);
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const resolved = query.resolveIds(idx, selector, storage);
    const roots = try callableIds(idx.gpa, idx, resolved);
    defer idx.gpa.free(roots);
    if (roots.len == 0) return noRaises(w, selector, opts);
    var analysis = try scan.collect(idx.gpa, idx);
    defer analysis.deinit();
    var hierarchy = try hierarchy_mod.build(idx.gpa, idx);
    defer hierarchy.deinit();
    var trace = try traceRoots(idx, &analysis, &hierarchy, roots, opts);
    defer trace.deinit();
    if (opts.format == .json) return raisesJson(w, idx, roots, trace.findings, trace.truncated, opts);
    return raisesText(w, idx, roots, trace.findings, trace.truncated, selector, opts);
}

pub fn catches(w: *Writer, idx: *const Index, exception: []const u8, opts: query.Options) !bool {
    std.debug.assert(exception.len > 0);
    std.debug.assert(opts.limit > 0);
    var analysis = try scan.collect(idx.gpa, idx);
    defer analysis.deinit();
    var hierarchy = try hierarchy_mod.build(idx.gpa, idx);
    defer hierarchy.deinit();
    const handlers = try selectedCatches(idx.gpa, idx, &hierarchy, analysis.catches, exception, opts.strict);
    defer idx.gpa.free(handlers);
    const origins = try selectedRaises(idx.gpa, idx, &hierarchy, analysis.raises, exception, opts.strict);
    defer idx.gpa.free(origins);
    if (opts.format == .json) return catchesJson(w, idx, &analysis, &hierarchy, exception, handlers, origins, opts);
    return catchesText(w, idx, &analysis, &hierarchy, exception, handlers, origins, opts);
}

fn traceRoots(idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, roots: []const SymbolId, opts: query.Options) !Trace {
    std.debug.assert(roots.len > 0);
    std.debug.assert(opts.limit > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(idx.gpa);
    errdefer freeFindings(idx.gpa, findings.items);
    var path: std.ArrayList(SymbolId) = .empty;
    defer path.deinit(idx.gpa);
    var edges: std.ArrayList(PathEdge) = .empty;
    defer edges.deinit(idx.gpa);
    const active = try idx.gpa.alloc(bool, idx.graph.symbols.len);
    defer idx.gpa.free(active);
    var probe_opts = opts;
    probe_opts.limit +|= 1;
    for (roots) |root| {
        if (findings.items.len >= probe_opts.limit) break;
        @memset(active, false);
        path.clearRetainingCapacity();
        edges.clearRetainingCapacity();
        try walkRaises(idx, analysis, hierarchy, root, root, 0, true, probe_opts, active, &path, &edges, &findings);
    }
    const truncated = findings.items.len > opts.limit;
    while (findings.items.len > opts.limit) {
        const extra = findings.pop().?;
        idx.gpa.free(extra.path);
    }
    return .{ .gpa = idx.gpa, .findings = try findings.toOwnedSlice(idx.gpa), .truncated = truncated };
}

fn walkRaises(idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, root: SymbolId, owner: SymbolId, depth: u32, exact: bool, opts: query.Options, active: []bool, path: *std.ArrayList(SymbolId), edges: *std.ArrayList(PathEdge), findings: *std.ArrayList(Finding)) std.mem.Allocator.Error!void {
    std.debug.assert(owner < idx.graph.symbols.len);
    std.debug.assert(active.len == idx.graph.symbols.len);
    if (active[owner]) return;
    active[owner] = true;
    defer active[owner] = false;
    try path.append(idx.gpa, owner);
    defer _ = path.pop();
    try appendOwnerRaises(idx, analysis, hierarchy, root, owner, exact, opts, path.items, edges.items, findings);
    if (depth >= opts.depth or findings.items.len >= opts.limit) return;
    for (idx.graph.symbols[owner].refs) |ref| {
        if (ref.kind != .call or ref.target == invalid or (opts.strict and !ref.exact)) continue;
        if (!isCallable(idx.graph.symbols[ref.target].kind)) continue;
        try walkCallSites(idx, analysis, hierarchy, root, owner, ref, depth, exact, opts, active, path, edges, findings);
        if (findings.items.len >= opts.limit) return;
    }
}

fn walkCallSites(idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, root: SymbolId, owner: SymbolId, ref: model.Reference, depth: u32, exact: bool, opts: query.Options, active: []bool, path: *std.ArrayList(SymbolId), edges: *std.ArrayList(PathEdge), findings: *std.ArrayList(Finding)) std.mem.Allocator.Error!void {
    std.debug.assert(ref.target != invalid);
    std.debug.assert(owner < idx.graph.symbols.len);
    if (ref.offsets.len == 0) {
        const offset = lineOffset(idx.graph.files[idx.graph.symbols[owner].file].text, ref.line);
        try descendCall(idx, analysis, hierarchy, root, owner, ref, offset, depth, exact, opts, active, path, edges, findings);
        return;
    }
    for (ref.offsets) |offset| {
        if (!isCallOccurrence(idx, owner, ref, offset)) continue;
        try descendCall(idx, analysis, hierarchy, root, owner, ref, offset, depth, exact, opts, active, path, edges, findings);
        if (findings.items.len >= opts.limit) return;
    }
}

fn descendCall(idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, root: SymbolId, owner: SymbolId, ref: model.Reference, offset: u32, depth: u32, exact: bool, opts: query.Options, active: []bool, path: *std.ArrayList(SymbolId), edges: *std.ArrayList(PathEdge), findings: *std.ArrayList(Finding)) std.mem.Allocator.Error!void {
    std.debug.assert(ref.target != invalid);
    std.debug.assert(offset <= idx.graph.files[idx.graph.symbols[owner].file].text.len);
    try edges.append(idx.gpa, .{ .caller = owner, .callee = ref.target, .offset = offset, .exact = ref.exact });
    defer _ = edges.pop();
    try walkRaises(idx, analysis, hierarchy, root, ref.target, depth + 1, exact and ref.exact, opts, active, path, edges, findings);
}

fn appendOwnerRaises(idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, root: SymbolId, owner: SymbolId, exact: bool, opts: query.Options, path: []const SymbolId, edges: []const PathEdge, findings: *std.ArrayList(Finding)) !void {
    std.debug.assert(path.len > 0 and path[path.len - 1] == owner);
    std.debug.assert(edges.len + 1 == path.len);
    for (analysis.raises) |origin| {
        if (origin.owner != owner or (opts.strict and !origin.exact)) continue;
        const handler = nearestAlongPath(idx, analysis.catches, hierarchy, origin, edges, opts.strict);
        try appendFinding(idx.gpa, findings, .{
            .root = root,
            .origin = origin,
            .handler = handler,
            .path = try idx.gpa.dupe(SymbolId, path),
            .exact = exact and origin.exact and (handler == null or handler.?.exact),
        });
        if (findings.items.len >= opts.limit) return;
    }
}

fn nearestAlongPath(idx: *const Index, catches_all: []const scan.CatchSite, hierarchy: *const hierarchy_mod.Graph, origin: scan.RaiseSite, edges: []const PathEdge, strict: bool) ?scan.CatchSite {
    std.debug.assert(origin.owner < idx.graph.symbols.len);
    std.debug.assert(edges.len <= idx.graph.symbols.len);
    if (nearestInOwner(idx, catches_all, hierarchy, origin.owner, origin.offset, origin.type_name, strict)) |site| return site;
    var i = edges.len;
    while (i > 0) {
        i -= 1;
        const edge = edges[i];
        if (strict and !edge.exact) continue;
        if (nearestInOwner(idx, catches_all, hierarchy, edge.caller, edge.offset, origin.type_name, strict)) |site| return site;
    }
    return null;
}

fn nearestInOwner(idx: *const Index, catches_all: []const scan.CatchSite, hierarchy: *const hierarchy_mod.Graph, owner: SymbolId, offset: u32, raised: []const u8, strict: bool) ?scan.CatchSite {
    std.debug.assert(owner < idx.graph.symbols.len);
    std.debug.assert(offset <= idx.graph.files[idx.graph.symbols[owner].file].text.len);
    var best: ?scan.CatchSite = null;
    var best_span: u32 = std.math.maxInt(u32);
    for (catches_all) |site| {
        if (site.owner != owner or offset < site.protected_lo or offset >= site.protected_hi) continue;
        if (strict and !site.exact) continue;
        if (!exceptionMatches(idx, hierarchy, raised, site.type_name, site.catch_all, strict)) continue;
        var matched = site;
        if (!strict and externalBaseMatchUsed(idx, raised, site.type_name, site.catch_all)) matched.exact = false;
        const span = site.protected_hi - site.protected_lo;
        if (span < best_span) {
            best = matched;
            best_span = span;
        }
    }
    return best;
}

fn exceptionMatches(idx: *const Index, hierarchy: *const hierarchy_mod.Graph, raised: []const u8, caught: []const u8, catch_all: bool, strict: bool) bool {
    std.debug.assert(raised.len > 0);
    std.debug.assert(caught.len > 0);
    if (catch_all) return true;
    if (std.mem.eql(u8, raised, caught)) return true;
    const raised_id = uniqueContainer(idx, raised) orelse
        return !strict and commonExternalBaseMatches(raised, caught);
    const caught_id = uniqueContainer(idx, caught) orelse
        return !strict and commonExternalBaseMatches(raised, caught);
    const order = hierarchy.mro(idx, raised_id) catch return false;
    defer idx.gpa.free(order);
    return std.mem.indexOfScalar(SymbolId, order, caught_id) != null;
}

fn externalBaseMatchUsed(idx: *const Index, raised: []const u8, caught: []const u8, catch_all: bool) bool {
    std.debug.assert(raised.len > 0);
    std.debug.assert(caught.len > 0);
    if (catch_all or std.mem.eql(u8, raised, caught)) return false;
    if (uniqueContainer(idx, raised) != null and uniqueContainer(idx, caught) != null) return false;
    return commonExternalBaseMatches(raised, caught);
}

fn commonExternalBaseMatches(raised: []const u8, caught: []const u8) bool {
    std.debug.assert(raised.len > 0);
    std.debug.assert(caught.len > 0);
    if (std.mem.eql(u8, caught, "BaseException")) return true;
    if (std.mem.eql(u8, caught, "Exception"))
        return !isExceptionalExit(raised);
    if (std.mem.eql(u8, caught, "StandardError"))
        return !isExceptionalExit(raised);
    if (std.ascii.eqlIgnoreCase(caught, "exception"))
        return containsIgnoreCase(raised, "error") or containsIgnoreCase(raised, "exception");
    return false;
}

fn isExceptionalExit(name: []const u8) bool {
    inline for (.{ "SystemExit", "KeyboardInterrupt", "GeneratorExit", "SignalException", "SystemStackError", "NoMemoryError" }) |special| {
        if (std.mem.eql(u8, name, special)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    std.debug.assert(needle.len > 0);
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn uniqueContainer(idx: *const Index, name: []const u8) ?SymbolId {
    std.debug.assert(name.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var found: ?SymbolId = null;
    for (idx.lookup(name)) |id| {
        if (!isContainer(idx.graph.symbols[id].kind)) continue;
        if (found != null) return null;
        found = id;
    }
    return found;
}

fn appendFinding(gpa: std.mem.Allocator, findings: *std.ArrayList(Finding), finding: Finding) !void {
    std.debug.assert(finding.path.len > 0);
    std.debug.assert(finding.origin.owner == finding.path[finding.path.len - 1]);
    for (findings.items) |existing| {
        if (existing.root == finding.root and existing.origin.offset == finding.origin.offset and optionalCatchOffset(existing.handler) == optionalCatchOffset(finding.handler) and std.mem.eql(u32, existing.path, finding.path)) {
            gpa.free(finding.path);
            return;
        }
    }
    errdefer gpa.free(finding.path);
    try findings.append(gpa, finding);
}

fn optionalCatchOffset(site: ?scan.CatchSite) ?u32 {
    return if (site) |value| value.offset else null;
}

const HandlingStatus = struct {
    handler: ?scan.CatchSite = null,
    unhandled: bool = false,
    exact: bool = true,
};

fn handlingStatus(idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, origin: scan.RaiseSite, strict: bool) !HandlingStatus {
    std.debug.assert(origin.owner < idx.graph.symbols.len);
    std.debug.assert(origin.type_name.len > 0);
    if (nearestInOwner(idx, analysis.catches, hierarchy, origin.owner, origin.offset, origin.type_name, strict)) |site|
        return .{ .handler = site, .exact = origin.exact and site.exact };
    const seen = try idx.gpa.alloc(bool, idx.graph.symbols.len);
    defer idx.gpa.free(seen);
    @memset(seen, false);
    var queue: std.ArrayList(SymbolId) = .empty;
    defer queue.deinit(idx.gpa);
    seen[origin.owner] = true;
    try queue.append(idx.gpa, origin.owner);
    var status = HandlingStatus{ .exact = origin.exact };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const target = queue.items[head];
        var has_caller = false;
        for (idx.callersOf(target)) |caller_id| {
            const outcome = callerOutcome(idx, analysis, hierarchy, idx.graph.symbols[caller_id], target, origin.type_name, strict);
            if (!outcome.had_call) continue;
            has_caller = true;
            status.exact = status.exact and outcome.exact;
            if (status.handler == null) status.handler = outcome.handler;
            if (!outcome.uncaught) continue;
            if (seen[caller_id]) continue;
            seen[caller_id] = true;
            try queue.append(idx.gpa, caller_id);
        }
        if (!has_caller) status.unhandled = true;
    }
    if (status.handler == null) status.unhandled = true;
    return status;
}

const CallerOutcome = struct {
    had_call: bool = false,
    uncaught: bool = false,
    handler: ?scan.CatchSite = null,
    exact: bool = true,
};

fn callerOutcome(idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, caller: model.Symbol, target: SymbolId, raised: []const u8, strict: bool) CallerOutcome {
    std.debug.assert(caller.id < idx.graph.symbols.len);
    std.debug.assert(target < idx.graph.symbols.len);
    var outcome = CallerOutcome{};
    for (caller.refs) |ref| {
        if (ref.target != target or ref.kind != .call or (strict and !ref.exact)) continue;
        outcome.exact = outcome.exact and ref.exact;
        if (ref.offsets.len == 0) {
            const offset = lineOffset(idx.graph.files[caller.file].text, ref.line);
            updateOutcome(idx, analysis, hierarchy, caller.id, offset, raised, strict, &outcome);
        } else for (ref.offsets) |offset| {
            if (isCallOccurrence(idx, caller.id, ref, offset))
                updateOutcome(idx, analysis, hierarchy, caller.id, offset, raised, strict, &outcome);
        }
    }
    return outcome;
}

fn updateOutcome(idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, owner: SymbolId, offset: u32, raised: []const u8, strict: bool, outcome: *CallerOutcome) void {
    std.debug.assert(owner < idx.graph.symbols.len);
    std.debug.assert(offset <= idx.graph.files[idx.graph.symbols[owner].file].text.len);
    outcome.had_call = true;
    if (nearestInOwner(idx, analysis.catches, hierarchy, owner, offset, raised, strict)) |site| {
        outcome.exact = outcome.exact and site.exact;
        if (outcome.handler == null) outcome.handler = site;
    } else {
        outcome.uncaught = true;
    }
}

fn raisesText(w: *Writer, idx: *const Index, roots: []const SymbolId, findings: []const Finding, truncated: bool, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(roots.len > 0);
    std.debug.assert(opts.limit > 0);
    if (findings.len == 0) {
        try w.print("(no exceptions raised by '{s}' within depth {d})\n", .{ selector, opts.depth });
        return false;
    }
    for (roots, 0..) |root, i| {
        if (i != 0) try w.writeByte('\n');
        try render.symbol(w, idx, idx.graph.symbols[root], opts.verbosity, 0, true);
        try w.writeByte('\n');
        for (findings) |finding| if (finding.root == root) try findingText(w, idx, finding);
    }
    if (truncated) try w.print("… (more exceptions; raise -l above {d})\n", .{opts.limit});
    return true;
}

fn findingText(w: *Writer, idx: *const Index, finding: Finding) !void {
    std.debug.assert(finding.root < idx.graph.symbols.len);
    std.debug.assert(finding.path.len > 0);
    try w.print("  {s} {s}  ", .{ if (finding.handler != null) "✓" else "✗", finding.origin.type_name });
    try pathText(w, idx, finding.path);
    if (finding.handler) |handler| {
        const owner = idx.graph.symbols[handler.owner];
        try w.print("  caught by {s} at {s}:{d}", .{ owner.name, idx.graph.files[owner.file].path, handler.line });
    } else {
        try w.writeAll("  unhandled");
    }
    if (!finding.exact) try w.writeAll(" ?");
    try w.writeByte('\n');
}

fn pathText(w: *Writer, idx: *const Index, path: []const SymbolId) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= idx.graph.symbols.len);
    for (path, 0..) |id, i| {
        if (i != 0) try w.writeAll(" → ");
        try w.writeAll(idx.graph.symbols[id].name);
    }
}

fn catchesText(w: *Writer, idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, exception: []const u8, handlers: []const scan.CatchSite, origins: []const scan.RaiseSite, opts: query.Options) !bool {
    std.debug.assert(exception.len > 0);
    std.debug.assert(opts.limit > 0);
    if (handlers.len == 0 and origins.len == 0) {
        try w.print("(no catches or raises matching '{s}')\n", .{exception});
        return false;
    }
    try w.print("catches {s}\nHANDLERS ({d}):\n", .{ exception, handlers.len });
    for (handlers[0..@min(handlers.len, opts.limit)]) |handler| try catchText(w, idx, handler);
    if (handlers.len > opts.limit) try w.print("… ({d} more handlers; raise -l to see them)\n", .{handlers.len - opts.limit});
    try w.print("RAISES ({d}):\n", .{origins.len});
    var shown: usize = 0;
    for (origins) |origin| {
        if (shown >= opts.limit) break;
        const status = try handlingStatus(idx, analysis, hierarchy, origin, opts.strict);
        try originStatusText(w, idx, origin, status);
        shown += 1;
    }
    if (origins.len > shown) try w.print("… ({d} more raises; raise -l to see them)\n", .{origins.len - shown});
    return true;
}

fn catchText(w: *Writer, idx: *const Index, site: scan.CatchSite) !void {
    std.debug.assert(site.owner < idx.graph.symbols.len);
    std.debug.assert(site.protected_lo <= site.protected_hi);
    const owner = idx.graph.symbols[site.owner];
    try w.print("  ⊕ {s}  {s}:{d} in {s}", .{ site.type_name, idx.graph.files[owner.file].path, site.line, owner.name });
    if (!site.exact) try w.writeAll(" ?");
    try w.writeByte('\n');
}

fn originStatusText(w: *Writer, idx: *const Index, origin: scan.RaiseSite, status: HandlingStatus) !void {
    std.debug.assert(origin.owner < idx.graph.symbols.len);
    std.debug.assert(origin.type_name.len > 0);
    const owner = idx.graph.symbols[origin.owner];
    const marker = if (status.handler != null and status.unhandled) "~" else if (status.handler != null) "✓" else "✗";
    try w.print("  {s} {s}  {s}:{d} in {s}", .{ marker, origin.type_name, idx.graph.files[owner.file].path, origin.line, owner.name });
    if (status.handler) |site| try w.print("  → caught at {s}:{d}", .{ idx.graph.files[idx.graph.symbols[site.owner].file].path, site.line });
    if (status.unhandled) try w.writeAll(if (status.handler != null) "; also reaches an unhandled path" else "  unhandled");
    if (!status.exact) try w.writeAll(" ?");
    try w.writeByte('\n');
}

fn raisesJson(w: *Writer, idx: *const Index, roots: []const SymbolId, findings: []const Finding, truncated: bool, opts: query.Options) !bool {
    std.debug.assert(roots.len > 0);
    std.debug.assert(opts.format == .json);
    try w.writeByte('[');
    for (roots, 0..) |root, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try json_out.symbolObject(w, idx, idx.graph.symbols[root], opts.verbosity);
        try w.writeAll(",\"exceptions\":[");
        try findingsJson(w, idx, findings, root);
        try w.print("],\"truncated\":{}}}", .{truncated});
    }
    try w.writeAll("]\n");
    return findings.len != 0;
}

fn findingsJson(w: *Writer, idx: *const Index, findings: []const Finding, root: SymbolId) !void {
    std.debug.assert(root < idx.graph.symbols.len);
    std.debug.assert(findings.len <= std.math.maxInt(u32));
    var first = true;
    for (findings) |finding| {
        if (finding.root != root) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try findingJson(w, idx, finding);
    }
}

fn findingJson(w: *Writer, idx: *const Index, finding: Finding) !void {
    std.debug.assert(finding.path.len > 0);
    std.debug.assert(finding.origin.owner < idx.graph.symbols.len);
    try w.writeAll("{\"type\":");
    try json_out.writeString(w, finding.origin.type_name);
    try w.print(",\"line\":{d},\"exact\":{},\"handled\":{},\"path\":[", .{ finding.origin.line, finding.exact, finding.handler != null });
    for (finding.path, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try json_out.symbolObject(w, idx, idx.graph.symbols[id], .names);
    }
    try w.writeAll("],\"handler\":");
    if (finding.handler) |site| try catchJson(w, idx, site) else try w.writeAll("null");
    try w.writeByte('}');
}

fn catchesJson(w: *Writer, idx: *const Index, analysis: *const scan.Analysis, hierarchy: *const hierarchy_mod.Graph, exception: []const u8, handlers: []const scan.CatchSite, origins: []const scan.RaiseSite, opts: query.Options) !bool {
    std.debug.assert(exception.len > 0);
    std.debug.assert(opts.format == .json);
    try w.writeAll("{\"exception\":");
    try json_out.writeString(w, exception);
    try w.writeAll(",\"handlers\":[");
    for (handlers[0..@min(handlers.len, opts.limit)], 0..) |site, i| {
        if (i != 0) try w.writeByte(',');
        try catchJson(w, idx, site);
    }
    try w.writeAll("],\"raises\":[");
    for (origins[0..@min(origins.len, opts.limit)], 0..) |origin, i| {
        if (i != 0) try w.writeByte(',');
        const status = try handlingStatus(idx, analysis, hierarchy, origin, opts.strict);
        try originJson(w, idx, origin, status);
    }
    try w.print("],\"counts\":{{\"handlers\":{d},\"raises\":{d}}},\"truncated\":{}}}\n", .{
        handlers.len, origins.len, handlers.len > opts.limit or origins.len > opts.limit,
    });
    return handlers.len != 0 or origins.len != 0;
}

fn catchJson(w: *Writer, idx: *const Index, site: scan.CatchSite) !void {
    std.debug.assert(site.owner < idx.graph.symbols.len);
    std.debug.assert(site.type_name.len > 0);
    const owner = idx.graph.symbols[site.owner];
    try w.writeAll("{\"type\":");
    try json_out.writeString(w, site.type_name);
    try w.writeAll(",\"owner\":");
    try json_out.symbolObject(w, idx, owner, .names);
    try w.print(",\"line\":{d},\"catch_all\":{},\"exact\":{}}}", .{ site.line, site.catch_all, site.exact });
}

fn originJson(w: *Writer, idx: *const Index, origin: scan.RaiseSite, status: HandlingStatus) !void {
    std.debug.assert(origin.owner < idx.graph.symbols.len);
    std.debug.assert(origin.type_name.len > 0);
    const state = if (status.handler != null and status.unhandled) "mixed" else if (status.handler != null) "handled" else "unhandled";
    try w.writeAll("{\"type\":");
    try json_out.writeString(w, origin.type_name);
    try w.writeAll(",\"owner\":");
    try json_out.symbolObject(w, idx, idx.graph.symbols[origin.owner], .names);
    try w.print(",\"line\":{d},\"exact\":{},\"handled\":{},\"unhandled\":{},\"status\":", .{ origin.line, status.exact, status.handler != null, status.unhandled });
    try json_out.writeString(w, state);
    try w.writeAll(",\"handler\":");
    if (status.handler) |site| try catchJson(w, idx, site) else try w.writeAll("null");
    try w.writeByte('}');
}

fn selectedCatches(gpa: std.mem.Allocator, idx: *const Index, hierarchy: *const hierarchy_mod.Graph, all: []const scan.CatchSite, pattern: []const u8, strict: bool) ![]scan.CatchSite {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(all.len <= std.math.maxInt(u32));
    const is_glob = std.mem.indexOfScalar(u8, pattern, '*') != null;
    var out: std.ArrayList(scan.CatchSite) = .empty;
    defer out.deinit(gpa);
    for (all) |site| {
        if (strict and !site.exact) continue;
        const matches = site.catch_all or if (is_glob)
            globMatch(pattern, site.type_name)
        else
            exceptionMatches(idx, hierarchy, pattern, site.type_name, false, strict);
        if (!matches) continue;
        var selected = site;
        if (!is_glob and !strict and externalBaseMatchUsed(idx, pattern, site.type_name, site.catch_all)) selected.exact = false;
        try out.append(gpa, selected);
    }
    return out.toOwnedSlice(gpa);
}

fn selectedRaises(gpa: std.mem.Allocator, idx: *const Index, hierarchy: *const hierarchy_mod.Graph, all: []const scan.RaiseSite, pattern: []const u8, strict: bool) ![]scan.RaiseSite {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(all.len <= std.math.maxInt(u32));
    const is_glob = std.mem.indexOfScalar(u8, pattern, '*') != null;
    var out: std.ArrayList(scan.RaiseSite) = .empty;
    defer out.deinit(gpa);
    for (all) |site| {
        if (strict and !site.exact) continue;
        const matches = if (is_glob)
            globMatch(pattern, site.type_name)
        else
            exceptionMatches(idx, hierarchy, site.type_name, pattern, false, strict);
        if (!matches) continue;
        var selected = site;
        if (!is_glob and !strict and externalBaseMatchUsed(idx, site.type_name, pattern, false)) selected.exact = false;
        try out.append(gpa, selected);
    }
    return out.toOwnedSlice(gpa);
}

fn callableIds(gpa: std.mem.Allocator, idx: *const Index, ids: []const SymbolId) ![]SymbolId {
    std.debug.assert(ids.len <= idx.graph.symbols.len);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var out: std.ArrayList(SymbolId) = .empty;
    defer out.deinit(gpa);
    for (ids) |id| if (isCallable(idx.graph.symbols[id].kind)) try out.append(gpa, id);
    return out.toOwnedSlice(gpa);
}

fn isCallable(kind: model.SymbolKind) bool {
    return switch (kind) {
        .function, .method, .test_case, .macro => true,
        else => false,
    };
}

fn isContainer(kind: model.SymbolKind) bool {
    return switch (kind) {
        .class, .@"struct", .interface => true,
        else => false,
    };
}

fn isCallOccurrence(idx: *const Index, owner: SymbolId, ref: model.Reference, offset: u32) bool {
    std.debug.assert(owner < idx.graph.symbols.len);
    std.debug.assert(ref.kind == .call);
    const source = idx.graph.files[idx.graph.symbols[owner].file].text;
    if (offset > source.len or ref.name.len > source.len - offset) return false;
    if (!std.mem.eql(u8, source[offset .. offset + ref.name.len], ref.name)) return false;
    return callSuffixOpen(source, offset + ref.name.len) != null;
}

fn callSuffixOpen(source: []const u8, from: usize) ?usize {
    std.debug.assert(from <= source.len);
    std.debug.assert(source.len <= std.math.maxInt(u32));
    var cursor = from;
    while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) cursor += 1;
    if (cursor < source.len and source[cursor] == '(') return cursor;
    if (cursor + 2 < source.len and source[cursor] == ':' and source[cursor + 1] == ':') cursor += 2;
    while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) cursor += 1;
    if (cursor >= source.len or source[cursor] != '<') return null;
    var depth: u32 = 0;
    while (cursor < source.len) : (cursor += 1) {
        if (source[cursor] == '<') depth += 1;
        if (source[cursor] != '>') continue;
        if (depth == 0) return null;
        depth -= 1;
        if (depth != 0) continue;
        cursor += 1;
        while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) cursor += 1;
        return if (cursor < source.len and source[cursor] == '(') cursor else null;
    }
    return null;
}

fn lineOffset(source: []const u8, line: u32) u32 {
    std.debug.assert(line > 0);
    std.debug.assert(source.len <= std.math.maxInt(u32));
    var current: u32 = 1;
    for (source, 0..) |c, i| {
        if (current == line) return @intCast(i);
        if (c == '\n') current += 1;
    }
    return @intCast(source.len);
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(text.len > 0);
    var pattern_i: usize = 0;
    var text_i: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (text_i < text.len) {
        if (pattern_i < pattern.len and pattern[pattern_i] == text[text_i]) {
            pattern_i += 1;
            text_i += 1;
        } else if (pattern_i < pattern.len and pattern[pattern_i] == '*') {
            star = pattern_i;
            pattern_i += 1;
            retry = text_i;
        } else if (star) |at| {
            retry += 1;
            text_i = retry;
            pattern_i = at + 1;
        } else return false;
    }
    while (pattern_i < pattern.len and pattern[pattern_i] == '*') pattern_i += 1;
    return pattern_i == pattern.len;
}

fn noRaises(w: *Writer, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(opts.limit > 0);
    if (opts.format == .json) try w.writeAll("[]\n") else try w.print("(no callable symbol named '{s}')\n", .{selector});
    return false;
}

fn freeFindings(gpa: std.mem.Allocator, findings: []Finding) void {
    std.debug.assert(findings.len <= std.math.maxInt(u32));
    std.debug.assert(@intFromPtr(gpa.ptr) != 0);
    for (findings) |finding| gpa.free(finding.path);
}

test "exception trace stops at the nearest matching handler" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "service.py", .data =
        \\class OrderError(Exception): pass
        \\def leaf():
        \\    raise OrderError("bad")
        \\def handled():
        \\    saved = leaf
        \\    try:
        \\        leaf()
        \\    except OrderError:
        \\        return None
        \\def open_gap():
        \\    leaf()
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var analysis = try scan.collect(testing.allocator, &idx);
    defer analysis.deinit();
    var hierarchy = try hierarchy_mod.build(testing.allocator, &idx);
    defer hierarchy.deinit();
    const roots = [_]SymbolId{ idx.lookup("handled")[0], idx.lookup("open_gap")[0] };
    var trace = try traceRoots(&idx, &analysis, &hierarchy, &roots, .{ .depth = 2 });
    defer trace.deinit();
    try testing.expectEqual(@as(usize, 2), trace.findings.len);
    try testing.expect(trace.findings[0].handler != null);
    try testing.expect(trace.findings[1].handler == null);
    var limited = try traceRoots(&idx, &analysis, &hierarchy, &roots, .{ .depth = 2, .limit = 1 });
    defer limited.deinit();
    try testing.expectEqual(@as(usize, 1), limited.findings.len);
    try testing.expect(limited.truncated);
    const mixed = try handlingStatus(&idx, &analysis, &hierarchy, analysis.raises[0], false);
    try testing.expect(mixed.handler != null);
    try testing.expect(mixed.unhandled);

    var output_bytes: std.ArrayList(u8) = .empty;
    defer output_bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &output_bytes);
    defer output.deinit();
    try testing.expect(try raises(&output.writer, &idx, "handled", .{ .depth = 2, .format = .json }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"handled\":true") != null);
}

test "generic call occurrences survive grouped reference revalidation" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 12), callSuffixOpen("leaf<string>(value)", 4));
    try testing.expectEqual(@as(?usize, 14), callSuffixOpen("leaf::<String>(value)", 4));
    try testing.expect(callSuffixOpen("leaf = saved", 4) == null);
}

test "exception subtype is caught by a nominal base handler" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "errors.py", .data =
        \\class AppError(Exception): pass
        \\class OrderError(AppError): pass
        \\def run():
        \\    try:
        \\        raise OrderError("bad")
        \\    except AppError:
        \\        return None
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var analysis = try scan.collect(testing.allocator, &idx);
    defer analysis.deinit();
    var hierarchy = try hierarchy_mod.build(testing.allocator, &idx);
    defer hierarchy.deinit();
    const site = nearestInOwner(&idx, analysis.catches, &hierarchy, idx.lookup("run")[0], analysis.raises[0].offset, "OrderError", false);
    try testing.expect(site != null);
    try testing.expect(std.mem.eql(u8, site.?.type_name, "AppError"));
    const base_origins = try selectedRaises(testing.allocator, &idx, &hierarchy, analysis.raises, "AppError", false);
    defer testing.allocator.free(base_origins);
    try testing.expectEqual(@as(usize, 1), base_origins.len);
    try testing.expectEqualStrings("OrderError", base_origins[0].type_name);
}

test "external standard exception bases match heuristically" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "builtin.py", .data =
        \\def run():
        \\    try:
        \\        raise ValueError("bad")
        \\    except Exception:
        \\        return None
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var analysis = try scan.collect(testing.allocator, &idx);
    defer analysis.deinit();
    var hierarchy = try hierarchy_mod.build(testing.allocator, &idx);
    defer hierarchy.deinit();
    const run_id = idx.lookup("run")[0];
    const matched = nearestInOwner(&idx, analysis.catches, &hierarchy, run_id, analysis.raises[0].offset, "ValueError", false);
    try testing.expect(matched != null);
    try testing.expect(!matched.?.exact);
    try testing.expect(nearestInOwner(&idx, analysis.catches, &hierarchy, run_id, analysis.raises[0].offset, "ValueError", true) == null);
    const handlers = try selectedCatches(testing.allocator, &idx, &hierarchy, analysis.catches, "ValueError", false);
    defer testing.allocator.free(handlers);
    try testing.expectEqual(@as(usize, 1), handlers.len);
    try testing.expect(!handlers[0].exact);
    const origins = try selectedRaises(testing.allocator, &idx, &hierarchy, analysis.raises, "Exception", false);
    defer testing.allocator.free(origins);
    try testing.expectEqual(@as(usize, 1), origins.len);
    try testing.expect(!origins[0].exact);
}

test "catches treats converging caller branches as one propagation state" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "converge.py", .data =
        \\class OrderError(Exception): pass
        \\def leaf(): raise OrderError("bad")
        \\def left(): leaf()
        \\def right(): leaf()
        \\def join():
        \\    left()
        \\    right()
        \\def guarded():
        \\    try: join()
        \\    except OrderError: return None
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var analysis = try scan.collect(testing.allocator, &idx);
    defer analysis.deinit();
    var hierarchy = try hierarchy_mod.build(testing.allocator, &idx);
    defer hierarchy.deinit();
    try testing.expectEqual(@as(usize, 1), analysis.raises.len);
    const status = try handlingStatus(&idx, &analysis, &hierarchy, analysis.raises[0], false);
    try testing.expect(status.handler != null);
    try testing.expect(!status.unhandled);
    try testing.expectEqualStrings("guarded", idx.graph.symbols[status.handler.?.owner].name);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &bytes);
    defer output.deinit();
    try testing.expect(try catches(&output.writer, &idx, "OrderError", .{ .format = .json }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"status\":\"handled\"") != null);
}

test "Ruby bare rescue does not claim to handle SystemExit" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "exit.rb", .data =
        \\def terminate
        \\  begin
        \\    raise SystemExit.new
        \\  rescue
        \\    nil
        \\  end
        \\end
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var analysis = try scan.collect(testing.allocator, &idx);
    defer analysis.deinit();
    var hierarchy = try hierarchy_mod.build(testing.allocator, &idx);
    defer hierarchy.deinit();
    try testing.expectEqualStrings("StandardError", analysis.catches[0].type_name);
    const handlers = try selectedCatches(testing.allocator, &idx, &hierarchy, analysis.catches, "SystemExit", false);
    defer testing.allocator.free(handlers);
    try testing.expectEqual(@as(usize, 0), handlers.len);
    try testing.expect(nearestInOwner(&idx, analysis.catches, &hierarchy, analysis.raises[0].owner, analysis.raises[0].offset, "SystemExit", false) == null);
}

test "strict catches excludes conditional C# catch filters" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Service.cs", .data =
        \\class OrderError : Exception {}
        \\class Service {
        \\  void Run() {
        \\    try { throw new OrderError(); }
        \\    catch (OrderError error) when (ShouldHandle(error)) {}
        \\  }
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var analysis = try scan.collect(testing.allocator, &idx);
    defer analysis.deinit();
    var hierarchy = try hierarchy_mod.build(testing.allocator, &idx);
    defer hierarchy.deinit();
    const loose = try selectedCatches(testing.allocator, &idx, &hierarchy, analysis.catches, "OrderError", false);
    defer testing.allocator.free(loose);
    try testing.expectEqual(@as(usize, 1), loose.len);
    try testing.expect(!loose[0].exact);
    const strict = try selectedCatches(testing.allocator, &idx, &hierarchy, analysis.catches, "OrderError", true);
    defer testing.allocator.free(strict);
    try testing.expectEqual(@as(usize, 0), strict.len);
}
