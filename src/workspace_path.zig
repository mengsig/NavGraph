//! Workspace-root containment for filesystem reads reached through agent tools.
//!
//! `std.Io.Dir` accepts absolute paths by design, and ordinary relative opens
//! may follow a symlink outside the directory. Agent-facing source reads need a
//! stronger contract: lexical parent traversal is rejected, the file is opened
//! with `resolve_beneath` where the platform supports it, and the opened file's
//! canonical path is checked against the canonical root before any bytes are
//! read. Checking the opened descriptor (not only the pathname before open)
//! also closes the common symlink-swap race.

const std = @import("std");
const builtin = @import("builtin");

pub const ValidationError = error{
    EmptyPath,
    AbsolutePath,
    ParentTraversal,
    OutsideRoot,
};

pub fn validateRelative(path: []const u8) ValidationError!void {
    if (path.len == 0) return error.EmptyPath;
    if (std.fs.path.isAbsolute(path)) return error.AbsolutePath;

    var start: usize = 0;
    while (start <= path.len) {
        var end = start;
        while (end < path.len and !std.fs.path.isSep(path[end])) : (end += 1) {}
        if (std.mem.eql(u8, path[start..end], "..")) return error.ParentTraversal;
        if (end == path.len) break;
        start = end + 1;
    }
}

/// Read one existing file while proving the opened descriptor is below `root`.
/// `root` is an already-open directory defining the authority boundary.
pub fn readFileAlloc(
    root: std.Io.Dir,
    io: std.Io,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) ![]u8 {
    var file = try openFile(root, io, path);
    defer file.close(io);
    return readOpenedFileAlloc(file, io, allocator, limit);
}

pub fn readFileAllocKnownRoot(
    root: std.Io.Dir,
    io: std.Io,
    canonical_root: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) ![]u8 {
    var file = try openFileKnownRoot(root, io, canonical_root, path);
    defer file.close(io);
    return readOpenedFileAlloc(file, io, allocator, limit);
}

pub fn readFileAllocKnownTarget(
    root: std.Io.Dir,
    io: std.Io,
    canonical_root: []const u8,
    path: []const u8,
    expected_target: []const u8,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) ![]u8 {
    var file = try openFileKnownTarget(root, io, canonical_root, path, expected_target);
    defer file.close(io);
    return readOpenedFileAlloc(file, io, allocator, limit);
}

/// Open one existing file and return only after the opened descriptor itself
/// has been proven to remain beneath `root`. Callers that also need `stat`
/// should keep this descriptor and perform both stat/read through it, avoiding
/// a second pathname lookup and its symlink-swap race.
pub fn openFile(root: std.Io.Dir, io: std.Io, path: []const u8) !std.Io.File {
    try validateRelative(path);

    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = root.realPath(io, &root_buf) catch |err| return escapeOnUnexpected(@TypeOf(err), err);
    var resolved_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved_len = root.realPathFile(io, path, &resolved_buf) catch |err| return escapeOnUnexpected(@TypeOf(err), err);
    if (!isWithin(root_buf[0..root_len], resolved_buf[0..resolved_len])) return error.OutsideRoot;

    return openFileKnownRoot(root, io, root_buf[0..root_len], path);
}

/// Descriptor-checked open for callers that already canonicalized a stable
/// authority root once (notably the indexer). This avoids repeating root and
/// pre-open canonicalization for every source file while retaining the
/// security-critical opened-descriptor check.
pub fn openFileKnownRoot(
    root: std.Io.Dir,
    io: std.Io,
    canonical_root: []const u8,
    path: []const u8,
) !std.Io.File {
    try validateRelative(path);

    var file = try root.openFile(io, path, .{
        .follow_symlinks = true,
        .resolve_beneath = true,
    });
    errdefer file.close(io);

    var file_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = try openedRelativePath(file, io, canonical_root, &file_buf);

    return file;
}

/// Open `path` beneath `root` and additionally prove that the descriptor still
/// resolves to the exact root-relative target captured when a single-file
/// authority was established. This permits atomic replacement at that target
/// path, but rejects retargeting an authority symlink to a sibling file.
pub fn openFileKnownTarget(
    root: std.Io.Dir,
    io: std.Io,
    canonical_root: []const u8,
    path: []const u8,
    expected_target: []const u8,
) !std.Io.File {
    try validateRelative(path);
    try validateRelative(expected_target);

    var file = try root.openFile(io, path, .{
        .follow_symlinks = true,
        .resolve_beneath = true,
    });
    errdefer file.close(io);

    var file_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative = try openedRelativePath(file, io, canonical_root, &file_buf);
    if (!std.mem.eql(u8, relative, expected_target)) return error.OutsideRoot;

    return file;
}

/// Return the canonical path of an opened file relative to `canonical_root`.
/// The returned slice borrows `buffer`. Comparing this value, rather than an
/// absolute path captured at startup, keeps a retained authority valid if its
/// directory is renamed while still detecting a single-file target swap.
pub fn openedRelativePath(
    file: std.Io.File,
    io: std.Io,
    canonical_root: []const u8,
    buffer: []u8,
) ![]const u8 {
    const file_len = file.realPath(io, buffer) catch |err| return escapeOnUnexpected(@TypeOf(err), err);
    return relativeWithin(canonical_root, buffer[0..file_len]) orelse error.OutsideRoot;
}

pub fn readOpenedFileAlloc(
    file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,
    limit: std.Io.Limit,
) ![]u8 {
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

fn isWithin(root: []const u8, target: []const u8) bool {
    if (target.len < root.len) return false;
    // Exact canonical comparison is deliberately conservative on Windows.
    // NTFS can enable case sensitivity per directory, so ASCII-folding here
    // would accept a distinct case-only sibling as though it were the root.
    const prefix_equal = std.mem.eql(u8, root, target[0..root.len]);
    if (!prefix_equal) return false;
    if (target.len == root.len) return true;
    if (root.len != 0 and std.fs.path.isSep(root[root.len - 1])) return true;
    return std.fs.path.isSep(target[root.len]);
}

fn relativeWithin(root: []const u8, target: []const u8) ?[]const u8 {
    if (!isWithin(root, target) or target.len == root.len) return null;
    var start = root.len;
    if (root.len == 0 or !std.fs.path.isSep(root[root.len - 1])) start += 1;
    if (start >= target.len) return null;
    return target[start..];
}

/// Canonicalization is the only proof that an opened descriptor stayed inside
/// `root`; a platform whose canonicalization syscall fails with an errno std
/// cannot classify (e.g. macOS `fcntl(F_GETPATH)` under a sandboxed/virtiofs
/// CI mount, surfacing as `error.Unexpected`) leaves containment unproven, not
/// disproven. Fail closed: score that the same as a caught escape instead of
/// letting an uncategorized error cross this boundary.
fn escapeOnUnexpected(comptime E: type, err: E) (E || ValidationError) {
    return if (err == error.Unexpected) error.OutsideRoot else err;
}

test "an unclassifiable canonicalization errno is scored as a proven escape, not propagated raw" {
    const RealPathError = error{ Unexpected, FileNotFound, NameTooLong };
    // escapeOnUnexpected returns a bare error value; wrap it in a real error
    // union so expectError has something to match against.
    const call = struct {
        fn run(err: RealPathError) !void {
            return escapeOnUnexpected(RealPathError, err);
        }
    }.run;
    try std.testing.expectError(error.OutsideRoot, call(error.Unexpected));
    try std.testing.expectError(error.FileNotFound, call(error.FileNotFound));
    try std.testing.expectError(error.NameTooLong, call(error.NameTooLong));
}

test "relative path validation rejects absolute and parent traversal" {
    try std.testing.expectError(error.EmptyPath, validateRelative(""));
    try std.testing.expectError(error.AbsolutePath, validateRelative("/etc/passwd"));
    try std.testing.expectError(error.ParentTraversal, validateRelative("../secret"));
    try std.testing.expectError(error.ParentTraversal, validateRelative("src/../../secret"));
    try validateRelative("README.md");
    try validateRelative("ignored/config.json");
    try validateRelative("src/./main.zig");
    // `not..parent` is an ordinary filename, not a traversal component.
    try validateRelative("src/not..parent/file.zig");
}

test "contained read allows ordinary and contained-symlink files but blocks symlink escape" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "root/inside.txt", .data = "inside\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "secret\n" });
    try tmp.dir.symLink(io, "inside.txt", "root/inside-link", .{});
    try tmp.dir.symLink(io, "../outside.txt", "root/outside-link", .{});
    var root = try tmp.dir.openDir(io, "root", .{});
    defer root.close(io);

    const direct = try readFileAlloc(root, io, "inside.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(direct);
    try testing.expectEqualStrings("inside\n", direct);

    const contained_link = try readFileAlloc(root, io, "inside-link", testing.allocator, .limited(1024));
    defer testing.allocator.free(contained_link);
    try testing.expectEqualStrings("inside\n", contained_link);

    try testing.expectError(error.OutsideRoot, readFileAlloc(root, io, "outside-link", testing.allocator, .limited(1024)));
    try testing.expectError(error.ParentTraversal, readFileAlloc(root, io, "../outside.txt", testing.allocator, .limited(1024)));
}

test "exact opened target survives content replacement but rejects symlink retarget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "root", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "root/safe.txt", .data = "safe\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root/secret.txt", .data = "secret\n" });
    try tmp.dir.symLink(io, "safe.txt", "root/entry.txt", .{});
    var root = try tmp.dir.openDir(io, "root", .{});
    defer root.close(io);
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try root.realPath(io, &root_buf);

    var initial = try openFileKnownTarget(root, io, root_buf[0..root_len], "entry.txt", "safe.txt");
    initial.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "root/safe.txt", .data = "updated\n" });
    var replaced = try openFileKnownTarget(root, io, root_buf[0..root_len], "entry.txt", "safe.txt");
    replaced.close(io);

    try tmp.dir.deleteFile(io, "root/entry.txt");
    try tmp.dir.symLink(io, "secret.txt", "root/entry.txt", .{});
    try testing.expectError(error.OutsideRoot, openFileKnownTarget(root, io, root_buf[0..root_len], "entry.txt", "safe.txt"));
}
