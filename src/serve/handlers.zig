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
const model = @import("../model.zig");
const query = @import("../query.zig");
const overlay = @import("overlay.zig");
const payload = @import("payload.zig");
const position = @import("position.zig");
const queries = @import("queries.zig");
const regex = @import("regex.zig");
const rpc = @import("rpc.zig");
const search = @import("search.zig");
const session_mod = @import("session.zig");

const Writer = std.Io.Writer;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

pub const protocol_version = 1;
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

/// The failures `mapError` gives a contract-defined code.
pub const Named = error{
    InvalidParams,
    MethodNotFound,
    SymbolNotFound,
    FileNotIndexed,
    BadPattern,
    RegexTooComplex,
    NotInitialized,
};

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
    cfg: session_mod.Config,
    encoding: position.Encoding,
    session: ?session_mod.Session,
    client_progress: bool,
    shutdown_requested: bool,
    /// Set when `exit` was received; the run loop stops and returns this code.
    exit_code: ?u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, out: *Writer, log: Log, cli_root: []const u8) Server {
        return .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .log = log,
            .cli_root = cli_root,
            .root = &.{},
            .cfg = .{},
            .encoding = .utf16,
            .session = null,
            .client_progress = false,
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
        var msg: Writer.Allocating = .init(arena);
        defer msg.deinit();
        try msg.writer.print("{s}: {s}", .{ method, mapped.message });
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
        error.InvalidGitPath => .{ .code = .request_failed, .message = "git reported an unusable diff path" },
        error.RegexTooComplex => .{ .code = .request_failed, .message = "regex too complex" },
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

    fn int(self: Params, key: []const u8, fallback: i64) i64 {
        const v = self.get(key) orelse return fallback;
        return switch (v) {
            .integer => |n| n,
            .float => |f| @intFromFloat(f),
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

    fn positive(self: Params, key: []const u8, fallback: u32) u32 {
        const n = self.int(key, fallback);
        if (n <= 0) return fallback;
        return @intCast(@min(n, std.math.maxInt(u32)));
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

fn positionOf(p: Params) Error!position.Position {
    const pos = p.nested("position");
    if (pos.obj == null) return error.InvalidParams;
    return .{
        .line = @intCast(@max(pos.int("line", 0), 0)),
        .character = @intCast(@max(pos.int("character", 0), 0)),
    };
}

fn scopeOf(self: *Server, p: Params) queries.Scope {
    var scope = queries.Scope.fromConfig(self.cfg);
    scope.strict = p.boolean("strict", scope.strict);
    if (p.str("tests")) |t| {
        if (query.TestScope.parse(t)) |ts| scope.tests = ts;
    }
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
            "\"experimental\":{{\"navgraph\":{{\"protocolVersion\":{d},\"methods\":[",
        .{ self.encoding.name(), protocol_version },
    );
    var first = true;
    for (navgraph_methods) |name| {
        if (!first) try w.writeByte(',');
        first = false;
        try payload.writeString(w, name);
    }
    try w.print("]}}}}}},\"serverInfo\":{{\"name\":\"navgraph\",\"version\":\"{s}\"}}}}", .{version});
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
    self.cfg.debounce_ms = opts.positive("debounceMs", self.cfg.debounce_ms);
    self.cfg.watch = opts.boolean("watch", self.cfg.watch);
    self.cfg.watch_interval_ms = opts.positive("watchIntervalMs", self.cfg.watch_interval_ms);
    self.cfg.depth = @min(opts.positive("depth", self.cfg.depth), session_mod.Config.max_depth);
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
    self.session = session_mod.Session.init(self.gpa, self.io, self.root, self.cfg) catch |err| {
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
    try writeReferenceLocations(w, arena, c, located.symbol, include_decl);
}

fn writeReferenceLocations(
    w: *Writer,
    gpa: std.mem.Allocator,
    c: payload.Ctx,
    id: SymbolId,
    include_declaration: bool,
) !void {
    const idx = c.index();
    const target = idx.graph.symbols[id];
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(gpa);

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

    const limit = p.positive("limit", 200);
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
    try w.print(",\"protocolVersion\":{d},\"version\":\"{s}\",\"files\":{d},\"symbols\":{d},\"edges\":{d},\"languages\":{{", .{
        protocol_version, version, s.fileCount(), s.symbolCount(), s.edgeCount(),
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
    try w.print("}},\"overlays\":{d},\"indexedAt\":\"", .{s.overlays.count()});
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
        return w.writeAll("{\"word\":\"\",\"symbol\":null,\"enclosing\":null,\"candidates\":[]}");
    };
    try w.writeAll("{\"word\":");
    try payload.writeString(w, located.word);
    try w.writeAll(",\"symbol\":");
    try writeSymbolOrNull(w, c, located.symbol);
    try w.writeAll(",\"enclosing\":");
    try writeSymbolOrNull(w, c, located.enclosing);
    try w.writeAll(",\"candidates\":");
    try payload.writeSymbolArray(w, c, located.candidates);
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
    const roots = try queries.resolveTarget(arena, c, target);
    try queries.writeBlast(w, arena, c, roots, .{
        .depth = @min(p.positive("depth", self.cfg.depth), session_mod.Config.max_depth),
        .direction = try directionOf(p, .callers),
        .limit = p.positive("limit", 500),
        .scope = scopeOf(self, p),
    });
}

fn directionOf(p: Params, fallback: queries.Direction) Error!queries.Direction {
    const d = p.str("direction") orelse return fallback;
    if (std.mem.eql(u8, d, "callers")) return .callers;
    if (std.mem.eql(u8, d, "callees")) return .callees;
    return error.InvalidParams;
}

fn searchMethod(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    try self.flushPending(arena, .change);
    const c = try self.ctx();
    const p = Params.from(params);
    const q = p.str("query") orelse return error.InvalidParams;
    const scope = scopeOf(self, p);
    const filter = search.Filter{ .kinds = try kindsOf(arena, p), .tests = scope.tests };

    var hits: std.ArrayList(search.Hit) = .empty;
    defer hits.deinit(arena);
    if (p.boolean("refs", false)) {
        try search.searchRefs(arena, c.index(), q, filter, &hits);
    } else {
        try search.searchSymbols(arena, c.index(), q, filter, &hits);
    }

    const limit = p.positive("limit", 50);
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
    try w.print("],\"total\":{d}}}", .{hits.items.len});
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
        .limit = p.positive("limit", 200),
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
    const roots = try queries.resolveTarget(arena, c, target);
    try w.writeAll("{\"root\":");
    try queries.writeTree(w, arena, c, roots[0], .{
        .depth = @min(p.positive("depth", 1), session_mod.Config.max_depth),
        .direction = direction,
        .refs = p.boolean("refs", false),
        .scope = scopeOf(self, p),
    });
    try w.writeByte('}');
}

fn rescan(self: *Server, arena: std.mem.Allocator, params: ?std.json.Value, w: *Writer) Error!void {
    const s = &(self.session orelse return error.NotInitialized);
    const report = try s.rescan(Params.from(params).boolean("full", false));
    try self.announce(arena, report);
    try writeStatus(w, try self.ctx());
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
    .{ .name = "navgraph/status", .run = status },
    .{ .name = "navgraph/symbolAt", .run = symbolAt },
    .{ .name = "navgraph/blast", .run = blast },
    .{ .name = "navgraph/search", .run = searchMethod },
    .{ .name = "navgraph/grep", .run = grep },
    .{ .name = "navgraph/callers", .run = callersMethod },
    .{ .name = "navgraph/calls", .run = callsMethod },
    .{ .name = "navgraph/rescan", .run = rescan },
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

/// Every implemented `navgraph/*` method, advertised in `initialize`.
pub const navgraph_methods = blk: {
    var names: [requests.len + 1][]const u8 = undefined;
    var n: usize = 0;
    for (requests) |e| {
        if (std.mem.startsWith(u8, e.name, "navgraph/")) {
            names[n] = e.name;
            n += 1;
        }
    }
    names[n] = "navgraph/indexed";
    n += 1;
    const out = names[0..n].*;
    break :blk out;
};
