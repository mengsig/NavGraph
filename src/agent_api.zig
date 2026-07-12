//! Compact, typed, read-only API used by the MCP `navgraph.query` tool.
//!
//! This deliberately does not accept argv. Structured fields are decoded into
//! canonical `cli.Parsed` requests, so the model-facing contract cannot reach
//! mutating commands or smuggle CLI-only flags into a long-lived server.

const std = @import("std");
const cli = @import("cli.zig");
const index_mod = @import("index.zig");
const model = @import("model.zig");
const query = @import("query.zig");

pub const tool_name = "navgraph.query";
pub const query_schema = "navgraph.agent.query.v1";
pub const result_schema = "navgraph.agent.result.v1";

pub const min_max_bytes: u32 = 1024;
pub const default_max_bytes: u32 = 32 * 1024;
pub const max_max_bytes: u32 = 64 * 1024;
pub const default_limit: u32 = 50;
pub const max_limit: u32 = 100;
pub const max_source_lines: u32 = 200;
pub const max_cursor_offset: u32 = 10_000;

pub const Operation = enum { map, symbol, relations, source, impact, diagnostics };

pub const SourcePage = struct {
    path: []const u8,
    start_line: u32,
    end_line: u32,
    requested_end: ?u32,
    limit: u32,
};

pub const CursorPage = struct {
    after: u32,
    limit: u32,
};

pub const Request = struct {
    operation: Operation,
    view: []const u8,
    selector: []const u8 = "",
    parsed: cli.Parsed,
    max_bytes: u32 = default_max_bytes,
    source_page: ?SourcePage = null,
    cursor_page: ?CursorPage = null,
    limit_may_truncate: bool = false,

    pub fn exactness(self: Request) []const u8 {
        if (self.operation == .source) return "exact_source";
        if (self.operation == .symbol and std.mem.eql(u8, self.view, "source")) return "exact_source";
        if (self.parsed.options.strict) return "strict_graph";
        return switch (self.operation) {
            .map, .symbol => "indexed_syntax",
            .relations => "heuristic_graph",
            .source => unreachable,
            .impact => if (std.mem.eql(u8, self.view, "edit_sites")) "exact_sites" else "heuristic_graph",
            .diagnostics => "observed_snapshot",
        };
    }
};

pub const DecodeError = error{
    ExpectedObject,
    MissingOperation,
    InvalidOperation,
    UnknownField,
    MissingField,
    InvalidFieldType,
    EmptyField,
    InvalidChoice,
    InvalidCombination,
    InvalidCursor,
    NumberOutOfRange,
    OutOfMemory,
};

pub fn reason(err: DecodeError) []const u8 {
    return switch (err) {
        error.ExpectedObject => "navgraph.query arguments must be an object",
        error.MissingOperation => "operation is required",
        error.InvalidOperation => "operation must be map, symbol, relations, source, impact, or diagnostics",
        error.UnknownField => "field is not valid for this operation",
        error.MissingField => "a required field is missing",
        error.InvalidFieldType => "field has the wrong JSON type",
        error.EmptyField => "string fields must not be empty",
        error.InvalidChoice => "field value is not one of the documented choices",
        error.InvalidCombination => "fields form an invalid operation-specific combination",
        error.InvalidCursor => "after must be a cursor of the form v1:N",
        error.NumberOutOfRange => "numeric field is outside its documented range",
        error.OutOfMemory => "out of memory while decoding navgraph.query",
    };
}

/// Emit the deliberately flat provider schema. The closed property set and
/// enums reject misspellings/raw argv at the provider boundary; `decode` then
/// enforces the operation-specific field combinations. Keeping those two jobs
/// separate avoids replaying six nearly-identical schema branches to a model on
/// every request.
pub const input_schema_json =
    "{\"type\":\"object\",\"properties\":{\"operation\":{\"enum\":[\"map\",\"symbol\",\"relations\",\"source\",\"impact\",\"diagnostics\"]},\"view\":{\"enum\":[\"definition\",\"docs\",\"source\",\"callees\",\"callers\",\"neighbors\",\"imports\",\"importers\",\"hierarchy\",\"implementations\",\"path\",\"flow\",\"edit_sites\",\"affected_tests\",\"changed_symbols\",\"status\",\"likely_local\",\"coverage\"]},\"selector\":{\"type\":\"string\",\"minLength\":1},\"path\":{\"type\":\"string\"},\"query\":{\"type\":\"string\",\"minLength\":1},\"to\":{\"type\":\"string\",\"minLength\":1},\"kinds\":{\"type\":\"string\",\"minLength\":1},\"since\":{\"type\":\"string\",\"minLength\":1},\"start_line\":{\"type\":\"integer\",\"minimum\":1},\"end_line\":{\"type\":\"integer\",\"minimum\":1},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":200},\"depth\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":4},\"strict\":{\"type\":\"boolean\"},\"include_implementations\":{\"type\":\"boolean\"},\"after\":{\"type\":\"string\",\"pattern\":\"^v1:[0-9]+$\",\"maxLength\":8},\"max_bytes\":{\"type\":\"integer\",\"minimum\":1024,\"maximum\":65536}},\"required\":[\"operation\"],\"additionalProperties\":false}";

pub fn writeInputSchema(w: *std.Io.Writer) !void {
    try w.writeAll(input_schema_json);
}

pub fn inputSchemaFingerprint() u64 {
    var hasher = std.hash.Wyhash.init(0x41_47_45_4e_54_41_50_49);
    hasher.update(input_schema_json);
    return hasher.final();
}

pub fn decode(allocator: std.mem.Allocator, value: std.json.Value) DecodeError!Request {
    if (value != .object) return error.ExpectedObject;
    const obj = value.object;
    const operation_text = try requiredString(obj, "operation", error.MissingOperation);
    const operation = std.meta.stringToEnum(Operation, operation_text) orelse return error.InvalidOperation;
    return switch (operation) {
        .map => decodeMap(obj),
        .symbol => decodeSymbol(obj),
        .relations => decodeRelations(obj),
        .source => decodeSource(allocator, obj),
        .impact => decodeImpact(obj),
        .diagnostics => decodeDiagnostics(obj),
    };
}

fn decodeMap(obj: std.json.ObjectMap) DecodeError!Request {
    try onlyFields(obj, &.{ "operation", "path", "query", "kinds", "limit", "after", "max_bytes" });
    const path = try optionalString(obj, "path");
    const pattern = try optionalString(obj, "query");
    const kinds = try optionalString(obj, "kinds");
    if (path != null and pattern != null) return error.InvalidCombination;
    if (kinds != null and pattern == null) return error.InvalidCombination;
    const limit = try boundedInt(obj, "limit", default_limit, 1, max_limit);
    const after = try optionalCursor(obj, "after");
    const fetch_limit = cursorFetchLimit(after, limit);
    const max_bytes = try boundedInt(obj, "max_bytes", default_max_bytes, min_max_bytes, max_max_bytes);
    var options: query.Options = .{ .format = .json, .limit = fetch_limit, .max_nodes = fetch_limit };
    if (kinds) |value| options.kinds = value;
    if (pattern) |value| return .{
        .operation = .map,
        .view = "search",
        .selector = value,
        .parsed = .{ .command = .search, .arg = value, .options = options },
        .max_bytes = max_bytes,
        .cursor_page = .{ .after = after orelse 0, .limit = limit },
        .limit_may_truncate = true,
    };
    if (path) |value| return .{
        .operation = .map,
        .view = "outline",
        .selector = value,
        .parsed = .{ .command = .outline, .arg = value, .options = options },
        .max_bytes = max_bytes,
        .cursor_page = .{ .after = after orelse 0, .limit = limit },
        .limit_may_truncate = true,
    };
    return .{
        .operation = .map,
        .view = "files",
        .parsed = .{ .command = .files, .options = options },
        .max_bytes = max_bytes,
        .cursor_page = .{ .after = after orelse 0, .limit = limit },
        .limit_may_truncate = true,
    };
}

fn decodeSymbol(obj: std.json.ObjectMap) DecodeError!Request {
    try onlyFields(obj, &.{ "operation", "selector", "view", "max_bytes" });
    const selector = try requiredString(obj, "selector", error.MissingField);
    const include = (try optionalString(obj, "view")) orelse "definition";
    if (!oneOf(include, &.{ "definition", "docs", "source" })) return error.InvalidChoice;
    const max_bytes = try boundedInt(obj, "max_bytes", default_max_bytes, min_max_bytes, max_max_bytes);
    var options: query.Options = .{ .format = .json };
    if (std.mem.eql(u8, include, "source")) options.verbosity = .full;
    return .{
        .operation = .symbol,
        .view = include,
        .selector = selector,
        .parsed = .{ .command = if (std.mem.eql(u8, include, "docs")) .docs else .def, .arg = selector, .options = options },
        .max_bytes = max_bytes,
    };
}

fn decodeRelations(obj: std.json.ObjectMap) DecodeError!Request {
    try onlyFields(obj, &.{ "operation", "selector", "view", "to", "depth", "strict", "include_implementations", "limit", "max_bytes" });
    const selector = try requiredString(obj, "selector", error.MissingField);
    const relation = try requiredString(obj, "view", error.MissingField);
    const to = try optionalString(obj, "to");
    const depth = try boundedInt(obj, "depth", 1, 0, 4);
    const limit = try boundedInt(obj, "limit", default_limit, 1, max_limit);
    const max_bytes = try boundedInt(obj, "max_bytes", default_max_bytes, min_max_bytes, max_max_bytes);
    const strict = try optionalBool(obj, "strict", false);
    const impls = try optionalBool(obj, "include_implementations", false);
    var command: cli.Command = undefined;
    if (std.mem.eql(u8, relation, "callees")) {
        command = .calls;
    } else if (std.mem.eql(u8, relation, "callers")) {
        command = .callers;
    } else if (std.mem.eql(u8, relation, "neighbors")) {
        command = .neighbors;
    } else if (std.mem.eql(u8, relation, "imports")) {
        command = .imports;
    } else if (std.mem.eql(u8, relation, "importers")) {
        command = .importers;
    } else if (std.mem.eql(u8, relation, "hierarchy")) {
        command = .hierarchy;
    } else if (std.mem.eql(u8, relation, "implementations")) {
        command = .conforms;
    } else if (std.mem.eql(u8, relation, "path")) {
        command = .path;
        if (to == null) return error.InvalidCombination;
    } else if (std.mem.eql(u8, relation, "flow")) {
        command = .flow;
    } else return error.InvalidChoice;
    if (to != null and command != .path and command != .flow) return error.InvalidCombination;
    var options: query.Options = .{
        .format = .json,
        .depth = depth,
        .limit = limit,
        .max_nodes = limit,
        .budget = max_bytes,
        .strict = strict,
        .impls = impls,
    };
    if (command == .flow and to != null) options.flow_to = to.?;
    return .{
        .operation = .relations,
        .view = relation,
        .selector = selector,
        .parsed = .{ .command = command, .arg = selector, .arg2 = if (command == .path) to.? else "", .options = options },
        .max_bytes = max_bytes,
        .limit_may_truncate = command != .path and command != .imports and command != .importers,
    };
}

fn decodeSource(allocator: std.mem.Allocator, obj: std.json.ObjectMap) DecodeError!Request {
    try onlyFields(obj, &.{ "operation", "path", "start_line", "end_line", "limit", "max_bytes" });
    const path = try requiredString(obj, "path", error.MissingField);
    const start = try boundedInt(obj, "start_line", 1, 1, std.math.maxInt(u32));
    const requested_end = try optionalInt(obj, "end_line", 1, std.math.maxInt(u32));
    if (requested_end != null and requested_end.? < start) return error.InvalidCombination;
    const limit = try boundedInt(obj, "limit", 120, 1, max_source_lines);
    const max_bytes = try boundedInt(obj, "max_bytes", default_max_bytes, min_max_bytes, max_max_bytes);
    const page_end = @min(requested_end orelse std.math.maxInt(u32), start +| (limit - 1));
    const range = std.fmt.allocPrint(allocator, "{s}:{}-{}", .{ path, start, page_end }) catch return error.OutOfMemory;
    return .{
        .operation = .source,
        .view = "lines",
        .selector = path,
        .parsed = .{ .command = .read, .arg = range, .options = .{ .format = .json } },
        .max_bytes = max_bytes,
        .source_page = .{ .path = path, .start_line = start, .end_line = page_end, .requested_end = requested_end, .limit = limit },
    };
}

fn decodeImpact(obj: std.json.ObjectMap) DecodeError!Request {
    try onlyFields(obj, &.{ "operation", "view", "selector", "since", "strict", "limit", "after", "max_bytes" });
    const analysis = try requiredString(obj, "view", error.MissingField);
    const selector = try optionalString(obj, "selector");
    const since = try optionalString(obj, "since");
    const limit = try boundedInt(obj, "limit", default_limit, 1, max_limit);
    const after = try optionalCursor(obj, "after");
    const max_bytes = try boundedInt(obj, "max_bytes", default_max_bytes, min_max_bytes, max_max_bytes);
    const strict = try optionalBool(obj, "strict", false);
    var command: cli.Command = undefined;
    if (std.mem.eql(u8, analysis, "edit_sites")) {
        command = .edits;
        if (selector == null or since != null) return error.InvalidCombination;
    } else if (std.mem.eql(u8, analysis, "affected_tests")) {
        command = .affected;
        if (selector != null) return error.InvalidCombination;
    } else if (std.mem.eql(u8, analysis, "changed_symbols")) {
        command = .diff;
        // Diff's JSON array is grouped by file while its limit counts symbols,
        // so an ordinal facade cursor would not be stable for this view.
        if (selector != null or strict or after != null) return error.InvalidCombination;
    } else return error.InvalidChoice;
    return .{
        .operation = .impact,
        .view = analysis,
        .selector = selector orelse since orelse "",
        .parsed = .{
            .command = command,
            .arg = if (command == .edits) selector.? else since orelse "",
            .options = .{ .format = .json, .limit = cursorFetchLimit(after, limit), .max_nodes = cursorFetchLimit(after, limit), .strict = strict },
        },
        .max_bytes = max_bytes,
        .cursor_page = if (command == .diff) null else .{ .after = after orelse 0, .limit = limit },
        .limit_may_truncate = command != .edits,
    };
}

fn decodeDiagnostics(obj: std.json.ObjectMap) DecodeError!Request {
    try onlyFields(obj, &.{ "operation", "view", "path", "limit", "after", "max_bytes" });
    const analysis = (try optionalString(obj, "view")) orelse "status";
    if (!oneOf(analysis, &.{ "status", "likely_local", "coverage" })) return error.InvalidChoice;
    const path = (try optionalStringAllowEmpty(obj, "path")) orelse "";
    const limit = try boundedInt(obj, "limit", 25, 1, max_limit);
    const after = try optionalCursor(obj, "after");
    const max_bytes = try boundedInt(obj, "max_bytes", default_max_bytes, min_max_bytes, max_max_bytes);
    return .{
        .operation = .diagnostics,
        .view = analysis,
        .selector = path,
        .parsed = .{
            .command = if (std.mem.eql(u8, analysis, "coverage")) .coverage else .status,
            .arg = path,
            .options = .{ .format = .json, .limit = cursorFetchLimit(after, limit) },
        },
        .max_bytes = max_bytes,
        .cursor_page = .{ .after = after orelse 0, .limit = limit },
    };
}

fn onlyFields(obj: std.json.ObjectMap, allowed: []const []const u8) DecodeError!void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!oneOf(entry.key_ptr.*, allowed)) return error.UnknownField;
    }
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

fn requiredString(obj: std.json.ObjectMap, name: []const u8, missing: DecodeError) DecodeError![]const u8 {
    const value = obj.get(name) orelse return missing;
    if (value != .string) return error.InvalidFieldType;
    if (value.string.len == 0) return error.EmptyField;
    return value.string;
}

fn optionalString(obj: std.json.ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string) return error.InvalidFieldType;
    if (value.string.len == 0) return error.EmptyField;
    return value.string;
}

fn optionalStringAllowEmpty(obj: std.json.ObjectMap, name: []const u8) DecodeError!?[]const u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string) return error.InvalidFieldType;
    return value.string;
}

fn optionalBool(obj: std.json.ObjectMap, name: []const u8, default: bool) DecodeError!bool {
    const value = obj.get(name) orelse return default;
    if (value != .bool) return error.InvalidFieldType;
    return value.bool;
}

fn optionalInt(obj: std.json.ObjectMap, name: []const u8, min: u32, max: u32) DecodeError!?u32 {
    const value = obj.get(name) orelse return null;
    if (value != .integer) return error.InvalidFieldType;
    if (value.integer < min or value.integer > max) return error.NumberOutOfRange;
    return @intCast(value.integer);
}

fn boundedInt(obj: std.json.ObjectMap, name: []const u8, default: u32, min: u32, max: u32) DecodeError!u32 {
    return (try optionalInt(obj, name, min, max)) orelse default;
}

fn optionalCursor(obj: std.json.ObjectMap, name: []const u8) DecodeError!?u32 {
    const value = obj.get(name) orelse return null;
    if (value != .string) return error.InvalidFieldType;
    const text = value.string;
    if (!std.mem.startsWith(u8, text, "v1:") or text.len == 3) return error.InvalidCursor;
    for (text[3..]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidCursor;
    const offset = std.fmt.parseInt(u32, text[3..], 10) catch return error.InvalidCursor;
    if (offset > max_cursor_offset) return error.NumberOutOfRange;
    return offset;
}

fn cursorFetchLimit(after: ?u32, limit: u32) u32 {
    std.debug.assert(limit > 0);
    std.debug.assert((after orelse 0) <= max_cursor_offset);
    return (after orelse 0) + limit + 1;
}

/// Content-addressed identity for the in-memory snapshot. It is computed once
/// at session initialization/reload, not on every query.
pub fn snapshotFingerprint(idx: *const index_mod.Index) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(idx.root);
    for (idx.graph.files) |file| {
        hasher.update(file.path);
        hasher.update(file.text);
    }
    return hasher.final();
}

pub const EnvelopeError = error{ InvalidCoreJson, ResultBudgetTooSmall, OutOfMemory, WriteFailed };

/// Resolve semantic endpoints before any traversal. An ambiguous selector is
/// evidence, not permission to walk every matching graph or choose an arbitrary
/// path. Null means dispatch may proceed; a returned envelope is an abstention
/// result with candidates and ready-to-call pinned alternatives.
pub fn ambiguityEnvelopeOwned(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    snapshot_id: u64,
    request: Request,
) EnvelopeError!?[]u8 {
    var from_buf: [64]model.SymbolId = undefined;
    var to_buf: [64]model.SymbolId = undefined;
    var from_ids: []const model.SymbolId = &.{};
    var to_ids: []const model.SymbolId = &.{};
    const command = request.parsed.command;
    const selector_unique = switch (command) {
        .def, .docs, .calls, .callers, .neighbors, .hierarchy, .conforms, .flow, .edits => true,
        else => false,
    };
    if (selector_unique or command == .path) from_ids = query.resolveIds(idx, request.parsed.arg, &from_buf);
    if (command == .path) to_ids = query.resolveIds(idx, request.parsed.arg2, &to_buf);
    const ambiguous_from = from_ids.len > 1;
    const ambiguous_to = to_ids.len > 1;
    if (!ambiguous_from and !ambiguous_to) return null;

    var candidate_limit: usize = 4;
    while (true) {
        const envelope = try buildAmbiguityEnvelope(
            allocator,
            idx,
            snapshot_id,
            request,
            from_ids,
            to_ids,
            candidate_limit,
        );
        if (envelope.len <= request.max_bytes) return envelope;
        allocator.free(envelope);
        if (candidate_limit > 1) {
            candidate_limit -= 1;
            continue;
        }
        return error.ResultBudgetTooSmall;
    }
}

fn buildAmbiguityEnvelope(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    snapshot_id: u64,
    request: Request,
    from_ids: []const model.SymbolId,
    to_ids: []const model.SymbolId,
    candidate_limit: usize,
) EnvelopeError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer aw.deinit();
    const w = &aw.writer;
    const ambiguous_from = from_ids.len > 1;
    const ambiguous_to = to_ids.len > 1;
    const candidate_total = (if (ambiguous_from) from_ids.len else 0) + (if (ambiguous_to) to_ids.len else 0);
    const candidate_shown = @min(candidate_total, candidate_limit);
    const parse_warnings = parseWarningCount(idx);
    try w.writeAll("{\"schema\":");
    try writeString(w, result_schema);
    try w.print(",\"snapshot_id\":\"{x:0>16}\",\"operation\":\"{s}\",\"view\":", .{ snapshot_id, @tagName(request.operation) });
    try writeString(w, request.view);
    try w.writeAll(",\"found\":true,\"exactness\":");
    try writeString(w, request.exactness());
    try w.writeAll(",\"ambiguous\":true,\"candidates\":[");
    var emitted: usize = 0;
    const from_cap = if (ambiguous_from and ambiguous_to and candidate_limit > 1) @max(@as(usize, 1), candidate_limit / 2) else candidate_limit;
    if (ambiguous_from) try writeResolvedCandidates(w, idx, from_ids, if (request.parsed.command == .path) "from" else "selector", from_cap, &emitted);
    if (ambiguous_to and emitted < candidate_limit) try writeResolvedCandidates(w, idx, to_ids, "to", candidate_limit, &emitted);
    try w.print("],\"truncated\":{},\"next\":null", .{candidate_shown < candidate_total});
    try w.print(",\"parse_health\":{{\"reliable\":{},\"warnings\":{}}}", .{ parse_warnings == 0, parse_warnings });
    try writeResolutionHealth(w, idx);
    try w.writeAll(",\"warnings\":[\"ambiguous_selector_pin_required\"],\"content\":null,\"items\":[],\"source_spans\":[],\"suggested_calls\":[");
    try writePinnedSuggestions(w, idx, request, from_ids, to_ids, @min(candidate_limit, 3));
    try w.writeAll("]}");
    return try aw.toOwnedSlice();
}

fn writeResolvedCandidates(
    w: *std.Io.Writer,
    idx: *const index_mod.Index,
    ids: []const model.SymbolId,
    endpoint: []const u8,
    limit: usize,
    emitted: *usize,
) !void {
    for (ids) |id| {
        if (emitted.* >= limit) return;
        const sym = idx.graph.symbols[id];
        const file = idx.graph.files[sym.file];
        if (emitted.* != 0) try w.writeByte(',');
        emitted.* += 1;
        try w.writeAll("{\"endpoint\":");
        try writeString(w, endpoint);
        try w.print(",\"id\":{},\"kind\":\"{s}\",\"name\":", .{ id, @tagName(sym.kind) });
        try writeString(w, sym.name);
        try w.writeAll(",\"file\":");
        try writeString(w, file.path);
        try w.print(",\"line\":{},\"line_end\":{}}}", .{ sym.line, sym.endLine(file.text) });
    }
}

fn writePinnedSuggestions(
    w: *std.Io.Writer,
    idx: *const index_mod.Index,
    request: Request,
    from_ids: []const model.SymbolId,
    to_ids: []const model.SymbolId,
    limit: usize,
) !void {
    var emitted: usize = 0;
    if (request.parsed.command == .path) {
        const from_choices = if (from_ids.len > 1) from_ids else from_ids[0..@min(from_ids.len, 1)];
        const to_choices = if (to_ids.len > 1) to_ids else to_ids[0..@min(to_ids.len, 1)];
        for (from_choices) |from_id| {
            for (to_choices) |to_id| {
                if (emitted >= limit) return;
                if (emitted != 0) try w.writeByte(',');
                emitted += 1;
                try w.writeAll("{\"operation\":\"relations\",\"view\":\"path\",\"selector\":");
                try writePinnedSelector(w, idx, from_id);
                try w.writeAll(",\"to\":");
                try writePinnedSelector(w, idx, to_id);
                if (request.parsed.options.strict) try w.writeAll(",\"strict\":true");
                try w.writeByte('}');
            }
        }
        return;
    }
    const ids = if (from_ids.len > 1) from_ids else to_ids;
    for (ids) |id| {
        if (emitted >= limit) return;
        if (emitted != 0) try w.writeByte(',');
        emitted += 1;
        try w.print("{{\"operation\":\"{s}\",\"view\":", .{@tagName(request.operation)});
        try writeString(w, request.view);
        try w.writeAll(",\"selector\":");
        try writePinnedSelector(w, idx, id);
        if (request.operation == .relations) {
            if (request.parsed.options.depth != 1) try w.print(",\"depth\":{}", .{request.parsed.options.depth});
            if (request.parsed.options.strict) try w.writeAll(",\"strict\":true");
        }
        try w.writeByte('}');
    }
}

fn writePinnedSelector(w: *std.Io.Writer, idx: *const index_mod.Index, id: model.SymbolId) !void {
    const sym = idx.graph.symbols[id];
    const file = idx.graph.files[sym.file];
    try w.writeByte('"');
    if (sym.parent != model.invalid_symbol) {
        try writeJsonStringInner(w, idx.graph.symbols[sym.parent].name);
        try w.writeByte('.');
    }
    try writeJsonStringInner(w, sym.name);
    try w.writeByte('@');
    try writeJsonStringInner(w, file.path);
    try w.writeByte('"');
}

fn writeJsonStringInner(w: *std.Io.Writer, value: []const u8) !void {
    const quoted = try std.json.Stringify.valueAlloc(std.heap.page_allocator, value, .{});
    defer std.heap.page_allocator.free(quoted);
    try w.writeAll(quoted[1 .. quoted.len - 1]);
}

/// Build the serialized `structuredContent` envelope. `max_bytes` is a hard
/// bound on this returned slice. The MCP framing and short human summary are
/// intentionally outside that bound and are constant-size.
pub fn envelopeOwned(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    snapshot_id: u64,
    request: Request,
    found: bool,
    raw_json: []const u8,
) EnvelopeError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return error.InvalidCoreJson;
    defer parsed.deinit();

    const window = resultWindow(parsed.value, request);
    var keep_items = window.count;
    var compact = false;
    while (true) {
        const envelope = try buildEnvelope(allocator, idx, snapshot_id, request, found, parsed.value, keep_items, compact);
        if (envelope.len <= request.max_bytes) return envelope;
        allocator.free(envelope);
        if (keep_items > 0) {
            keep_items = if (keep_items == 1) 0 else keep_items / 2;
            continue;
        }
        if (!compact) {
            compact = true;
            continue;
        }
        const minimal = try buildMinimalEnvelope(allocator, idx, snapshot_id, request, found, parsed.value);
        if (minimal.len > request.max_bytes) {
            allocator.free(minimal);
            return error.ResultBudgetTooSmall;
        }
        return minimal;
    }
}

fn buildEnvelope(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    snapshot_id: u64,
    request: Request,
    found: bool,
    root: std.json.Value,
    keep_items: usize,
    compact: bool,
) EnvelopeError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer aw.deinit();
    const w = &aw.writer;
    const window = resultWindow(root, request);
    const emitted_items = @min(keep_items, window.count);
    const result_found = if (isLikelyLocalDiagnostics(request)) window.count != 0 else found;
    // Endpoint ambiguity is resolved before dispatch by
    // `ambiguityEnvelopeOwned`; row count is never a proxy for candidates.
    const ambiguous = false;
    const parse_warnings = parseWarningCount(idx);
    const core_truncated = !isLikelyLocalDiagnostics(request) and
        (valueTruncated(root) or (request.limit_may_truncate and window.values.len >= request.parsed.options.limit));
    const budget_truncated = emitted_items < window.count or (compact and root != .array);
    const source_next = nextSourceLine(request, root, emitted_items);
    const cursor_next = nextCursor(request, window, emitted_items);
    const truncated = core_truncated or budget_truncated or source_next != null or cursor_next != null;
    const review_sites = reviewSiteCount(root);

    try w.writeAll("{\"schema\":");
    try writeString(w, result_schema);
    try w.print(",\"snapshot_id\":\"{x:0>16}\",\"operation\":\"{s}\",\"view\":", .{ snapshot_id, @tagName(request.operation) });
    try writeString(w, request.view);
    try w.print(",\"found\":{},\"exactness\":", .{result_found});
    try writeString(w, effectiveExactness(request, review_sites));
    try w.print(",\"ambiguous\":{},\"candidates\":[", .{ambiguous});
    if (ambiguous and !compact) try writeCandidates(w, root, 5);
    try w.print("],\"truncated\":{},\"next\":", .{truncated});
    if (source_next) |line|
        try writeSourceCall(w, request.source_page.?, line)
    else if (cursor_next) |after|
        try writeCursorCall(w, request, after)
    else
        try w.writeAll("null");
    try w.print(",\"parse_health\":{{\"reliable\":{},\"warnings\":{}}}", .{ parse_warnings == 0, parse_warnings });
    try writeResolutionHealth(w, idx);
    try w.writeAll(",\"warnings\":[");
    var warning_count: u8 = 0;
    if (parse_warnings != 0) try warning(w, &warning_count, "parse_health_unreliable");
    if (ambiguous) try warning(w, &warning_count, "ambiguous_selector_pin_required");
    if (budget_truncated) try warning(w, &warning_count, "max_bytes_content_truncated");
    if (review_sites != 0) try warning(w, &warning_count, "review_sites_present");
    if (core_truncated and source_next == null and cursor_next == null) try warning(w, &warning_count, "core_result_truncated_narrow_scope");
    try w.writeAll("],\"content\":");
    try writeContent(w, root, request, compact);
    try w.writeAll(",\"items\":[");
    const items_are_source_spans = request.operation == .impact and std.mem.eql(u8, request.view, "edit_sites");
    if (!items_are_source_spans) try writeValueWindow(w, window, request, emitted_items);
    try w.writeAll("],\"source_spans\":[");
    try writeSourceSpans(w, root, request, compact, window, emitted_items);
    try w.writeAll("],\"suggested_calls\":[");
    try writeSuggestion(w, request, root, result_found, ambiguous, source_next, cursor_next, truncated);
    try w.writeAll("]}");
    return try aw.toOwnedSlice();
}

fn buildMinimalEnvelope(
    allocator: std.mem.Allocator,
    idx: *const index_mod.Index,
    snapshot_id: u64,
    request: Request,
    found: bool,
    root: std.json.Value,
) EnvelopeError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"schema\":");
    try writeString(w, result_schema);
    try w.print(",\"snapshot_id\":\"{x:0>16}\",\"operation\":\"{s}\",\"view\":", .{ snapshot_id, @tagName(request.operation) });
    try writeString(w, request.view);
    const review_sites = reviewSiteCount(root);
    const window = resultWindow(root, request);
    const result_found = if (isLikelyLocalDiagnostics(request)) window.count != 0 else found;
    try w.print(",\"found\":{},\"exactness\":", .{result_found});
    const source_next = nextSourceLine(request, root, 0);
    const cursor_next = nextCursor(request, window, 0);
    try writeString(w, effectiveExactness(request, review_sites));
    try w.writeAll(",\"ambiguous\":false,\"candidates\":[],\"truncated\":true,\"next\":");
    if (source_next) |line|
        try writeSourceCall(w, request.source_page.?, line)
    else if (cursor_next) |after|
        try writeCursorCall(w, request, after)
    else
        try w.writeAll("null");
    try w.print(",\"parse_health\":{{\"reliable\":{},\"warnings\":{}}}", .{ parseWarningCount(idx) == 0, parseWarningCount(idx) });
    try writeResolutionHealth(w, idx);
    try w.writeAll(",\"warnings\":[\"max_bytes_content_truncated\"");
    if (review_sites != 0) try w.writeAll(",\"review_sites_present\"");
    try w.writeAll("],\"content\":null,\"items\":[],\"source_spans\":[],\"suggested_calls\":[]}");
    return try aw.toOwnedSlice();
}

fn resultItems(root: std.json.Value, request: Request) ?[]const std.json.Value {
    if (root == .array) return root.array.items;
    if (root != .object) return null;
    const obj = root.object;
    if (obj.get("lines")) |value| if (value == .array) return value.array.items;
    if (obj.get("sites")) |value| if (value == .array) return value.array.items;
    if (request.operation == .impact) if (obj.get("results")) |value| if (value == .array) return value.array.items;
    if (request.operation == .diagnostics and std.mem.eql(u8, request.view, "coverage"))
        if (obj.get("files")) |value| if (value == .array) return value.array.items;
    if (request.operation == .diagnostics and !std.mem.eql(u8, request.view, "coverage")) {
        if (obj.get("unresolved_references")) |unresolved| if (unresolved == .object)
            if (unresolved.object.get("items")) |value| if (value == .array) return value.array.items;
    }
    if (obj.get("items")) |value| if (value == .array) return value.array.items;
    return null;
}

const ResultWindow = struct {
    values: []const std.json.Value,
    offset: usize,
    count: usize,
    more: bool,
};

fn isLikelyLocalDiagnostics(request: Request) bool {
    return request.operation == .diagnostics and std.mem.eql(u8, request.view, "likely_local");
}

fn resultWindow(root: std.json.Value, request: Request) ResultWindow {
    const values = resultItems(root, request) orelse &.{};
    const eligible = eligibleItemCount(values, request);
    const page = request.cursor_page orelse return .{ .values = values, .offset = 0, .count = eligible, .more = false };
    const offset = @min(@as(usize, page.after), eligible);
    const count = @min(@as(usize, page.limit), eligible - offset);
    return .{ .values = values, .offset = offset, .count = count, .more = offset + count < eligible };
}

fn itemEligible(value: std.json.Value, request: Request) bool {
    if (!isLikelyLocalDiagnostics(request)) return true;
    if (value != .object) return false;
    const resolution = value.object.get("resolution") orelse return false;
    return resolution == .string and std.mem.eql(u8, resolution.string, "likely_local");
}

fn eligibleItemCount(values: []const std.json.Value, request: Request) usize {
    var count: usize = 0;
    for (values) |value| if (itemEligible(value, request)) {
        count += 1;
    };
    return count;
}

fn writeValueWindow(w: *std.Io.Writer, window: ResultWindow, request: Request, count: usize) !void {
    var skipped: usize = 0;
    var emitted: usize = 0;
    for (window.values) |value| {
        if (!itemEligible(value, request)) continue;
        if (skipped < window.offset) {
            skipped += 1;
            continue;
        }
        if (emitted >= count) break;
        if (emitted != 0) try w.writeByte(',');
        try std.json.Stringify.value(value, .{}, w);
        emitted += 1;
    }
}

fn nextCursor(request: Request, window: ResultWindow, emitted: usize) ?u32 {
    const page = request.cursor_page orelse return null;
    if (emitted >= window.count and !window.more) return null;
    return page.after + @as(u32, @intCast(emitted));
}

fn reviewSiteCount(root: std.json.Value) u32 {
    if (root != .object) return 0;
    const value = root.object.get("review_sites") orelse return 0;
    if (value != .integer or value.integer <= 0) return 0;
    return @intCast(@min(value.integer, std.math.maxInt(u32)));
}

fn effectiveExactness(request: Request, review_sites: u32) []const u8 {
    if (request.operation == .impact and std.mem.eql(u8, request.view, "edit_sites") and review_sites != 0)
        return "exact_sites_with_review_gaps";
    return request.exactness();
}

fn writeContent(w: *std.Io.Writer, root: std.json.Value, request: Request, compact: bool) !void {
    if (root == .array) return w.writeAll("null");
    if (compact) return w.writeAll("null");
    if (root == .object and request.operation == .source)
        return writeObjectExcept(w, root.object, &.{ "lines", "ranges", "offset", "limit", "budget", "estimated_bytes", "selected", "shown", "truncated", "next" });
    if (root == .object and request.operation == .impact and std.mem.eql(u8, request.view, "edit_sites"))
        return writeObjectExcept(w, root.object, &.{"sites"});
    if (root == .object and request.operation == .impact and std.mem.eql(u8, request.view, "affected_tests"))
        return writeObjectExcept(w, root.object, &.{"results"});
    if (root == .object and request.operation == .diagnostics and std.mem.eql(u8, request.view, "coverage"))
        return writeObjectExcept(w, root.object, &.{"files"});
    if (root == .object and request.operation == .diagnostics)
        return writeObjectExcept(w, root.object, &.{"unresolved_references"});
    try std.json.Stringify.value(root, .{}, w);
}

fn writeObjectExcept(w: *std.Io.Writer, obj: std.json.ObjectMap, excluded: []const []const u8) !void {
    try w.writeByte('{');
    var first = true;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (oneOf(entry.key_ptr.*, excluded)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try writeString(w, entry.key_ptr.*);
        try w.writeByte(':');
        try std.json.Stringify.value(entry.value_ptr.*, .{}, w);
    }
    try w.writeByte('}');
}

fn writeValuePrefix(w: *std.Io.Writer, values: []const std.json.Value, count: usize) !void {
    for (values[0..@min(values.len, count)], 0..) |value, i| {
        if (i != 0) try w.writeByte(',');
        try std.json.Stringify.value(value, .{}, w);
    }
}

fn writeCandidates(w: *std.Io.Writer, root: std.json.Value, max: usize) !void {
    if (root != .array) return;
    var first = true;
    for (root.array.items[0..@min(root.array.items.len, max)]) |candidate| {
        if (candidate != .object) continue;
        const obj = candidate.object;
        const identity = if (obj.get("type")) |value| if (value == .object) value.object else obj else obj;
        if (!first) try w.writeByte(',');
        first = false;
        try writeCandidateIdentity(w, identity);
    }
}

fn writeCandidateIdentity(w: *std.Io.Writer, obj: std.json.ObjectMap) !void {
    try w.writeByte('{');
    var first = true;
    const fields = [_][]const u8{ "id", "kind", "name", "file", "line", "line_end", "sig" };
    for (&fields) |field| {
        const value = obj.get(field) orelse continue;
        if (!first) try w.writeByte(',');
        first = false;
        try writeString(w, field);
        try w.writeByte(':');
        try std.json.Stringify.value(value, .{}, w);
    }
    try w.writeByte('}');
}

fn writeSourceSpans(
    w: *std.Io.Writer,
    root: std.json.Value,
    request: Request,
    compact: bool,
    window: ResultWindow,
    emitted_items: usize,
) !void {
    if (compact or root != .object) return;
    const obj = root.object;
    if (request.operation == .source) {
        const file = obj.get("file") orelse return;
        const lines = obj.get("lines") orelse return;
        if (lines != .array or emitted_items == 0) return;
        const shown = @min(emitted_items, lines.array.items.len);
        const first_line = lines.array.items[0].object.get("line") orelse return;
        const last_line = lines.array.items[shown - 1].object.get("line") orelse return;
        try w.writeAll("{\"file\":");
        try std.json.Stringify.value(file, .{}, w);
        try w.writeAll(",\"start_line\":");
        try std.json.Stringify.value(first_line, .{}, w);
        try w.writeAll(",\"end_line\":");
        try std.json.Stringify.value(last_line, .{}, w);
        try w.writeByte('}');
        return;
    }
    if (request.operation == .impact and std.mem.eql(u8, request.view, "edit_sites")) {
        try writeValueWindow(w, window, request, emitted_items);
    }
}

fn valueTruncated(value: std.json.Value) bool {
    switch (value) {
        .array => for (value.array.items) |item| if (valueTruncated(item)) return true,
        .object => {
            if (value.object.get("truncated")) |flag| if (flag == .bool and flag.bool) return true;
            const fields = [_][]const u8{ "unresolved_references", "parse_health", "scope" };
            for (&fields) |field| {
                if (value.object.get(field)) |nested| if (valueTruncated(nested)) return true;
            }
        },
        else => {},
    }
    return false;
}

fn nextSourceLine(request: Request, root: std.json.Value, emitted_items: usize) ?u32 {
    const page = request.source_page orelse return null;
    if (root != .object) return null;
    if (root.object.get("lines")) |lines| {
        if (lines == .array and emitted_items < lines.array.items.len) {
            const omitted = lines.array.items[emitted_items];
            if (omitted == .object) {
                if (omitted.object.get("line")) |line| {
                    if (line == .integer and line.integer > 0 and line.integer <= std.math.maxInt(u32)) return @intCast(line.integer);
                }
            }
        }
    }
    const total_value = root.object.get("total_lines") orelse return null;
    if (total_value != .integer or total_value.integer <= 0) return null;
    const total: u32 = @intCast(@min(total_value.integer, std.math.maxInt(u32)));
    const requested_last = @min(page.requested_end orelse total, total);
    if (page.end_line >= requested_last) return null;
    return page.end_line + 1;
}

fn writeSourceCall(w: *std.Io.Writer, page: SourcePage, start: u32) !void {
    try w.writeAll("{\"operation\":\"source\",\"path\":");
    try writeString(w, page.path);
    try w.print(",\"start_line\":{},\"limit\":{}", .{ start, page.limit });
    if (page.requested_end) |end| try w.print(",\"end_line\":{}", .{end});
    try w.writeByte('}');
}

fn writeCursorCall(w: *std.Io.Writer, request: Request, after: u32) !void {
    const page = request.cursor_page orelse return w.writeAll("null");
    try w.print("{{\"operation\":\"{s}\"", .{@tagName(request.operation)});
    switch (request.operation) {
        .map => {
            if (std.mem.eql(u8, request.view, "outline")) {
                try w.writeAll(",\"path\":");
                try writeString(w, request.selector);
            } else if (std.mem.eql(u8, request.view, "search")) {
                try w.writeAll(",\"query\":");
                try writeString(w, request.selector);
                if (request.parsed.options.kinds.len != 0) {
                    try w.writeAll(",\"kinds\":");
                    try writeString(w, request.parsed.options.kinds);
                }
            }
        },
        .diagnostics => {
            try w.writeAll(",\"view\":");
            try writeString(w, request.view);
            if (request.selector.len != 0) {
                try w.writeAll(",\"path\":");
                try writeString(w, request.selector);
            }
        },
        .impact => {
            try w.writeAll(",\"view\":");
            try writeString(w, request.view);
            if (request.selector.len != 0) {
                try w.writeAll(if (std.mem.eql(u8, request.view, "edit_sites")) ",\"selector\":" else ",\"since\":");
                try writeString(w, request.selector);
            }
            if (request.parsed.options.strict) try w.writeAll(",\"strict\":true");
        },
        else => return w.writeAll("}"),
    }
    try w.print(",\"limit\":{},\"after\":\"v1:{}\"", .{ page.limit, after });
    if (request.max_bytes != default_max_bytes) try w.print(",\"max_bytes\":{}", .{request.max_bytes});
    try w.writeByte('}');
}

fn writeSuggestion(
    w: *std.Io.Writer,
    request: Request,
    root: std.json.Value,
    found: bool,
    ambiguous: bool,
    source_next: ?u32,
    cursor_next: ?u32,
    truncated: bool,
) !void {
    if (source_next) |line| return writeSourceCall(w, request.source_page.?, line);
    if (cursor_next) |after| return writeCursorCall(w, request, after);
    if (ambiguous and root == .array) {
        for (root.array.items) |candidate| {
            if (candidate != .object) continue;
            const obj = candidate.object;
            const identity = if (obj.get("type")) |value| if (value == .object) value.object else obj else obj;
            const name = identity.get("name") orelse continue;
            const file = identity.get("file") orelse continue;
            if (name != .string or file != .string) continue;
            try w.print("{{\"operation\":\"{s}\",", .{@tagName(request.operation)});
            if (request.operation == .relations) {
                try w.writeAll("\"view\":");
                try writeString(w, request.view);
                try w.writeAll(",");
            } else if (request.operation == .impact) {
                try w.writeAll("\"view\":");
                try writeString(w, request.view);
                try w.writeAll(",");
            } else if (request.operation == .symbol) {
                try w.writeAll("\"view\":");
                try writeString(w, request.view);
                try w.writeAll(",");
            }
            try w.writeAll("\"selector\":");
            var selector_buf: [512]u8 = undefined;
            const pinned = std.fmt.bufPrint(&selector_buf, "{s}@{s}", .{ name.string, file.string }) catch request.selector;
            try writeString(w, pinned);
            try w.writeByte('}');
            return;
        }
    }
    if (!found and request.selector.len != 0 and request.operation != .map and request.operation != .source) {
        try w.writeAll("{\"operation\":\"map\",\"query\":");
        try writeString(w, request.selector);
        try w.writeAll(",\"limit\":10}");
        return;
    }
    if (truncated and request.operation == .symbol and std.mem.eql(u8, request.view, "source") and root == .array and root.array.items.len != 0) {
        const candidate = root.array.items[0];
        if (candidate == .object) {
            const file = candidate.object.get("file");
            const line = candidate.object.get("line");
            const line_end = candidate.object.get("line_end");
            if (file != null and file.? == .string and line != null and line.? == .integer and line_end != null and line_end.? == .integer) {
                try w.writeAll("{\"operation\":\"source\",\"path\":");
                try writeString(w, file.?.string);
                try w.print(",\"start_line\":{},\"end_line\":{},\"limit\":{}", .{ line.?.integer, line_end.?.integer, max_source_lines });
                try w.writeByte('}');
                return;
            }
        }
    }
    if (truncated and request.operation == .relations) {
        try w.writeAll("{\"operation\":\"symbol\",\"view\":\"definition\",\"selector\":");
        try writeString(w, request.selector);
        try w.writeByte('}');
    } else if (truncated and request.operation == .map and request.selector.len != 0) {
        try w.writeAll("{\"operation\":\"symbol\",\"view\":\"definition\",\"selector\":");
        try writeString(w, request.selector);
        try w.writeByte('}');
    }
}

fn parseWarningCount(idx: *const index_mod.Index) u32 {
    var count: u32 = 0;
    for (idx.graph.files) |file| {
        if (!file.parse_health.reliable()) count += 1;
    }
    return count;
}

const ResolutionHealth = struct { likely_local: u32 = 0, external_or_unmodeled: u32 = 0 };

fn resolutionWarningCounts(idx: *const index_mod.Index) ResolutionHealth {
    var counts: ResolutionHealth = .{};
    for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            const class = query.referenceDiagnosticClass(idx, sym, ref) orelse continue;
            switch (class) {
                .likely_local => counts.likely_local += 1,
                .external_or_unmodeled => counts.external_or_unmodeled += 1,
            }
        }
    }
    return counts;
}

fn writeResolutionHealth(w: *std.Io.Writer, idx: *const index_mod.Index) !void {
    const counts = resolutionWarningCounts(idx);
    try w.print(",\"resolution_health\":{{\"likely_local\":{},\"external_or_unmodeled\":{},\"scope\":\"call_type_import_edges\"}}", .{
        counts.likely_local,
        counts.external_or_unmodeled,
    });
}

fn warning(w: *std.Io.Writer, count: *u8, message: []const u8) !void {
    if (count.* != 0) try w.writeByte(',');
    count.* += 1;
    try writeString(w, message);
}

fn writeString(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, w);
}

test "typed agent schema is valid, closed, and at most 1200 bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(std.testing.allocator, &buf);
    defer aw.deinit();
    try writeInputSchema(&aw.writer);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("properties").?.object.get("operation") != null);
    try std.testing.expect(parsed.value.object.get("properties").?.object.get("view") != null);
    try std.testing.expect(aw.written().len <= 1200);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "args") == null);
}

test "typed agent decoder constructs canonical read-only requests" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"operation\":\"relations\",\"selector\":\"run\",\"view\":\"callers\",\"strict\":true,\"depth\":2}", .{});
    defer parsed.deinit();
    const request = try decode(std.testing.allocator, parsed.value);
    try std.testing.expectEqual(cli.Command.callers, request.parsed.command);
    try std.testing.expect(request.parsed.options.strict);
    try std.testing.expectEqual(@as(u32, 2), request.parsed.options.depth);
    try std.testing.expect(cli.registry.descriptor(request.parsed.command).access == .read_only);
}

test "typed agent decoder rejects cross-operation and unsafe combinations" {
    const cases = [_]struct { json: []const u8, expected: DecodeError }{
        .{ .json = "{\"operation\":\"source\",\"path\":\"a.zig\",\"start_line\":9,\"end_line\":2}", .expected = error.InvalidCombination },
        .{ .json = "{\"operation\":\"map\",\"path\":\"src\",\"query\":\"run\"}", .expected = error.InvalidCombination },
        .{ .json = "{\"operation\":\"symbol\",\"selector\":\"run\",\"to\":\"leaf\"}", .expected = error.UnknownField },
        .{ .json = "{\"operation\":\"impact\",\"view\":\"edit_sites\",\"since\":\"HEAD~1\"}", .expected = error.InvalidCombination },
        .{ .json = "{\"operation\":\"relations\",\"selector\":\"run\",\"view\":\"path\"}", .expected = error.InvalidCombination },
        .{ .json = "{\"operation\":\"map\",\"after\":\"9\"}", .expected = error.InvalidCursor },
        .{ .json = "{\"operation\":\"map\",\"after\":\"v1:10001\"}", .expected = error.NumberOutOfRange },
        .{ .json = "{\"operation\":\"impact\",\"view\":\"changed_symbols\",\"after\":\"v1:1\"}", .expected = error.InvalidCombination },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.expected, decode(std.testing.allocator, parsed.value));
    }
}

test "typed list envelope applies cursor before byte truncation and emits runnable next call" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var files: [0]model.SourceFile = .{};
    var symbols: [0]model.Symbol = .{};
    var callers: [0][]model.SymbolId = .{};
    var file_imports: [0][]const index_mod.FileImport = .{};
    var import_outcomes: [0][]const index_mod.FileImportOutcome = .{};
    var idx: index_mod.Index = .{
        .gpa = testing.allocator,
        .arena = &arena,
        .graph = .{ .files = &files, .symbols = &symbols },
        .by_name = .empty,
        .callers = &callers,
        .file_imports = &file_imports,
        .import_outcomes = &import_outcomes,
        .root = ".",
    };
    const request: Request = .{
        .operation = .map,
        .view = "files",
        .parsed = .{ .command = .files, .options = .{ .format = .json, .limit = 4, .max_nodes = 4 } },
        .max_bytes = max_max_bytes,
        .cursor_page = .{ .after = 1, .limit = 2 },
        .limit_may_truncate = true,
    };
    const envelope = try envelopeOwned(testing.allocator, &idx, 1, request, true, "[{\"id\":0},{\"id\":1},{\"id\":2},{\"id\":3}]");
    defer testing.allocator.free(envelope);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, envelope, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(usize, 2), root.get("items").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), root.get("items").?.array.items[0].object.get("id").?.integer);
    try testing.expectEqualStrings("v1:3", root.get("next").?.object.get("after").?.string);
    try testing.expectEqual(@as(i64, 2), root.get("next").?.object.get("limit").?.integer);
}

test "edit site review gaps lower envelope exactness and remain visible as a warning" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var files: [0]model.SourceFile = .{};
    var symbols: [0]model.Symbol = .{};
    var callers: [0][]model.SymbolId = .{};
    var file_imports: [0][]const index_mod.FileImport = .{};
    var import_outcomes: [0][]const index_mod.FileImportOutcome = .{};
    var idx: index_mod.Index = .{
        .gpa = testing.allocator,
        .arena = &arena,
        .graph = .{ .files = &files, .symbols = &symbols },
        .by_name = .empty,
        .callers = &callers,
        .file_imports = &file_imports,
        .import_outcomes = &import_outcomes,
        .root = ".",
    };
    const request: Request = .{
        .operation = .impact,
        .view = "edit_sites",
        .selector = "run",
        .parsed = .{ .command = .edits, .arg = "run", .options = .{ .format = .json } },
        .max_bytes = max_max_bytes,
        .cursor_page = .{ .after = 0, .limit = 1 },
    };
    const envelope = try envelopeOwned(testing.allocator, &idx, 1, request, true, "{\"target\":{},\"sites\":[{\"file\":\"a.zig\",\"line\":1},{\"file\":\"b.zig\",\"line\":2}],\"review_sites\":2}");
    defer testing.allocator.free(envelope);
    try testing.expect(std.mem.indexOf(u8, envelope, "\"exactness\":\"exact_sites_with_review_gaps\"") != null);
    try testing.expect(std.mem.indexOf(u8, envelope, "\"review_sites_present\"") != null);
    try testing.expect(std.mem.indexOf(u8, envelope, "\"after\":\"v1:1\"") != null);
}

test "likely-local diagnostics does not inherit external-only truncation or found state" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var files: [0]model.SourceFile = .{};
    var symbols: [0]model.Symbol = .{};
    var callers: [0][]model.SymbolId = .{};
    var file_imports: [0][]const index_mod.FileImport = .{};
    var import_outcomes: [0][]const index_mod.FileImportOutcome = .{};
    var idx: index_mod.Index = .{
        .gpa = testing.allocator,
        .arena = &arena,
        .graph = .{ .files = &files, .symbols = &symbols },
        .by_name = .empty,
        .callers = &callers,
        .file_imports = &file_imports,
        .import_outcomes = &import_outcomes,
        .root = ".",
    };
    const request: Request = .{
        .operation = .diagnostics,
        .view = "likely_local",
        .parsed = .{ .command = .status, .options = .{ .format = .json, .limit = 3 } },
        .max_bytes = max_max_bytes,
        .cursor_page = .{ .after = 0, .limit = 2 },
        .limit_may_truncate = true,
    };
    const raw = "{\"unresolved_references\":{\"count\":20,\"categories\":{\"likely_local\":0,\"external_or_unmodeled\":20},\"items\":[{\"resolution\":\"external_or_unmodeled\"}],\"truncated\":true}}";
    const envelope = try envelopeOwned(testing.allocator, &idx, 1, request, true, raw);
    defer testing.allocator.free(envelope);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, envelope, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(!root.get("found").?.bool);
    try testing.expect(!root.get("truncated").?.bool);
    try testing.expect(root.get("next").? == .null);
    try testing.expectEqual(@as(usize, 0), root.get("items").?.array.items.len);
}
