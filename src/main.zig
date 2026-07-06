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

    try dispatch(out, &idx, parsed);
    try out.flush();
}

fn dispatch(out: *std.Io.Writer, idx: *index_mod.Index, parsed: cli.Parsed) !void {
    switch (parsed.command) {
        .outline => try query.outline(out, idx, parsed.arg, parsed.options),
        .def => try query.showDef(out, idx, parsed.arg, parsed.options),
        .calls => try query.walk(out, idx, parsed.arg, false, parsed.options),
        .callers => try query.walk(out, idx, parsed.arg, true, parsed.options),
        .search => try query.search(out, idx, parsed.arg, parsed.options),
        .routes => try query.listRoutes(out, idx, parsed.arg, parsed.options),
        .help => unreachable,
    }
}
