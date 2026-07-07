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

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    graph: model.Graph,
    by_name: std.StringHashMapUnmanaged([]SymbolId),
    callers: [][]SymbolId,
    /// Per-file resolved imports (arena-owned), indexed by `FileId`.
    file_imports: [][]const FileImport,
    root: []const u8,
    /// Unique names of directories the walker pruned (build/vendor/fixture dirs
    /// from `ignored_dirs`). Surfaced on empty results so a skipped subtree reads
    /// as "not indexed" rather than "absent". Arena-owned.
    skipped_dirs: []const []const u8 = &.{},

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

    var root_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
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
    try collectDir(&b, root_dir, &path_buf);

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
        .skipped_dirs = try arena.dupe([]const u8, b.skipped.items),
    };
    try buildNameIndex(&idx);
    try buildImportTable(&idx);
    resolveReferences(&idx);
    linkRoutes(&idx);
    try buildCallers(&idx);
    if (use_cache and cacheStale(&b)) persistCache(&b, &idx);
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
fn persistCache(b: *const Builder, idx: *const Index) void {
    std.debug.assert(idx.graph.files.len == b.stats.items.len);
    cache.write(b.gpa, b.io, b.root_dir, idx.graph.files, b.stats.items, idx.graph.symbols) catch |err| {
        std.debug.print("navgraph: cache write skipped: {s}\n", .{@errorName(err)});
    };
}

const ignored_dirs = std.StaticStringMap(void).initComptime(.{
    .{".git"},        .{"node_modules"}, .{"zig-out"},   .{".zig-cache"},
    .{"zig-cache"},   .{"__pycache__"},  .{".venv"},     .{"venv"},
    .{"dist"},        .{"build"},        .{".next"},     .{"target"},
    .{".mypy_cache"}, .{".pytest_cache"}, .{"vendor"},   .{".advantage"},
    .{".nvime"},      .{".idea"},        .{".vscode"},   .{"coverage"},
    .{".navgraph"},   .{"testenv"},
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

/// Load `dir`'s `.gitignore` (if any) into the matcher, tagged with `base` (the
/// directory's path relative to the root). Rule text and base are duped into the
/// arena so they outlive this call. Absent/unreadable files are simply skipped.
fn loadGitignore(b: *Builder, dir: std.Io.Dir, base: []const u8) !void {
    const text = dir.readFileAlloc(b.io, ".gitignore", b.arena, .limited(max_gitignore_bytes)) catch return;
    try b.ignore.addFile(try b.arena.dupe(u8, base), text);
}

fn enterDir(b: *Builder, parent: std.Io.Dir, name: []const u8, path_buf: *std.ArrayList(u8)) !void {
    if (ignored_dirs.has(name)) {
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
    .{"src"},    .{"lib"},      .{"app"}, .{"source"},
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
/// (e.g. `vendor`, `testenv`) can plausibly hold real source, so its skip is
/// reported to avoid the silent-failure trap.
const silent_skip = std.StaticStringMap(void).initComptime(.{
    .{".git"},        .{"node_modules"}, .{"zig-out"},    .{".zig-cache"},
    .{"zig-cache"},   .{"__pycache__"},  .{".venv"},      .{"venv"},
    .{"dist"},        .{"build"},        .{".next"},      .{"target"},
    .{".mypy_cache"}, .{".pytest_cache"}, .{".idea"},     .{".vscode"},
    .{"coverage"},    .{".navgraph"},    .{".advantage"}, .{".nvime"},
});

/// Record a pruned, potentially-source directory's name once (deduped) for the
/// skipped-dirs note. Silent (build/VCS/cache) skips are not recorded.
fn noteSkipped(b: *Builder, name: []const u8) !void {
    if (silent_skip.has(name)) return;
    for (b.skipped.items) |s| if (std.mem.eql(u8, s, name)) return;
    try b.skipped.append(b.gpa, try b.arena.dupe(u8, name));
}

fn maybeAddFile(b: *Builder, rel_path: []const u8) !void {
    const lang = language.detect(rel_path);
    if (lang == .unknown) return;
    if (b.ignore.isIgnored(rel_path, false)) return;
    const stat = statOf(b, rel_path) orelse return;

    if (b.store) |*s| {
        if (s.restore(b.arena, rel_path, stat)) |hit| {
            std.debug.assert(hit.text.len == stat.size);
            try appendFile(b, rel_path, lang, hit.text, hit.symbols, stat);
            b.cache_hits += 1;
            return;
        }
    }
    const text = b.root_dir.readFileAlloc(b.io, rel_path, b.arena, .limited(max_file_bytes)) catch return;
    std.debug.assert(text.len <= std.math.maxInt(u32));
    const parsed = try parseFile(b, text, lang);
    try appendFile(b, rel_path, lang, text, parsed, stat);
}

/// (mtime, size) of `rel_path`, or null when the file cannot be stat'd (e.g. it
/// vanished between directory iteration and here).
fn statOf(b: *Builder, rel_path: []const u8) ?cache.FileStat {
    const st = b.root_dir.statFile(b.io, rel_path, .{}) catch return null;
    return .{ .mtime_ns = st.mtime.nanoseconds, .ctime_ns = st.ctime.nanoseconds, .size = st.size };
}

fn parseFile(b: *Builder, text: []const u8, lang: language.Language) ![]parser.ParsedSymbol {
    var parsed: std.ArrayList(parser.ParsedSymbol) = .empty;
    defer parsed.deinit(b.gpa);
    try parser.parse(b.gpa, b.arena, text, lang, &parsed);
    return b.arena.dupe(parser.ParsedSymbol, parsed.items);
}

/// Assign global ids to `parsed`, append its symbols and the owning `SourceFile`
/// (plus its cache stat). Shared by the fresh-parse and cache-restore paths.
fn appendFile(
    b: *Builder,
    rel_path: []const u8,
    lang: language.Language,
    text: []const u8,
    parsed: []const parser.ParsedSymbol,
    stat: cache.FileStat,
) !void {
    std.debug.assert(text.len <= std.math.maxInt(u32));
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
        .sym_start = base,
        .sym_end = @intCast(b.symbols.items.len),
    });
    try b.stats.append(b.gpa, stat);
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
    if (receiverType(idx, from, ref.qualifier)) |type_name| {
        ref.target = memberOf(idx, type_name, ref.name);
        if (ref.target != invalid) {
            ref.exact = true;
            return;
        }
        // Known receiver but no such member here (an inherited/mixin method, or
        // an external type): fall through to the heuristic call match below.
    } else if (importTarget(idx, from.file, ref.qualifier)) |file_id| {
        ref.target = topLevelIn(idx, file_id, ref.name);
        if (ref.target != invalid) {
            ref.exact = true;
            return;
        }
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
    for (candidates) |cid| {
        if (cid == from.id) continue;
        const cand = idx.graph.symbols[cid];
        if (cand.kind != .function and cand.kind != .method) continue;
        if (idx.graph.files[cand.file].language.family() != from_lang) continue;
        var score: i32 = 0;
        if (cand.kind == .method) score += 2; // `recv.x()` most likely hits a method
        if (cand.file == from.file) score += 1;
        if (score > best_score) {
            best_score = score;
            best = cid;
        }
    }
    return best;
}

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

fn matchRoute(idx: *const Index, client_key: []const u8) SymbolId {
    const c = api.splitKey(client_key) orelse return invalid;
    for (idx.graph.symbols) |rsym| {
        if (rsym.kind != .route) continue;
        const r = api.splitKey(rsym.name) orelse continue;
        if (api.methodsMatch(r.method, c.method) and api.pathsMatch(r.path, c.path)) return rsym.id;
    }
    return invalid;
}

/// The type name a receiver identifier refers to inside `from`'s body: the
/// enclosing type for self/this, otherwise a local `var -> type` binding.
fn receiverType(idx: *const Index, from: model.Symbol, qualifier: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, qualifier, "self") or std.mem.eql(u8, qualifier, "this")) {
        if (from.parent == invalid) return null;
        return idx.graph.symbols[from.parent].name;
    }
    for (from.bindings) |b| {
        if (std.mem.eql(u8, b.name, qualifier)) return b.type_name;
    }
    return null;
}

/// A member (method/field/const) named `name` whose parent type is `type_name`.
fn memberOf(idx: *const Index, type_name: []const u8, name: []const u8) SymbolId {
    const candidates = idx.by_name.get(name) orelse return invalid;
    for (candidates) |cid| {
        const cand = idx.graph.symbols[cid];
        if (cand.parent == invalid) continue;
        if (std.mem.eql(u8, idx.graph.symbols[cand.parent].name, type_name)) return cid;
    }
    return invalid;
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
