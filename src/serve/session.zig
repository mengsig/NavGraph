//! The resident code graph: the index, the open-document overlays, and the
//! incremental re-index that keeps them in step.
//!
//! Concurrency model: there is none. The server runs on one thread; a re-index
//! is an ordinary call made between two requests, so the index is never read
//! while it is being replaced. Debouncing and the mtime watcher are deadlines
//! the run loop waits on, not background work — see `docs/lsp.md`.
//!
//! Ownership: the initial walk's arena (`sources`) owns every file's text and
//! parse output until that file is re-parsed, after which its `Slot` owns a
//! private arena holding the newer copy. Retired arenas are still referenced by
//! the live index, so they are freed only after the replacement index is in
//! place — `retired` holds them until then.

const std = @import("std");
const index_mod = @import("../index.zig");
const language = @import("../language.zig");
const model = @import("../model.zig");
const query = @import("../query.zig");
const cache = @import("../cache.zig");
const overlay = @import("overlay.zig");

const Arena = std.heap.ArenaAllocator;

/// Client-supplied `initializationOptions`, with the contract's defaults.
pub const Config = struct {
    tests: query.TestScope = .with,
    strict: bool = false,
    debounce_ms: u32 = 120,
    watch: bool = true,
    watch_interval_ms: u32 = 2000,
    depth: u32 = 3,

    pub const max_depth: u32 = 10;
};

/// Why an index was (re)built. Reported verbatim in `navgraph/indexed`.
pub const Reason = enum {
    initial,
    change,
    save,
    rescan,
    watch,

    pub fn tag(self: Reason) []const u8 {
        return @tagName(self);
    }
};

/// What one (re)index produced. `changed` is owned by the session and stays
/// valid until the next re-index.
pub const Report = struct {
    reason: Reason,
    files: u32,
    symbols: u32,
    edges: u32,
    ms: u32,
    changed: []const []const u8,
};

/// One indexed file. `arena` is non-null once the file has been re-parsed since
/// startup, in which case it owns `file`'s text and parse output.
const Slot = struct {
    arena: ?*Arena,
    file: index_mod.ParsedFile,
    /// Whether an overlay supplied the current text (the watcher ignores such
    /// files: the editor's copy is authoritative while a document is open).
    overlaid: bool,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Root as given on the command line / in `initialize` (what the CLI prints).
    root_path: []const u8,
    /// Absolute, symlink-resolved root; the base for `file://` URIs.
    root_abs: [:0]u8,
    root_dir: std.Io.Dir,
    cfg: Config,

    overlays: overlay.Store,
    sources: index_mod.Sources,
    slots: std.ArrayList(Slot),
    /// Interned path strings, stable for the session's lifetime. Every path key
    /// in `by_path`, `dirty` and `Slot.file.path` is one of these, so re-parsing
    /// a file never invalidates a key.
    paths: Arena,
    interned: std.StringHashMapUnmanaged(void),
    by_path: std.StringHashMapUnmanaged(usize),
    idx: index_mod.Index,

    /// Paths awaiting re-index, and the arenas the live index still points into.
    dirty: std.StringArrayHashMapUnmanaged(void),
    retired: std.ArrayList(*Arena),
    /// Scratch for the last report's `changed` list.
    changed: std.ArrayList([]const u8),

    /// Deadline (ms on the awake clock) at which pending edits must be indexed,
    /// or null when nothing is pending.
    debounce_deadline_ms: ?i64,
    /// Deadline for the next mtime scan, or null when watching is off.
    watch_deadline_ms: ?i64,

    edges: u32,
    last_index_ms: u32,
    indexed_at_unix_ms: i64,
    used_cache: bool,

    /// Open the root, walk it, and assemble the first index.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        root_path: []const u8,
        cfg: Config,
    ) !Session {
        const start_ms: i64 = @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
        var root_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
        errdefer root_dir.close(io);
        const root_abs = try root_dir.realPathFileAlloc(io, ".", gpa);
        errdefer gpa.free(root_abs);

        var sources = try index_mod.collect(gpa, io, root_dir, null, null, true);
        errdefer sources.deinit();

        // No document can be open yet, so the first walk is always safe to cache.
        var idx = try index_mod.assemble(gpa, .{
            .root_label = root_path,
            .files = sources.files,
            .skipped_dirs = sources.skipped_dirs,
            .cache = sources.cache,
            .cache_write = if (sources.cache_stale) .{ .io = io, .dir = root_dir } else null,
        });
        errdefer idx.deinit();
        sources.cache_stale = idx.cache_snapshot.rewrite != .written;

        var self = Session{
            .gpa = gpa,
            .io = io,
            .root_path = root_path,
            .root_abs = root_abs,
            .root_dir = root_dir,
            .cfg = cfg,
            .overlays = overlay.Store.init(gpa),
            .sources = sources,
            .slots = .empty,
            .paths = Arena.init(gpa),
            .interned = .empty,
            .by_path = .empty,
            .idx = idx,
            .dirty = .empty,
            .retired = .empty,
            .changed = .empty,
            .debounce_deadline_ms = null,
            .watch_deadline_ms = null,
            .edges = 0,
            .last_index_ms = 0,
            .indexed_at_unix_ms = 0,
            .used_cache = sources.cache.hits != 0,
        };
        errdefer self.deinitOwned();
        try self.adoptSources();
        _ = self.finishIndex(.initial, start_ms);
        self.armWatch();
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.idx.deinit();
        self.deinitOwned();
    }

    /// Everything the session owns apart from the index, so `init` can unwind
    /// without a half-built session escaping.
    fn deinitOwned(self: *Session) void {
        for (self.slots.items) |s| destroyArena(self.gpa, s.arena);
        for (self.retired.items) |a| destroyArena(self.gpa, a);
        self.retired.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        self.interned.deinit(self.gpa);
        self.paths.deinit();
        self.by_path.deinit(self.gpa);
        self.dirty.deinit(self.gpa);
        self.changed.deinit(self.gpa);
        self.overlays.deinit();
        self.sources.deinit();
        self.gpa.free(self.root_abs);
        self.root_dir.close(self.io);
    }

    // -----------------------------------------------------------------------
    // Documents
    // -----------------------------------------------------------------------

    /// Record an editor's copy of `path` and schedule a re-index of it.
    pub fn openDocument(self: *Session, path: []const u8, text: []const u8) !void {
        try self.overlays.put(path, text);
        try self.markDirty(path);
    }

    /// Drop the editor's copy of `path`; the disk copy becomes authoritative.
    pub fn closeDocument(self: *Session, path: []const u8) !void {
        if (!self.overlays.remove(path)) return;
        try self.markDirty(path);
    }

    /// Queue `path` for the next re-index and start the debounce window.
    pub fn markDirty(self: *Session, path: []const u8) !void {
        try self.dirty.put(self.gpa, try self.intern(path), {});
        self.debounce_deadline_ms = self.nowMs() + @as(i64, self.cfg.debounce_ms);
    }

    /// Whether edits are waiting to be indexed.
    pub fn pending(self: *const Session) bool {
        return self.dirty.count() != 0;
    }

    // -----------------------------------------------------------------------
    // Indexing
    // -----------------------------------------------------------------------

    /// Re-parse every dirty file and rebuild the graph. Returns null when
    /// nothing was pending.
    pub fn reindex(self: *Session, reason: Reason) !?Report {
        if (self.dirty.count() == 0) return null;
        const start = self.nowMs();

        self.changed.clearRetainingCapacity();
        for (self.dirty.keys()) |path| {
            try self.changed.append(self.gpa, path);
            try self.reparse(path);
        }
        // An edit-driven re-index never refreshes the on-disk cache: what it
        // assembles reflects editor buffers, not what a CLI run would parse.
        try self.swapIndex(null);
        self.dirty.clearRetainingCapacity();
        self.debounce_deadline_ms = null;
        return self.finishIndex(reason, start);
    }

    /// Re-walk the tree from disk: picks up created and deleted files as well as
    /// changes made outside the editor. `full` ignores the on-disk parse cache.
    pub fn rescan(self: *Session, full: bool) !Report {
        const start = self.nowMs();
        var sources = try index_mod.collect(self.gpa, self.io, self.root_dir, null, null, !full);
        errdefer sources.deinit();

        // Replace the whole file set, then re-apply every open document on top so
        // unsaved edits survive a rescan.
        for (self.slots.items) |s| try self.retired.append(self.gpa, s.arena orelse continue);
        self.slots.clearRetainingCapacity();
        var old_sources = self.sources;
        self.sources = sources;
        self.used_cache = sources.cache.hits != 0;
        try self.adoptSources();

        self.changed.clearRetainingCapacity();
        for (self.overlays.docs.keys()) |path| {
            try self.changed.append(self.gpa, path);
            try self.reparse(path);
        }
        try self.swapIndex(self.cacheWrite());
        old_sources.deinit();
        self.dirty.clearRetainingCapacity();
        self.debounce_deadline_ms = null;
        return self.finishIndex(.rescan, start);
    }

    /// Re-stat every non-overlaid file; queue the ones that changed on disk.
    /// Returns the number of files queued.
    pub fn scanForChanges(self: *Session) !u32 {
        var found: u32 = 0;
        for (self.slots.items) |slot| {
            if (slot.overlaid) continue;
            const path = slot.file.path;
            const st = self.statOf(path);
            const same = if (st) |s|
                s.mtime_ns == slot.file.stat.mtime_ns and s.ctime_ns == slot.file.stat.ctime_ns and s.size == slot.file.stat.size
            else
                false;
            if (same) continue;
            try self.markDirty(path);
            found += 1;
        }
        return found;
    }

    // -----------------------------------------------------------------------
    // Deadlines
    // -----------------------------------------------------------------------

    pub fn nowMs(self: *const Session) i64 {
        return @intCast(@divFloor(std.Io.Clock.awake.now(self.io).nanoseconds, std.time.ns_per_ms));
    }

    pub fn armWatch(self: *Session) void {
        self.watch_deadline_ms = if (self.cfg.watch)
            self.nowMs() + @as(i64, self.cfg.watch_interval_ms)
        else
            null;
    }

    /// Milliseconds until the soonest pending deadline, or null when the server
    /// has nothing scheduled and may block indefinitely on input.
    pub fn nextDeadlineMs(self: *const Session) ?i64 {
        const now = self.nowMs();
        var best: ?i64 = null;
        for ([_]?i64{ self.debounce_deadline_ms, self.watch_deadline_ms }) |d| {
            const at = d orelse continue;
            const in = @max(at - now, 0);
            if (best == null or in < best.?) best = in;
        }
        return best;
    }

    // -----------------------------------------------------------------------
    // Lookups
    // -----------------------------------------------------------------------

    /// The current text of `path`: the overlay when one is open, else the copy
    /// the index holds. Null when the file is not indexed.
    pub fn textOf(self: *const Session, path: []const u8) ?[]const u8 {
        if (self.overlays.get(path)) |t| return t;
        const i = self.by_path.get(path) orelse return null;
        return self.slots.items[i].file.text;
    }

    /// Whether `path` is indexed.
    pub fn hasFile(self: *const Session, path: []const u8) bool {
        return self.by_path.contains(path);
    }

    pub fn fileCount(self: *const Session) u32 {
        return @intCast(self.idx.graph.files.len);
    }

    pub fn symbolCount(self: *const Session) u32 {
        return @intCast(self.idx.graph.symbols.len);
    }

    pub fn edgeCount(self: *const Session) u32 {
        return self.edges;
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    /// The session's canonical copy of `path`. Interned so a key in `dirty`,
    /// `by_path` or a `Slot` stays valid however the file is later re-parsed.
    fn intern(self: *Session, path: []const u8) ![]const u8 {
        if (self.interned.getKey(path)) |k| return k;
        const copy = try self.paths.allocator().dupe(u8, path);
        try self.interned.put(self.gpa, copy, {});
        return copy;
    }

    /// Seed the slot list and path table from the current `sources`.
    fn adoptSources(self: *Session) !void {
        try self.slots.ensureTotalCapacity(self.gpa, self.sources.files.len);
        for (self.sources.files) |f| {
            var file = f;
            file.path = try self.intern(f.path);
            self.slots.appendAssumeCapacity(.{ .arena = null, .file = file, .overlaid = false });
        }
        try self.reindexPathTable();
    }

    /// Rebuild `by_path` from `slots`. Keys are interned, so nothing is freed.
    fn reindexPathTable(self: *Session) !void {
        self.by_path.clearRetainingCapacity();
        for (self.slots.items, 0..) |slot, i| try self.by_path.put(self.gpa, slot.file.path, i);
    }

    /// Re-read and re-parse one file into a private arena. A file that has no
    /// overlay and cannot be read is dropped from the index.
    fn reparse(self: *Session, path: []const u8) !void {
        const lang = language.detect(path);
        if (lang == .unknown) return;
        const key = try self.intern(path);

        const arena_box = try self.gpa.create(Arena);
        arena_box.* = Arena.init(self.gpa);
        errdefer {
            arena_box.deinit();
            self.gpa.destroy(arena_box);
        }
        const arena = arena_box.allocator();

        const from_overlay = self.overlays.get(key);
        const text: []const u8 = if (from_overlay) |t|
            try arena.dupe(u8, t)
        else
            self.root_dir.readFileAlloc(self.io, key, arena, .limited(max_file_bytes)) catch {
                arena_box.deinit();
                self.gpa.destroy(arena_box);
                try self.dropFile(key);
                return;
            };
        if (text.len > std.math.maxInt(u32)) return error.FileTooBig;

        const parsed = try index_mod.parseOne(self.gpa, arena, text, lang);
        try self.installSlot(.{
            .arena = arena_box,
            .file = .{
                .path = key,
                .language = lang,
                .text = text,
                .symbols = parsed.symbols,
                .parse_health = parsed.health,
                .stat = self.statOf(key) orelse .{ .mtime_ns = 0, .ctime_ns = 0, .size = text.len },
            },
            .overlaid = from_overlay != null,
        });
    }

    /// Put `slot` in place of its path's entry (appending when the file is new),
    /// retiring the arena the live index still points into.
    fn installSlot(self: *Session, slot: Slot) !void {
        try self.slots.ensureUnusedCapacity(self.gpa, 1);
        const gop = try self.by_path.getOrPut(self.gpa, slot.file.path);
        if (gop.found_existing) {
            const i = gop.value_ptr.*;
            if (self.slots.items[i].arena) |a| try self.retired.append(self.gpa, a);
            self.slots.items[i] = slot;
            return;
        }
        gop.value_ptr.* = self.slots.items.len;
        self.slots.appendAssumeCapacity(slot);
    }

    /// Remove a vanished file from the index.
    fn dropFile(self: *Session, path: []const u8) !void {
        const i = self.by_path.get(path) orelse return;
        // Still referenced by the live index; freed after the swap.
        if (self.slots.items[i].arena) |a| try self.retired.append(self.gpa, a);
        _ = self.slots.orderedRemove(i);
        try self.reindexPathTable();
    }

    /// Assemble a new index over the current slots and retire the old one.
    /// `cache_write` refreshes `.navgraph/cache` from the new graph; `cacheWrite`
    /// decides when that is allowed.
    fn swapIndex(self: *Session, cache_write: ?index_mod.CacheWrite) !void {
        const files = try self.gpa.alloc(index_mod.ParsedFile, self.slots.items.len);
        defer self.gpa.free(files);
        for (self.slots.items, files) |slot, *f| f.* = slot.file;

        var next = try index_mod.assemble(self.gpa, .{
            .root_label = self.root_path,
            .files = files,
            .skipped_dirs = self.sources.skipped_dirs,
            .cache = self.sources.cache,
            .cache_write = cache_write,
        });
        errdefer next.deinit();
        try self.reindexPathTable();

        self.idx.deinit();
        self.idx = next;
        if (cache_write != null) self.sources.cache_stale = next.cache_snapshot.rewrite != .written;
        for (self.retired.items) |a| destroyArena(self.gpa, a);
        self.retired.clearRetainingCapacity();
    }

    /// The cache refresh to fold into the next assembly, or null. The cache is
    /// never written while a document is open: the index then carries unsaved
    /// editor text, which must not become what the next CLI run reads back.
    fn cacheWrite(self: *const Session) ?index_mod.CacheWrite {
        if (!self.sources.cache_stale or self.overlays.count() != 0) return null;
        return .{ .io = self.io, .dir = self.root_dir };
    }

    fn finishIndex(self: *Session, reason: Reason, start_ms: i64) Report {
        self.edges = countEdges(&self.idx);
        self.last_index_ms = @intCast(@max(self.nowMs() - start_ms, 0));
        self.indexed_at_unix_ms = @intCast(@divFloor(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_ms));
        return .{
            .reason = reason,
            .files = self.fileCount(),
            .symbols = self.symbolCount(),
            .edges = self.edges,
            .ms = self.last_index_ms,
            .changed = self.changed.items,
        };
    }

    /// Write back the on-disk parse cache when the walk found it out of date, so
    /// the next server or CLI start is a cache-restore rather than a full parse.
    ///
    /// Skipped while any document is open: the live index then holds unsaved
    /// buffer text, which must never be written to a cache keyed by disk mtime.
    /// The existing cache stays valid for the files that were not edited.
    fn statOf(self: *const Session, path: []const u8) ?cache.FileStat {
        const st = self.root_dir.statFile(self.io, path, .{}) catch return null;
        return .{ .mtime_ns = st.mtime.nanoseconds, .ctime_ns = st.ctime.nanoseconds, .size = st.size };
    }
};

/// Mirrors the indexer's own per-file read cap.
const max_file_bytes: usize = 8 * 1024 * 1024;

fn destroyArena(gpa: std.mem.Allocator, arena: ?*Arena) void {
    const a = arena orelse return;
    a.deinit();
    gpa.destroy(a);
}

/// Resolved outgoing edges in the graph — the `edges` figure in `navgraph/status`.
fn countEdges(idx: *const index_mod.Index) u32 {
    var n: u32 = 0;
    for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            if (ref.target != model.invalid_symbol) n += 1;
        }
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A temp project with a call chain across two files, plus a live Session on it.
pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    session: Session,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, files: []const [2][]const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
        const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer gpa.free(root);
        const session = try Session.init(gpa, io, root, .{ .watch = false });
        return .{ .tmp = tmp, .root = root, .session = session };
    }

    pub fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.session.deinit();
        gpa.free(self.root);
        self.tmp.cleanup();
    }
};

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

test "session builds an index over the project at startup" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), fx.session.fileCount());
    try testing.expect(fx.session.idx.lookup("helper").len == 1);
    try testing.expect(fx.session.edgeCount() > 0);
    try testing.expect(!fx.session.pending());
}

test "an overlay replaces the disk copy and adds an edge to the graph" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const s = &fx.session;

    try testing.expectEqual(@as(usize, 1), s.idx.callersOf(s.idx.lookup("helper")[0]).len);
    try s.openDocument("app.zig",
        \\const util = @import("util.zig");
        \\
        \\pub fn run() void {
        \\    mid();
        \\    util.helper();
        \\}
        \\
        \\fn mid() void {
        \\    util.helper();
        \\}
        \\
    );
    try testing.expect(s.pending());
    const report = (try s.reindex(.change)).?;
    try testing.expectEqual(Reason.change, report.reason);
    try testing.expectEqual(@as(usize, 1), report.changed.len);
    try testing.expectEqualStrings("app.zig", report.changed[0]);
    // `run` now calls helper too, so helper has two callers.
    try testing.expectEqual(@as(usize, 2), s.idx.callersOf(s.idx.lookup("helper")[0]).len);
    try testing.expect(!s.pending());
}

test "closing a document reverts the graph to the copy on disk" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const s = &fx.session;

    try s.openDocument("util.zig", "pub fn helper() void {}\npub fn extra() void {}\n");
    _ = try s.reindex(.change);
    try testing.expect(s.idx.lookup("extra").len == 1);
    try testing.expectEqualStrings("pub fn helper() void {}\npub fn extra() void {}\n", s.textOf("util.zig").?);

    try s.closeDocument("util.zig");
    _ = try s.reindex(.change);
    try testing.expect(s.idx.lookup("extra").len == 0);
    try testing.expectEqual(@as(usize, 0), s.overlays.count());
}

test "an overlay for a file not on disk is indexed as a new file" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const s = &fx.session;

    try s.openDocument("fresh.zig", "pub fn brandNew() void {}\n");
    _ = try s.reindex(.change);
    try testing.expectEqual(@as(u32, 3), s.fileCount());
    try testing.expect(s.idx.lookup("brandNew").len == 1);

    // Closing it removes the file again: there is no copy on disk.
    try s.closeDocument("fresh.zig");
    _ = try s.reindex(.change);
    try testing.expectEqual(@as(u32, 2), s.fileCount());
    try testing.expect(s.idx.lookup("brandNew").len == 0);
}

test "repeated re-indexes stay correct and do not accumulate stale edges" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const s = &fx.session;
    const before = s.edgeCount();
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try s.openDocument("app.zig", sample[0][1]);
        _ = try s.reindex(.change);
        try testing.expectEqual(before, s.edgeCount());
        try testing.expectEqual(@as(u32, 2), s.fileCount());
    }
}

test "rescan picks up a file created on disk and keeps unsaved overlays" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const s = &fx.session;

    try s.openDocument("util.zig", "pub fn helper() void {}\npub fn unsaved() void {}\n");
    _ = try s.reindex(.change);

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "added.zig", .data = "pub fn added() void {}\n" });
    const report = try s.rescan(false);
    try testing.expectEqual(@as(u32, 3), report.files);
    try testing.expect(s.idx.lookup("added").len == 1);
    // The unsaved edit survived the rescan.
    try testing.expect(s.idx.lookup("unsaved").len == 1);
}

test "scanForChanges queues a file edited on disk but ignores an open one" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const s = &fx.session;

    try testing.expectEqual(@as(u32, 0), try s.scanForChanges());
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "util.zig", .data = "pub fn helper() void {}\npub fn onDisk() void {}\n" });
    try testing.expectEqual(@as(u32, 1), try s.scanForChanges());
    _ = try s.reindex(.watch);
    try testing.expect(s.idx.lookup("onDisk").len == 1);

    // With the document open, the editor's copy wins and the watcher stays quiet.
    try s.openDocument("util.zig", "pub fn helper() void {}\n");
    _ = try s.reindex(.change);
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "util.zig", .data = "pub fn helper() void {}\npub fn ignored() void {}\n" });
    try testing.expectEqual(@as(u32, 0), try s.scanForChanges());
}

test "a deleted file drops out of the index on re-index" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const s = &fx.session;
    try fx.tmp.dir.deleteFile(testing.io, "util.zig");
    try s.markDirty("util.zig");
    _ = try s.reindex(.watch);
    try testing.expectEqual(@as(u32, 1), s.fileCount());
    try testing.expect(s.idx.lookup("helper").len == 0);
}

test "reindex reports nothing when no edit is pending" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    try testing.expect((try fx.session.reindex(.change)) == null);
}

test "nextDeadlineMs reflects the debounce window and the watcher interval" {
    var fx = try Fixture.init(testing.allocator, testing.io, &sample);
    defer fx.deinit(testing.allocator);
    const s = &fx.session;
    try testing.expect(s.nextDeadlineMs() == null); // watch off, nothing dirty
    try s.markDirty("app.zig");
    const in = s.nextDeadlineMs().?;
    try testing.expect(in >= 0 and in <= s.cfg.debounce_ms);
    s.cfg.watch = true;
    s.cfg.watch_interval_ms = 10;
    s.armWatch();
    try testing.expect(s.nextDeadlineMs().? <= 10);
}
