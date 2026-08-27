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

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var chunk: [read_chunk]u8 = undefined;

    while (true) {
        if (try pump(gpa, &server, &pending)) |code| return code;

        const n = readSome(io, &server, &chunk) catch |err| switch (err) {
            error.Timeout => {
                try runDueWork(gpa, &server);
                continue;
            },
            error.EndOfStream => return 0,
            else => return err,
        };
        try pending.appendSlice(gpa, chunk[0..n]);
    }
}

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

/// Dispatch every complete frame in `pending`, then drop what was consumed.
/// Returns an exit code once the client has said `exit`.
fn pump(gpa: std.mem.Allocator, server: *handlers.Server, pending: *std.ArrayList(u8)) !?u8 {
    var consumed: usize = 0;
    while (true) {
        switch (rpc.nextFrame(pending.items[consumed..], max_body_bytes)) {
            .incomplete => break,
            .malformed => |bad| {
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
