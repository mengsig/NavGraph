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
const build_options = @import("build_options");
const language = @import("language.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");

const Language = language.Language;
const ParsedSymbol = parser.ParsedSymbol;
const Reference = model.Reference;
const Binding = model.Binding;
const invalid_local: u32 = std.math.maxInt(u32);

/// Bump the trailing digit whenever the on-disk *layout* changes. Logic changes
/// (parser/indexer) are guarded separately by `build_key` below, so you only
/// touch this when the byte format itself moves.
const magic = "NGCACHE10";

/// A fingerprint of NavGraph's own source, injected by `build.zig`. It is
/// written into every cache header and checked on load: a cache produced by a
/// binary with different indexer logic is ignored (a safe rebuild) even when the
/// serialized layout is unchanged. This is what stops a stale cache from
/// silently masking a parser fix — the failure mode that made an older NavGraph
/// serve wrong `imports`/`routes` results after its own bugs were fixed.
const build_key: u64 = build_options.cache_key;
const cache_dir = ".navgraph";
const cache_path = ".navgraph/cache";
const max_cache_bytes: usize = 256 * 1024 * 1024;

/// The stat fields that key a cached parse. `ctime_ns` (inode status-change
/// time) is included alongside `mtime_ns` because tools like `tar -x`, `cp -p`,
/// and `rsync --times` preserve mtime but cannot backdate ctime — so a
/// same-size restore that keeps mtime still busts the entry. All three are pure
/// `stat` fields: matching stays read-free (no hashing file contents).
pub const FileStat = struct { mtime_ns: i128, ctime_ns: i128, size: u64 };

/// A restored file: its exact source text plus parsed symbols, both owned by the
/// caller-provided arena so they can be spliced straight into the graph.
pub const Restored = struct {
    text: []const u8,
    symbols: []ParsedSymbol,
    parse_health: model.ParseHealth,
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
        if (e.stat.mtime_ns != stat.mtime_ns or e.stat.ctime_ns != stat.ctime_ns or
            e.stat.size != stat.size) return null;
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
    if ((try cur.getU64()) != build_key) return error.StaleBuild;
    const count = try cur.getU32();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const stat = FileStat{
            .mtime_ns = try cur.getI128(),
            .ctime_ns = try cur.getI128(),
            .size = try cur.getU64(),
        };
        const path = try cur.getStr();
        const lang = try cur.getLang();
        const blob = try readBlob(&cur);
        try store.entries.put(store.gpa, path, .{ .stat = stat, .lang = lang, .blob = blob });
    }
    if (cur.pos != store.bytes.len) return error.TrailingData;
}

/// Read (and skip past) one file's text+symbols region, returning it as a slice.
fn readBlob(cur: *Cursor) ![]const u8 {
    const start = cur.pos;
    _ = try readHealth(cur);
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
    _ = try cur.getU8(); // modifiers
    _ = try cur.getStr(); // doc
    _ = try cur.getStr(); // import_path
    _ = try cur.getStr(); // receiver
    _ = try cur.getStr(); // impl_protocol
    const ref_count = try cur.getU32();
    var r: u32 = 0;
    while (r < ref_count) : (r += 1) {
        _ = try cur.getStr(); // name
        _ = try cur.getStr(); // qualifier
        _ = try cur.getU32(); // line
        _ = try cur.getU8(); // kind
        _ = try cur.getU8(); // write
        _ = try cur.getU32(); // count
        const nlines = try cur.getU32(); // distinct call-site lines
        var l: u32 = 0;
        while (l < nlines) : (l += 1) _ = try cur.getU32();
        const noffsets = try cur.getU32(); // exact occurrence byte offsets
        var o: u32 = 0;
        while (o < noffsets) : (o += 1) _ = try cur.getU32();
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
    const parse_health = try readHealth(&cur);
    const text = try arena.dupe(u8, try cur.getStr());
    const sym_count = try cur.getU32();
    const symbols = try arena.alloc(ParsedSymbol, sym_count);
    for (symbols) |*sym| sym.* = try readSymbol(arena, &cur);
    if (cur.pos != blob.len) return error.TrailingData;
    return .{ .text = text, .symbols = symbols, .parse_health = parse_health };
}

fn readHealth(cur: *Cursor) !model.ParseHealth {
    const from_raw = try cur.getU32();
    const to = try cur.getU32();
    if (from_raw == 0) {
        if (to != 0) return error.BadParseHealth;
        return .{};
    }
    if (to < from_raw) return error.BadParseHealth;
    return .{ .desync_from = from_raw, .desync_to = to };
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
    const modifiers: model.Mods = @bitCast(try cur.getU8());
    const doc = try arena.dupe(u8, try cur.getStr());
    const import_path = try arena.dupe(u8, try cur.getStr());
    const receiver = try arena.dupe(u8, try cur.getStr());
    const impl_protocol = try arena.dupe(u8, try cur.getStr());
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
        .modifiers = modifiers,
        .parent_local = if (parent_raw == invalid_local) null else parent_raw,
        .refs = try readRefs(arena, cur),
        .bindings = try readBindings(arena, cur),
        .receiver = receiver,
        .impl_protocol = impl_protocol,
        .import_path = import_path,
    };
}

fn readRefs(arena: std.mem.Allocator, cur: *Cursor) ![]Reference {
    const n = try cur.getU32();
    const refs = try arena.alloc(Reference, n);
    for (refs) |*ref| {
        const name = try arena.dupe(u8, try cur.getStr());
        const qualifier = try arena.dupe(u8, try cur.getStr());
        const line = try cur.getU32();
        const kind = try cur.getRefKind();
        const is_write = try cur.getU8() != 0;
        const count = try cur.getU32();
        const nlines = try cur.getU32();
        const lines = try arena.alloc(u32, nlines);
        for (lines) |*ln| ln.* = try cur.getU32();
        const noffsets = try cur.getU32();
        const offsets = try arena.alloc(u32, noffsets);
        for (offsets) |*offset| offset.* = try cur.getU32();
        ref.* = .{
            .name = name,
            .qualifier = qualifier,
            .line = line,
            .kind = kind,
            .write = is_write,
            .count = count,
            .lines = lines,
            .offsets = offsets,
        };
    }
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
    try putU64(gpa, &buf, build_key);
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
    try putI128(gpa, buf, stat.ctime_ns);
    try putU64(gpa, buf, stat.size);
    try putStr(gpa, buf, file.path);
    try buf.append(gpa, @intFromEnum(file.language));
    try putHealth(gpa, buf, file.parse_health);
    try putStr(gpa, buf, file.text);
    try putU32(gpa, buf, file.sym_end - file.sym_start);
    var i = file.sym_start;
    while (i < file.sym_end) : (i += 1) {
        try writeSymbol(gpa, buf, symbols[i], file.sym_start, file.sym_end);
    }
}

fn writeSymbol(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    sym: model.Symbol,
    base: u32,
    end: u32,
) !void {
    try putStr(gpa, buf, sym.name);
    try buf.append(gpa, @intFromEnum(sym.kind));
    try putU32(gpa, buf, sym.line);
    try putU32(gpa, buf, sym.span_start);
    try putU32(gpa, buf, sym.span_end);
    try putU32(gpa, buf, sym.sig_end);
    try putU32(gpa, buf, localParent(sym, base, end));
    try buf.append(gpa, @intFromBool(sym.exported));
    try buf.append(gpa, @as(u8, @bitCast(sym.modifiers)));
    try putStr(gpa, buf, sym.doc);
    try putStr(gpa, buf, sym.import_path);
    try putStr(gpa, buf, sym.receiver);
    try putStr(gpa, buf, sym.impl_protocol);
    try putU32(gpa, buf, @intCast(sym.refs.len));
    for (sym.refs) |ref| {
        try putStr(gpa, buf, ref.name);
        try putStr(gpa, buf, ref.qualifier);
        try putU32(gpa, buf, ref.line);
        try buf.append(gpa, @intFromEnum(ref.kind));
        try buf.append(gpa, @intFromBool(ref.write));
        try putU32(gpa, buf, ref.count);
        try putU32(gpa, buf, @intCast(ref.lines.len));
        for (ref.lines) |ln| try putU32(gpa, buf, ln);
        try putU32(gpa, buf, @intCast(ref.offsets.len));
        for (ref.offsets) |offset| try putU32(gpa, buf, offset);
    }
    try putU32(gpa, buf, @intCast(sym.bindings.len));
    for (sym.bindings) |b| {
        try putStr(gpa, buf, b.name);
        try putStr(gpa, buf, b.type_name);
    }
}

/// Store same-file parents relative to the file base so they survive global-id
/// renumbering. Cross-file parents are reconstructed from receiver metadata;
/// `invalid` and cross-file ids both serialize as the sentinel.
fn localParent(sym: model.Symbol, base: u32, end: u32) u32 {
    if (sym.parent == model.invalid_symbol) return invalid_local;
    // Cross-file owners are reconstructed from `receiver` after all cached
    // files are restored; the per-file cache can only encode local parent ids.
    if (sym.parent < base or sym.parent >= end) return invalid_local;
    return sym.parent - base;
}

// ---------------------------------------------------------------------------
// Low-level encode helpers
// ---------------------------------------------------------------------------

fn putHealth(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), health: model.ParseHealth) !void {
    const from = health.desync_from orelse 0;
    std.debug.assert((from == 0) == (health.desync_to == 0));
    try putU32(gpa, buf, from);
    try putU32(gpa, buf, health.desync_to);
}

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
    _ = try parser.parse(testing.allocator, arena, source, .zig, &parsed);
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
        .parse_health = .{ .desync_from = 3, .desync_to = 5 },
        .sym_start = 0,
        .sym_end = @intCast(syms.items.len),
    }};
    const stats = [_]FileStat{.{ .mtime_ns = 123, .ctime_ns = 456, .size = source.len }};

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(testing.allocator, testing.io, tmp.dir, &files, &stats, syms.items);

    var store = load(testing.allocator, testing.io, tmp.dir).?;
    defer store.deinit();
    const hit = store.restore(arena, "m.zig", stats[0]).?;
    try testing.expectEqualStrings(source, hit.text);
    try testing.expectEqual(@as(?u32, 3), hit.parse_health.desync_from);
    try testing.expectEqual(@as(u32, 5), hit.parse_health.desync_to);
    try testing.expectEqual(parsed.items.len, hit.symbols.len);
    try testing.expectEqualStrings(parsed.items[0].name, hit.symbols[0].name);
    // A changed mtime misses; a changed ctime misses; an absent path misses.
    try testing.expect(store.restore(arena, "m.zig", .{ .mtime_ns = 999, .ctime_ns = 456, .size = source.len }) == null);
    try testing.expect(store.restore(arena, "m.zig", .{ .mtime_ns = 123, .ctime_ns = 999, .size = source.len }) == null);
    try testing.expect(store.restore(arena, "other.zig", stats[0]) == null);
}

test "a cache stamped with a different build key is ignored" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Write a minimal valid cache (zero files is enough — we only exercise the
    // header check), then flip a byte inside the build-key field on disk to
    // simulate a cache produced by a binary with different indexer logic.
    const empty_files = [_]model.SourceFile{};
    const empty_stats = [_]FileStat{};
    try write(testing.allocator, testing.io, tmp.dir, &empty_files, &empty_stats, &.{});

    const raw = try tmp.dir.readFileAlloc(testing.io, cache_path, testing.allocator, .unlimited);
    defer testing.allocator.free(raw);
    // The build key is the u64 immediately after the magic; a matching cache
    // loads, a tampered one must not.
    var loaded = load(testing.allocator, testing.io, tmp.dir);
    if (loaded) |*store| store.deinit() else return error.ValidCacheRejected;
    raw[magic.len] +%= 1;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = cache_path, .data = raw });
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
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
        .modifiers = p.modifiers,
        .refs = p.refs,
        .bindings = p.bindings,
        .receiver = p.receiver,
        .impl_protocol = p.impl_protocol,
    };
}

// ---------------------------------------------------------------------------
// Appended tests: exhaustive coverage of cache serialization round-trips,
// corruption safety, cursor bounds, and enum validation.
// ---------------------------------------------------------------------------

/// A test-only description of one serialized reference record (mirrors the
/// on-disk ref layout so we can hand-build blobs with chosen enum bytes).
const TestRef = struct {
    name: []const u8 = "",
    qualifier: []const u8 = "",
    line: u32 = 1,
    kind: u8 = 0,
    write: bool = false,
    count: u32 = 1,
    lines: []const u32 = &[_]u32{},
    offsets: []const u32 = &[_]u32{},
};

/// Hand-encode one symbol record in exactly the byte layout `readSymbol`
/// expects, letting a test inject arbitrary (possibly out-of-range) enum bytes.
fn encSym(
    a: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    name: []const u8,
    kind_byte: u8,
    parent_raw: u32,
    exported_byte: u8,
    mods_byte: u8,
    doc: []const u8,
    import_path: []const u8,
    refs: []const TestRef,
    binds: []const Binding,
) !void {
    try putStr(a, buf, name);
    try putU8(a, buf, kind_byte);
    try putU32(a, buf, 1); // line
    try putU32(a, buf, 0); // span_start
    try putU32(a, buf, 8); // span_end
    try putU32(a, buf, 4); // sig_end
    try putU32(a, buf, parent_raw);
    try putU8(a, buf, exported_byte);
    try putU8(a, buf, mods_byte);
    try putStr(a, buf, doc);
    try putStr(a, buf, import_path);
    try putStr(a, buf, ""); // receiver
    try putStr(a, buf, ""); // impl_protocol
    try putU32(a, buf, @intCast(refs.len));
    for (refs) |r| {
        try putStr(a, buf, r.name);
        try putStr(a, buf, r.qualifier);
        try putU32(a, buf, r.line);
        try putU8(a, buf, r.kind);
        try putU8(a, buf, @intFromBool(r.write));
        try putU32(a, buf, r.count);
        try putU32(a, buf, @intCast(r.lines.len));
        for (r.lines) |ln| try putU32(a, buf, ln);
        try putU32(a, buf, @intCast(r.offsets.len));
        for (r.offsets) |offset| try putU32(a, buf, offset);
    }
    try putU32(a, buf, @intCast(binds.len));
    for (binds) |b| {
        try putStr(a, buf, b.name);
        try putStr(a, buf, b.type_name);
    }
}

/// Hand-encode a whole cache holding exactly one entry with an empty symbol
/// list. `lang_byte` is written verbatim so a test can drive `getLang`.
fn buildOneEntryCache(
    a: std.mem.Allocator,
    path: []const u8,
    lang_byte: u8,
    mtime: i128,
    ctime: i128,
    text: []const u8,
) !std.ArrayList(u8) {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, magic);
    try putU64(a, &buf, build_key);
    try putU32(a, &buf, 1); // entry count
    try putI128(a, &buf, mtime);
    try putI128(a, &buf, ctime);
    try putU64(a, &buf, @intCast(text.len)); // size
    try putStr(a, &buf, path);
    try putU8(a, &buf, lang_byte);
    try putHealth(a, &buf, .{});
    try putStr(a, &buf, text); // blob: text
    try putU32(a, &buf, 0); // blob: sym_count
    return buf;
}

/// Write raw bytes to the cache path under a tmp dir (creating `.navgraph`).
fn writeRawCache(tmp: *std.testing.TmpDir, bytes: []const u8) !void {
    try tmp.dir.createDirPath(std.testing.io, cache_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = cache_path, .data = bytes });
}

/// Assert a restored ParsedSymbol equals the originating graph Symbol across
/// every cached field. `base` is the file's `sym_start` (parent ids are stored
/// base-relative).
fn expectSymEq(base: u32, expected: model.Symbol, got: ParsedSymbol) !void {
    const t = std.testing;
    try t.expectEqualStrings(expected.name, got.name);
    try t.expectEqual(expected.kind, got.kind);
    try t.expectEqual(expected.line, got.line);
    try t.expectEqual(expected.span_start, got.span_start);
    try t.expectEqual(expected.span_end, got.span_end);
    try t.expectEqual(expected.sig_end, got.sig_end);
    try t.expectEqual(expected.exported, got.exported);
    try t.expectEqual(@as(u8, @bitCast(expected.modifiers)), @as(u8, @bitCast(got.modifiers)));
    try t.expectEqualStrings(expected.doc, got.doc);
    try t.expectEqualStrings(expected.import_path, got.import_path);
    try t.expectEqualStrings(expected.receiver, got.receiver);
    try t.expectEqualStrings(expected.impl_protocol, got.impl_protocol);
    if (expected.parent == model.invalid_symbol) {
        try t.expectEqual(@as(?u32, null), got.parent_local);
    } else {
        try t.expectEqual(@as(?u32, expected.parent - base), got.parent_local);
    }
    try t.expectEqual(expected.refs.len, got.refs.len);
    for (expected.refs, got.refs) |er, gr| {
        try t.expectEqualStrings(er.name, gr.name);
        try t.expectEqualStrings(er.qualifier, gr.qualifier);
        try t.expectEqual(er.line, gr.line);
        try t.expectEqual(er.kind, gr.kind);
        try t.expectEqual(er.write, gr.write);
        try t.expectEqual(er.count, gr.count);
        try t.expectEqualSlices(u32, er.lines, gr.lines);
        try t.expectEqualSlices(u32, er.offsets, gr.offsets);
    }
    try t.expectEqual(expected.bindings.len, got.bindings.len);
    for (expected.bindings, got.bindings) |eb, gb| {
        try t.expectEqualStrings(eb.name, gb.name);
        try t.expectEqualStrings(eb.type_name, gb.type_name);
    }
}

test "full round-trip preserves every field across two files with distinct languages" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // File A (zig): a struct + a method (parent-relative), the method carrying
    // rich refs (multi-line + qualified) and bindings, plus modifiers.
    const textA = "pub const Container = struct { pub fn run() void {} };\n    // pad pad\n";
    const textB = "import numpy as np\ncount = 0\n";

    var no_refs = [_]Reference{};
    var refs1 = [_]Reference{
        .{ .name = "helper", .qualifier = "", .line = 30, .kind = .call, .count = 3, .lines = &[_]u32{ 30, 33, 40 }, .offsets = &[_]u32{ 2, 7, 12 } },
        .{ .name = "Widget", .qualifier = "w", .line = 31, .kind = .type_use, .count = 1, .lines = &[_]u32{}, .offsets = &[_]u32{8} },
    };
    const binds1 = [_]Binding{
        .{ .name = "tmp", .type_name = "i32" },
        .{ .name = "w", .type_name = "Widget" },
    };
    var refs3 = [_]Reference{
        .{ .name = "total", .qualifier = "self", .line = 5, .kind = .read, .write = true, .count = 2, .lines = &[_]u32{ 5, 6 }, .offsets = &[_]u32{ 1, 5 } },
    };

    var syms = [_]model.Symbol{
        .{ .id = 0, .file = 0, .name = "Container", .kind = .@"struct", .line = 1, .span_start = 0, .span_end = 20, .sig_end = 10, .doc = "/// A container", .parent = model.invalid_symbol, .exported = true, .refs = &no_refs },
        .{ .id = 1, .file = 0, .name = "run", .kind = .method, .line = 3, .span_start = 20, .span_end = 30, .sig_end = 25, .doc = "", .parent = 0, .exported = false, .modifiers = .{ .is_async = true, .getter = true }, .refs = &refs1, .bindings = &binds1, .receiver = "Container", .impl_protocol = "Runnable" },
        // File B (python): an import (carries import_path) + a variable whose
        // parent points base-relative into file B to exercise the base offset.
        .{ .id = 2, .file = 1, .name = "np", .kind = .import, .line = 1, .span_start = 0, .span_end = 10, .sig_end = 8, .doc = "", .parent = model.invalid_symbol, .exported = false, .import_path = "numpy", .refs = &no_refs },
        .{ .id = 3, .file = 1, .name = "count", .kind = .variable, .line = 2, .span_start = 10, .span_end = 25, .sig_end = 18, .doc = "/// counter", .parent = 2, .exported = true, .modifiers = .{ .is_static = true }, .refs = &refs3 },
    };

    const files = [_]model.SourceFile{
        .{ .id = 0, .path = "a.zig", .language = .zig, .text = textA, .sym_start = 0, .sym_end = 2 },
        .{ .id = 1, .path = "b.py", .language = .python, .text = textB, .parse_health = .{ .desync_from = 2, .desync_to = 4 }, .sym_start = 2, .sym_end = 4 },
    };
    const stats = [_]FileStat{
        .{ .mtime_ns = 1000, .ctime_ns = 2000, .size = textA.len },
        .{ .mtime_ns = 3000, .ctime_ns = 4000, .size = textB.len },
    };

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(testing.allocator, testing.io, tmp.dir, &files, &stats, &syms);

    var store = load(testing.allocator, testing.io, tmp.dir).?;
    defer store.deinit();
    try testing.expectEqual(@as(u32, 2), store.entries.count());
    try testing.expectEqual(Language.zig, store.entries.get("a.zig").?.lang);
    try testing.expectEqual(Language.python, store.entries.get("b.py").?.lang);

    const hitA = store.restore(arena, "a.zig", stats[0]).?;
    try testing.expectEqualStrings(textA, hitA.text);
    try testing.expectEqual(@as(usize, 2), hitA.symbols.len);
    try expectSymEq(0, syms[0], hitA.symbols[0]);
    try expectSymEq(0, syms[1], hitA.symbols[1]);

    const hitB = store.restore(arena, "b.py", stats[1]).?;
    try testing.expectEqualStrings(textB, hitB.text);
    try testing.expectEqual(@as(?u32, 2), hitB.parse_health.desync_from);
    try testing.expectEqual(@as(u32, 4), hitB.parse_health.desync_to);
    try testing.expectEqual(@as(usize, 2), hitB.symbols.len);
    try expectSymEq(2, syms[2], hitB.symbols[0]);
    try expectSymEq(2, syms[3], hitB.symbols[1]);

    // A size mismatch (mtime/ctime intact) still misses.
    try testing.expect(store.restore(arena, "a.zig", .{ .mtime_ns = 1000, .ctime_ns = 2000, .size = 99999 }) == null);
}

test "putU8 appends a single byte and cursor reads it back" {
    const testing = std.testing;
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putU8(a, &buf, 0);
    try putU8(a, &buf, 200);
    try putU8(a, &buf, 255);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 200, 255 }, buf.items);
    var cur = Cursor{ .bytes = buf.items };
    try testing.expectEqual(@as(u8, 0), try cur.getU8());
    try testing.expectEqual(@as(u8, 200), try cur.getU8());
    try testing.expectEqual(@as(u8, 255), try cur.getU8());
    // Exhausted cursor errors rather than reading past end.
    try testing.expectError(error.Truncated, cur.getU8());
}

test "encode helpers write little-endian bytes" {
    const testing = std.testing;
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putU32(a, &buf, 0x01020304);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x04, 0x03, 0x02, 0x01 }, buf.items);
    buf.clearRetainingCapacity();
    try putU64(a, &buf, 0x0102030405060708);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 }, buf.items);
    buf.clearRetainingCapacity();
    try putStr(a, &buf, "AB");
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 0, 0, 0, 'A', 'B' }, buf.items);
}

test "encode/decode helpers round-trip edge values" {
    const testing = std.testing;
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putU8(a, &buf, 0);
    try putU8(a, &buf, 255);
    try putU32(a, &buf, 0);
    try putU32(a, &buf, std.math.maxInt(u32));
    try putU64(a, &buf, 0);
    try putU64(a, &buf, std.math.maxInt(u64));
    try putI128(a, &buf, std.math.minInt(i128));
    try putI128(a, &buf, std.math.maxInt(i128));
    try putI128(a, &buf, -1);
    try putStr(a, &buf, "");
    try putStr(a, &buf, "round trip");
    var cur = Cursor{ .bytes = buf.items };
    try testing.expectEqual(@as(u8, 0), try cur.getU8());
    try testing.expectEqual(@as(u8, 255), try cur.getU8());
    try testing.expectEqual(@as(u32, 0), try cur.getU32());
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), try cur.getU32());
    try testing.expectEqual(@as(u64, 0), try cur.getU64());
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), try cur.getU64());
    try testing.expectEqual(@as(i128, std.math.minInt(i128)), try cur.getI128());
    try testing.expectEqual(@as(i128, std.math.maxInt(i128)), try cur.getI128());
    try testing.expectEqual(@as(i128, -1), try cur.getI128());
    try testing.expectEqualStrings("", try cur.getStr());
    try testing.expectEqualStrings("round trip", try cur.getStr());
    try testing.expectEqual(buf.items.len, cur.pos);
    try testing.expectError(error.Truncated, cur.getU8());
}

test "cursor take yields exact bytes and errors past the end" {
    const testing = std.testing;
    const data = [_]u8{ 10, 20, 30, 40 };
    var cur = Cursor{ .bytes = &data };
    try testing.expectEqualSlices(u8, &[_]u8{ 10, 20 }, try cur.take(2));
    try testing.expectEqualSlices(u8, &[_]u8{ 30, 40 }, try cur.take(2));
    try testing.expectError(error.Truncated, cur.take(1));
    // take(0) at the exact end is a valid empty slice, not an error.
    try testing.expectEqualSlices(u8, &[_]u8{}, try cur.take(0));
}

test "getStr with a length exceeding the buffer is Truncated" {
    const testing = std.testing;
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putU32(a, &buf, 100); // claims a 100-byte payload that isn't present
    var cur = Cursor{ .bytes = buf.items };
    try testing.expectError(error.Truncated, cur.getStr());
}

test "fixed-width getters error on short input" {
    const testing = std.testing;
    {
        var c = Cursor{ .bytes = &[_]u8{ 1, 2, 3 } };
        try testing.expectError(error.Truncated, c.getU32());
    }
    {
        var c = Cursor{ .bytes = &[_]u8{ 1, 2, 3, 4, 5, 6, 7 } };
        try testing.expectError(error.Truncated, c.getU64());
    }
    {
        var c = Cursor{ .bytes = &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } };
        try testing.expectError(error.Truncated, c.getI128());
    }
    {
        var c = Cursor{ .bytes = &[_]u8{} };
        try testing.expectError(error.Truncated, c.getU8());
    }
}

test "enumFromInt accepts in-range values and rejects out-of-range" {
    const testing = std.testing;
    inline for (@typeInfo(Language).@"enum".fields) |f| {
        try testing.expectEqual(@as(Language, @enumFromInt(f.value)), try enumFromInt(Language, @intCast(f.value)));
    }
    try testing.expectError(error.BadEnum, enumFromInt(Language, @intCast(@typeInfo(Language).@"enum".fields.len)));
    try testing.expectError(error.BadEnum, enumFromInt(Language, 255));

    inline for (@typeInfo(model.SymbolKind).@"enum".fields) |f| {
        try testing.expectEqual(@as(model.SymbolKind, @enumFromInt(f.value)), try enumFromInt(model.SymbolKind, @intCast(f.value)));
    }
    try testing.expectError(error.BadEnum, enumFromInt(model.SymbolKind, @intCast(@typeInfo(model.SymbolKind).@"enum".fields.len)));

    inline for (@typeInfo(model.RefKind).@"enum".fields) |f| {
        try testing.expectEqual(@as(model.RefKind, @enumFromInt(f.value)), try enumFromInt(model.RefKind, @intCast(f.value)));
    }
    try testing.expectError(error.BadEnum, enumFromInt(model.RefKind, @intCast(@typeInfo(model.RefKind).@"enum".fields.len)));
}

test "cursor enum getters decode valid bytes and reject out-of-range" {
    const testing = std.testing;
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putU8(a, &buf, @intFromEnum(Language.rust));
    try putU8(a, &buf, @intFromEnum(model.SymbolKind.method));
    try putU8(a, &buf, @intFromEnum(model.RefKind.type_use));
    var cur = Cursor{ .bytes = buf.items };
    try testing.expectEqual(Language.rust, try cur.getLang());
    try testing.expectEqual(model.SymbolKind.method, try cur.getKind());
    try testing.expectEqual(model.RefKind.type_use, try cur.getRefKind());

    {
        var c = Cursor{ .bytes = &[_]u8{200} };
        try testing.expectError(error.BadEnum, c.getLang());
    }
    {
        var c = Cursor{ .bytes = &[_]u8{200} };
        try testing.expectError(error.BadEnum, c.getKind());
    }
    {
        var c = Cursor{ .bytes = &[_]u8{200} };
        try testing.expectError(error.BadEnum, c.getRefKind());
    }
    // An empty buffer truncates before it can even read the enum byte.
    {
        var c = Cursor{ .bytes = &[_]u8{} };
        try testing.expectError(error.Truncated, c.getLang());
    }
}

test "materialize reconstructs all scalar, string, ref and binding fields" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const a = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putHealth(a, &buf, .{ .desync_from = 7, .desync_to = 9 });
    try putStr(a, &buf, "the text"); // blob text
    try putU32(a, &buf, 2); // sym_count

    const mods = model.Mods{ .is_async = true, .setter = true };
    const mods_byte = @as(u8, @bitCast(mods));
    const refs = [_]TestRef{
        .{ .name = "helper", .qualifier = "", .line = 30, .kind = @intFromEnum(model.RefKind.call), .count = 3, .lines = &[_]u32{ 30, 33, 40 } },
        .{ .name = "Widget", .qualifier = "w", .line = 31, .kind = @intFromEnum(model.RefKind.type_use), .count = 1, .lines = &[_]u32{} },
    };
    const binds = [_]Binding{
        .{ .name = "tmp", .type_name = "i32" },
        .{ .name = "w", .type_name = "Widget" },
    };
    // sym0: parent invalid -> null; carries doc, import_path, modifiers, refs, binds.
    try encSym(a, &buf, "run", @intFromEnum(model.SymbolKind.method), invalid_local, 1, mods_byte, "/// doc", "mod.zig", &refs, &binds);
    // sym1: parent id 0 -> parent_local 0 (distinct from null).
    try encSym(a, &buf, "leaf", @intFromEnum(model.SymbolKind.field), 0, 0, 0, "", "", &.{}, &.{});

    const r = try materialize(arena, buf.items);
    try testing.expectEqualStrings("the text", r.text);
    try testing.expectEqual(@as(?u32, 7), r.parse_health.desync_from);
    try testing.expectEqual(@as(u32, 9), r.parse_health.desync_to);
    try testing.expectEqual(@as(usize, 2), r.symbols.len);

    const s0 = r.symbols[0];
    try testing.expectEqualStrings("run", s0.name);
    try testing.expectEqual(model.SymbolKind.method, s0.kind);
    try testing.expect(s0.exported);
    try testing.expectEqual(mods_byte, @as(u8, @bitCast(s0.modifiers)));
    try testing.expectEqualStrings("/// doc", s0.doc);
    try testing.expectEqualStrings("mod.zig", s0.import_path);
    try testing.expectEqual(@as(?u32, null), s0.parent_local);
    try testing.expectEqual(@as(usize, 2), s0.refs.len);
    try testing.expectEqualStrings("helper", s0.refs[0].name);
    try testing.expectEqualStrings("", s0.refs[0].qualifier);
    try testing.expectEqual(@as(u32, 30), s0.refs[0].line);
    try testing.expectEqual(model.RefKind.call, s0.refs[0].kind);
    try testing.expectEqual(@as(u32, 3), s0.refs[0].count);
    try testing.expectEqualSlices(u32, &[_]u32{ 30, 33, 40 }, s0.refs[0].lines);
    try testing.expectEqualStrings("w", s0.refs[1].qualifier);
    try testing.expectEqual(model.RefKind.type_use, s0.refs[1].kind);
    try testing.expectEqual(@as(usize, 0), s0.refs[1].lines.len);
    try testing.expectEqual(@as(usize, 2), s0.bindings.len);
    try testing.expectEqualStrings("tmp", s0.bindings[0].name);
    try testing.expectEqualStrings("i32", s0.bindings[0].type_name);
    try testing.expectEqualStrings("Widget", s0.bindings[1].type_name);

    const s1 = r.symbols[1];
    try testing.expectEqual(@as(?u32, 0), s1.parent_local);
    try testing.expectEqual(model.SymbolKind.field, s1.kind);
    try testing.expect(!s1.exported);
}

test "materialize decodes every SymbolKind value" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const a = testing.allocator;
    inline for (@typeInfo(model.SymbolKind).@"enum".fields) |f| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try putHealth(a, &buf, .{});
        try putStr(a, &buf, "t");
        try putU32(a, &buf, 1);
        try encSym(a, &buf, "s", @intCast(f.value), invalid_local, 0, 0, "", "", &.{}, &.{});
        const r = try materialize(arena, buf.items);
        try testing.expectEqual(@as(model.SymbolKind, @enumFromInt(f.value)), r.symbols[0].kind);
    }
}

test "materialize decodes every RefKind value" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const a = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putHealth(a, &buf, .{});
    try putStr(a, &buf, "t");
    try putU32(a, &buf, 1);
    var refs: [@typeInfo(model.RefKind).@"enum".fields.len]TestRef = undefined;
    inline for (@typeInfo(model.RefKind).@"enum".fields, 0..) |f, i| {
        refs[i] = .{ .name = "r", .qualifier = "", .line = 1, .kind = @intCast(f.value), .count = 1, .lines = &[_]u32{} };
    }
    try encSym(a, &buf, "s", @intFromEnum(model.SymbolKind.function), invalid_local, 0, 0, "", "", &refs, &.{});
    const r = try materialize(arena, buf.items);
    inline for (@typeInfo(model.RefKind).@"enum".fields, 0..) |f, i| {
        try testing.expectEqual(@as(model.RefKind, @enumFromInt(f.value)), r.symbols[0].refs[i].kind);
    }
}

test "materialize rejects an out-of-range symbol kind" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putHealth(a, &buf, .{});
    try putStr(a, &buf, "t");
    try putU32(a, &buf, 1);
    try encSym(a, &buf, "s", 250, invalid_local, 0, 0, "", "", &.{}, &.{});
    try testing.expectError(error.BadEnum, materialize(arena, buf.items));
}

test "materialize rejects an out-of-range ref kind" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putHealth(a, &buf, .{});
    try putStr(a, &buf, "t");
    try putU32(a, &buf, 1);
    const refs = [_]TestRef{.{ .name = "r", .kind = 250, .line = 1 }};
    try encSym(a, &buf, "s", @intFromEnum(model.SymbolKind.function), invalid_local, 0, 0, "", "", &refs, &.{});
    try testing.expectError(error.BadEnum, materialize(arena, buf.items));
}

test "materialize rejects a truncated blob" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try putHealth(a, &buf, .{});
    try putStr(a, &buf, "text");
    try putU32(a, &buf, 1);
    try encSym(a, &buf, "s", @intFromEnum(model.SymbolKind.function), invalid_local, 0, 0, "", "", &.{}, &.{});
    // Chop it down before the parse-health header is complete.
    try testing.expectError(error.Truncated, materialize(arena, buf.items[0..3]));
}

test "materialize rejects inconsistent parse health" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try putU32(testing.allocator, &buf, 0);
    try putU32(testing.allocator, &buf, 3);
    try testing.expectError(error.BadParseHealth, materialize(arena, buf.items));

    buf.clearRetainingCapacity();
    try putU32(testing.allocator, &buf, 7);
    try putU32(testing.allocator, &buf, 6);
    try testing.expectError(error.BadParseHealth, materialize(arena, buf.items));
}

test "write emits the versioned magic and build key header" {
    const testing = std.testing;
    const empty_files = [_]model.SourceFile{};
    const empty_stats = [_]FileStat{};
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(testing.allocator, testing.io, tmp.dir, &empty_files, &empty_stats, &.{});

    const raw = try tmp.dir.readFileAlloc(testing.io, cache_path, testing.allocator, .unlimited);
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.startsWith(u8, raw, magic));
    const bk = std.mem.readInt(u64, raw[magic.len..][0..8], .little);
    try testing.expectEqual(build_key, bk);
    const count = std.mem.readInt(u32, raw[magic.len + 8 ..][0..4], .little);
    try testing.expectEqual(@as(u32, 0), count);
}

test "load reads a hand-built cache and restores an empty-symbol file" {
    const testing = std.testing;
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var buf = try buildOneEntryCache(testing.allocator, "f.zig", @intFromEnum(Language.zig), 11, 22, "hello");
    defer buf.deinit(testing.allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeRawCache(&tmp, buf.items);

    var store = load(testing.allocator, testing.io, tmp.dir).?;
    defer store.deinit();
    try testing.expectEqual(@as(u32, 1), store.entries.count());
    try testing.expectEqual(Language.zig, store.entries.get("f.zig").?.lang);

    const hit = store.restore(arena, "f.zig", .{ .mtime_ns = 11, .ctime_ns = 22, .size = 5 }).?;
    try testing.expectEqualStrings("hello", hit.text);
    try testing.expectEqual(@as(usize, 0), hit.symbols.len);
    // Size mismatch misses.
    try testing.expect(store.restore(arena, "f.zig", .{ .mtime_ns = 11, .ctime_ns = 22, .size = 4 }) == null);
}

test "every language tag survives the cache header" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    inline for (@typeInfo(Language).@"enum".fields) |f| {
        var buf = try buildOneEntryCache(testing.allocator, "f.zig", @intCast(f.value), 1, 2, "x");
        defer buf.deinit(testing.allocator);
        try writeRawCache(&tmp, buf.items);
        var store = load(testing.allocator, testing.io, tmp.dir).?;
        defer store.deinit();
        try testing.expectEqual(@as(Language, @enumFromInt(f.value)), store.entries.get("f.zig").?.lang);
    }
}

test "load rejects a cache header with an out-of-range language" {
    const testing = std.testing;
    var buf = try buildOneEntryCache(testing.allocator, "f.zig", 250, 1, 2, "x");
    defer buf.deinit(testing.allocator);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeRawCache(&tmp, buf.items);
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
}

test "load rejects a corrupt magic" {
    const testing = std.testing;
    var buf = try buildOneEntryCache(testing.allocator, "f.zig", @intFromEnum(Language.zig), 1, 2, "x");
    defer buf.deinit(testing.allocator);
    buf.items[0] +%= 1;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeRawCache(&tmp, buf.items);
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
}

test "load rejects a cache whose entry count exceeds its data" {
    const testing = std.testing;
    var buf = try buildOneEntryCache(testing.allocator, "f.zig", @intFromEnum(Language.zig), 1, 2, "x");
    defer buf.deinit(testing.allocator);
    // Header claims five entries but only one is encoded -> Truncated -> null.
    std.mem.writeInt(u32, buf.items[magic.len + 8 ..][0..4], 5, .little);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeRawCache(&tmp, buf.items);
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
}

test "load rejects empty and sub-magic cache files" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeRawCache(&tmp, "");
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
    try writeRawCache(&tmp, "NG");
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
}

test "load ignores cache data with trailing junk or truncation" {
    const testing = std.testing;
    var no_refs = [_]Reference{};
    const binds = [_]Binding{.{ .name = "v", .type_name = "X" }};
    var syms = [_]model.Symbol{
        .{ .id = 0, .file = 0, .name = "s", .kind = .function, .line = 1, .span_start = 0, .span_end = 1, .sig_end = 1, .doc = "", .parent = model.invalid_symbol, .exported = false, .refs = &no_refs, .bindings = &binds },
    };
    const files = [_]model.SourceFile{
        .{ .id = 0, .path = "s.zig", .language = .zig, .text = "x", .sym_start = 0, .sym_end = 1 },
    };
    const stats = [_]FileStat{.{ .mtime_ns = 1, .ctime_ns = 1, .size = 1 }};

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try write(testing.allocator, testing.io, tmp.dir, &files, &stats, &syms);

    const raw = try tmp.dir.readFileAlloc(testing.io, cache_path, testing.allocator, .unlimited);
    defer testing.allocator.free(raw);
    try testing.expect(raw.len > 1);
    // A valid cache loads; trailing or missing bytes bust the whole thing.
    {
        var ok = load(testing.allocator, testing.io, tmp.dir).?;
        ok.deinit();
    }
    const with_junk = try testing.allocator.alloc(u8, raw.len + 1);
    defer testing.allocator.free(with_junk);
    @memcpy(with_junk[0..raw.len], raw);
    with_junk[raw.len] = 0xff;
    try writeRawCache(&tmp, with_junk);
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
    try writeRawCache(&tmp, raw[0 .. raw.len - 1]);
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
}

test "load returns null when no cache file exists" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
}
