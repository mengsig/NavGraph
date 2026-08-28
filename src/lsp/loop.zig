//! The stdio run loop.
//!
//! Single-threaded by design: one timed read on stdin drives everything. When
//! the read times out, the debounce window or the mtime watcher is due and the
//! loop does that work; otherwise it extracts whatever complete frames arrived
//! and dispatches them one at a time. Because the same thread owns the index,
//! the reader and the writer, there is no shared mutable state and no lock.
//!
//! stdout is the protocol channel and carries nothing but frames. Diagnostics go
//! to stderr, or to `--log <file>`.

const std = @import("std");
const handlers = @import("handlers.zig");
const rpc = @import("rpc.zig");
const session_mod = @import("session.zig");

const Writer = std.Io.Writer;

/// Largest message body accepted. A bigger `Content-Length` is refused without
/// buffering it, so a bad client cannot exhaust memory.
pub const max_body_bytes: usize = 32 * 1024 * 1024;

const read_chunk = 64 * 1024;

pub const Options = struct {
    /// `--root`; empty means take the root from `initialize`.
    root: []const u8 = "",
    /// `--log <file>`; empty means log to stderr.
    log_path: []const u8 = "",
    log_level: handlers.LogLevel = .err,
};

/// Serve until stdin ends or the client sends `exit`. Returns the process exit
/// code: 0 for a clean shutdown or EOF, 1 for `exit` without `shutdown`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, opts: Options) !u8 {
    var out_buf: [64 * 1024]u8 = undefined;
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);

    var log_buf: [8 * 1024]u8 = undefined;
    const log_file = try openLog(io, opts.log_path);
    defer if (log_file) |f| f.close(io);
    var log_writer: std.Io.File.Writer = .initStreaming(log_file orelse .stderr(), io, &log_buf);

    var server = handlers.Server.init(gpa, io, &out_file.interface, .{
        .writer = &log_writer.interface,
        .level = opts.log_level,
    }, opts.root);
    defer server.deinit();

    var stream: Stream = .{};
    defer stream.deinit(gpa);
    var chunk: [read_chunk]u8 = undefined;

    while (true) {
        if (try pump(gpa, &server, &stream)) |code| return code;

        const n = readSome(io, &server, &chunk) catch |err| switch (err) {
            error.Timeout => {
                try runDueWork(gpa, &server);
                continue;
            },
            error.EndOfStream => return 0,
            else => return err,
        };
        try stream.pending.appendSlice(gpa, chunk[0..n]);
    }
}

/// The stdin byte stream between reads: the bytes that do not yet form a whole
/// frame, and the framing state needed to resync across reads.
const Stream = struct {
    pending: std.ArrayList(u8) = .empty,
    reader: rpc.Reader = .{},

    fn deinit(self: *Stream, gpa: std.mem.Allocator) void {
        self.pending.deinit(gpa);
    }
};

/// Read the next bytes from stdin, waiting no longer than the soonest scheduled
/// deadline so a debounce or watch tick is never starved by an idle client.
fn readSome(io: std.Io, server: *handlers.Server, buf: []u8) !usize {
    const op: std.Io.Operation = .{ .file_read_streaming = .{ .file = .stdin(), .data = &.{buf} } };
    const wait_ms: ?i64 = if (server.session) |*s| s.nextDeadlineMs() else null;
    const result = if (wait_ms) |ms|
        try io.operateTimeout(op, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(ms) } })
    else
        try io.operate(op);
    return result.file_read_streaming;
}

/// Dispatch every complete frame in the stream, then drop what was consumed.
/// Returns an exit code once the client has said `exit`.
fn pump(gpa: std.mem.Allocator, server: *handlers.Server, stream: *Stream) !?u8 {
    const pending = &stream.pending;
    var consumed: usize = 0;
    while (true) {
        switch (stream.reader.next(pending.items[consumed..], max_body_bytes)) {
            .incomplete => |partial| {
                consumed += partial.drop;
                break;
            },
            .malformed => |bad| {
                std.debug.assert(bad.consumed != 0); // else this loop would spin
                consumed += bad.consumed;
                server.log.print(.err, "malformed frame ({s}), resyncing", .{@errorName(bad.err)});
                try reportParseError(gpa, server, @errorName(bad.err));
            },
            .frame => |frame| {
                try handleFrame(gpa, server, frame.body);
                consumed += frame.consumed;
            },
        }
        if (server.exit_code) |code| return code;
    }
    if (consumed != 0) {
        std.mem.copyForwards(u8, pending.items, pending.items[consumed..]);
        pending.shrinkRetainingCapacity(pending.items.len - consumed);
    }
    return null;
}

fn handleFrame(gpa: std.mem.Allocator, server: *handlers.Server, body: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    switch (rpc.decode(alloc, body)) {
        .message => |msg| try server.dispatch(alloc, msg),
        // Answering a response with an error is a protocol violation, and the
        // only request we send carries no information we need back.
        .response => server.log.print(.debug, "ignored response frame", .{}),
        .invalid => |bad| {
            server.log.print(.info, "bad request: {s}", .{bad.message});
            // A malformed *notification* has no id to answer, per JSON-RPC.
            if (bad.id == .none and bad.code != .parse_error) return;
            var envelope: Writer.Allocating = .init(alloc);
            defer envelope.deinit();
            try rpc.writeError(&envelope.writer, bad.id, bad.code, bad.message, null);
            try server.send(envelope.written());
        },
    }
}

/// A frame we could not even parse still gets an answer, so a client is never
/// left waiting on a request the server silently dropped.
fn reportParseError(gpa: std.mem.Allocator, server: *handlers.Server, detail: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var envelope: Writer.Allocating = .init(arena.allocator());
    defer envelope.deinit();
    try rpc.writeError(&envelope.writer, .none, .parse_error, detail, null);
    try server.send(envelope.written());
}

/// Run whatever the clock made due: the debounce flush, then the watcher scan.
fn runDueWork(gpa: std.mem.Allocator, server: *handlers.Server) !void {
    const s = &(server.session orelse return);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const now = s.nowMs();
    if (s.debounce_deadline_ms) |at| {
        if (now >= at) try server.flushPending(alloc, .change);
    }
    if (s.watch_deadline_ms) |at| {
        if (now >= at) {
            const found = try s.scanForChanges();
            s.armWatch();
            if (found != 0) try server.flushPending(alloc, .watch);
        }
    }
}

fn openLog(io: std.Io, path: []const u8) !?std.Io.File {
    if (path.len == 0) return null;
    // Truncated per run: a session's log is about that session.
    return try std.Io.Dir.cwd().createFile(io, path, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const project = [_][2][]const u8{
    .{
        "app.zig",
        \\const util = @import("util.zig");
        \\
        \\pub fn run() void {
        \\    mid();
        \\}
        \\
        \\fn mid() void {
        \\    util.helper();
        \\}
        \\
    },
    .{
        "util.zig",
        \\pub fn helper() void {}
        \\
    },
};

/// Feed `bytes` to the loop in chunks of `chunk` bytes, as a slow pipe would.
fn feed(
    gpa: std.mem.Allocator,
    server: *handlers.Server,
    stream: *Stream,
    bytes: []const u8,
    chunk: usize,
) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const end = @min(i + chunk, bytes.len);
        try stream.pending.appendSlice(gpa, bytes[i..end]);
        _ = try pump(gpa, server, stream);
        i = end;
    }
}

fn framed(gpa: std.mem.Allocator, bodies: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var aw: Writer.Allocating = .fromArrayList(gpa, &out);
    defer aw.deinit();
    for (bodies) |b| try rpc.writeFrame(&aw.writer, b);
    return gpa.dupe(u8, aw.written());
}

test "the loop reassembles a frame split across many reads" {
    const ts = try handlers.TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    var stream: Stream = .{};
    defer stream.deinit(testing.allocator);

    const bytes = try framed(testing.allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"navgraph/status","params":{}}
    });
    defer testing.allocator.free(bytes);

    // One byte at a time: every partial header and partial body must be held.
    try feed(testing.allocator, &ts.server, &stream, bytes, 1);
    try testing.expectEqual(@as(usize, 0), stream.pending.items.len);

    var res = try ts.responseFor(2);
    defer res.deinit();
    try testing.expectEqual(@as(i64, 2), res.value.object.get("result").?.object.get("files").?.integer);
}

test "several frames arriving in one read are all dispatched" {
    const ts = try handlers.TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    var stream: Stream = .{};
    defer stream.deinit(testing.allocator);

    const bytes = try framed(testing.allocator, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"navgraph/status","params":{}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"navgraph/search","params":{"query":"helper"}}
    });
    defer testing.allocator.free(bytes);
    try feed(testing.allocator, &ts.server, &stream, bytes, bytes.len);

    var status = try ts.responseFor(2);
    defer status.deinit();
    try testing.expect(status.value.object.get("result") != null);
    var found = try ts.responseFor(3);
    defer found.deinit();
    try testing.expect(found.value.object.get("result").?.object.get("items").?.array.items.len >= 1);
}

test "a malformed frame is answered and the server keeps serving" {
    const ts = try handlers.TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    try ts.start();
    var stream: Stream = .{};
    defer stream.deinit(testing.allocator);

    const good = try framed(testing.allocator, &.{
        \\{"jsonrpc":"2.0","id":4,"method":"navgraph/status","params":{}}
    });
    defer testing.allocator.free(good);
    const bytes = try std.mem.concat(testing.allocator, u8, &.{ "Content-Type: junk\r\n\r\n", good });
    defer testing.allocator.free(bytes);

    try feed(testing.allocator, &ts.server, &stream, bytes, 7);
    // The bad header block produced a parse error...
    try testing.expect(std.mem.indexOf(u8, ts.out.written(), "-32700") != null);
    // ...and the frame behind it was still served.
    var res = try ts.responseFor(4);
    defer res.deinit();
    try testing.expect(res.value.object.get("result") != null);
}

/// A malformed frame *with a body* must not swallow the frames behind it: the
/// body is skipped, not re-read as headers. Feeds the stream in `chunk`-byte
/// reads so the resync is exercised across read boundaries too.
fn expectServesBehind(bad: []const u8, chunk: usize) !void {
    const gpa = testing.allocator;
    const ts = try handlers.TestServer.init(gpa, testing.io, &project);
    defer ts.deinit();
    try ts.start();
    var stream: Stream = .{};
    defer stream.deinit(gpa);

    const good = try framed(gpa, &.{
        \\{"jsonrpc":"2.0","id":77,"method":"navgraph/status","params":{}}
        ,
        \\{"jsonrpc":"2.0","method":"exit"}
    });
    defer gpa.free(good);
    const bytes = try std.mem.concat(gpa, u8, &.{ bad, good });
    defer gpa.free(bytes);

    try stream.pending.appendSlice(gpa, bytes);
    // `exit` is behind the garbage: reaching it proves the stream resynced.
    try testing.expectEqual(@as(u8, 1), (try pump(gpa, &ts.server, &stream)).?);
    try testing.expect(std.mem.indexOf(u8, ts.out.written(), "-32700") != null);
    var res = try ts.responseFor(77);
    defer res.deinit();
    try testing.expect(res.value.object.get("result") != null);

    // Same stream, one byte at a time.
    const ts2 = try handlers.TestServer.init(gpa, testing.io, &project);
    defer ts2.deinit();
    try ts2.start();
    var slow: Stream = .{};
    defer slow.deinit(gpa);
    try feed(gpa, &ts2.server, &slow, bytes, chunk);
    var res2 = try ts2.responseFor(77);
    defer res2.deinit();
    try testing.expect(res2.value.object.get("result") != null);
}

test "a malformed frame with a body never desyncs the connection" {
    // The reviewer's repro: one bad header, then a request that must be answered.
    try expectServesBehind("Content-Length: abc\r\n\r\n{}", 1);
    try expectServesBehind("Content-Length: -5\r\n\r\n{}", 3);
    try expectServesBehind("Content-Type: x\r\n\r\n{}", 5);
    // A JSON body is full of colons; none may be mistaken for a header.
    try expectServesBehind(
        "Content-Length: xx\r\n\r\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"navgraph/status\"}",
        7,
    );
    // A body we refuse to buffer at all.
    try expectServesBehind("Content-Length: 999999999\r\n\r\n{\"a\":1}", 11);
    // Header bytes that never terminate.
    try expectServesBehind("x" ** (rpc.max_header_bytes + 16), 1024);
}

/// A frame that is well-formed but unusable must cost a reply at most, never
/// the connection: the request behind it is still answered, and no extra frame
/// goes out. `replies` says whether the bad frame itself is answered.
fn expectServedAfter(prefix: []const u8, replies: bool, chunk: usize) !void {
    const gpa = testing.allocator;
    const ts = try handlers.TestServer.init(gpa, testing.io, &project);
    defer ts.deinit();
    try ts.start();
    var stream: Stream = .{};
    defer stream.deinit(gpa);

    const good = try framed(gpa, &.{
        \\{"jsonrpc":"2.0","id":55,"method":"navgraph/status","params":{}}
    });
    defer gpa.free(good);
    const bytes = try std.mem.concat(gpa, u8, &.{ prefix, good });
    defer gpa.free(bytes);

    const before = ts.out.written().len;
    try feed(gpa, &ts.server, &stream, bytes, chunk);
    var res = try ts.responseFor(55);
    defer res.deinit();
    try testing.expect(res.value.object.get("result") != null);
    const sent = std.mem.count(u8, ts.out.written()[before..], "Content-Length:");
    try testing.expectEqual(@as(usize, if (replies) 2 else 1), sent);
}

test "a well-formed but unusable frame never costs the connection" {
    // An empty body is not JSON, so it is answered with a parse error, id null.
    try expectServedAfter("Content-Length: 0\r\n\r\n", true, 1);
    // LSP has no batching, and a body with no id gets no reply.
    try expectServedAfter("Content-Length: 2\r\n\r\n[]", false, 3);
    // A repeated Content-Length: the last one wins, so the body is `{}` and the
    // good frame behind it stays intact. Taking the first (9) would eat into it.
    try expectServedAfter("Content-Length: 9\r\nContent-Length: 2\r\n\r\n{}", false, 5);
    // Bare \n line endings, which hand-written clients and scripts send.
    try expectServedAfter("Content-Length: 2\n\n{}", false, 7);
}

test "a run of garbage is answered once, not once per read" {
    const gpa = testing.allocator;
    const ts = try handlers.TestServer.init(gpa, testing.io, &project);
    defer ts.deinit();
    try ts.start();
    var stream: Stream = .{};
    defer stream.deinit(gpa);

    const junk = "garbage\r\n" ** 512;
    const good = try framed(gpa, &.{
        \\{"jsonrpc":"2.0","id":8,"method":"navgraph/status","params":{}}
    });
    defer gpa.free(good);
    const bytes = try std.mem.concat(gpa, u8, &.{ junk, good });
    defer gpa.free(bytes);
    try feed(gpa, &ts.server, &stream, bytes, 64);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, ts.out.written(), "-32700"));
    var res = try ts.responseFor(8);
    defer res.deinit();
    try testing.expect(res.value.object.get("result") != null);
}

test "a frame whose body is bogus JSON gets -32700 and does not stop the loop" {
    const ts = try handlers.TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    try ts.start();
    var stream: Stream = .{};
    defer stream.deinit(testing.allocator);

    const bytes = try framed(testing.allocator, &.{
        "{not json at all",
        \\{"jsonrpc":"2.0","id":5,"method":"navgraph/status","params":{}}
    });
    defer testing.allocator.free(bytes);
    try feed(testing.allocator, &ts.server, &stream, bytes, 13);

    try testing.expect(std.mem.indexOf(u8, ts.out.written(), "-32700") != null);
    var res = try ts.responseFor(5);
    defer res.deinit();
    try testing.expect(res.value.object.get("result") != null);
}

test "the client's answer to our progress request is never replied to" {
    const gpa = testing.allocator;
    const ts = try handlers.TestServer.init(gpa, testing.io, &project);
    defer ts.deinit();
    var stream: Stream = .{};
    defer stream.deinit(gpa);

    const boot = try framed(gpa, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"window":{"workDoneProgress":true}}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    });
    defer gpa.free(boot);
    try feed(gpa, &ts.server, &stream, boot, 64);
    // We asked the client to create a progress token, so its answer is coming.
    try testing.expect(std.mem.indexOf(u8, ts.out.written(), "window/workDoneProgress/create") != null);

    const before = ts.out.written().len;
    const answer = try framed(gpa, &.{
        \\{"jsonrpc":"2.0","id":"navgraph-progress","result":null}
        ,
        \\{"jsonrpc":"2.0","id":9,"method":"navgraph/status","params":{}}
    });
    defer gpa.free(answer);
    try feed(gpa, &ts.server, &stream, answer, 64);

    // Nothing addressed to "navgraph-progress" went back out...
    try testing.expect(std.mem.indexOf(u8, ts.out.written()[before..], "navgraph-progress") == null);
    // ...and the request behind it was still served.
    var res = try ts.responseFor(9);
    defer res.deinit();
    try testing.expect(res.value.object.get("result") != null);
}

test "exit stops the loop and reports the shutdown-aware code" {
    const ts = try handlers.TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    try ts.start();
    var stream: Stream = .{};
    defer stream.deinit(testing.allocator);

    const bytes = try framed(testing.allocator, &.{
        \\{"jsonrpc":"2.0","method":"exit"}
        ,
        // Never reached: the loop stops at `exit`.
        \\{"jsonrpc":"2.0","id":6,"method":"navgraph/status","params":{}}
    });
    defer testing.allocator.free(bytes);
    try stream.pending.appendSlice(testing.allocator, bytes);
    try testing.expectEqual(@as(u8, 1), (try pump(testing.allocator, &ts.server, &stream)).?);
    try testing.expectError(error.NoSuchResponse, ts.responseFor(6));
}

test "end-to-end: an unsaved edit adds a caller, and closing the buffer reverts it" {
    const gpa = testing.allocator;
    const ts = try handlers.TestServer.init(gpa, testing.io, &project);
    defer ts.deinit();
    var stream: Stream = .{};
    defer stream.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // initialize + initialized, so the workspace root (and its URIs) exist.
    const boot = try framed(gpa, &.{
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8"]}}}}
        ,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    });
    defer gpa.free(boot);
    try feed(gpa, &ts.server, &stream, boot, 64);

    const uri = try ts.uri(alloc, "app.zig");
    const edited =
        \\const util = @import(\"util.zig\");\n\npub fn run() void {\n    mid();\n    util.helper();\n}\n\nfn mid() void {\n    util.helper();\n}\n
    ;

    // Baseline: only `mid` calls helper.
    const before = try framed(gpa, &.{
        \\{"jsonrpc":"2.0","id":2,"method":"navgraph/blast","params":{"symbol":"helper","depth":1}}
    });
    defer gpa.free(before);
    try feed(gpa, &ts.server, &stream, before, 64);
    var base = try ts.responseFor(2);
    defer base.deinit();
    try testing.expectEqual(@as(i64, 2), base.value.object.get("result").?.object
        .get("summary").?.object.get("symbols").?.integer);

    // The editor opens the file unchanged, then types a call to helper in `run`.
    const editing = try framed(gpa, &.{
        try std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":
            \\ {{"uri":"{s}","languageId":"zig","version":1,"text":"{s}"}}}}}}
        , .{ uri, edited }),
        try std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":
            \\ {{"uri":"{s}","version":2}},"contentChanges":[{{"text":"{s}"}}]}}}}
        , .{ uri, edited }),
        \\{"jsonrpc":"2.0","id":3,"method":"navgraph/blast","params":{"symbol":"helper","depth":1}}
    });
    defer gpa.free(editing);
    try feed(gpa, &ts.server, &stream, editing, 64);

    var edited_blast = try ts.responseFor(3);
    defer edited_blast.deinit();
    const nodes = edited_blast.value.object.get("result").?.object.get("nodes").?.array.items;
    // helper now has two direct callers: mid and run.
    try testing.expectEqual(@as(usize, 3), nodes.len);
    var saw_run = false;
    for (nodes) |n| {
        const sym = n.object.get("symbol").?.object;
        if (std.mem.eql(u8, sym.get("name").?.string, "run")) {
            saw_run = true;
            try testing.expectEqual(@as(i64, 1), n.object.get("depth").?.integer);
        }
    }
    try testing.expect(saw_run);

    // The re-index was announced, naming the file that changed.
    const notes = try ts.takeNotifications(alloc, "navgraph/indexed");
    try testing.expect(notes.len >= 1);
    const last = notes[notes.len - 1].object.get("params").?.object;
    try testing.expectEqualStrings("app.zig", last.get("changedFiles").?.array.items[0].string);

    // Closing the buffer drops the overlay and the graph returns to disk truth.
    const closing = try framed(gpa, &.{
        try std.fmt.allocPrint(alloc,
            \\{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":"{s}"}}}}}}
        , .{uri}),
        \\{"jsonrpc":"2.0","id":4,"method":"navgraph/blast","params":{"symbol":"helper","depth":1}}
    });
    defer gpa.free(closing);
    try feed(gpa, &ts.server, &stream, closing, 64);

    var reverted = try ts.responseFor(4);
    defer reverted.deinit();
    try testing.expectEqual(@as(i64, 2), reverted.value.object.get("result").?.object
        .get("summary").?.object.get("symbols").?.integer);
}
