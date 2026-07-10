//! Builds the whole-project code graph: walks the tree, parses each source
//! file, assigns global symbol ids, then resolves references into edges and a
//! reverse (callers) index.
//!
//! Everything the graph points at is owned by `Index.arena`, which lives for the
//! process. `Index` is heap-stable: the arena is boxed so the struct can be
//! returned and moved without invalidating allocator pointers.

const std = @import("std");
const model = @import("model.zig");
const language = @import("language.zig");
const parser = @import("parser.zig");
const api = @import("api.zig");
const cache = @import("cache.zig");
const imports = @import("imports.zig");
const gitignore = @import("gitignore.zig");

const SymbolId = model.SymbolId;
const FileId = model.FileId;
const invalid = model.invalid_symbol;
const max_file_bytes: usize = 8 * 1024 * 1024;
const max_gitignore_bytes: usize = 1024 * 1024;

/// An import binding within a file: `binding` (e.g. `api`) resolves to file
/// `target`. `binding` is "" for imports that only contribute a module edge
/// (named/`from` imports), which still populate the import dependency graph.
pub const FileImport = struct { binding: []const u8, target: FileId };

pub const CacheRewrite = enum { disabled, current, written, failed };

pub const CacheSnapshot = struct {
    enabled: bool = false,
    loaded: bool = false,
    loaded_entries: u32 = 0,
    hits: u32 = 0,
    rewrite: CacheRewrite = .disabled,
};

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    graph: model.Graph,
    by_name: std.StringHashMapUnmanaged([]SymbolId),
    callers: [][]SymbolId,
    /// Per-file resolved imports (arena-owned), indexed by `FileId`.
    file_imports: [][]const FileImport,
    root: []const u8,
    /// Filesystem stats captured while this in-memory snapshot was built.
    file_stats: []const cache.FileStat = &.{},
    cache_snapshot: CacheSnapshot = .{},
    /// Unique names of directories the walker pruned (build/vendor/fixture dirs
    /// from `ignored_dirs`). Surfaced on empty results so a skipped subtree reads
    /// as "not indexed" rather than "absent". Arena-owned.
    skipped_dirs: []const []const u8 = &.{},
    /// Go package name → files declaring it (`package caddy` in caddy.go,
    /// logging.go, …). Lets a package-qualified call (`caddy.Load(...)`) resolve
    /// to the package's top-level definitions. Arena-owned.
    go_packages: std.StringHashMapUnmanaged([]const FileId) = .empty,

    pub fn deinit(self: *Index) void {
        self.by_name.deinit(self.gpa);
        self.gpa.free(self.callers);
        self.gpa.free(self.graph.files);
        self.gpa.free(self.graph.symbols);
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    /// Definitions matching `name` exactly (empty when none).
    pub fn lookup(self: *const Index, name: []const u8) []const SymbolId {
        return self.by_name.get(name) orelse &.{};
    }

    /// Symbols that reference symbol `id` (incoming edges).
    pub fn callersOf(self: *const Index, id: SymbolId) []const SymbolId {
        std.debug.assert(id < self.callers.len);
        return self.callers[id];
    }

    /// Imports declared by file `id` (outgoing module edges).
    pub fn importsOf(self: *const Index, id: FileId) []const FileImport {
        std.debug.assert(id < self.file_imports.len);
        return self.file_imports[id];
    }
};

const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    files: std.ArrayList(model.SourceFile),
    symbols: std.ArrayList(model.Symbol),
    /// Per-file (mtime, size) aligned 1:1 with `files`, used to write the cache.
    stats: std.ArrayList(cache.FileStat),
    /// Loaded on-disk cache of previously parsed files (null when disabled).
    store: ?cache.Store,
    /// Count of files served from `store` (vs. freshly parsed) this build.
    cache_hits: u32,
    /// Unique names of directories pruned during the walk (arena-owned strings).
    skipped: std.ArrayList([]const u8),
    /// Accumulated `.gitignore` rules, matched to skip git-ignored files/dirs.
    ignore: gitignore.Matcher,
};

/// Build an index rooted at `root_path` (relative to cwd or absolute). When
/// `use_cache` is set, unchanged files are restored from `.navgraph/cache` and
/// the refreshed cache is written back.
pub fn build(gpa: std.mem.Allocator, io: std.Io, root_path: []const u8, use_cache: bool) !Index {
    std.debug.assert(root_path.len > 0);
    const arena_box = try gpa.create(std.heap.ArenaAllocator);
    arena_box.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena_box.deinit();
        gpa.destroy(arena_box);
    }
    const arena = arena_box.allocator();

    // `-C <path>` normally names a directory. If it names a single file, index
    // just that file (rooted at its parent dir) instead of erroring with NotDir —
    // so `outline -C src/parser.zig` scopes to one file.
    var single_file: ?[]const u8 = null;
    var root_dir = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| dir: {
        if (err != error.NotDir) return err;
        single_file = std.fs.path.basename(root_path);
        const dir_part = std.fs.path.dirname(root_path) orelse ".";
        break :dir try std.Io.Dir.cwd().openDir(io, dir_part, .{ .iterate = true });
    };
    defer root_dir.close(io);

    var b = Builder{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .root_dir = root_dir,
        .files = .empty,
        .symbols = .empty,
        .stats = .empty,
        .store = if (use_cache) cache.load(gpa, io, root_dir) else null,
        .cache_hits = 0,
        .skipped = .empty,
        .ignore = gitignore.Matcher.init(gpa),
    };
    defer b.files.deinit(gpa);
    defer b.symbols.deinit(gpa);
    defer b.stats.deinit(gpa);
    defer b.skipped.deinit(gpa);
    defer b.ignore.deinit();
    defer if (b.store) |*s| s.deinit();

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    if (single_file) |f| {
        // An explicitly-named file is indexed directly (no .gitignore pruning).
        try maybeAddFile(&b, f);
    } else {
        try collectDir(&b, root_dir, &path_buf);
    }

    std.debug.assert(b.stats.items.len == b.files.items.len);
    std.debug.assert(b.cache_hits <= b.files.items.len);
    const loaded_entries: u32 = if (b.store) |*store| @intCast(store.entries.count()) else 0;
    const rewrite_cache = use_cache and cacheStale(&b);
    const graph = model.Graph{
        .files = try gpa.dupe(model.SourceFile, b.files.items),
        .symbols = try gpa.dupe(model.Symbol, b.symbols.items),
    };
    var idx = Index{
        .gpa = gpa,
        .arena = arena_box,
        .graph = graph,
        .by_name = .empty,
        .callers = &.{},
        .file_imports = &.{},
        .root = try arena.dupe(u8, root_path),
        .file_stats = try arena.dupe(cache.FileStat, b.stats.items),
        .cache_snapshot = .{
            .enabled = use_cache,
            .loaded = b.store != null,
            .loaded_entries = loaded_entries,
            .hits = b.cache_hits,
            .rewrite = if (use_cache) .current else .disabled,
        },
        .skipped_dirs = try arena.dupe([]const u8, b.skipped.items),
    };
    try buildNameIndex(&idx);
    try buildImportTable(&idx);
    try buildGoPackageTable(&idx);
    resolveReferences(&idx);
    // Persist BEFORE applying router mounts: the mount pass rewrites route
    // symbol names in place (prepending the mount prefix), and those rewritten
    // names must not reach the per-file cache — the mount lives in a different
    // file, so caching the prefixed name would double-prefix on the next build.
    if (rewrite_cache) idx.cache_snapshot.rewrite = if (persistCache(&b, &idx)) .written else .failed;
    if (applyRouterMounts(&idx)) try rebuildNameIndex(&idx);
    linkRoutes(&idx);
    try buildCallers(&idx);
    return idx;
}

/// Whether the on-disk cache differs from what we just built. When every file
/// was a cache hit and no file was added or removed (hit count == file count ==
/// stored entry count) the cache is already current, so we skip rewriting it —
/// avoiding a full-repo-sized write on every no-op query.
fn cacheStale(b: *const Builder) bool {
    const store = b.store orelse return true; // no prior cache: must write
    const files = b.files.items.len;
    return b.cache_hits != files or store.entries.count() != files;
}

/// Best-effort cache write. A failure here (e.g. a read-only tree) must never
/// fail the query, so it is reported on stderr and swallowed — the cache is a
/// pure optimization, not required for correctness.
fn persistCache(b: *const Builder, idx: *const Index) bool {
    std.debug.assert(idx.graph.files.len == b.stats.items.len);
    std.debug.assert(idx.cache_snapshot.enabled);
    cache.write(b.gpa, b.io, b.root_dir, idx.graph.files, b.stats.items, idx.graph.symbols) catch |err| {
        std.debug.print("navgraph: cache write skipped: {s}\n", .{@errorName(err)});
        return false;
    };
    return true;
}

const ignored_dirs = std.StaticStringMap(void).initComptime(.{
    .{".git"},        .{"node_modules"},  .{"zig-out"}, .{".zig-cache"},
    .{"zig-cache"},   .{"__pycache__"},   .{".venv"},   .{"venv"},
    .{"dist"},        .{"build"},         .{".next"},   .{"target"},
    .{".mypy_cache"}, .{".pytest_cache"}, .{"vendor"},  .{".advantage"},
    .{".nvime"},      .{".idea"},         .{".vscode"}, .{"coverage"},
    .{".navgraph"},   .{"site-packages"}, .{".tox"},    .{".ruff_cache"},
    .{".codeflow"},
});

fn collectDir(b: *Builder, dir: std.Io.Dir, path_buf: *std.ArrayList(u8)) anyerror!void {
    try loadGitignore(b, dir, path_buf.items);
    var it = dir.iterate();
    const base_len = path_buf.items.len;
    while (try it.next(b.io)) |entry| {
        if (entry.name.len == 0) continue;
        path_buf.shrinkRetainingCapacity(base_len);
        if (base_len != 0) try path_buf.append(b.gpa, '/');
        try path_buf.appendSlice(b.gpa, entry.name);
        switch (entry.kind) {
            .directory => try enterDir(b, dir, entry.name, path_buf),
            .file => try maybeAddFile(b, path_buf.items),
            else => {},
        }
    }
    path_buf.shrinkRetainingCapacity(base_len);
}

/// Load `dir`'s `.gitignore` and `.navgraphignore` (if any) into the matcher,
/// tagged with `base` (the directory's path relative to the root). Rule text and
/// base are duped into the arena so they outlive this call. Absent/unreadable
/// files are simply skipped. `.navgraphignore` uses the same syntax and is added
/// after `.gitignore`, so (last-match-wins) it can both add ignores git doesn't
/// have and re-include (`!pattern`) something `.gitignore` — or the built-in
/// skip set — prunes.
fn loadGitignore(b: *Builder, dir: std.Io.Dir, base: []const u8) !void {
    inline for (.{ ".gitignore", ".navgraphignore" }) |ignore_file| {
        if (dir.readFileAlloc(b.io, ignore_file, b.arena, .limited(max_gitignore_bytes))) |text| {
            try b.ignore.addFile(try b.arena.dupe(u8, base), text);
        } else |_| {}
    }
}

fn enterDir(b: *Builder, parent: std.Io.Dir, name: []const u8, path_buf: *std.ArrayList(u8)) !void {
    // An explicit `!pattern` re-include (from a `.navgraphignore`) overrides the
    // built-in skip set — the user's way to force-index e.g. `vendor/`.
    if (ignored_dirs.has(name) and !b.ignore.isReincluded(path_buf.items, true)) {
        // A build-output-conventional name (`coverage`, `build`, `dist`, `target`)
        // is a *real source directory* when it sits under a source tree
        // (`frontend/src/coverage/`) — a domain dir (satellite coverage, a build
        // step), not nyc/webpack output. Index it there; prune it only near the
        // root, where it's almost certainly an artifact. This stops a legit
        // `src/coverage/` from being silently eaten.
        if (!(soft_ignore.has(name) and underSourceRoot(path_buf.items))) {
            try noteSkipped(b, name);
            return;
        }
    }
    // A git-ignored directory is pruned silently: its skip is expected, not a
    // could-be-source surprise worth reporting.
    if (b.ignore.isIgnored(path_buf.items, true)) return;
    var sub = parent.openDir(b.io, name, .{ .iterate = true }) catch return;
    defer sub.close(b.io);
    try collectDir(b, sub, path_buf);
}

/// Build-output-conventional directory names that are *also* common source/domain
/// directory names. Pruned like the rest of `ignored_dirs` at the root, but kept
/// (indexed) when nested under a source tree — see `enterDir`/`underSourceRoot`.
const soft_ignore = std.StaticStringMap(void).initComptime(.{
    .{"coverage"}, .{"build"}, .{"dist"}, .{"target"},
});

/// Conventional source-container directory names. A `soft_ignore` dir with any of
/// these as an ancestor is treated as source, not build output.
const source_roots = std.StaticStringMap(void).initComptime(.{
    .{"src"},     .{"lib"},      .{"app"}, .{"source"},
    .{"sources"}, .{"packages"}, .{"pkg"},
});

/// True when `path` (a `/`-separated relative dir path) has a `source_roots`
/// component anywhere in it — i.e. the directory lives inside a source tree.
fn underSourceRoot(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (source_roots.has(comp)) return true;
    }
    return false;
}

/// Directories whose skip is universally expected (VCS, dependency, build, cache
/// and editor dirs) — never worth surfacing. Anything else in `ignored_dirs`
/// (e.g. `vendor`) can plausibly hold real source, so its skip is reported to
/// avoid the silent-failure trap.
const silent_skip = std.StaticStringMap(void).initComptime(.{
    .{".git"},          .{"node_modules"},  .{"zig-out"},     .{".zig-cache"},
    .{"zig-cache"},     .{"__pycache__"},   .{".venv"},       .{"venv"},
    .{"dist"},          .{"build"},         .{".next"},       .{"target"},
    .{".mypy_cache"},   .{".pytest_cache"}, .{".idea"},       .{".vscode"},
    .{"coverage"},      .{".navgraph"},     .{".advantage"},  .{".nvime"},
    .{"site-packages"}, .{".tox"},          .{".ruff_cache"}, .{".codeflow"},
});

/// Record a pruned, potentially-source directory's name once (deduped) for the
/// skipped-dirs note. Silent (build/VCS/cache) skips are not recorded.
fn noteSkipped(b: *Builder, name: []const u8) !void {
    if (silent_skip.has(name)) return;
    for (b.skipped.items) |s| if (std.mem.eql(u8, s, name)) return;
    try b.skipped.append(b.gpa, try b.arena.dupe(u8, name));
}

/// Record a skipped minified/bundled file for the skipped-note, annotated so it
/// reads as a file judgement rather than a pruned directory.
fn noteSkippedMinified(b: *Builder, path: []const u8) !void {
    const label = try std.fmt.allocPrint(b.arena, "{s} (minified)", .{path});
    for (b.skipped.items) |s| if (std.mem.eql(u8, s, label)) return;
    try b.skipped.append(b.gpa, label);
}

fn maybeAddFile(b: *Builder, rel_path: []const u8) !void {
    const lang = language.detect(rel_path);
    if (lang == .unknown) return;
    if (b.ignore.isIgnored(rel_path, false)) return;
    if (isMinifiedName(rel_path)) return noteSkippedMinified(b, rel_path);
    const stat = statOf(b, rel_path) orelse return;

    if (b.store) |*s| {
        if (s.restore(b.arena, rel_path, stat)) |hit| {
            std.debug.assert(hit.text.len == stat.size);
            try appendFile(b, rel_path, lang, hit.text, hit.symbols, hit.parse_health, stat);
            b.cache_hits += 1;
            return;
        }
    }
    const text = b.root_dir.readFileAlloc(b.io, rel_path, b.arena, .limited(max_file_bytes)) catch return;
    std.debug.assert(text.len <= std.math.maxInt(u32));
    // A minified/bundled artifact (one enormous line) indexes as thousands of
    // meaningless one-letter symbols that pollute `hot`/`unused`/`search` — a
    // real trial hit this with a vendored asciinema player under `testdata/`.
    // Skip it and record the basename for the skipped-note.
    if (isMinifiedText(text)) return noteSkippedMinified(b, rel_path);
    const parsed = try parseFile(b, text, lang);
    try appendFile(b, rel_path, lang, text, parsed.symbols, parsed.health, stat);
}

fn basenameOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    return if (slash) |i| path[i + 1 ..] else path;
}

/// Conventionally-minified basenames: `x.min.js`, `x.bundle.js`, `x.min.mjs`, …
fn isMinifiedName(path: []const u8) bool {
    const base = basenameOf(path);
    return std.mem.indexOf(u8, base, ".min.") != null or
        std.mem.indexOf(u8, base, ".bundle.") != null;
}

/// Content heuristic for minified/generated code: a big file whose average
/// line length is machine-scale (no human writes 4 KiB of 300+-char lines).
fn isMinifiedText(text: []const u8) bool {
    if (text.len < 4096) return false;
    const lines = 1 + std.mem.count(u8, text, "\n");
    return text.len / lines > 300;
}

/// (mtime, size) of `rel_path`, or null when the file cannot be stat'd (e.g. it
/// vanished between directory iteration and here).
fn statOf(b: *Builder, rel_path: []const u8) ?cache.FileStat {
    const st = b.root_dir.statFile(b.io, rel_path, .{}) catch return null;
    return .{ .mtime_ns = st.mtime.nanoseconds, .ctime_ns = st.ctime.nanoseconds, .size = st.size };
}

const ParsedFile = struct {
    symbols: []const parser.ParsedSymbol,
    health: model.ParseHealth,
};

fn parseFile(b: *Builder, text: []const u8, lang: language.Language) !ParsedFile {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert(lang != .unknown);
    var parsed: std.ArrayList(parser.ParsedSymbol) = .empty;
    defer parsed.deinit(b.gpa);
    const health = try parser.parse(b.gpa, b.arena, text, lang, &parsed);
    return .{ .symbols = try b.arena.dupe(parser.ParsedSymbol, parsed.items), .health = health };
}

fn warnParseHealth(rel_path: []const u8, health: model.ParseHealth) void {
    const from = health.desync_from orelse return;
    std.debug.assert(rel_path.len > 0);
    std.debug.assert(health.desync_to >= from);
    std.debug.print(
        "navgraph: parse-health: {s}: tokenizer lost sync (likely an unterminated string) — symbols on lines {d}-{d} may be missing\n",
        .{ rel_path, from, health.desync_to },
    );
}

/// Assign global ids to `parsed`, append its symbols and the owning `SourceFile`
/// (plus its cache stat). Shared by the fresh-parse and cache-restore paths.
fn appendFile(
    b: *Builder,
    rel_path: []const u8,
    lang: language.Language,
    text: []const u8,
    parsed: []const parser.ParsedSymbol,
    health: model.ParseHealth,
    stat: cache.FileStat,
) !void {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    std.debug.assert((health.desync_from == null) == (health.desync_to == 0));
    warnParseHealth(rel_path, health);
    const base: u32 = @intCast(b.symbols.items.len);
    const file_id: FileId = @intCast(b.files.items.len);
    for (parsed, 0..) |p, local| {
        const parent: SymbolId = if (p.parent_local) |pl| base + pl else invalid;
        try b.symbols.append(b.gpa, .{
            .id = base + @as(u32, @intCast(local)),
            .file = file_id,
            .name = p.name,
            .kind = p.kind,
            .line = p.line,
            .span_start = p.span_start,
            .span_end = p.span_end,
            .sig_end = p.sig_end,
            .doc = p.doc,
            .parent = parent,
            .exported = p.exported,
            .modifiers = p.modifiers,
            .refs = p.refs,
            .bindings = p.bindings,
            .import_path = p.import_path,
        });
    }
    try b.files.append(b.gpa, .{
        .id = file_id,
        .path = try b.arena.dupe(u8, rel_path),
        .language = lang,
        .text = text,
        .parse_health = health,
        .sym_start = base,
        .sym_end = @intCast(b.symbols.items.len),
    });
    try b.stats.append(b.gpa, stat);
}

fn rebuildNameIndex(idx: *Index) !void {
    std.debug.assert(idx.graph.symbols.len != 0);
    std.debug.assert(idx.by_name.count() != 0);
    idx.by_name.deinit(idx.gpa);
    idx.by_name = .empty;
    try buildNameIndex(idx);
}

fn buildNameIndex(idx: *Index) !void {
    var acc = std.StringHashMapUnmanaged(std.ArrayList(SymbolId)){};
    defer {
        var vit = acc.valueIterator();
        while (vit.next()) |v| v.deinit(idx.gpa);
        acc.deinit(idx.gpa);
    }
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        const gop = try acc.getOrPut(idx.gpa, sym.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(idx.gpa, sym.id);
    }
    var it = acc.iterator();
    while (it.next()) |e| {
        const slice = try idx.arena.allocator().dupe(SymbolId, e.value_ptr.items);
        try idx.by_name.put(idx.gpa, e.key_ptr.*, slice);
    }
}

/// Resolve every file's import statements to target `FileId`s (arena-owned),
/// building the per-file import table used for module-qualified resolution and
/// the imports/importers dependency graph.
fn buildImportTable(idx: *Index) !void {
    var by_path = std.StringHashMapUnmanaged(FileId){};
    defer by_path.deinit(idx.gpa);
    for (idx.graph.files) |f| try by_path.put(idx.gpa, f.path, f.id);

    const a = idx.arena.allocator();
    const lists = try a.alloc([]const FileImport, idx.graph.files.len);
    for (idx.graph.files) |f| lists[f.id] = try resolveFileImports(idx, a, f, &by_path);
    idx.file_imports = lists;
}

fn resolveFileImports(
    idx: *const Index,
    arena: std.mem.Allocator,
    f: model.SourceFile,
    by_path: *const std.StringHashMapUnmanaged(FileId),
) ![]const FileImport {
    var tmp: std.ArrayList(FileImport) = .empty;
    defer tmp.deinit(idx.gpa);
    var i = f.sym_start;
    while (i < f.sym_end) : (i += 1) {
        const s = idx.graph.symbols[i];
        if (s.kind != .import or s.import_path.len == 0) continue;
        const target = resolveModule(idx, arena, f, s.import_path, by_path) orelse continue;
        if (target == f.id) continue; // ignore self-imports
        try tmp.append(idx.gpa, .{ .binding = s.name, .target = target });
    }
    return arena.dupe(FileImport, tmp.items);
}

/// Match a module string to an indexed file via language-aware candidate paths.
///
/// After exact path matching fails, Python absolute imports fall back to a
/// unique-suffix match: `from ccso_core.classes.Ship import Ship` yields the
/// candidate `ccso_core/classes/Ship.py`, which in a src-layout monorepo lives
/// at `packages/ccso_core/src/ccso_core/classes/Ship.py`. When exactly one
/// indexed file ends with `/<candidate>` we bind to it; ambiguous suffixes are
/// left unresolved rather than guessed.
fn resolveModule(
    idx: *const Index,
    arena: std.mem.Allocator,
    importer: model.SourceFile,
    module: []const u8,
    by_path: *const std.StringHashMapUnmanaged(FileId),
) ?FileId {
    const cands = imports.candidates(arena, importer.path, module, importer.language) catch return null;
    for (cands) |c| if (by_path.get(c)) |fid| return fid;
    if (importer.language.family() == .python) {
        for (cands) |c| if (uniqueSuffixMatch(idx, c)) |fid| return fid;
    }
    return null;
}

/// The single indexed file whose path is `<something>/<cand>`, or null when
/// there is no such file or more than one (ambiguous → don't guess).
fn uniqueSuffixMatch(idx: *const Index, cand: []const u8) ?FileId {
    var found: FileId = undefined;
    var count: u32 = 0;
    for (idx.graph.files) |f| {
        if (f.path.len <= cand.len) continue;
        if (f.path[f.path.len - cand.len - 1] != '/') continue;
        if (!std.mem.endsWith(u8, f.path, cand)) continue;
        found = f.id;
        count += 1;
        if (count > 1) return null;
    }
    return if (count == 1) found else null;
}

/// Collect `package X` declarations (Go `.module` symbols) into
/// `Index.go_packages`. All allocations go through the arena, so the table
/// dies with the index.
fn buildGoPackageTable(idx: *Index) !void {
    const arena = idx.arena.allocator();
    var lists: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(FileId)) = .empty;
    for (idx.graph.symbols) |sym| {
        if (sym.kind != .module) continue;
        if (idx.graph.files[sym.file].language != .go) continue;
        const slot = try lists.getOrPut(arena, sym.name);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(arena, sym.file);
    }
    var it = lists.iterator();
    while (it.next()) |e| {
        try idx.go_packages.put(arena, e.key_ptr.*, e.value_ptr.items);
    }
}

/// Resolve a Go package-qualified call (`caddy.Load(...)`) to a top-level
/// definition in one of the files declaring `package <qualifier>`. Exact when
/// exactly one package file defines the name; a cross-package name collision
/// binds the first hit as heuristic.
fn goPackageTarget(idx: *const Index, from: model.Symbol, ref: *model.Reference) bool {
    if (idx.graph.files[from.file].language != .go) return false;
    const files = idx.go_packages.get(ref.qualifier) orelse return false;
    var found: SymbolId = invalid;
    var hits: u32 = 0;
    for (files) |fid| {
        if (fid == from.file) continue; // own package is never name-qualified
        const t = topLevelIn(idx, fid, ref.name);
        if (t == invalid) continue;
        hits += 1;
        if (found == invalid) found = t;
    }
    if (found == invalid) return false;
    ref.target = found;
    ref.exact = hits == 1;
    return true;
}

fn resolveReferences(idx: *Index) void {
    for (idx.graph.symbols) |*sym| {
        for (sym.refs) |*ref| {
            resolveOne(idx, sym.*, ref);
        }
    }
}

/// Resolve a single reference to a target definition and set its confidence.
///
/// A member access `recv.name` is *type-scoped*: it resolves only to a member
/// of `recv`'s known type (self/this, or a local binding). If that type is
/// unknown we leave the ref external rather than guess — this is what stops
/// same-name false edges like a stdlib `x.deinit()` pointing at `Index.deinit`.
/// A bare `name(...)` falls back to a heuristic global name match.
fn resolveOne(idx: *const Index, from: model.Symbol, ref: *model.Reference) void {
    if (ref.kind == .route_call) return; // resolved later by linkRoutes
    if (ref.qualifier.len != 0) return resolveQualified(idx, from, ref);
    // A bare name that is a local variable/parameter of `from` is a value read,
    // not a reference to a same-named global — don't bind it (kills false edges
    // like a local `const candidates = ...` pointing at a global `fn candidates`).
    if (isLocalBinding(from, ref.name)) return;
    const candidates = idx.by_name.get(ref.name) orelse return;
    // A bare identifier never denotes a class member: a method/field is always
    // reached through a receiver (`self.x`, `obj.m()`, `Type.m()`). Binding a
    // bare name to a member manufactures false edges — e.g. an untyped local
    // `name` mis-resolving to a class field `RouteContext.name` and inflating
    // that member's fan-in. Restrict bare resolution to top-level definitions.
    const choice = chooseTarget(idx, from, candidates, false);
    ref.target = choice.id;
    ref.exact = choice.confident;
}

/// Whether `name` is a local binding (typed local or parameter) of `from`.
fn isLocalBinding(from: model.Symbol, name: []const u8) bool {
    for (from.bindings) |b| if (std.mem.eql(u8, b.name, name)) return true;
    return false;
}

/// Resolve a member access `recv.name`: first by the receiver's known type
/// (self/this or a local binding), then by treating `recv` as an imported
/// module bound to a file. If neither applies, leave it external.
fn resolveQualified(idx: *const Index, from: model.Symbol, ref: *model.Reference) void {
    // `self`/`this`: dispatch within the *exact* enclosing type (a concrete
    // parent symbol id), never another file's same-named class. Resolving by the
    // bare type name here let `self.put()` escape into a sibling package's class
    // (a confidently-wrong EXACT edge).
    if (isSelfReceiver(ref.qualifier)) {
        if (from.parent != invalid) {
            ref.target = memberOfParent(idx, from.parent, ref.name);
            if (ref.target != invalid) {
                ref.exact = true;
                return;
            }
        }
        // No such member on the own class (inherited/mixin): heuristic below.
    } else if (receiverType(idx, from, ref.qualifier)) |type_name| {
        const m = memberOfType(idx, from.file, type_name, ref.name);
        if (m.id != invalid) {
            ref.target = m.id;
            // A named type that resolves to several same-named classes in
            // different files is ambiguous: bind it but mark it heuristic (`?`)
            // so `--strict` drops it rather than trusting an arbitrary pick.
            ref.exact = m.unambiguous;
            return;
        }
        // Known receiver but no such member here (an inherited/mixin method, or
        // an external type): fall through to the heuristic call match below.
    } else if (ref.write) {
        // Constructor keyword writes carry the constructed type as qualifier.
        // Resolve only against a member of that type; never global-name guess.
        const m = memberOfType(idx, from.file, ref.qualifier, ref.name);
        if (m.id != invalid) {
            ref.target = m.id;
            ref.exact = m.unambiguous;
            return;
        }
    } else if (importTarget(idx, from.file, ref.qualifier)) |file_id| {
        ref.target = topLevelIn(idx, file_id, ref.name);
        if (ref.target != invalid) {
            ref.exact = true;
            return;
        }
    } else if (goPackageTarget(idx, from, ref)) {
        return;
    }
    // Heuristic fallback: a *call* whose receiver type we can't infer
    // (`svc.create_run()`, `self.planning_service.create_run()`, `Foo.bar()` on
    // an untracked value). Bind it by method name so instance/static dispatch is
    // visible to callers/unused/path. Marked non-exact (`?`) — the receiver is a
    // guess, so `--strict` drops it. Only calls, never member *reads* (a `.name`
    // read must not re-inflate a same-named field's fan-in).
    if (ref.kind == .call) {
        ref.target = heuristicMethodTarget(idx, from, ref.name);
        ref.exact = false;
    }
}

/// Best method/function named `name` for an unresolved member *call*: a member
/// of any type (dispatch on an unknown receiver), preferring a same-file and a
/// method definition. Always a guess — the caller marks the edge heuristic.
fn heuristicMethodTarget(idx: *const Index, from: model.Symbol, name: []const u8) SymbolId {
    const candidates = idx.by_name.get(name) orelse return invalid;
    const from_lang = idx.graph.files[from.file].language.family();
    var best: SymbolId = invalid;
    var best_score: i32 = -1;
    var eligible: u32 = 0;
    for (candidates) |cid| {
        if (cid == from.id) continue;
        const cand = idx.graph.symbols[cid];
        if (cand.kind != .function and cand.kind != .method) continue;
        if (idx.graph.files[cand.file].language.family() != from_lang) continue;
        eligible += 1;
        var score: i32 = 0;
        if (cand.kind == .method) score += 2; // `recv.x()` most likely hits a method
        if (cand.file == from.file) score += 1;
        if (score > best_score) {
            best_score = score;
            best = cid;
        }
    }
    // A name with many same-named callables is an interface-dispatch pattern
    // (Go `Provision` across 100+ modules, `sort.Interface.Less`, …). Picking
    // one would pile every call site onto an arbitrary implementation —
    // confidently wrong. Better to leave the call external than to guess 1-in-N.
    if (eligible > max_heuristic_candidates) return invalid;
    return best;
}

/// Above this many same-named callable candidates, a receiver-unknown call is
/// left unresolved instead of heuristically bound (see heuristicMethodTarget).
const max_heuristic_candidates = 4;

/// The file an imported module `binding` refers to inside `file`, if any.
fn importTarget(idx: *const Index, file: FileId, binding: []const u8) ?FileId {
    for (idx.importsOf(file)) |imp| {
        if (imp.binding.len != 0 and std.mem.eql(u8, imp.binding, binding)) return imp.target;
    }
    return null;
}

/// A top-level (non-nested) symbol named `name` in file `file_id`, preferring an
/// exported one. `invalid` when the file has no such definition.
fn topLevelIn(idx: *const Index, file_id: FileId, name: []const u8) SymbolId {
    const f = idx.graph.files[file_id];
    var fallback: SymbolId = invalid;
    var i = f.sym_start;
    while (i < f.sym_end) : (i += 1) {
        const s = idx.graph.symbols[i];
        if (s.parent != invalid or s.kind == .import) continue;
        if (!std.mem.eql(u8, s.name, name)) continue;
        if (s.exported) return s.id;
        if (fallback == invalid) fallback = s.id;
    }
    return fallback;
}

/// Resolve `route_call` references (HTTP client calls) to the `route` symbol
/// whose method and path pattern they match — the cross-language edge that links
/// a frontend fetch/axios/requests call to the backend endpoint that serves it.
fn linkRoutes(idx: *Index) void {
    for (idx.graph.symbols) |*sym| {
        for (sym.refs) |*ref| {
            if (ref.kind != .route_call) continue;
            ref.target = matchRoute(idx, ref.name);
            ref.exact = ref.target != invalid;
        }
    }
}

/// Apply one cross-file prefix per mounted route file before client linking.
/// Returns whether any route name changed, so the name index can be rebuilt.
fn applyRouterMounts(idx: *Index) bool {
    const arena = idx.arena.allocator();
    const done = idx.gpa.alloc(bool, idx.graph.files.len) catch return false;
    defer idx.gpa.free(done);
    @memset(done, false);
    var changed = false;
    for (idx.graph.symbols) |mount| {
        if (mount.kind != .route_mount) continue;
        std.debug.assert(mount.file < idx.graph.files.len);
        const target = mountTargetFile(idx, mount.file, mount.import_path) orelse continue;
        if (done[target]) continue;
        done[target] = true;
        changed = prefixRoutesIn(idx, arena, target, mount.name) or changed;
    }
    return changed;
}

/// The file whose routes a mount in `from_file` prefixes. A dotted router arg
/// (`orders.router`, `module` = "orders") binds to an imported route-file whose
/// path stem is that module, else the sole project route-file with that stem
/// (import edges often resolve only to the package, not the submodule). A bare
/// arg falls back to the sole imported route-file. Null when ambiguous/absent.
fn mountTargetFile(idx: *const Index, from_file: FileId, module: []const u8) ?FileId {
    const stem = moduleStem(module);
    const imports_for_file = idx.importsOf(from_file);
    var single: FileId = invalid;
    var route_files: u32 = 0;
    for (imports_for_file, 0..) |imp, pos| {
        if (!fileHasRoutes(idx, imp.target)) continue;
        if (module.len != 0 and std.mem.eql(u8, imp.binding, module)) return imp.target;
        if (stem.len != 0 and pathStemEquals(idx.graph.files[imp.target].path, stem)) return imp.target;
        var duplicate = false;
        for (imports_for_file[0..pos]) |prior| duplicate = duplicate or prior.target == imp.target;
        if (duplicate) continue;
        route_files += 1;
        single = imp.target;
    }
    if (stem.len != 0) return uniqueRouteFileWithStem(idx, stem);
    if (route_files == 1) return single;
    return null;
}

fn moduleStem(module: []const u8) []const u8 {
    if (module.len == 0) return module;
    const slash = std.mem.lastIndexOfScalar(u8, module, '/');
    const dot = std.mem.lastIndexOfScalar(u8, module, '.');
    const cut = if (slash) |s| if (dot) |d| @max(s, d) else s else dot orelse return module;
    if (cut + 1 >= module.len) return "";
    return module[cut + 1 ..];
}

/// The single project file that both defines routes and has path stem `stem`
/// (`routers/orders.py` for "orders"). Null when there is no such file or more
/// than one — an ambiguous stem must not be guessed.
fn uniqueRouteFileWithStem(idx: *const Index, stem: []const u8) ?FileId {
    var found: FileId = invalid;
    var count: u32 = 0;
    for (idx.graph.files) |f| {
        if (!pathStemEquals(f.path, stem)) continue;
        if (!fileHasRoutes(idx, f.id)) continue;
        found = f.id;
        count += 1;
        if (count > 1) return null;
    }
    return if (count == 1) found else null;
}

/// Whether file `fid` defines at least one `route` symbol.
fn fileHasRoutes(idx: *const Index, fid: FileId) bool {
    const f = idx.graph.files[fid];
    var i = f.sym_start;
    while (i < f.sym_end) : (i += 1) {
        if (idx.graph.symbols[i].kind == .route) return true;
    }
    return false;
}

/// Whether `path`'s basename without extension equals `stem` (`routers/orders.py`
/// vs "orders").
fn pathStemEquals(path: []const u8, stem: []const u8) bool {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const base = if (slash) |s| path[s + 1 ..] else path;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    const name = if (dot) |d| base[0..d] else base;
    return std.mem.eql(u8, name, stem);
}

/// Prepend `prefix` to the path of every `route` symbol in file `fid`. A route
/// name is "METHOD /path"; the method and any construction prefix are preserved.
fn prefixRoutesIn(idx: *Index, arena: std.mem.Allocator, fid: FileId, prefix: []const u8) bool {
    const f = idx.graph.files[fid];
    var changed = false;
    var i = f.sym_start;
    while (i < f.sym_end) : (i += 1) {
        var sym = &idx.graph.symbols[i];
        if (sym.kind != .route) continue;
        const ep = api.splitKey(sym.name) orelse continue;
        const new_path = if (std.mem.eql(u8, ep.path, "/"))
            arena.dupe(u8, prefix) catch continue
        else
            std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, ep.path }) catch continue;
        sym.name = std.fmt.allocPrint(arena, "{s} {s}", .{ ep.method, new_path }) catch continue;
        changed = true;
    }
    return changed;
}

fn matchRoute(idx: *const Index, client_key: []const u8) SymbolId {
    const c = api.splitKey(client_key) orelse return invalid;
    for (idx.graph.symbols) |rsym| {
        if (rsym.kind != .route) continue;
        const r = api.splitKey(rsym.name) orelse continue;
        if (api.methodsMatch(r.method, c.method) and api.pathsMatch(r.path, c.path)) return rsym.id;
    }
    return invalid;
}

/// Whether `qualifier` is the current-instance receiver (`self`/`this`), whose
/// dispatch is scoped to the exact enclosing type rather than a type name.
fn isSelfReceiver(qualifier: []const u8) bool {
    return std.mem.eql(u8, qualifier, "self") or std.mem.eql(u8, qualifier, "this");
}

/// The type name a *named* receiver identifier refers to inside `from`'s body: a
/// local `var -> type` binding. `self`/`this` are handled separately (scoped by
/// the concrete parent id, see `memberOfParent`).
fn receiverType(idx: *const Index, from: model.Symbol, qualifier: []const u8) ?[]const u8 {
    _ = idx;
    // Return only a *typed* binding: bindings now also carry untyped locals and
    // parameters (name-only, empty type) to shadow same-named globals in bare
    // resolution, but those give no receiver type to scope a member access by.
    for (from.bindings) |b| {
        if (std.mem.eql(u8, b.name, qualifier) and b.type_name.len > 0) return b.type_name;
    }
    return null;
}

/// The member named `name` defined directly on the exact type `parent_id`. This
/// scopes `self`/`this` dispatch to the receiver's own class, so it can never
/// bind to a same-named class in another file.
fn memberOfParent(idx: *const Index, parent_id: SymbolId, name: []const u8) SymbolId {
    const candidates = idx.by_name.get(name) orelse return invalid;
    for (candidates) |cid| {
        if (idx.graph.symbols[cid].parent == parent_id) return cid;
    }
    return invalid;
}

/// A resolved member plus whether the pick was unambiguous. `unambiguous` is
/// false when several classes named the same as the receiver type define the
/// member in different files, so the caller can downgrade the edge to heuristic.
const MemberMatch = struct { id: SymbolId, unambiguous: bool };

/// The member named `name` whose parent type is `type_name`, scoped for a *named*
/// receiver of that type. A member on a type defined in `from_file` wins (a
/// same-file/-package receiver resolves to its own class); otherwise the sole
/// project-wide match is taken as unambiguous, and if the type name collides
/// across files the first is returned but flagged ambiguous.
fn memberOfType(idx: *const Index, from_file: FileId, type_name: []const u8, name: []const u8) MemberMatch {
    const candidates = idx.by_name.get(name) orelse return .{ .id = invalid, .unambiguous = false };
    var any: SymbolId = invalid;
    var matches: u32 = 0;
    for (candidates) |cid| {
        const cand = idx.graph.symbols[cid];
        if (cand.parent == invalid) continue;
        if (!std.mem.eql(u8, idx.graph.symbols[cand.parent].name, type_name)) continue;
        if (cand.file == from_file) return .{ .id = cid, .unambiguous = true };
        matches += 1;
        if (any == invalid) any = cid;
    }
    if (any == invalid) return .{ .id = invalid, .unambiguous = false };
    return .{ .id = any, .unambiguous = matches == 1 };
}

const Choice = struct { id: SymbolId, confident: bool };

/// Pick the best definition for a bare reference: prefer same file, then same
/// language family, then a callable over a value. `confident` is set when the
/// pick is unambiguous (same file, or the only candidate).
fn chooseTarget(idx: *const Index, from: model.Symbol, candidates: []const SymbolId, allow_members: bool) Choice {
    std.debug.assert(candidates.len > 0);
    const from_lang = idx.graph.files[from.file].language.family();
    var best: SymbolId = invalid;
    var best_score: i32 = -1;
    var eligible: u32 = 0;
    for (candidates) |cid| {
        if (cid == from.id) continue;
        const cand = idx.graph.symbols[cid];
        // A bare reference resolves only to a top-level definition, never a class
        // member (which needs a receiver). Skip members unless the caller asks
        // for them (the qualified-call heuristic does).
        if (!allow_members and cand.parent != invalid) continue;
        // Never bind a bare reference across language families: a Python `Ship`
        // and a TSX component `Ship` share a name but not a namespace. The only
        // intended cross-language edge (client call → route) is a route_call,
        // resolved separately in `linkRoutes`.
        if (idx.graph.files[cand.file].language.family() != from_lang) continue;
        eligible += 1;
        var score: i32 = 0;
        if (cand.file == from.file) score += 4;
        if (cand.kind == .function or cand.kind == .method) score += 1;
        if (score > best_score) {
            best_score = score;
            best = cid;
        }
    }
    const confident = best != invalid and (eligible == 1 or best_score >= 4);
    return .{ .id = best, .confident = confident };
}

fn buildCallers(idx: *Index) !void {
    const n = idx.graph.symbols.len;
    var counts = try idx.gpa.alloc(u32, n);
    defer idx.gpa.free(counts);
    @memset(counts, 0);
    for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            if (ref.target != invalid) counts[ref.target] += 1;
        }
    }
    const a = idx.arena.allocator();
    const lists = try a.alloc([]SymbolId, n);
    for (lists, 0..) |*slot, i| slot.* = try a.alloc(SymbolId, counts[i]);
    @memset(counts, 0);
    for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            if (ref.target == invalid) continue;
            lists[ref.target][counts[ref.target]] = sym.id;
            counts[ref.target] += 1;
        }
    }
    idx.callers = try idx.gpa.dupe([]SymbolId, lists);
}

test "module-qualified calls resolve through imports" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "util.zig", .data =
        \\pub fn helper(x: i32) i32 {
        \\    return x;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data =
        \\const util = @import("util.zig");
        \\pub fn run() i32 {
        \\    return util.helper(41);
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const helper = idx.lookup("helper")[0];
    const run = idx.graph.symbols[idx.lookup("run")[0]];
    var linked = false;
    for (run.refs) |ref| {
        if (!std.mem.eql(u8, ref.name, "helper")) continue;
        try testing.expectEqualStrings("util", ref.qualifier);
        try testing.expectEqual(helper, ref.target); // resolved via import, not name
        try testing.expect(ref.exact);
        linked = true;
    }
    try testing.expect(linked);
    // The reverse edge and the import dependency graph both exist.
    try testing.expectEqual(run.id, idx.callersOf(helper)[0]);
    const main_file = idx.graph.symbols[run.id].file;
    try testing.expect(idx.importsOf(main_file).len == 1);
}

test "qualified call to a same-named function in another module resolves" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "util.zig", .data =
        \\pub fn run() i32 {
        \\    return 1;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data =
        \\const util = @import("util.zig");
        \\pub fn run() i32 {
        \\    return util.run();
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // `main.run` calls `util.run` — the shared name must not be dropped as a
    // self-reference; the qualified edge must point at util's run, not itself.
    const util_run = qualifiedFileSym(&idx, "util.zig", "run").?;
    const main_run = qualifiedFileSym(&idx, "main.zig", "run").?;
    const caller = idx.graph.symbols[main_run];
    var linked = false;
    for (caller.refs) |ref| {
        if (!std.mem.eql(u8, ref.name, "run")) continue;
        try testing.expectEqualStrings("util", ref.qualifier);
        try testing.expectEqual(util_run, ref.target);
        try testing.expect(ref.target != main_run);
        linked = true;
    }
    try testing.expect(linked);
}

test "src-layout package imports resolve by unique suffix, no cross-language edge" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A src-layout monorepo: the installed package name `pkg` sits under
    // `libs/pkg/src/pkg/`, so the import path never matches an on-disk prefix.
    try tmp.dir.createDirPath(io, "libs/pkg/src/pkg");
    try tmp.dir.createDirPath(io, "app");
    try tmp.dir.createDirPath(io, "web");
    try tmp.dir.writeFile(io, .{ .sub_path = "libs/pkg/src/pkg/ship.py", .data =
        \\class Ship:
        \\    def sail(self):
        \\        return 1
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/main.py", .data =
        \\from pkg.ship import Ship
        \\def run():
        \\    return Ship()
    });
    // A TS component that only mentions the name "Ship" — must not become an edge.
    try tmp.dir.writeFile(io, .{ .sub_path = "web/editor.ts", .data =
        \\export function ShipEditor() {
        \\    return Ship;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // The cross-package import binds to the real file despite the src-layout.
    const main_file = idx.graph.symbols[idx.lookup("run")[0]].file;
    const ship_file = idx.graph.symbols[idx.lookup("Ship")[0]].file;
    try testing.expectEqual(@as(usize, 1), idx.importsOf(main_file).len);
    try testing.expectEqual(ship_file, idx.importsOf(main_file)[0].target);

    // The Python class `Ship` is referenced only from Python `run`, never from
    // the TS component that merely shares the name.
    const ship = idx.lookup("Ship")[0];
    const callers = idx.callersOf(ship);
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqual(idx.lookup("run")[0], callers[0]);
}

test "a build-output name under a source tree is indexed; at the root it is pruned" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Legit source: satellite-coverage math under a `src` tree. `coverage` is a
    // build-output convention (nyc/jest), but nested under src it's a domain dir
    // and must be indexed — the silent-eat bug a trial hit.
    try tmp.dir.createDirPath(io, "frontend/src/coverage");
    try tmp.dir.writeFile(io, .{ .sub_path = "frontend/src/coverage/CoverageSystem.js", .data =
        \\export class CoverageSystem {
        \\    halfAngle() { return 1; }
        \\}
    });
    // Real build output at the repo root — must stay pruned.
    try tmp.dir.createDirPath(io, "coverage");
    try tmp.dir.writeFile(io, .{ .sub_path = "coverage/lcovReport.js", .data =
        \\export function lcovArtifact() { return 0; }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // The nested source directory is indexed…
    try testing.expectEqual(@as(usize, 1), idx.lookup("CoverageSystem").len);
    // …while the root-level build artifact stays pruned.
    try testing.expectEqual(@as(usize, 0), idx.lookup("lcovArtifact").len);
}

fn qualifiedFileSym(idx: *const Index, file_suffix: []const u8, name: []const u8) ?SymbolId {
    for (idx.graph.symbols) |s| {
        if (!std.mem.eql(u8, s.name, name)) continue;
        if (std.mem.endsWith(u8, idx.graph.files[s.file].path, file_suffix)) return s.id;
    }
    return null;
}

test "incremental cache: second build restores identical symbols from disk" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn alpha(x: i32) i32 {
        \\    return beta(x);
        \\}
        \\pub fn beta(x: i32) i32 {
        \\    return x;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // First build parses and writes `.navgraph/cache`.
    var cold = try build(testing.allocator, io, root, true);
    const cold_names = try dupeNames(testing.allocator, &cold);
    defer freeNames(testing.allocator, cold_names);
    const cold_alpha = cold.lookup("alpha")[0];
    const cold_beta_callers = cold.callersOf(cold.lookup("beta")[0]).len;
    cold.deinit();

    // Second build restores from the cache; the resulting graph must match.
    var warm = try build(testing.allocator, io, root, true);
    defer warm.deinit();
    try testing.expectEqual(cold_names.len, warm.graph.symbols.len);
    for (cold_names, warm.graph.symbols) |name, sym| try testing.expectEqualStrings(name, sym.name);
    // Resolution re-runs on the restored symbols: the alpha→beta edge survives.
    try testing.expectEqual(cold_alpha, warm.lookup("alpha")[0]);
    try testing.expectEqual(cold_beta_callers, warm.callersOf(warm.lookup("beta")[0]).len);
    try testing.expect(cold_beta_callers == 1);
}

/// Copy every symbol name (bytes and all) so the comparison outlives the index
/// whose arena owns the originals.
fn dupeNames(gpa: std.mem.Allocator, idx: *const Index) ![][]const u8 {
    const names = try gpa.alloc([]const u8, idx.graph.symbols.len);
    for (idx.graph.symbols, names) |sym, *slot| slot.* = try gpa.dupe(u8, sym.name);
    return names;
}

fn freeNames(gpa: std.mem.Allocator, names: [][]const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

test "links a frontend HTTP client call to a backend route across languages" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "api.py", .data =
        \\app = FastAPI()
        \\@app.get("/users/{id}")
        \\def get_user(id):
        \\    return id
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function loadUser(id) {
        \\  return fetch(`/users/${id}`);
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // The route symbol exists and links to its handler.
    const route_id = routeId(&idx).?;
    const route = idx.graph.symbols[route_id];
    try testing.expectEqualStrings("GET /users/{id}", route.name);

    // The frontend fetch resolves (exact) to that route across languages.
    const loader = idx.graph.symbols[idx.lookup("loadUser")[0]];
    var linked = false;
    for (loader.refs) |ref| {
        if (ref.kind != .route_call) continue;
        try testing.expectEqual(route_id, ref.target);
        try testing.expect(ref.exact);
        linked = true;
    }
    try testing.expect(linked);
    // And the route's callers include the frontend loader.
    try testing.expectEqual(loader.id, idx.callersOf(route_id)[0]);
}

fn routeId(idx: *const Index) ?SymbolId {
    for (idx.graph.symbols) |s| if (s.kind == .route) return s.id;
    return null;
}

fn routeCallRef(sym: model.Symbol) ?model.Reference {
    for (sym.refs) |ref| if (ref.kind == .route_call) return ref;
    return null;
}

test "include_router prefix is applied across files and links a prefixed client" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "routers");
    // The route is declared bare (/orders) in the router module.
    try tmp.dir.writeFile(io, .{ .sub_path = "routers/orders.py", .data =
        \\from fastapi import APIRouter
        \\router = APIRouter()
        \\@router.post("/orders")
        \\def create_order():
        \\    return 1
    });
    // The app mounts it under /v1 in a different file.
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\from fastapi import FastAPI
        \\from .routers import orders
        \\app = FastAPI()
        \\app.include_router(orders.router, prefix="/v1")
    });
    // A frontend that calls the fully-prefixed path.
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function placeOrder() {
        \\  return fetch("/v1/orders", { method: "POST" });
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // The route's path carries the mount prefix.
    const route_id = routeId(&idx).?;
    try testing.expectEqualStrings("POST /v1/orders", idx.graph.symbols[route_id].name);

    // The prefixed client call links (exact) to the route.
    const client = idx.graph.symbols[idx.lookup("placeOrder")[0]];
    var linked = false;
    for (client.refs) |ref| {
        if (ref.kind != .route_call) continue;
        try testing.expectEqual(route_id, ref.target);
        try testing.expect(ref.exact);
        linked = true;
    }
    try testing.expect(linked);
}

test "aliased from-import mount stacks with an APIRouter prefix" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "backend/app/routes");
    try tmp.dir.writeFile(io, .{ .sub_path = "backend/app/routes/aoi_library.py", .data =
        \\from fastapi import APIRouter
        \\router = APIRouter(prefix="/aoi-library")
        \\@router.get("")
        \\def list_aois():
        \\    return []
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "backend/app/routes/health.py", .data =
        \\from fastapi import APIRouter
        \\router = APIRouter()
        \\@router.get("/health")
        \\def health(): return 1
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "backend/app/main.py", .data =
        \\from .routes.aoi_library import router as aoi_library_router
        \\from .routes.health import router as health_router
        \\app.include_router(aoi_library_router, prefix="/api/v1")
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "module_app.py", .data =
        \\import backend.app.routes.health as health_routes
        \\app.include_router(health_routes.router, prefix="/api/v2")
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function listLibraryAois(query: string) {
        \\  return fetch(`/api/v1/aoi-library${query ? `?${query}` : ""}`);
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const route_id = routeByName(&idx, "GET /api/v1/aoi-library").?;
    try testing.expectEqualStrings("GET /api/v1/aoi-library", idx.graph.symbols[route_id].name);
    try testing.expectEqual(@as(usize, 1), idx.lookup("GET /api/v1/aoi-library").len);
    try testing.expectEqual(@as(usize, 0), idx.lookup("GET /aoi-library").len);
    try testing.expect(routeByName(&idx, "GET /api/v2/health") != null);
    const client = idx.graph.symbols[idx.lookup("listLibraryAois")[0]];
    const route_ref = routeCallRef(client).?;
    try testing.expectEqual(route_id, route_ref.target);
    try testing.expect(route_ref.exact);
}

test "trailing conditional client path does not wildcard-match the first route" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "routes.py", .data =
        \\@app.get("/health")
        \\def health(): return 1
        \\@app.get("/aoi-library")
        \\def list_aois(): return []
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function listLibraryAois(query: string) {
        \\  return fetch(`/aoi-library${query ? `?${query}` : ""}`);
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();
    const client = idx.graph.symbols[idx.lookup("listLibraryAois")[0]];
    const route_ref = routeCallRef(client).?;
    const target = idx.graph.symbols[route_ref.target];
    try testing.expectEqualStrings("GET /aoi-library", target.name);
    try testing.expect(!std.mem.eql(u8, target.name, "GET /health"));
}

test "links a frontend call through a request() wrapper to a backend route" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "api.py", .data =
        \\app = FastAPI()
        \\@app.get("/things/{id}")
        \\def get_thing(id):
        \\    return id
    });
    // A generic wrapper that forwards its path to fetch, plus a client function
    // that calls the wrapper (never fetch directly) with a template path — the
    // pattern that produced zero edges before wrapper detection.
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\const BASE = "/api";
        \\async function request(path, opts) {
        \\  return fetch(`${BASE}${path}`, opts);
        \\}
        \\function loadThing(id) {
        \\  return request(`/things/${id}`);
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const route_id = routeId(&idx).?;
    // The client function reaches the route through the wrapper call, not fetch.
    const loader = idx.graph.symbols[idx.lookup("loadThing")[0]];
    var linked = false;
    for (loader.refs) |ref| {
        if (ref.kind != .route_call) continue;
        try testing.expectEqual(route_id, ref.target);
        linked = true;
    }
    try testing.expect(linked);
    try testing.expectEqual(loader.id, idx.callersOf(route_id)[0]);
}

test "member calls: typed receiver is exact; unknown receiver is a heuristic guess" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub const Foo = struct {
        \\    pub fn stop(self: *Foo) void {}
        \\};
        \\pub const Bar = struct {
        \\    pub fn stop(self: *Bar) void {}
        \\};
        \\pub fn run(f: *Foo) void {
        \\    f.stop();
        \\    g.stop();
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // The typed `f.stop()` must resolve to Foo.stop (exact), never Bar.stop.
    const foo_stop = qualifiedId(&idx, "Foo", "stop").?;
    const bar_stop = qualifiedId(&idx, "Bar", "stop").?;
    const run = idx.graph.symbols[idx.lookup("run")[0]];
    var checked = false;
    for (run.refs) |ref| {
        if (!std.mem.eql(u8, ref.name, "stop")) continue;
        if (std.mem.eql(u8, ref.qualifier, "f")) {
            try testing.expectEqual(foo_stop, ref.target);
            try testing.expect(ref.target != bar_stop);
            try testing.expect(ref.exact);
            checked = true;
        } else if (std.mem.eql(u8, ref.qualifier, "g")) {
            // Unknown receiver type: a *call* is bound to a same-named method by
            // the dispatch heuristic so it stays visible, but never as an exact
            // edge (`--strict` drops it) — the receiver is only a guess.
            try testing.expect(ref.target == foo_stop or ref.target == bar_stop);
            try testing.expect(!ref.exact);
        }
    }
    try testing.expect(checked);
}

test "a bare identifier never binds to a same-named class member" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A class field `name` and a free function with a bare local `name`. The
    // bare `name` must not resolve to `Ctx.name` — that false edge is what
    // inflated a property's fan-in across a real repo.
    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\class Ctx:
        \\    name: str = ""
        \\
        \\def build(x):
        \\    name = x + "!"
        \\    return name
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const field = qualifiedId(&idx, "Ctx", "name").?;
    try testing.expectEqual(@as(usize, 0), idx.callersOf(field).len);
}

fn qualifiedId(idx: *const Index, parent: []const u8, child: []const u8) ?SymbolId {
    for (idx.lookup(child)) |id| {
        const sym = idx.graph.symbols[id];
        if (sym.parent == invalid) continue;
        if (std.mem.eql(u8, idx.graph.symbols[sym.parent].name, parent)) return id;
    }
    return null;
}

/// A member `parent.child` whose defining file's path contains `path_frag` —
/// disambiguates same-named classes that live in different files.
fn qualifiedIdInFile(idx: *const Index, parent: []const u8, child: []const u8, path_frag: []const u8) ?SymbolId {
    for (idx.lookup(child)) |id| {
        const sym = idx.graph.symbols[id];
        if (sym.parent == invalid) continue;
        if (!std.mem.eql(u8, idx.graph.symbols[sym.parent].name, parent)) continue;
        if (std.mem.indexOf(u8, idx.graph.files[sym.file].path, path_frag) != null) return id;
    }
    return null;
}

test "self-dispatch and a typed receiver stay in their own file's class" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Two packages each define `Store` with `put`. `self.put()` and a typed
    // `s: *Store` receiver must bind to pkg_a's Store.put, never pkg_b's.
    try tmp.dir.createDirPath(io, "pkg_a");
    try tmp.dir.createDirPath(io, "pkg_b");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg_a/store.zig", .data =
        \\pub const Store = struct {
        \\    pub fn put(self: *Store, x: i32) void {}
        \\    pub fn put_twice(self: *Store) void {
        \\        self.put(1);
        \\        self.put(2);
        \\    }
        \\};
        \\pub fn use_store(s: *Store) void {
        \\    s.put(3);
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg_b/store.zig", .data =
        \\pub const Store = struct {
        \\    pub fn put(self: *Store, x: i32) void {}
        \\};
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const a_put = qualifiedIdInFile(&idx, "Store", "put", "pkg_a").?;
    const b_put = qualifiedIdInFile(&idx, "Store", "put", "pkg_b").?;
    try testing.expect(a_put != b_put);

    // self.put() resolves to pkg_a Store.put, exact.
    const put_twice = qualifiedIdInFile(&idx, "Store", "put_twice", "pkg_a").?;
    var saw_self = false;
    for (idx.graph.symbols[put_twice].refs) |ref| {
        if (!std.mem.eql(u8, ref.name, "put")) continue;
        try testing.expectEqual(a_put, ref.target);
        try testing.expect(ref.exact);
        saw_self = true;
    }
    try testing.expect(saw_self);

    // s.put() with `s: *Store` resolves to pkg_a Store.put, exact.
    const use_store = idx.graph.symbols[idx.lookup("use_store")[0]];
    var saw_typed = false;
    for (use_store.refs) |ref| {
        if (!std.mem.eql(u8, ref.name, "put")) continue;
        try testing.expectEqual(a_put, ref.target);
        try testing.expect(ref.exact);
        saw_typed = true;
    }
    try testing.expect(saw_typed);

    // pkg_b Store.put gains no phantom cross-package caller.
    try testing.expectEqual(@as(usize, 0), idx.callersOf(b_put).len);
}

test "build index over a temp project resolves cross-file calls" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "util.zig", .data =
        \\pub fn helper(x: i32) i32 {
        \\    return x + 1;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data =
        \\const util = @import("util.zig");
        \\pub fn run() i32 {
        \\    return helper(41);
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    try testing.expect(idx.graph.files.len == 2);
    const helper_ids = idx.lookup("helper");
    try testing.expectEqual(@as(usize, 1), helper_ids.len);
    // `run` in main.zig should have a resolved edge to `helper` in util.zig.
    const run_ids = idx.lookup("run");
    try testing.expectEqual(@as(usize, 1), run_ids.len);
    const run = idx.graph.symbols[run_ids[0]];
    var resolved = false;
    for (run.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "helper")) {
            try testing.expectEqual(helper_ids[0], ref.target);
            resolved = true;
        }
    }
    try testing.expect(resolved);
    // And the reverse index: helper is called by run.
    const callers = idx.callersOf(helper_ids[0]);
    try testing.expectEqual(@as(usize, 1), callers.len);
    try testing.expectEqual(run_ids[0], callers[0]);
}

test "a POST fetch with a method option links to the POST route, not the GET route" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "api.py", .data =
        \\app = FastAPI()
        \\@app.get("/orders")
        \\def list_orders():
        \\    return []
        \\@app.post("/orders")
        \\def create_order():
        \\    return 1
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function createOrder(o) {
        \\  return fetch('/orders', { method: 'POST' });
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const post_route = routeByName(&idx, "POST /orders").?;
    const creator = idx.graph.symbols[idx.lookup("createOrder")[0]];
    var linked_target: SymbolId = invalid;
    for (creator.refs) |ref| {
        if (ref.kind == .route_call) linked_target = ref.target;
    }
    try testing.expectEqual(post_route, linked_target); // POST, not the GET route
}

fn routeByName(idx: *const Index, name: []const u8) ?SymbolId {
    for (idx.graph.symbols) |s| {
        if (s.kind == .route and std.mem.eql(u8, s.name, name)) return s.id;
    }
    return null;
}

test "an inline-arrow route gets no phantom handler; an identifier arg is linked" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "routes.js", .data =
        \\const router = express.Router();
        \\router.get('/items', listItems);
        \\router.delete('/items/:id', (req, res) => { return del(); });
        \\function listItems(req, res) { return 1; }
        \\function del() { return 2; }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // GET route → its identifier handler `listItems`.
    const get_route = idx.graph.symbols[routeByName(&idx, "GET /items").?];
    var get_handler: SymbolId = invalid;
    for (get_route.refs) |r| if (r.kind == .call and r.target != invalid) {
        get_handler = r.target;
    };
    try testing.expectEqual(idx.lookup("listItems")[0], get_handler);

    // DELETE route has an inline anonymous arrow → NO handler ref at all (the
    // forward `function` scan must not bind the unrelated `listItems`/`del`).
    const del_route = idx.graph.symbols[routeByName(&idx, "DELETE /items/:id").?];
    for (del_route.refs) |r| try testing.expect(r.kind != .call);
}

test "FastAPI decorator kwargs (response_model) don't hijack the handler" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // The decorator's `response_model=` kwarg sits exactly where an Express
    // identifier handler would — the route must still bind the following `def`.
    try tmp.dir.writeFile(io, .{ .sub_path = "dash.py", .data =
        \\router = APIRouter(prefix="/ops")
        \\@router.get("/dashboard", response_model=DashboardResponse)
        \\def get_operations_dashboard():
        \\    return {}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const route = idx.graph.symbols[routeByName(&idx, "GET /ops/dashboard").?];
    var handler: SymbolId = invalid;
    for (route.refs) |r| if (r.kind == .call and r.target != invalid) {
        handler = r.target;
    };
    try testing.expectEqual(idx.lookup("get_operations_dashboard")[0], handler);
}

test "python relative imports resolve to package files" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "app/services");
    try tmp.dir.writeFile(io, .{ .sub_path = "app/services/user_service.py", .data =
        \\class UserService:
        \\    def fetch(self, id):
        \\        return id
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "app/routes.py", .data =
        \\from .services.user_service import UserService
        \\def get_user(id):
        \\    return UserService().fetch(id)
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const routes_file = idx.graph.symbols[idx.lookup("get_user")[0]].file;
    const svc_file = idx.graph.symbols[idx.lookup("UserService")[0]].file;
    try testing.expectEqual(@as(usize, 1), idx.importsOf(routes_file).len);
    try testing.expectEqual(svc_file, idx.importsOf(routes_file)[0].target);
}

test "a bare read of a local variable is not bound to a same-named global" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub fn candidates() u32 {
        \\    return 1;
        \\}
        \\pub fn use() u32 {
        \\    const candidates = Thing.init();
        \\    return candidates.len;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // `use`'s local `candidates` must not create an edge to the global fn.
    const cand_fn = idx.lookup("candidates")[0];
    try testing.expectEqual(@as(usize, 0), idx.callersOf(cand_fn).len);
}

test "go: a call resolves across files within the Go family" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "store.go", .data =
        \\package app
        \\func Save(x int) int { return x }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "handler.go", .data =
        \\package app
        \\func Handle() int { return Save(1) }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const save = idx.lookup("Save")[0];
    const handle = idx.lookup("Handle")[0];
    // The cross-file `Save(1)` call resolves and shows Handle as a caller.
    try testing.expectEqual(handle, idx.callersOf(save)[0]);
}

test "rust: a call resolves by name across files within the Rust family" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "util.rs", .data =
        \\pub fn parse(s: &str) -> u32 { 0 }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.rs", .data =
        \\mod util;
        \\pub fn run() -> u32 { parse("x") }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const parse = idx.lookup("parse")[0];
    const run = idx.lookup("run")[0];
    try testing.expectEqual(run, idx.callersOf(parse)[0]);
    // `mod util;` resolved to util.rs as an import dependency.
    const main_file = idx.graph.symbols[run].file;
    try testing.expectEqual(@as(usize, 1), idx.importsOf(main_file).len);
}

test "ruby: require_relative resolves and a cross-file call links within the Ruby family" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "util.rb", .data =
        \\def helper(x)
        \\  x + 1
        \\end
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.rb", .data =
        \\require_relative "util"
        \\def run
        \\  helper(1)
        \\end
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const helper = idx.lookup("helper")[0];
    const run = idx.lookup("run")[0];
    // The `helper(1)` call resolves to util.rb's top-level def.
    try testing.expectEqual(run, idx.callersOf(helper)[0]);
    // require_relative bound main.rb → util.rb as an import.
    const main_file = idx.graph.symbols[run].file;
    try testing.expectEqual(@as(usize, 1), idx.importsOf(main_file).len);
}

test "cross-language: a Go and a Python function sharing a name stay isolated" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "svc.go", .data =
        \\package app
        \\func Process() int { return 1 }
        \\func Run() int { return Process() }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "svc.py", .data =
        \\def Process():
        \\    return 2
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // Both `Process` definitions exist under one name.
    try testing.expectEqual(@as(usize, 2), idx.lookup("Process").len);
    const go_process = qualifiedFileSym(&idx, "svc.go", "Process").?;
    const py_process = qualifiedFileSym(&idx, "svc.py", "Process").?;
    const run = idx.lookup("Run")[0];

    // The Go `Run` links only to the Go `Process`; the Python one has no callers.
    try testing.expectEqual(run, idx.callersOf(go_process)[0]);
    try testing.expectEqual(@as(usize, 0), idx.callersOf(py_process).len);
}

test "cross-language: Rust and Go definitions with the same name do not cross-link" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "lib.rs", .data =
        \\pub fn encode() -> u32 { helper() }
        \\pub fn helper() -> u32 { 1 }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "enc.go", .data =
        \\package app
        \\func helper() int { return 2 }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const rs_helper = qualifiedFileSym(&idx, "lib.rs", "helper").?;
    const go_helper = qualifiedFileSym(&idx, "enc.go", "helper").?;
    const encode = idx.lookup("encode")[0];
    // The Rust `encode` calls the Rust `helper`, never the Go one.
    try testing.expectEqual(encode, idx.callersOf(rs_helper)[0]);
    try testing.expectEqual(@as(usize, 0), idx.callersOf(go_helper).len);
}

test "cross-language: a mixed Go/Rust/Ruby/Python repo resolves only within families" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Each language defines and calls its own `compute`; none may bleed.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.go", .data =
        \\package app
        \\func compute() int { return 1 }
        \\func GoRun() int { return compute() }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.rs", .data =
        \\fn compute() -> u32 { 1 }
        \\pub fn rs_run() -> u32 { compute() }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.rb", .data =
        \\def compute
        \\  1
        \\end
        \\def rb_run
        \\  compute()
        \\end
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "d.py", .data =
        \\def compute():
        \\    return 1
        \\def py_run():
        \\    return compute()
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // Four distinct `compute` definitions, each with exactly one caller from its
    // own language.
    try testing.expectEqual(@as(usize, 4), idx.lookup("compute").len);
    inline for (.{
        .{ "a.go", "GoRun" },
        .{ "b.rs", "rs_run" },
        .{ "c.rb", "rb_run" },
        .{ "d.py", "py_run" },
    }) |c| {
        const compute = qualifiedFileSym(&idx, c[0], "compute").?;
        const callers = idx.callersOf(compute);
        try testing.expectEqual(@as(usize, 1), callers.len);
        try testing.expectEqualStrings(c[1], idx.graph.symbols[callers[0]].name);
    }
}

// ===========================================================================
// APPENDED HARDENING TESTS (build + resolution)
// ===========================================================================

/// First reference of `sym` whose name matches, ignoring the qualifier.
fn refByName(sym: model.Symbol, name: []const u8) ?model.Reference {
    for (sym.refs) |ref| {
        if (std.mem.eql(u8, ref.name, name)) return ref;
    }
    return null;
}

/// First reference of `sym` matching both `qualifier` and `name`.
fn refByQual(sym: model.Symbol, qualifier: []const u8, name: []const u8) ?model.Reference {
    for (sym.refs) |ref| {
        if (std.mem.eql(u8, ref.qualifier, qualifier) and std.mem.eql(u8, ref.name, name)) return ref;
    }
    return null;
}

/// Count how many entries of `list` equal `needle`.
fn countStr(list: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (list) |s| if (std.mem.eql(u8, s, needle)) {
        n += 1;
    };
    return n;
}

test "underSourceRoot: a source-root component anywhere makes it true" {
    const testing = std.testing;
    // A `source_roots` component (src/lib/app/source/sources/packages/pkg) at any
    // depth flips it true — this is what keeps `frontend/src/coverage/` indexed.
    try testing.expect(underSourceRoot("src"));
    try testing.expect(underSourceRoot("frontend/src/coverage"));
    try testing.expect(underSourceRoot("a/lib/b"));
    try testing.expect(underSourceRoot("app/models"));
    try testing.expect(underSourceRoot("packages/x/target"));
    try testing.expect(underSourceRoot("some/pkg/deep"));
    try testing.expect(underSourceRoot("source/gen"));
    try testing.expect(underSourceRoot("a/sources/b"));
    // No source-root component anywhere: false (a root-level build dir, an
    // arbitrary nesting, and the empty path).
    try testing.expect(!underSourceRoot("coverage"));
    try testing.expect(!underSourceRoot("frontend/build"));
    try testing.expect(!underSourceRoot("a/b/c"));
    try testing.expect(!underSourceRoot(""));
    // A substring that isn't a whole path component must not match.
    try testing.expect(!underSourceRoot("libs/foo")); // "libs" != "lib"
    try testing.expect(!underSourceRoot("srcgen/x")); // "srcgen" != "src"
}

test "lua: require binds a module edge and a qualified cross-file call resolves" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/util.lua", .data =
        \\local M = {}
        \\function M.clamp(x)
        \\  return x
        \\end
        \\function clamp(x)
        \\  return x
        \\end
        \\return M
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.lua", .data =
        \\local util = require("lib.util")
        \\local function run()
        \\  return util.clamp(1)
        \\end
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // The Lua `require("lib.util")` binds `util` -> lib/util.lua as a module edge.
    const main_file = idx.graph.symbols[idx.lookup("run")[0]].file;
    const util_file = idx.graph.files[main_file];
    try testing.expectEqual(@as(usize, 1), idx.importsOf(main_file).len);
    const imp = idx.importsOf(main_file)[0];
    try testing.expectEqualStrings("util", imp.binding);
    try testing.expect(std.mem.endsWith(u8, idx.graph.files[imp.target].path, "lib/util.lua"));
    try testing.expect(imp.target != util_file.id);

    // `util.clamp(1)` resolves through the import to the top-level `clamp` in
    // lib/util.lua (exact, module-qualified).
    const target = qualifiedFileSym(&idx, "lib/util.lua", "clamp").?;
    const run = idx.graph.symbols[idx.lookup("run")[0]];
    const ref = refByQual(run, "util", "clamp").?;
    try testing.expectEqual(target, ref.target);
    try testing.expect(ref.exact);
}

test "js: a CommonJS require binds a module and a qualified member call resolves" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "util.js", .data =
        \\function foo() { return 1; }
        \\module.exports = { foo };
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.js", .data =
        \\const util = require('./util');
        \\function run() { return util.foo(); }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const main_file = idx.graph.symbols[idx.lookup("run")[0]].file;
    try testing.expectEqual(@as(usize, 1), idx.importsOf(main_file).len);
    try testing.expectEqualStrings("util", idx.importsOf(main_file)[0].binding);

    // `util.foo()` resolves through the require binding to util.js's foo (exact).
    const foo = idx.lookup("foo")[0];
    const run = idx.graph.symbols[idx.lookup("run")[0]];
    const ref = refByQual(run, "util", "foo").?;
    try testing.expectEqual(foo, ref.target);
    try testing.expect(ref.exact);
    try testing.expectEqual(run.id, idx.callersOf(foo)[0]);
}

test "python from-import records a module edge whose binding is empty" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/util.py", .data =
        \\def helper():
        \\    return 1
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/main.py", .data =
        \\from .util import helper
        \\def run():
        \\    return helper()
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const main_file = idx.graph.symbols[idx.lookup("run")[0]].file;
    const util_file = idx.graph.symbols[idx.lookup("helper")[0]].file;
    try testing.expectEqual(@as(usize, 1), idx.importsOf(main_file).len);
    const imp = idx.importsOf(main_file)[0];
    // A `from X import Y` contributes a module edge but no callable binding.
    try testing.expectEqual(@as(usize, 0), imp.binding.len);
    try testing.expectEqual(util_file, imp.target);
    // The bare `helper()` still resolves within the Python family.
    try testing.expectEqual(idx.lookup("run")[0], idx.callersOf(idx.lookup("helper")[0])[0]);
}

test "a zig @import of the file's own path is ignored (no self-import edge)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "self.zig", .data =
        \\const me = @import("self.zig");
        \\pub fn f() u32 {
        \\    return 1;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const file = idx.graph.symbols[idx.lookup("f")[0]].file;
    // resolveFileImports drops `target == f.id`, so a self-import yields no edge.
    try testing.expectEqual(@as(usize, 0), idx.importsOf(file).len);
}

test "chooseTarget: a bare call to a name defined in two files is a non-confident guess" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn shared() u32 {
        \\    return 1;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub fn shared() u32 {
        \\    return 2;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data =
        \\pub fn go() u32 {
        \\    return shared();
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 2), idx.lookup("shared").len);
    const go = idx.graph.symbols[idx.lookup("go")[0]];
    const ref = refByName(go, "shared").?;
    // Two equally-plausible cross-file candidates: it binds one but is not exact.
    try testing.expect(ref.target != invalid);
    try testing.expect(!ref.exact);
    // The chosen target is one of the two `shared` defs and `go` is its only
    // caller; the total caller count across both defs is exactly one.
    var total: usize = 0;
    for (idx.lookup("shared")) |sid| total += idx.callersOf(sid).len;
    try testing.expectEqual(@as(usize, 1), total);
    try testing.expectEqual(go.id, idx.callersOf(ref.target)[0]);
}

test "chooseTarget: a same-file definition wins and is exact over a same-named other-file def" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data =
        \\pub fn dup() u32 {
        \\    return 1;
        \\}
        \\pub fn caller() u32 {
        \\    return dup();
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data =
        \\pub fn dup() u32 {
        \\    return 2;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const a_dup = qualifiedFileSym(&idx, "a.zig", "dup").?;
    const b_dup = qualifiedFileSym(&idx, "b.zig", "dup").?;
    const caller = idx.graph.symbols[idx.lookup("caller")[0]];
    const ref = refByName(caller, "dup").?;
    // Same-file scores highest (>= 4) so the pick is confident/exact.
    try testing.expectEqual(a_dup, ref.target);
    try testing.expect(ref.exact);
    // The other file's identically-named def is never linked.
    try testing.expectEqual(@as(usize, 0), idx.callersOf(b_dup).len);
    try testing.expectEqual(caller.id, idx.callersOf(a_dup)[0]);
}

test "member call: a self receiver resolves exactly to a sibling method (zig)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "t.zig", .data =
        \\pub const T = struct {
        \\    pub fn first(self: *T) u32 {
        \\        return self.second();
        \\    }
        \\    pub fn second(self: *T) u32 {
        \\        return 1;
        \\    }
        \\};
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const first = qualifiedId(&idx, "T", "first").?;
    const second = qualifiedId(&idx, "T", "second").?;
    const first_sym = idx.graph.symbols[first];
    const ref = refByQual(first_sym, "self", "second").?;
    // `self.second()` resolves to the enclosing type's member, exactly.
    try testing.expectEqual(second, ref.target);
    try testing.expect(ref.exact);
    try testing.expectEqual(first, idx.callersOf(second)[0]);
}

test "member call: a this receiver resolves exactly to a sibling method (js class)" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "svc.js", .data =
        \\class Svc {
        \\  first() { return this.second(); }
        \\  second() { return 1; }
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const first = qualifiedId(&idx, "Svc", "first").?;
    const second = qualifiedId(&idx, "Svc", "second").?;
    const ref = refByQual(idx.graph.symbols[first], "this", "second").?;
    try testing.expectEqual(second, ref.target);
    try testing.expect(ref.exact);
    try testing.expectEqual(first, idx.callersOf(second)[0]);
}

test "unknown receiver: a member call is a heuristic guess, a member read stays unbound" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "m.py", .data =
        \\class Ctx:
        \\    value: int = 0
        \\    def compute(self):
        \\        return 1
        \\
        \\def build():
        \\    obj = make()
        \\    total = obj.value
        \\    return obj.compute()
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const value = qualifiedId(&idx, "Ctx", "value").?;
    const compute = qualifiedId(&idx, "Ctx", "compute").?;
    const build_sym = idx.graph.symbols[idx.lookup("build")[0]];

    // `obj.compute()` on an untyped receiver is bound to the method by the
    // dispatch heuristic, but never as an exact edge.
    const call = refByQual(build_sym, "obj", "compute").?;
    try testing.expectEqual(compute, call.target);
    try testing.expect(!call.exact);
    try testing.expectEqual(build_sym.id, idx.callersOf(compute)[0]);

    // `obj.value` is a member *read*, so it must not inflate the field's fan-in.
    try testing.expectEqual(@as(usize, 0), idx.callersOf(value).len);
}

test "heuristic method target prefers a same-file method over a free function" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\pub const T = struct {
        \\    pub fn process(self: *T) u32 {
        \\        return 1;
        \\    }
        \\};
        \\pub fn run() u32 {
        \\    return g.process();
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "other.zig", .data =
        \\pub fn process() u32 {
        \\    return 2;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const method = qualifiedId(&idx, "T", "process").?;
    const run = idx.graph.symbols[idx.lookup("run")[0]];
    const ref = refByQual(run, "g", "process").?;
    // The method (score: +2 method, +1 same-file) beats the other-file free fn.
    try testing.expectEqual(method, ref.target);
    try testing.expect(!ref.exact); // heuristic dispatch is never exact
    try testing.expectEqual(run.id, idx.callersOf(method)[0]);
}

test "a qualified call to a nonexistent member of an imported module stays unresolved" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "util.zig", .data =
        \\pub fn helper() u32 {
        \\    return 1;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data =
        \\const util = @import("util.zig");
        \\pub fn run() u32 {
        \\    return util.ghost();
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const run = idx.graph.symbols[idx.lookup("run")[0]];
    const ref = refByQual(run, "util", "ghost").?;
    // The module resolves, but it has no `ghost`, and no other file does either:
    // the heuristic fallback also finds nothing, so the edge stays external.
    try testing.expectEqual(invalid, ref.target);
    // The import edge itself is still present.
    const main_file = run.file;
    try testing.expectEqual(@as(usize, 1), idx.importsOf(main_file).len);
    // helper was never called.
    try testing.expectEqual(@as(usize, 0), idx.callersOf(idx.lookup("helper")[0]).len);
}

test "route linking: an unmatched client fetch stays external and the route has no callers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "api.py", .data =
        \\app = FastAPI()
        \\@app.get("/users")
        \\def list_users():
        \\    return []
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "client.ts", .data =
        \\function loadThing() {
        \\  return fetch('/nonexistent');
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    const loader = idx.graph.symbols[idx.lookup("loadThing")[0]];
    var seen = false;
    for (loader.refs) |ref| {
        if (ref.kind != .route_call) continue;
        // No backend route matches `/nonexistent`, so it stays unresolved.
        try testing.expectEqual(invalid, ref.target);
        try testing.expect(!ref.exact);
        seen = true;
    }
    try testing.expect(seen);
    // The real route exists but nobody calls it.
    const route = routeByName(&idx, "GET /users").?;
    try testing.expectEqual(@as(usize, 0), idx.callersOf(route).len);
}

test "skipped_dirs: a pruned vendor tree is reported once; a build/dep dir is silent" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A potentially-source dir (`vendor`) appears twice; its skip must be
    // recorded once (deduped). `node_modules` is a universally-expected skip and
    // must never be surfaced.
    try tmp.dir.createDirPath(io, "vendor");
    try tmp.dir.createDirPath(io, "deep/vendor");
    try tmp.dir.createDirPath(io, "node_modules");
    try tmp.dir.createDirPath(io, ".codeflow/artifacts");
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/a.zig", .data =
        \\pub fn vendored() u32 { return 1; }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "deep/vendor/b.zig", .data =
        \\pub fn vendored2() u32 { return 2; }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/c.zig", .data =
        \\pub fn nodedep() u32 { return 3; }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = ".codeflow/artifacts/probe.py", .data =
        \\def generated_probe(): return 3
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "real.zig", .data =
        \\pub fn realfn() u32 { return 4; }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    // Only the top-level real source is indexed; pruned trees are absent.
    try testing.expectEqual(@as(usize, 1), idx.lookup("realfn").len);
    try testing.expectEqual(@as(usize, 0), idx.lookup("vendored").len);
    try testing.expectEqual(@as(usize, 0), idx.lookup("vendored2").len);
    try testing.expectEqual(@as(usize, 0), idx.lookup("nodedep").len);
    try testing.expectEqual(@as(usize, 0), idx.lookup("generated_probe").len);

    // `vendor` is reported exactly once; generated/dependency trees are silent.
    try testing.expectEqual(@as(usize, 1), countStr(idx.skipped_dirs, "vendor"));
    try testing.expectEqual(@as(usize, 0), countStr(idx.skipped_dirs, "node_modules"));
    try testing.expectEqual(@as(usize, 0), countStr(idx.skipped_dirs, ".codeflow"));
}

test "skipped_dirs is empty when nothing potentially-source is pruned" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "only.zig", .data =
        \\pub fn only() u32 { return 1; }
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 1), idx.lookup("only").len);
    try testing.expectEqual(@as(usize, 0), idx.skipped_dirs.len);
}

test "a project with only unsupported files indexes nothing" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "just prose, no code\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data.json", .data = "{\"a\":1}\n" });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 0), idx.graph.files.len);
    try testing.expectEqual(@as(usize, 0), idx.graph.symbols.len);
    try testing.expectEqual(@as(usize, 0), idx.lookup("anything").len);
    try testing.expectEqual(@as(usize, 0), idx.skipped_dirs.len);
}

test "incremental cache: a file grown between builds is re-parsed, not served stale" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data =
        \\pub fn one() u32 {
        \\    return 1;
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    // Cold build writes the cache.
    var cold = try build(testing.allocator, io, root, true);
    try testing.expectEqual(@as(usize, 1), cold.lookup("one").len);
    try testing.expectEqual(@as(usize, 0), cold.lookup("two").len);
    cold.deinit();

    // Grow the file: the size differs, so the cached entry no longer matches its
    // stat and the file must be re-parsed (not restored from disk).
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zig", .data =
        \\pub fn one() u32 {
        \\    return 1;
        \\}
        \\pub fn two() u32 {
        \\    return 2;
        \\}
    });

    var warm = try build(testing.allocator, io, root, true);
    defer warm.deinit();
    try testing.expectEqual(@as(usize, 1), warm.lookup("one").len);
    try testing.expectEqual(@as(usize, 1), warm.lookup("two").len); // freshly parsed
}

test "no-cache builds are deterministic and agree with a cached build" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "u.zig", .data =
        \\pub fn helper(x: i32) i32 {
        \\    return x;
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "m.zig", .data =
        \\const u = @import("u.zig");
        \\pub fn run() i32 {
        \\    return u.helper(1);
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var a = try build(testing.allocator, io, root, false);
    const names_a = try dupeNames(testing.allocator, &a);
    defer freeNames(testing.allocator, names_a);
    a.deinit();

    // A second no-cache build yields an identical symbol sequence.
    var b = try build(testing.allocator, io, root, false);
    defer b.deinit();
    try testing.expectEqual(names_a.len, b.graph.symbols.len);
    for (names_a, b.graph.symbols) |name, sym| try testing.expectEqualStrings(name, sym.name);

    // And a cached build produces the same symbols too — the cache is transparent.
    var c = try build(testing.allocator, io, root, true);
    defer c.deinit();
    try testing.expectEqual(names_a.len, c.graph.symbols.len);
    for (names_a, c.graph.symbols) |name, sym| try testing.expectEqualStrings(name, sym.name);
    // The cross-module edge survives in all three.
    try testing.expectEqual(b.lookup("run")[0], b.callersOf(b.lookup("helper")[0])[0]);
    try testing.expectEqual(c.lookup("run")[0], c.callersOf(c.lookup("helper")[0])[0]);
}

test "scope-blind refs: JS object key and param do not create false caller edges" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "db.js", .data =
        \\function count() { return 0; }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "use.js", .data =
        \\function statsHandler(req, res) {
        \\    res.json({ count: size() });
        \\}
        \\function formatStatus(count) {
        \\    return count > 0;
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, root, false);
    defer idx.deinit();
    // The dead global count() must have no callers: the `{ count: ... }` object
    // key and the `count` parameter are not references to it.
    const count = qualifiedFileSym(&idx, "db.js", "count").?;
    try testing.expectEqual(@as(usize, 0), idx.callersOf(count).len);
}

test "build indexes a single file when the root path names a file, not a directory" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub fn one() u32 { return 1; }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zig", .data = "pub fn two() u32 { return 2; }" });
    var path_buf: [256]u8 = undefined;
    const file_root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/a.zig", .{tmp.sub_path});
    var idx = try build(testing.allocator, io, file_root, false);
    defer idx.deinit();
    // Only a.zig is indexed; its symbol resolves, b.zig's does not.
    try testing.expectEqual(@as(usize, 1), idx.graph.files.len);
    try testing.expectEqual(@as(usize, 1), idx.lookup("one").len);
    try testing.expectEqual(@as(usize, 0), idx.lookup("two").len);
}

test "parse health and cache snapshot survive a warm cache restore" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.js", .data =
        \\function ok() { return 1; }
        \\const bad = "never closed
        \\function hidden() { return 2; }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var cold = try build(testing.allocator, io, root, true);
    try testing.expectEqual(@as(?u32, 2), cold.graph.files[0].parse_health.desync_from);
    try testing.expectEqual(CacheRewrite.written, cold.cache_snapshot.rewrite);
    cold.deinit();

    var warm = try build(testing.allocator, io, root, true);
    defer warm.deinit();
    try testing.expectEqual(@as(u32, 1), warm.cache_snapshot.hits);
    try testing.expectEqual(CacheRewrite.current, warm.cache_snapshot.rewrite);
    try testing.expectEqual(@as(?u32, 2), warm.graph.files[0].parse_health.desync_from);
    try testing.expect(warm.graph.files[0].parse_health.desync_to >= 3);
}
