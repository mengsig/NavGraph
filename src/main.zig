//! NavGraph CLI entry point: parse args, build the index, dispatch the query.

const std = @import("std");
const model = @import("model.zig");
const cli = @import("cli.zig");
const index_mod = @import("index.zig");
const query = @import("query.zig");
const workflow = @import("workflow.zig");
const json_out = @import("json_out.zig");
const viz = @import("viz.zig");

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
        try cli.usage(out);
        try out.flush();
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
    if (parsed.command == .help) {
        try cli.usage(out);
        try out.flush();
        return;
    }

    var idx = index_mod.build(gpa, io, parsed.root, parsed.use_cache) catch |err| {
        try out.print("navgraph: failed to index '{s}': {s}\n", .{ parsed.root, @errorName(err) });
        try out.flush();
        return err;
    };
    defer idx.deinit();

    if (parsed.command == .serve) {
        var session = try ServerSession.init(gpa, io, &idx, parsed.root, parsed.use_cache);
        defer session.deinit();
        try serve(out, &session);
        try out.flush();
        return;
    }

    const found = dispatch(out, io, &idx, parsed) catch |err| switch (err) {
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

/// Run the parsed command; true when at least one real result row was printed
/// (notes, suggestions, and empty JSON arrays don't count).
fn dispatch(out: *std.Io.Writer, io: std.Io, idx: *index_mod.Index, parsed: cli.Parsed) !bool {
    return switch (parsed.command) {
        .outline => try query.outline(out, idx, parsed.arg, parsed.options),
        .files => try query.listFiles(out, idx, parsed.arg, parsed.options),
        .status => try query.status(out, io, idx, parsed.arg, parsed.options),
        .read => try query.readLines(out, io, idx, parsed.root, parsed.arg, parsed.options),
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
        .neighbors => try query.neighbors(out, idx, parsed.arg, parsed.options),
        .unused => try query.unused(out, idx, parsed.arg, parsed.options),
        .imports => try query.listImports(out, idx, parsed.arg, parsed.options),
        .importers => try query.listImporters(out, idx, parsed.arg, parsed.options),
        .path => try query.shortestPath(out, idx, parsed.arg, parsed.arg2, parsed.options),
        .flow => try query.flow(out, idx, parsed.arg, parsed.options),
        .reaches => try workflow.reaches(out, idx, parsed.arg, parsed.options),
        .affected => try workflow.affected(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .hot => try query.hot(out, idx, parsed.arg, parsed.options),
        .diff => try query.diff(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .todos => try workflow.todos(out, idx, parsed.arg, parsed.options),
        .edits => try workflow.edits(out, idx, parsed.arg, parsed.options),
        .rename => try workflow.rename(out, io, idx, parsed.root, parsed.arg, parsed.arg2, parsed.options),
        .coverage => try query.coverage(out, idx, parsed.arg, parsed.options),
        .graph => blk: {
            try viz.graph(out, idx, parsed.arg, parsed.options);
            break :blk true; // graph always emits a page/model
        },
        .serve, .help => unreachable,
    };
}

const ServerSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    idx: *index_mod.Index,
    root: []u8,
    use_cache: bool,

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        idx: *index_mod.Index,
        root: []const u8,
        use_cache: bool,
    ) !ServerSession {
        std.debug.assert(root.len > 0);
        std.debug.assert(idx.gpa.ptr == gpa.ptr);
        return .{ .gpa = gpa, .io = io, .idx = idx, .root = try gpa.dupe(u8, root), .use_cache = use_cache };
    }

    fn deinit(self: *ServerSession) void {
        self.gpa.free(self.root);
        self.* = undefined;
    }

    fn reload(self: *ServerSession, use_cache: bool) !void {
        std.debug.assert(self.root.len > 0);
        std.debug.assert(self.idx.gpa.ptr == self.gpa.ptr);
        var fresh = try index_mod.build(self.gpa, self.io, self.root, use_cache);
        const old = self.idx.*;
        self.idx.* = fresh;
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
    while (try input.takeDelimiter('\n')) |raw| {
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
    try out.writeAll("{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"navgraph\",\"version\":\"phase3\"}}}\n");
    return true;
}

fn rpcTools(out: *std.Io.Writer, id: ?std.json.Value) !bool {
    std.debug.assert(id != null);
    try rpcResultPrefix(out, id);
    try out.writeAll("{\"tools\":[");
    try out.writeAll("{\"name\":\"navgraph\",\"description\":\"Run a NavGraph command against the server's in-memory index\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"args\":{\"type\":\"array\",\"minItems\":1,\"items\":{\"type\":\"string\"}}},\"required\":[\"args\"]}},");
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
    if (std.mem.eql(u8, name.string, "navgraph.reload"))
        return rpcReloadTool(out, session, id, arguments);
    try rpcError(out, id, -32602, "unknown tool");
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
    if (request.command == .serve or request.command == .help or !std.mem.eql(u8, request.root, ".")) {
        try rpcError(out, id, -32602, "serve, help, and -C are not allowed inside a server request");
        return true;
    }
    request.root = session.root;
    try dispatchServerResult(out, session, id, request);
    return true;
}

fn dispatchServerResult(out: *std.Io.Writer, session: *ServerSession, id: ?std.json.Value, request: cli.Parsed) !void {
    std.debug.assert(request.command != .serve and request.command != .help);
    std.debug.assert(request.root.len > 0);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(session.gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(session.gpa, &buf);
    defer aw.deinit();
    const found = dispatch(&aw.writer, session.io, session.idx, request) catch |err| {
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
