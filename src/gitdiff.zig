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


// ---------------------------------------------------------------------------
// Appended hardening tests for gitdiff.zig
// ---------------------------------------------------------------------------

test "parse keeps every file with its own ranges" {
    const gpa = std.testing.allocator;
    const diff =
        \\diff --git a/one.zig b/one.zig
        \\--- a/one.zig
        \\+++ b/one.zig
        \\@@ -1,0 +1,2 @@
        \\diff --git a/two.zig b/two.zig
        \\--- a/two.zig
        \\+++ b/two.zig
        \\@@ -5,1 +5,1 @@ fn a() void {
        \\@@ -10,0 +12,3 @@ fn b() void {
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 2), changes.len);

    try std.testing.expectEqualStrings("one.zig", changes[0].path);
    try std.testing.expectEqual(@as(usize, 1), changes[0].ranges.len);
    try std.testing.expectEqual(Range{ .lo = 1, .hi = 2 }, changes[0].ranges[0]);

    try std.testing.expectEqualStrings("two.zig", changes[1].path);
    try std.testing.expectEqual(@as(usize, 2), changes[1].ranges.len);
    try std.testing.expectEqual(Range{ .lo = 5, .hi = 5 }, changes[1].ranges[0]);
    try std.testing.expectEqual(Range{ .lo = 12, .hi = 14 }, changes[1].ranges[1]);
}

test "parse skips a /dev/null deletion file entirely" {
    const gpa = std.testing.allocator;
    const diff =
        \\diff --git a/keep.zig b/keep.zig
        \\--- a/keep.zig
        \\+++ b/keep.zig
        \\@@ -3,0 +3,1 @@
        \\diff --git a/gone.zig b/gone.zig
        \\deleted file mode 100644
        \\--- a/gone.zig
        \\+++ /dev/null
        \\@@ -1,7 +0,0 @@
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("keep.zig", changes[0].path);
    try std.testing.expectEqual(Range{ .lo = 3, .hi = 3 }, changes[0].ranges[0]);
}

test "parse records a zero-length (deletion) hunk as its anchor line" {
    const gpa = std.testing.allocator;
    // File still exists (has a +++ b/ path) but these hunks only remove lines.
    const diff =
        \\diff --git a/edit.zig b/edit.zig
        \\--- a/edit.zig
        \\+++ b/edit.zig
        \\@@ -10,5 +9,0 @@ fn a() void {
        \\@@ -20,3 +18,0 @@ fn b() void {
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("edit.zig", changes[0].path);
    try std.testing.expectEqual(@as(usize, 2), changes[0].ranges.len);
    try std.testing.expectEqual(Range{ .lo = 9, .hi = 9 }, changes[0].ranges[0]);
    try std.testing.expectEqual(Range{ .lo = 18, .hi = 18 }, changes[0].ranges[1]);
}

test "parse ignores hunks that appear before any file header" {
    const gpa = std.testing.allocator;
    const diff =
        \\@@ -1,2 +1,3 @@ orphan hunk
        \\@@ -5,0 +6,1 @@ another orphan
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "parse drops a file that has a header but no hunks" {
    const gpa = std.testing.allocator;
    // a.zig gets a +++ header but no @@ lines → flushed with empty ranges → dropped.
    const diff =
        \\diff --git a/a.zig b/a.zig
        \\--- a/a.zig
        \\+++ b/a.zig
        \\diff --git a/b.zig b/b.zig
        \\--- a/b.zig
        \\+++ b/b.zig
        \\@@ -1,0 +1,1 @@
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("b.zig", changes[0].path);
    try std.testing.expectEqual(Range{ .lo = 1, .hi = 1 }, changes[0].ranges[0]);
}

test "parse skips a malformed hunk header but keeps valid ones" {
    const gpa = std.testing.allocator;
    const diff =
        \\diff --git a/m.zig b/m.zig
        \\--- a/m.zig
        \\+++ b/m.zig
        \\@@ -1,0 +1,2 @@ ok
        \\@@ totally malformed no plus here
        \\@@ -9,0 +9,4 @@ ok2
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("m.zig", changes[0].path);
    // Only the two well-formed hunks are recorded.
    try std.testing.expectEqual(@as(usize, 2), changes[0].ranges.len);
    try std.testing.expectEqual(Range{ .lo = 1, .hi = 2 }, changes[0].ranges[0]);
    try std.testing.expectEqual(Range{ .lo = 9, .hi = 12 }, changes[0].ranges[1]);
}

test "parse drops a file whose only hunk header is malformed" {
    const gpa = std.testing.allocator;
    const diff =
        \\diff --git a/bad.zig b/bad.zig
        \\--- a/bad.zig
        \\+++ b/bad.zig
        \\@@ garbage @@
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "parse records a rename under its new post-image path" {
    const gpa = std.testing.allocator;
    // A rename-with-modification: the new path must come from `+++ b/...`.
    const diff =
        \\diff --git a/old/mod.zig b/new/mod.zig
        \\similarity index 87%
        \\rename from old/mod.zig
        \\rename to new/mod.zig
        \\index abc..def 100644
        \\--- a/old/mod.zig
        \\+++ b/new/mod.zig
        \\@@ -3,2 +3,4 @@ fn x() void {
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("new/mod.zig", changes[0].path);
    try std.testing.expectEqual(Range{ .lo = 3, .hi = 6 }, changes[0].ranges[0]);
}

test "parse records a newly-added file (source /dev/null)" {
    const gpa = std.testing.allocator;
    const diff =
        \\diff --git a/new.zig b/new.zig
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/new.zig
        \\@@ -0,0 +1,10 @@
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("new.zig", changes[0].path);
    try std.testing.expectEqual(Range{ .lo = 1, .hi = 10 }, changes[0].ranges[0]);
}

test "parse on empty input yields no files" {
    const gpa = std.testing.allocator;
    const changes = try parse(gpa, "");
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "parse on non-diff text yields no files" {
    const gpa = std.testing.allocator;
    const changes = try parse(gpa, "just some\nplain text\nwith no diff\n");
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "parse handles CRLF line endings" {
    const gpa = std.testing.allocator;
    const diff =
        "diff --git a/c.zig b/c.zig\r\n" ++
        "--- a/c.zig\r\n" ++
        "+++ b/c.zig\r\n" ++
        "@@ -1,0 +1,3 @@\r\n";
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("c.zig", changes[0].path);
    try std.testing.expectEqual(Range{ .lo = 1, .hi = 3 }, changes[0].ranges[0]);
}

test "parse strips trailing tab metadata from the +++ header" {
    const gpa = std.testing.allocator;
    const diff =
        "diff --git a/t.zig b/t.zig\n" ++
        "--- a/t.zig\t2024-01-01 00:00:00\n" ++
        "+++ b/t.zig\t2024-01-02 00:00:00\n" ++
        "@@ -2,0 +2,1 @@\n";
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("t.zig", changes[0].path);
    try std.testing.expectEqual(Range{ .lo = 2, .hi = 2 }, changes[0].ranges[0]);
}

test "parse reuses the range buffer cleanly across many files" {
    const gpa = std.testing.allocator;
    const diff =
        \\+++ b/f1
        \\@@ -1,0 +1,1 @@
        \\@@ -3,0 +3,1 @@
        \\+++ b/f2
        \\@@ -1,0 +1,1 @@
        \\+++ b/f3
        \\@@ -7,0 +7,2 @@
        \\@@ -9,0 +20,5 @@
    ;
    const changes = try parse(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 3), changes.len);
    try std.testing.expectEqualStrings("f1", changes[0].path);
    try std.testing.expectEqual(@as(usize, 2), changes[0].ranges.len);
    try std.testing.expectEqualStrings("f2", changes[1].path);
    try std.testing.expectEqual(@as(usize, 1), changes[1].ranges.len);
    try std.testing.expectEqualStrings("f3", changes[2].path);
    try std.testing.expectEqual(@as(usize, 2), changes[2].ranges.len);
    try std.testing.expectEqual(Range{ .lo = 20, .hi = 24 }, changes[2].ranges[1]);
}

// --- hunkRange direct unit tests -------------------------------------------

test "hunkRange parses an explicit new-range length" {
    try std.testing.expectEqual(Range{ .lo = 3, .hi = 4 }, hunkRange("@@ -1,1 +3,2 @@ ctx").?);
    try std.testing.expectEqual(Range{ .lo = 10, .hi = 12 }, hunkRange("@@ -10,2 +10,3 @@").?);
    try std.testing.expectEqual(Range{ .lo = 1, .hi = 100 }, hunkRange("@@ -1,1 +1,100 @@").?);
}

test "hunkRange defaults omitted length to a single line" {
    try std.testing.expectEqual(Range{ .lo = 12, .hi = 12 }, hunkRange("@@ -7 +12 @@").?);
    try std.testing.expectEqual(Range{ .lo = 42, .hi = 42 }, hunkRange("@@ -42 +42 @@ fn foo").?);
}

test "hunkRange anchors a zero-length hunk to its start line" {
    try std.testing.expectEqual(Range{ .lo = 41, .hi = 41 }, hunkRange("@@ -40 +41,0 @@").?);
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 0 }, hunkRange("@@ -1,5 +0,0 @@").?);
}

test "hunkRange returns null on malformed headers" {
    // No '+' at all.
    try std.testing.expectEqual(@as(?Range, null), hunkRange("@@ garbage"));
    // Non-numeric start.
    try std.testing.expectEqual(@as(?Range, null), hunkRange("@@ -1 +x,2 @@"));
    // Non-numeric length.
    try std.testing.expectEqual(@as(?Range, null), hunkRange("@@ -1 +3,y @@"));
    // Empty start (nothing between '+' and space).
    try std.testing.expectEqual(@as(?Range, null), hunkRange("@@ -1 + @@"));
    // Trailing comma with empty length.
    try std.testing.expectEqual(@as(?Range, null), hunkRange("@@ -1 +5, @@"));
}

test "hunkRange picks the new-file range, not a '+' in trailing context" {
    // The first '+' is the one introducing the new range (+5,3); the '+' in the
    // context tail must not confuse it.
    try std.testing.expectEqual(Range{ .lo = 5, .hi = 7 }, hunkRange("@@ -1,2 +5,3 @@ a + b").?);
}

// --- newPath direct unit tests ---------------------------------------------

test "newPath strips a leading b/ prefix" {
    try std.testing.expectEqualStrings("src/foo.zig", newPath("b/src/foo.zig").?);
    try std.testing.expectEqualStrings("foo.zig", newPath("b/foo.zig").?);
}

test "newPath maps /dev/null to null" {
    try std.testing.expect(newPath("/dev/null") == null);
}

test "newPath strips trailing tab metadata" {
    try std.testing.expectEqualStrings("foo.zig", newPath("b/foo.zig\t2024-01-01 12:00:00").?);
}

test "newPath trims trailing spaces and carriage returns" {
    try std.testing.expectEqualStrings("foo.zig", newPath("b/foo.zig \r").?);
    try std.testing.expectEqualStrings("foo.zig", newPath("b/foo.zig\r").?);
    try std.testing.expectEqualStrings("foo.zig", newPath("b/foo.zig   ").?);
}

test "newPath returns null for empty or prefix-only bodies" {
    try std.testing.expect(newPath("") == null);
    try std.testing.expect(newPath("b/") == null);
    try std.testing.expect(newPath("b/\r") == null);
}

test "newPath without a b/ prefix is returned verbatim" {
    try std.testing.expectEqualStrings("weird.txt", newPath("weird.txt").?);
}

test "freeChanges releases a multi-range, multi-file result without leaking" {
    const gpa = std.testing.allocator;
    const diff =
        \\+++ b/x.zig
        \\@@ -1,0 +1,3 @@
        \\@@ -5,0 +10,2 @@
        \\+++ b/y.zig
        \\@@ -1,0 +1,1 @@
    ;
    const changes = try parse(gpa, diff);
    // Explicitly free (rather than via defer) to exercise freeChanges directly;
    // the testing allocator asserts no leak afterward.
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    freeChanges(gpa, changes);
}
