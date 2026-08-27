//! Open-document overlays and `file://` URI handling.
//!
//! An overlay is the editor's in-memory copy of a file. While a document is
//! open its overlay text overrides the copy on disk everywhere the server reads
//! source: indexing, grep, hover and position lookups. Closing it drops the
//! overlay, and the disk copy is authoritative again.

const std = @import("std");

/// The open documents, keyed by root-relative path.
pub const Store = struct {
    gpa: std.mem.Allocator,
    /// path -> text. Both the key and the value are owned by the store.
    docs: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        for (self.docs.keys(), self.docs.values()) |k, v| {
            self.gpa.free(k);
            self.gpa.free(v);
        }
        self.docs.deinit(self.gpa);
    }

    /// Set (or replace) the overlay for `path`. Copies both arguments.
    pub fn put(self: *Store, path: []const u8, text: []const u8) !void {
        const copy = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(copy);
        const gop = try self.docs.getOrPut(self.gpa, path);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, path) catch |err| {
                self.docs.swapRemoveAt(gop.index);
                return err;
            };
        }
        gop.value_ptr.* = copy;
    }

    /// Drop the overlay for `path`. Returns whether one was held.
    pub fn remove(self: *Store, path: []const u8) bool {
        const idx = self.docs.getIndex(path) orelse return false;
        self.gpa.free(self.docs.keys()[idx]);
        self.gpa.free(self.docs.values()[idx]);
        self.docs.swapRemoveAt(idx);
        return true;
    }

    pub fn get(self: *const Store, path: []const u8) ?[]const u8 {
        return self.docs.get(path);
    }

    pub fn count(self: *const Store) usize {
        return self.docs.count();
    }
};

// ---------------------------------------------------------------------------
// file:// URIs
// ---------------------------------------------------------------------------

pub const UriError = error{ NotAFileUri, BadPercentEscape };

/// Decode a `file://` URI into a filesystem path (percent-escapes resolved).
/// Caller owns the result. A bare path (no scheme) is accepted as-is, which is
/// what hand-written scripts and some clients send.
pub fn pathFromUri(gpa: std.mem.Allocator, uri: []const u8) (UriError || std.mem.Allocator.Error)![]u8 {
    var rest = uri;
    if (std.mem.startsWith(u8, uri, "file://")) {
        rest = uri["file://".len..];
        // Strip an authority component ("file://host/path"); an empty authority
        // ("file:///path") leaves `rest` starting at the '/'.
        if (rest.len != 0 and rest[0] != '/') {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NotAFileUri;
            rest = rest[slash..];
        }
    } else if (std.mem.indexOf(u8, uri, "://") != null) {
        return error.NotAFileUri;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] != '%') {
            try out.append(gpa, rest[i]);
            i += 1;
            continue;
        }
        if (i + 2 >= rest.len) return error.BadPercentEscape;
        const byte = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch return error.BadPercentEscape;
        try out.append(gpa, byte);
        i += 3;
    }
    return out.toOwnedSlice(gpa);
}

/// Write `abs_path` as a `file://` URI, percent-escaping everything outside the
/// RFC 3986 unreserved set plus the path separators we must preserve.
pub fn writeUri(w: *std.Io.Writer, abs_path: []const u8) !void {
    try w.writeAll("file://");
    if (abs_path.len == 0 or abs_path[0] != '/') try w.writeByte('/');
    try escapePath(w, abs_path);
}

/// Write the `file://` URI of `rel_path` under `root_abs`, without materializing
/// the joined path — the hot path for every symbol in a payload.
pub fn writeUriIn(w: *std.Io.Writer, root_abs: []const u8, rel_path: []const u8) !void {
    try writeUri(w, root_abs);
    if (rel_path.len == 0) return;
    if (!std.mem.endsWith(u8, root_abs, "/")) try w.writeByte('/');
    try escapePath(w, rel_path);
}

fn escapePath(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~/:", c) != null) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

/// The path of `abs_path` relative to `root_abs`, or null when it lies outside
/// the root. Both must be normalized absolute paths.
pub fn relativeTo(root_abs: []const u8, abs_path: []const u8) ?[]const u8 {
    const root = std.mem.trimEnd(u8, root_abs, "/");
    if (!std.mem.startsWith(u8, abs_path, root)) return null;
    const rest = abs_path[root.len..];
    if (rest.len == 0) return "";
    if (rest[0] != '/') return null; // "/a/bc" is not under "/a/b"
    return rest[1..];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Store put replaces the text and keeps one entry per path" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.put("a.zig", "one");
    try s.put("b.zig", "two");
    try s.put("a.zig", "one-updated");
    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expectEqualStrings("one-updated", s.get("a.zig").?);
    try testing.expectEqualStrings("two", s.get("b.zig").?);
}

test "Store copies its arguments so callers may reuse their buffers" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    var path_buf = "a.zig".*;
    var text_buf = "hello".*;
    try s.put(&path_buf, &text_buf);
    @memset(&path_buf, 'x');
    @memset(&text_buf, 'y');
    try testing.expectEqualStrings("hello", s.get("a.zig").?);
}

test "Store remove drops the overlay and reports whether one was held" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.put("a.zig", "one");
    try testing.expect(s.remove("a.zig"));
    try testing.expect(s.get("a.zig") == null);
    try testing.expect(!s.remove("a.zig"));
    try testing.expectEqual(@as(usize, 0), s.count());
}

test "pathFromUri decodes escapes, authorities and bare paths" {
    const cases = [_]struct { uri: []const u8, path: []const u8 }{
        .{ .uri = "file:///home/u/a.zig", .path = "/home/u/a.zig" },
        .{ .uri = "file:///home/my%20dir/a%2Bb.zig", .path = "/home/my dir/a+b.zig" },
        .{ .uri = "file://localhost/tmp/x.zig", .path = "/tmp/x.zig" },
        .{ .uri = "/plain/path.zig", .path = "/plain/path.zig" },
    };
    for (cases) |c| {
        const got = try pathFromUri(testing.allocator, c.uri);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.path, got);
    }
}

test "pathFromUri rejects a non-file scheme and a truncated escape" {
    try testing.expectError(error.NotAFileUri, pathFromUri(testing.allocator, "http://example.com/x"));
    try testing.expectError(error.BadPercentEscape, pathFromUri(testing.allocator, "file:///a%2"));
    try testing.expectError(error.BadPercentEscape, pathFromUri(testing.allocator, "file:///a%zz"));
}

test "writeUri escapes and round-trips through pathFromUri" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeUri(&aw.writer, "/home/my dir/a+b.zig");
    try testing.expectEqualStrings("file:///home/my%20dir/a%2Bb.zig", aw.written());

    const back = try pathFromUri(testing.allocator, aw.written());
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("/home/my dir/a+b.zig", back);
}

test "writeUriIn joins a root and a relative path into one URI" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeUriIn(&aw.writer, "/w/repo", "src/a b.zig");
    try testing.expectEqualStrings("file:///w/repo/src/a%20b.zig", aw.written());

    aw.clearRetainingCapacity();
    try writeUriIn(&aw.writer, "/w/repo/", "src/a.zig");
    try testing.expectEqualStrings("file:///w/repo/src/a.zig", aw.written());

    aw.clearRetainingCapacity();
    try writeUriIn(&aw.writer, "/w/repo", "");
    try testing.expectEqualStrings("file:///w/repo", aw.written());
}

test "relativeTo strips the root and rejects paths outside it" {
    try testing.expectEqualStrings("src/a.zig", relativeTo("/w/repo", "/w/repo/src/a.zig").?);
    try testing.expectEqualStrings("src/a.zig", relativeTo("/w/repo/", "/w/repo/src/a.zig").?);
    try testing.expectEqualStrings("", relativeTo("/w/repo", "/w/repo").?);
    try testing.expect(relativeTo("/w/repo", "/w/repository/a.zig") == null);
    try testing.expect(relativeTo("/w/repo", "/other/a.zig") == null);
}
