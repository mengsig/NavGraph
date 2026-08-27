//! Drives the built `navgraph lsp` binary through one hostile session and
//! checks what came back on stdout.
//!
//! Exists because the things that most need proving cannot be proven in-process:
//! that a crash-shaped input does not kill the *process*, that the session still
//! exits with the right code afterwards, and that stdout carries frames and
//! nothing else. Run by `zig build test` and by CI against the shipped
//! ReleaseFast binary.
//!
//! Usage: `lsp-smoke <navgraph-exe> <work-dir>`

const std = @import("std");

/// Ids whose replies must carry a `result`. Each is a request sent *behind* a
/// hostile one, so answering it proves the server survived and stayed in sync.
const must_succeed = [_]i64{ 1, 11, 13, 77, 14, 15 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 3) fail("usage: lsp-smoke <navgraph-exe> <work-dir>", .{});
    const exe = argv[1];
    const root = argv[2];

    const cwd = std.Io.Dir.cwd();
    try writeFixture(cwd, io, arena, root);

    const session = try buildSession(gpa, arena, root);
    defer gpa.free(session);
    const in_path = try std.fs.path.join(arena, &.{ root, "session.lsp" });
    const out_path = try std.fs.path.join(arena, &.{ root, "session.out" });
    try cwd.writeFile(io, .{ .sub_path = in_path, .data = session });

    const term = try runServer(io, cwd, exe, root, in_path, out_path);
    if (term != .exited or term.exited != 0) {
        fail("server did not exit cleanly: {any} (session bytes in {s})", .{ term, in_path });
    }

    const out = try cwd.readFileAlloc(io, out_path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(out);
    try checkReplies(gpa, out);
    std.debug.print("lsp-smoke: ok ({d} bytes of frames)\n", .{out.len});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lsp-smoke: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn writeFixture(cwd: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, root: []const u8) !void {
    const files = [_][2][]const u8{
        .{
            "app.zig",
            \\const util = @import("util.zig");
            \\
            \\pub fn run() void {
            \\    util.helper();
            \\}
            \\
        },
        .{ "util.zig", "pub fn helper() void {}\n" },
    };
    for (files) |f| {
        const path = try std.fs.path.join(arena, &.{ root, f[0] });
        try cwd.writeFile(io, .{ .sub_path = path, .data = f[1] });
    }
}

fn runServer(
    io: std.Io,
    cwd: std.Io.Dir,
    exe: []const u8,
    root: []const u8,
    in_path: []const u8,
    out_path: []const u8,
) !std.process.Child.Term {
    // stdin and stdout are files, not pipes: a pipe could deadlock on the
    // 300 KB session, and this is exactly how an editor's stream is replayed.
    const stdin = try cwd.openFile(io, in_path, .{});
    defer stdin.close(io);
    const stdout = try cwd.createFile(io, out_path, .{});
    defer stdout.close(io);

    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "lsp", "--root", root },
        .stdin = .{ .file = stdin },
        .stdout = .{ .file = stdout },
        .stderr = .inherit,
    });
    return child.wait(io);
}

/// The session: each hostile frame is followed by a request that must still be
/// answered, so a crash, a hang or a desync all show up as a missing reply.
fn buildSession(gpa: std.mem.Allocator, arena: std.mem.Allocator, root: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );

    // F1: 20 000 nested groups used to crash the parser during parsing.
    const nested = try arena.alloc(u8, 20_000 * 2 + 1);
    @memset(nested[0..20_000], '(');
    nested[20_000] = 'a';
    @memset(nested[20_001..], ')');
    try frame(gpa, &out, try std.fmt.allocPrint(arena,
        "{{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"navgraph/grep\"," ++
            "\"params\":{{\"pattern\":\"{s}\",\"regex\":true,\"limit\":1}}}}",
        .{nested},
    ));
    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","id":11,"method":"navgraph/status","params":{}}
    );

    // F2: `a+b` over a 300k-character line — one recursion per matched byte.
    const line = try arena.alloc(u8, 300_000);
    @memset(line, 'a');
    const uri = try std.fmt.allocPrint(arena, "file://{s}/min.js", .{root});
    try frame(gpa, &out, try std.fmt.allocPrint(arena,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":" ++
            "{{\"uri\":\"{s}\",\"languageId\":\"javascript\",\"version\":1,\"text\":\"{s}\"}}}}}}",
        .{ uri, line },
    ));
    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","id":12,"method":"navgraph/grep","params":{"pattern":"a+b","regex":true,"limit":1}}
    );
    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","id":13,"method":"navgraph/status","params":{}}
    );

    // F3: one malformed header with a body used to swallow everything behind it.
    try out.appendSlice(gpa, "Content-Length: abc\r\n\r\n{}");
    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","id":77,"method":"navgraph/status","params":{}}
    );

    // F9: a result shape only the navgraph/* handlers can produce.
    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","id":14,"method":"navgraph/blast","params":{"symbol":"helper","depth":1}}
    );
    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","id":15,"method":"shutdown"}
    );
    try frame(gpa, &out,
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    return out.toOwnedSlice(gpa);
}

fn frame(gpa: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) !void {
    try out.print(gpa, "Content-Length: {d}\r\n\r\n", .{body.len});
    try out.appendSlice(gpa, body);
}

/// Walk stdout as an exact frame stream — every byte belongs to a frame and the
/// last one ends at EOF — then check what the frames said.
fn checkReplies(gpa: std.mem.Allocator, out: []const u8) !void {
    var replies: std.AutoHashMapUnmanaged(i64, std.json.Value) = .empty;
    defer replies.deinit(gpa);
    var parsed_arena = std.heap.ArenaAllocator.init(gpa);
    defer parsed_arena.deinit();
    const alloc = parsed_arena.allocator();

    var frames: u32 = 0;
    var indexed: u32 = 0;
    var at: usize = 0;
    while (at < out.len) {
        const header = "Content-Length: ";
        if (!std.mem.startsWith(u8, out[at..], header)) {
            fail("stray bytes outside a frame at offset {d}: '{s}'", .{ at, clip(out[at..]) });
        }
        at += header.len;
        const eol = std.mem.indexOfScalarPos(u8, out, at, '\r') orelse fail("unterminated header", .{});
        const len = std.fmt.parseInt(usize, out[at..eol], 10) catch
            fail("bad Content-Length '{s}'", .{clip(out[at..eol])});
        if (!std.mem.startsWith(u8, out[eol..], "\r\n\r\n")) fail("malformed header terminator", .{});
        at = eol + 4;
        if (at + len > out.len) fail("frame body runs past EOF at offset {d}", .{at});
        const body = out[at .. at + len];
        at += len;
        frames += 1;

        const value = std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{}) catch
            fail("frame {d} is not JSON: '{s}'", .{ frames, clip(body) });
        if (value != .object) fail("frame {d} is not an object", .{frames});
        if (value.object.get("method")) |m| {
            if (m == .string and std.mem.eql(u8, m.string, "navgraph/indexed")) indexed += 1;
            continue;
        }
        const id = value.object.get("id") orelse continue;
        if (id == .integer) try replies.put(gpa, id.integer, value);
    }
    if (at != out.len) fail("trailing bytes after the last frame", .{});
    if (indexed == 0) fail("no navgraph/indexed notification", .{});

    for (must_succeed) |id| {
        const reply = replies.get(id) orelse fail("id {d} was never answered", .{id});
        if (reply.object.get("error")) |e| {
            fail("id {d} failed: {any}", .{ id, e.object.get("code") });
        }
        if (reply.object.get("result") == null) fail("id {d} has no result", .{id});
    }

    // A pattern past the nesting/length cap is a params error, not a crash.
    const nested = replies.get(10) orelse fail("the nested-pattern request was never answered", .{});
    const code = (nested.object.get("error") orelse fail("id 10 should have failed", .{}))
        .object.get("code").?.integer;
    if (code != -32602) fail("nested pattern gave {d}, want -32602", .{code});

    // The long-line grep may match, may be refused as too complex; it may not
    // take the server down, and something must come back.
    _ = replies.get(12) orelse fail("the long-line grep was never answered", .{});

    // Only navgraph/blast produces this, so a regression in the navgraph/*
    // handlers cannot leave this check green.
    const blast = replies.get(14).?.object.get("result").?.object;
    const roots = blast.get("roots").?.array.items;
    if (roots.len != 1) fail("blast returned {d} roots, want 1", .{roots.len});
    const name = roots[0].object.get("name").?.string;
    if (!std.mem.eql(u8, name, "helper")) fail("blast root is '{s}', want 'helper'", .{name});
    if (blast.get("summary").?.object.get("symbols").?.integer < 2) {
        fail("blast found no caller of helper", .{});
    }
    if (blast.get("edges").?.array.items.len == 0) fail("blast found no edge", .{});
    if (replies.get(15).?.object.get("result").? != .null) fail("shutdown must return null", .{});
}

fn clip(s: []const u8) []const u8 {
    return s[0..@min(s.len, 40)];
}
