//! Backend differ: proves what the tree-sitter backend is allowed to change.
//!
//! Runs BOTH backends over the checked-in fixture trees and asserts three
//! things, because "the new parser looks better" is not evidence:
//!   1. no definition the heuristic scanner finds disappears,
//!   2. the definitions the spike measured as missing are now present, with the
//!      declared types the resolver wave needs,
//!   3. no call edge is lost, and every *newly exact* edge is one that was read
//!      against the source and adjudicated correct (listed below with its
//!      reason) — an exact edge is a promise, so a new one is a review item.
//!
//! Skipped whole when the build links no grammars (`-Dtree-sitter=none`).

const std = @import("std");
const navgraph = @import("NavGraph");

const index = navgraph.index;
const model = navgraph.model;
const backends = navgraph.backends;
const parser = navgraph.parser;
const ts_backend = navgraph.ts_backend;
const language = navgraph.language;

const testing = std.testing;

/// Fixture trees that contain python/typescript/tsx sources.
const fixture_trees = [_][]const u8{
    "testenv/py_fastapi",
    "testenv/ts_frontend",
    "testenv/fullstack",
    "testenv/parser_gaps",
};

/// Identity of a definition for differ purposes. Deliberately not the span or
/// the signature: those legitimately differ between a token scanner and a
/// grammar, while file+name+kind+line is the identity users navigate by.
const Key = struct {
    file: []const u8,
    name: []const u8,
    kind: model.SymbolKind,
    line: u32,

    fn of(idx: *const index.Index, sym: model.Symbol) Key {
        return .{
            .file = idx.graph.files[sym.file].path,
            .name = sym.name,
            .kind = sym.kind,
            .line = sym.line,
        };
    }

    fn format(self: Key, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:{d} {s} {s}", .{
            self.file, self.line, self.kind.tag(), self.name,
        }) catch "<key too long>";
    }
};

const KeySet = std.HashMapUnmanaged(Key, void, KeyContext, std.hash_map.default_max_load_percentage);

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.file);
        h.update(k.name);
        h.update(std.mem.asBytes(&k.kind));
        h.update(std.mem.asBytes(&k.line));
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.line == b.line and a.kind == b.kind and
            std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.file, b.file);
    }
};

/// Only languages a grammar is linked for can differ; everything else must be
/// byte-identical because it never leaves the heuristic scanner.
fn grammarBacked(lang: language.Language) bool {
    return ts_backend.supports(lang);
}

fn collectDefs(gpa: std.mem.Allocator, idx: *const index.Index, out: *KeySet) !void {
    for (idx.graph.symbols) |sym| {
        if (!grammarBacked(idx.graph.files[sym.file].language)) continue;
        try out.put(gpa, Key.of(idx, sym), {});
    }
}

const Pair = struct {
    heuristic: index.Index,
    tree_sitter: index.Index,

    fn open(gpa: std.mem.Allocator, tree: []const u8) !Pair {
        var h = try index.build(gpa, testing.io, tree, false, .heuristic);
        errdefer h.deinit();
        const t = try index.build(gpa, testing.io, tree, false, .tree_sitter);
        return .{ .heuristic = h, .tree_sitter = t };
    }

    fn close(self: *Pair) void {
        self.tree_sitter.deinit();
        self.heuristic.deinit();
    }
};

test "no definition the heuristic backend finds is lost" {
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    for (fixture_trees) |tree| {
        var pair = try Pair.open(gpa, tree);
        defer pair.close();

        var want: KeySet = .empty;
        defer want.deinit(gpa);
        try collectDefs(gpa, &pair.heuristic, &want);
        var got: KeySet = .empty;
        defer got.deinit(gpa);
        try collectDefs(gpa, &pair.tree_sitter, &got);

        try testing.expect(want.count() > 0);
        var missing: u32 = 0;
        var it = want.keyIterator();
        while (it.next()) |k| {
            if (got.contains(k.*)) continue;
            missing += 1;
            var buf: [256]u8 = undefined;
            std.debug.print("navgraph differ: {s} lost {s}\n", .{ tree, k.format(&buf) });
        }
        try testing.expectEqual(@as(u32, 0), missing);
        // The point of the exercise: strictly more, never fewer.
        try testing.expect(got.count() >= want.count());
    }
}

/// A definition the heuristic scanner cannot see, with the type the resolver
/// wave will consume. Every entry was measured in the spike report.
const Gain = struct {
    tree: []const u8,
    file: []const u8,
    parent: []const u8,
    name: []const u8,
    line: u32,
    declared_type: []const u8,
};

const expected_gains = [_]Gain{
    // Python `self.x = …` instance fields — the heuristic indexes none of these.
    .{ .tree = "testenv/py_fastapi", .file = "app/models.py", .parent = "User", .name = "id", .line = 14, .declared_type = "" },
    .{ .tree = "testenv/py_fastapi", .file = "app/models.py", .parent = "User", .name = "name", .line = 15, .declared_type = "" },
    .{ .tree = "testenv/py_fastapi", .file = "app/models.py", .parent = "User", .name = "email", .line = 16, .declared_type = "" },
    .{ .tree = "testenv/py_fastapi", .file = "app/services/auth_service.py", .parent = "AuthService", .name = "secret", .line = 13, .declared_type = "" },
    .{ .tree = "testenv/py_fastapi", .file = "app/services/auth_service.py", .parent = "AuthService", .name = "_issued", .line = 14, .declared_type = "dict" },
    // The two that carry a constructor type: this is the fact the resolver needs
    // to stop `self.items.get(…)` resolving to the wrong service.
    .{ .tree = "testenv/py_fastapi", .file = "app/services/order_service.py", .parent = "OrderService", .name = "items", .line = 14, .declared_type = "ItemService" },
    .{ .tree = "testenv/py_fastapi", .file = "app/services/order_service.py", .parent = "OrderService", .name = "users", .line = 15, .declared_type = "UserService" },
    // TypeScript interface members: the heuristic emits zero field symbols for
    // TS, so `interface Account { id; role; … }` indexes as an empty interface.
    .{ .tree = "testenv/ts_frontend", .file = "src/models/user.ts", .parent = "Account", .name = "id", .line = 6, .declared_type = "number" },
    .{ .tree = "testenv/ts_frontend", .file = "src/models/user.ts", .parent = "Account", .name = "role", .line = 7, .declared_type = "Role" },
    .{ .tree = "testenv/ts_frontend", .file = "src/models/user.ts", .parent = "Account", .name = "email", .line = 8, .declared_type = "string" },
    .{ .tree = "testenv/ts_frontend", .file = "src/models/user.ts", .parent = "Account", .name = "active", .line = 9, .declared_type = "boolean" },
    // A TS class field, with the constructor its initializer names.
    .{ .tree = "testenv/ts_frontend", .file = "src/store/store.ts", .parent = "Store", .name = "items", .line = 5, .declared_type = "Map" },
    // A TSX interface member, proving the tsx grammar (not the typescript one)
    // parsed the .tsx file.
    .{ .tree = "testenv/ts_frontend", .file = "src/components/PostList.tsx", .parent = "PostListProps", .name = "cursor", .line = 6, .declared_type = "string" },
};

test "the definitions the spike measured as missing are present, with their types" {
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    for (fixture_trees) |tree| {
        var pair = try Pair.open(gpa, tree);
        defer pair.close();
        for (expected_gains) |want| {
            if (!std.mem.eql(u8, want.tree, tree)) continue;
            try expectAbsent(&pair.heuristic, want);
            try expectPresent(&pair.tree_sitter, want);
        }
    }
}

fn findGain(idx: *const index.Index, want: Gain) ?model.Symbol {
    for (idx.graph.symbols) |sym| {
        if (sym.kind != .field or sym.line != want.line) continue;
        if (!std.mem.eql(u8, sym.name, want.name)) continue;
        if (!std.mem.eql(u8, idx.graph.files[sym.file].path, want.file)) continue;
        return sym;
    }
    return null;
}

fn expectAbsent(idx: *const index.Index, want: Gain) !void {
    if (findGain(idx, want) == null) return;
    std.debug.print(
        "navgraph differ: {s}:{d} {s} is NOT a heuristic gap any more — update the expectation\n",
        .{ want.file, want.line, want.name },
    );
    return error.TestUnexpectedResult;
}

fn expectPresent(idx: *const index.Index, want: Gain) !void {
    const sym = findGain(idx, want) orelse {
        std.debug.print("navgraph differ: missing expected field {s}:{d} {s}\n", .{ want.file, want.line, want.name });
        return error.TestExpectedEqual;
    };
    try testing.expect(sym.parent != model.invalid_symbol);
    try testing.expectEqualStrings(want.parent, idx.graph.symbols[sym.parent].name);
    try testing.expectEqualStrings(want.declared_type, sym.declared_type);
}

// ---------------------------------------------------------------------------
// Edges
// ---------------------------------------------------------------------------

/// An edge, keyed by both endpoints' identity rather than by symbol id (the ids
/// differ between the two builds).
const Edge = struct {
    from: Key,
    to: Key,

    fn format(self: Edge, buf: []u8) []const u8 {
        var a: [256]u8 = undefined;
        var b: [256]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}  ->  {s}", .{
            self.from.format(&a), self.to.format(&b),
        }) catch "<edge too long>";
    }
};

const EdgeSet = std.HashMapUnmanaged(Edge, void, EdgeContext, std.hash_map.default_max_load_percentage);

const EdgeContext = struct {
    pub fn hash(_: EdgeContext, e: Edge) u64 {
        const kc = KeyContext{};
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&kc.hash(e.from)));
        h.update(std.mem.asBytes(&kc.hash(e.to)));
        return h.final();
    }
    pub fn eql(_: EdgeContext, a: Edge, b: Edge) bool {
        const kc = KeyContext{};
        return kc.eql(a.from, b.from) and kc.eql(a.to, b.to);
    }
};

fn collectEdges(gpa: std.mem.Allocator, idx: *const index.Index, only_exact: bool, out: *EdgeSet) !void {
    for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            if (ref.target == model.invalid_symbol) continue;
            if (only_exact and !ref.exact) continue;
            const target = idx.graph.symbols[ref.target];
            // Restrict to edges either end of which a grammar could have moved.
            if (!grammarBacked(idx.graph.files[sym.file].language) and
                !grammarBacked(idx.graph.files[target.file].language)) continue;
            try out.put(gpa, .{ .from = Key.of(idx, sym), .to = Key.of(idx, target) }, {});
        }
    }
}

/// Newly-exact edges that were read against the fixture source and confirmed
/// correct. Anything not on this list failing the test is the intended outcome:
/// an `exact` edge is a promise to `--strict` consumers, so gaining one is a
/// deliberate, reviewed act.
const AdjudicatedExact = struct {
    tree: []const u8,
    from: []const u8,
    to: []const u8,
    why: []const u8,
};

const adjudicated_exact = [_]AdjudicatedExact{
    .{
        .tree = "testenv/ts_frontend",
        .from = "debugDump",
        .to = "size",
        // `debugDump(store: Store<T>)` calls `store.size()`. Correct: the
        // parameter's declared type is Store and `size` is a Store method. The
        // heuristic drops the binding because of the generic argument.
        .why = "typed parameter Store<T> receiver",
    },
    .{
        .tree = "testenv/fullstack",
        .from = "loadSnapshot",
        .to = "listOrders",
        .why = "heuristic span stops at the multi-line return type and never sees the body",
    },
    .{ .tree = "testenv/fullstack", .from = "loadSnapshot", .to = "listCustomers", .why = "same multi-line return type" },
    .{ .tree = "testenv/fullstack", .from = "loadSnapshot", .to = "listInventory", .why = "same multi-line return type" },
    .{ .tree = "testenv/fullstack", .from = "loadSnapshot", .to = "checkHealth", .why = "same multi-line return type" },
};

/// Edges only the heuristic backend draws, kept out of the "lost" count because
/// each was read against the source and is an artifact of a heuristic bug, not
/// a real relationship. Neither backend records references from a function's
/// *signature*; these exist only because the heuristic mis-measures the span of
/// `loadSnapshot`, whose return type spans several lines, and treats part of the
/// return type as the body.
const adjudicated_losses = [_]AdjudicatedExact{
    .{ .tree = "testenv/fullstack", .from = "loadSnapshot", .to = "Order", .why = "signature type read, only seen through a mis-measured span" },
    .{ .tree = "testenv/fullstack", .from = "loadSnapshot", .to = "Customer", .why = "same" },
    .{ .tree = "testenv/fullstack", .from = "loadSnapshot", .to = "InventoryItem", .why = "same" },
};

fn isAdjudicatedLoss(tree: []const u8, e: Edge) bool {
    for (adjudicated_losses) |a| {
        if (!std.mem.eql(u8, a.tree, tree)) continue;
        if (std.mem.eql(u8, a.from, e.from.name) and std.mem.eql(u8, a.to, e.to.name)) return true;
    }
    return false;
}

fn isAdjudicated(tree: []const u8, e: Edge) bool {
    for (adjudicated_exact) |a| {
        if (!std.mem.eql(u8, a.tree, tree)) continue;
        if (std.mem.eql(u8, a.from, e.from.name) and std.mem.eql(u8, a.to, e.to.name)) return true;
    }
    return false;
}

test "no call edge is lost and every new exact edge was adjudicated" {
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    for (fixture_trees) |tree| {
        var pair = try Pair.open(gpa, tree);
        defer pair.close();

        var h_all: EdgeSet = .empty;
        defer h_all.deinit(gpa);
        try collectEdges(gpa, &pair.heuristic, false, &h_all);
        var t_all: EdgeSet = .empty;
        defer t_all.deinit(gpa);
        try collectEdges(gpa, &pair.tree_sitter, false, &t_all);

        var lost: u32 = 0;
        var it = h_all.keyIterator();
        while (it.next()) |e| {
            if (t_all.contains(e.*) or isAdjudicatedLoss(tree, e.*)) continue;
            lost += 1;
            var buf: [560]u8 = undefined;
            std.debug.print("navgraph differ: {s} lost edge {s}\n", .{ tree, e.format(&buf) });
        }
        try testing.expectEqual(@as(u32, 0), lost);

        var h_exact: EdgeSet = .empty;
        defer h_exact.deinit(gpa);
        try collectEdges(gpa, &pair.heuristic, true, &h_exact);

        var h_defs: KeySet = .empty;
        defer h_defs.deinit(gpa);
        try collectDefs(gpa, &pair.heuristic, &h_defs);

        const unreviewed = try countUnreviewedExact(tree, &pair.tree_sitter, &h_exact, &h_defs);
        try testing.expectEqual(@as(u32, 0), unreviewed);
    }
}

/// Count exact edges the tree-sitter build has and the heuristic build does not,
/// excluding the two categories that are correct by construction:
///   * an explicitly adjudicated edge (read against the source, see above), and
///   * a reference to a *newly indexed field*, resolved through a receiver whose
///     type the resolver knows (`self.x`, or a local with a declared type). The
///     resolution path is unchanged; only the target became visible.
/// Everything else is printed and fails: gaining an `exact` edge is a promise to
/// `--strict` consumers and must be a reviewed act.
fn countUnreviewedExact(
    tree: []const u8,
    idx: *const index.Index,
    heuristic_exact: *const EdgeSet,
    heuristic_defs: *const KeySet,
) !u32 {
    var unreviewed: u32 = 0;
    for (idx.graph.symbols) |sym| {
        for (sym.refs) |ref| {
            if (!ref.exact or ref.target == model.invalid_symbol) continue;
            const target = idx.graph.symbols[ref.target];
            if (!grammarBacked(idx.graph.files[sym.file].language) and
                !grammarBacked(idx.graph.files[target.file].language)) continue;
            const e = Edge{ .from = Key.of(idx, sym), .to = Key.of(idx, target) };
            if (heuristic_exact.contains(e)) continue;
            if (isAdjudicated(tree, e)) continue;
            if (isNewFieldViaTypedReceiver(target, ref, heuristic_defs, e)) continue;
            unreviewed += 1;
            var buf: [560]u8 = undefined;
            std.debug.print("navgraph differ: {s} new UNREVIEWED exact edge {s} (reason {t})\n", .{
                tree, e.format(&buf), ref.resolution_reason,
            });
        }
    }
    return unreviewed;
}

fn isNewFieldViaTypedReceiver(
    target: model.Symbol,
    ref: model.Reference,
    heuristic_defs: *const KeySet,
    e: Edge,
) bool {
    if (target.kind != .field) return false;
    if (heuristic_defs.contains(e.to)) return false; // not a new symbol
    return ref.resolution_reason == .self_member or ref.resolution_reason == .typed_receiver;
}

// ---------------------------------------------------------------------------
// Robustness
// ---------------------------------------------------------------------------

const Hostile = struct { lang: language.Language, source: []const u8 };

test "hostile inputs never crash and an unparseable file falls back, recorded" {
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..20_000) |i| {
        var line: [64]u8 = undefined;
        try big.appendSlice(gpa, try std.fmt.bufPrint(&line, "def f{d}():\n    return {d}\n", .{ i, i }));
    }

    const cases = [_]Hostile{
        .{ .lang = .python, .source = "" },
        .{ .lang = .typescript, .source = "" },
        .{ .lang = .python, .source = "# nothing but a comment\n" },
        .{ .lang = .typescript, .source = "// nothing but a comment\n" },
        .{ .lang = .python, .source = "def broken(:\n    x = (\n" },
        .{ .lang = .typescript, .source = "class A { fn( {\n" },
        // Invalid UTF-8 in a string literal.
        .{ .lang = .python, .source = "x = \"\xff\xfe\xfa\"\n" },
        .{ .lang = .typescript, .source = "const a = \"\xff\xfe\";\n" },
        // JSX inside a .ts file: the typescript grammar cannot parse it, which
        // is exactly the ERROR-node path.
        .{ .lang = .typescript, .source = "export const X = () => <div>hi</div>;\nexport function y() { return 1; }\n" },
        .{ .lang = .python, .source = big.items },
    };

    var reg = backends.Registry.init(gpa);
    defer reg.deinit();

    for (cases) |case| {
        if (!ts_backend.supports(case.lang)) continue;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var out: std.ArrayList(parser.ParsedSymbol) = .empty;
        defer out.deinit(gpa);
        const health = try backends.parse(
            &reg,
            gpa,
            arena.allocator(),
            case.source,
            case.lang,
            .tree_sitter,
            &out,
        );
        // A fallback is always recorded against the heuristic backend, never
        // presented as a tree-sitter parse.
        if (health.tree_sitter_fallback) try testing.expectEqual(model.Backend.heuristic, health.backend);
        for (out.items) |sym| {
            try testing.expect(sym.span_start <= sym.sig_end);
            try testing.expect(sym.sig_end <= sym.span_end);
            try testing.expect(sym.span_end <= case.source.len);
            try testing.expect(sym.line >= 1);
        }
    }
}

test "JSX in a .ts file falls back to the heuristic scanner, recorded in ParseHealth" {
    if (!ts_backend.supports(.typescript)) return error.SkipZigTest;
    const gpa = testing.allocator;
    var reg = backends.Registry.init(gpa);
    defer reg.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(parser.ParsedSymbol) = .empty;
    defer out.deinit(gpa);

    const health = try backends.parse(
        &reg,
        gpa,
        arena.allocator(),
        "export const X = () => <div>hi</div>;\n",
        .typescript,
        .tree_sitter,
        &out,
    );
    try testing.expect(health.tree_sitter_fallback);
    try testing.expectEqual(model.Backend.heuristic, health.backend);
    try testing.expect(out.items.len > 0);
}

test "a clean parse is recorded as the tree-sitter backend" {
    if (!ts_backend.supports(.python)) return error.SkipZigTest;
    const gpa = testing.allocator;
    var reg = backends.Registry.init(gpa);
    defer reg.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(parser.ParsedSymbol) = .empty;
    defer out.deinit(gpa);

    const health = try backends.parse(
        &reg,
        gpa,
        arena.allocator(),
        "class C:\n    def __init__(self):\n        self.x = C()\n",
        .python,
        .tree_sitter,
        &out,
    );
    try testing.expectEqual(model.Backend.tree_sitter, health.backend);
    try testing.expect(!health.tree_sitter_fallback);

    var found = false;
    for (out.items) |sym| {
        if (sym.kind != .field or !std.mem.eql(u8, sym.name, "x")) continue;
        found = true;
        try testing.expectEqualStrings("C", sym.declared_type);
        // The span ends at the `=`, never swallowing the initializer.
        try testing.expectEqualStrings("self.x", "class C:\n    def __init__(self):\n        self.x = C()\n"[sym.span_start + 8 .. sym.span_end]);
    }
    try testing.expect(found);
}

test "auto keeps every language on the heuristic backend" {
    const gpa = testing.allocator;
    var reg = backends.Registry.init(gpa);
    defer reg.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var out: std.ArrayList(parser.ParsedSymbol) = .empty;
    defer out.deinit(gpa);

    const health = try backends.parse(
        &reg,
        gpa,
        arena.allocator(),
        "def f():\n    return 1\n",
        .python,
        .auto,
        &out,
    );
    try testing.expectEqual(model.Backend.heuristic, health.backend);
    try testing.expect(!health.tree_sitter_fallback);
}
