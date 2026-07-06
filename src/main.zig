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

    const argv = try init.minimal.args.toSlice(arena);
    const parsed = cli.parse(argv[1..]) catch {
        try cli.usage(out);
        try out.flush();
        return;
    };
    if (parsed.command == .help) {
        try cli.usage(out);
        try out.flush();
        return;
    }

    var idx = index_mod.build(gpa, io, parsed.root) catch |err| {
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
