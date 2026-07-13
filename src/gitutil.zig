const std = @import("std");

pub const Error = error{InvalidGitRef};
pub const Root = union(enum) { path: []const u8, dir: std.Io.Dir };

pub fn validRef(ref: []const u8) bool {
    if (ref.len == 0 or ref[0] == '-') return false;
    for (ref) |c| {
        if (c == 0 or c == '\n' or c == '\r' or c == '\t' or c == ' ') return false;
    }
    return true;
}

pub fn validLowerBoundRef(ref: []const u8) bool {
    return validRef(ref) and std.mem.indexOf(u8, ref, "..") == null;
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, root: []const u8, argv: []const []const u8) !std.process.RunResult {
    return runAt(gpa, io, .{ .path = root }, argv);
}

pub fn runAt(gpa: std.mem.Allocator, io: std.Io, root: Root, argv: []const []const u8) !std.process.RunResult {
    std.debug.assert(argv.len >= 2);
    std.debug.assert(std.mem.eql(u8, argv[0], "git"));
    var owned_dir: ?std.Io.Dir = null;
    const dir = switch (root) {
        .dir => |bound| bound,
        .path => |path| opened: {
            std.debug.assert(path.len > 0);
            owned_dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| parent: {
                if (err != error.NotDir) return err;
                break :parent try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{});
            };
            break :opened owned_dir.?;
        },
    };
    defer if (owned_dir) |owned| owned.close(io);
    return std.process.run(gpa, io, .{
        .argv = argv,
        // Keep the descriptor open through the child lifetime. In addition to
        // server calls (which already supply a retained directory), this binds
        // one-shot calls before spawn instead of validating a pathname and then
        // reopening that mutable spelling inside the child.
        .cwd = .{ .dir = dir },
        .stdout_limit = std.Io.Limit.limited(32 * 1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(4 * 1024 * 1024),
    });
}

test "git revisions reject option-like and whitespace-bearing input" {
    const testing = std.testing;
    try testing.expect(validRef("HEAD"));
    try testing.expect(validRef("HEAD~10"));
    try testing.expect(validRef("release/v1..HEAD"));
    try testing.expect(validLowerBoundRef("release/v1"));
    try testing.expect(!validLowerBoundRef("release/v1..HEAD"));
    try testing.expect(!validRef("--output=/tmp/x"));
    try testing.expect(!validRef("HEAD --help"));
    try testing.expect(!validRef(""));
}
