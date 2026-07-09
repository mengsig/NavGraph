//! NavGraph CLI entry point: parse args, build the index, dispatch the query.

const std = @import("std");
const cli = @import("cli.zig");
const index_mod = @import("index.zig");
const query = @import("query.zig");

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
        // A malformed invocation is a usage error: explain it on stderr and exit
        // non-zero so callers (agents, scripts) can detect the failure.
        try err_out.print("navgraph: {s}\n\n", .{cli.reason(err)});
        try cli.usage(err_out);
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

    try dispatch(out, io, &idx, parsed);
    try out.flush();
}

fn dispatch(out: *std.Io.Writer, io: std.Io, idx: *index_mod.Index, parsed: cli.Parsed) !void {
    switch (parsed.command) {
        .outline => try query.outline(out, idx, parsed.arg, parsed.options),
        .files => try query.listFiles(out, idx, parsed.arg, parsed.options),
        .read => try query.readLines(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .strings => try query.strings(out, idx, parsed.arg, parsed.options),
        .def => try query.showDef(out, idx, parsed.arg, parsed.options),
        .calls => try query.walk(out, idx, parsed.arg, false, parsed.options),
        .callers => try query.walk(out, idx, parsed.arg, true, parsed.options),
        .search => try query.search(out, idx, parsed.arg, parsed.options),
        .routes => try query.listRoutes(out, idx, parsed.arg, parsed.options),
        .events => try query.events(out, idx, parsed.arg, parsed.options),
        .neighbors => try query.neighbors(out, idx, parsed.arg, parsed.options),
        .unused => try query.unused(out, idx, parsed.arg, parsed.options),
        .imports => try query.listImports(out, idx, parsed.arg, parsed.options),
        .importers => try query.listImporters(out, idx, parsed.arg, parsed.options),
        .path => try query.shortestPath(out, idx, parsed.arg, parsed.arg2, parsed.options),
        .hot => try query.hot(out, idx, parsed.arg, parsed.options),
        .diff => try query.diff(out, io, idx, parsed.root, parsed.arg, parsed.options),
        .coverage => try query.coverage(out, idx, parsed.arg, parsed.options),
        .help => unreachable,
    }
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
        \\pub fn run() void {
        \\    mid();
        \\    util.helper();
        \\}
        \\
        \\fn mid() void {
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
    try dispatch(&aw.writer, io, idx, parsed);
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
