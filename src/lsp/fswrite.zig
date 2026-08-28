//! Guarded writes for files a request handler creates under the served root
//! (currently only `.navgraph/`), where the path is predictable from repo
//! content and the repo itself may be untrusted (a clone, a PR branch, a
//! vendored dependency).
//!
//! `writeGuarded` never opens the destination path directly. It stages the
//! bytes in a temp file in the same directory, then renames the temp file
//! into place. `rename(2)` replaces whatever directory entry sits at the
//! destination — file, symlink, or nothing — without ever following a
//! symlink planted there, so a pre-existing symlink at a guessed path cannot
//! redirect the write to its target (coldstart review F1).

const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;

pub const Error = error{WriteFailed} || std.mem.Allocator.Error;

/// Write `bytes` to `dir`/`rel`, creating parent directories as needed,
/// replacing whatever is already at `rel`. On failure, `detail.*` is set to
/// an allocated (from `gpa`) message naming the path and the OS error, for
/// the caller to surface in a JSON-RPC error message; `error.WriteFailed` is
/// returned in that case.
pub fn writeGuarded(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    rel: []const u8,
    bytes: []const u8,
    detail: *?[]const u8,
) Error!void {
    var af = dir.createFileAtomic(io, rel, .{ .make_path = true, .replace = true }) catch |err|
        return fail(gpa, detail, rel, err);
    defer af.deinit(io);

    af.file.writeStreamingAll(io, bytes) catch |err| return fail(gpa, detail, rel, err);
    af.replace(io) catch |err| return fail(gpa, detail, rel, err);
}

fn fail(gpa: std.mem.Allocator, detail: *?[]const u8, rel: []const u8, err: anyerror) Error {
    detail.* = std.fmt.allocPrint(gpa, "cannot write {s} ({s})", .{ rel, @errorName(err) }) catch |alloc_err| return alloc_err;
    return error.WriteFailed;
}

const testing = std.testing;

test "writeGuarded replaces a pre-existing symlink instead of writing through it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "PRECIOUS-ORIGINAL-CONTENT" });
    try tmp.dir.createDirPath(io, ".navgraph");
    try tmp.dir.symLink(io, "../victim.txt", ".navgraph/graph-deadbeef.html", .{});

    var detail: ?[]const u8 = null;
    try writeGuarded(testing.allocator, io, tmp.dir, ".navgraph/graph-deadbeef.html", "<!doctype html>new graph", &detail);
    try testing.expect(detail == null);

    // The symlink's target must be untouched.
    var victim_buf: [64]u8 = undefined;
    const victim = try tmp.dir.readFile(io, "victim.txt", &victim_buf);
    try testing.expectEqualStrings("PRECIOUS-ORIGINAL-CONTENT", victim);

    // The guessed path itself now holds the real content, no longer a symlink.
    var out_buf: [64]u8 = undefined;
    const out = try tmp.dir.readFile(io, ".navgraph/graph-deadbeef.html", &out_buf);
    try testing.expectEqualStrings("<!doctype html>new graph", out);
    const st = try tmp.dir.statFile(io, ".navgraph/graph-deadbeef.html", .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.file, st.kind);
}

test "writeGuarded overwrites a plain file in place, repeatable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var detail: ?[]const u8 = null;
    try writeGuarded(testing.allocator, io, tmp.dir, ".navgraph/view.html", "first", &detail);
    try writeGuarded(testing.allocator, io, tmp.dir, ".navgraph/view.html", "second", &detail);

    var buf: [16]u8 = undefined;
    const out = try tmp.dir.readFile(io, ".navgraph/view.html", &buf);
    try testing.expectEqualStrings("second", out);
}
