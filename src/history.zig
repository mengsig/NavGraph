const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");
const query = @import("query.zig");
const render = @import("render.zig");
const json_out = @import("json_out.zig");
const gitdiff = @import("gitdiff.zig");
const gitutil = @import("gitutil.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const SymbolId = model.SymbolId;

const Commit = struct {
    sha: []const u8,
    author: []const u8,
    date: []const u8,
    subject: []const u8,
    patch: []const u8,
};

const BlameLine = struct {
    sha: []const u8,
    author: []const u8,
    author_time: []const u8,
    summary: []const u8,
    line: u32,
};

const ChurnEntry = struct {
    id: SymbolId,
    commits: u32 = 0,
    lines: u32 = 0,
};

pub fn history(w: *Writer, io: std.Io, idx: *const Index, root: []const u8, selector: []const u8, opts: query.Options) !bool {
    return historyAt(w, io, idx, .{ .path = root }, selector, opts);
}

pub fn historyAt(w: *Writer, io: std.Io, idx: *const Index, root: gitutil.Root, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    const ids = try resolveSymbols(idx, selector);
    defer idx.gpa.free(ids);
    if (ids.len == 0) return noSymbol(w, selector, opts);
    if (opts.format == .json) try w.writeByte('[');
    var emitted: u32 = 0;
    var rows: u32 = 0;
    for (ids[0..@min(ids.len, opts.limit)]) |id| {
        const fetch_last = opts.history_last +| 1;
        const result = runHistory(idx.gpa, io, root, idx, id, fetch_last) catch |err| {
            if (opts.format == .json) {
                if (rows != 0) try w.writeByte(',');
                try symbolGitErrorJson(w, idx, id, "history", @errorName(err));
                rows += 1;
            } else try w.print("navgraph: history failed for {s} ({s})\n", .{ idx.graph.symbols[id].name, @errorName(err) });
            continue;
        };
        defer freeRunResult(idx.gpa, result);
        if (!runSucceeded(result)) {
            if (opts.format == .json) {
                if (rows != 0) try w.writeByte(',');
                try symbolGitErrorJson(w, idx, id, "history", result.stderr);
                rows += 1;
            } else try gitFailure(w, "history", result.stderr);
            continue;
        }
        const commits = try parseCommits(idx.gpa, result.stdout);
        defer idx.gpa.free(commits);
        const visible = commits[0..@min(commits.len, opts.history_last)];
        const truncated = commits.len > opts.history_last;
        if (opts.format == .json) {
            if (rows != 0) try w.writeByte(',');
            try historyJson(w, idx, id, visible, truncated, opts);
            rows += 1;
        } else {
            if (emitted != 0) try w.writeByte('\n');
            try historyText(w, idx, id, visible, truncated, opts);
        }
        emitted += 1;
    }
    if (opts.format == .json) try w.writeAll("]\n");
    return emitted != 0;
}

pub fn blame(w: *Writer, io: std.Io, idx: *const Index, root: []const u8, selector: []const u8, opts: query.Options) !bool {
    return blameAt(w, io, idx, .{ .path = root }, selector, opts);
}

pub fn blameAt(w: *Writer, io: std.Io, idx: *const Index, root: gitutil.Root, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    const ids = try resolveSymbols(idx, selector);
    defer idx.gpa.free(ids);
    if (ids.len == 0) return noSymbol(w, selector, opts);
    if (opts.format == .json) try w.writeByte('[');
    var emitted: u32 = 0;
    var rows: u32 = 0;
    for (ids[0..@min(ids.len, opts.limit)]) |id| {
        const result = runBlame(idx.gpa, io, root, idx, id) catch |err| {
            if (opts.format == .json) {
                if (rows != 0) try w.writeByte(',');
                try symbolGitErrorJson(w, idx, id, "blame", @errorName(err));
                rows += 1;
            } else try w.print("navgraph: blame failed for {s} ({s})\n", .{ idx.graph.symbols[id].name, @errorName(err) });
            continue;
        };
        defer freeRunResult(idx.gpa, result);
        if (!runSucceeded(result)) {
            if (opts.format == .json) {
                if (rows != 0) try w.writeByte(',');
                try symbolGitErrorJson(w, idx, id, "blame", result.stderr);
                rows += 1;
            } else try gitFailure(w, "blame", result.stderr);
            continue;
        }
        const lines = try parseBlame(idx.gpa, result.stdout);
        defer idx.gpa.free(lines);
        if (opts.format == .json) {
            if (rows != 0) try w.writeByte(',');
            try blameJson(w, idx, id, lines, opts);
            rows += 1;
        } else {
            if (emitted != 0) try w.writeByte('\n');
            try blameText(w, idx, id, lines, opts);
        }
        emitted += 1;
    }
    if (opts.format == .json) try w.writeAll("]\n");
    return emitted != 0;
}

pub fn churn(w: *Writer, io: std.Io, idx: *const Index, root: []const u8, filter: []const u8, opts: query.Options) !bool {
    return churnAt(w, io, idx, .{ .path = root }, filter, opts);
}

pub fn churnAt(w: *Writer, io: std.Io, idx: *const Index, root: gitutil.Root, filter: []const u8, opts: query.Options) !bool {
    std.debug.assert(opts.history_last > 0);
    const result = runChurn(idx.gpa, io, root, opts) catch |err| {
        if (opts.format == .json) try gitErrorJson(w, "churn", @errorName(err)) else try w.print("navgraph: churn failed ({s})\n", .{@errorName(err)});
        return false;
    };
    defer freeRunResult(idx.gpa, result);
    if (!runSucceeded(result)) {
        if (try isUnbornRepository(idx.gpa, io, root)) {
            const empty = try idx.gpa.alloc(ChurnEntry, 0);
            defer idx.gpa.free(empty);
            if (opts.format == .json) return churnJson(w, idx, empty, opts);
            return churnText(w, idx, empty, opts);
        }
        if (opts.format == .json) try gitErrorJson(w, "churn", result.stderr) else try gitFailure(w, "churn", result.stderr);
        return false;
    }
    const entries = try collectChurn(idx, result.stdout, filter, opts.churn_sort);
    defer idx.gpa.free(entries);
    if (opts.format == .json) return churnJson(w, idx, entries, opts);
    return churnText(w, idx, entries, opts);
}

fn runHistory(gpa: std.mem.Allocator, io: std.Io, root: gitutil.Root, idx: *const Index, id: SymbolId, last: u32) !std.process.RunResult {
    std.debug.assert(id < idx.graph.symbols.len);
    std.debug.assert(last > 0);
    const sym = idx.graph.symbols[id];
    const file = idx.graph.files[sym.file];
    const range = try std.fmt.allocPrint(gpa, "-L{d},{d}:{s}", .{ symbolStartLine(sym, file.text), sym.endLine(file.text), file.path });
    defer gpa.free(range);
    const last_arg = try std.fmt.allocPrint(gpa, "{d}", .{last});
    defer gpa.free(last_arg);
    const argv = [_][]const u8{ "git", "-c", "core.quotePath=false", "log", "--no-ext-diff", "--no-textconv", "--no-color", "--date=short", "--format=NG:%H%x00%an%x00%ad%x00%s", "-n", last_arg, range };
    return gitutil.runAt(gpa, io, root, &argv);
}

fn runBlame(gpa: std.mem.Allocator, io: std.Io, root: gitutil.Root, idx: *const Index, id: SymbolId) !std.process.RunResult {
    std.debug.assert(id < idx.graph.symbols.len);
    const sym = idx.graph.symbols[id];
    const file = idx.graph.files[sym.file];
    const range = try std.fmt.allocPrint(gpa, "{d},{d}", .{ symbolStartLine(sym, file.text), sym.endLine(file.text) });
    defer gpa.free(range);
    const argv = [_][]const u8{ "git", "blame", "--line-porcelain", "-L", range, "--", file.path };
    return gitutil.runAt(gpa, io, root, &argv);
}

fn runChurn(gpa: std.mem.Allocator, io: std.Io, root: gitutil.Root, opts: query.Options) !std.process.RunResult {
    std.debug.assert(opts.history_last > 0);
    const last_arg = try std.fmt.allocPrint(gpa, "{d}", .{opts.history_last});
    defer gpa.free(last_arg);
    var range: ?[]u8 = null;
    defer if (range) |value| gpa.free(value);
    if (opts.since.len != 0) {
        if (!gitutil.validLowerBoundRef(opts.since)) return error.InvalidGitRef;
        range = try std.fmt.allocPrint(gpa, "{s}..HEAD", .{opts.since});
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-c", "core.quotePath=false", "log", "--no-ext-diff", "--no-textconv", "--no-color", "--format=NGCOMMIT:%H", "-n", last_arg, "--unified=0", "-p" });
    if (range) |value| try argv.append(gpa, value);
    try argv.append(gpa, "--");
    return gitutil.runAt(gpa, io, root, argv.items);
}

fn parseCommits(gpa: std.mem.Allocator, text: []const u8) ![]Commit {
    std.debug.assert(text.len <= 32 * 1024 * 1024);
    std.debug.assert(@intFromPtr(text.ptr) != 0 or text.len == 0);
    var out: std.ArrayList(Commit) = .empty;
    defer out.deinit(gpa);
    var cursor: usize = 0;
    while (nextMarker(text, cursor, "NG:")) |start| {
        const line_end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const next = nextMarker(text, line_end, "NG:") orelse text.len;
        if (parseCommitHeader(text[start + 3 .. line_end])) |header| {
            try out.append(gpa, .{ .sha = header[0], .author = header[1], .date = header[2], .subject = header[3], .patch = std.mem.trim(u8, text[line_end..next], "\n\r") });
        }
        cursor = next;
        if (cursor == text.len) break;
    }
    return out.toOwnedSlice(gpa);
}

fn parseCommitHeader(line: []const u8) ?[4][]const u8 {
    std.debug.assert(@intFromPtr(line.ptr) != 0 or line.len == 0);
    std.debug.assert(line.len <= 32 * 1024 * 1024);
    var fields: [4][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, 0);
    for (&fields) |*field| field.* = it.next() orelse return null;
    if (it.next() != null) return null;
    return fields;
}

fn parseBlame(gpa: std.mem.Allocator, text: []const u8) ![]BlameLine {
    std.debug.assert(text.len <= 32 * 1024 * 1024);
    std.debug.assert(@intFromPtr(text.ptr) != 0 or text.len == 0);
    var out: std.ArrayList(BlameLine) = .empty;
    defer out.deinit(gpa);
    var current: BlameLine = .{ .sha = "", .author = "", .author_time = "", .summary = "", .line = 0 };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (blameHeader(line)) |head| current = .{ .sha = head.sha, .author = "", .author_time = "", .summary = "", .line = head.line } else if (std.mem.startsWith(u8, line, "author ")) current.author = line[7..] else if (std.mem.startsWith(u8, line, "author-time ")) current.author_time = line[12..] else if (std.mem.startsWith(u8, line, "summary ")) current.summary = line[8..] else if (line.len != 0 and line[0] == '\t' and current.sha.len != 0) try out.append(gpa, current);
    }
    return out.toOwnedSlice(gpa);
}

const BlameHeader = struct { sha: []const u8, line: u32 };

fn blameHeader(line: []const u8) ?BlameHeader {
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    const sha = parts.next() orelse return null;
    if (sha.len != 40 and sha.len != 64) return null;
    for (sha) |c| if (!std.ascii.isHex(c)) return null;
    _ = parts.next() orelse return null;
    const final = parts.next() orelse return null;
    const line_no = std.fmt.parseInt(u32, final, 10) catch return null;
    return .{ .sha = sha, .line = line_no };
}

fn collectChurn(idx: *const Index, text: []const u8, filter: []const u8, sort: query.ChurnSort) ![]ChurnEntry {
    std.debug.assert(text.len <= 32 * 1024 * 1024);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    const tallies = try idx.gpa.alloc(ChurnEntry, idx.graph.symbols.len);
    defer idx.gpa.free(tallies);
    for (tallies, 0..) |*entry, id| entry.* = .{ .id = @intCast(id) };
    var cursor: usize = 0;
    while (nextMarker(text, cursor, "NGCOMMIT:")) |start| {
        const body_start = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const next = nextMarker(text, body_start, "NGCOMMIT:") orelse text.len;
        try tallyCommit(idx, tallies, text[body_start..next], filter);
        cursor = next;
        if (cursor == text.len) break;
    }
    var out: std.ArrayList(ChurnEntry) = .empty;
    defer out.deinit(idx.gpa);
    for (tallies) |entry| if (entry.commits != 0) try out.append(idx.gpa, entry);
    std.mem.sort(ChurnEntry, out.items, ChurnContext{ .idx = idx, .sort = sort }, churnLessThan);
    return out.toOwnedSlice(idx.gpa);
}

fn tallyCommit(idx: *const Index, tallies: []ChurnEntry, patch: []const u8, filter: []const u8) !void {
    std.debug.assert(tallies.len == idx.graph.symbols.len);
    std.debug.assert(patch.len <= 32 * 1024 * 1024);
    const changes = try gitdiff.parseWithRemoved(idx.gpa, patch);
    defer gitdiff.freeChanges(idx.gpa, changes);
    const touched = try idx.gpa.alloc(bool, idx.graph.symbols.len);
    defer idx.gpa.free(touched);
    @memset(touched, false);
    for (changes) |change| {
        const file = query.findDiffFile(idx, change.path) orelse continue;
        if (!query.matchesFilter(file.path, filter)) continue;
        var id = file.sym_start;
        while (id < file.sym_end) : (id += 1) {
            const sym = idx.graph.symbols[id];
            if (!query.symbolTouched(sym, file.text, change.ranges)) continue;
            tallies[id].lines +|= changedLinesForSymbol(sym, file.text, change.ranges);
            touched[id] = true;
        }
    }
    for (touched, 0..) |hit, id| if (hit) {
        tallies[id].commits +|= 1;
    };
}

fn changedLinesForSymbol(sym: model.Symbol, source: []const u8, ranges: []const gitdiff.Range) u32 {
    std.debug.assert(sym.span_end <= source.len);
    std.debug.assert(sym.line <= sym.endLine(source));
    const sym_hi = sym.endLine(source);
    var total: u32 = 0;
    for (ranges) |range| {
        const range_lo = if (range.empty and range.lo == 0) @as(u32, 1) else range.lo;
        const range_hi = if (range.empty and range.hi == 0) @as(u32, 1) else range.hi;
        if (range_hi < sym.line or range_lo > sym_hi) continue;
        const lo = @max(range_lo, sym.line);
        const hi = @min(range_hi, sym_hi);
        const added = if (range.empty) 0 else hi - lo + 1;
        const changed = added +| range.removed;
        total +|= if (changed == 0) 1 else changed;
    }
    return total;
}

fn changedLines(ranges: []const gitdiff.Range) u32 {
    std.debug.assert(ranges.len <= std.math.maxInt(u32));
    std.debug.assert(ranges.len == 0 or ranges[0].lo > 0);
    var total: u32 = 0;
    for (ranges) |range| {
        const added = if (range.empty) 0 else @max(1, range.hi - range.lo + 1);
        const changed = added +| range.removed;
        total +|= if (changed == 0) 1 else changed;
    }
    return total;
}

const ChurnContext = struct { idx: *const Index, sort: query.ChurnSort };

fn churnLessThan(ctx: ChurnContext, a: ChurnEntry, b: ChurnEntry) bool {
    if (ctx.sort == .lines and a.lines != b.lines) return a.lines > b.lines;
    if (ctx.sort == .commits and a.commits != b.commits) return a.commits > b.commits;
    if (a.commits != b.commits) return a.commits > b.commits;
    if (a.lines != b.lines) return a.lines > b.lines;
    const sa = ctx.idx.graph.symbols[a.id];
    const sb = ctx.idx.graph.symbols[b.id];
    return std.mem.lessThan(u8, sa.name, sb.name);
}

fn historyText(w: *Writer, idx: *const Index, id: SymbolId, commits: []const Commit, truncated: bool, opts: query.Options) !void {
    std.debug.assert(id < idx.graph.symbols.len);
    std.debug.assert(opts.history_last > 0);
    try render.symbol(w, idx, idx.graph.symbols[id], opts.verbosity, 0, true);
    try w.print("\nHISTORY ({d} commit{s}):\n", .{ commits.len, if (commits.len == 1) "" else "s" });
    for (commits) |commit| {
        try w.print("  {s}  {s}  {s}  {s}\n", .{ shortSha(commit.sha), commit.date, commit.author, commit.subject });
        if (opts.verbosity == .full and commit.patch.len != 0) try indentedPatch(w, commit.patch);
    }
    if (truncated) try w.print("… (more history; raise --last above {d})\n", .{opts.history_last});
}

fn blameText(w: *Writer, idx: *const Index, id: SymbolId, lines: []const BlameLine, opts: query.Options) !void {
    std.debug.assert(id < idx.graph.symbols.len);
    std.debug.assert(opts.limit > 0);
    try render.symbol(w, idx, idx.graph.symbols[id], opts.verbosity, 0, true);
    try w.print("\nBLAME ({d} lines):\n", .{lines.len});
    for (lines[0..@min(lines.len, opts.limit)]) |line| try w.print("  {d:>5}  {s}  {s}  {s}\n", .{ line.line, shortSha(line.sha), line.author, line.summary });
    if (lines.len > opts.limit) try w.print("… ({d} more; raise -l to see them)\n", .{lines.len - opts.limit});
}

fn churnText(w: *Writer, idx: *const Index, entries: []const ChurnEntry, opts: query.Options) !bool {
    std.debug.assert(opts.limit > 0);
    std.debug.assert(entries.len <= idx.graph.symbols.len);
    if (entries.len == 0) {
        try w.writeAll("(no symbol churn in the selected history)\n");
        return false;
    }
    for (entries[0..@min(entries.len, opts.limit)]) |entry| {
        try w.print("{d:>4} commits  {d:>5} lines  ~ ", .{ entry.commits, entry.lines });
        try render.symbol(w, idx, idx.graph.symbols[entry.id], opts.verbosity, 0, true);
    }
    if (entries.len > opts.limit) try w.print("… ({d} more; raise -l to see them)\n", .{entries.len - opts.limit});
    try w.writeAll("~ historical hunks are mapped to current symbol ranges (heuristic after moves)\n");
    return true;
}

fn historyJson(w: *Writer, idx: *const Index, id: SymbolId, commits: []const Commit, truncated: bool, opts: query.Options) !void {
    std.debug.assert(id < idx.graph.symbols.len);
    std.debug.assert(opts.history_last > 0);
    try w.writeAll("{\"symbol\":");
    try json_out.symbolObject(w, idx, idx.graph.symbols[id], opts.verbosity);
    try w.writeAll(",\"commits\":[");
    for (commits, 0..) |commit, i| {
        if (i != 0) try w.writeByte(',');
        try commitJson(w, commit, opts.verbosity == .full);
    }
    try w.print("],\"truncated\":{}}}", .{truncated});
}

fn blameJson(w: *Writer, idx: *const Index, id: SymbolId, lines: []const BlameLine, opts: query.Options) !void {
    std.debug.assert(id < idx.graph.symbols.len);
    std.debug.assert(opts.limit > 0);
    try w.writeAll("{\"symbol\":");
    try json_out.symbolObject(w, idx, idx.graph.symbols[id], opts.verbosity);
    try w.writeAll(",\"lines\":[");
    for (lines[0..@min(lines.len, opts.limit)], 0..) |line, i| {
        if (i != 0) try w.writeByte(',');
        try blameLineJson(w, line);
    }
    try w.print("],\"truncated\":{}}}", .{lines.len > opts.limit});
}

fn churnJson(w: *Writer, idx: *const Index, entries: []const ChurnEntry, opts: query.Options) !bool {
    std.debug.assert(opts.format == .json);
    std.debug.assert(opts.limit > 0);
    try w.writeAll("{\"entries\":[");
    for (entries[0..@min(entries.len, opts.limit)], 0..) |entry, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try json_out.symbolObject(w, idx, idx.graph.symbols[entry.id], opts.verbosity);
        try w.print(",\"commits\":{d},\"lines\":{d},\"exact\":false}}", .{ entry.commits, entry.lines });
    }
    try w.print("],\"count\":{d},\"truncated\":{},\"exact\":false}}\n", .{ entries.len, entries.len > opts.limit });
    return entries.len != 0;
}

fn commitJson(w: *Writer, commit: Commit, include_patch: bool) !void {
    std.debug.assert(commit.sha.len > 0);
    std.debug.assert(commit.subject.len <= 32 * 1024 * 1024);
    try w.writeAll("{\"sha\":");
    try json_out.writeString(w, commit.sha);
    try w.writeAll(",\"author\":");
    try json_out.writeString(w, commit.author);
    try w.writeAll(",\"date\":");
    try json_out.writeString(w, commit.date);
    try w.writeAll(",\"subject\":");
    try json_out.writeString(w, commit.subject);
    if (include_patch) {
        try w.writeAll(",\"patch\":");
        try json_out.writeString(w, commit.patch);
    }
    try w.writeByte('}');
}

fn blameLineJson(w: *Writer, line: BlameLine) !void {
    std.debug.assert(line.sha.len > 0);
    std.debug.assert(line.line > 0);
    try w.print("{{\"line\":{d},\"sha\":", .{line.line});
    try json_out.writeString(w, line.sha);
    try w.writeAll(",\"author\":");
    try json_out.writeString(w, line.author);
    try w.writeAll(",\"author_time\":");
    try json_out.writeString(w, line.author_time);
    try w.writeAll(",\"summary\":");
    try json_out.writeString(w, line.summary);
    try w.writeByte('}');
}

fn resolveSymbols(idx: *const Index, selector: []const u8) ![]SymbolId {
    std.debug.assert(selector.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    if (idx.graph.symbols.len == 0) return idx.gpa.alloc(SymbolId, 0);
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const ids = query.resolveIds(idx, selector, storage);
    return idx.gpa.dupe(SymbolId, ids);
}

fn nextMarker(text: []const u8, from: usize, marker: []const u8) ?usize {
    std.debug.assert(from <= text.len);
    std.debug.assert(marker.len > 0);
    var cursor = from;
    while (std.mem.indexOfPos(u8, text, cursor, marker)) |at| {
        if (at == 0 or text[at - 1] == '\n') return at;
        cursor = at + marker.len;
    }
    return null;
}

fn indentedPatch(w: *Writer, patch: []const u8) !void {
    std.debug.assert(patch.len > 0);
    std.debug.assert(patch.len <= 32 * 1024 * 1024);
    var it = std.mem.splitScalar(u8, patch, '\n');
    while (it.next()) |line| try w.print("    {s}\n", .{line});
}

fn symbolStartLine(sym: model.Symbol, source: []const u8) u32 {
    std.debug.assert(sym.span_start <= sym.span_end);
    std.debug.assert(sym.span_end <= source.len);
    var line: u32 = 1;
    for (source[0..sym.span_start]) |c| if (c == '\n') {
        line += 1;
    };
    return line;
}

fn shortSha(sha: []const u8) []const u8 {
    return sha[0..@min(sha.len, 10)];
}

fn isUnbornRepository(gpa: std.mem.Allocator, io: std.Io, root: gitutil.Root) !bool {
    const argv = [_][]const u8{ "git", "rev-parse", "--verify", "--quiet", "HEAD" };
    const result = try gitutil.runAt(gpa, io, root, &argv);
    defer freeRunResult(gpa, result);
    if (result.term != .exited) return false;
    return result.term.exited == 1;
}

fn runSucceeded(result: std.process.RunResult) bool {
    return result.term == .exited and result.term.exited == 0;
}

fn freeRunResult(gpa: std.mem.Allocator, result: std.process.RunResult) void {
    gpa.free(result.stdout);
    gpa.free(result.stderr);
}

fn symbolGitErrorJson(w: *Writer, idx: *const Index, id: SymbolId, verb: []const u8, message: []const u8) !void {
    std.debug.assert(id < idx.graph.symbols.len);
    std.debug.assert(verb.len > 0);
    try w.writeAll("{\"symbol\":");
    try json_out.symbolObject(w, idx, idx.graph.symbols[id], .names);
    try w.writeAll(",\"error\":");
    try gitErrorObject(w, verb, message);
    try w.writeByte('}');
}

fn gitErrorJson(w: *Writer, verb: []const u8, message: []const u8) !void {
    std.debug.assert(verb.len > 0);
    std.debug.assert(message.len <= 4 * 1024 * 1024);
    try w.writeAll("{\"error\":");
    try gitErrorObject(w, verb, message);
    try w.writeAll("}\n");
}

fn gitErrorObject(w: *Writer, verb: []const u8, message: []const u8) !void {
    std.debug.assert(verb.len > 0);
    std.debug.assert(message.len <= 4 * 1024 * 1024);
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    try w.writeAll("{\"command\":");
    try json_out.writeString(w, verb);
    try w.writeAll(",\"message\":");
    try json_out.writeString(w, if (trimmed.len == 0) "git command failed" else trimmed);
    try w.writeByte('}');
}

fn gitFailure(w: *Writer, verb: []const u8, stderr: []const u8) !void {
    std.debug.assert(verb.len > 0);
    std.debug.assert(stderr.len <= 4 * 1024 * 1024);
    try w.print("navgraph: git {s} failed: {s}\n", .{ verb, std.mem.trim(u8, stderr, " \t\r\n") });
}

fn noSymbol(w: *Writer, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(opts.limit > 0);
    if (opts.format == .json) try w.writeAll("[]\n") else try w.print("(no symbol named '{s}')\n", .{selector});
    return false;
}

fn runGitTest(io: std.Io, root: []const u8, argv: []const []const u8) !void {
    std.debug.assert(root.len > 0);
    std.debug.assert(argv.len >= 2 and std.mem.eql(u8, argv[0], "git"));
    const result = try gitutil.run(std.testing.allocator, io, root, argv);
    defer freeRunResult(std.testing.allocator, result);
    if (!runSucceeded(result)) {
        std.debug.print("git test command failed: {s}\n", .{result.stderr});
        return error.GitTestCommandFailed;
    }
}

fn initTestRepository(io: std.Io, root: []const u8) !void {
    std.debug.assert(root.len > 0);
    std.debug.assert(std.fs.path.isAbsolute(root) or root[0] == '.');
    try runGitTest(io, root, &.{ "git", "init", "--quiet" });
    try runGitTest(io, root, &.{ "git", "config", "user.email", "navgraph@example.invalid" });
    try runGitTest(io, root, &.{ "git", "config", "user.name", "NavGraph Test" });
    try runGitTest(io, root, &.{ "git", "add", "--", "app.py" });
    try runGitTest(io, root, &.{ "git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-verify", "-m", "initial" });
}

test "history blame and churn run against a real repository" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\def run(value):
        \\    return value
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try initTestRepository(io, root);
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 1), idx.lookup("run").len);

    var history_bytes: std.ArrayList(u8) = .empty;
    defer history_bytes.deinit(testing.allocator);
    var history_output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &history_bytes);
    defer history_output.deinit();
    try testing.expect(try history(&history_output.writer, io, &idx, root, "run", .{ .format = .json, .history_last = 1 }));
    var history_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, history_output.written(), .{});
    defer history_json.deinit();
    try testing.expect(std.mem.indexOf(u8, history_output.written(), "\"commits\"") != null);

    var blame_bytes: std.ArrayList(u8) = .empty;
    defer blame_bytes.deinit(testing.allocator);
    var blame_output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &blame_bytes);
    defer blame_output.deinit();
    try testing.expect(try blame(&blame_output.writer, io, &idx, root, "run", .{ .format = .json }));
    var blame_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, blame_output.written(), .{});
    defer blame_json.deinit();

    var churn_bytes: std.ArrayList(u8) = .empty;
    defer churn_bytes.deinit(testing.allocator);
    var churn_output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &churn_bytes);
    defer churn_output.deinit();
    try testing.expect(try churn(&churn_output.writer, io, &idx, root, "", .{ .format = .json }));
    var churn_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, churn_output.written(), .{});
    defer churn_json.deinit();
    try testing.expect(churn_json.value == .object);
    const churn_object = churn_json.value.object;
    try testing.expectEqual(@as(usize, 1), churn_object.get("entries").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), churn_object.get("count").?.integer);
    try testing.expect(!churn_object.get("truncated").?.bool);
    try testing.expect(!churn_object.get("exact").?.bool);
}

test "Git patch commands disable configured external diff and textconv helpers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data = "def run(value):\n    return value\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.py diff=poison\n" });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try runGitTest(io, root, &.{ "git", "init", "--quiet" });
    try runGitTest(io, root, &.{ "git", "config", "user.email", "navgraph@example.invalid" });
    try runGitTest(io, root, &.{ "git", "config", "user.name", "NavGraph Test" });
    try runGitTest(io, root, &.{ "git", "config", "diff.external", "false" });
    try runGitTest(io, root, &.{ "git", "config", "diff.poison.textconv", "false" });
    try runGitTest(io, root, &.{ "git", "add", "--", "app.py", ".gitattributes" });
    try runGitTest(io, root, &.{ "git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--no-verify", "-m", "initial" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data = "def run(value):\n    return value + 1\n" });

    const poisoned = try gitutil.run(testing.allocator, io, root, &.{ "git", "diff", "--ext-diff", "--textconv", "HEAD", "--" });
    defer freeRunResult(testing.allocator, poisoned);
    try testing.expect(!runSucceeded(poisoned));

    const diff_result = try query.runGitDiff(testing.allocator, io, root, "HEAD");
    defer freeRunResult(testing.allocator, diff_result);
    try testing.expect(runSucceeded(diff_result));
    try testing.expect(std.mem.indexOf(u8, diff_result.stdout, "+++ b/app.py") != null);

    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    const history_result = try runHistory(testing.allocator, io, .{ .path = root }, &idx, idx.lookup("run")[0], 10);
    defer freeRunResult(testing.allocator, history_result);
    try testing.expect(runSucceeded(history_result));
    const churn_result = try runChurn(testing.allocator, io, .{ .path = root }, .{});
    defer freeRunResult(testing.allocator, churn_result);
    try testing.expect(runSucceeded(churn_result));
}

test "churn JSON reports result truncation" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "two.py", .data =
        \\def first(): pass
        \\def second(): pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    const entries = [_]ChurnEntry{
        .{ .id = idx.lookup("first")[0], .commits = 2, .lines = 3 },
        .{ .id = idx.lookup("second")[0], .commits = 1, .lines = 1 },
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &bytes);
    defer output.deinit();
    try testing.expect(try churnJson(&output.writer, &idx, &entries, .{ .format = .json, .limit = 1 }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqual(@as(usize, 1), object.get("entries").?.array.items.len);
    try testing.expectEqual(@as(i64, 2), object.get("count").?.integer);
    try testing.expect(object.get("truncated").?.bool);
    try testing.expect(!object.get("exact").?.bool);
}

test "churn treats an unborn repository as empty history" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data = "def run(): pass\n" });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try runGitTest(io, root, &.{ "git", "init", "--quiet" });
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &bytes);
    defer output.deinit();
    try testing.expect(!try churn(&output.writer, io, &idx, root, "", .{ .format = .json, .since = "HEAD~1" }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqual(@as(usize, 0), object.get("entries").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), object.get("count").?.integer);
    try testing.expect(!object.get("truncated").?.bool);
    try testing.expect(!object.get("exact").?.bool);
    try testing.expect(object.get("error") == null);
}

test "git failures stay visible in JSON" {
    const testing = std.testing;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &bytes);
    defer output.deinit();
    try gitErrorJson(&output.writer, "churn", "fatal: bad revision\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(std.mem.indexOf(u8, output.written(), "bad revision") != null);
}

test "commit metadata parser keeps each commit's patch" {
    const testing = std.testing;
    const input = "NG:abc\x00Ada\x002026-01-01\x00one\n\ndiff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\nNG:def\x00Bob\x002026-01-02\x00two\n\n@@ -2 +2 @@\n-c\n+d\n";
    const commits = try parseCommits(testing.allocator, input);
    defer testing.allocator.free(commits);
    try testing.expectEqual(@as(usize, 2), commits.len);
    try testing.expect(std.mem.eql(u8, commits[0].author, "Ada"));
    try testing.expect(std.mem.indexOf(u8, commits[0].patch, "+b") != null);
    try testing.expect(std.mem.indexOf(u8, commits[1].patch, "+d") != null);
}

test "line porcelain blame parser captures line ownership" {
    const testing = std.testing;
    const input = "0123456789012345678901234567890123456789 1 7 1\nauthor Ada\nauthor-time 123\nsummary add run\nfilename x.py\n\tdef run():\n";
    const lines = try parseBlame(testing.allocator, input);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(@as(u32, 7), lines[0].line);
    try testing.expect(std.mem.eql(u8, lines[0].author, "Ada"));
    const sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const header = try std.fmt.allocPrint(testing.allocator, "{s} 2 9 1", .{sha256});
    defer testing.allocator.free(header);
    try testing.expectEqual(@as(u32, 9), blameHeader(header).?.line);
    try testing.expectEqualStrings(sha256, blameHeader(header).?.sha);
}

test "churn line count preserves deletion-only anchors" {
    const testing = std.testing;
    const ranges = [_]gitdiff.Range{
        .{ .lo = 4, .hi = 4, .empty = true, .removed = 5 },
        .{ .lo = 8, .hi = 10, .removed = 2 },
    };
    try testing.expectEqual(@as(u32, 10), changedLines(&ranges));
    try testing.expect(gitutil.validRef("HEAD~1"));
}
