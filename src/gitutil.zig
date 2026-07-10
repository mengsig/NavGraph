const std = @import("std");

pub const Error = error{InvalidGitRef};

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
    std.debug.assert(root.len > 0);
    std.debug.assert(argv.len >= 2);
    std.debug.assert(std.mem.eql(u8, argv[0], "git"));
    var cwd_path = root;
    var root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch |err| dir: {
        if (err != error.NotDir) return err;
        cwd_path = std.fs.path.dirname(root) orelse ".";
        break :dir try std.Io.Dir.cwd().openDir(io, cwd_path, .{});
    };
    root_dir.close(io);
    return std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd_path },
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
