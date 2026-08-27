//! LSP wire framing and JSON-RPC 2.0 envelopes.
//!
//! Framing and envelope handling are kept free of IO so both can be tested
//! against byte slices: `nextFrame` extracts one message from a growing buffer,
//! and the writers render a response into any `std.Io.Writer`.

const std = @import("std");

const Writer = std.Io.Writer;

/// Largest header block (bytes before the blank line) we will buffer. A stream
/// that never terminates its headers is malformed, not merely incomplete.
pub const max_header_bytes: usize = 8 * 1024;

/// JSON-RPC error codes. The `-32000..-32099` range is server-defined; navgraph
/// uses `symbol_not_found` for a target that resolves to nothing.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    symbol_not_found = -32001,
    request_failed = -32002,
};

/// A JSON-RPC request id. `none` is a notification (no response is sent).
pub const Id = union(enum) {
    none,
    number: i64,
    string: []const u8,

    /// Write the id as a JSON value (`null` for a notification, so an error
    /// response to an unidentifiable message is still well-formed).
    pub fn write(self: Id, w: *Writer) !void {
        switch (self) {
            .none => try w.writeAll("null"),
            .number => |n| try w.print("{d}", .{n}),
            .string => |s| try std.json.Stringify.encodeJsonString(s, .{}, w),
        }
    }
};

/// One decoded message body.
pub const Message = struct {
    id: Id,
    method: []const u8,
    /// The `params` member, or null when absent.
    params: ?std.json.Value,
};

pub const DecodeError = struct {
    id: Id,
    code: ErrorCode,
    message: []const u8,
};

pub const Decoded = union(enum) {
    message: Message,
    /// The body was not a usable JSON-RPC request; reply with this error unless
    /// the id is `none` (a malformed notification gets no reply, per spec).
    invalid: DecodeError,
};

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

pub const FrameError = error{
    /// Header block present but no usable `Content-Length`.
    MissingContentLength,
    /// A header line was not `Name: value`, or the length was not a number.
    MalformedHeader,
    /// `Content-Length` exceeded the configured cap.
    BodyTooLarge,
};

/// One extracted frame: the message body and how many bytes of the input it
/// consumed (headers included).
pub const Frame = struct { body: []const u8, consumed: usize };

/// The outcome of trying to read one frame off the front of a buffer.
pub const Extract = union(enum) {
    /// `buf` holds only part of a frame; read more bytes and retry.
    incomplete,
    frame: Frame,
    /// The frame was unusable. `consumed` is the resync point: drop that many
    /// bytes and keep serving. Always non-zero, so a reader always progresses.
    malformed: struct { consumed: usize, err: FrameError },
};

/// The header every frame starts with, and so the only place a frame can begin
/// again once the stream has lost sync.
const frame_marker = "Content-Length:";

const Resync = union(enum) {
    /// A frame can begin at this offset; sync is regained.
    at: usize,
    /// No frame boundary in sight: drop this many bytes and keep hunting.
    drop: usize,
};

/// Find the next frame boundary in `buf` after the stream lost sync.
///
/// The marker is matched anywhere, not only at a line start: a real stream puts
/// the next header directly after the previous body's last byte. Bytes at the
/// end that could still grow into the marker are held back for the next read.
fn resync(buf: []const u8) Resync {
    var i: usize = 0;
    while (i + frame_marker.len <= buf.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(buf[i .. i + frame_marker.len], frame_marker)) return .{ .at = i };
    }
    var keep = @min(frame_marker.len - 1, buf.len);
    while (keep > 0) : (keep -= 1) {
        if (std.ascii.eqlIgnoreCase(buf[buf.len - keep ..], frame_marker[0..keep])) break;
    }
    return .{ .drop = buf.len - keep };
}

/// Pulls frames out of a growing byte stream, resynchronizing when it goes bad.
///
/// Stateful because a resync can span many reads: `nextFrame` alone can only
/// say that the bytes in front of it are garbage, and re-reading a malformed
/// frame's body as headers is what lets one bad header swallow every frame
/// behind it. The reader keeps hunting for the next `Content-Length:` across
/// reads instead, so a client is never left waiting on a request that arrived.
pub const Reader = struct {
    resyncing: bool = false,

    pub const Result = union(enum) {
        /// Need more bytes. Drop `drop` of them meanwhile (garbage being
        /// skipped); the rest is a partial frame and must be kept.
        incomplete: struct { drop: usize },
        frame: Frame,
        /// Sync was just lost. `consumed` bytes are garbage and it is always
        /// non-zero, so a reader driving this in a loop always progresses.
        /// Reported once per run of garbage: the reads that follow, until the
        /// stream resyncs, come back `incomplete`.
        malformed: struct { consumed: usize, err: FrameError },
    };

    pub fn next(self: *Reader, buf: []const u8, max_body: usize) Result {
        var at: usize = 0;
        if (self.resyncing) {
            switch (resync(buf)) {
                .at => |i| {
                    at = i;
                    self.resyncing = false;
                },
                .drop => |n| return .{ .incomplete = .{ .drop = n } },
            }
        }
        return switch (nextFrame(buf[at..], max_body)) {
            .incomplete => .{ .incomplete = .{ .drop = at } },
            .frame => |f| .{ .frame = .{ .body = f.body, .consumed = at + f.consumed } },
            .malformed => |bad| blk: {
                self.resyncing = true;
                // Only the byte the bad frame starts on is consumed here; the
                // rest goes to `resync`. Consuming what `nextFrame` parsed
                // would eat a header that had merged with the garbage in front
                // of it, and consuming nothing would spin.
                break :blk .{ .malformed = .{ .consumed = at + 1, .err = bad.err } };
            },
        };
    }
};

/// Extract one LSP frame from the front of `buf`.
///
/// Tolerates `\n` as well as `\r\n` line endings (some clients and every hand-
/// written test script use bare `\n`), ignores headers other than
/// `Content-Length`, and matches the header name case-insensitively.
///
/// Every failure resynchronizes to the next plausible frame boundary rather
/// than to the offending header line: a malformed frame's body must never be
/// re-read as headers, or one bad header swallows every frame behind it.
pub fn nextFrame(buf: []const u8, max_body: usize) Extract {
    var content_len: ?usize = null;
    var pos: usize = 0;
    while (true) {
        const line_end = std.mem.indexOfScalarPos(u8, buf, pos, '\n') orelse {
            // No line terminator yet: incomplete, unless the client is streaming
            // an unbounded header block at us.
            if (buf.len - pos > max_header_bytes) {
                return .{ .malformed = .{ .consumed = buf.len, .err = error.MalformedHeader } };
            }
            return .incomplete;
        };
        const line = std.mem.trimEnd(u8, buf[pos..line_end], "\r");
        pos = line_end + 1;
        if (pos > max_header_bytes) {
            return .{ .malformed = .{ .consumed = pos, .err = error.MalformedHeader } };
        }
        if (line.len == 0) break; // end of header block
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
            return .{ .malformed = .{ .consumed = pos, .err = error.MalformedHeader } };
        };
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        content_len = std.fmt.parseInt(usize, value, 10) catch {
            return .{ .malformed = .{ .consumed = pos, .err = error.MalformedHeader } };
        };
    }
    const len = content_len orelse {
        return .{ .malformed = .{ .consumed = pos, .err = error.MissingContentLength } };
    };
    if (len > max_body) {
        // Refused without buffering, so the declared length cannot be used to
        // find the boundary either: the reader resynchronizes on the header.
        return .{ .malformed = .{ .consumed = pos, .err = error.BodyTooLarge } };
    }
    if (buf.len - pos < len) return .incomplete;
    return .{ .frame = .{ .body = buf[pos .. pos + len], .consumed = pos + len } };
}

// ---------------------------------------------------------------------------
// Envelope decoding
// ---------------------------------------------------------------------------

/// Decode one message body. `arena` owns the parsed JSON tree, which the
/// returned `Message` points into.
pub fn decode(arena: std.mem.Allocator, body: []const u8) Decoded {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        return .{ .invalid = .{ .id = .none, .code = .parse_error, .message = "invalid JSON" } };
    };
    if (parsed != .object) {
        return .{ .invalid = .{ .id = .none, .code = .invalid_request, .message = "message must be a JSON object" } };
    }
    const obj = parsed.object;
    const id = idOf(obj.get("id"));
    const method_val = obj.get("method") orelse {
        return .{ .invalid = .{ .id = id, .code = .invalid_request, .message = "missing method" } };
    };
    if (method_val != .string) {
        return .{ .invalid = .{ .id = id, .code = .invalid_request, .message = "method must be a string" } };
    }
    return .{ .message = .{ .id = id, .method = method_val.string, .params = obj.get("params") } };
}

fn idOf(v: ?std.json.Value) Id {
    const val = v orelse return .none;
    return switch (val) {
        .integer => |n| .{ .number = n },
        .string => |s| .{ .string = s },
        else => .none,
    };
}

// ---------------------------------------------------------------------------
// Writers
// ---------------------------------------------------------------------------

/// Write `body` with its `Content-Length` header. The only place the wire format
/// is produced.
pub fn writeFrame(w: *Writer, body: []const u8) !void {
    try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(body);
}

/// Render a success envelope around an already-serialized `result` value.
pub fn writeResult(w: *Writer, id: Id, result_json: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try id.write(w);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeByte('}');
}

/// Render an error envelope. `data_json`, when given, is an already-serialized
/// JSON value attached as `error.data`.
pub fn writeError(w: *Writer, id: Id, code: ErrorCode, message: []const u8, data_json: ?[]const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try id.write(w);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{@intFromEnum(code)});
    try std.json.Stringify.encodeJsonString(message, .{}, w);
    if (data_json) |d| {
        try w.writeAll(",\"data\":");
        try w.writeAll(d);
    }
    try w.writeAll("}}");
}

/// Render a notification envelope around an already-serialized `params` value.
pub fn writeNotification(w: *Writer, method: []const u8, params_json: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try std.json.Stringify.encodeJsonString(method, .{}, w);
    try w.writeAll(",\"params\":");
    try w.writeAll(params_json);
    try w.writeByte('}');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFrame(buf: []const u8, body: []const u8, consumed: usize) !void {
    const got = nextFrame(buf, 1 << 20);
    try testing.expect(got == .frame);
    try testing.expectEqualStrings(body, got.frame.body);
    try testing.expectEqual(consumed, got.frame.consumed);
}

test "nextFrame reads a single well-formed frame" {
    try expectFrame("Content-Length: 2\r\n\r\n{}", "{}", 23);
}

test "nextFrame tolerates bare \\n line endings" {
    try expectFrame("Content-Length: 2\n\n{}", "{}", 21);
}

test "nextFrame ignores extra headers and matches the name case-insensitively" {
    const buf = "content-length: 7\r\nContent-Type: application/vscode-jsonrpc\r\n\r\n{\"a\":1}";
    const got = nextFrame(buf, 1 << 20);
    try testing.expect(got == .frame);
    try testing.expectEqualStrings("{\"a\":1}", got.frame.body);
}

test "nextFrame reports incomplete for a partial header and a partial body" {
    try testing.expect(nextFrame("Content-Len", 1 << 20) == .incomplete);
    try testing.expect(nextFrame("Content-Length: 10\r\n\r\n{}", 1 << 20) == .incomplete);
    try testing.expect(nextFrame("", 1 << 20) == .incomplete);
}

test "nextFrame yields several frames from one buffer" {
    const buf = "Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\n[1,2";
    const first = nextFrame(buf, 1 << 20);
    try testing.expect(first == .frame);
    try testing.expectEqualStrings("{}", first.frame.body);
    const second = nextFrame(buf[first.frame.consumed..], 1 << 20);
    try testing.expect(second == .frame);
    try testing.expectEqualStrings("[1,2", second.frame.body);
}

test "nextFrame rejects a header block with no Content-Length" {
    const got = nextFrame("Content-Type: x\r\n\r\n{}", 1 << 20);
    try testing.expect(got == .malformed);
    try testing.expectEqual(FrameError.MissingContentLength, got.malformed.err);
    // Only the header block is reported consumed; the body is the Reader's to
    // skip, because reading it back as headers is what desyncs the stream.
    try testing.expectEqual(@as(usize, 19), got.malformed.consumed);
}

/// Drive `bad` followed by a good frame through a `Reader` in `chunk`-byte
/// reads, as a pipe delivers it. Returns how many times sync was lost.
fn resyncCount(bad: []const u8, chunk: usize) !u32 {
    const good = "Content-Length: 2\r\n\r\n{}";
    var buf: [16 * 1024]u8 = undefined;
    const stream = try std.fmt.bufPrint(&buf, "{s}{s}", .{ bad, good });

    var reader: Reader = .{};
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(testing.allocator);
    var losses: u32 = 0;
    var served = false;

    var sent: usize = 0;
    while (sent < stream.len) {
        const end = @min(sent + chunk, stream.len);
        try pending.appendSlice(testing.allocator, stream[sent..end]);
        sent = end;
        var consumed: usize = 0;
        while (true) {
            switch (reader.next(pending.items[consumed..], 1 << 20)) {
                .incomplete => |partial| {
                    consumed += partial.drop;
                    break;
                },
                .malformed => |m| {
                    try testing.expect(m.consumed != 0); // else the loop spins
                    consumed += m.consumed;
                    losses += 1;
                },
                .frame => |f| {
                    try testing.expectEqualStrings("{}", f.body);
                    served = true;
                    consumed += f.consumed;
                },
            }
        }
        std.mem.copyForwards(u8, pending.items, pending.items[consumed..]);
        pending.shrinkRetainingCapacity(pending.items.len - consumed);
    }
    try testing.expect(served);
    return losses;
}

test "a malformed frame with a body never swallows the frame behind it" {
    // Each shape the reviewer wedged the server with, at several read sizes.
    const shapes = [_][]const u8{
        "Content-Length: abc\r\n\r\n{}",
        "Content-Length: -5\r\n\r\n{}",
        "Content-Type: x\r\n\r\n{}",
        "Content-Length: 999999999\r\n\r\n{\"a\":1}",
        // A JSON body is full of colons; none may be read as a header.
        "Content-Length: xx\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"m\"}",
        "garbage\r\n\r\n{\"a\":1}",
        "x" ** (max_header_bytes + 16),
    };
    for (shapes) |bad| {
        for ([_]usize{ 1, 3, 64, 8192 }) |chunk| {
            const losses = try resyncCount(bad, chunk);
            // Sync is lost once and reported once, however the bytes arrive.
            try testing.expectEqual(@as(u32, 1), losses);
        }
    }
}

test "a well-formed stream never enters resync" {
    var reader: Reader = .{};
    const stream = "Content-Length: 2\r\n\r\n{}Content-Length: 4\r\n\r\n[1,2]";
    const first = reader.next(stream, 1 << 20);
    try testing.expectEqualStrings("{}", first.frame.body);
    const second = reader.next(stream[first.frame.consumed..], 1 << 20);
    try testing.expectEqualStrings("[1,2", second.frame.body);
    try testing.expect(!reader.resyncing);
}

test "resync holds back a truncated header instead of dropping it" {
    // Nothing that could still become a header: drop it all.
    try testing.expectEqual(@as(usize, 13), resync("garbage\r\n\r\n{}").drop);
    // A header cut in half by the read boundary is kept for the next read.
    try testing.expectEqual(@as(usize, 11), resync("garbage\r\n\r\nContent-Len").drop);
    try testing.expectEqual(@as(usize, 2), resync("{}Content-Length: 2\r\n\r\n{}").at);
}

test "nextFrame rejects a header line without a colon and a non-numeric length" {
    const no_colon = nextFrame("garbage\r\n\r\n{}", 1 << 20);
    try testing.expect(no_colon == .malformed);
    try testing.expectEqual(FrameError.MalformedHeader, no_colon.malformed.err);

    const bad_len = nextFrame("Content-Length: abc\r\n\r\n{}", 1 << 20);
    try testing.expect(bad_len == .malformed);
    try testing.expectEqual(FrameError.MalformedHeader, bad_len.malformed.err);
}

test "nextFrame rejects a body larger than the cap without buffering it" {
    const got = nextFrame("Content-Length: 999999\r\n\r\n", 1024);
    try testing.expect(got == .malformed);
    try testing.expectEqual(FrameError.BodyTooLarge, got.malformed.err);
}

test "nextFrame rejects an unterminated header block past the cap" {
    const big = "x" ** (max_header_bytes + 16);
    const got = nextFrame(big, 1 << 20);
    try testing.expect(got == .malformed);
    try testing.expectEqual(FrameError.MalformedHeader, got.malformed.err);
    try testing.expectEqual(big.len, got.malformed.consumed);
}

test "decode extracts id, method and params" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = decode(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"m\",\"params\":{\"k\":1}}");
    try testing.expect(got == .message);
    try testing.expectEqual(@as(i64, 7), got.message.id.number);
    try testing.expectEqualStrings("m", got.message.method);
    try testing.expect(got.message.params.? == .object);
}

test "decode accepts a string id and a notification without an id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = decode(arena.allocator(), "{\"id\":\"abc\",\"method\":\"m\"}");
    try testing.expectEqualStrings("abc", s.message.id.string);
    const n = decode(arena.allocator(), "{\"method\":\"m\"}");
    try testing.expect(n.message.id == .none);
    try testing.expect(n.message.params == null);
}

test "decode reports parse and shape failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad_json = decode(arena.allocator(), "{not json");
    try testing.expectEqual(ErrorCode.parse_error, bad_json.invalid.code);

    const not_object = decode(arena.allocator(), "[1,2]");
    try testing.expectEqual(ErrorCode.invalid_request, not_object.invalid.code);

    const no_method = decode(arena.allocator(), "{\"id\":1}");
    try testing.expectEqual(ErrorCode.invalid_request, no_method.invalid.code);
    try testing.expectEqual(@as(i64, 1), no_method.invalid.id.number);

    const bad_method = decode(arena.allocator(), "{\"id\":1,\"method\":5}");
    try testing.expectEqual(ErrorCode.invalid_request, bad_method.invalid.code);
}

fn rendered(alloc: std.mem.Allocator, comptime f: anytype, args: anytype) ![]u8 {
    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return alloc.dupe(u8, aw.written());
}

test "writeFrame emits the Content-Length header and the exact body" {
    const out = try rendered(testing.allocator, writeFrame, .{"{\"a\":1}"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Content-Length: 7\r\n\r\n{\"a\":1}", out);
    // Round-trips through the frame reader.
    try expectFrame(out, "{\"a\":1}", out.len);
}

test "writeResult and writeError produce valid JSON-RPC envelopes" {
    const ok = try rendered(testing.allocator, writeResult, .{ Id{ .number = 3 }, "[]" });
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":[]}", ok);

    const err = try rendered(testing.allocator, writeError, .{
        Id{ .string = "x\"y" }, ErrorCode.method_not_found, "no such method", null,
    });
    defer testing.allocator.free(err);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"x\\\"y\",\"error\":{\"code\":-32601,\"message\":\"no such method\"}}",
        err,
    );

    const with_data = try rendered(testing.allocator, writeError, .{
        Id.none, ErrorCode.symbol_not_found, "symbol not found: q", "{\"name\":\"q\"}",
    });
    defer testing.allocator.free(with_data);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"symbol not found: q\",\"data\":{\"name\":\"q\"}}}",
        with_data,
    );
}

test "writeNotification emits a method and params with no id" {
    const out = try rendered(testing.allocator, writeNotification, .{ "navgraph/indexed", "{\"files\":2}" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"navgraph/indexed\",\"params\":{\"files\":2}}",
        out,
    );
}
