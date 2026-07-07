//! Parses `git diff --unified=0` output into per-file changed line ranges (in the
//! *new* file), so a caller can map edits back to the symbols they touch. Pure
//! text processing — running git lives in the caller, keeping this testable.

const std = @import("std");

/// A closed range of 1-based line numbers in the new file.
pub const Range = struct { lo: u32, hi: u32 };

/// The changed line ranges of one file in a diff.
pub const FileChange = struct {
    /// New (post-image) repo-relative path. A pure deletion (`+++ /dev/null`) is
    /// skipped entirely — it has no lines to map to surviving symbols.
    path: []const u8,
    ranges: []Range,
};

/// Parse unified-diff `text` into a list of `FileChange` (gpa-owned; caller frees
/// via `freeChanges`). Recognizes `+++ b/<path>` headers and `@@ … +c,d @@`
/// hunks, recording the new-file range each hunk covers. `d == 0` (a pure
/// deletion) is recorded as the single anchor line `c` so the enclosing symbol
/// still surfaces. Slices into `text`, which must outlive the result.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ![]FileChange {
    var files: std.ArrayList(FileChange) = .empty;
    errdefer freeChanges(gpa, files.items);
    var cur_path: ?[]const u8 = null;
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(gpa);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ ")) {
            try flush(gpa, &files, &cur_path, &ranges);
            cur_path = newPath(line[4..]);
        } else if (std.mem.startsWith(u8, line, "@@")) {
            if (cur_path == null) continue;
            if (hunkRange(line)) |r| try ranges.append(gpa, r);
        }
    }
    try flush(gpa, &files, &cur_path, &ranges);
    return files.toOwnedSlice(gpa);
}

/// Emit the pending file's ranges (if any) into `files` and reset the buffer.
fn flush(
    gpa: std.mem.Allocator,
    files: *std.ArrayList(FileChange),
    cur_path: *?[]const u8,
    ranges: *std.ArrayList(Range),
) !void {
    const path = cur_path.* orelse return;
    cur_path.* = null;
    if (ranges.items.len == 0) return;
    try files.append(gpa, .{ .path = path, .ranges = try ranges.toOwnedSlice(gpa) });
}

pub fn freeChanges(gpa: std.mem.Allocator, changes: []FileChange) void {
    for (changes) |c| gpa.free(c.ranges);
    gpa.free(changes);
}

/// The repo-relative new path from a `+++ ` header body, or null for
/// `/dev/null` (deletion). Strips a leading `b/` and any trailing tab metadata.
fn newPath(body_in: []const u8) ?[]const u8 {
    var body = body_in;
    if (std.mem.indexOfScalar(u8, body, '\t')) |t| body = body[0..t];
    body = std.mem.trimEnd(u8, body, " \r");
    if (std.mem.eql(u8, body, "/dev/null")) return null;
    if (std.mem.startsWith(u8, body, "b/")) body = body[2..];
    return if (body.len == 0) null else body;
}

/// The new-file range of a hunk header `@@ -a,b +c,d @@`. Returns null when the
/// header is malformed. `d` defaults to 1 when omitted; `d == 0` yields `[c, c]`.
fn hunkRange(line: []const u8) ?Range {
    const plus = std.mem.indexOfScalar(u8, line, '+') orelse return null;
    var rest = line[plus + 1 ..];
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    rest = rest[0..end];
    var parts = std.mem.splitScalar(u8, rest, ',');
    const start_s = parts.next() orelse return null;
    const start = std.fmt.parseInt(u32, start_s, 10) catch return null;
    const len: u32 = if (parts.next()) |len_s|
        std.fmt.parseInt(u32, len_s, 10) catch return null
    else
        1;
    if (len == 0) return .{ .lo = start, .hi = start };
    return .{ .lo = start, .hi = start + len - 1 };
}

test "parse extracts per-file new-line ranges, skipping deletions" {
    const gpa = std.testing.allocator;
    const diff =
        \\diff --git a/src/foo.zig b/src/foo.zig
        \\index 111..222 100644
        \\--- a/src/foo.zig
        \\+++ b/src/foo.zig
        \\@@ -10,2 +10,3 @@ fn a() void {
        \\ ctx
        \\@@ -40 +41,0 @@ fn b() void {
        \\diff --git a/old.txt b/dev/null
        \\--- a/old.txt
        \\+++ /dev/null
        \\@@ -1,5 +0,0 @@
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("src/foo.zig", changes[0].path);
    try std.testing.expectEqual(@as(usize, 2), changes[0].ranges.len);
    // `+10,3` → lines 10..12; `+41,0` (deletion) → anchor line 41.
    try std.testing.expectEqual(Range{ .lo = 10, .hi = 12 }, changes[0].ranges[0]);
    try std.testing.expectEqual(Range{ .lo = 41, .hi = 41 }, changes[0].ranges[1]);
}

test "hunkRange defaults length to 1 when omitted" {
    try std.testing.expectEqual(Range{ .lo = 7, .hi = 7 }, hunkRange("@@ -7 +7 @@").?);
    try std.testing.expectEqual(Range{ .lo = 3, .hi = 4 }, hunkRange("@@ -1,1 +3,2 @@ ctx").?);
    try std.testing.expectEqual(@as(?Range, null), hunkRange("@@ garbage"));
}
