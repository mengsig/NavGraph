//! One-shot CLI/MCP mirrors of `navgraph/impact`, `navgraph/context` and
//! `navgraph/where` (`docs/lsp.md`'s 1.1 addendum).
//!
//! The LSP methods stream straight from `queries.write*` into a *resident*
//! `Session`. A one-shot `navgraph hunks/context/where` invocation or MCP tool
//! call has no resident session, so this builds a throwaway one per call —
//! the same walk `Session.init` already does, and the same one-shot cost model
//! every other `navgraph` CLI command already pays. No `openDocument` is ever
//! called, so the overlay/watch/debounce machinery `Session` also owns is
//! simply never exercised.
//!
//! This is the seam picked over the two heavier options the server already
//! has: threading a `Session` through the CLI's `*Index`-based `dispatch`
//! (main.zig), or extending `agent_api`'s ~1250-line typed operation envelope
//! with three more shapes. Both would mean either duplicating
//! `queries.writeContext`/`writeWhere`/`writeImpact`'s logic in a
//! `*Index`-shaped form, or growing an already-large decoder for three
//! Session-shaped operations it has no other reason to know about. Building a
//! `Session` here and calling the exact same `queries.write*` functions the
//! LSP server calls keeps the query logic in exactly one place.
//!
//! Known limitation: an MCP `navgraph.hunks`/`.context`/`.where` call re-walks
//! the project on every call, unlike `navgraph.query`/legacy `navgraph`, which
//! reuse `ServerSession`'s resident index. `Session` always builds its own
//! index rather than adopting an existing one, so sharing that resident index
//! here would mean carrying two synchronized indices. Not worth it unless
//! these mirrors turn out to be called often enough to matter.

const std = @import("std");
const session_mod = @import("session.zig");
const queries = @import("queries.zig");
const payload = @import("payload.zig");

/// A `Ctx` for a one-shot session, at the encoding a non-editor JSON consumer
/// (a CLI user, an MCP-calling agent) actually wants: byte columns, not the
/// UTF-16 code units a real editor's `initialize` would normally negotiate.
pub fn ctxOf(session: *session_mod.Session) payload.Ctx {
    return .{ .session = session, .encoding = .utf8 };
}

/// `navgraph hunks [ref]`: `navgraph/impact`'s exact wire shape (roots, blast
/// nodes/edges, hunks, changeId). CLI/MCP callers have no open-document
/// overlays, so `ref` is always passed non-null — an empty string still means
/// "HEAD", same as `navgraph diff`/`navgraph affected`'s own default-ref rule.
pub fn hunks(w: *std.Io.Writer, gpa: std.mem.Allocator, ctx: payload.Ctx, ref: []const u8, detail: *?[]const u8) !void {
    const cfg = ctx.session.cfg;
    try queries.writeImpact(w, gpa, ctx, ref, null, null, .{
        .depth = cfg.depth,
        .direction = .callers,
        .limit = 500,
        .scope = queries.Scope.fromConfig(cfg),
    }, detail);
}

/// `navgraph context <symbol> [--budget N] [--include LIST]`: resolve the
/// name the same way every CLI symbol argument resolves (`query.resolveIds`,
/// via `queries.resolveTarget`), then `navgraph/context`'s exact wire shape
/// for the first match — same "first match wins" convention `contextMethod`
/// uses for an ambiguous name.
pub fn context(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    ctx: payload.Ctx,
    symbol: []const u8,
    budget: u32,
    include: queries.ContextInclude,
) !void {
    var detail: ?[]const u8 = null;
    const roots = try queries.resolveTarget(gpa, ctx, .{ .symbol = symbol }, &detail);
    defer gpa.free(roots);
    try queries.writeContext(w, gpa, ctx, roots[0], .{ .budget = budget, .include = include });
}

/// `navgraph where <file>:<line>`.
pub fn where(w: *std.Io.Writer, gpa: std.mem.Allocator, ctx: payload.Ctx, path: []const u8, line: u32) !void {
    try queries.writeWhere(w, gpa, ctx, path, line);
}

/// One `<file>:<line>` positional, split on the last `:` (a repo path never
/// contains one). `null` on any shape a real location cannot have — no colon,
/// an empty path, or a non-positive/unparseable line — so the caller reports
/// one uniform "malformed location" error instead of a wrong split.
pub const FileLine = struct { path: []const u8, line: u32 };

pub fn parseFileLine(spec: []const u8) ?FileLine {
    const at = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return null;
    const path = spec[0..at];
    const line_str = spec[at + 1 ..];
    if (path.len == 0 or line_str.len == 0) return null;
    const line = std.fmt.parseInt(u32, line_str, 10) catch return null;
    if (line == 0) return null;
    return .{ .path = path, .line = line };
}

/// `--include a,b,c`: the same allow-list `handlers.includeOf` validates for
/// the wire `include` array, applied to comma-separated CLI tokens instead of
/// a JSON array — absent (the CLI never calls this) means "everything" (the
/// `ContextInclude{}` default); present, even empty, is a strict allow-list.
/// An unrecognized token is `error.InvalidParams`, same as the wire form.
pub fn parseIncludeCsv(csv: []const u8) error{InvalidParams}!queries.ContextInclude {
    var inc = queries.ContextInclude.none;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "callers")) {
            inc.callers = true;
        } else if (std.mem.eql(u8, tok, "callees")) {
            inc.callees = true;
        } else if (std.mem.eql(u8, tok, "types")) {
            inc.types = true;
        } else if (std.mem.eql(u8, tok, "tests")) {
            inc.tests = true;
        } else if (std.mem.eql(u8, tok, "body")) {
            inc.body = true;
        } else {
            return error.InvalidParams;
        }
    }
    return inc;
}

/// JSON-RPC-style numeric code for a mirror error — the same codes
/// `docs/lsp.md` documents for `navgraph/impact`/`context`/`where`, shared by
/// the CLI's format-aware error output and the MCP tools' `rpcError`.
pub fn errorCode(err: anyerror) i32 {
    return switch (err) {
        error.SymbolNotFound => -32001,
        error.GitFailed => -32002,
        error.InvalidParams, error.FileNotIndexed => -32602,
        else => -32603,
    };
}

/// A human-readable fallback message for `err`, used when the failure carries
/// no richer `detail` (git failures set one; see `hunks`' `detail` param).
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.SymbolNotFound => "symbol not found",
        error.GitFailed => "git diff failed",
        error.InvalidParams => "invalid params",
        error.FileNotIndexed => "file is not indexed",
        else => @errorName(err),
    };
}

const testing = std.testing;
const gitutil = @import("../gitutil.zig");
const Fixture = session_mod.Fixture;

const sample = [_][2][]const u8{
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

const Git = struct {
    fn ok(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) !void {
        const result = try gitutil.run(allocator, io, cwd, argv);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expect(result.term == .exited and result.term.exited == 0);
    }
};

test "hunks reports the working change against HEAD, grouped by hunk" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for (sample) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try Git.ok(testing.allocator, io, root, &.{ "git", "init", "--quiet" });
    try Git.ok(testing.allocator, io, root, &.{ "git", "add", "--", "app.zig", "util.zig" });
    try Git.ok(testing.allocator, io, root, &.{
        "git",     "-c",                   "user.name=NavGraph Test", "-c",                       "user.email=navgraph@example.invalid",
        "-c",      "commit.gpgsign=false", "-c",                      "core.hooksPath=/dev/null", "commit",
        "--quiet", "--no-verify",          "-m",                      "base",
    });
    // Edit on disk *before* the session walks it, so the index and `git diff`
    // agree on the current content (a one-shot session always reflects
    // whatever is on disk when it is built — there is no live overlay here).
    try tmp.dir.writeFile(io, .{ .sub_path = "util.zig", .data = "pub fn helper() void {\n    _ = 1;\n}\n" });

    var session = try session_mod.Session.init(testing.allocator, io, root, .{ .watch = false }, true);
    defer session.deinit();
    const ctx = ctxOf(&session);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var detail: ?[]const u8 = null;
    try hunks(&aw.writer, testing.allocator, ctx, "", &detail);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expect(obj.get("hunks").?.array.items.len == 1);
    try testing.expect(obj.get("roots").?.array.items.len == 1);
    try testing.expectEqualStrings("helper", obj.get("roots").?.array.items[0].object.get("name").?.string);
    try testing.expect(!std.mem.eql(u8, "0000000000000000", obj.get("changeId").?.string));
}

test "hunks off a bad ref is GitFailed, with the git detail attached" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    try Git.ok(testing.allocator, testing.io, fx.root, &.{ "git", "init", "--quiet" });
    const ctx = ctxOf(&fx.session);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var detail: ?[]const u8 = null;
    try testing.expectError(error.GitFailed, hunks(&aw.writer, testing.allocator, ctx, "not-a-real-ref", &detail));
    try testing.expect(detail != null);
    if (detail) |d| testing.allocator.free(d);
}

test "context returns the definition, trimmed to the given budget" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const ctx = ctxOf(&fx.session);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try context(&aw.writer, testing.allocator, ctx, "run", 2000, .{});
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("run", parsed.value.object.get("symbol").?.object.get("name").?.string);
}

test "context on an unknown symbol is SymbolNotFound" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const ctx = ctxOf(&fx.session);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expectError(error.SymbolNotFound, context(&aw.writer, testing.allocator, ctx, "nope_xyz", 2000, .{}));
}

test "context budget 0 does not error (silently reinterpreted, per the wire contract)" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const ctx = ctxOf(&fx.session);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try context(&aw.writer, testing.allocator, ctx, "run", 0, .{});
    try testing.expect(aw.written().len != 0);
}

test "where names the enclosing symbol and its breadcrumb chain" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const ctx = ctxOf(&fx.session);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try where(&aw.writer, testing.allocator, ctx, "app.zig", 3);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("run", parsed.value.object.get("enclosing").?.object.get("name").?.string);
}

test "where off a file outside the index reports null, never an error" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const ctx = ctxOf(&fx.session);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try where(&aw.writer, testing.allocator, ctx, "does/not/exist.zig", 1);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("enclosing").? == .null);
}

test "parseFileLine rejects a missing colon, a non-numeric line and line 0" {
    try testing.expect(parseFileLine("app.zig") == null);
    try testing.expect(parseFileLine("app.zig:abc") == null);
    try testing.expect(parseFileLine("app.zig:0") == null);
    try testing.expect(parseFileLine(":5") == null);
    const ok = parseFileLine("app.zig:5").?;
    try testing.expectEqualStrings("app.zig", ok.path);
    try testing.expectEqual(@as(u32, 5), ok.line);
}

test "parseIncludeCsv accepts the documented tokens and rejects an unknown one" {
    const inc = try parseIncludeCsv("callers,types");
    try testing.expect(inc.callers);
    try testing.expect(inc.types);
    try testing.expect(!inc.callees);
    try testing.expect(!inc.tests);
    try testing.expect(!inc.body);
    try testing.expectError(error.InvalidParams, parseIncludeCsv("bogus"));
    // Explicitly empty is a strict "nothing" allow-list, not "everything".
    const empty = try parseIncludeCsv("");
    try testing.expect(!empty.callers and !empty.callees and !empty.types and !empty.tests and !empty.body);
}
