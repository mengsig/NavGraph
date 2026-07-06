//! Incremental on-disk cache of parsed files, keyed by path + mtime + size.
//!
//! Parsing (lex + bracket-match + scope walk) dominates index build time, so we
//! persist each file's parsed symbols to `.navgraph/cache`. On the next run,
//! files whose mtime and size are unchanged are restored from the cache instead
//! of re-parsed — turning repeated agent calls from ~parse-bound to ~stat-bound.
//!
//! The format is a single self-describing binary blob (little-endian,
//! length-prefixed). Only parse-time fields are stored; reference *targets* are
//! never cached because global symbol ids are recomputed on every build. A
//! version-tagged magic guards the format: any mismatch or truncation makes the
//! whole cache be ignored (a safe rebuild), never a crash.

const std = @import("std");
const language = @import("language.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");

const Language = language.Language;
const ParsedSymbol = parser.ParsedSymbol;
const Reference = model.Reference;
const Binding = model.Binding;
const invalid_local: u32 = std.math.maxInt(u32);

/// Bump the trailing digit whenever the on-disk layout changes.
const magic = "NGCACHE3";
const cache_dir = ".navgraph";
const cache_path = ".navgraph/cache";
const max_cache_bytes: usize = 256 * 1024 * 1024;

pub const FileStat = struct { mtime_ns: i128, size: u64 };

/// A restored file: its exact source text plus parsed symbols, both owned by the
/// caller-provided arena so they can be spliced straight into the graph.
pub const Restored = struct {
    text: []const u8,
    symbols: []ParsedSymbol,
};

/// One file's entry located within a loaded cache buffer, not yet materialized.
const Entry = struct {
    stat: FileStat,
    lang: Language,
    /// Sub-slice of `Store.bytes` covering this file's text + symbol records.
    blob: []const u8,
};

/// A loaded cache: the raw file bytes plus a path→entry index into them. Strings
/// (paths, and later materialized symbols) borrow from `bytes` until copied into
/// an arena, so `bytes` outlives every lookup for the duration of a build.
pub const Store = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
    entries: std.StringHashMapUnmanaged(Entry),

    pub fn deinit(self: *Store) void {
        self.entries.deinit(self.gpa);
        self.gpa.free(self.bytes);
    }

    /// Restore a file into `arena` iff the cache holds a matching (mtime, size)
    /// entry for `path`; otherwise null (caller re-parses).
    pub fn restore(self: *const Store, arena: std.mem.Allocator, path: []const u8, stat: FileStat) ?Restored {
        const e = self.entries.get(path) orelse return null;
        if (e.stat.mtime_ns != stat.mtime_ns or e.stat.size != stat.size) return null;
        return materialize(arena, e.blob) catch null;
    }
};

/// Load the cache under `root_dir`. Returns null (no crash) when the cache is
/// absent, unreadable, wrong-version, or corrupt — every such case is a safe
/// full rebuild rather than an error.
pub fn load(gpa: std.mem.Allocator, io: std.Io, root_dir: std.Io.Dir) ?Store {
    const bytes = root_dir.readFileAlloc(io, cache_path, gpa, .limited(max_cache_bytes)) catch return null;
    var store = Store{ .gpa = gpa, .bytes = bytes, .entries = .empty };
    indexEntries(&store) catch {
        store.deinit();
        return null;
    };
    return store;
}

fn indexEntries(store: *Store) !void {
    var cur = Cursor{ .bytes = store.bytes };
    const head = try cur.take(magic.len);
    if (!std.mem.eql(u8, head, magic)) return error.BadMagic;
    const count = try cur.getU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const stat = FileStat{ .mtime_ns = try cur.getI128(), .size = try cur.getU64() };
        const path = try cur.getStr();
        const lang = try cur.getLang();
        const blob = try readBlob(&cur);
        try store.entries.put(store.gpa, path, .{ .stat = stat, .lang = lang, .blob = blob });
    }
}

/// Read (and skip past) one file's text+symbols region, returning it as a slice.
fn readBlob(cur: *Cursor) ![]const u8 {
    const start = cur.pos;
    _ = try cur.getStr(); // text
    const sym_count = try cur.getU32();
    var s: u32 = 0;
    while (s < sym_count) : (s += 1) try skipSymbol(cur);
    return cur.bytes[start..cur.pos];
}

fn skipSymbol(cur: *Cursor) !void {
    _ = try cur.getStr(); // name
    _ = try cur.getU8(); // kind
    var f: u32 = 0;
    while (f < 5) : (f += 1) _ = try cur.getU32(); // line, span_start, span_end, sig_end, parent_local
    _ = try cur.getU8(); // exported
    _ = try cur.getStr(); // doc
    _ = try cur.getStr(); // import_path
    const ref_count = try cur.getU32();
    var r: u32 = 0;
    while (r < ref_count) : (r += 1) {
        _ = try cur.getStr(); // name
        _ = try cur.getStr(); // qualifier
        _ = try cur.getU32(); // line
        _ = try cur.getU8(); // kind
        _ = try cur.getU32(); // count
    }
    const bind_count = try cur.getU32();
    var b: u32 = 0;
    while (b < bind_count) : (b += 1) {
        _ = try cur.getStr(); // name
        _ = try cur.getStr(); // type_name
    }
}

// ---------------------------------------------------------------------------
// Materialize (cache -> arena)
// ---------------------------------------------------------------------------

fn materialize(arena: std.mem.Allocator, blob: []const u8) !Restored {
    var cur = Cursor{ .bytes = blob };
    const text = try arena.dupe(u8, try cur.getStr());
    const sym_count = try cur.getU32();
    const symbols = try arena.alloc(ParsedSymbol, sym_count);
    for (symbols) |*sym| sym.* = try readSymbol(arena, &cur);
    std.debug.assert(cur.pos == blob.len);
    return .{ .text = text, .symbols = symbols };
}

fn readSymbol(arena: std.mem.Allocator, cur: *Cursor) !ParsedSymbol {
    const name = try arena.dupe(u8, try cur.getStr());
    const kind = try cur.getKind();
    const line = try cur.getU32();
    const span_start = try cur.getU32();
    const span_end = try cur.getU32();
    const sig_end = try cur.getU32();
    const parent_raw = try cur.getU32();
    const exported = (try cur.getU8()) != 0;
    const doc = try arena.dupe(u8, try cur.getStr());
    const import_path = try arena.dupe(u8, try cur.getStr());
    std.debug.assert(span_start <= sig_end and sig_end <= span_end);
    return .{
        .name = name,
        .kind = kind,
        .line = line,
        .span_start = span_start,
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = doc,
        .exported = exported,
        .parent_local = if (parent_raw == invalid_local) null else parent_raw,
        .refs = try readRefs(arena, cur),
        .bindings = try readBindings(arena, cur),
        .import_path = import_path,
    };
}

fn readRefs(arena: std.mem.Allocator, cur: *Cursor) ![]Reference {
    const n = try cur.getU32();
    const refs = try arena.alloc(Reference, n);
    for (refs) |*ref| ref.* = .{
        .name = try arena.dupe(u8, try cur.getStr()),
        .qualifier = try arena.dupe(u8, try cur.getStr()),
        .line = try cur.getU32(),
        .kind = try cur.getRefKind(),
        .count = try cur.getU32(),
    };
    return refs;
}

fn readBindings(arena: std.mem.Allocator, cur: *Cursor) ![]const Binding {
    const n = try cur.getU32();
    const binds = try arena.alloc(Binding, n);
    for (binds) |*b| b.* = .{
        .name = try arena.dupe(u8, try cur.getStr()),
        .type_name = try arena.dupe(u8, try cur.getStr()),
    };
    return binds;
}

// ---------------------------------------------------------------------------
// Write (graph -> cache)
// ---------------------------------------------------------------------------

/// Serialize the whole graph to `.navgraph/cache` under `root_dir`. `stats[i]`
/// must correspond to `files[i]`. Best-effort: creating the dir or file may
/// legitimately fail (read-only tree) and the error is returned for the caller
/// to log and continue — the cache is an optimization, never required.
pub fn write(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    files: []const model.SourceFile,
    stats: []const FileStat,
    symbols: []const model.Symbol,
) !void {
    std.debug.assert(files.len == stats.len);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, magic);
    try putU32(gpa, &buf, @intCast(files.len));
    for (files, stats) |file, stat| try writeFile(gpa, &buf, file, stat, symbols);

    try root_dir.createDirPath(io, cache_dir);
    try root_dir.writeFile(io, .{ .sub_path = cache_path, .data = buf.items });
}

fn writeFile(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    file: model.SourceFile,
    stat: FileStat,
    symbols: []const model.Symbol,
) !void {
    std.debug.assert(file.sym_start <= file.sym_end);
    std.debug.assert(file.sym_end <= symbols.len);
    std.debug.assert(stat.size == file.text.len);
    try putI128(gpa, buf, stat.mtime_ns);
    try putU64(gpa, buf, stat.size);
    try putStr(gpa, buf, file.path);
    try buf.append(gpa, @intFromEnum(file.language));
    try putStr(gpa, buf, file.text);
    try putU32(gpa, buf, file.sym_end - file.sym_start);
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) try writeSymbol(gpa, buf, symbols[i], file.sym_start);
}

fn writeSymbol(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), sym: model.Symbol, base: u32) !void {
    try putStr(gpa, buf, sym.name);
    try buf.append(gpa, @intFromEnum(sym.kind));
    try putU32(gpa, buf, sym.line);
    try putU32(gpa, buf, sym.span_start);
    try putU32(gpa, buf, sym.span_end);
    try putU32(gpa, buf, sym.sig_end);
    try putU32(gpa, buf, localParent(sym, base));
    try buf.append(gpa, @intFromBool(sym.exported));
    try putStr(gpa, buf, sym.doc);
    try putStr(gpa, buf, sym.import_path);
    try putU32(gpa, buf, @intCast(sym.refs.len));
    for (sym.refs) |ref| {
        try putStr(gpa, buf, ref.name);
        try putStr(gpa, buf, ref.qualifier);
        try putU32(gpa, buf, ref.line);
        try buf.append(gpa, @intFromEnum(ref.kind));
        try putU32(gpa, buf, ref.count);
    }
    try putU32(gpa, buf, @intCast(sym.bindings.len));
    for (sym.bindings) |b| {
        try putStr(gpa, buf, b.name);
        try putStr(gpa, buf, b.type_name);
    }
}

/// A parent symbol id is always within the same file range; store it relative
/// to the file base so it survives global-id renumbering. `invalid` → sentinel.
fn localParent(sym: model.Symbol, base: u32) u32 {
    if (sym.parent == model.invalid_symbol) return invalid_local;
    std.debug.assert(sym.parent >= base);
    return sym.parent - base;
}

// ---------------------------------------------------------------------------
// Low-level encode helpers
// ---------------------------------------------------------------------------

fn putU8(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: u8) !void {
    try buf.append(gpa, v);
}
fn putU32(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try buf.appendSlice(gpa, &tmp);
}
fn putU64(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, v, .little);
    try buf.appendSlice(gpa, &tmp);
}
fn putI128(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), v: i128) !void {
    var tmp: [16]u8 = undefined;
    std.mem.writeInt(i128, &tmp, v, .little);
    try buf.appendSlice(gpa, &tmp);
}
fn putStr(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    std.debug.assert(s.len <= std.math.maxInt(u32));
    try putU32(gpa, buf, @intCast(s.len));
    try buf.appendSlice(gpa, s);
}

// ---------------------------------------------------------------------------
// Bounds-checked decode cursor
// ---------------------------------------------------------------------------

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn getU8(self: *Cursor) !u8 {
        return (try self.take(1))[0];
    }
    fn getU32(self: *Cursor) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }
    fn getU64(self: *Cursor) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }
    fn getI128(self: *Cursor) !i128 {
        return std.mem.readInt(i128, (try self.take(16))[0..16], .little);
    }
    fn getStr(self: *Cursor) ![]const u8 {
        const n = try self.getU32();
        return self.take(n);
    }
    fn getLang(self: *Cursor) !Language {
        return enumFromInt(Language, try self.getU8());
    }
    fn getKind(self: *Cursor) !model.SymbolKind {
        return enumFromInt(model.SymbolKind, try self.getU8());
    }
    fn getRefKind(self: *Cursor) !model.RefKind {
        return enumFromInt(model.RefKind, try self.getU8());
    }
};

fn enumFromInt(comptime E: type, raw: u8) !E {
    if (raw >= @typeInfo(E).@"enum".fields.len) return error.BadEnum;
    return @enumFromInt(raw);
}

test "cache round-trips a file's parsed symbols" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Parse a small source into symbols we can serialize.
    const source =
        \\pub const Foo = struct {
        \\    /// doc for stop
        \\    pub fn stop(self: *Foo, n: i32) void {
        \\        helper(n);
        \\    }
        \\};
    ;
    var parsed: std.ArrayList(ParsedSymbol) = .empty;
    defer parsed.deinit(testing.allocator);
    try parser.parse(testing.allocator, arena, source, .zig, &parsed);
    try testing.expect(parsed.items.len >= 2);

    // Promote parsed symbols into graph Symbols (mirrors index.zig).
    var syms: std.ArrayList(model.Symbol) = .empty;
    defer syms.deinit(testing.allocator);
    for (parsed.items, 0..) |p, i| try syms.append(testing.allocator, promote(p, @intCast(i)));
    const files = [_]model.SourceFile{.{
        .id = 0,
        .path = "m.zig",
        .language = .zig,
        .text = source,
        .sym_start = 0,
        .sym_end = @intCast(syms.items.len),
    }};
    const stats = [_]FileStat{.{ .mtime_ns = 123, .size = source.len }};

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(testing.allocator, testing.io, tmp.dir, &files, &stats, syms.items);

    var store = load(testing.allocator, testing.io, tmp.dir).?;
    defer store.deinit();
    const hit = store.restore(arena, "m.zig", stats[0]).?;
    try testing.expectEqualStrings(source, hit.text);
    try testing.expectEqual(parsed.items.len, hit.symbols.len);
    try testing.expectEqualStrings(parsed.items[0].name, hit.symbols[0].name);
    // A changed mtime misses; an absent path misses.
    try testing.expect(store.restore(arena, "m.zig", .{ .mtime_ns = 999, .size = source.len }) == null);
    try testing.expect(store.restore(arena, "other.zig", stats[0]) == null);
}

fn promote(p: ParsedSymbol, id: u32) model.Symbol {
    return .{
        .id = id,
        .file = 0,
        .name = p.name,
        .kind = p.kind,
        .line = p.line,
        .span_start = p.span_start,
        .span_end = p.span_end,
        .sig_end = p.sig_end,
        .doc = p.doc,
        .parent = if (p.parent_local) |pl| pl else model.invalid_symbol,
        .exported = p.exported,
        .refs = p.refs,
        .bindings = p.bindings,
    };
}
