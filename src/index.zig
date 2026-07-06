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

const SymbolId = model.SymbolId;
const FileId = model.FileId;
const invalid = model.invalid_symbol;
const max_file_bytes: usize = 8 * 1024 * 1024;

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    graph: model.Graph,
    by_name: std.StringHashMapUnmanaged([]SymbolId),
    callers: [][]SymbolId,
    root: []const u8,

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
};

const Builder = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    files: std.ArrayList(model.SourceFile),
    symbols: std.ArrayList(model.Symbol),
};

/// Build an index rooted at `root_path` (relative to cwd or absolute).
pub fn build(gpa: std.mem.Allocator, io: std.Io, root_path: []const u8) !Index {
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
    };
    defer b.files.deinit(gpa);
    defer b.symbols.deinit(gpa);

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
        .root = try arena.dupe(u8, root_path),
    };
    try buildNameIndex(&idx);
    resolveReferences(&idx);
    try buildCallers(&idx);
    return idx;
}

const ignored_dirs = std.StaticStringMap(void).initComptime(.{
    .{".git"},        .{"node_modules"}, .{"zig-out"},   .{".zig-cache"},
    .{"zig-cache"},   .{"__pycache__"},  .{".venv"},     .{"venv"},
    .{"dist"},        .{"build"},        .{".next"},     .{"target"},
    .{".mypy_cache"}, .{".pytest_cache"}, .{"vendor"},   .{".advantage"},
    .{".nvime"},      .{".idea"},        .{".vscode"},   .{"coverage"},
});

fn collectDir(b: *Builder, dir: std.Io.Dir, path_buf: *std.ArrayList(u8)) anyerror!void {
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

fn enterDir(b: *Builder, parent: std.Io.Dir, name: []const u8, path_buf: *std.ArrayList(u8)) !void {
    if (ignored_dirs.has(name)) return;
    var sub = parent.openDir(b.io, name, .{ .iterate = true }) catch return;
    defer sub.close(b.io);
    try collectDir(b, sub, path_buf);
}

fn maybeAddFile(b: *Builder, rel_path: []const u8) !void {
    const lang = language.detect(rel_path);
    if (lang == .unknown) return;
    const text = b.root_dir.readFileAlloc(b.io, rel_path, b.arena, .limited(max_file_bytes)) catch return;
    std.debug.assert(text.len <= std.math.maxInt(u32));

    const sym_start: u32 = @intCast(b.symbols.items.len);
    const file_id: FileId = @intCast(b.files.items.len);
    try parseFileInto(b, text, lang, file_id, sym_start);
    const sym_end: u32 = @intCast(b.symbols.items.len);
    try b.files.append(b.gpa, .{
        .id = file_id,
        .path = try b.arena.dupe(u8, rel_path),
        .language = lang,
        .text = text,
        .sym_start = sym_start,
        .sym_end = sym_end,
    });
}

fn parseFileInto(b: *Builder, text: []const u8, lang: language.Language, file_id: FileId, base: u32) !void {
    var parsed: std.ArrayList(parser.ParsedSymbol) = .empty;
    defer parsed.deinit(b.gpa);
    parser.parse(b.gpa, b.arena, text, lang, &parsed) catch return;

    for (parsed.items, 0..) |p, local| {
        const id: SymbolId = base + @as(u32, @intCast(local));
        const parent: SymbolId = if (p.parent_local) |pl| base + pl else invalid;
        try b.symbols.append(b.gpa, .{
            .id = id,
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
            .refs = p.refs,
            .bindings = p.bindings,
        });
    }
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
    if (ref.qualifier.len != 0) {
        const type_name = receiverType(idx, from, ref.qualifier) orelse return;
        ref.target = memberOf(idx, type_name, ref.name);
        ref.exact = ref.target != invalid;
        return;
    }
    const candidates = idx.by_name.get(ref.name) orelse return;
    const choice = chooseTarget(idx, from, candidates);
    ref.target = choice.id;
    ref.exact = choice.confident;
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
fn chooseTarget(idx: *const Index, from: model.Symbol, candidates: []const SymbolId) Choice {
    std.debug.assert(candidates.len > 0);
    const from_lang = idx.graph.files[from.file].language.family();
    var best: SymbolId = invalid;
    var best_score: i32 = -1;
    var eligible: u32 = 0;
    for (candidates) |cid| {
        if (cid == from.id) continue;
        eligible += 1;
        const cand = idx.graph.symbols[cid];
        var score: i32 = 0;
        if (cand.file == from.file) score += 4;
        if (idx.graph.files[cand.file].language.family() == from_lang) score += 2;
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

test "member calls resolve by receiver type, not global name" {
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
    var idx = try build(testing.allocator, io, root);
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
            // Unknown receiver type: left external, not guessed globally.
            try testing.expectEqual(invalid, ref.target);
        }
    }
    try testing.expect(checked);
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

    var idx = try build(testing.allocator, io, root);
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
