//! Method dispatch: the standard LSP subset plus the `navgraph/*` methods.
//!
//! One request in, one framed response out. Every handler renders its result
//! into a per-request arena and returns; the dispatcher wraps that in the
//! JSON-RPC envelope, so no handler can produce a half-written frame or write
//! to stdout by accident.
//!
//! Handlers that read the graph run `flushPending` first, so a request that
//! arrives during the debounce window sees the edits, never a stale graph.

const std = @import("std");
const capabilities = @import("../capabilities.zig");
const impls = @import("../impls.zig");
const model = @import("../model.zig");
const query = @import("../query.zig");
const overlay = @import("overlay.zig");
const payload = @import("payload.zig");
const position = @import("position.zig");
const queries = @import("queries.zig");
const regex = @import("regex.zig");
const rpc = @import("rpc.zig");
const search = @import("search.zig");
const backends = @import("../backends.zig");
const session_mod = @import("session.zig");

const Writer = std.Io.Writer;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

pub const protocol_version = 1;
/// `navgraph/status.protocolMinor`: the addendum level. Bump on every additive
/// v1.x addendum; `protocol_version` itself stays 1 (breaking changes only).
pub const protocol_minor = 1;
/// Reported in `initialize`'s serverInfo and `navgraph/status`. One source of
/// truth with `navgraph capabilities`.
pub const version = capabilities.product_version;

pub const LogLevel = enum {
    err,
    info,
    debug,

    pub fn parse(s: []const u8) ?LogLevel {
        if (std.mem.eql(u8, s, "error")) return .err;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        return null;
    }
};

/// Diagnostics sink. Never stdout — that channel carries the protocol.
pub const Log = struct {
    writer: ?*Writer,
    level: LogLevel,

    pub fn print(self: *Log, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) > @intFromEnum(self.level)) return;
        const w = self.writer orelse return;
        w.print("navgraph-lsp [{s}] " ++ fmt ++ "\n", .{@tagName(level)} ++ args) catch return;
        w.flush() catch {};
    }
};

/// What a handler may fail with. Deliberately open: a handler reaches the
/// filesystem, the allocator, git and the JSON parser, and the protocol requires
/// that *any* of those failures becomes a JSON-RPC error rather than killing the
/// server. `mapError` names the ones the contract specifies; everything else is
/// an internal error.
pub const Error = anyerror;

/// A handler renders the JSON-RPC `result` value into `w`.
const Handler = *const fn (*Server, std.mem.Allocator, ?std.json.Value, *Writer) Error!void;
const Notifier = *const fn (*Server, std.mem.Allocator, ?std.json.Value) Error!void;
const Entry = struct { name: []const u8, run: Handler };
const NotifEntry = struct { name: []const u8, run: Notifier };

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The framed protocol channel.
    out: *Writer,
    log: Log,
    /// `--root` from the command line; empty means "take it from initialize".
    cli_root: []const u8,
    /// The resolved index root, owned by the server.
    root: []u8,
    /// `--backend`; the session compiles its grammars for this once.
    backend: backends.Choice,
    cfg: session_mod.Config,
    encoding: position.Encoding,
    session: ?session_mod.Session,
    client_progress: bool,
    shutdown_requested: bool,
    /// Set when `exit` was received; the run loop stops and returns this code.
    exit_code: ?u8,
    /// A handler that fails with a cause richer than its error name (an OS
    /// error, a git message) sets this before returning; `sendError` reads it
    /// in place of the generic `mapError` message, then clears it. Arena-owned
    /// by the same request, so it never outlives the response it describes.
    err_detail: ?[]const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, out: *Writer, log: Log, cli_root: []const u8, backend: backends.Choice) Server {
        return .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .log = log,
            .cli_root = cli_root,
            .root = &.{},
            .backend = backend,
            .cfg = .{},
            .encoding = .utf16,
            .session = null,
            .client_progress = false,
            .err_detail = null,
            .shutdown_requested = false,
            .exit_code = null,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.session) |*s| s.deinit();
        self.gpa.free(self.root);
    }

    pub fn ctx(self: *Server) Error!payload.Ctx {
        const s = &(self.session orelse return error.NotInitialized);
        return .{ .session = s, .encoding = self.encoding };
    }

    // -----------------------------------------------------------------------
    // Dispatch
    // -----------------------------------------------------------------------

    /// Handle one decoded message. Returns only IO/allocation failures; a bad
    /// request is answered with a JSON-RPC error, not propagated.
    pub fn dispatch(self: *Server, arena: std.mem.Allocator, msg: rpc.Message) !void {
        if (msg.id == .none) return self.dispatchNotification(arena, msg);

        var body: Writer.Allocating = .init(arena);
        defer body.deinit();
        var result: Writer.Allocating = .init(arena);
        defer result.deinit();

        for (requests) |entry| {
            if (!std.mem.eql(u8, entry.name, msg.method)) continue;
            entry.run(self, arena, msg.params, &result.writer) catch |err| {
                return self.sendError(arena, msg.id, msg.method, err);
            };
            try rpc.writeResult(&body.writer, msg.id, result.written());
            return self.send(body.written());
        }
        self.log.print(.info, "unknown method {s}", .{msg.method});
        try rpc.writeError(&body.writer, msg.id, .method_not_found, msg.method, null);
        try self.send(body.written());
    }

    fn dispatchNotification(self: *Server, arena: std.mem.Allocator, msg: rpc.Message) !void {
        for (notifications) |entry| {
            if (!std.mem.eql(u8, entry.name, msg.method)) continue;
            entry.run(self, arena, msg.params) catch |err| {
                // A notification has no reply, so a failure is only visible in
                // the log; never let it stop the server.
                self.log.print(.err, "{s} failed: {s}", .{ msg.method, @errorName(err) });
            };
            return;
        }
        self.log.print(.debug, "ignored notification {s}", .{msg.method});
    }

    fn sendError(self: *Server, arena: std.mem.Allocator, id: rpc.Id, method: []const u8, err: anyerror) !void {
        const mapped = mapError(err);
        const detail = self.err_detail;
        self.err_detail = null;
        var msg: Writer.Allocating = .init(arena);
        defer msg.deinit();
        try msg.writer.print("{s}: {s}", .{ method, detail orelse mapped.message });
        var body: Writer.Allocating = .init(arena);
        defer body.deinit();
        try rpc.writeError(&body.writer, id, mapped.code, msg.written(), null);
        self.log.print(.info, "{s} -> {s}", .{ method, @errorName(err) });
        try self.send(body.written());
    }

    pub fn send(self: *Server, body: []const u8) !void {
        try rpc.writeFrame(self.out, body);
        try self.out.flush();
    }

    pub fn notify(self: *Server, arena: std.mem.Allocator, method: []const u8, params_json: []const u8) !void {
        var body: Writer.Allocating = .init(arena);
        defer body.deinit();
        try rpc.writeNotification(&body.writer, method, params_json);
        try self.send(body.written());
    }

    // -----------------------------------------------------------------------
    // Indexing hooks used by the run loop
    // -----------------------------------------------------------------------

    /// Re-index queued edits, if any, and announce the result.
    pub fn flushPending(self: *Server, arena: std.mem.Allocator, reason: session_mod.Reason) !void {
        const s = &(self.session orelse return);
        const report = (try s.reindex(reason)) orelse return;
        try self.announce(arena, report);
    }

    pub fn announce(self: *Server, arena: std.mem.Allocator, report: session_mod.Report) !void {
        var params: Writer.Allocating = .init(arena);
        defer params.deinit();
        try writeIndexedParams(&params.writer, report);
        try self.notify(arena, "navgraph/indexed", params.written());
    }
};

fn writeIndexedParams(w: *Writer, report: session_mod.Report) !void {
    try w.print("{{\"reason\":\"{s}\",\"files\":{d},\"symbols\":{d},\"edges\":{d},\"ms\":{d},\"changedFiles\":[", .{
        report.reason.tag(), report.files, report.symbols, report.edges, report.ms,
    });
    for (report.changed, 0..) |path, i| {
        if (i != 0) try w.writeByte(',');
        try payload.writeString(w, path);
    }
    try w.writeAll("]}");
}

const MappedError = struct { code: rpc.ErrorCode, message: []const u8 };

fn mapError(err: anyerror) MappedError {
    return switch (err) {
        error.InvalidParams => .{ .code = .invalid_params, .message = "invalid params" },
        error.MethodNotFound => .{ .code = .method_not_found, .message = "unknown method" },
        error.SymbolNotFound => .{ .code = .symbol_not_found, .message = "symbol not found" },
        error.FileNotIndexed => .{ .code = .invalid_params, .message = "file is not indexed" },
        error.BadPattern => .{ .code = .invalid_params, .message = "invalid pattern" },
        error.RegexTooComplex => .{ .code = .request_failed, .message = "regex too complex" },
        error.GitFailed => .{ .code = .request_failed, .message = "git diff failed" },
        error.WriteFailed => .{ .code = .internal_error, .message = "internal error" },
        error.NotInitialized => .{ .code = .invalid_request, .message = "server not initialized" },
        error.OutOfMemory => .{ .code = .internal_error, .message = "out of memory" },
        else => .{ .code = .internal_error, .message = "internal error" },
    };
}

// ---------------------------------------------------------------------------
// Params helpers
// ---------------------------------------------------------------------------

const Params = struct {
    obj: ?std.json.ObjectMap,

    fn from(v: ?std.json.Value) Params {
        const val = v orelse return .{ .obj = null };
        return .{ .obj = if (val == .object) val.object else null };
    }

    fn get(self: Params, key: []const u8) ?std.json.Value {
        const o = self.obj orelse return null;
        return o.get(key);
    }

    fn str(self: Params, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// Absent or wrong-typed -> `fallback` (matches every existing caller's
    /// "optional, defaulted" contract). Present as a number but hostile
    /// (NaN, infinite, or outside `i64`) -> `InvalidParams`, never a crash and
    /// never a silently-truncated/wrapped value (coldstart F1: `@intFromFloat`
    /// on an out-of-range float is illegal behavior — UB in ReleaseFast,
    /// SIGABRT in Debug).
    fn int(self: Params, key: []const u8, fallback: i64) Error!i64 {
        const v = self.get(key) orelse return fallback;
        return switch (v) {
            .integer => |n| n,
            .float => |f| blk: {
                if (!std.math.isFinite(f)) return error.InvalidParams;
                // i64's exact range as f64: -2^63 is exact; 2^63 is the first
                // power-of-two a truncated float could hit that no longer fits.
                if (f < -9223372036854775808.0 or f >= 9223372036854775808.0) return error.InvalidParams;
                break :blk @intFromFloat(f);
            },
            else => fallback,
        };
    }

    fn boolean(self: Params, key: []const u8, fallback: bool) bool {
        const v = self.get(key) orelse return fallback;
        return if (v == .bool) v.bool else fallback;
    }

    fn nested(self: Params, key: []const u8) Params {
        return Params.from(self.get(key));
    }

    fn strings(self: Params, gpa: std.mem.Allocator, key: []const u8) ![]const []const u8 {
        const v = self.get(key) orelse return &.{};
        if (v != .array) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        for (v.array.items) |item| {
            if (item == .string) try out.append(gpa, item.string);
        }
        return out.toOwnedSlice(gpa);
    }

    /// A non-positive value (absent, `0`, or negative) means "use the
    /// default" (established 1.0 convention, coldstart F8 documents the
    /// tradeoff). A value too large for `u32` is hostile, not a sentinel for
    /// "unbounded" -> `InvalidParams` rather than the silent-wraparound
    /// `@intCast` this replaces (coldstart F1).
    fn positive(self: Params, key: []const u8, fallback: u32) Error!u32 {
        const n = try self.int(key, fallback);
        if (n <= 0) return fallback;
        if (n > std.math.maxInt(u32)) return error.InvalidParams;
        return @intCast(n);
    }
};

/// Root-relative path for a document URI, or null when it lies outside the root.
fn pathOf(self: *Server, gpa: std.mem.Allocator, uri: []const u8) Error!?[]const u8 {
    const s = &(self.session orelse return error.NotInitialized);
    const abs = overlay.pathFromUri(gpa, uri) catch return error.InvalidParams;
    return overlay.relativeTo(s.root_abs, abs) orelse null;
}

/// `textDocument.uri` from a request's params.
fn documentPath(self: *Server, gpa: std.mem.Allocator, p: Params) Error!?[]const u8 {
    const uri = p.nested("textDocument").str("uri") orelse p.str("uri") orelse return error.InvalidParams;
    return pathOf(self, gpa, uri);
}

/// `i64` -> `u32`, rejecting negative and out-of-range instead of the
/// clamp-to-zero / trapping `@intCast` this replaces (coldstart F1: a hostile
/// `position.line`/`range.*.line` of e.g. `5000000000` doesn't fit `u32` and
/// used to abort the process).
fn toU32(n: i64) Error!u32 {
    if (n < 0 or n > std.math.maxInt(u32)) return error.InvalidParams;
    return @intCast(n);
}

/// 0-based `n` -> 1-based `u32`, checked so the `+ 1` itself cannot overflow
/// (coldstart F1: `@max(n, 0) + 1` on `n == maxInt(i64)` trapped).
fn oneBasedLine(n: i64) Error!u32 {
    if (n < 0 or n >= std.math.maxInt(u32)) return error.InvalidParams;
    return @as(u32, @intCast(n)) + 1;
}

fn positionOf(p: Params) Error!position.Position {
    const pos = p.nested("position");
    if (pos.obj == null) return error.InvalidParams;
    return .{
        .line = try toU32(try pos.int("line", 0)),
        .character = try toU32(try pos.int("character", 0)),
    };
}

/// `Scope` is `{ strict?:bool, tests?:string }` at the *top level* of
/// `params` (`docs/lsp.md`'s `& Scope` intersection), not nested under a
/// `scope` key — a client sending `{"scope":{"tests":"only"}}` gets its
/// filter silently ignored otherwise, since an unrecognized key is dropped.
/// Reject that shape outright instead (coldstart review F10).
fn scopeOf(self: *Server, p: Params) Error!queries.Scope {
    if (p.get("scope")) |v| {
        if (v == .object) return error.InvalidParams;
    }
    var scope = queries.Scope.fromConfig(self.cfg);
    scope.strict = p.boolean("strict", scope.strict);
    // An unknown scope is rejected, not dropped: answering the default question
    // instead of the one asked is worse than erroring.
    if (p.str("tests")) |t| scope.tests = query.TestScope.parse(t) orelse return error.InvalidParams;
    return scope;
}

/// Byte offset of a `{ uri, position }` pair in the indexed text.
fn offsetOf(self: *Server, gpa: std.mem.Allocator, p: Params) Error!?struct { path: []const u8, offset: usize } {
    const path = (try documentPath(self, gpa, p)) orelse return null;
    const s = &(self.session orelse return error.NotInitialized);
    const text = s.textOf(path) orelse return null;
    return .{ .path = path, .offset = position.offsetAt(text, try positionOf(p), self.encoding) };
}

/// The contract's `Target`, in any of its four forms.
fn targetOf(self: *Server, gpa: std.mem.Allocator, p: Params) Error!queries.Target {
    if (p.str("symbol")) |name| return .{ .symbol = name };
    if (p.str("file")) |file| return .{ .file = file };
    if (p.str("ref")) |ref| return .{ .git_ref = ref };
    const at = (try offsetOf(self, gpa, p)) orelse return error.InvalidParams;
    return .{ .at = .{ .path = at.path, .offset = at.offset } };
}

/// `queries.resolveTarget`, recording a git failure's detail on `self` so
/// `sendError` can surface it (a `{ref}` target shares `navgraph/diff`'s F2
/// fix: a git error must not look like "nothing changed" or "not found").
fn resolveTargetOrErr(self: *Server, arena: std.mem.Allocator, c: payload.Ctx, target: queries.Target) Error![]SymbolId {
    var detail: ?[]const u8 = null;
    return queries.resolveTarget(arena, c, target, &detail) catch |err| {
        self.err_detail = detail;
        return err;
    };
}

// ---------------------------------------------------------------------------
// Standard LSP
// ---------------------------------------------------------------------------

fn initialize(self: *Server, gpa: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    const p = Params.from(params);
    try applyInitOptions(self, p.nested("initializationOptions"));

    const caps = p.nested("capabilities");
    self.encoding = negotiateEncoding(caps);
    self.client_progress = caps.nested("window").boolean("workDoneProgress", false);

    const root = try resolveRoot(self, gpa, p);
    self.gpa.free(self.root);
    self.root = root;

    try w.print(
        "{{\"capabilities\":{{\"positionEncoding\":\"{s}\"," ++
            "\"textDocumentSync\":{{\"openClose\":true,\"change\":1,\"save\":{{\"includeText\":false}}}}," ++
            "\"definitionProvider\":true,\"referencesProvider\":true,\"hoverProvider\":true," ++
            "\"documentSymbolProvider\":true,\"workspaceSymbolProvider\":true," ++
            "\"callHierarchyProvider\":true,\"typeHierarchyProvider\":true," ++
            "\"implementationProvider\":true,\"typeDefinitionProvider\":true," ++
            "\"documentHighlightProvider\":true,\"codeLensProvider\":{{\"resolveProvider\":true}}," ++
            "\"experimental\":{{\"navgraph\":{{\"protocolVersion\":{d},\"methods\":[",
        .{ self.encoding.name(), protocol_version },
    );
    try writeNameList(w, &navgraph_methods);
    try w.writeAll("],\"notifications\":[");
    try writeNameList(w, &navgraph_notifications);
    try w.print("]}}}}}},\"serverInfo\":{{\"name\":\"navgraph\",\"version\":\"{s}\"}}}}", .{version});
}

fn writeNameList(w: *Writer, names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        if (i != 0) try w.writeByte(',');
        try payload.writeString(w, name);
    }
}

fn negotiateEncoding(caps: Params) position.Encoding {
    const list = caps.nested("general").get("positionEncodings") orelse return .utf16;
    if (list != .array) return .utf16;
    for (list.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, "utf-8")) return .utf8;
    }
    return .utf16;
}

fn applyInitOptions(self: *Server, opts: Params) Error!void {
    if (opts.str("tests")) |t| {
        self.cfg.tests = query.TestScope.parse(t) orelse return error.InvalidParams;
    }
    self.cfg.strict = opts.boolean("strict", self.cfg.strict);
    self.cfg.debounce_ms = try opts.positive("debounceMs", self.cfg.debounce_ms);
    self.cfg.watch = opts.boolean("watch", self.cfg.watch);
    self.cfg.watch_interval_ms = try opts.positive("watchIntervalMs", self.cfg.watch_interval_ms);
    self.cfg.depth = @min(try opts.positive("depth", self.cfg.depth), session_mod.Config.max_depth);
}

/// `--root` wins; then the client's workspace; then the current directory.
fn resolveRoot(self: *Server, gpa: std.mem.Allocator, p: Params) Error![]u8 {
    if (self.cli_root.len != 0) return self.gpa.dupe(u8, self.cli_root);
    const uri = p.str("rootUri") orelse workspaceFolderUri(p);
    if (uri) |u| {
        if (overlay.pathFromUri(gpa, u)) |abs| return self.gpa.dupe(u8, abs) else |_| {}
    }
    if (p.str("rootPath")) |path| return self.gpa.dupe(u8, path);
    return self.gpa.dupe(u8, ".");
}

fn workspaceFolderUri(p: Params) ?[]const u8 {
    const folders = p.get("workspaceFolders") orelse return null;
    if (folders != .array or folders.array.items.len == 0) return null;
    const first = folders.array.items[0];
    if (first != .object) return null;
    const uri = first.object.get("uri") orelse return null;
    return if (uri == .string) uri.string else null;
}

fn initialized(self: *Server, arena: std.mem.Allocator, _: ?std.json.Value) Error!void {
    if (self.session != null) return;
    const token = "navgraph/index";
    if (self.client_progress) {
        try self.send(try progressCreate(arena, token));
        try self.notify(arena, "$/progress", try progressBegin(arena, token));
    }
    self.session = session_mod.Session.init(self.gpa, self.io, self.root, self.cfg, self.backend) catch |err| {
        self.log.print(.err, "indexing {s} failed: {s}", .{ self.root, @errorName(err) });
        if (self.client_progress) try self.notify(arena, "$/progress", try progressEnd(arena, token, "index failed"));
        try self.notify(arena, "window/logMessage", try logMessageParams(arena, 1, "navgraph: indexing failed"));
        return;
    };
    const s = &self.session.?;
    if (self.client_progress) try self.notify(arena, "$/progress", try progressEnd(arena, token, "indexed"));
    try self.announce(arena, .{
        .reason = .initial,
        .files = s.fileCount(),
        .symbols = s.symbolCount(),
        .edges = s.edgeCount(),
        .ms = s.last_index_ms,
        .changed = &.{},
    });
    self.log.print(.info, "indexed {d} files, {d} symbols", .{ s.fileCount(), s.symbolCount() });
}

fn progressCreate(arena: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"navgraph-progress\",\"method\":\"window/workDoneProgress/create\"," ++
            "\"params\":{{\"token\":\"{s}\"}}}}",
        .{token},
    );
}

fn progressBegin(arena: std.mem.Allocator, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"token\":\"{s}\",\"value\":{{\"kind\":\"begin\",\"title\":\"navgraph: indexing\"}}}}",
        .{token},
    );
}

fn progressEnd(arena: std.mem.Allocator, token: []const u8, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"token\":\"{s}\",\"value\":{{\"kind\":\"end\",\"message\":\"{s}\"}}}}",
        .{ token, message },
    );
}

fn logMessageParams(arena: std.mem.Allocator, level: u8, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"type\":{d},\"message\":\"{s}\"}}", .{ level, message });
}

fn shutdown(self: *Server, _: std.mem.Allocator, _: ?std.json.Value, w: *Writer) Error!void {
    self.shutdown_requested = true;
    try w.writeAll("null");
}

fn exitNotification(self: *Server, _: std.mem.Allocator, _: ?std.json.Value) Error!void {
    self.exit_code = if (self.shutdown_requested) 0 else 1;
}

fn ignore(_: *Server, _: std.mem.Allocator, _: ?std.json.Value) Error!void {}

// ---------------------------------------------------------------------------
// Document synchronization
// ---------------------------------------------------------------------------

fn didOpen(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value) Error!void {
    const s = &(self.session orelse return error.NotInitialized);
    const p = Params.from(params);
    const doc = p.nested("textDocument");
    const path = (try documentPath(self, arena, p)) orelse return;
    const text = doc.str("text") orelse return error.InvalidParams;
    try s.openDocument(path, text);
}

fn didChange(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value) Error!void {
    const s = &(self.session orelse return error.NotInitialized);
    const p = Params.from(params);
    const path = (try documentPath(self, arena, p)) orelse return;
    const changes = p.get("contentChanges") orelse return error.InvalidParams;
    if (changes != .array or changes.array.items.len == 0) return error.InvalidParams;
    // Full sync: the last change carries the whole document.
    const last = changes.array.items[changes.array.items.len - 1];
    if (last != .object) return error.InvalidParams;
    const text = last.object.get("text") orelse return error.InvalidParams;
    if (text != .string) return error.InvalidParams;
    try s.openDocument(path, text.string);
}

fn didSave(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value) Error!void {
    const s = &(self.session orelse return error.NotInitialized);
    const path = (try documentPath(self, arena, Params.from(params))) orelse return;
    try s.markDirty(path);
    try self.flushPending(arena, .save);
}

fn didClose(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value) Error!void {
    const s = &(self.session orelse return error.NotInitialized);
    const path = (try documentPath(self, arena, Params.from(params))) orelse return;
    try s.closeDocument(path);
}

fn didChangeWatchedFiles(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value) Error!void {
    const s = &(self.session orelse return error.NotInitialized);
    const changes = Params.from(params).get("changes") orelse return error.InvalidParams;
    if (changes != .array) return error.InvalidParams;
    for (changes.array.items) |item| {
        if (item != .object) continue;
        const uri = item.object.get("uri") orelse continue;
        if (uri != .string) continue;
        const path = (try pathOf(self, arena, uri.string)) orelse continue;
        try s.markDirty(path);
    }
    try self.flushPending(arena, .watch);
}

// ---------------------------------------------------------------------------
// Language features
// ---------------------------------------------------------------------------

fn definition(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const at = (try offsetOf(self, arena, Params.from(params))) orelse return w.writeAll("[]");
    const located = (try queries.locate(arena, c, at.path, at.offset)) orelse return w.writeAll("[]");

    try w.writeByte('[');
    var wrote: u32 = 0;
    if (located.symbol != invalid) {
        try payload.writeSymbolLocation(w, c, c.index().graph.symbols[located.symbol]);
        wrote += 1;
    }
    // Same-name definitions the graph could not choose between are still
    // candidates the editor should offer.
    for (located.candidates) |id| {
        if (wrote != 0) try w.writeByte(',');
        try payload.writeSymbolLocation(w, c, c.index().graph.symbols[id]);
        wrote += 1;
    }
    try w.writeByte(']');
}

fn references(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const at = (try offsetOf(self, arena, p)) orelse return w.writeAll("[]");
    const located = (try queries.locate(arena, c, at.path, at.offset)) orelse return w.writeAll("[]");
    if (located.symbol == invalid) return w.writeAll("[]");
    const include_decl = p.nested("context").boolean("includeDeclaration", false);
    try writeReferenceLocations(w, c, located.symbol, include_decl);
}

fn writeReferenceLocations(
    w: *Writer,
    c: payload.Ctx,
    id: SymbolId,
    include_declaration: bool,
) !void {
    const idx = c.index();
    const target = idx.graph.symbols[id];
    // `query.callSiteLines` grows and frees this with the index's own allocator.
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(idx.gpa);

    try w.writeByte('[');
    var wrote: u32 = 0;
    if (include_declaration) {
        try payload.writeSymbolLocation(w, c, target);
        wrote += 1;
    }
    for (idx.callersOf(id)) |cid| {
        try query.callSiteLines(idx, cid, id, &lines);
        const file = idx.graph.files[idx.graph.symbols[cid].file];
        for (lines.items) |line| {
            if (wrote != 0) try w.writeByte(',');
            try payload.writeLocation(w, c, file, line, target.name);
            wrote += 1;
        }
    }
    try w.writeByte(']');
}

fn hover(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const at = (try offsetOf(self, arena, Params.from(params))) orelse return w.writeAll("null");
    const located = (try queries.locate(arena, c, at.path, at.offset)) orelse return w.writeAll("null");
    if (located.symbol == invalid) return w.writeAll("null");

    var md: Writer.Allocating = .init(arena);
    defer md.deinit();
    try queries.writeHoverMarkdown(&md.writer, c, c.index().graph.symbols[located.symbol]);
    try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":");
    try payload.writeString(w, md.written());
    try w.writeAll("}}");
}

fn documentSymbol(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const path = (try documentPath(self, arena, Params.from(params))) orelse return w.writeAll("[]");
    const file_id = queries.fileIdOf(c.index(), path) orelse return w.writeAll("[]");
    try queries.writeDocumentSymbols(w, c, c.index().graph.files[file_id]);
}

fn workspaceSymbol(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const q = p.str("query") orelse "";
    var hits: std.ArrayList(search.Hit) = .empty;
    defer hits.deinit(arena);
    try search.searchSymbols(arena, c.index(), q, .{ .tests = self.cfg.tests }, &hits);

    const limit = try p.positive("limit", 200);
    try w.writeByte('[');
    for (hits.items[0..@min(hits.items.len, limit)], 0..) |hit, i| {
        if (i != 0) try w.writeByte(',');
        const sym = c.index().graph.symbols[hit.id];
        try w.writeAll("{\"name\":");
        try payload.writeString(w, sym.name);
        try w.print(",\"kind\":{d},\"location\":", .{queries.lspSymbolKind(sym.kind)});
        try payload.writeSymbolLocation(w, c, sym);
        if (sym.parent != invalid) {
            try w.writeAll(",\"containerName\":");
            try payload.writeString(w, c.index().graph.symbols[sym.parent].name);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

// ---------------------------------------------------------------------------
// Call hierarchy / type hierarchy
// ---------------------------------------------------------------------------

fn prepareCallHierarchy(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const at = (try offsetOf(self, arena, Params.from(params))) orelse return w.writeAll("[]");
    const located = (try queries.locate(arena, c, at.path, at.offset)) orelse return w.writeAll("[]");
    try queries.writePrepareHierarchy(w, c, located.symbol);
}

fn prepareTypeHierarchy(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const at = (try offsetOf(self, arena, Params.from(params))) orelse return w.writeAll("[]");
    const located = (try queries.locate(arena, c, at.path, at.offset)) orelse return w.writeAll("[]");
    // Only a container has supertypes/subtypes; a non-container resolves to
    // nothing rather than an empty-but-misleading hierarchy item.
    const id = located.symbol;
    if (id == invalid or !impls.isContainer(c.index().graph.symbols[id])) return w.writeAll("[]");
    try queries.writePrepareHierarchy(w, c, id);
}

/// The item `id` an `incomingCalls`/`outgoingCalls`/`supertypes`/`subtypes`
/// request names via its `item.data` (re-resolved by `qualified`+`file`, not
/// the possibly-stale `id` — see `queries.resolveHierarchyItemData`).
fn hierarchyItemId(c: payload.Ctx, p: Params) Error!SymbolId {
    const data = p.nested("item").nested("data");
    const qualified = data.str("qualified") orelse return error.InvalidParams;
    const file = data.str("file") orelse return error.InvalidParams;
    return queries.resolveHierarchyItemData(c.index(), qualified, file) orelse error.SymbolNotFound;
}

fn incomingCalls(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const id = try hierarchyItemId(c, p);
    try queries.writeIncomingCalls(w, arena, c, id, try scopeOf(self, p));
}

fn outgoingCalls(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const id = try hierarchyItemId(c, p);
    try queries.writeOutgoingCalls(w, arena, c, id, try scopeOf(self, p));
}

fn typeSupertypes(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const id = try hierarchyItemId(c, p);
    try queries.writeTypeRelatives(w, arena, c, id, true, try scopeOf(self, p));
}

fn typeSubtypes(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const id = try hierarchyItemId(c, p);
    try queries.writeTypeRelatives(w, arena, c, id, false, try scopeOf(self, p));
}

// ---------------------------------------------------------------------------
// implementation / typeDefinition / documentHighlight / codeLens
// ---------------------------------------------------------------------------

fn implementation(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const at = (try offsetOf(self, arena, p)) orelse return w.writeAll("[]");
    const located = (try queries.locate(arena, c, at.path, at.offset)) orelse return w.writeAll("[]");
    if (located.symbol == invalid) return w.writeAll("[]");
    try queries.writeImplementation(w, arena, c, located.symbol, try scopeOf(self, p));
}

fn typeDefinition(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const at = (try offsetOf(self, arena, Params.from(params))) orelse return w.writeAll("[]");
    try queries.writeTypeDefinition(w, c, at.path, at.offset);
}

fn documentHighlight(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const at = (try offsetOf(self, arena, Params.from(params))) orelse return w.writeAll("[]");
    try queries.writeDocumentHighlight(w, arena, c, at.path, at.offset);
}

fn codeLens(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const path = (try documentPath(self, arena, Params.from(params))) orelse return w.writeAll("[]");
    const file_id = queries.fileIdOf(c.index(), path) orelse return w.writeAll("[]");
    try queries.writeCodeLens(w, c, c.index().graph.files[file_id]);
}

/// A no-op: `codeLens` already populates `command` eagerly, so resolving a
/// lens is the identity function. Exists only to satisfy `resolveProvider`.
fn codeLensResolve(_: *Server, _: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    const value = params orelse return error.InvalidParams;
    try std.json.Stringify.value(value, .{}, w);
}

// ---------------------------------------------------------------------------
// navgraph/*
// ---------------------------------------------------------------------------

fn status(self: *Server, arena: std.mem.Allocator, _: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    try writeStatus(w, try self.ctx());
}

fn writeStatus(w: *Writer, c: payload.Ctx) !void {
    const s = c.session;
    const idx = c.index();
    try w.writeAll("{\"root\":");
    try payload.writeString(w, s.root_abs);
    try w.print(",\"protocolVersion\":{d},\"protocolMinor\":{d},\"version\":\"{s}\",\"files\":{d},\"symbols\":{d},\"edges\":{d},\"languages\":{{", .{
        protocol_version, protocol_minor, version, s.fileCount(), s.symbolCount(), s.edgeCount(),
    });
    var counts: std.EnumArray(@import("../language.zig").Language, u32) = .initFill(0);
    for (idx.graph.files) |f| counts.set(f.language, counts.get(f.language) + 1);
    var first = true;
    var it = counts.iterator();
    while (it.next()) |e| {
        if (e.value.* == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\":{d}", .{ e.key.tag(), e.value.* });
    }
    try w.writeAll("},\"backend\":{\"default\":\"auto\",\"languages\":{");
    // No tree-sitter backend ships in this repo (the seam lives behind
    // `index.ReparseHint`, PR #9) — every present language is "heuristic".
    first = true;
    var bit = counts.iterator();
    while (bit.next()) |e| {
        if (e.value.* == 0) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\":\"heuristic\"", .{e.key.tag()});
    }
    try w.print("}}}},\"overlays\":{d},\"indexedAt\":\"", .{s.overlays.count()});
    try writeIso8601(w, s.indexed_at_unix_ms);
    try w.print("\",\"lastIndexMs\":{d},\"cache\":{}}}", .{ s.last_index_ms, s.used_cache });
}

fn writeIso8601(w: *Writer, unix_ms: i64) !void {
    const secs: u64 = @intCast(@max(@divFloor(unix_ms, 1000), 0));
    const day: std.time.epoch.EpochDay = .{ .day = @intCast(secs / std.time.epoch.secs_per_day) };
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const in_day: u32 = @intCast(secs % std.time.epoch.secs_per_day);
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        in_day / 3600,
        (in_day % 3600) / 60,
        in_day % 60,
        @as(u32, @intCast(@mod(unix_ms, 1000))),
    });
}

fn symbolAt(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const at = (try offsetOf(self, arena, Params.from(params))) orelse return error.InvalidParams;
    const located = (try queries.locate(arena, c, at.path, at.offset)) orelse {
        return w.writeAll("{\"word\":\"\",\"symbol\":null,\"enclosing\":null,\"candidates\":[],\"range\":null,\"breadcrumbs\":[]}");
    };
    const file_id = queries.fileIdOf(c.index(), at.path).?; // `locate` already resolved this path.
    const file = c.index().graph.files[file_id];
    try w.writeAll("{\"word\":");
    try payload.writeString(w, located.word);
    try w.writeAll(",\"symbol\":");
    try writeSymbolOrNull(w, c, located.symbol);
    try w.writeAll(",\"enclosing\":");
    try writeSymbolOrNull(w, c, located.enclosing);
    try w.writeAll(",\"candidates\":");
    try payload.writeSymbolArray(w, c, located.candidates);
    try w.writeAll(",\"range\":");
    try payload.writeByteRange(w, file.text, located.start, located.end, c.encoding);
    try w.writeAll(",\"breadcrumbs\":");
    try payload.writeSymbolArray(w, c, try queries.breadcrumbChain(c.index(), arena, located.enclosing));
    try w.writeByte('}');
}

fn writeSymbolOrNull(w: *Writer, c: payload.Ctx, id: SymbolId) !void {
    if (id == invalid) return w.writeAll("null");
    try payload.writeSymbolId(w, c, id);
}

fn blast(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const target = try targetOf(self, arena, p);
    const roots = try resolveTargetOrErr(self, arena, c, target);
    try queries.writeBlast(w, arena, c, roots, .{
        .depth = @min(try p.positive("depth", self.cfg.depth), session_mod.Config.max_depth),
        .direction = try directionOf(p, .callers),
        .limit = try p.positive("limit", 500),
        .scope = try scopeOf(self, p),
    });
}

fn directionOf(p: Params, fallback: queries.Direction) Error!queries.Direction {
    const d = p.str("direction") orelse return fallback;
    if (std.mem.eql(u8, d, "callers")) return .callers;
    if (std.mem.eql(u8, d, "callees")) return .callees;
    return error.InvalidParams;
}

/// `navgraph/tests`: `query.coverage`'s forward walk from every test,
/// inverted and rooted at one target. `Scope` is accepted for the contract's
/// `Target & Scope` shape but unused: the result already IS a test list, so
/// `scope.tests` has no meaningful filter, and the walk mirrors
/// `query.testReachable`'s own always-exact edge criterion (no strict knob).
fn testsMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    _ = try scopeOf(self, p);
    const target = try targetOf(self, arena, p);
    const roots = try resolveTargetOrErr(self, arena, c, target);
    try queries.writeTestsFor(w, arena, c, roots[0], .{ .limit = try p.positive("limit", 200) });
}

/// `navgraph/types`: "who uses type T" — supertypes/subtypes/implementors
/// plus a best-effort `users` list (see `queries.writeTypes`'s doc for what
/// is and is not extracted per language).
fn typesMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const scope = try scopeOf(self, p);
    const target = try targetOf(self, arena, p);
    const roots = try resolveTargetOrErr(self, arena, c, target);
    try queries.writeTypes(w, arena, c, roots[0], .{ .limit = try p.positive("limit", 200), .scope = scope });
}

/// `navgraph/impact`: the blast radius of the current working change
/// (overlay vs disk), or of disk vs `ref` when given — grouped by hunk. `uri`
/// narrows to one document; `range` (only meaningful with `uri`, outside
/// `ref` mode) hands navgraph a hunk it already knows about instead of
/// requiring an overlay to already differ from disk.
fn impactMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const scope = try scopeOf(self, p);
    const opts = queries.ImpactOptions{
        .depth = @min(try p.positive("depth", self.cfg.depth), session_mod.Config.max_depth),
        .direction = try directionOf(p, .callers),
        .limit = try p.positive("limit", 500),
        .scope = scope,
    };
    const ref = p.str("ref");
    // A `uri` outside the workspace root can never match a real overlay path;
    // force a no-match rather than silently falling back to "every document".
    var uri_path: ?[]const u8 = null;
    if (p.str("uri")) |uri| uri_path = (try pathOf(self, arena, uri)) orelse "\x00 outside workspace";
    var range: ?queries.ImpactRange = null;
    if (p.nested("range").obj != null) {
        const rg = p.nested("range");
        range = .{
            .lo = try oneBasedLine(try rg.nested("start").int("line", 0)),
            .hi = try oneBasedLine(try rg.nested("end").int("line", 0)),
        };
    }
    var detail: ?[]const u8 = null;
    queries.writeImpact(w, arena, c, ref, uri_path, range, opts, &detail) catch |err| {
        self.err_detail = detail;
        return err;
    };
}

/// `navgraph/context`: everything an editing agent typically needs about one
/// symbol in a single call, trimmed to `budget` tokens. See
/// `queries.writeContext`'s doc for the drop order.
fn contextMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const target = try targetOf(self, arena, p);
    const roots = try resolveTargetOrErr(self, arena, c, target);
    try queries.writeContext(w, arena, c, roots[0], .{ .budget = try p.positive("budget", 2000) });
}

/// `navgraph/where`: the symbol enclosing `{uri, line}` and its breadcrumb
/// chain. `line` is 1-based, like a stack trace or a diff hunk — unlike an
/// LSP `position.line`, which is 0-based.
fn whereMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const path = (try documentPath(self, arena, p)) orelse return error.InvalidParams;
    const line = try p.positive("line", 0);
    if (line == 0) return error.InvalidParams;
    try queries.writeWhere(w, arena, c, path, line);
}

fn searchMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const q = p.str("query") orelse return error.InvalidParams;
    const scope = try scopeOf(self, p);
    const filter = search.Filter{
        .kinds = try kindsOf(arena, p),
        .tests = scope.tests,
        .recent = try p.strings(arena, "recent"),
    };

    var hits: std.ArrayList(search.Hit) = .empty;
    defer hits.deinit(arena);
    if (p.boolean("refs", false)) {
        try search.searchRefs(arena, c.index(), q, filter, &hits);
    } else {
        try search.searchSymbols(arena, c.index(), q, filter, &hits);
    }

    const limit = try p.positive("limit", 50);
    const shown = hits.items[0..@min(hits.items.len, limit)];
    try w.writeAll("{\"items\":[");
    for (shown, 0..) |hit, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try payload.writeSymbolId(w, c, hit.id);
        try w.print(",\"score\":{d},\"matches\":", .{hit.score});
        try payload.writeLines(w, hit.matches());
        if (hit.lines.len != 0) {
            try w.writeAll(",\"lines\":");
            try payload.writeLines(w, hit.lines);
        }
        try w.writeByte('}');
    }
    try w.print("],\"total\":{d},\"truncated\":{}}}", .{ hits.items.len, shown.len < hits.items.len });
}

fn kindsOf(arena: std.mem.Allocator, p: Params) ![]const u8 {
    const list = try p.strings(arena, "kinds");
    if (list.len == 0) return "";
    return std.mem.join(arena, ",", list);
}

fn grep(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const pattern_text = p.str("pattern") orelse return error.InvalidParams;
    if (pattern_text.len == 0) return error.InvalidParams;

    var pattern = search.compilePattern(
        arena,
        pattern_text,
        p.boolean("regex", false),
        p.boolean("caseSensitive", false),
    ) catch return error.BadPattern;
    defer pattern.deinit();

    try queries.writeGrep(w, c, &pattern, .{
        .limit = try p.positive("limit", 200),
        .include = try p.strings(arena, "include"),
    });
}

fn callersMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    return tree(self, arena, params, w, .callers);
}

fn callsMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    return tree(self, arena, params, w, .callees);
}

fn tree(
    self: *Server,
    arena: std.mem.Allocator,
    params: ?std.json.Value,
    w: *Writer,
    direction: queries.Direction,
) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const target = try targetOf(self, arena, p);
    const roots = try resolveTargetOrErr(self, arena, c, target);
    try w.writeAll("{\"root\":");
    try queries.writeTree(w, arena, c, roots[0], .{
        .depth = @min(try p.positive("depth", 1), session_mod.Config.max_depth),
        .direction = direction,
        .refs = p.boolean("refs", false),
        .scope = try scopeOf(self, p),
    });
    try w.writeByte('}');
}

fn rescan(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    const s = &(self.session orelse return error.NotInitialized);
    const report = try s.rescan(Params.from(params).boolean("full", false));
    try self.announce(arena, report);
    try writeStatus(w, try self.ctx());
}

fn neighborsMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const target = try targetOf(self, arena, p);
    const roots = try resolveTargetOrErr(self, arena, c, target);
    try queries.writeNeighbors(w, c, roots, try scopeOf(self, p));
}

fn pathMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const from = p.str("from") orelse return error.InvalidParams;
    const to = p.str("to") orelse return error.InvalidParams;
    try queries.writePath(w, c, from, to);
}

fn outlineMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    try queries.writeOutline(w, c, p.str("path") orelse "", .{
        .kinds = try kindsOf(arena, p),
        .limit = try p.positive("limit", 300),
        .scope = try scopeOf(self, p),
    });
}

fn hotMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    try queries.writeHot(w, c, p.str("path") orelse "", .{
        .limit = try p.positive("limit", 25),
        .scope = try scopeOf(self, p),
    });
}

fn unusedMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    try queries.writeUnused(w, c, p.str("path") orelse "", .{
        .noPublic = p.boolean("noPublic", false),
        .followImports = p.boolean("followImports", false),
        .limit = try p.positive("limit", 300),
        .scope = try scopeOf(self, p),
    });
}

fn diffMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    var detail: ?[]const u8 = null;
    queries.writeDiff(w, arena, c, p.str("ref") orelse "HEAD", .{
        .depth = @min(try p.positive("depth", 1), session_mod.Config.max_depth),
        .direction = try directionOf(p, .callers),
        .limit = try p.positive("limit", 500),
        .scope = try scopeOf(self, p),
    }, &detail) catch |err| {
        self.err_detail = detail;
        return err;
    };
}

fn routesMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    try queries.writeRoutes(w, c, p.str("filter") orelse "", try p.positive("limit", 300));
}

fn eventsMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    try queries.writeEvents(w, c, p.str("filter") orelse "", try p.positive("limit", 50));
}

fn importsMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    try queries.writeImports(w, c, p.str("path") orelse "", try p.positive("limit", 300));
}

fn importersMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const path = p.str("path") orelse return error.InvalidParams;
    if (path.len == 0) return error.InvalidParams;
    try queries.writeImporters(w, c, path, try p.positive("limit", 300));
}

fn graphMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    var detail: ?[]const u8 = null;
    queries.writeGraphFile(w, arena, c, p.str("path") orelse "", try scopeOf(self, p), &detail) catch |err| {
        self.err_detail = detail;
        return err;
    };
}

// ---------------------------------------------------------------------------
// Method tables
// ---------------------------------------------------------------------------

const requests = [_]Entry{
    .{ .name = "initialize", .run = initialize },
    .{ .name = "shutdown", .run = shutdown },
    .{ .name = "textDocument/definition", .run = definition },
    .{ .name = "textDocument/references", .run = references },
    .{ .name = "textDocument/hover", .run = hover },
    .{ .name = "textDocument/documentSymbol", .run = documentSymbol },
    .{ .name = "workspace/symbol", .run = workspaceSymbol },
    .{ .name = "textDocument/prepareCallHierarchy", .run = prepareCallHierarchy },
    .{ .name = "callHierarchy/incomingCalls", .run = incomingCalls },
    .{ .name = "callHierarchy/outgoingCalls", .run = outgoingCalls },
    .{ .name = "textDocument/prepareTypeHierarchy", .run = prepareTypeHierarchy },
    .{ .name = "typeHierarchy/supertypes", .run = typeSupertypes },
    .{ .name = "typeHierarchy/subtypes", .run = typeSubtypes },
    .{ .name = "textDocument/implementation", .run = implementation },
    .{ .name = "textDocument/typeDefinition", .run = typeDefinition },
    .{ .name = "textDocument/documentHighlight", .run = documentHighlight },
    .{ .name = "textDocument/codeLens", .run = codeLens },
    .{ .name = "codeLens/resolve", .run = codeLensResolve },
    .{ .name = "navgraph/status", .run = status },
    .{ .name = "navgraph/symbolAt", .run = symbolAt },
    .{ .name = "navgraph/blast", .run = blast },
    .{ .name = "navgraph/tests", .run = testsMethod },
    .{ .name = "navgraph/types", .run = typesMethod },
    .{ .name = "navgraph/impact", .run = impactMethod },
    .{ .name = "navgraph/context", .run = contextMethod },
    .{ .name = "navgraph/where", .run = whereMethod },
    .{ .name = "navgraph/search", .run = searchMethod },
    .{ .name = "navgraph/grep", .run = grep },
    .{ .name = "navgraph/callers", .run = callersMethod },
    .{ .name = "navgraph/calls", .run = callsMethod },
    .{ .name = "navgraph/rescan", .run = rescan },
    .{ .name = "navgraph/neighbors", .run = neighborsMethod },
    .{ .name = "navgraph/path", .run = pathMethod },
    .{ .name = "navgraph/outline", .run = outlineMethod },
    .{ .name = "navgraph/hot", .run = hotMethod },
    .{ .name = "navgraph/unused", .run = unusedMethod },
    .{ .name = "navgraph/diff", .run = diffMethod },
    .{ .name = "navgraph/routes", .run = routesMethod },
    .{ .name = "navgraph/events", .run = eventsMethod },
    .{ .name = "navgraph/imports", .run = importsMethod },
    .{ .name = "navgraph/importers", .run = importersMethod },
    .{ .name = "navgraph/graph", .run = graphMethod },
};

const notifications = [_]NotifEntry{
    .{ .name = "initialized", .run = initialized },
    .{ .name = "exit", .run = exitNotification },
    .{ .name = "textDocument/didOpen", .run = didOpen },
    .{ .name = "textDocument/didChange", .run = didChange },
    .{ .name = "textDocument/didSave", .run = didSave },
    .{ .name = "textDocument/didClose", .run = didClose },
    .{ .name = "workspace/didChangeWatchedFiles", .run = didChangeWatchedFiles },
    // Cancellation is accepted and ignored: a request is answered before the
    // next one is read, so there is never one in flight to cancel.
    .{ .name = "$/cancelRequest", .run = ignore },
    .{ .name = "$/setTrace", .run = ignore },
};

/// Every callable `navgraph/*` request, advertised in `initialize`. A client is
/// told to build its method list from this, so it must hold only names that can
/// actually be called — `navgraph/indexed` is a notification and lives below.
pub const navgraph_methods = blk: {
    var names: [requests.len][]const u8 = undefined;
    var n: usize = 0;
    for (requests) |e| {
        if (std.mem.startsWith(u8, e.name, "navgraph/")) {
            names[n] = e.name;
            n += 1;
        }
    }
    const out = names[0..n].*;
    break :blk out;
};

/// Every `navgraph/*` notification the server sends, advertised separately.
pub const navgraph_notifications = [_][]const u8{"navgraph/indexed"};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const index_mod = @import("../index.zig");
const json_out = @import("../json_out.zig");

/// A live server over a temporary project, driven message by message.
///
/// Heap-allocated because the `Server` holds a pointer into this struct's own
/// output buffer, which must not move. Shared with `loop.zig`'s tests.
pub const TestServer = struct {
    gpa: std.mem.Allocator,
    tmp: ?std.testing.TmpDir,
    root: []u8,
    out: Writer.Allocating,
    logged: Writer.Allocating,
    server: Server,
    /// Bytes of `out` already returned by `takeFrames`.
    read_at: usize,

    /// Serve a fresh temp project made of `{ path, contents }` pairs.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, files: []const [2][]const u8) !*TestServer {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
        const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer gpa.free(root);
        return build(gpa, io, tmp, root);
    }

    /// Serve a private temp copy of an existing repository directory (the
    /// `testenv/` fixtures). A resident session's first walk always writes a
    /// parse cache back (`Session.init`, no open document yet), so serving
    /// `testenv/` in place would leave a `.navgraph/` cache dir in the
    /// checked-in fixture tree on every test run (merge-gate review F4).
    pub fn initAt(gpa: std.mem.Allocator, io: std.Io, root_path: []const u8) !*TestServer {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var src = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
        defer src.close(io);
        try copyTree(gpa, io, src, tmp.dir);
        const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer gpa.free(root);
        return build(gpa, io, tmp, root);
    }

    /// Copy every regular file from `src` into `dest`, preserving relative
    /// paths; directories are created as needed.
    fn copyTree(gpa: std.mem.Allocator, io: std.Io, src: std.Io.Dir, dest: std.Io.Dir) !void {
        var walker = try src.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            try src.copyFile(entry.path, dest, entry.path, io, .{ .make_path = true });
        }
    }

    fn build(gpa: std.mem.Allocator, io: std.Io, tmp: ?std.testing.TmpDir, root: []u8) !*TestServer {
        const self = try gpa.create(TestServer);
        self.* = .{
            .gpa = gpa,
            .tmp = tmp,
            .root = root,
            .out = .init(gpa),
            .logged = .init(gpa),
            .server = undefined,
            .read_at = 0,
        };
        self.server = Server.init(gpa, io, &self.out.writer, .{
            .writer = &self.logged.writer,
            .level = .err,
        }, self.root, .auto);
        return self;
    }

    pub fn deinit(self: *TestServer) void {
        self.server.deinit();
        self.out.deinit();
        self.logged.deinit();
        self.gpa.free(self.root);
        if (self.tmp) |*t| t.cleanup();
        self.gpa.destroy(self);
    }

    /// Bring the server up: `initialize` (utf-8 positions) then `initialized`.
    /// The initialize response stays in the output buffer for `responseFor(1)`.
    pub fn start(self: *TestServer) !void {
        try self.send(
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":
            \\ {"capabilities":{"general":{"positionEncodings":["utf-8"]}}}}
        );
        try self.send(
            \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        );
    }

    /// Dispatch one raw message body.
    pub fn send(self: *TestServer, body: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const alloc = arena.allocator();
        const decoded = rpc.decode(alloc, body);
        try testing.expect(decoded == .message);
        try self.server.dispatch(alloc, decoded.message);
    }

    /// Dispatch a request and return its parsed response. Caller owns it.
    pub fn request(self: *TestServer, id: i64, body: []const u8) !std.json.Parsed(std.json.Value) {
        try self.send(body);
        return self.responseFor(id);
    }

    /// The parsed body of the newest message whose `id` matches.
    pub fn responseFor(self: *TestServer, id: i64) !std.json.Parsed(std.json.Value) {
        var found: ?[]const u8 = null;
        var rest = self.out.written();
        while (rpc.nextFrame(rest, 1 << 24) == .frame) {
            const frame = rpc.nextFrame(rest, 1 << 24).frame;
            if (matchesId(frame.body, id)) found = frame.body;
            rest = rest[frame.consumed..];
        }
        const body = found orelse return error.NoSuchResponse;
        return std.json.parseFromSlice(std.json.Value, self.gpa, body, .{});
    }

    /// Parsed bodies of every message written since the last call. Caller frees
    /// the slice; each entry is owned by `arena`.
    pub fn takeNotifications(self: *TestServer, arena: std.mem.Allocator, method: []const u8) ![]std.json.Value {
        var out: std.ArrayList(std.json.Value) = .empty;
        var rest = self.out.written()[self.read_at..];
        self.read_at = self.out.written().len;
        while (rpc.nextFrame(rest, 1 << 24) == .frame) {
            const frame = rpc.nextFrame(rest, 1 << 24).frame;
            rest = rest[frame.consumed..];
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, frame.body, .{}) catch continue;
            if (parsed != .object) continue;
            const m = parsed.object.get("method") orelse continue;
            if (m == .string and std.mem.eql(u8, m.string, method)) try out.append(arena, parsed);
        }
        return out.toOwnedSlice(arena);
    }

    /// A `file://` URI for a path inside the served root.
    pub fn uri(self: *TestServer, arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
        var aw: Writer.Allocating = .init(arena);
        defer aw.deinit();
        try overlay.writeUriIn(&aw.writer, self.server.session.?.root_abs, rel);
        return arena.dupe(u8, aw.written());
    }
};

fn matchesId(body: []const u8, id: i64) bool {
    var buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\"id\":{d},", .{id}) catch return false;
    return std.mem.indexOf(u8, body, needle) != null;
}

/// `result` of a parsed response, or an error when the server replied with one.
fn resultOf(parsed: std.json.Parsed(std.json.Value)) !std.json.Value {
    if (parsed.value.object.get("error")) |_| return error.ServerReturnedError;
    return parsed.value.object.get("result") orelse error.NoResult;
}

fn errorCodeOf(parsed: std.json.Parsed(std.json.Value)) !i64 {
    const err = parsed.value.object.get("error") orelse return error.NoError;
    return err.object.get("code").?.integer;
}

const project = [_][2][]const u8{
    .{
        "app.zig",
        \\const util = @import("util.zig");
        \\
        \\/// Entry point.
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
        \\pub const marker = "needle-in-a-haystack";
        \\
        \\pub fn helper() void {}
        \\
    },
};

fn started(gpa: std.mem.Allocator) !*TestServer {
    const ts = try TestServer.init(gpa, testing.io, &project);
    errdefer ts.deinit();
    try ts.start();
    return ts;
}

test "initialize advertises the contract's capabilities and methods" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.responseFor(1);
    defer res.deinit();
    const caps = (try resultOf(res)).object.get("capabilities").?.object;

    try testing.expectEqualStrings("utf-8", caps.get("positionEncoding").?.string);
    try testing.expect(caps.get("definitionProvider").?.bool);
    try testing.expect(caps.get("referencesProvider").?.bool);
    try testing.expect(caps.get("hoverProvider").?.bool);
    try testing.expect(caps.get("documentSymbolProvider").?.bool);
    try testing.expect(caps.get("workspaceSymbolProvider").?.bool);
    const sync = caps.get("textDocumentSync").?.object;
    try testing.expect(sync.get("openClose").?.bool);
    try testing.expectEqual(@as(i64, 1), sync.get("change").?.integer);

    const ng = caps.get("experimental").?.object.get("navgraph").?.object;
    try testing.expectEqual(@as(i64, protocol_version), ng.get("protocolVersion").?.integer);
    // Only implemented methods are advertised.
    const methods = ng.get("methods").?.array.items;
    try testing.expectEqual(navgraph_methods.len, methods.len);
    for (methods) |m| try testing.expect(std.mem.startsWith(u8, m.string, "navgraph/"));

    // A notification is not a callable method; clients build their method list
    // from this array, so anything in it must survive being called.
    const notifs = ng.get("notifications").?.array.items;
    try testing.expectEqual(navgraph_notifications.len, notifs.len);
    try testing.expectEqualStrings("navgraph/indexed", notifs[0].string);
    for (methods) |m| try testing.expect(!std.mem.eql(u8, m.string, "navgraph/indexed"));
}

test "every advertised navgraph method is dispatchable" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.responseFor(1);
    defer res.deinit();
    const ng = (try resultOf(res)).object.get("capabilities").?.object
        .get("experimental").?.object.get("navgraph").?.object;

    var id: i64 = 200;
    for (ng.get("methods").?.array.items) |m| {
        id += 1;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const body = try std.fmt.allocPrint(
            arena.allocator(),
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{}}}}",
            .{ id, m.string },
        );
        var got = try ts.request(id, body);
        defer got.deinit();
        // Params may well be wrong for the method; "unknown method" may not be.
        if (got.value.object.get("error")) |e| {
            try testing.expect(e.object.get("code").?.integer != -32601);
        }
    }
}

test "an invalid tests scope is rejected, not silently ignored" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    const methods = [_][]const u8{ "navgraph/blast", "navgraph/search", "navgraph/callers", "navgraph/calls" };
    var id: i64 = 300;
    for (methods) |method| {
        id += 1;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const body = try std.fmt.allocPrint(
            arena.allocator(),
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"," ++
                "\"params\":{{\"symbol\":\"run\",\"query\":\"run\",\"tests\":\"bogus\"}}}}",
            .{ id, method },
        );
        var got = try ts.request(id, body);
        defer got.deinit();
        try testing.expectEqual(@as(i64, -32602), try errorCodeOf(got));
    }

    // A valid scope still answers.
    var ok = try ts.request(320,
        \\{"jsonrpc":"2.0","id":320,"method":"navgraph/blast","params":{"symbol":"run","tests":"without"}}
    );
    defer ok.deinit();
    try testing.expect((try resultOf(ok)).object.get("summary") != null);
}

test "the released version agrees across serverInfo, navgraph/status, and the manifest (F4)" {
    const ts = try started(testing.allocator);
    defer ts.deinit();

    var init_res = try ts.responseFor(1);
    defer init_res.deinit();
    const server_info = (try resultOf(init_res)).object.get("serverInfo").?.object;
    try testing.expectEqualStrings(capabilities.product_version, server_info.get("version").?.string);

    var status_res = try ts.request(2,
        \\{"jsonrpc":"2.0","id":2,"method":"navgraph/status","params":{}}
    );
    defer status_res.deinit();
    try testing.expectEqualStrings(capabilities.product_version, (try resultOf(status_res)).object.get("version").?.string);

    // A release binary reporting this placeholder is the exact defect F4
    // found: build.zig.zon's version was never bumped from its default, and
    // the release workflow gates the tag on that same value.
    try testing.expect(!std.mem.eql(u8, capabilities.product_version, "0.0.0"));
}

test "initialize defaults to utf-16 when the client offers no encoding" {
    const ts = try TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    var res = try ts.request(1,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    defer res.deinit();
    const caps = (try resultOf(res)).object.get("capabilities").?.object;
    try testing.expectEqualStrings("utf-16", caps.get("positionEncoding").?.string);
    try testing.expectEqual(position.Encoding.utf16, ts.server.encoding);
}

test "initializationOptions override the session defaults" {
    const ts = try TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    var res = try ts.request(1,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"initializationOptions":
        \\ {"tests":"without","strict":true,"debounceMs":7,"watch":false,"depth":99}}}
    );
    defer res.deinit();
    try testing.expectEqual(query.TestScope.without, ts.server.cfg.tests);
    try testing.expect(ts.server.cfg.strict);
    try testing.expectEqual(@as(u32, 7), ts.server.cfg.debounce_ms);
    try testing.expect(!ts.server.cfg.watch);
    // depth is clamped to the contract's maximum.
    try testing.expectEqual(session_mod.Config.max_depth, ts.server.cfg.depth);
}

test "initialized indexes the project and always announces navgraph/indexed" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const notes = try ts.takeNotifications(arena.allocator(), "navgraph/indexed");
    try testing.expectEqual(@as(usize, 1), notes.len);
    const p = notes[0].object.get("params").?.object;
    try testing.expectEqualStrings("initial", p.get("reason").?.string);
    try testing.expectEqual(@as(i64, 2), p.get("files").?.integer);
    try testing.expect(p.get("symbols").?.integer > 0);
}

test "an unknown method is -32601 and the server keeps serving" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var bad = try ts.request(5,
        \\{"jsonrpc":"2.0","id":5,"method":"navgraph/nope","params":{}}
    );
    defer bad.deinit();
    try testing.expectEqual(@as(i64, -32601), try errorCodeOf(bad));

    var ok = try ts.request(6,
        \\{"jsonrpc":"2.0","id":6,"method":"navgraph/status","params":{}}
    );
    defer ok.deinit();
    try testing.expect((try resultOf(ok)).object.get("files").?.integer == 2);
}

test "bad params are -32602 and an unresolvable target is -32001" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var bad_dir = try ts.request(7,
        \\{"jsonrpc":"2.0","id":7,"method":"navgraph/blast","params":{"symbol":"run","direction":"sideways"}}
    );
    defer bad_dir.deinit();
    try testing.expectEqual(@as(i64, -32602), try errorCodeOf(bad_dir));

    var missing = try ts.request(8,
        \\{"jsonrpc":"2.0","id":8,"method":"navgraph/blast","params":{"symbol":"no_such_symbol_xyz"}}
    );
    defer missing.deinit();
    try testing.expectEqual(@as(i64, -32001), try errorCodeOf(missing));

    var no_query = try ts.request(9,
        \\{"jsonrpc":"2.0","id":9,"method":"navgraph/search","params":{}}
    );
    defer no_query.deinit();
    try testing.expectEqual(@as(i64, -32602), try errorCodeOf(no_query));
}

test "navgraph/status reports the graph, the languages and the cache flag" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(10,
        \\{"jsonrpc":"2.0","id":10,"method":"navgraph/status","params":{}}
    );
    defer res.deinit();
    const s = (try resultOf(res)).object;
    try testing.expectEqual(@as(i64, protocol_version), s.get("protocolVersion").?.integer);
    try testing.expectEqual(@as(i64, 2), s.get("files").?.integer);
    try testing.expectEqual(@as(i64, 2), s.get("languages").?.object.get("zig").?.integer);
    try testing.expectEqual(@as(i64, 0), s.get("overlays").?.integer);
    try testing.expect(s.get("edges").?.integer > 0);
    // ISO-8601 with a Z suffix.
    const at = s.get("indexedAt").?.string;
    try testing.expectEqual(@as(u8, 'Z'), at[at.len - 1]);
    try testing.expectEqual(@as(usize, 24), at.len);
}

test "navgraph/search ranks an exact name first and reports the total" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(11,
        \\{"jsonrpc":"2.0","id":11,"method":"navgraph/search","params":{"query":"helper"}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    const items = r.get("items").?.array.items;
    try testing.expect(items.len >= 1);
    try testing.expectEqualStrings("helper", items[0].object.get("symbol").?.object.get("name").?.string);
    try testing.expect(items[0].object.get("score").?.integer >= 4000);
    try testing.expectEqual(@as(i64, @intCast(items.len)), r.get("total").?.integer);
    // `matches` carries the byte offsets in the qualified name.
    try testing.expectEqual(@as(usize, 6), items[0].object.get("matches").?.array.items.len);
}

test "navgraph/search honors kinds and the limit" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var only_const = try ts.request(12,
        \\{"jsonrpc":"2.0","id":12,"method":"navgraph/search","params":{"query":"marker","kinds":["const"]}}
    );
    defer only_const.deinit();
    try testing.expectEqual(@as(usize, 1), (try resultOf(only_const)).object.get("items").?.array.items.len);

    var none = try ts.request(13,
        \\{"jsonrpc":"2.0","id":13,"method":"navgraph/search","params":{"query":"marker","kinds":["fn"]}}
    );
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), (try resultOf(none)).object.get("items").?.array.items.len);

    var capped = try ts.request(14,
        \\{"jsonrpc":"2.0","id":14,"method":"navgraph/search","params":{"query":"e","limit":1}}
    );
    defer capped.deinit();
    const r = (try resultOf(capped)).object;
    try testing.expectEqual(@as(usize, 1), r.get("items").?.array.items.len);
    try testing.expect(r.get("total").?.integer > 1);
}

test "navgraph/grep finds a literal, respects include globs and reports totals" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(15,
        \\{"jsonrpc":"2.0","id":15,"method":"navgraph/grep","params":{"pattern":"needle-in-a-haystack"}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    const items = r.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("util.zig", items[0].object.get("file").?.string);
    try testing.expectEqual(@as(i64, 1), items[0].object.get("line").?.integer);
    try testing.expect(!r.get("truncated").?.bool);
    // The enclosing definition is reported alongside the hit.
    try testing.expectEqualStrings("marker", items[0].object.get("enclosing").?.object.get("name").?.string);

    var filtered = try ts.request(16,
        \\{"jsonrpc":"2.0","id":16,"method":"navgraph/grep","params":{"pattern":"needle","include":["app.zig"]}}
    );
    defer filtered.deinit();
    try testing.expectEqual(@as(usize, 0), (try resultOf(filtered)).object.get("items").?.array.items.len);
}

test "navgraph/grep supports regular expressions and rejects a bad one" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(17,
        \\{"jsonrpc":"2.0","id":17,"method":"navgraph/grep","params":{"pattern":"fn\\s+\\w+","regex":true}}
    );
    defer res.deinit();
    try testing.expect((try resultOf(res)).object.get("items").?.array.items.len >= 2);

    var bad = try ts.request(18,
        \\{"jsonrpc":"2.0","id":18,"method":"navgraph/grep","params":{"pattern":"(unclosed","regex":true}}
    );
    defer bad.deinit();
    try testing.expectEqual(@as(i64, -32602), try errorCodeOf(bad));
}

test "navgraph/callers and navgraph/calls mirror the CLI tree" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var callers = try ts.request(19,
        \\{"jsonrpc":"2.0","id":19,"method":"navgraph/callers","params":{"symbol":"helper","depth":2}}
    );
    defer callers.deinit();
    const root = (try resultOf(callers)).object.get("root").?.object;
    try testing.expectEqualStrings("helper", root.get("symbol").?.object.get("name").?.string);
    try testing.expect(!root.get("recursion").?.bool);
    const children = root.get("children").?.array.items;
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqualStrings("mid", children[0].object.get("symbol").?.object.get("name").?.string);
    // The edge carries its call-site line.
    try testing.expectEqual(@as(i64, 9), children[0].object.get("lines").?.array.items[0].integer);
    // Depth 2 reaches `run`, which calls `mid`.
    try testing.expectEqualStrings(
        "run",
        children[0].object.get("children").?.array.items[0].object.get("symbol").?.object.get("name").?.string,
    );

    var calls = try ts.request(20,
        \\{"jsonrpc":"2.0","id":20,"method":"navgraph/calls","params":{"symbol":"run","depth":2}}
    );
    defer calls.deinit();
    const out = (try resultOf(calls)).object.get("root").?.object;
    try testing.expectEqualStrings("mid", out.get("children").?.array.items[0].object.get("symbol").?.object.get("name").?.string);
}

test "prepareCallHierarchy resolves the definition at the cursor" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "app.zig");
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":50,"method":"textDocument/prepareCallHierarchy","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":7,"character":3}}}}}}
    , .{uri});
    var res = try ts.request(50, body);
    defer res.deinit();
    const items = (try resultOf(res)).array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("mid", items[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 12), items[0].object.get("kind").?.integer);
    const data = items[0].object.get("data").?.object;
    try testing.expectEqualStrings("mid", data.get("qualified").?.string);
    try testing.expectEqualStrings("app.zig", data.get("file").?.string);
    try testing.expect(data.get("exact") == null);
}

test "callHierarchy/incomingCalls and outgoingCalls mirror the call graph" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var incoming = try ts.request(51,
        \\{"jsonrpc":"2.0","id":51,"method":"callHierarchy/incomingCalls","params":{"item":{"data":{"qualified":"mid","file":"app.zig"}}}}
    );
    defer incoming.deinit();
    const in_items = (try resultOf(incoming)).array.items;
    try testing.expectEqual(@as(usize, 1), in_items.len);
    const from = in_items[0].object.get("from").?.object;
    try testing.expectEqualStrings("run", from.get("name").?.string);
    try testing.expect(from.get("data").?.object.get("exact").?.bool);
    const from_ranges = in_items[0].object.get("fromRanges").?.array.items;
    try testing.expectEqual(@as(usize, 1), from_ranges.len);
    try testing.expectEqual(@as(i64, 4), from_ranges[0].object.get("start").?.object.get("line").?.integer);

    var outgoing = try ts.request(52,
        \\{"jsonrpc":"2.0","id":52,"method":"callHierarchy/outgoingCalls","params":{"item":{"data":{"qualified":"mid","file":"app.zig"}}}}
    );
    defer outgoing.deinit();
    const out_items = (try resultOf(outgoing)).array.items;
    try testing.expectEqual(@as(usize, 1), out_items.len);
    const to = out_items[0].object.get("to").?.object;
    try testing.expectEqualStrings("helper", to.get("name").?.string);
    try testing.expectEqualStrings("util.zig", to.get("data").?.object.get("file").?.string);

    // A stale/unknown item (a re-index renamed or removed it) is a routine
    // "not found", the same as any other unresolved Target.
    var missing = try ts.request(53,
        \\{"jsonrpc":"2.0","id":53,"method":"callHierarchy/incomingCalls","params":{"item":{"data":{"qualified":"nope","file":"app.zig"}}}}
    );
    defer missing.deinit();
    try testing.expectEqual(@as(i64, -32001), try errorCodeOf(missing));
}

const py_ports_project = [_][2][]const u8{
    .{
        "ports.py",
        \\from typing import Protocol
        \\class Store(Protocol):
        \\    def get(self, key: str) -> str: ...
        \\    def put(self, key: str, value: str) -> None: ...
        \\class MemoryStore:
        \\    def get(self, key: str) -> str: return key
        \\    def put(self, key: str, value: str) -> None: pass
        \\class Partial(Store):
        \\    def get(self, key: str) -> str: return key
        \\
    },
};

fn startedPy(gpa: std.mem.Allocator) !*TestServer {
    const ts = try TestServer.init(gpa, testing.io, &py_ports_project);
    errdefer ts.deinit();
    try ts.start();
    return ts;
}

test "prepareTypeHierarchy, supertypes and subtypes walk the base/impl table" {
    const ts = try startedPy(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "ports.py");

    // `Store` sits on line 2 (1-based) -> 0-based line 1, "class " = 6 cols in.
    const prep_body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":60,"method":"textDocument/prepareTypeHierarchy","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":1,"character":6}}}}}}
    , .{uri});
    var prep = try ts.request(60, prep_body);
    defer prep.deinit();
    const items = (try resultOf(prep)).array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("Store", items[0].object.get("name").?.string);

    var sub = try ts.request(61,
        \\{"jsonrpc":"2.0","id":61,"method":"typeHierarchy/subtypes","params":{"item":{"data":{"qualified":"Store","file":"ports.py"}}}}
    );
    defer sub.deinit();
    const subtypes = (try resultOf(sub)).array.items;
    // Nominal (`class Partial(Store)`) is a keyword base edge; structural-only
    // `MemoryStore` is not — that distinction lives in `textDocument/implementation`.
    try testing.expectEqual(@as(usize, 1), subtypes.len);
    try testing.expectEqualStrings("Partial", subtypes[0].object.get("name").?.string);
    try testing.expect(subtypes[0].object.get("data").?.object.get("exact") == null);

    var sup = try ts.request(62,
        \\{"jsonrpc":"2.0","id":62,"method":"typeHierarchy/supertypes","params":{"item":{"data":{"qualified":"Partial","file":"ports.py"}}}}
    );
    defer sup.deinit();
    const supertypes = (try resultOf(sup)).array.items;
    try testing.expectEqual(@as(usize, 1), supertypes.len);
    try testing.expectEqualStrings("Store", supertypes[0].object.get("name").?.string);
}

test "textDocument/implementation covers structural and nominal conformance" {
    const ts = try startedPy(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "ports.py");

    const type_body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":63,"method":"textDocument/implementation","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":1,"character":6}}}}}}
    , .{uri});
    var type_res = try ts.request(63, type_body);
    defer type_res.deinit();
    const type_locs = (try resultOf(type_res)).array.items;
    try testing.expectEqual(@as(usize, 2), type_locs.len);

    // The `get` method (line 3, 1-based -> 0-based 2, "    def " = 8 cols in).
    const method_body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":64,"method":"textDocument/implementation","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":2,"character":8}}}}}}
    , .{uri});
    var method_res = try ts.request(64, method_body);
    defer method_res.deinit();
    const method_locs = (try resultOf(method_res)).array.items;
    try testing.expectEqual(@as(usize, 2), method_locs.len);
}

const widget_project = [_][2][]const u8{
    .{
        "widget.zig",
        \\pub const Widget = struct {
        \\    id: u32 = 0,
        \\};
        \\
        \\pub fn run(w: Widget) void {
        \\    _ = w;
        \\}
        \\
    },
};

test "textDocument/typeDefinition resolves a typed param to its declaration" {
    const ts = try TestServer.init(testing.allocator, testing.io, &widget_project);
    defer ts.deinit();
    try ts.start();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "widget.zig");

    // Param `w: Widget` sits on line 5 (1-based) -> 0-based 4, "pub fn run(" = 11 cols in.
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":65,"method":"textDocument/typeDefinition","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":4,"character":11}}}}}}
    , .{uri});
    var res = try ts.request(65, body);
    defer res.deinit();
    const locs = (try resultOf(res)).array.items;
    try testing.expectEqual(@as(usize, 1), locs.len);
    try testing.expect(std.mem.endsWith(u8, locs[0].object.get("uri").?.string, "widget.zig"));
    try testing.expectEqual(@as(i64, 0), locs[0].object.get("range").?.object.get("start").?.object.get("line").?.integer);
}

test "textDocument/typeDefinition off an untyped identifier returns an empty array" {
    const ts = try TestServer.init(testing.allocator, testing.io, &widget_project);
    defer ts.deinit();
    try ts.start();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "widget.zig");

    // `run` itself (line 5, 1-based -> 0-based 4, "pub fn " = 7 cols in) has
    // no binding named "run" in its own body/param list.
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":66,"method":"textDocument/typeDefinition","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":4,"character":7}}}}}}
    , .{uri});
    var res = try ts.request(66, body);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 0), (try resultOf(res)).array.items.len);
}

test "textDocument/documentHighlight reports the definition and each call site" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "app.zig");

    // The `mid()` call inside `run` (line 5, 1-based -> 0-based 4).
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":67,"method":"textDocument/documentHighlight","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":4,"character":5}}}}}}
    , .{uri});
    var res = try ts.request(67, body);
    defer res.deinit();
    const items = (try resultOf(res)).array.items;
    try testing.expectEqual(@as(usize, 2), items.len);

    var saw_def = false;
    var saw_call = false;
    for (items) |item| {
        const line = item.object.get("range").?.object.get("start").?.object.get("line").?.integer;
        const kind = item.object.get("kind").?.integer;
        if (line == 7) { // `fn mid` definition line (0-based).
            try testing.expectEqual(@as(i64, 1), kind);
            saw_def = true;
        } else if (line == 4) { // `mid();` call site (0-based).
            try testing.expectEqual(@as(i64, 2), kind);
            saw_call = true;
        }
    }
    try testing.expect(saw_def and saw_call);
}

test "textDocument/documentHighlight off whitespace returns an empty array" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "app.zig");
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":68,"method":"textDocument/documentHighlight","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":1,"character":0}}}}}}
    , .{uri});
    var res = try ts.request(68, body);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 0), (try resultOf(res)).array.items.len);
}

const highlight_leak_project = [_][2][]const u8{
    .{ "app.zig", "pub fn run() void {}\n" },
    .{ "other.zig", "pub fn run() void {}\n" },
    .{ "third.zig", "pub fn run() void {}\n" },
};

// coldstart F2: `writeDocumentHighlight` passed `locate`'s `candidates`
// allocation to the long-lived session allocator instead of the per-request
// arena, leaking on every request whose cursor sits on a name with any
// same-named definition elsewhere in the index. `run` here has two such
// candidates (`other.zig`, `third.zig`); `testing.allocator` panics on any
// leaked byte at teardown, so 1000 requests reaching `ts.deinit()` below is
// itself the RSS-flat proof — no leaked memory survives a single iteration.
test "textDocument/documentHighlight does not leak into the session allocator across many requests on a multi-candidate name" {
    const ts = try TestServer.init(testing.allocator, testing.io, &highlight_leak_project);
    defer ts.deinit();
    try ts.start();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "app.zig");
    // Cursor on `run`'s own definition (0-based col 7 -> the 'r').
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":900,"method":"textDocument/documentHighlight","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":0,"character":7}}}}}}
    , .{uri});

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        var res = try ts.request(900, body);
        defer res.deinit();
        const items = (try resultOf(res)).array.items;
        try testing.expectEqual(@as(usize, 1), items.len); // just the definition; no cross-file refs.
    }
}

test "textDocument/codeLens reports callers/callees per definition, and resolve is a no-op" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "app.zig");
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":69,"method":"textDocument/codeLens","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{uri});
    var res = try ts.request(69, body);
    defer res.deinit();
    const items = (try resultOf(res)).array.items;
    try testing.expectEqual(@as(usize, 2), items.len);

    var by_symbol = std.StringHashMap(std.json.Value).init(testing.allocator);
    defer by_symbol.deinit();
    for (items) |item| {
        const args = item.object.get("command").?.object.get("arguments").?.array.items;
        try by_symbol.put(args[0].object.get("symbol").?.string, item);
    }

    const run_lens = by_symbol.get("run@app.zig").?.object;
    try testing.expectEqualStrings("0 callers \xc2\xb7 1 callees", run_lens.get("command").?.object.get("title").?.string);
    try testing.expectEqualStrings("navgraph.blast", run_lens.get("command").?.object.get("command").?.string);

    const mid_lens = by_symbol.get("mid@app.zig").?.object;
    try testing.expectEqualStrings("1 callers \xc2\xb7 1 callees", mid_lens.get("command").?.object.get("title").?.string);

    // `codeLens/resolve` is the identity function: it echoes its params.
    var resolve_res = try ts.request(70,
        \\{"jsonrpc":"2.0","id":70,"method":"codeLens/resolve","params":{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":1}},"command":{"title":"0 callers \u00b7 1 callees","command":"navgraph.blast","arguments":[{"symbol":"run@app.zig"}]}}}
    );
    defer resolve_res.deinit();
    const resolved = (try resultOf(resolve_res)).object;
    try testing.expectEqual(@as(i64, 3), resolved.get("range").?.object.get("start").?.object.get("line").?.integer);
    try testing.expectEqualStrings("navgraph.blast", resolved.get("command").?.object.get("command").?.string);
    try testing.expectEqualStrings("run@app.zig", resolved.get("command").?.object.get("arguments").?.array.items[0].object.get("symbol").?.string);

    // Missing params is a hostile-input rejection, not a crash.
    var bad = try ts.request(71,
        \\{"jsonrpc":"2.0","id":71,"method":"codeLens/resolve"}
    );
    defer bad.deinit();
    try testing.expectEqual(@as(i64, -32602), try errorCodeOf(bad));
}

const tests_project = [_][2][]const u8{
    .{
        "app.zig",
        \\pub fn leaf() void {}
        \\
        \\fn mid() void {
        \\    leaf();
        \\}
        \\
        \\pub fn run() void {
        \\    mid();
        \\}
        \\
        \\pub fn orphan() void {}
        \\
        \\test "covers run" {
        \\    run();
        \\}
        \\
    },
};

test "navgraph/tests inverts coverage: every test reaching the target, with depth and via" {
    const ts = try TestServer.init(testing.allocator, testing.io, &tests_project);
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(74,
        \\{"jsonrpc":"2.0","id":74,"method":"navgraph/tests","params":{"symbol":"leaf"}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqualStrings("leaf", r.get("symbol").?.object.get("name").?.string);

    const found = r.get("tests").?.array.items;
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("covers run", found[0].object.get("symbol").?.object.get("name").?.string);
    // leaf(0) <- mid(1) <- run(2) <- "covers run"(3).
    try testing.expectEqual(@as(i64, 3), found[0].object.get("depth").?.integer);
    const via = found[0].object.get("via").?.array.items;
    try testing.expectEqual(@as(usize, 1), via.len);
    try testing.expectEqualStrings("run", ts.server.session.?.idx.graph.symbols[@intCast(via[0].integer)].name);

    const summary = r.get("summary").?.object;
    try testing.expectEqual(@as(i64, 1), summary.get("count").?.integer);
    try testing.expectEqual(@as(i64, 3), summary.get("maxDepth").?.integer);
    try testing.expect(!summary.get("truncated").?.bool);
}

test "navgraph/tests reports an empty list for an uncalled symbol, and -32001 off a bad target" {
    const ts = try TestServer.init(testing.allocator, testing.io, &tests_project);
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(75,
        \\{"jsonrpc":"2.0","id":75,"method":"navgraph/tests","params":{"symbol":"orphan"}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqual(@as(usize, 0), r.get("tests").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), r.get("summary").?.object.get("count").?.integer);

    var missing = try ts.request(76,
        \\{"jsonrpc":"2.0","id":76,"method":"navgraph/tests","params":{"symbol":"nope"}}
    );
    defer missing.deinit();
    try testing.expectEqual(@as(i64, -32001), try errorCodeOf(missing));
}

test "navgraph/types reports the base/impl table and dedupes a user across extends and implements" {
    const ts = try startedPy(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(77,
        \\{"jsonrpc":"2.0","id":77,"method":"navgraph/types","params":{"symbol":"Store"}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqualStrings("Store", r.get("symbol").?.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 0), r.get("supertypes").?.array.items.len);

    const subtypes = r.get("subtypes").?.array.items;
    try testing.expectEqual(@as(usize, 1), subtypes.len);
    try testing.expectEqualStrings("Partial", subtypes[0].object.get("name").?.string);

    // Both `Partial` (nominal) and `MemoryStore` (structural-only) implement Store.
    const implementors = r.get("implementors").?.array.items;
    try testing.expectEqual(@as(usize, 2), implementors.len);

    // `Partial` qualifies as both a subtype (extends) and an implementor
    // (implements); it must appear exactly once in `users`, as the more
    // specific "implements" (coldstart F3 — implementors are labeled first).
    const users = r.get("users").?.array.items;
    try testing.expectEqual(@as(usize, 2), users.len);
    var saw_partial_implements = false;
    var saw_memorystore_implements = false;
    for (users) |u| {
        const name = u.object.get("symbol").?.object.get("name").?.string;
        const kind = u.object.get("kind").?.string;
        if (std.mem.eql(u8, name, "Partial")) {
            try testing.expectEqualStrings("implements", kind);
            saw_partial_implements = true;
        } else if (std.mem.eql(u8, name, "MemoryStore")) {
            try testing.expectEqualStrings("implements", kind);
            saw_memorystore_implements = true;
        }
    }
    try testing.expect(saw_partial_implements and saw_memorystore_implements);
    try testing.expect(!r.get("truncated").?.bool);
}

test "navgraph/types classifies a typed param binding as a user" {
    const ts = try TestServer.init(testing.allocator, testing.io, &widget_project);
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(78,
        \\{"jsonrpc":"2.0","id":78,"method":"navgraph/types","params":{"symbol":"Widget"}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    const users = r.get("users").?.array.items;
    try testing.expectEqual(@as(usize, 1), users.len);
    try testing.expectEqualStrings("run", users[0].object.get("symbol").?.object.get("name").?.string);
    try testing.expectEqualStrings("param", users[0].object.get("kind").?.string);
}

test "navgraph/blast reports depth, via, byFile and the file target form" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(21,
        \\{"jsonrpc":"2.0","id":21,"method":"navgraph/blast","params":{"symbol":"helper","depth":3}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqual(@as(usize, 1), r.get("roots").?.array.items.len);

    const nodes = r.get("nodes").?.array.items;
    // helper (0) <- mid (1) <- run (2).
    try testing.expectEqual(@as(usize, 3), nodes.len);
    var by_name = std.StringHashMap(i64).init(testing.allocator);
    defer by_name.deinit();
    for (nodes) |n| {
        try by_name.put(n.object.get("symbol").?.object.get("name").?.string, n.object.get("depth").?.integer);
    }
    try testing.expectEqual(@as(i64, 0), by_name.get("helper").?);
    try testing.expectEqual(@as(i64, 1), by_name.get("mid").?);
    try testing.expectEqual(@as(i64, 2), by_name.get("run").?);

    // `via` names the depth-1 neighbour each node was reached through.
    for (nodes) |n| {
        const via = n.object.get("via").?.array.items;
        if (n.object.get("depth").?.integer == 0) {
            try testing.expectEqual(@as(usize, 0), via.len);
        } else {
            try testing.expectEqual(@as(usize, 1), via.len);
        }
    }

    const summary = r.get("summary").?.object;
    try testing.expectEqual(@as(i64, 3), summary.get("symbols").?.integer);
    try testing.expectEqual(@as(i64, 2), summary.get("files").?.integer);
    try testing.expectEqual(@as(i64, 2), summary.get("maxDepth").?.integer);
    try testing.expect(!summary.get("truncated").?.bool);
    const by_depth = try depths(testing.allocator, summary);
    defer testing.allocator.free(by_depth);
    try testing.expectEqualSlices(i64, &.{ 1, 1, 1 }, by_depth);
    const by_file = summary.get("byFile").?.array.items;
    try testing.expectEqual(@as(usize, 2), by_file.len);
    // Ranked by count desc: app.zig holds mid and run.
    try testing.expectEqualStrings("app.zig", by_file[0].object.get("file").?.string);
    try testing.expectEqual(@as(i64, 2), by_file[0].object.get("count").?.integer);
}

fn depths(gpa: std.mem.Allocator, summary: std.json.ObjectMap) ![]const i64 {
    const items = summary.get("byDepth").?.array.items;
    const out = try gpa.alloc(i64, items.len);
    for (items, out) |v, *o| o.* = v.integer;
    return out;
}

test "navgraph/blast truncates at the limit and honors the callees direction" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var capped = try ts.request(22,
        \\{"jsonrpc":"2.0","id":22,"method":"navgraph/blast","params":{"symbol":"helper","depth":3,"limit":2}}
    );
    defer capped.deinit();
    const summary = (try resultOf(capped)).object.get("summary").?.object;
    try testing.expectEqual(@as(i64, 2), summary.get("symbols").?.integer);
    try testing.expect(summary.get("truncated").?.bool);

    var down = try ts.request(23,
        \\{"jsonrpc":"2.0","id":23,"method":"navgraph/blast","params":{"symbol":"run","direction":"callees","depth":3}}
    );
    defer down.deinit();
    const nodes = (try resultOf(down)).object.get("nodes").?.array.items;
    try testing.expectEqual(@as(usize, 3), nodes.len); // run -> mid -> helper
}

test "blast over a file target unions that file's definitions" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(24,
        \\{"jsonrpc":"2.0","id":24,"method":"navgraph/blast","params":{"file":"util.zig","depth":1}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    // marker and helper are both roots; mid is helper's caller at depth 1.
    try testing.expectEqual(@as(usize, 2), r.get("roots").?.array.items.len);
    try testing.expectEqual(@as(i64, 3), r.get("summary").?.object.get("symbols").?.integer);
}

test "navgraph/rescan picks up a file written outside the editor" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    try ts.tmp.?.dir.writeFile(testing.io, .{ .sub_path = "added.zig", .data = "pub fn justAdded() void {}\n" });
    var res = try ts.request(25,
        \\{"jsonrpc":"2.0","id":25,"method":"navgraph/rescan","params":{"full":true}}
    );
    defer res.deinit();
    try testing.expectEqual(@as(i64, 3), (try resultOf(res)).object.get("files").?.integer);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The rescan is announced like every other index.
    const notes = try ts.takeNotifications(arena.allocator(), "navgraph/indexed");
    try testing.expect(notes.len >= 1);
    try testing.expectEqualStrings("rescan", notes[notes.len - 1].object.get("params").?.object.get("reason").?.string);
}

test "navgraph/symbolAt names the word, its definition and its enclosing symbol" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":26,"method":"navgraph/symbolAt","params":{{"uri":"{s}","position":{{"line":8,"character":9}}}}}}
    , .{try ts.uri(arena.allocator(), "app.zig")});
    var res = try ts.request(26, body);
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqualStrings("helper", r.get("word").?.string);
    try testing.expectEqualStrings("helper", r.get("symbol").?.object.get("name").?.string);
    try testing.expectEqualStrings("util.zig", r.get("symbol").?.object.get("file").?.string);
    try testing.expectEqualStrings("mid", r.get("enclosing").?.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 0), r.get("candidates").?.array.items.len);

    // "    util.helper();" -> "helper" starts at column 9 and is 6 chars wide.
    const range = r.get("range").?.object;
    try testing.expectEqual(@as(i64, 8), range.get("start").?.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 9), range.get("start").?.object.get("character").?.integer);
    try testing.expectEqual(@as(i64, 15), range.get("end").?.object.get("character").?.integer);

    // `mid` is a top-level function: its own breadcrumb chain is just itself.
    const breadcrumbs = r.get("breadcrumbs").?.array.items;
    try testing.expectEqual(@as(usize, 1), breadcrumbs.len);
    try testing.expectEqualStrings("mid", breadcrumbs[0].object.get("name").?.string);
}

test "navgraph/symbolAt breadcrumbs walk outermost to innermost" {
    const ts = try startedPy(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "ports.py");

    // `get`'s body (line 6, 1-based -> 0-based 5, "        return key" starts
    // at column 8) sits inside `MemoryStore.get`.
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":72,"method":"navgraph/symbolAt","params":{{"uri":"{s}","position":{{"line":5,"character":8}}}}}}
    , .{uri});
    var res = try ts.request(72, body);
    defer res.deinit();
    const r = (try resultOf(res)).object;
    const breadcrumbs = r.get("breadcrumbs").?.array.items;
    try testing.expectEqual(@as(usize, 2), breadcrumbs.len);
    try testing.expectEqualStrings("MemoryStore", breadcrumbs[0].object.get("name").?.string);
    try testing.expectEqualStrings("get", breadcrumbs[1].object.get("name").?.string);
}

test "navgraph/symbolAt off whitespace answers a null range and no breadcrumbs" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "app.zig");
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":73,"method":"navgraph/symbolAt","params":{{"uri":"{s}","position":{{"line":1,"character":0}}}}}}
    , .{uri});
    var res = try ts.request(73, body);
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expect(r.get("range").? == .null);
    try testing.expectEqual(@as(usize, 0), r.get("breadcrumbs").?.array.items.len);
}

test "hover renders the signature, the location and the fan-in counts" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":27,"method":"textDocument/hover","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":3,"character":8}}}}}}
    , .{try ts.uri(arena.allocator(), "app.zig")});
    var res = try ts.request(27, body);
    defer res.deinit();
    const contents = (try resultOf(res)).object.get("contents").?.object;
    try testing.expectEqualStrings("markdown", contents.get("kind").?.string);
    const md = contents.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, md, "fn `run`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "```zig") != null);
    try testing.expect(std.mem.indexOf(u8, md, "app.zig:4-6") != null);
    try testing.expect(std.mem.indexOf(u8, md, "← 0 callers → 1 callees") != null);
    try testing.expect(std.mem.indexOf(u8, md, "Entry point.") != null);
}

test "documentSymbol reflects the file's nesting and ranges" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":28,"method":"textDocument/documentSymbol","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{try ts.uri(arena.allocator(), "app.zig")});
    var res = try ts.request(28, body);
    defer res.deinit();
    const items = (try resultOf(res)).array.items;
    // `run` and `mid`; the import is not a document symbol.
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("run", items[0].object.get("name").?.string);
    const range = items[0].object.get("range").?.object;
    try testing.expectEqual(@as(i64, 3), range.get("start").?.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 5), range.get("end").?.object.get("line").?.integer);
    const sel = items[0].object.get("selectionRange").?.object;
    try testing.expectEqual(@as(i64, 7), sel.get("start").?.object.get("character").?.integer);
}

test "workspace/symbol returns ranked SymbolInformation" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(29,
        \\{"jsonrpc":"2.0","id":29,"method":"workspace/symbol","params":{"query":"helper"}}
    );
    defer res.deinit();
    const items = (try resultOf(res)).array.items;
    try testing.expect(items.len >= 1);
    try testing.expectEqualStrings("helper", items[0].object.get("name").?.string);
    try testing.expect(items[0].object.get("location").?.object.get("uri") != null);
}

test "definition and references resolve real testenv sources" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const vm_uri = try ts.uri(alloc, "vm.zig");

    // `self.push(...)` on line 52 (0-based 51) resolves to Vm.push on line 32.
    var def = try ts.request(30, try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","id":30,"method":"textDocument/definition","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":51,"character":22}}}}}}
    , .{vm_uri}));
    defer def.deinit();
    const locs = (try resultOf(def)).array.items;
    // The graph's own choice comes first; the generic `Stack.push` and
    // `Registry.push` are the same-name candidates the editor is also offered.
    try testing.expectEqual(@as(usize, 3), locs.len);
    try testing.expectEqualStrings(vm_uri, locs[0].object.get("uri").?.string);
    try testing.expectEqual(@as(i64, 31), locs[0].object.get("range").?.object.get("start").?.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 11), locs[0].object.get("range").?.object.get("start").?.object.get("character").?.integer);

    // References from the definition site list every call, declaration included.
    var refs = try ts.request(31, try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","id":31,"method":"textDocument/references","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":31,"character":11}},"context":{{"includeDeclaration":true}}}}}}
    , .{vm_uri}));
    defer refs.deinit();
    const sites = (try resultOf(refs)).array.items;
    // Declaration plus the two call sites in `run` and `apply`. bytecode_vm's
    // `self.operands.push(...)` belongs to the generic `Stack.push`, not here.
    try testing.expectEqual(@as(usize, 3), sites.len);
    try testing.expectEqual(@as(i64, 31), sites[0].object.get("range").?.object.get("start").?.object.get("line").?.integer);

    // symbolAt on the same position names the method and its enclosing type.
    var at = try ts.request(32, try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","id":32,"method":"navgraph/symbolAt","params":{{"uri":"{s}","position":{{"line":51,"character":22}}}}}}
    , .{vm_uri}));
    defer at.deinit();
    const r = (try resultOf(at)).object;
    try testing.expectEqualStrings("push", r.get("word").?.string);
    try testing.expectEqualStrings("Vm.push", r.get("symbol").?.object.get("qualified").?.string);
    try testing.expectEqualStrings("run", r.get("enclosing").?.object.get("name").?.string);
}

test "definition returns an empty array off an identifier" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":33,"method":"textDocument/definition","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":1,"character":0}}}}}}
    , .{try ts.uri(arena.allocator(), "app.zig")});
    var res = try ts.request(33, body);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 0), (try resultOf(res)).array.items.len);
}

test "a document outside the workspace root is answered, not errored" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(34,
        \\{"jsonrpc":"2.0","id":34,"method":"textDocument/documentSymbol","params":
        \\ {"textDocument":{"uri":"file:///elsewhere/other.zig"}}}
    );
    defer res.deinit();
    try testing.expectEqual(@as(usize, 0), (try resultOf(res)).array.items.len);
}

test "shutdown then exit is a clean stop; exit alone is not" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(35,
        \\{"jsonrpc":"2.0","id":35,"method":"shutdown"}
    );
    defer res.deinit();
    try testing.expect((try resultOf(res)) == .null);
    try ts.send(
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try testing.expectEqual(@as(u8, 0), ts.server.exit_code.?);

    const bare = try started(testing.allocator);
    defer bare.deinit();
    try bare.send(
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try testing.expectEqual(@as(u8, 1), bare.server.exit_code.?);
}

test "grep sees an unsaved buffer, and forgets it after didClose" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const uri = try ts.uri(alloc, "util.zig");

    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":
        \\ {{"uri":"{s}","languageId":"zig","version":1,"text":"pub fn helper() void {{}}\nconst unsavedToken = 1;\n"}}}}}}
    , .{uri}));

    var found = try ts.request(36,
        \\{"jsonrpc":"2.0","id":36,"method":"navgraph/grep","params":{"pattern":"unsavedToken"}}
    );
    defer found.deinit();
    try testing.expectEqual(@as(usize, 1), (try resultOf(found)).object.get("items").?.array.items.len);

    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{uri}));
    var gone = try ts.request(37,
        \\{"jsonrpc":"2.0","id":37,"method":"navgraph/grep","params":{"pattern":"unsavedToken"}}
    );
    defer gone.deinit();
    try testing.expectEqual(@as(usize, 0), (try resultOf(gone)).object.get("items").?.array.items.len);
}

test "a client advertising workDoneProgress gets a progress create/begin/end" {
    const ts = try TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    try ts.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":
        \\ {"capabilities":{"window":{"workDoneProgress":true}}}}
    );
    try ts.send(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    const out = ts.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "window/workDoneProgress/create") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"begin\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"end\"") != null);
    // The indexed notification is sent whether or not progress was requested.
    try testing.expect(std.mem.indexOf(u8, out, "navgraph/indexed") != null);
}

test "a client without workDoneProgress gets no progress traffic" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    try testing.expect(std.mem.indexOf(u8, ts.out.written(), "$/progress") == null);
    try testing.expect(std.mem.indexOf(u8, ts.out.written(), "navgraph/indexed") != null);
}

test "didSave and didChangeWatchedFiles re-stat and re-index the named files" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const uri = try ts.uri(alloc, "util.zig");

    try ts.tmp.?.dir.writeFile(testing.io, .{
        .sub_path = "util.zig",
        .data = "pub const marker = \"needle-in-a-haystack\";\npub fn helper() void {}\npub fn savedLater() void {}\n",
    });
    _ = try ts.takeNotifications(alloc, "navgraph/indexed");

    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didSave","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{uri}));
    var found = try ts.request(40,
        \\{"jsonrpc":"2.0","id":40,"method":"navgraph/search","params":{"query":"savedLater"}}
    );
    defer found.deinit();
    try testing.expectEqual(@as(usize, 1), (try resultOf(found)).object.get("items").?.array.items.len);
    const notes = try ts.takeNotifications(alloc, "navgraph/indexed");
    try testing.expectEqualStrings("save", notes[0].object.get("params").?.object.get("reason").?.string);

    // The same file changed again, announced through the watched-files channel.
    try ts.tmp.?.dir.writeFile(testing.io, .{
        .sub_path = "util.zig",
        .data = "pub const marker = \"needle-in-a-haystack\";\npub fn helper() void {}\npub fn watchedLater() void {}\n",
    });
    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{{"changes":[{{"uri":"{s}","type":2}}]}}}}
    , .{uri}));
    var again = try ts.request(41,
        \\{"jsonrpc":"2.0","id":41,"method":"navgraph/search","params":{"query":"watchedLater"}}
    );
    defer again.deinit();
    try testing.expectEqual(@as(usize, 1), (try resultOf(again)).object.get("items").?.array.items.len);
}

test "navgraph/search with refs finds use sites and reports their lines" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(42,
        \\{"jsonrpc":"2.0","id":42,"method":"navgraph/search","params":{"query":"helper","refs":true}}
    );
    defer res.deinit();
    const items = (try resultOf(res)).object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    // The item is the *referencing* definition, with the use-site lines.
    try testing.expectEqualStrings("mid", items[0].object.get("symbol").?.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 9), items[0].object.get("lines").?.array.items[0].integer);
}

test "the tests scope narrows search and blast" {
    const with_tests = [_][2][]const u8{
        .{ "lib.zig", "pub fn subject() void {}\n" },
        .{
            "lib_test.zig",
            \\const lib = @import("lib.zig");
            \\test "exercises subject" {
            \\    lib.subject();
            \\}
            \\
        },
    };
    const ts = try TestServer.init(testing.allocator, testing.io, &with_tests);
    defer ts.deinit();
    try ts.start();

    var all = try ts.request(43,
        \\{"jsonrpc":"2.0","id":43,"method":"navgraph/blast","params":{"symbol":"subject","depth":1}}
    );
    defer all.deinit();
    try testing.expectEqual(@as(i64, 1), (try resultOf(all)).object.get("summary").?.object.get("tests").?.integer);

    var no_tests = try ts.request(44,
        \\{"jsonrpc":"2.0","id":44,"method":"navgraph/blast","params":{"symbol":"subject","depth":1,"tests":"without"}}
    );
    defer no_tests.deinit();
    const summary = (try resultOf(no_tests)).object.get("summary").?.object;
    try testing.expectEqual(@as(i64, 1), summary.get("symbols").?.integer); // the root alone
    try testing.expectEqual(@as(i64, 0), summary.get("tests").?.integer);
}

test "$/cancelRequest is accepted and the next request still answers" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    try ts.send(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":99}}
    );
    var res = try ts.request(45,
        \\{"jsonrpc":"2.0","id":45,"method":"navgraph/status","params":{}}
    );
    defer res.deinit();
    try testing.expect((try resultOf(res)).object.get("files") != null);
}

test "requests before initialized report a not-initialized error" {
    const ts = try TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    try ts.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    var res = try ts.request(46,
        \\{"jsonrpc":"2.0","id":46,"method":"navgraph/status","params":{}}
    );
    defer res.deinit();
    try testing.expectEqual(@as(i64, -32600), try errorCodeOf(res));
}

test "blast emits one edge per caller/callee pair, listing every call site" {
    const repeated = [_][2][]const u8{
        .{
            "app.zig",
            \\pub fn target() void {}
            \\
            \\pub fn twice() void {
            \\    target();
            \\    target();
            \\}
            \\
        },
    };
    const ts = try TestServer.init(testing.allocator, testing.io, &repeated);
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(47,
        \\{"jsonrpc":"2.0","id":47,"method":"navgraph/blast","params":{"symbol":"target","depth":1}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    const edges = r.get("edges").?.array.items;
    try testing.expectEqual(@as(usize, 1), edges.len);
    // Both call sites are on the single edge.
    const lines = try lineList(testing.allocator, edges[0].object);
    defer testing.allocator.free(lines);
    try testing.expectEqualSlices(i64, &.{ 4, 5 }, lines);
    try testing.expectEqual(@as(i64, 2), r.get("summary").?.object.get("symbols").?.integer);
}

fn lineList(gpa: std.mem.Allocator, edge: std.json.ObjectMap) ![]const i64 {
    const items = edge.get("lines").?.array.items;
    const out = try gpa.alloc(i64, items.len);
    for (items, out) |v, *o| o.* = v.integer;
    return out;
}

test "a call tree marks a symbol reached twice as recursion, not a second subtree" {
    const cyclic = [_][2][]const u8{
        .{
            "app.zig",
            \\pub fn alpha() void {
            \\    beta();
            \\}
            \\
            \\pub fn beta() void {
            \\    alpha();
            \\}
            \\
        },
    };
    const ts = try TestServer.init(testing.allocator, testing.io, &cyclic);
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(48,
        \\{"jsonrpc":"2.0","id":48,"method":"navgraph/calls","params":{"symbol":"alpha","depth":5}}
    );
    defer res.deinit();
    var node = (try resultOf(res)).object.get("root").?.object;
    // alpha -> beta -> alpha(recursion): terminates instead of unrolling to depth 5.
    var hops: usize = 0;
    while (node.get("children").?.array.items.len != 0) : (hops += 1) {
        try testing.expect(hops < 5);
        node = node.get("children").?.array.items[0].object;
    }
    try testing.expect(node.get("recursion").?.bool);
    try testing.expectEqual(@as(usize, 2), hops);
}

// ---------------------------------------------------------------------------
// The remaining navgraph/* mirrors, over the real testenv/ fixtures.
// ---------------------------------------------------------------------------

test "navgraph/neighbors reports Vm.push's caller and its lack of callees" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    // Pinned: the fixture also has the generic `Stack.push`, so a bare `push`
    // is ambiguous — the same disambiguation the CLI asks for.
    var res = try ts.request(49,
        \\{"jsonrpc":"2.0","id":49,"method":"navgraph/neighbors","params":{"symbol":"Vm.push"}}
    );
    defer res.deinit();
    const items = (try resultOf(res)).object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    const r = items[0].object;
    try testing.expectEqualStrings("push", r.get("symbol").?.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 0), r.get("callees").?.array.items.len);
    var found_run = false;
    for (r.get("callers").?.array.items) |c| {
        if (std.mem.eql(u8, c.object.get("symbol").?.object.get("name").?.string, "run")) found_run = true;
    }
    try testing.expect(found_run);
}

test "navgraph/neighbors returns an item per resolution, not just the first" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(49,
        \\{"jsonrpc":"2.0","id":49,"method":"navgraph/neighbors","params":{"symbol":"run"}}
    );
    defer res.deinit();
    const items = (try resultOf(res)).object.get("items").?.array.items;
    // `run` is defined in vm.zig, bytecode_vm.zig and tricky_zig.zig; every one
    // must appear, not just whichever the graph happens to index first.
    try testing.expectEqual(@as(usize, 3), items.len);
    for ([_][]const u8{ "vm.zig", "bytecode_vm.zig", "tricky_zig.zig" }) |want| {
        var seen = false;
        for (items) |item| {
            if (std.mem.eql(u8, item.object.get("symbol").?.object.get("file").?.string, want)) seen = true;
        }
        try testing.expect(seen);
    }
}

test "navgraph/neighbors includes a data-read callee, unlike the tree walks (F14)" {
    const ts = try TestServer.init(testing.allocator, testing.io, &.{
        .{
            "state.zig",
            \\pub var counter: i32 = 0;
            \\
            \\pub fn bump() void {
            \\    counter += 1;
            \\}
            \\
        },
    });
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(49,
        \\{"jsonrpc":"2.0","id":49,"method":"navgraph/neighbors","params":{"symbol":"bump"}}
    );
    defer res.deinit();
    const items = (try resultOf(res)).object.get("items").?.array.items;
    try testing.expectEqual(@as(usize, 1), items.len);
    var found_counter = false;
    for (items[0].object.get("callees").?.array.items) |c| {
        if (std.mem.eql(u8, c.object.get("symbol").?.object.get("name").?.string, "counter")) found_counter = true;
    }
    try testing.expect(found_counter);
}

test "navgraph/path finds the call chain from eval to push" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(50,
        \\{"jsonrpc":"2.0","id":50,"method":"navgraph/path","params":{"from":"eval","to":"Vm.push"}}
    );
    defer res.deinit();
    const ok = (try resultOf(res)).object;
    const chain = ok.get("path").?.array.items;
    try testing.expectEqual(@as(usize, 3), chain.len);
    try testing.expectEqualStrings("eval", chain[0].object.get("name").?.string);
    try testing.expectEqualStrings("run", chain[1].object.get("name").?.string);
    try testing.expectEqualStrings("push", chain[2].object.get("name").?.string);
    try testing.expectEqual(@as(usize, 0), ok.get("ambiguousTo").?.array.items.len);

    var none = try ts.request(51,
        \\{"jsonrpc":"2.0","id":51,"method":"navgraph/path","params":{"from":"no_such_symbol_xyz","to":"Vm.push"}}
    );
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), (try resultOf(none)).object.get("path").?.array.items.len);
}

test "navgraph/path names an ambiguous endpoint instead of reporting no path" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    // `Stack.push`, `Vm.push` and `Registry.push` all match; a bare `push` has
    // no unique endpoint, and answering `path: []` would be a wrong answer.
    var res = try ts.request(52,
        \\{"jsonrpc":"2.0","id":52,"method":"navgraph/path","params":{"from":"eval","to":"push"}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqual(@as(usize, 0), r.get("path").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), r.get("ambiguousFrom").?.array.items.len);
    const cands = r.get("ambiguousTo").?.array.items;
    try testing.expectEqual(@as(usize, 3), cands.len);
    for (cands) |c| try testing.expectEqualStrings("push", c.object.get("name").?.string);
}

test "navgraph/outline lists vm.zig's symbols" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(52,
        \\{"jsonrpc":"2.0","id":52,"method":"navgraph/outline","params":{"path":"vm.zig"}}
    );
    defer res.deinit();
    // The filter is a substring match, so it also picks up bytecode_vm.zig.
    const files = (try resultOf(res)).object.get("files").?.array.items;
    var vm_file: ?std.json.ObjectMap = null;
    for (files) |f| {
        if (std.mem.eql(u8, f.object.get("file").?.string, "vm.zig")) vm_file = f.object;
    }
    try testing.expect(vm_file != null);
    try testing.expectEqualStrings("zig", vm_file.?.get("lang").?.string);
    var found = false;
    for (vm_file.?.get("symbols").?.array.items) |s| {
        if (std.mem.eql(u8, s.object.get("name").?.string, "push")) found = true;
    }
    try testing.expect(found);
}

test "navgraph/outline reports truncated once the limit caps the symbol count" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    var capped = try ts.request(52,
        \\{"jsonrpc":"2.0","id":52,"method":"navgraph/outline","params":{"limit":1}}
    );
    defer capped.deinit();
    try testing.expect((try resultOf(capped)).object.get("truncated").?.bool);

    var full = try ts.request(53,
        \\{"jsonrpc":"2.0","id":53,"method":"navgraph/outline","params":{}}
    );
    defer full.deinit();
    try testing.expect(!(try resultOf(full)).object.get("truncated").?.bool);
}

test "a nested scope object is rejected instead of silently ignored (F10)" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();

    // The documented contract is `Target & Scope` — `tests`/`strict` at the
    // top level of params, not nested under a `scope` key.
    var nested = try ts.request(52,
        \\{"jsonrpc":"2.0","id":52,"method":"navgraph/outline","params":{"scope":{"tests":"only"}}}
    );
    defer nested.deinit();
    try testing.expectEqual(@as(i64, -32602), try errorCodeOf(nested));

    // The correctly-shaped, top-level form still works and is honored: the
    // fixture has no test symbols, so `tests: only` finds none.
    var top_level = try ts.request(53,
        \\{"jsonrpc":"2.0","id":53,"method":"navgraph/outline","params":{"tests":"only"}}
    );
    defer top_level.deinit();
    const files = (try resultOf(top_level)).object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 0), files.len);
}

test "navgraph/hot ranks tokenize above the leaf push/pop methods" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(53,
        \\{"jsonrpc":"2.0","id":53,"method":"navgraph/hot","params":{}}
    );
    defer res.deinit();
    const items = (try resultOf(res)).object.get("items").?.array.items;
    try testing.expect(items.len > 0);
    try testing.expectEqualStrings("tokenize", items[0].object.get("symbol").?.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 4), items[0].object.get("fanIn").?.integer);
    try testing.expectEqual(@as(i64, 4), items[0].object.get("fanInExact").?.integer);
}

test "navgraph/hot honors an explicit limit at 300, unlike the CLI's sentinel default (F9)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 30 functions each calling a shared `common`, so every one of them (plus
    // `common` itself) has fan_out/fan_in > 0 and is a `hot` candidate.
    var src: Writer.Allocating = .init(alloc);
    try src.writer.writeAll("pub fn common() void {}\n");
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        try src.writer.print("pub fn f{d}() void {{ common(); }}\n", .{i});
    }
    const files = [_][2][]const u8{.{ "many.zig", src.written() }};

    const ts = try TestServer.init(testing.allocator, testing.io, &files);
    defer ts.deinit();
    try ts.start();

    // The CLI treats an explicit `-l 300` as its own unset-default sentinel
    // and silently falls back to 25; the adapter has no such sentinel.
    var res = try ts.request(53,
        \\{"jsonrpc":"2.0","id":53,"method":"navgraph/hot","params":{"limit":300}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    const items = r.get("items").?.array.items;
    try testing.expect(items.len > 25);
    try testing.expect(!r.get("truncated").?.bool);

    var capped = try ts.request(54,
        \\{"jsonrpc":"2.0","id":54,"method":"navgraph/hot","params":{"limit":5}}
    );
    defer capped.deinit();
    try testing.expect((try resultOf(capped)).object.get("truncated").?.bool);
}

test "navgraph/unused finds stack.zig's private, uncalled growHint" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(54,
        \\{"jsonrpc":"2.0","id":54,"method":"navgraph/unused","params":{}}
    );
    defer res.deinit();
    const items = (try resultOf(res)).object.get("items").?.array.items;
    var found = false;
    for (items) |it| {
        const sym = it.object.get("symbol").?.object;
        if (std.mem.eql(u8, sym.get("name").?.string, "growHint")) {
            try testing.expectEqualStrings("stack.zig", sym.get("file").?.string);
            found = true;
        }
    }
    try testing.expect(found);
}

test "navgraph/diff reports the roots of an unsaved overlay edit, wrapping blast" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const app_uri = try ts.uri(alloc, "app.zig");

    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":
        \\ {{"uri":"{s}","languageId":"zig","version":1,"text":"const util = @import(\"util.zig\");\npub fn run() void {{\n    mid();\n}}\nfn mid() void {{\n    util.helper();\n}}\nfn added() void {{}}\n"}}}}}}
    , .{app_uri}));

    var res = try ts.request(49,
        \\{"jsonrpc":"2.0","id":49,"method":"navgraph/diff","params":{}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqualStrings("HEAD", r.get("ref").?.string);
    const blast_result = r.get("blast").?.object;
    const roots = blast_result.get("roots").?.array.items;
    // Every non-import definition in the edited file becomes a root: an overlay
    // diff (unlike a git diff) has no hunk-level range, so the whole file counts.
    try testing.expect(roots.len >= 3);
    var found = false;
    for (roots) |root| {
        if (std.mem.eql(u8, root.object.get("name").?.string, "added")) found = true;
    }
    try testing.expect(found);
}

test "navgraph/diff misses a new untracked file, matching the CLI's own gap (F12, documented limitation)" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    try ts.tmp.?.dir.writeFile(testing.io, .{ .sub_path = "brandnew.zig", .data = "pub fn brandNewFn() void {}\n" });
    var rescan_res = try ts.request(25,
        \\{"jsonrpc":"2.0","id":25,"method":"navgraph/rescan","params":{"full":true}}
    );
    rescan_res.deinit();

    // git diff never lists an untracked path, and the overlay half only
    // catches an *unsaved* edit — this file is already on disk, unopened, so
    // neither half sees it. Documented at docs/lsp.md's Limitations.
    var res = try ts.request(49,
        \\{"jsonrpc":"2.0","id":49,"method":"navgraph/diff","params":{}}
    );
    defer res.deinit();
    const roots = (try resultOf(res)).object.get("blast").?.object.get("roots").?.array.items;
    for (roots) |root| {
        try testing.expect(!std.mem.eql(u8, root.object.get("name").?.string, "brandNewFn"));
    }
}

test "navgraph/diff on a ref git rejects is a git-failed error, not an empty change set" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(49,
        \\{"jsonrpc":"2.0","id":49,"method":"navgraph/diff","params":{"ref":"no-such-ref-xyz"}}
    );
    defer res.deinit();
    try testing.expectEqual(@as(i64, -32002), try errorCodeOf(res));
    const message = res.value.object.get("error").?.object.get("message").?.string;
    try testing.expect(std.mem.indexOf(u8, message, "no-such-ref-xyz") != null);
}

const impact_disk = "pub fn run() void {}\npub fn mid() void {}\n";
const impact_project = [_][2][]const u8{.{ "app.zig", impact_disk }};

test "navgraph/impact reports an empty change as all zeros, not an error" {
    const ts = try TestServer.init(testing.allocator, testing.io, &impact_project);
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(79,
        \\{"jsonrpc":"2.0","id":79,"method":"navgraph/impact","params":{}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqual(@as(usize, 0), r.get("roots").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), r.get("nodes").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), r.get("edges").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), r.get("hunks").?.array.items.len);
    try testing.expectEqual(@as(i64, 0), r.get("summary").?.object.get("symbols").?.integer);
}

test "navgraph/impact groups the working change into a hunk and blasts from its roots" {
    const ts = try TestServer.init(testing.allocator, testing.io, &impact_project);
    defer ts.deinit();
    try ts.start();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const uri = try ts.uri(alloc, "app.zig");

    // Same bytes as `impact_disk`, plus one appended function -> a single
    // hunk anchored at the new line (`index.computeEdit`'s common-prefix trim).
    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":
        \\ {{"uri":"{s}","languageId":"zig","version":1,"text":"pub fn run() void {{}}\npub fn mid() void {{}}\npub fn added() void {{ mid(); }}\n"}}}}}}
    , .{uri}));

    var res = try ts.request(80,
        \\{"jsonrpc":"2.0","id":80,"method":"navgraph/impact","params":{}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;

    const hunks = r.get("hunks").?.array.items;
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expect(std.mem.endsWith(u8, hunks[0].object.get("uri").?.string, "app.zig"));
    var saw_added_in_hunk = false;
    for (hunks[0].object.get("roots").?.array.items) |root| {
        if (std.mem.eql(u8, root.object.get("name").?.string, "added")) saw_added_in_hunk = true;
    }
    try testing.expect(saw_added_in_hunk);

    var saw_added_root = false;
    for (r.get("roots").?.array.items) |root| {
        if (std.mem.eql(u8, root.object.get("name").?.string, "added")) saw_added_root = true;
    }
    try testing.expect(saw_added_root);
    try testing.expect(r.get("changeId").?.string.len > 0);
}

test "navgraph/impact narrows to the named uri when several documents changed" {
    const ts = try TestServer.init(testing.allocator, testing.io, &project);
    defer ts.deinit();
    try ts.start();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const app_uri = try ts.uri(alloc, "app.zig");
    const util_uri = try ts.uri(alloc, "util.zig");

    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":
        \\ {{"uri":"{s}","languageId":"zig","version":1,"text":"const util = @import(\"util.zig\");\npub fn run() void {{\n    mid();\n}}\nfn mid() void {{\n    util.helper();\n}}\nfn extra() void {{}}\n"}}}}}}
    , .{app_uri}));
    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":
        \\ {{"uri":"{s}","languageId":"zig","version":1,"text":"pub const marker = \"needle-in-a-haystack\";\npub fn helper() void {{}}\npub fn extraUtil() void {{}}\n"}}}}}}
    , .{util_uri}));

    const body = try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","id":81,"method":"navgraph/impact","params":{{"uri":"{s}"}}}}
    , .{util_uri});
    var res = try ts.request(81, body);
    defer res.deinit();
    const hunks = (try resultOf(res)).object.get("hunks").?.array.items;
    try testing.expectEqual(@as(usize, 1), hunks.len);
    try testing.expect(std.mem.endsWith(u8, hunks[0].object.get("uri").?.string, "util.zig"));
}

test "navgraph/context reports the definition, callers, callees and a token estimate" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(82,
        \\{"jsonrpc":"2.0","id":82,"method":"navgraph/context","params":{"symbol":"mid"}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqualStrings("mid", r.get("symbol").?.object.get("name").?.string);
    try testing.expect(std.mem.indexOf(u8, r.get("definition").?.object.get("text").?.string, "util.helper()") != null);
    try testing.expect(std.mem.indexOf(u8, r.get("signature").?.string, "fn mid") != null);

    const callers = r.get("callers").?.array.items;
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqualStrings("run", callers[0].object.get("name").?.string);

    const callees = r.get("callees").?.array.items;
    try testing.expectEqual(@as(usize, 1), callees.len);
    try testing.expectEqualStrings("helper", callees[0].object.get("name").?.string);

    try testing.expectEqual(@as(usize, 0), r.get("tests").?.array.items.len);
    try testing.expect(!r.get("truncated").?.bool);
    try testing.expect(r.get("tokensEstimate").?.integer > 0);
}

test "navgraph/context drops sections in order under a tight budget, but never callers" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(83,
        \\{"jsonrpc":"2.0","id":83,"method":"navgraph/context","params":{"symbol":"mid","budget":1}}
    );
    defer res.deinit();
    const r = (try resultOf(res)).object;
    // The body drops first: `definition.text` falls back to the bare signature.
    try testing.expect(std.mem.indexOf(u8, r.get("definition").?.object.get("text").?.string, "util.helper()") == null);
    try testing.expectEqual(@as(usize, 0), r.get("callees").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), r.get("types").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), r.get("tests").?.array.items.len);
    try testing.expectEqual(@as(usize, 1), r.get("callers").?.array.items.len);
    try testing.expect(r.get("truncated").?.bool);
}

test "navgraph/context on an unresolved symbol is a symbol-not-found error" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(84,
        \\{"jsonrpc":"2.0","id":84,"method":"navgraph/context","params":{"symbol":"nope_xyz"}}
    );
    defer res.deinit();
    try testing.expectEqual(@as(i64, -32001), try errorCodeOf(res));
}

test "navgraph/where resolves the enclosing symbol and its breadcrumb chain" {
    const ts = try startedPy(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "ports.py");

    // Line 6 (1-based) is `MemoryStore.get`'s body ("return key").
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":85,"method":"navgraph/where","params":{{"uri":"{s}","line":6}}}}
    , .{uri});
    var res = try ts.request(85, body);
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expectEqualStrings("get", r.get("enclosing").?.object.get("name").?.string);
    try testing.expectEqualStrings("ports.py", r.get("file").?.string);
    const breadcrumbs = r.get("breadcrumbs").?.array.items;
    try testing.expectEqual(@as(usize, 2), breadcrumbs.len);
    try testing.expectEqualStrings("MemoryStore", breadcrumbs[0].object.get("name").?.string);
    try testing.expectEqualStrings("get", breadcrumbs[1].object.get("name").?.string);
}

test "navgraph/where off any definition answers null, and a missing line is rejected" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uri = try ts.uri(arena.allocator(), "app.zig");

    // Line 2 (1-based) is blank, outside every definition's span.
    const body = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":86,"method":"navgraph/where","params":{{"uri":"{s}","line":2}}}}
    , .{uri});
    var res = try ts.request(86, body);
    defer res.deinit();
    const r = (try resultOf(res)).object;
    try testing.expect(r.get("enclosing").? == .null);
    try testing.expectEqual(@as(usize, 0), r.get("breadcrumbs").?.array.items.len);

    const missing_line = try std.fmt.allocPrint(arena.allocator(),
        \\{{"jsonrpc":"2.0","id":87,"method":"navgraph/where","params":{{"uri":"{s}"}}}}
    , .{uri});
    var bad = try ts.request(87, missing_line);
    defer bad.deinit();
    try testing.expectEqual(@as(i64, -32602), try errorCodeOf(bad));
}

test "navgraph/routes maps an HTTP route to its handler and its client caller" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/fullstack");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(55,
        \\{"jsonrpc":"2.0","id":55,"method":"navgraph/routes","params":{}}
    );
    defer res.deinit();
    const items = (try resultOf(res)).object.get("items").?.array.items;
    var route: ?std.json.ObjectMap = null;
    for (items) |it| {
        if (std.mem.eql(u8, it.object.get("symbol").?.object.get("name").?.string, "GET /api/orders")) {
            route = it.object;
        }
    }
    try testing.expect(route != null);
    const handler = route.?.get("handler").?.object;
    try testing.expectEqualStrings("list_orders", handler.get("name").?.string);
    var found = false;
    for (route.?.get("callers").?.array.items) |c| {
        if (std.mem.eql(u8, c.object.get("name").?.string, "listOrders")) found = true;
    }
    try testing.expect(found);
}

test "navgraph/events pairs the backend handler with the frontend emitter" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/fullstack");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(56,
        \\{"jsonrpc":"2.0","id":56,"method":"navgraph/events","params":{"filter":"order_placed"}}
    );
    defer res.deinit();
    const groups = (try resultOf(res)).object.get("groups").?.array.items;
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqualStrings("order_placed", groups[0].object.get("key").?.string);
    const sites = groups[0].object.get("sites").?.array.items;
    try testing.expectEqual(@as(usize, 2), sites.len);
    var saw_handler = false;
    var saw_emitter = false;
    for (sites) |s| {
        const role = s.object.get("role").?.string;
        if (std.mem.eql(u8, role, "handler")) saw_handler = true;
        if (std.mem.eql(u8, role, "emitter")) saw_emitter = true;
    }
    try testing.expect(saw_handler and saw_emitter);
}

test "navgraph/imports lists app.py's local module imports" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/fullstack");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(57,
        \\{"jsonrpc":"2.0","id":57,"method":"navgraph/imports","params":{"path":"app.py"}}
    );
    defer res.deinit();
    const files = (try resultOf(res)).object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("backend/app.py", files[0].object.get("file").?.string);
    const imps = files[0].object.get("imports").?.array.items;
    var found = false;
    for (imps) |i| {
        if (std.mem.eql(u8, i.object.get("target").?.string, "backend/store.py")) found = true;
    }
    try testing.expect(found);
}

test "navgraph/imports honors an explicit limit on the number of files listed (F13)" {
    const ts = try TestServer.init(testing.allocator, testing.io, &.{
        .{ "shared.zig", "pub fn helper() void {}\n" },
        .{ "a.zig", "const shared = @import(\"shared.zig\");\npub fn useA() void { shared.helper(); }\n" },
        .{ "b.zig", "const shared = @import(\"shared.zig\");\npub fn useB() void { shared.helper(); }\n" },
    });
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(57,
        \\{"jsonrpc":"2.0","id":57,"method":"navgraph/imports","params":{"limit":1}}
    );
    defer res.deinit();
    const files = (try resultOf(res)).object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
}

test "navgraph/importers lists a file once even with two import edges to the same target (F13)" {
    const ts = try TestServer.init(testing.allocator, testing.io, &.{
        .{ "mod.py", "def helper():\n    pass\n" },
        .{
            "user.py",
            \\from mod import helper
            \\from mod import helper as h2
            \\
            \\def use():
            \\    helper()
            \\    h2()
            \\
            ,
        },
    });
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(58,
        \\{"jsonrpc":"2.0","id":58,"method":"navgraph/importers","params":{"path":"mod.py"}}
    );
    defer res.deinit();
    const files = (try resultOf(res)).object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    const importers = files[0].object.get("importers").?.array.items;
    try testing.expectEqual(@as(usize, 1), importers.len);
    try testing.expectEqualStrings("user.py", importers[0].object.get("file").?.string);
}

test "navgraph/importers lists store.py's reverse dependencies" {
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/fullstack");
    defer ts.deinit();
    try ts.start();
    var res = try ts.request(58,
        \\{"jsonrpc":"2.0","id":58,"method":"navgraph/importers","params":{"path":"store.py"}}
    );
    defer res.deinit();
    const files = (try resultOf(res)).object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("backend/store.py", files[0].object.get("file").?.string);
    var found = false;
    for (files[0].object.get("importers").?.array.items) |imp| {
        if (std.mem.eql(u8, imp.object.get("file").?.string, "backend/app.py")) found = true;
    }
    try testing.expect(found);

    var missing = try ts.request(59,
        \\{"jsonrpc":"2.0","id":59,"method":"navgraph/importers","params":{}}
    );
    defer missing.deinit();
    try testing.expectEqual(@as(i64, -32602), try errorCodeOf(missing));
}

test "navgraph/importers honors an explicit limit and reports truncated" {
    const ts = try TestServer.init(testing.allocator, testing.io, &.{
        .{ "shared.zig", "pub fn helper() void {}\n" },
        .{ "a.zig", "const shared = @import(\"shared.zig\");\npub fn useA() void { shared.helper(); }\n" },
        .{ "b.zig", "const shared = @import(\"shared.zig\");\npub fn useB() void { shared.helper(); }\n" },
    });
    defer ts.deinit();
    try ts.start();

    // `path:".zig"` matches all 3 files; the *files listed* cap applies
    // across all of them regardless of whether each one has an importer.
    var capped = try ts.request(88,
        \\{"jsonrpc":"2.0","id":88,"method":"navgraph/importers","params":{"path":".zig","limit":1}}
    );
    defer capped.deinit();
    const capped_r = (try resultOf(capped)).object;
    try testing.expectEqual(@as(usize, 1), capped_r.get("files").?.array.items.len);
    try testing.expect(capped_r.get("truncated").?.bool);

    var full = try ts.request(89,
        \\{"jsonrpc":"2.0","id":89,"method":"navgraph/importers","params":{"path":".zig"}}
    );
    defer full.deinit();
    const full_r = (try resultOf(full)).object;
    try testing.expectEqual(@as(usize, 3), full_r.get("files").?.array.items.len);
    try testing.expect(!full_r.get("truncated").?.bool);
}

test "navgraph/graph writes an HTML file under .navgraph and returns its path" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var res = try ts.request(60,
        \\{"jsonrpc":"2.0","id":60,"method":"navgraph/graph","params":{}}
    );
    defer res.deinit();
    const path = (try resultOf(res)).object.get("path").?.string;
    try testing.expect(std.mem.startsWith(u8, path, ".navgraph/graph-"));
    try testing.expect(std.mem.endsWith(u8, path, ".html"));
    const st = try ts.server.session.?.root_dir.statFile(ts.server.io, path, .{});
    try testing.expect(st.size > 0);
}

test "navgraph/graph replaces a symlink planted at the guessed path instead of writing through it" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    const root_dir = ts.server.session.?.root_dir;
    const io = ts.server.io;

    var first = try ts.request(60,
        \\{"jsonrpc":"2.0","id":60,"method":"navgraph/graph","params":{}}
    );
    const path = try testing.allocator.dupe(u8, (try resultOf(first)).object.get("path").?.string);
    first.deinit();
    defer testing.allocator.free(path);

    // Plant a symlink at the exact path the next request will guess (the view
    // is unchanged, so the hash — and the path — repeat), pointing at a
    // victim file outside `.navgraph/`.
    try root_dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "PRECIOUS-ORIGINAL-CONTENT" });
    try root_dir.deleteFile(io, path);
    try root_dir.symLink(io, "../victim.txt", path, .{});

    var second = try ts.request(61,
        \\{"jsonrpc":"2.0","id":61,"method":"navgraph/graph","params":{}}
    );
    defer second.deinit();
    const path2 = (try resultOf(second)).object.get("path").?.string;
    try testing.expectEqualStrings(path, path2);

    var buf: [64]u8 = undefined;
    const victim = try root_dir.readFile(io, "victim.txt", &buf);
    try testing.expectEqualStrings("PRECIOUS-ORIGINAL-CONTENT", victim);

    const st = try root_dir.statFile(io, path, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.file, st.kind);
    try testing.expect(st.size > 0);
}

test "navgraph/graph overwrites its one file per view instead of accumulating one per edit" {
    const ts = try started(testing.allocator);
    defer ts.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const app_uri = try ts.uri(alloc, "app.zig");

    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":
        \\ {{"uri":"{s}","languageId":"zig","version":1,"text":"pub fn run() void {{}}\n"}}}}}}
    , .{app_uri}));

    var first = try ts.request(60,
        \\{"jsonrpc":"2.0","id":60,"method":"navgraph/graph","params":{}}
    );
    const path1 = try testing.allocator.dupe(u8, (try resultOf(first)).object.get("path").?.string);
    first.deinit();
    defer testing.allocator.free(path1);

    try ts.send(try std.fmt.allocPrint(alloc,
        \\{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":
        \\ {{"uri":"{s}","version":2}},"contentChanges":[{{"text":"pub fn run() void {{}}\npub fn added() void {{}}\n"}}]}}}}
    , .{app_uri}));

    var second = try ts.request(61,
        \\{"jsonrpc":"2.0","id":61,"method":"navgraph/graph","params":{}}
    );
    defer second.deinit();
    const path2 = (try resultOf(second)).object.get("path").?.string;
    // Same view (no filter, same test scope) after an edit: same file, not a
    // second one — the edit changed the rendered bytes but not the view.
    try testing.expectEqualStrings(path1, path2);

    var navgraph_dir = try ts.server.session.?.root_dir.openDir(ts.server.io, ".navgraph", .{ .iterate = true });
    defer navgraph_dir.close(ts.server.io);
    var count: u32 = 0;
    var it = navgraph_dir.iterate();
    while (try it.next(ts.server.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "graph-")) count += 1;
    }
    try testing.expectEqual(@as(u32, 1), count);
}

// ---------------------------------------------------------------------------
// Golden parity harness (F15) — for each mirrored method, the adapter and the
// CLI's `-j` output over the same fixture must agree on membership and
// ordering. Building the CLI's Index directly (rather than shelling out) so
// the two sides can be compared as parsed JSON in one process.
// ---------------------------------------------------------------------------

fn namesFlat(alloc: std.mem.Allocator, arr: []const std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (arr) |v| try out.append(alloc, v.object.get("name").?.string);
    return out.toOwnedSlice(alloc);
}

fn namesNested(alloc: std.mem.Allocator, arr: []const std.json.Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (arr) |v| try out.append(alloc, v.object.get("symbol").?.object.get("name").?.string);
    return out.toOwnedSlice(alloc);
}

fn expectSameOrder(a: []const []const u8, b: []const []const u8) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqualStrings(x, y);
}

test "golden parity: outline/unused/hot/path/neighbors agree with the CLI's -j output (testenv/zig_vm)" {
    var idx = try index_mod.build(testing.allocator, testing.io, "testenv/zig_vm", false, .auto);
    defer idx.deinit();
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/zig_vm");
    defer ts.deinit();
    try ts.start();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // outline: flatten (file, symbol name) pairs so file grouping and
    // per-file symbol order are both checked in one comparison.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.outline(&cli_out.writer, &idx, "", .{ .format = .json });
        const cli_parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{});
        var cli_flat: std.ArrayList([]const u8) = .empty;
        for (cli_parsed.array.items) |file| {
            const path = file.object.get("path").?.string;
            for (file.object.get("symbols").?.array.items) |sym| {
                try cli_flat.append(alloc, try std.fmt.allocPrint(alloc, "{s}::{s}", .{ path, sym.object.get("name").?.string }));
            }
        }

        var res = try ts.request(1001,
            \\{"jsonrpc":"2.0","id":1001,"method":"navgraph/outline","params":{}}
        );
        defer res.deinit();
        var lsp_flat: std.ArrayList([]const u8) = .empty;
        for ((try resultOf(res)).object.get("files").?.array.items) |file| {
            const path = file.object.get("file").?.string;
            for (file.object.get("symbols").?.array.items) |sym| {
                const name = sym.object.get("name").?.string;
                try lsp_flat.append(alloc, try std.fmt.allocPrint(alloc, "{s}::{s}", .{ path, name }));
            }
        }
        try expectSameOrder(cli_flat.items, lsp_flat.items);
    }

    // unused: flat array, both sides.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.unused(&cli_out.writer, &idx, "", .{ .format = .json });
        const cli_names = try namesFlat(alloc, (try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).array.items);

        var res = try ts.request(1002,
            \\{"jsonrpc":"2.0","id":1002,"method":"navgraph/unused","params":{}}
        );
        defer res.deinit();
        const lsp_names = try namesNested(alloc, (try resultOf(res)).object.get("items").?.array.items);
        try expectSameOrder(cli_names, lsp_names);
    }

    // hot: flat array, default limit both sides (25), same rank ordering.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.hot(&cli_out.writer, &idx, "", .{ .format = .json });
        const cli_names = try namesFlat(alloc, (try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).array.items);

        var res = try ts.request(1003,
            \\{"jsonrpc":"2.0","id":1003,"method":"navgraph/hot","params":{}}
        );
        defer res.deinit();
        const lsp_names = try namesNested(alloc, (try resultOf(res)).object.get("items").?.array.items);
        try expectSameOrder(cli_names, lsp_names);
    }

    // path: eval -> Vm.push. Pinned because the fixture also holds the generic
    // `Stack.push`; both sides refuse to walk an ambiguous endpoint, and the
    // block below checks they refuse it the same way.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.shortestPath(&cli_out.writer, &idx, "eval", "Vm.push", .{ .format = .json });
        const cli_names = try namesFlat(alloc, (try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).array.items);

        var res = try ts.request(1004,
            \\{"jsonrpc":"2.0","id":1004,"method":"navgraph/path","params":{"from":"eval","to":"Vm.push"}}
        );
        defer res.deinit();
        const lsp_names = try namesFlat(alloc, (try resultOf(res)).object.get("path").?.array.items);
        try expectSameOrder(cli_names, lsp_names);
    }

    // path with an ambiguous endpoint: neither side answers "no path" — the
    // CLI reports `ambiguous` with `candidates`, the adapter `ambiguousTo`.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.shortestPath(&cli_out.writer, &idx, "eval", "push", .{ .format = .json });
        const cli = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).object;
        try testing.expect(cli.get("ambiguous").?.bool);
        const cli_names = try namesFlat(alloc, cli.get("candidates").?.array.items);

        var res = try ts.request(1006,
            \\{"jsonrpc":"2.0","id":1006,"method":"navgraph/path","params":{"from":"eval","to":"push"}}
        );
        defer res.deinit();
        const r = (try resultOf(res)).object;
        try testing.expectEqual(@as(usize, 0), r.get("path").?.array.items.len);
        const lsp_names = try namesFlat(alloc, r.get("ambiguousTo").?.array.items);
        try expectSameOrder(cli_names, lsp_names);
    }

    // neighbors: pinned for the same reason; the CLI's per-name array and the
    // adapter's items array then line up 1:1.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.neighbors(&cli_out.writer, &idx, "Vm.push", .{ .format = .json });
        const cli_items = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).array.items;
        try testing.expectEqual(@as(usize, 1), cli_items.len);
        const cli_callees = try namesFlat(alloc, cli_items[0].object.get("callees").?.array.items);
        const cli_callers = try namesFlat(alloc, cli_items[0].object.get("callers").?.array.items);

        var res = try ts.request(1005,
            \\{"jsonrpc":"2.0","id":1005,"method":"navgraph/neighbors","params":{"symbol":"Vm.push"}}
        );
        defer res.deinit();
        const lsp_items = (try resultOf(res)).object.get("items").?.array.items;
        try testing.expectEqual(@as(usize, 1), lsp_items.len);
        const lsp_callees = try namesNested(alloc, lsp_items[0].object.get("callees").?.array.items);
        const lsp_callers = try namesNested(alloc, lsp_items[0].object.get("callers").?.array.items);
        try expectSameOrder(cli_callees, lsp_callees);
        try expectSameOrder(cli_callers, lsp_callers);
    }
}

test "golden parity: routes/events/imports/importers agree with the CLI's -j output (testenv/fullstack)" {
    var idx = try index_mod.build(testing.allocator, testing.io, "testenv/fullstack", false, .auto);
    defer idx.deinit();
    const ts = try TestServer.initAt(testing.allocator, testing.io, "testenv/fullstack");
    defer ts.deinit();
    try ts.start();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // routes: CLI's own identity field is "route" (the symbol's name).
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.listRoutes(&cli_out.writer, &idx, "", .{ .format = .json });
        var cli_names: std.ArrayList([]const u8) = .empty;
        for ((try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).array.items) |v| {
            try cli_names.append(alloc, v.object.get("route").?.string);
        }

        var res = try ts.request(1006,
            \\{"jsonrpc":"2.0","id":1006,"method":"navgraph/routes","params":{}}
        );
        defer res.deinit();
        const lsp_names = try namesNested(alloc, (try resultOf(res)).object.get("items").?.array.items);
        try expectSameOrder(cli_names.items, lsp_names);
    }

    // events: both sides group by "key", key-sorted with paired keys first.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.events(&cli_out.writer, &idx, "", .{ .format = .json });
        var cli_keys: std.ArrayList([]const u8) = .empty;
        for ((try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).array.items) |v| {
            try cli_keys.append(alloc, v.object.get("key").?.string);
        }

        var res = try ts.request(1007,
            \\{"jsonrpc":"2.0","id":1007,"method":"navgraph/events","params":{}}
        );
        defer res.deinit();
        var lsp_keys: std.ArrayList([]const u8) = .empty;
        for ((try resultOf(res)).object.get("groups").?.array.items) |v| {
            try lsp_keys.append(alloc, v.object.get("key").?.string);
        }
        try expectSameOrder(cli_keys.items, lsp_keys.items);
    }

    // imports: flatten (file, target) pairs.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.listImports(&cli_out.writer, &idx, "", .{ .format = .json });
        var cli_flat: std.ArrayList([]const u8) = .empty;
        for ((try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).array.items) |file| {
            const path = file.object.get("file").?.string;
            for (file.object.get("imports").?.array.items) |imp| {
                try cli_flat.append(alloc, try std.fmt.allocPrint(alloc, "{s}->{s}", .{ path, imp.object.get("target").?.string }));
            }
        }

        var res = try ts.request(1008,
            \\{"jsonrpc":"2.0","id":1008,"method":"navgraph/imports","params":{}}
        );
        defer res.deinit();
        var lsp_flat: std.ArrayList([]const u8) = .empty;
        for ((try resultOf(res)).object.get("files").?.array.items) |file| {
            const path = file.object.get("file").?.string;
            for (file.object.get("imports").?.array.items) |imp| {
                try lsp_flat.append(alloc, try std.fmt.allocPrint(alloc, "{s}->{s}", .{ path, imp.object.get("target").?.string }));
            }
        }
        try expectSameOrder(cli_flat.items, lsp_flat.items);
    }

    // importers: CLI's per-file list is bare path strings, the adapter's is
    // {file,uri} objects — extract the path both ways and flatten.
    {
        var cli_out: Writer.Allocating = .init(alloc);
        _ = try json_out.listImporters(&cli_out.writer, &idx, "store.py", .{ .format = .json });
        var cli_flat: std.ArrayList([]const u8) = .empty;
        for ((try std.json.parseFromSliceLeaky(std.json.Value, alloc, cli_out.written(), .{})).array.items) |file| {
            const path = file.object.get("file").?.string;
            for (file.object.get("importers").?.array.items) |imp| {
                try cli_flat.append(alloc, try std.fmt.allocPrint(alloc, "{s}<-{s}", .{ path, imp.string }));
            }
        }

        var res = try ts.request(1009,
            \\{"jsonrpc":"2.0","id":1009,"method":"navgraph/importers","params":{"path":"store.py"}}
        );
        defer res.deinit();
        var lsp_flat: std.ArrayList([]const u8) = .empty;
        for ((try resultOf(res)).object.get("files").?.array.items) |file| {
            const path = file.object.get("file").?.string;
            for (file.object.get("importers").?.array.items) |imp| {
                try lsp_flat.append(alloc, try std.fmt.allocPrint(alloc, "{s}<-{s}", .{ path, imp.object.get("file").?.string }));
            }
        }
        try expectSameOrder(cli_flat.items, lsp_flat.items);
    }
}
