//! Parses `git diff --unified=0` output into per-file changed line ranges (in the
//! *new* file), so a caller can map edits back to the symbols they touch. Pure
//! text processing — running git lives in the caller, keeping this testable.

const std = @import("std");

/// A closed range of 1-based line numbers in the new file. A deletion-only
/// hunk keeps its post-image anchor in `lo`/`hi` and sets `empty`.
pub const Range = struct {
    lo: u32,
    hi: u32,
    empty: bool = false,
    /// Removed/replaced old-side lines. Populated only by `parseWithRemoved`.
    removed: u32 = 0,
};

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
/// deletion) is recorded as an empty anchor at line `c`, so the enclosing symbol
/// still surfaces without claiming current source bytes. Paths and ranges are
/// allocator-owned and released by `freeChanges`.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ![]FileChange {
    return parseImpl(gpa, text, false);
}

/// Parse post-image ranges and retain each hunk's old-side removed/replaced line
/// count for churn metrics. Range mapping remains post-image and heuristic.
pub fn parseWithRemoved(gpa: std.mem.Allocator, text: []const u8) ![]FileChange {
    return parseImpl(gpa, text, true);
}

fn parseImpl(gpa: std.mem.Allocator, text: []const u8, include_removed: bool) ![]FileChange {
    var files: std.ArrayList(FileChange) = .empty;
    errdefer {
        freeChangeItems(gpa, files.items);
        files.deinit(gpa);
    }
    var cur_path: ?[]u8 = null;
    errdefer if (cur_path) |path| gpa.free(path);
    var ranges: std.ArrayList(Range) = .empty;
    errdefer ranges.deinit(gpa);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ ")) {
            try flush(gpa, &files, &cur_path, &ranges);
            cur_path = try newPath(gpa, line[4..]);
        } else if (std.mem.startsWith(u8, line, "@@")) {
            if (cur_path == null) continue;
            if (hunkRange(line)) |parsed| {
                var range = parsed;
                if (include_removed) range.removed = oldLength(line) orelse 0;
                try ranges.append(gpa, range);
            }
        }
    }
    try flush(gpa, &files, &cur_path, &ranges);
    return files.toOwnedSlice(gpa);
}

/// Emit the pending file's ranges (if any) into `files` and reset the buffer.
fn flush(
    gpa: std.mem.Allocator,
    files: *std.ArrayList(FileChange),
    cur_path: *?[]u8,
    ranges: *std.ArrayList(Range),
) !void {
    const path = cur_path.* orelse return;
    cur_path.* = null;
    if (ranges.items.len == 0) {
        gpa.free(path);
        return;
    }
    errdefer gpa.free(path);
    const owned_ranges = try ranges.toOwnedSlice(gpa);
    errdefer gpa.free(owned_ranges);
    try files.append(gpa, .{ .path = path, .ranges = owned_ranges });
}

pub fn freeChanges(gpa: std.mem.Allocator, changes: []FileChange) void {
    freeChangeItems(gpa, changes);
    gpa.free(changes);
}

fn freeChangeItems(gpa: std.mem.Allocator, changes: []const FileChange) void {
    std.debug.assert(changes.len <= std.math.maxInt(u32));
    for (changes) |change| {
        gpa.free(change.path);
        gpa.free(change.ranges);
    }
}

/// The repo-relative new path from a `+++ ` header body, or null for
/// `/dev/null` (deletion). Decodes Git C quoting, strips `b/`, and owns the result.
fn newPath(gpa: std.mem.Allocator, body_in: []const u8) !?[]u8 {
    std.debug.assert(body_in.len <= std.math.maxInt(u32));
    std.debug.assert(std.mem.indexOfScalar(u8, body_in, '\n') == null);
    if (std.mem.indexOfScalar(u8, body_in, 0) != null) return error.InvalidGitPath;
    if (body_in.len != 0 and body_in[0] == '"') {
        const decoded = try decodeQuotedPath(gpa, body_in);
        defer gpa.free(decoded);
        return ownNormalizedPath(gpa, decoded);
    }
    var body = body_in;
    if (std.mem.indexOfScalar(u8, body, '\t')) |t| body = body[0..t];
    body = std.mem.trimEnd(u8, body, " \r");
    return ownNormalizedPath(gpa, body);
}

fn ownNormalizedPath(gpa: std.mem.Allocator, body_in: []const u8) !?[]u8 {
    std.debug.assert(body_in.len <= std.math.maxInt(u32));
    std.debug.assert(std.mem.indexOfScalar(u8, body_in, 0) == null);
    var body = body_in;
    if (std.mem.eql(u8, body, "/dev/null")) return null;
    if (std.mem.startsWith(u8, body, "b/")) body = body[2..];
    return if (body.len == 0) null else try gpa.dupe(u8, body);
}

fn decodeQuotedPath(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    std.debug.assert(body.len > 0 and body[0] == '"');
    std.debug.assert(std.mem.indexOfScalar(u8, body, 0) == null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var cursor: usize = 1;
    while (cursor < body.len and body[cursor] != '"') {
        if (body[cursor] == 0) return error.InvalidGitPath;
        if (body[cursor] != '\\') {
            try out.append(gpa, body[cursor]);
            cursor += 1;
            continue;
        }
        cursor += 1;
        if (cursor >= body.len) return error.InvalidGitPath;
        const decoded = try decodeEscape(body, &cursor);
        if (decoded == 0) return error.InvalidGitPath;
        try out.append(gpa, decoded);
    }
    if (cursor >= body.len or body[cursor] != '"') return error.InvalidGitPath;
    const trailing = std.mem.trim(u8, body[cursor + 1 ..], " \r");
    if (trailing.len != 0 and trailing[0] != '\t') return error.InvalidGitPath;
    return out.toOwnedSlice(gpa);
}

fn decodeEscape(body: []const u8, cursor: *usize) !u8 {
    std.debug.assert(cursor.* < body.len);
    std.debug.assert(body[cursor.*] != 0);
    const c = body[cursor.*];
    if (c >= '0' and c <= '7') {
        var value: u16 = 0;
        var digits: u2 = 0;
        while (cursor.* < body.len and digits < 3 and body[cursor.*] >= '0' and body[cursor.*] <= '7') : (digits += 1) {
            value = value * 8 + body[cursor.*] - '0';
            cursor.* += 1;
        }
        if (value > std.math.maxInt(u8)) return error.InvalidGitPath;
        return @intCast(value);
    }
    cursor.* += 1;
    return switch (c) {
        'a' => 0x07,
        'b' => 0x08,
        't' => '\t',
        'n' => '\n',
        'v' => 0x0b,
        'f' => 0x0c,
        'r' => '\r',
        '\\' => '\\',
        '"' => '"',
        else => error.InvalidGitPath,
    };
}

/// The new-file range of a hunk header `@@ -a,b +c,d @@`. Returns null when the
/// header is malformed. `d` defaults to 1 when omitted; `d == 0` yields an empty
/// anchor at `[c, c]`.
fn oldLength(line: []const u8) ?u32 {
    const minus = std.mem.indexOfScalar(u8, line, '-') orelse return null;
    const plus = std.mem.indexOfScalarPos(u8, line, minus + 1, '+') orelse return null;
    var rest = line[minus + 1 .. plus];
    rest = std.mem.trim(u8, rest, " \t");
    var parts = std.mem.splitScalar(u8, rest, ',');
    _ = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    return if (parts.next()) |len_s|
        std.fmt.parseInt(u32, len_s, 10) catch null
    else
        1;
}

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
    if (len == 0) return .{ .lo = start, .hi = start, .empty = true };
    const tail = len - 1;
    if (tail > std.math.maxInt(u32) - start) return null;
    return .{ .lo = start, .hi = start + tail };
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
    try std.testing.expectEqual(Range{ .lo = 41, .hi = 41, .empty = true }, changes[0].ranges[1]);
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
    try std.testing.expectEqual(Range{ .lo = 9, .hi = 9, .empty = true }, changes[0].ranges[0]);
    try std.testing.expectEqual(Range{ .lo = 18, .hi = 18, .empty = true }, changes[0].ranges[1]);
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

test "hunkRange preserves a zero-length hunk at its start line" {
    try std.testing.expectEqual(Range{ .lo = 41, .hi = 41, .empty = true }, hunkRange("@@ -40 +41,0 @@").?);
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 0, .empty = true }, hunkRange("@@ -1,5 +0,0 @@").?);
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
    // The closed end would overflow u32.
    try std.testing.expectEqual(@as(?Range, null), hunkRange("@@ -1 +4294967295,2 @@"));
}

test "hunkRange picks the new-file range, not a '+' in trailing context" {
    // The first '+' is the one introducing the new range (+5,3); the '+' in the
    // context tail must not confuse it.
    try std.testing.expectEqual(Range{ .lo = 5, .hi = 7 }, hunkRange("@@ -1,2 +5,3 @@ a + b").?);
}

// --- newPath direct unit tests ---------------------------------------------

test "newPath normalizes ordinary path headers" {
    const testing = std.testing;
    inline for (.{
        .{ "b/src/foo.zig", "src/foo.zig" },
        .{ "b/foo.zig", "foo.zig" },
        .{ "b/foo.zig\t2024-01-01 12:00:00", "foo.zig" },
        .{ "b/foo.zig \r", "foo.zig" },
        .{ "weird.txt", "weird.txt" },
    }) |case| {
        const actual = (try newPath(testing.allocator, case[0])).?;
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(case[1], actual);
    }
    inline for (.{ "/dev/null", "", "b/", "b/\r" }) |body| {
        try testing.expect(try newPath(testing.allocator, body) == null);
    }
}

test "parse decodes Git C-quoted UTF-8 and escaped path bytes" {
    const testing = std.testing;
    const diff =
        "+++ \"b/src/\\303\\251 file.zig\"\n" ++
        "@@ -1,0 +1,1 @@\n" ++
        "+++ \"b/tab\\tquote\\\"slash\\\\.zig\"\n" ++
        "@@ -1,0 +1,1 @@\n";
    const changes = try parse(testing.allocator, diff);
    defer freeChanges(testing.allocator, changes);
    try testing.expectEqual(@as(usize, 2), changes.len);
    try testing.expectEqualStrings("src/é file.zig", changes[0].path);
    try testing.expectEqualStrings("tab\tquote\"slash\\.zig", changes[1].path);
}

test "parse rejects malformed Git C-quoted paths" {
    const testing = std.testing;
    const bad_escape = "+++ \"b/bad\\q.zig\"\n@@ -1,0 +1,1 @@\n";
    const unterminated = "+++ \"b/bad.zig\n@@ -1,0 +1,1 @@\n";
    const partial = "+++ b/good.zig\n@@ -1,0 +1,1 @@\n+++ \"b/bad\\q.zig\"\n";
    try testing.expectError(error.InvalidGitPath, parse(testing.allocator, bad_escape));
    try testing.expectError(error.InvalidGitPath, parse(testing.allocator, unterminated));
    try testing.expectError(error.InvalidGitPath, parse(testing.allocator, partial));
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

test "parseWithRemoved retains old-side churn counts" {
    const gpa = std.testing.allocator;
    const diff =
        \\+++ b/x.zig
        \\@@ -4,7 +4,2 @@
        \\@@ -1,5 +0,0 @@
    ;
    const changes = try parseWithRemoved(gpa, diff);
    defer freeChanges(gpa, changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(Range{ .lo = 4, .hi = 5, .removed = 7 }, changes[0].ranges[0]);
    try std.testing.expectEqual(Range{ .lo = 0, .hi = 0, .empty = true, .removed = 5 }, changes[0].ranges[1]);
}
