//! NavGraph CLI entry point: parse args, build the index, dispatch the query.

const std = @import("std");
const model = @import("model.zig");
const cli = @import("cli.zig");
const index_mod = @import("index.zig");
const query = @import("query.zig");
const workflow = @import("workflow.zig");
const hierarchy = @import("hierarchy.zig");
const exceptions = @import("exceptions.zig");
const taint = @import("taint.zig");
const history_mod = @import("history.zig");
const json_out = @import("json_out.zig");
const viz = @import("viz.zig");
const capabilities = @import("capabilities.zig");
const agent_api = @import("agent_api.zig");
const workspace_path = @import("workspace_path.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file.interface;

    var stderr_buffer: [4 * 1024]u8 = undefined;
    var stderr_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_file.interface;

    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];
    // Bare `navgraph` (no args) prints help and succeeds.
    if (args.len == 0) {
        cli.usage(out) catch std.process.exit(141);
        out.flush() catch std.process.exit(141);
        return;
    }
    const parsed = cli.parse(args) catch |err| {
        // A malformed invocation is a usage error: one precise line on stderr
        // (never the full help dump — ~75 lines an agent pays for per typo) and
        // exit non-zero so callers (agents, scripts) can detect the failure.
        const detail = cli.diag();
        if (detail.len != 0) {
            try err_out.print("navgraph: {s}\n", .{detail});
        } else {
            try err_out.print("navgraph: {s}\n", .{cli.reason(err)});
        }
        try err_out.writeAll("run `navgraph help` for usage\n");
        try err_out.flush();
        std.process.exit(2);
    };
    // A global-class flag the command does not use is accepted so a client's
    // standard argv keeps working, but never silently: name it on stderr.
    {
        var it = parsed.ignored_options.iterator();
        while (it.next()) |option| {
            try err_out.print("navgraph: option '{s}' does not apply to {s}; ignored\n", .{
                cli.registry.optionDescriptor(option).name,
                @tagName(parsed.command),
            });
        }
        try err_out.flush();
    }
    if (parsed.command == .help) {
        if (parsed.arg.len == 0) {
            cli.usage(out) catch std.process.exit(141);
        } else {
            _ = cli.usageCommand(out, parsed.arg) catch std.process.exit(141);
        }
        out.flush() catch std.process.exit(141);
        return;
    }
    if (parsed.command == .capabilities) {
        capabilities.writeManifest(out) catch std.process.exit(141);
        out.writeByte('\n') catch std.process.exit(141);
        out.flush() catch std.process.exit(141);
        return;
    }
    if (parsed.command == .read) {
        const found = query.readLinesStandalone(out, io, gpa, parsed.root, parsed.arg, parsed.options) catch |err| switch (err) {
            error.WriteFailed => std.process.exit(141),
            else => return err,
        };
        out.flush() catch std.process.exit(141);
        if (!found) std.process.exit(1);
        return;
    }

    if (parsed.command == .serve) {
        var authority = RootAuthority.open(gpa, io, parsed.root) catch |err| {
            try out.print("navgraph: failed to bind server root '{s}': {s}\n", .{ parsed.root, @errorName(err) });
            try out.flush();
            std.process.exit(1);
        };
        var authority_owned = true;
        errdefer if (authority_owned) authority.deinit();
        var idx = index_mod.buildOpenDir(
            gpa,
            io,
            authority.dir,
            parsed.root,
            authority.single_file,
            authority.single_file_target,
            parsed.use_cache,
        ) catch |err| {
            try out.print("navgraph: failed to index '{s}': {s}\n", .{ parsed.root, @errorName(err) });
            try out.flush();
            std.process.exit(1);
        };
        defer idx.deinit();
        var session = try ServerSession.initBound(gpa, io, &idx, parsed.root, parsed.use_cache, authority);
        authority_owned = false;
        defer session.deinit();
        try serve(out, &session);
        try out.flush();
        return;
    }

    var idx = index_mod.build(gpa, io, parsed.root, parsed.use_cache) catch |err| {
        try out.print("navgraph: failed to index '{s}': {s}\n", .{ parsed.root, @errorName(err) });
        try out.flush();
        // The diagnostic is the product contract. Returning the error from
        // `main` adds an internal Zig stack trace that is noisy and unactionable
        // for an agent.
        std.process.exit(1);
    };
    defer idx.deinit();

    const found = dispatchHardBudget(out, io, &idx, parsed) catch |err| switch (err) {
        // Downstream closed the pipe (`navgraph … | head`). That's a normal way
        // to consume a Unix tool, not an internal error: exit quietly with the
        // conventional SIGPIPE status instead of spraying `error.WriteFailed`.
        error.WriteFailed => std.process.exit(141),
        else => return err,
    };
    // flush's only error is WriteFailed — same broken-pipe treatment.
    out.flush() catch std.process.exit(141);
    // grep convention: 0 = found results, 1 = query ran fine but found nothing
    // (the "(no …)" note), so scripts/agents can branch on $? instead of
    // re-parsing output. Usage errors exit 2, indexing failures propagate.
    if (!found) std.process.exit(1);
}

/// Say on stderr how many graph nodes `-l` withheld.
fn noteGraphTruncation(io: std.Io, truncation: viz.Truncation, limit: u32) !void {
    var buf: [128]u8 = undefined;
    var file: std.Io.File.Writer = .init(.stderr(), io, &buf);
    try file.interface.print("navgraph: graph truncated to {d} of {d} nodes (-l {d})\n", .{
        truncation.shown, truncation.total, limit,
    });
    try file.interface.flush();
}

/// Run the parsed command; true when at least one real result row was printed
/// (notes, suggestions, and empty JSON arrays don't count).
fn dispatch(out: *std.Io.Writer, io: std.Io, idx: *index_mod.Index, parsed: cli.Parsed) !bool {
    return dispatchWithAuthority(out, io, idx, parsed, null);
}

fn dispatchWithAuthority(
    out: *std.Io.Writer,
    io: std.Io,
    idx: *index_mod.Index,
    parsed: cli.Parsed,
    authority: ?*const RootAuthority,
) !bool {
    return switch (parsed.command) {
        .outline => try query.outline(out, idx, parsed.arg, parsed.options),
        .files => try query.listFiles(out, idx, parsed.arg, parsed.options),
        .status => if (authority) |root| bound: {
            var canonical_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const canonical = try root.canonicalPath(&canonical_buf);
            break :bound try query.statusInRoot(
                out,
                io,
                idx,
                root.dir,
                canonical,
                root.single_file_target,
                parsed.arg,
                parsed.options,
            );
        } else try query.status(out, io, idx, parsed.arg, parsed.options),
        .read => if (authority) |root| bound: {
            var canonical_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const canonical = try root.canonicalPath(&canonical_buf);
            break :bound try query.readLinesInRoot(
                out,
                io,
                idx,
                root.dir,
                canonical,
                root.single_file,
                root.single_file_target,
                parsed.arg,
                parsed.options,
            );
        } else try query.readLines(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .strings => try query.strings(out, idx, parsed.arg, parsed.options),
        .def => try query.showDef(out, idx, parsed.arg, parsed.options),
        .docs => try workflow.docs(out, idx, parsed.arg, parsed.options),
        .calls => try query.walk(out, idx, parsed.arg, false, parsed.options),
        .callers => try query.walk(out, idx, parsed.arg, true, parsed.options),
        .search => try query.search(out, idx, parsed.arg, parsed.options),
        .collisions => try query.collisions(out, idx, parsed.arg, parsed.options),
        .routes => try query.listRoutes(out, idx, parsed.arg, parsed.options),
        .events => try query.events(out, idx, parsed.arg, parsed.options),
        .conforms => try query.conforms(out, idx, parsed.arg, parsed.options),
        .hierarchy => try hierarchy.run(out, idx, parsed.arg, parsed.options),
        .raises => try exceptions.raises(out, idx, parsed.arg, parsed.options),
        .catches => try exceptions.catches(out, idx, parsed.arg, parsed.options),
        .neighbors => try query.neighbors(out, idx, parsed.arg, parsed.options),
        .unused => try query.unused(out, idx, parsed.arg, parsed.options),
        .imports => try query.listImports(out, idx, parsed.arg, parsed.options),
        .importers => try query.listImporters(out, idx, parsed.arg, parsed.options),
        .path => try query.shortestPath(out, idx, parsed.arg, parsed.arg2, parsed.options),
        .flow => try query.flow(out, idx, parsed.arg, parsed.options),
        .taint => try taint.run(out, idx, parsed.arg, parsed.options),
        .reaches => try workflow.reaches(out, idx, parsed.arg, parsed.options),
        .affected => if (authority) |root|
            try workflow.affectedAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try workflow.affected(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .hot => try query.hot(out, idx, parsed.arg, parsed.options),
        .diff => if (authority) |root|
            try query.diffAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try query.diff(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .history => if (authority) |root|
            try history_mod.historyAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try history_mod.history(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .blame => if (authority) |root|
            try history_mod.blameAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try history_mod.blame(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .churn => if (authority) |root|
            try history_mod.churnAt(out, io, idx, .{ .dir = root.dir }, parsed.arg, parsed.options)
        else
            try history_mod.churn(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .todos => try workflow.todos(out, idx, parsed.arg, parsed.options),
        .edits => try workflow.edits(out, idx, parsed.arg, parsed.options),
        .rename => try workflow.rename(out, io, idx, parsed.root, parsed.arg, parsed.arg2, parsed.options),
        .coverage => try query.coverage(out, idx, parsed.arg, parsed.options),
        .graph => blk: {
            const truncation = try viz.graph(out, idx, parsed.arg, parsed.options);
            // The JSON model carries `truncated`/`nodes_total`; the HTML page has
            // nowhere to put it and stdout must stay a valid page, so say it on
            // stderr instead of passing a capped subgraph off as the graph.
            if (truncation.any() and parsed.options.format != .json)
                try noteGraphTruncation(io, truncation, parsed.options.limit);
            break :blk true; // graph always emits a page/model
        },
        .capabilities, .serve, .help => unreachable,
    };
}

const CapturedDispatch = struct {
    bytes: []u8,
    found: bool,
};

/// `--budget` is an exact serialized stdout contract. Individual query domains
/// still use it to rank/prune likely-useful rows, then this final boundary
/// measures the real rendering (signatures, source, JSON escaping, metadata and
/// all) and compacts/re-renders until the complete value fits.
fn dispatchHardBudget(out: *std.Io.Writer, io: std.Io, idx: *index_mod.Index, parsed: cli.Parsed) !bool {
    return dispatchHardBudgetWithAuthority(out, io, idx, parsed, null);
}

fn dispatchHardBudgetWithAuthority(
    out: *std.Io.Writer,
    io: std.Io,
    idx: *index_mod.Index,
    parsed: cli.Parsed,
    authority: ?*const RootAuthority,
) !bool {
    if (parsed.options.budget == 0 or parsed.command == .read) return dispatchWithAuthority(out, io, idx, parsed, authority);
    const hard_limit = parsed.options.budget;

    const initial = try captureDispatch(idx.gpa, io, idx, parsed, authority);
    defer idx.gpa.free(initial.bytes);
    if (initial.bytes.len <= hard_limit) {
        try out.writeAll(initial.bytes);
        return initial.found;
    }
    const found = initial.found;

    var compact = parsed;
    compact.options.budget = 0;
    compact.options.summary = true;
    compact.options.verbosity = .names;
    // Raw patches cannot be semantically compacted by lowering a result count;
    // fall back to the changed-symbol summary before resorting to a metadata-only
    // hard-budget response.
    if (compact.command == .diff) compact.options.exact_source = false;
    var cap = compact.options.limit;
    if (compact.options.max_nodes != 0) cap = @min(cap, compact.options.max_nodes);
    cap = @min(cap, @max(@as(u32, 1), hard_limit / 96));

    while (true) {
        compact.options.limit = cap;
        compact.options.max_nodes = cap;
        const rendered = try captureDispatch(idx.gpa, io, idx, compact, authority);
        defer idx.gpa.free(rendered.bytes);
        const annotated = try annotateHardBudget(idx.gpa, rendered.bytes, parsed.options.format, hard_limit, initial.bytes.len);
        defer idx.gpa.free(annotated);
        if (annotated.len <= hard_limit) {
            try out.writeAll(annotated);
            return found;
        }
        if (cap == 1) break;
        cap = @max(@as(u32, 1), cap / 2);
    }

    const minimal = try hardBudgetOnly(idx.gpa, parsed.options.format, hard_limit);
    defer idx.gpa.free(minimal);
    std.debug.assert(minimal.len <= hard_limit);
    try out.writeAll(minimal);
    return found;
}

fn captureDispatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    idx: *index_mod.Index,
    parsed: cli.Parsed,
    authority: ?*const RootAuthority,
) !CapturedDispatch {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer aw.deinit();
    const found = try dispatchWithAuthority(&aw.writer, io, idx, parsed, authority);
    return .{ .bytes = try allocator.dupe(u8, aw.written()), .found = found };
}

fn annotateHardBudget(
    allocator: std.mem.Allocator,
    raw: []const u8,
    format: query.OutputFormat,
    budget: u32,
    original_bytes: usize,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer aw.deinit();
    const w = &aw.writer;
    switch (format) {
        .text => {
            try w.writeAll(raw);
            if (raw.len != 0 and raw[raw.len - 1] != '\n') try w.writeByte('\n');
            try w.print("… hard byte budget truncated/compacted output (budget={}, original_bytes={})\n", .{ budget, original_bytes });
        },
        .json => {
            const trimmed = std.mem.trimEnd(u8, raw, " \t\r\n");
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                try w.writeAll(trimmed[0 .. trimmed.len - 1]);
                if (std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n").len != 0) try w.writeByte(',');
                try w.print("{{\"truncated\":true,\"reason\":\"hard_byte_budget\",\"budget\":{},\"original_bytes\":{}}}]\n", .{ budget, original_bytes });
            } else if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
                try w.writeAll(trimmed[0 .. trimmed.len - 1]);
                if (std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n").len != 0) try w.writeByte(',');
                try w.print("\"hard_budget\":{{\"truncated\":true,\"budget\":{},\"original_bytes\":{}}}}}\n", .{ budget, original_bytes });
            } else {
                return hardBudgetOnly(allocator, format, budget);
            }
        },
        .jsonl => {
            try w.writeAll(raw);
            if (raw.len != 0 and raw[raw.len - 1] != '\n') try w.writeByte('\n');
            try w.print("{{\"kind\":\"budget\",\"truncated\":true,\"budget\":{},\"original_bytes\":{}}}\n", .{ budget, original_bytes });
        },
    }
    return aw.toOwnedSlice();
}

fn hardBudgetOnly(allocator: std.mem.Allocator, format: query.OutputFormat, budget: u32) ![]u8 {
    var buf: [96]u8 = undefined;
    const rendered = switch (format) {
        .text => std.fmt.bufPrint(&buf, "… output truncated (--budget {})\n", .{budget}) catch "",
        .json, .jsonl => std.fmt.bufPrint(&buf, "{{\"truncated\":true,\"reason\":\"hard_byte_budget\",\"budget\":{}}}\n", .{budget}) catch "{}\n",
    };
    // CLI validation keeps budgets >=64, enough for the complete diagnostic.
    // Retain a defensive slice for programmatic Options constructed in tests.
    return allocator.dupe(u8, rendered[0..@min(rendered.len, budget)]);
}

const RootAuthority = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    single_file: ?[]u8,
    single_file_target: ?[]u8,

    fn open(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !RootAuthority {
        std.debug.assert(root.len > 0);
        var single_file: ?[]u8 = null;
        errdefer if (single_file) |file| gpa.free(file);
        var single_file_target: ?[]u8 = null;
        errdefer if (single_file_target) |target| gpa.free(target);
        var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| opened: {
            if (err != error.NotDir) return err;
            single_file = try gpa.dupe(u8, std.fs.path.basename(root));
            const parent = std.fs.path.dirname(root) orelse ".";
            break :opened try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
        };
        errdefer dir.close(io);
        var canonical_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const canonical_len = try dir.realPath(io, &canonical_buf);
        if (single_file) |path| {
            var file = try workspace_path.openFileKnownRoot(dir, io, canonical_buf[0..canonical_len], path);
            defer file.close(io);
            var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const target = try workspace_path.openedRelativePath(file, io, canonical_buf[0..canonical_len], &target_buf);
            single_file_target = try gpa.dupe(u8, target);
        }
        return .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .single_file = single_file,
            .single_file_target = single_file_target,
        };
    }

    fn canonicalPath(self: *const RootAuthority, buffer: []u8) ![]const u8 {
        const len = try self.dir.realPath(self.io, buffer);
        return buffer[0..len];
    }

    fn deinit(self: *RootAuthority) void {
        self.dir.close(self.io);
        if (self.single_file) |file| self.gpa.free(file);
        if (self.single_file_target) |target| self.gpa.free(target);
        self.* = undefined;
    }
};

const ServerSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    idx: *index_mod.Index,
    root: []u8,
    authority: RootAuthority,
    use_cache: bool,
    snapshot_id: u64,

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        idx: *index_mod.Index,
        root: []const u8,
        use_cache: bool,
    ) !ServerSession {
        var authority = try RootAuthority.open(gpa, io, root);
        errdefer authority.deinit();
        return initBound(gpa, io, idx, root, use_cache, authority);
    }

    fn initBound(
        gpa: std.mem.Allocator,
        io: std.Io,
        idx: *index_mod.Index,
        root: []const u8,
        use_cache: bool,
        authority_value: RootAuthority,
    ) !ServerSession {
        std.debug.assert(root.len > 0);
        std.debug.assert(idx.gpa.ptr == gpa.ptr);
        return .{
            .gpa = gpa,
            .io = io,
            .idx = idx,
            .root = try gpa.dupe(u8, root),
            // Ownership transfers only after every fallible field above has
            // initialized. The caller retains and cleans authority_value when
            // this function returns an error.
            .authority = authority_value,
            .use_cache = use_cache,
            .snapshot_id = agent_api.snapshotFingerprint(idx),
        };
    }

    fn deinit(self: *ServerSession) void {
        self.authority.deinit();
        self.gpa.free(self.root);
        self.* = undefined;
    }

    fn reload(self: *ServerSession, use_cache: bool) !void {
        std.debug.assert(self.root.len > 0);
        std.debug.assert(self.idx.gpa.ptr == self.gpa.ptr);
        var fresh = try index_mod.buildOpenDir(
            self.gpa,
            self.io,
            self.authority.dir,
            self.root,
            self.authority.single_file,
            self.authority.single_file_target,
            use_cache,
        );
        const fresh_snapshot_id = agent_api.snapshotFingerprint(&fresh);
        const old = self.idx.*;
        self.idx.* = fresh;
        self.snapshot_id = fresh_snapshot_id;
        fresh = old;
        fresh.deinit();
    }
};

fn serve(out: *std.Io.Writer, session: *ServerSession) !void {
    std.debug.assert(session.root.len > 0);
    std.debug.assert(session.idx.graph.files.len > 0 or session.idx.graph.symbols.len == 0);
    var input_buffer: [64 * 1024]u8 = undefined;
    var stdin_file: std.Io.File.Reader = .initStreaming(.stdin(), session.io, &input_buffer);
    const input = &stdin_file.interface;
    while (true) {
        const maybe = input.takeDelimiter('\n') catch |err| switch (err) {
            // A request line that fills the whole input buffer would otherwise
            // crash the long-lived server. Drain it (through the newline) to
            // resync, report a parse error, and keep serving. If it cannot be
            // drained (EOF / read failure), stop cleanly instead of looping.
            error.StreamTooLong => {
                const drained = input.discardDelimiterInclusive('\n');
                try rpcError(out, null, -32700, "request line exceeds input buffer");
                try out.flush();
                _ = drained catch return;
                continue;
            },
            error.ReadFailed => return err,
        };
        const raw = maybe orelse break;
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) continue;
        const keep_going = try handleServerRequest(out, session, line);
        try out.flush();
        if (!keep_going) return;
    }
}

fn handleServerRequest(out: *std.Io.Writer, session: *ServerSession, line: []const u8) !bool {
    std.debug.assert(session.root.len > 0);
    std.debug.assert(line.len > 0);
    var parsed = std.json.parseFromSlice(std.json.Value, session.gpa, line, .{}) catch {
        try rpcError(out, null, -32700, "invalid JSON");
        return true;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try rpcError(out, null, -32600, "request must be an object");
        return true;
    }
    const obj = parsed.value.object;
    const id = obj.get("id");
    const version = obj.get("jsonrpc") orelse {
        try rpcError(out, id, -32600, "missing jsonrpc version");
        return true;
    };
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) {
        try rpcError(out, id, -32600, "jsonrpc must be 2.0");
        return true;
    }
    const method_value = obj.get("method") orelse {
        try rpcError(out, id, -32600, "missing method");
        return true;
    };
    if (method_value != .string) {
        try rpcError(out, id, -32600, "method must be a string");
        return true;
    }
    const method = method_value.string;
    if (std.mem.eql(u8, method, "workspace/reload")) return rpcReload(out, session, id, obj.get("params"));
    if (std.mem.startsWith(u8, method, "notifications/")) return true;
    if (id == null) return true;
    if (std.mem.eql(u8, method, "initialize")) return rpcInitialize(out, id);
    if (std.mem.eql(u8, method, "navgraph/capabilities")) return rpcCapabilities(out, id);
    if (std.mem.eql(u8, method, "tools/list")) return rpcTools(out, id);
    if (std.mem.eql(u8, method, "tools/call")) return rpcToolCall(out, session, id, obj.get("params"));
    if (std.mem.eql(u8, method, "ping")) {
        try rpcResultPrefix(out, id);
        try out.writeAll("{} }\n");
        return true;
    }
    if (std.mem.eql(u8, method, "shutdown")) {
        try rpcResultPrefix(out, id);
        try out.writeAll("null}\n");
        return false;
    }
    try rpcError(out, id, -32601, "unknown method");
    return true;
}

fn rpcInitialize(out: *std.Io.Writer, id: ?std.json.Value) !bool {
    std.debug.assert(id != null);
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"protocolVersion\":");
    try json_out.writeString(out, capabilities.mcp_protocol_version);
    try out.writeAll(",\"capabilities\":{\"tools\":{\"listChanged\":false},\"experimental\":{\"navgraph\":{\"capabilitySchema\":");
    try json_out.writeString(out, capabilities.capability_schema);
    try out.print(",\"capabilitySchemaVersion\":{},\"agentProtocolVersion\":", .{capabilities.capability_schema_version});
    try json_out.writeString(out, capabilities.agent_protocol_version);
    try out.print(",\"schemaHash\":\"wyhash64:{x:0>16}\"", .{capabilities.schemaFingerprint()});
    try out.writeAll(",\"capabilitiesMethod\":\"navgraph/capabilities\",\"capabilitiesTool\":\"navgraph.capabilities\",\"queryTool\":");
    try json_out.writeString(out, agent_api.tool_name);
    try out.writeAll(",\"querySchema\":");
    try json_out.writeString(out, agent_api.query_schema);
    try out.writeAll(",\"resultSchema\":");
    try json_out.writeString(out, agent_api.result_schema);
    try out.print(",\"agentSchemaHash\":\"wyhash64:{x:0>16}\"", .{agent_api.inputSchemaFingerprint()});
    try out.writeAll(",\"buildId\":\"");
    try capabilities.writeBuildId(out);
    try out.writeAll("\"}}},\"serverInfo\":{\"name\":\"navgraph\",\"version\":\"");
    try capabilities.writeBuildVersion(out);
    try out.writeAll("\"}}}\n");
    return true;
}

fn rpcCapabilities(out: *std.Io.Writer, id: ?std.json.Value) !bool {
    std.debug.assert(id != null);
    try rpcResultPrefix(out, id);
    try capabilities.writeManifest(out);
    try out.writeAll("}\n");
    return true;
}

fn rpcTools(out: *std.Io.Writer, id: ?std.json.Value) !bool {
    std.debug.assert(id != null);
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"tools\":[");
    try out.writeAll("{\"name\":\"");
    try out.writeAll(agent_api.tool_name);
    try out.writeAll("\",\"description\":\"Compact typed read-only API; no argv or mutation. map uses query/path; symbol views definition/docs/source; relations views callees/callers/neighbors/imports/importers/hierarchy/implementations/path/flow; source uses bounded lines; impact views edit_sites/affected_tests/changed_symbols; diagnostics views status/coverage. Protocol ");
    try out.writeAll(capabilities.agent_protocol_version);
    try out.writeAll("; build ");
    try capabilities.writeBuildId(out);
    try out.writeAll(". max_bytes hard-bounds structuredContent.\",\"inputSchema\":");
    try agent_api.writeInputSchema(out);
    try out.writeAll(",\"annotations\":{\"readOnlyHint\":true,\"destructiveHint\":false,\"idempotentHint\":true}},");
    try out.writeAll("{\"name\":\"navgraph\",\"description\":\"Legacy read-only argv compatibility tool. Prefer navgraph.query. Mutating commands, including rename and rename --preview, are rejected.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"args\":{\"type\":\"array\",\"minItems\":1,\"items\":{\"type\":\"string\"}}},\"required\":[\"args\"],\"additionalProperties\":false},\"annotations\":{\"readOnlyHint\":true,\"destructiveHint\":false}},");
    try out.writeAll("{\"name\":\"navgraph.capabilities\",\"description\":\"Return NavGraph's machine-readable protocol, build identity, language, command, option, output, access, and trust contract without rebuilding the index.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}},");
    try out.writeAll("{\"name\":\"navgraph.reload\",\"description\":\"Atomically rebuild and replace the server's in-memory index\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"noCache\":{\"type\":\"boolean\"}},\"additionalProperties\":false}}]}}\n");
    return true;
}

fn rpcReload(
    out: *std.Io.Writer,
    session: *ServerSession,
    id: ?std.json.Value,
    params: ?std.json.Value,
) !bool {
    reloadFromValue(session, params) catch |err| {
        if (id) |_| try rpcError(out, id, reloadErrorCode(err), @errorName(err));
        return true;
    };
    if (id == null) return true;
    try rpcResultPrefix(out, id);
    try writeReloadMetadata(out, session);
    try out.writeAll("}\n");
    return true;
}

fn rpcReloadTool(
    out: *std.Io.Writer,
    session: *ServerSession,
    id: ?std.json.Value,
    arguments: std.json.Value,
) !bool {
    std.debug.assert(id != null);
    reloadFromValue(session, arguments) catch |err| {
        try rpcError(out, id, reloadErrorCode(err), @errorName(err));
        return true;
    };
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":\"index reloaded\"}],\"isError\":false,\"index\":");
    try writeReloadMetadata(out, session);
    try out.writeAll("}}\n");
    return true;
}

fn reloadFromValue(session: *ServerSession, value: ?std.json.Value) !void {
    var no_cache = false;
    if (value) |params| {
        if (params != .object) return error.InvalidReloadArguments;
        const field_count = params.object.count();
        const raw = params.object.get("noCache");
        if (field_count > @as(usize, @intFromBool(raw != null))) return error.InvalidReloadArguments;
        if (raw) |flag| {
            if (flag != .bool) return error.InvalidReloadArguments;
            no_cache = flag.bool;
        }
    }
    try session.reload(if (no_cache) false else session.use_cache);
}

fn reloadErrorCode(err: anyerror) i32 {
    return if (err == error.InvalidReloadArguments) -32602 else -32603;
}

fn writeReloadMetadata(out: *std.Io.Writer, session: *const ServerSession) !void {
    const snapshot = session.idx.cache_snapshot;
    try out.print("{{\"files\":{},\"symbols\":{},\"cache_hits\":{},\"cache_rewrite\":\"{s}\"}}", .{
        session.idx.graph.files.len, session.idx.graph.symbols.len, snapshot.hits, @tagName(snapshot.rewrite),
    });
}

fn rpcToolCall(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, params_value: ?std.json.Value) !bool {
    std.debug.assert(session.root.len > 0);
    std.debug.assert(id != null);
    if (params_value == null or params_value.? != .object) {
        try rpcError(out, id, -32602, "tools/call requires params");
        return true;
    }
    const params = params_value.?.object;
    const name = params.get("name") orelse {
        try rpcError(out, id, -32602, "missing tool name");
        return true;
    };
    if (name != .string) {
        try rpcError(out, id, -32602, "tool name must be a string");
        return true;
    }
    const arguments = params.get("arguments") orelse {
        try rpcError(out, id, -32602, "missing arguments");
        return true;
    };
    if (arguments != .object) {
        try rpcError(out, id, -32602, "arguments must be an object");
        return true;
    }
    if (std.mem.eql(u8, name.string, "navgraph"))
        return runServerTool(out, session, id, arguments.object.get("args"));
    if (std.mem.eql(u8, name.string, agent_api.tool_name))
        return runAgentTool(out, session, id, arguments);
    if (std.mem.eql(u8, name.string, "navgraph.capabilities"))
        return rpcCapabilitiesTool(out, session.gpa, id, arguments);
    if (std.mem.eql(u8, name.string, "navgraph.reload"))
        return rpcReloadTool(out, session, id, arguments);
    try rpcError(out, id, -32602, "unknown tool");
    return true;
}

fn rpcCapabilitiesTool(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    arguments: std.json.Value,
) !bool {
    std.debug.assert(id != null);
    if (arguments != .object or arguments.object.count() != 0) {
        try rpcError(out, id, -32602, "navgraph.capabilities takes no arguments");
        return true;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer allocating.deinit();
    try capabilities.writeManifest(&allocating.writer);
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try json_out.writeString(out, allocating.written());
    try out.writeAll("}],\"isError\":false,\"schema\":");
    try json_out.writeString(out, capabilities.capability_schema);
    try out.writeAll("}}\n");
    return true;
}

fn runServerTool(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, args_value: ?std.json.Value) !bool {
    std.debug.assert(session.root.len > 0);
    std.debug.assert(session.idx.graph.symbols.len <= std.math.maxInt(model.SymbolId));
    if (args_value == null or args_value.? != .array or args_value.?.array.items.len == 0) {
        try rpcError(out, id, -32602, "args must be a non-empty string array");
        return true;
    }
    var arena_state = std.heap.ArenaAllocator.init(session.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try arena.alloc([:0]const u8, args_value.?.array.items.len);
    for (args_value.?.array.items, 0..) |value, i| {
        if (value != .string) {
            try rpcError(out, id, -32602, "every arg must be a string");
            return true;
        }
        args[i] = try arena.dupeZ(u8, value.string);
    }
    var request = cli.parse(args) catch {
        try rpcError(out, id, -32602, if (cli.diag().len != 0) cli.diag() else "invalid navgraph arguments");
        return true;
    };
    if (request.command == .capabilities) return rpcCapabilities(out, id);
    const descriptor = cli.registry.descriptor(request.command);
    if (descriptor.access != .read_only) {
        try rpcError(out, id, -32602, "legacy navgraph MCP tool is read-only; mutating commands are prohibited");
        return true;
    }
    if (!descriptor.server_available or !std.mem.eql(u8, request.root, ".")) {
        try rpcError(out, id, -32602, "this command or -C is not allowed inside a server request");
        return true;
    }
    request.root = session.root;
    try dispatchServerResult(out, session, id, request);
    return true;
}

fn runAgentTool(
    out: *std.Io.Writer,
    session: *ServerSession,
    id: ?std.json.Value,
    arguments: std.json.Value,
) !bool {
    std.debug.assert(id != null);
    var arena_state = std.heap.ArenaAllocator.init(session.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var request = agent_api.decode(arena, arguments) catch |err| {
        try rpcError(out, id, -32602, agent_api.reason(err));
        return true;
    };
    const descriptor = cli.registry.descriptor(request.parsed.command);
    if (descriptor.access != .read_only or !descriptor.server_available) {
        try rpcError(out, id, -32602, "navgraph.query resolved to a prohibited command");
        return true;
    }
    request.parsed.root = session.root;

    if (try agent_api.ambiguityEnvelopeOwned(session.gpa, session.idx, session.snapshot_id, request)) |envelope| {
        defer session.gpa.free(envelope);
        std.debug.assert(envelope.len <= request.max_bytes);
        try writeAgentResult(out, id, envelope);
        return true;
    }

    var raw_buf: std.ArrayList(u8) = .empty;
    defer raw_buf.deinit(session.gpa);
    var raw_writer: std.Io.Writer.Allocating = .fromArrayList(session.gpa, &raw_buf);
    defer raw_writer.deinit();
    const found = dispatchWithAuthority(&raw_writer.writer, session.io, session.idx, request.parsed, &session.authority) catch |err| {
        try rpcError(out, id, -32603, @errorName(err));
        return true;
    };
    const envelope = agent_api.envelopeOwned(session.gpa, session.idx, session.snapshot_id, request, found, raw_writer.written()) catch |err| {
        try rpcError(out, id, -32603, @errorName(err));
        return true;
    };
    defer session.gpa.free(envelope);
    std.debug.assert(envelope.len <= request.max_bytes);
    try writeAgentResult(out, id, envelope);
    return true;
}

fn writeAgentResult(out: *std.Io.Writer, id: ?std.json.Value, envelope: []const u8) !void {
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":\"NavGraph structured result\"}],\"structuredContent\":");
    try out.writeAll(envelope);
    try out.writeAll(",\"isError\":false}}\n");
}

fn dispatchServerResult(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, request: cli.Parsed) !void {
    std.debug.assert(request.command != .serve and request.command != .help);
    std.debug.assert(request.root.len > 0);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(session.gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(session.gpa, &buf);
    defer aw.deinit();
    const found = dispatchHardBudgetWithAuthority(&aw.writer, session.io, session.idx, request, &session.authority) catch |err| {
        try rpcError(out, id, -32603, @errorName(err));
        return;
    };
    if (found and request.command == .rename and !request.options.preview) {
        session.reload(session.use_cache) catch |err| {
            var message_buf: [192]u8 = undefined;
            const message = std.fmt.bufPrint(&message_buf, "rename was applied, but index reload failed: {s}", .{@errorName(err)}) catch
                "rename was applied, but index reload failed";
            try rpcError(out, id, -32603, message);
            return;
        };
    }
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try json_out.writeString(out, aw.written());
    try out.writeAll("}],\"isError\":false");
    try out.writeAll(",\"found\":");
    try out.print("{}", .{found});
    try out.writeAll("}}\n");
}

fn rpcResultPrefix(out: *std.Io.Writer, id: ?std.json.Value) !void {
    std.debug.assert(id != null);
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id.?, .{}, out);
    try out.writeAll(",\"result\":");
}

fn rpcError(out: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8) !void {
    std.debug.assert(message.len > 0);
    std.debug.assert(code < 0);
    try out.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |value| try std.json.Stringify.value(value, .{}, out) else try out.writeAll("null");
    try out.print(",\"error\":{{\"code\":{},\"message\":", .{code});
    try json_out.writeString(out, message);
    try out.writeAll("}}\n");
}

// ---------------------------------------------------------------------------
// End-to-end dispatch() tests: parse (or hand-build) a cli.Parsed for each
// Command, build a real index from a tmpDir, run dispatch() into an Allocating
// buffer, and assert the rendered output matches the verb. Also verifies that
// cli.parse of a full argv round-trips into the right Command + options that
// dispatch then acts on.
// ---------------------------------------------------------------------------

/// Write the shared two-file sample project into `dir`. `app.zig` imports
/// `util.zig`; the call chain is run → mid → leaf (in-file) plus run →
/// util.helper → inner (cross-file). `orphan` is dead. `greeting` holds a
/// string literal for the `strings` verb.
fn writeSampleProject(io: std.Io, dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = "app.zig", .data =
        \\const util = @import("util.zig");
        \\
        \\pub const greeting = "hello /api/health world";
        \\
        \\/// Run the sample workflow.
        \\pub fn run() void {
        \\    mid();
        \\    util.helper();
        \\}
        \\
        \\fn mid() void {
        \\    // TODO remove this wrapper after migration
        \\    leaf();
        \\}
        \\
        \\fn leaf() void {}
        \\
        \\fn orphan() void {}
    });
    try dir.writeFile(io, .{ .sub_path = "util.zig", .data =
        \\pub fn helper() void {
        \\    inner();
        \\}
        \\
        \\fn inner() void {}
    });
}

const SampleFixture = struct {
    tmp: std.testing.TmpDir,
    idx: index_mod.Index,

    fn deinit(self: *SampleFixture) void {
        self.idx.deinit();
        self.tmp.cleanup();
    }
};

/// Build an index over a fresh copy of the sample project. Caller must
/// `defer fx.deinit()`.
fn sampleFixture(io: std.Io) !SampleFixture {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    try writeSampleProject(io, tmp.dir);
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const idx = try index_mod.build(std.testing.allocator, io, root, false);
    return .{ .tmp = tmp, .idx = idx };
}

fn ambiguousFixture(io: std.Io) !SampleFixture {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub const Alpha = struct {
        \\    pub fn parse() void { tokenize(); }
        \\    fn tokenize() void {}
        \\};
        \\pub const Beta = struct {
        \\    pub fn parse() void { tokenize(); }
        \\    fn tokenize() void {}
        \\};
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub const Gamma = struct {
        \\    pub fn parse() void { tokenize(); }
        \\    fn tokenize() void {}
        \\};
        \\pub const Delta = struct {
        \\    pub fn parse() void { tokenize(); }
        \\    fn tokenize() void {}
        \\};
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const idx = try index_mod.build(std.testing.allocator, io, root, false);
    return .{ .tmp = tmp, .idx = idx };
}

/// Run dispatch() for `parsed` and return the rendered output (caller frees).
fn dispatchOwned(alloc: std.mem.Allocator, io: std.Io, idx: *index_mod.Index, parsed: cli.Parsed) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &buf);
    defer aw.deinit();
    _ = try dispatch(&aw.writer, io, idx, parsed);
    return alloc.dupe(u8, aw.written());
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "dispatch outline lists the files and their symbols" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .outline });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "util.zig"));
    try std.testing.expect(has(out, "run"));
    try std.testing.expect(has(out, "mid"));
    try std.testing.expect(has(out, "helper"));
}

test "dispatch outline honors the path filter argument" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // Filter to util.zig only: app.zig's private `mid` must not appear.
    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .outline, .arg = "util.zig" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "util.zig"));
    try std.testing.expect(has(out, "helper"));
    try std.testing.expect(!has(out, "app.zig"));
    try std.testing.expect(!has(out, "mid"));
}

test "dispatch files lists every indexed file" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .files });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "util.zig"));
}

test "dispatch def shows a definition signature" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .def, .arg = "run" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "run"));
    try std.testing.expect(has(out, "fn"));
    try std.testing.expect(has(out, "app.zig"));
}

test "dispatch def and search resolve glob patterns" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // `def` with a prefix glob lists every match (issue #3's `def Ba*` shape).
    const defs = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .def, .arg = "m*" });
    defer std.testing.allocator.free(defs);
    try std.testing.expect(has(defs, "mid"));
    try std.testing.expect(!has(defs, "leaf"));

    // `search` with a glob anchors on the whole name: `r*n` hits `run` only.
    const found = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .search, .arg = "r*n" });
    defer std.testing.allocator.free(found);
    try std.testing.expect(has(found, "run"));
    try std.testing.expect(!has(found, "orphan")); // substring would hit it; glob must not
}

test "index honors .navgraphignore: prune a source dir, re-include a built-in skip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".navgraphignore", .data = "junk/\n!node_modules/\n" });
    try tmp.dir.createDir(io, "junk", .default_dir);
    try tmp.dir.createDir(io, "node_modules", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data = "def real():\n    pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "junk/j.py", .data = "def scratch():\n    pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/v.py", .data = "def vendored():\n    pass\n" });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(std.testing.allocator, io, root, false);
    defer idx.deinit();

    var saw_app = false;
    var saw_vendored = false;
    for (idx.graph.files) |f| {
        try std.testing.expect(!std.mem.startsWith(u8, f.path, "junk/")); // pruned
        if (std.mem.eql(u8, f.path, "app.py")) saw_app = true;
        if (std.mem.eql(u8, f.path, "node_modules/v.py")) saw_vendored = true;
    }
    try std.testing.expect(saw_app);
    try std.testing.expect(saw_vendored); // `!node_modules/` overrode the built-in skip
}

test "dispatch def on an unknown name reports not found without crashing" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .def, .arg = "no_such_symbol_xyz" });
    defer std.testing.allocator.free(out);

    // A miss must still produce output (a note) and never the symbol name.
    try std.testing.expect(out.len > 0);
    try std.testing.expect(has(out, "no_such_symbol_xyz"));
}

test "dispatch calls walks callees of a function" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .calls, .arg = "run" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "run"));
    try std.testing.expect(has(out, "mid")); // run → mid (in-file callee)
}

test "dispatch callers walks incoming edges of a function" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .callers, .arg = "leaf" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "leaf"));
    try std.testing.expect(has(out, "mid")); // mid → leaf, so mid is a caller
}

test "dispatch search finds symbols by name" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .search, .arg = "helper" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "helper"));
    try std.testing.expect(has(out, "util.zig"));
}

test "dispatch neighbors shows both callees and callers" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .neighbors, .arg = "mid" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "mid"));
    try std.testing.expect(has(out, "leaf")); // callee
    try std.testing.expect(has(out, "run")); // caller
}

test "dispatch unused flags an uncalled private function" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .unused });
    defer std.testing.allocator.free(out);

    // orphan is private, uncalled, and named nowhere → dead code.
    try std.testing.expect(has(out, "orphan"));
}

test "dispatch imports lists a file's local import edges" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .imports });
    defer std.testing.allocator.free(out);

    // app.zig imports util.zig.
    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "util.zig"));
}

test "dispatch importers lists reverse dependencies of a file" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .importers, .arg = "util.zig" });
    defer std.testing.allocator.free(out);

    // util.zig is imported by app.zig.
    try std.testing.expect(has(out, "util.zig"));
    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "imported by"));
}

test "dispatch path finds a call path and reports its absence" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // run → mid → leaf exists.
    const found = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .path, .arg = "run", .arg2 = "leaf" });
    defer std.testing.allocator.free(found);
    try std.testing.expect(has(found, "run"));
    try std.testing.expect(has(found, "leaf"));
    try std.testing.expect(!has(found, "no call path"));

    // No reverse path leaf → run.
    const none = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .path, .arg = "leaf", .arg2 = "run" });
    defer std.testing.allocator.free(none);
    try std.testing.expect(has(none, "no call path"));
}

test "dispatch hot ranks the load-bearing symbols" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .hot });
    defer std.testing.allocator.free(out);

    try std.testing.expect(out.len > 0);
    // mid is central: fan-in from run, fan-out to leaf.
    try std.testing.expect(has(out, "mid"));
}

test "dispatch read prints numbered source of an indexed file" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .read, .arg = "app.zig" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "app.zig"));
    try std.testing.expect(has(out, "pub fn run"));
    // Numbered lines use a tab separator.
    try std.testing.expect(has(out, "\t"));
}

test "dispatch read honors an explicit line range" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // Line 3 of app.zig is the `greeting` const.
    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .read, .arg = "app.zig:3-3" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "greeting"));
    // The run function is on later lines and must be excluded by the range.
    try std.testing.expect(!has(out, "pub fn run"));
}

test "dispatch strings searches inside string literals" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .strings, .arg = "/api/health" });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "/api/health"));
    try std.testing.expect(has(out, "app.zig"));
}

test "dispatch routes reports the empty case for a project with no routes" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .routes });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "no routes"));
}

test "dispatch events reports the empty case for a project with no dispatch" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{ .command = .events });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "event"));
}

test "dispatch diff handles an unrunnable git root gracefully" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // Point the diff at a nonexistent root so git cannot run; dispatch must
    // still return normally (the error is caught and reported, not propagated).
    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{
        .command = .diff,
        .root = "/nonexistent-navgraph-root-xyz-123",
    });
    defer std.testing.allocator.free(out);

    try std.testing.expect(has(out, "git diff"));
}

test "dispatch honors the json output format and emits well-formed JSON" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{
        .command = .calls,
        .arg = "run",
        .options = .{ .depth = 2, .format = .json },
    });
    defer std.testing.allocator.free(out);

    // Parse it to prove it is valid JSON, then assert on its shape.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(has(out, "\"name\":\"run\""));
}

test "dispatch honors the verbosity option (names hides signatures)" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // -v names lists bare names; the parameter/return signature `() void` must
    // not be rendered.
    const names = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{
        .command = .outline,
        .options = .{ .verbosity = .names },
    });
    defer std.testing.allocator.free(names);
    try std.testing.expect(has(names, "run"));

    // -v sig (default) includes the `fn ... void` signature text.
    const sig = try dispatchOwned(std.testing.allocator, io, &fx.idx, .{
        .command = .outline,
        .options = .{ .verbosity = .sig },
    });
    defer std.testing.allocator.free(sig);
    try std.testing.expect(has(sig, "void"));
    // The names view is strictly shorter than the signature view.
    try std.testing.expect(names.len < sig.len);
}

test "cli.parse then dispatch round-trips a full argv through the pipeline" {
    const io = std.testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    // Full argv (program name already stripped, as main.zig does).
    const parsed = try cli.parse(&.{ "search", "helper" });
    try std.testing.expectEqual(cli.Command.search, parsed.command);
    try std.testing.expectEqualStrings("helper", parsed.arg);

    const out = try dispatchOwned(std.testing.allocator, io, &fx.idx, parsed);
    defer std.testing.allocator.free(out);
    try std.testing.expect(has(out, "helper"));
    try std.testing.expect(has(out, "util.zig"));
}

test "cli.parse maps command aliases and dispatch-relevant flags" {
    // `o` is an alias for outline; `-C` sets the root; `-j` selects JSON.
    const a = try cli.parse(&.{ "o", "src", "-C", "myroot", "-j" });
    try std.testing.expectEqual(cli.Command.outline, a.command);
    try std.testing.expectEqualStrings("src", a.arg);
    try std.testing.expectEqualStrings("myroot", a.root);
    try std.testing.expectEqual(query.OutputFormat.json, a.options.format);

    // `path` fills both positionals.
    const b = try cli.parse(&.{ "path", "alpha", "omega" });
    try std.testing.expectEqual(cli.Command.path, b.command);
    try std.testing.expectEqualStrings("alpha", b.arg);
    try std.testing.expectEqualStrings("omega", b.arg2);

    // `cat` is an alias for read.
    const c = try cli.parse(&.{ "cat", "x.zig" });
    try std.testing.expectEqual(cli.Command.read, c.command);
    try std.testing.expectEqualStrings("x.zig", c.arg);

    // `--no-cache` disables the on-disk cache flag dispatch/build reads.
    const d = try cli.parse(&.{ "outline", "--no-cache" });
    try std.testing.expect(!d.use_cache);
}

test "cli.parse rejects malformed invocations" {
    // Unknown command.
    try std.testing.expectError(error.Usage, cli.parse(&.{"frobnicate"}));
    // Missing required positional for a name verb.
    try std.testing.expectError(error.Usage, cli.parse(&.{"def"}));
    // path needs two positionals.
    try std.testing.expectError(error.Usage, cli.parse(&.{ "path", "onlyone" }));
    // Unknown flag.
    try std.testing.expectError(error.UnknownFlag, cli.parse(&.{ "outline", "--bogus" }));
}

test "phase 4 hierarchy exceptions and taint dispatch" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "depth.py", .data =
        \\class AppError(Exception): pass
        \\class OrderError(AppError): pass
        \\def fail(): raise OrderError("bad")
        \\def run(request):
        \\    try:
        \\        subprocess.run(request.json)
        \\    except OrderError:
        \\        return None
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();

    const hierarchy_out = try dispatchOwned(testing.allocator, io, &idx, .{ .command = .hierarchy, .arg = "AppError", .options = .{ .format = .json, .hierarchy_overrides = true } });
    defer testing.allocator.free(hierarchy_out);
    var hierarchy_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, hierarchy_out, .{});
    defer hierarchy_json.deinit();
    try testing.expect(has(hierarchy_out, "OrderError"));

    const raises_out = try dispatchOwned(testing.allocator, io, &idx, .{ .command = .raises, .arg = "fail", .options = .{ .format = .json, .depth = 2 } });
    defer testing.allocator.free(raises_out);
    var raises_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, raises_out, .{});
    defer raises_json.deinit();
    try testing.expect(has(raises_out, "OrderError"));

    const catches_out = try dispatchOwned(testing.allocator, io, &idx, .{ .command = .catches, .arg = "OrderError", .options = .{ .format = .json } });
    defer testing.allocator.free(catches_out);
    var catches_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, catches_out, .{});
    defer catches_json.deinit();
    try testing.expect(has(catches_out, "handler"));

    const taint_out = try dispatchOwned(testing.allocator, io, &idx, .{ .command = .taint, .arg = "request.json", .options = .{ .flow_to = "subprocess.run", .format = .json } });
    defer testing.allocator.free(taint_out);
    var taint_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, taint_out, .{});
    defer taint_json.deinit();
    try testing.expect(has(taint_out, "\"status\":\"reachable\""));
}

test "phase 3 reachability, docs, todos, rename preview, and compaction dispatch" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();

    const reach = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .reaches, .arg = "run" });
    defer testing.allocator.free(reach);
    try testing.expect(has(reach, "run"));
    try testing.expect(has(reach, "leaf"));

    const docs_out = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .docs, .arg = "run" });
    defer testing.allocator.free(docs_out);
    try testing.expect(has(docs_out, "sample workflow"));
    const todo_out = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .todos });
    defer testing.allocator.free(todo_out);
    try testing.expect(has(todo_out, "TODO remove this wrapper"));

    const preview = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .rename, .arg = "leaf", .arg2 = "finish", .options = .{ .preview = true } });
    defer testing.allocator.free(preview);
    try testing.expect(has(preview, "--- a/app.zig"));
    try testing.expect(has(preview, "+fn finish"));

    const bounded = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .calls, .arg = "run", .options = .{ .depth = 3, .max_nodes = 2, .summary = true } });
    defer testing.allocator.free(bounded);
    try testing.expect(has(bounded, "nodes shown"));
    try testing.expect(!has(bounded, "() void"));

    const bounded_neighbors = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .neighbors, .arg = "run", .options = .{ .max_nodes = 2, .summary = true } });
    defer testing.allocator.free(bounded_neighbors);
    try testing.expect(has(bounded_neighbors, "nodes shown"));
    try testing.expect(!has(bounded_neighbors, "() void"));

    // `-l/--limit` is the universal result contract, including tree walks.
    // It must cap nodes even when neither of the optional compaction flags is
    // present; agents rely on this before they know a graph's fan-out.
    const limited = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .calls, .arg = "run", .options = .{ .depth = 3, .limit = 1 } });
    defer testing.allocator.free(limited);
    try testing.expect(has(limited, "run"));
    try testing.expect(!has(limited, "mid"));
    try testing.expect(has(limited, "1 nodes shown"));

    const limited_json = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .neighbors, .arg = "run", .options = .{ .format = .json, .limit = 1 } });
    defer testing.allocator.free(limited_json);
    var parsed_limited = try std.json.parseFromSlice(std.json.Value, testing.allocator, limited_json, .{});
    defer parsed_limited.deinit();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, limited_json, "\"id\":"));
    try testing.expect(has(limited_json, "\"truncated\":true"));

    var hard_text_buf: std.ArrayList(u8) = .empty;
    defer hard_text_buf.deinit(testing.allocator);
    var hard_text_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &hard_text_buf);
    defer hard_text_writer.deinit();
    try testing.expect(try dispatchHardBudget(&hard_text_writer.writer, io, &fx.idx, .{
        .command = .calls,
        .arg = "run",
        .options = .{ .depth = 3, .verbosity = .full, .budget = 160 },
    }));
    try testing.expect(hard_text_writer.written().len <= 160);

    var hard_json_buf: std.ArrayList(u8) = .empty;
    defer hard_json_buf.deinit(testing.allocator);
    var hard_json_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &hard_json_buf);
    defer hard_json_writer.deinit();
    try testing.expect(try dispatchHardBudget(&hard_json_writer.writer, io, &fx.idx, .{
        .command = .neighbors,
        .arg = "run",
        .options = .{ .format = .json, .budget = 256 },
    }));
    try testing.expect(hard_json_writer.written().len <= 256);
    var hard_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, hard_json_writer.written(), .{});
    defer hard_json.deinit();
}

test "phase 3 JSONL pages are independently valid and expose a cursor" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    const out = try dispatchOwned(testing.allocator, io, &fx.idx, .{ .command = .search, .arg = "i", .options = .{ .format = .jsonl, .limit = 2 } });
    defer testing.allocator.free(out);

    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    var count: u32 = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        count += 1;
    }
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expect(has(out, "\"next\":\"v1:2\""));
}

test "serve handles MCP initialize and a tool call on the in-memory index" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false);
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph\",\"arguments\":{\"args\":[\"search\",\"leaf\",\"-j\"]}}}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"unknown\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph\",\"arguments\":{\"args\":[\"search\",\"missing_symbol\",\"-j\"]}}}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"1.0\",\"id\":5,\"method\":\"ping\"}"));
    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var count: u32 = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        count += 1;
    }
    try testing.expectEqual(@as(u32, 5), count);
    try testing.expect(has(aw.written(), "\\\"name\\\":\\\"leaf\\\""));
    try testing.expect(has(aw.written(), "\"error\":{\"code\":-32601"));
    try testing.expect(has(aw.written(), "\"isError\":false,\"found\":false"));
    try testing.expect(has(aw.written(), "\"error\":{\"code\":-32600"));
}

test "typed MCP facade covers six read-only surfaces with a stable bounded envelope" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false);
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"map\",\"query\":\"leaf\",\"limit\":5}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"symbol\",\"selector\":\"leaf\",\"view\":\"definition\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"relations\",\"selector\":\"leaf\",\"view\":\"callers\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"source\",\"path\":\"app.zig\",\"start_line\":1,\"limit\":200,\"max_bytes\":1024}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"impact\",\"view\":\"edit_sites\",\"selector\":\"leaf\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"diagnostics\",\"view\":\"status\",\"limit\":1,\"max_bytes\":4096}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"source\",\"path\":\"app.zig\",\"selector\":\"leaf\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph\",\"arguments\":{\"args\":[\"rename\",\"leaf\",\"finish\",\"--preview\"]}}}",
    };
    for (requests) |request| try testing.expect(try handleServerRequest(&aw.writer, &session, request));

    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var responses: [requests.len]std.json.Parsed(std.json.Value) = undefined;
    var response_count: usize = 0;
    defer for (responses[0..response_count]) |*response| response.deinit();
    while (lines.next()) |line| {
        responses[response_count] = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        response_count += 1;
    }
    try testing.expectEqual(requests.len, response_count);
    const operations = [_][]const u8{ "map", "symbol", "relations", "source", "impact", "diagnostics" };
    const first_snapshot = responses[0].value.object.get("result").?.object.get("structuredContent").?.object.get("snapshot_id").?.string;
    for (responses[0..operations.len], operations) |response, operation| {
        const result = response.value.object.get("result").?.object;
        try testing.expect(!result.get("isError").?.bool);
        const envelope = result.get("structuredContent").?.object;
        try testing.expectEqualStrings(agent_api.result_schema, envelope.get("schema").?.string);
        try testing.expectEqualStrings(operation, envelope.get("operation").?.string);
        try testing.expectEqualStrings(first_snapshot, envelope.get("snapshot_id").?.string);
        inline for (.{ "found", "exactness", "ambiguous", "candidates", "truncated", "next", "parse_health", "resolution_health", "warnings", "content", "items", "source_spans", "suggested_calls" }) |field|
            try testing.expect(envelope.get(field) != null);
    }
    const bounded = responses[3].value.object.get("result").?.object.get("structuredContent").?.object;
    const bounded_json = try std.json.Stringify.valueAlloc(testing.allocator, std.json.Value{ .object = bounded }, .{});
    defer testing.allocator.free(bounded_json);
    try testing.expect(bounded_json.len <= 1024);
    try testing.expect(bounded.get("next").? != .null);
    const bounded_items = bounded.get("items").?.array.items;
    try testing.expect(bounded_items.len > 0);
    const last_emitted_line = bounded_items[bounded_items.len - 1].object.get("line").?.integer;
    try testing.expectEqual(last_emitted_line + 1, bounded.get("next").?.object.get("start_line").?.integer);
    try testing.expectEqual(last_emitted_line, bounded.get("source_spans").?.array.items[0].object.get("end_line").?.integer);
    try testing.expectEqual(@as(i64, -32602), responses[6].value.object.get("error").?.object.get("code").?.integer);
    try testing.expectEqual(@as(i64, -32602), responses[7].value.object.get("error").?.object.get("code").?.integer);
    try testing.expect(std.mem.indexOf(u8, responses[7].value.object.get("error").?.object.get("message").?.string, "read-only") != null);
}

test "typed MCP relations abstain before ambiguous calls and path traversal" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try ambiguousFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false);
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"relations\",\"selector\":\"parse\",\"view\":\"callees\"}}}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.query\",\"arguments\":{\"operation\":\"relations\",\"selector\":\"parse\",\"view\":\"path\",\"to\":\"tokenize\"}}}"));

    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        var response = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer response.deinit();
        const envelope = response.value.object.get("result").?.object.get("structuredContent").?.object;
        try testing.expect(envelope.get("ambiguous").?.bool);
        try testing.expect(envelope.get("content").? == .null);
        try testing.expectEqual(@as(usize, 0), envelope.get("items").?.array.items.len);
        try testing.expect(envelope.get("candidates").?.array.items.len >= 2);
        try testing.expect(envelope.get("suggested_calls").?.array.items.len >= 1);
        for (envelope.get("suggested_calls").?.array.items) |suggested| {
            const call = suggested.object;
            var selector_buf: [64]model.SymbolId = undefined;
            const selector = call.get("selector").?.string;
            try testing.expect(std.mem.indexOfScalar(u8, selector, '.') != null);
            try testing.expectEqual(@as(usize, 1), query.resolveIds(&fx.idx, selector, &selector_buf).len);
            if (call.get("to")) |to| {
                var to_buf: [64]model.SymbolId = undefined;
                try testing.expectEqual(@as(usize, 1), query.resolveIds(&fx.idx, to.string, &to_buf).len);
            }
        }
        if (count == 1) {
            var saw_from = false;
            var saw_to = false;
            for (envelope.get("candidates").?.array.items) |candidate| {
                const endpoint = candidate.object.get("endpoint").?.string;
                saw_from = saw_from or std.mem.eql(u8, endpoint, "from");
                saw_to = saw_to or std.mem.eql(u8, endpoint, "to");
            }
            try testing.expect(saw_from and saw_to);
            const suggestion = envelope.get("suggested_calls").?.array.items[0].object;
            try testing.expect(suggestion.get("selector") != null and suggestion.get("to") != null);
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "MCP identity and capability surfaces share the live manifest contract" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false);
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"navgraph/capabilities\"}"));
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.capabilities\",\"arguments\":{}}}"));

    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var responses: [4]std.json.Parsed(std.json.Value) = undefined;
    var response_count: usize = 0;
    defer for (responses[0..response_count]) |*response| response.deinit();
    while (lines.next()) |line| {
        responses[response_count] = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        response_count += 1;
    }
    try testing.expectEqual(@as(usize, 4), response_count);

    const initialize = responses[0].value.object.get("result").?.object;
    try testing.expectEqualStrings(capabilities.mcp_protocol_version, initialize.get("protocolVersion").?.string);
    const server_version = initialize.get("serverInfo").?.object.get("version").?.string;
    try testing.expect(std.mem.startsWith(u8, server_version, capabilities.product_version));
    try testing.expect(std.mem.indexOf(u8, server_version, "src.") != null);
    const init_navgraph = initialize.get("capabilities").?.object.get("experimental").?.object.get("navgraph").?.object;
    try testing.expectEqualStrings(capabilities.capability_schema, init_navgraph.get("capabilitySchema").?.string);

    const tools = responses[1].value.object.get("result").?.object;
    try testing.expectEqual(@as(usize, 4), tools.get("tools").?.array.items.len);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "navgraph.capabilities") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "navgraph.query") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "phase3") == null);
    try testing.expectEqualStrings(agent_api.tool_name, init_navgraph.get("queryTool").?.string);
    try testing.expectEqualStrings(agent_api.query_schema, init_navgraph.get("querySchema").?.string);
    try testing.expectEqualStrings(agent_api.result_schema, init_navgraph.get("resultSchema").?.string);
    try testing.expect(init_navgraph.get("agentSchemaHash") != null);

    const direct_manifest = responses[2].value.object.get("result").?.object;
    try testing.expectEqualStrings(capabilities.capability_schema, direct_manifest.get("schema").?.string);
    try testing.expect(direct_manifest.get("build").?.object.get("buildId") != null);
    try testing.expectEqualStrings(direct_manifest.get("schemaHash").?.string, init_navgraph.get("schemaHash").?.string);
    try testing.expectEqualStrings(direct_manifest.get("server").?.object.get("agentSchemaHash").?.string, init_navgraph.get("agentSchemaHash").?.string);

    const tool_result = responses[3].value.object.get("result").?.object;
    const manifest_text = tool_result.get("content").?.array.items[0].object.get("text").?.string;
    var manifest = try std.json.parseFromSlice(std.json.Value, testing.allocator, manifest_text, .{});
    defer manifest.deinit();
    try testing.expectEqualStrings(capabilities.capability_schema, manifest.value.object.get("schema").?.string);
    try testing.expect(std.mem.indexOf(u8, manifest_text, "\"name\":\"java\"") != null);
    try testing.expectEqualStrings(direct_manifest.get("schemaHash").?.string, manifest.value.object.get("schemaHash").?.string);
}

test "README and agent prompt carry the generated language inventory marker" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;
    const readme = try std.Io.Dir.cwd().readFileAlloc(io, "README.md", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(readme);
    const prompt = try std.Io.Dir.cwd().readFileAlloc(io, "prompt.md", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(prompt);

    var marker_buf: std.ArrayList(u8) = .empty;
    defer marker_buf.deinit(allocator);
    var marker_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &marker_buf);
    defer marker_writer.deinit();
    try marker_writer.writer.writeAll("navgraph-supported-languages: ");
    for (&@import("language.zig").supported, 0..) |language_desc, i| {
        if (i != 0) try marker_writer.writer.writeByte(',');
        try marker_writer.writer.writeAll(language_desc.name);
    }
    const marker = marker_writer.written();
    try testing.expect(std.mem.indexOf(u8, readme, marker) != null);
    try testing.expect(std.mem.indexOf(u8, prompt, marker) != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Anything else (Java") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "(`.java`)") != null);
}

test "server reload atomically refreshes requests and notifications" {
    const testing = std.testing;
    const io = testing.io;
    var fx = try sampleFixture(io);
    defer fx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &fx.idx, fx.idx.root, false);
    defer session.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();

    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"));
    try testing.expect(has(aw.written(), "navgraph.reload"));
    try testing.expectEqual(@as(usize, 0), session.idx.lookup("freshAfterReload").len);
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "app.zig", .data = "pub fn freshAfterReload() void {}\n" });

    const before_notification = aw.written().len;
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"method\":\"workspace/reload\",\"params\":{\"noCache\":true}}"));
    try testing.expectEqual(before_notification, aw.written().len);
    try testing.expectEqual(@as(usize, 1), session.idx.lookup("freshAfterReload").len);

    try fx.tmp.dir.writeFile(io, .{ .sub_path = "app.zig", .data = "pub fn freshFromTool() void {}\n" });
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.reload\",\"arguments\":{\"noCache\":true}}}"));
    try testing.expectEqual(@as(usize, 1), session.idx.lookup("freshFromTool").len);
    try testing.expectEqual(@as(usize, 0), session.idx.lookup("freshAfterReload").len);
    try testing.expect(try handleServerRequest(&aw.writer, &session, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph.reload\",\"arguments\":{\"unknown\":true}}}"));
    try testing.expectEqual(@as(usize, 1), session.idx.lookup("freshFromTool").len);

    var lines = std.mem.tokenizeScalar(u8, aw.written(), '\n');
    var responses: u32 = 0;
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try testing.expect(parsed.value == .object);
        responses += 1;
    }
    try testing.expectEqual(@as(u32, 3), responses);
    try testing.expect(has(aw.written(), "index reloaded"));
    try testing.expect(has(aw.written(), "\"error\":{\"code\":-32602"));
}

test "failed server reload preserves the previous index" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "only.zig", .data = "pub fn stillIndexed() void {}\n" });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/only.zig", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var session = try ServerSession.init(testing.allocator, io, &idx, root, false);
    defer session.deinit();
    try testing.expectEqual(@as(usize, 1), idx.lookup("stillIndexed").len);
    try tmp.dir.deleteFile(io, "only.zig");

    if (session.reload(false)) |_| return error.ReloadOfMissingRootSucceeded else |err| {
        try testing.expect(@errorName(err).len > 0);
    }
    try testing.expectEqual(@as(usize, 1), idx.lookup("stillIndexed").len);
}
