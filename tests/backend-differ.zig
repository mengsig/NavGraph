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

// ---------------------------------------------------------------------------
// Receiver chain heads
// ---------------------------------------------------------------------------

fn refByQual(sym: model.Symbol, qualifier: []const u8, name: []const u8) ?model.Reference {
    for (sym.refs) |ref| {
        if (std.mem.eql(u8, ref.qualifier, qualifier) and std.mem.eql(u8, ref.name, name)) return ref;
    }
    return null;
}

fn memberSymbolIn(idx: *const index.Index, file: []const u8, parent: []const u8, child: []const u8) ?model.Symbol {
    for (idx.graph.symbols) |sym| {
        if (sym.parent == model.invalid_symbol) continue;
        if (!std.mem.eql(u8, sym.name, child)) continue;
        if (!std.mem.eql(u8, idx.graph.files[sym.file].path, file)) continue;
        if (std.mem.eql(u8, idx.graph.symbols[sym.parent].name, parent)) return sym;
    }
    return null;
}

const ChainCase = struct {
    /// Method holding the `store.fetch()` call site.
    caller: []const u8,
    /// `receiver_root` the reference must carry: "self" is spelled per language.
    root: []const u8,
};

const chain_cases = [_]ChainCase{
    // `self.store` / `this.store`: the enclosing instance heads the chain, so
    // the resolver may read Api's own field table.
    .{ .caller = "direct", .root = "self" },
    // Another object heads the chain. Losing this root is the mis-resolution
    // PR #7 landed to kill: Api's field table would answer for Holder's field.
    .{ .caller = "cross", .root = "o" },
    // A bare qualifier heads its own chain, so no field table may answer.
    .{ .caller = "bare", .root = "" },
};

/// Assert the three chain shapes carry the chain head the resolver reads, and
/// that none of them is confidently resolved. Container field tables are Go-only
/// today (`collectGoFieldBindings`), so a TS/Python chain cannot yet produce an
/// exact edge — the roots are what must be right when it can.
fn expectChainCases(idx: *const index.Index, file: []const u8, self_word: []const u8) !void {
    for (chain_cases) |case| {
        const caller = memberSymbolIn(idx, file, "Api", case.caller) orelse {
            std.debug.print("navgraph differ: no Api.{s} in {s}\n", .{ case.caller, file });
            return error.TestExpectedEqual;
        };
        const ref = refByQual(caller, "store", "fetch") orelse {
            std.debug.print("navgraph differ: {s} Api.{s} has no store.fetch reference\n", .{ file, case.caller });
            return error.TestExpectedEqual;
        };
        const want_root = if (std.mem.eql(u8, case.root, "self")) self_word else case.root;
        testing.expectEqualStrings(want_root, ref.receiver_root) catch |err| {
            std.debug.print("navgraph differ: {s} Api.{s} chain head\n", .{ file, case.caller });
            return err;
        };
        try testing.expect(!ref.exact);
    }
}

test "the tree-sitter backend records the receiver chain head the resolver needs" {
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\class Store:
        \\    def fetch(self):
        \\        return 1
        \\
        \\class Cache:
        \\    def fetch(self):
        \\        return 2
        \\
        \\class Holder:
        \\    def __init__(self):
        \\        self.store: Store = Store()
        \\
        \\class Api:
        \\    def __init__(self):
        \\        self.store: Cache = Cache()
        \\
        \\    def direct(self):
        \\        return self.store.fetch()
        \\
        \\    def cross(self, o: Holder):
        \\        return o.store.fetch()
        \\
        \\    def bare(self):
        \\        return store.fetch()
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.ts", .data =
        \\export class Store {
        \\  fetch(): number {
        \\    return 1;
        \\  }
        \\}
        \\
        \\export class Cache {
        \\  fetch(): number {
        \\    return 2;
        \\  }
        \\}
        \\
        \\export class Holder {
        \\  store: Store = new Store();
        \\}
        \\
        \\export class Api {
        \\  store: Cache = new Cache();
        \\
        \\  direct(): number {
        \\    return this.store.fetch();
        \\  }
        \\
        \\  cross(o: Holder): number {
        \\    return o.store.fetch();
        \\  }
        \\
        \\  bare(): number {
        \\    return store.fetch();
        \\  }
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var ts_idx = try index.build(testing.allocator, io, root, false, .tree_sitter);
    defer ts_idx.deinit();
    var heuristic = try index.build(testing.allocator, io, root, false, .heuristic);
    defer heuristic.deinit();
    for ([_]*const index.Index{ &ts_idx, &heuristic }) |idx| {
        try expectChainCases(idx, "app.py", "self");
        try expectChainCases(idx, "app.ts", "this");
    }
}

test "no reference loses its chain head on the fixture trees" {
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    var compared: u32 = 0;
    var mismatched: u32 = 0;
    for (fixture_trees) |tree| {
        var pair = try Pair.open(gpa, tree);
        defer pair.close();
        for (pair.heuristic.graph.symbols) |sym| {
            if (!grammarBacked(pair.heuristic.graph.files[sym.file].language)) continue;
            const twin = memberOrTopLevel(&pair.tree_sitter, &pair.heuristic, sym) orelse continue;
            for (sym.refs) |ref| {
                if (ref.receiver_root.len == 0) continue;
                const other = refByQual(twin, ref.qualifier, ref.name) orelse continue;
                compared += 1;
                if (std.mem.eql(u8, other.receiver_root, ref.receiver_root)) continue;
                mismatched += 1;
                std.debug.print(
                    "navgraph differ: {s} {s}.{s}.{s} chain head \"{s}\" -> \"{s}\"\n",
                    .{ tree, sym.name, ref.qualifier, ref.name, ref.receiver_root, other.receiver_root },
                );
            }
        }
    }
    try testing.expectEqual(@as(u32, 0), mismatched);
    // A silent zero would make the assertion above vacuous.
    try testing.expect(compared > 0);
}

/// The tree-sitter build's counterpart of a heuristic symbol, matched on the
/// identity users navigate by (file + name + line); symbol ids differ per build.
fn memberOrTopLevel(other: *const index.Index, from: *const index.Index, sym: model.Symbol) ?model.Symbol {
    const path = from.graph.files[sym.file].path;
    for (other.graph.symbols) |cand| {
        if (cand.line != sym.line or !std.mem.eql(u8, cand.name, sym.name)) continue;
        if (!std.mem.eql(u8, other.graph.files[cand.file].path, path)) continue;
        return cand;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Cache identity
// ---------------------------------------------------------------------------

fn symbolCount(gpa: std.mem.Allocator, root: []const u8, use_cache: bool, choice: backends.Choice) !usize {
    var idx = try index.build(gpa, testing.io, root, use_cache, choice);
    defer idx.deinit();
    return idx.graph.symbols.len;
}

test "a warm cache never serves the other backend's symbols" {
    // F1. `--backend` is a flag whose entire job is to pick the backend; before
    // this the on-disk cache was keyed on the source alone, so whichever backend
    // ran first answered for every later run on the default (cache-on) path.
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.ts", .data =
        \\export class Store {
        \\  private items: Map<string, number> = new Map();
        \\
        \\  size(): number {
        \\    return this.items.size;
        \\  }
        \\}
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const cold_heuristic = try symbolCount(gpa, root, false, .heuristic);
    const cold_tree_sitter = try symbolCount(gpa, root, false, .tree_sitter);
    // The fixture must actually distinguish the backends, or the test is empty.
    try testing.expect(cold_heuristic != cold_tree_sitter);

    // Heuristic first, then tree-sitter over the same cache.
    try testing.expectEqual(cold_heuristic, try symbolCount(gpa, root, true, .heuristic));
    try testing.expectEqual(cold_tree_sitter, try symbolCount(gpa, root, true, .tree_sitter));
    // …and back, so the rewritten cache does not trap the other direction.
    try testing.expectEqual(cold_heuristic, try symbolCount(gpa, root, true, .heuristic));
}

test "a cache entry may only answer for the backend that produced it" {
    const ts: model.ParseHealth = .{ .backend = .tree_sitter };
    const heur: model.ParseHealth = .{ .backend = .heuristic };
    // A file the grammar could not parse cleanly was re-parsed heuristically on
    // purpose: that entry is right for tree-sitter and wrong for heuristic.
    const fell_back: model.ParseHealth = .{ .backend = .heuristic, .tree_sitter_fallback = true };

    try testing.expect(backends.cacheEntryUsable(.python, .heuristic, heur));
    try testing.expect(!backends.cacheEntryUsable(.python, .heuristic, ts));
    try testing.expect(!backends.cacheEntryUsable(.python, .heuristic, fell_back));

    if (!ts_backend.any_grammar) return;
    try testing.expect(backends.cacheEntryUsable(.python, .tree_sitter, ts));
    try testing.expect(backends.cacheEntryUsable(.python, .tree_sitter, fell_back));
    try testing.expect(!backends.cacheEntryUsable(.python, .tree_sitter, heur));
    // A language no grammar covers stays on the heuristic scanner under every
    // choice, so its heuristic entry is the only usable one.
    try testing.expect(backends.cacheEntryUsable(.go, .tree_sitter, heur));
    try testing.expect(!backends.cacheEntryUsable(.go, .tree_sitter, ts));
}

// ---------------------------------------------------------------------------
// Visibility
// ---------------------------------------------------------------------------

test "exportedness agrees with the heuristic backend for every shared symbol" {
    // F2. `Key` deliberately excludes `exported`, so nothing else in this file
    // notices when the two backends disagree about what is public API — and
    // `--visibility`, `unused --no-public` and every JSON payload read it.
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    var compared: u32 = 0;
    var mismatched: u32 = 0;
    for (fixture_trees) |tree| {
        var pair = try Pair.open(gpa, tree);
        defer pair.close();
        for (pair.heuristic.graph.symbols) |sym| {
            if (!grammarBacked(pair.heuristic.graph.files[sym.file].language)) continue;
            const twin = memberOrTopLevel(&pair.tree_sitter, &pair.heuristic, sym) orelse continue;
            compared += 1;
            if (twin.exported == sym.exported) continue;
            mismatched += 1;
            std.debug.print("navgraph differ: {s} {s}:{d} {s} exported {} -> {}\n", .{
                tree, pair.heuristic.graph.files[sym.file].path, sym.line, sym.name, sym.exported, twin.exported,
            });
        }
    }
    try testing.expectEqual(@as(u32, 0), mismatched);
    try testing.expect(compared > 0);
}

// ---------------------------------------------------------------------------
// Member identity
// ---------------------------------------------------------------------------

fn countMembers(idx: *const index.Index, parent: []const u8, name: []const u8) u32 {
    var n: u32 = 0;
    for (idx.graph.symbols) |sym| {
        if (!std.mem.eql(u8, sym.name, name)) continue;
        if (parent.len == 0) {
            if (sym.parent == model.invalid_symbol) n += 1;
            continue;
        }
        if (sym.parent == model.invalid_symbol) continue;
        if (std.mem.eql(u8, idx.graph.symbols[sym.parent].name, parent)) n += 1;
    }
    return n;
}

fn kindOf(idx: *const index.Index, name: []const u8) ?model.SymbolKind {
    for (idx.graph.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, name)) return sym.kind;
    }
    return null;
}

test "one symbol per member, and no definition lost on shapes the fixtures lack" {
    // F3/F4/F6/F7. The fixture trees contain none of these shapes, so the
    // "no definition lost" test above passes over them vacuously.
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data =
        \\export class Store {
        \\  #secret = 1;
        \\  private cache: Map<string, number>;
        \\  total = 0;
        \\
        \\  constructor(seed: number) {
        \\    this.cache = new Map();
        \\    this.total = seed;
        \\    this.extra = seed * 2;
        \\  }
        \\
        \\  get size(): number {
        \\    return this.total;
        \\  }
        \\
        \\  set size(v: number) {
        \\    this.total = v;
        \\  }
        \\}
        \\
        \\export function overload(a: string): string;
        \\export function overload(a: number): number;
        \\export function overload(a: any): any {
        \\  return a;
        \\}
        \\
        \\export const arrowFn = (a: number) => a + 1;
        \\export const exprFn = function (a: number) { return a; };
        \\export const genHelper = function* () { yield 1; };
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.py", .data =
        \\class Repo:
        \\    def __init__(self, url):
        \\        self.url = url
        \\
        \\    @property
        \\    def host(self):
        \\        return self.url
        \\
        \\    @host.setter
        \\    def host(self, value):
        \\        self.url = value
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var heuristic = try index.build(gpa, io, root, false, .heuristic);
    defer heuristic.deinit();
    var ts = try index.build(gpa, io, root, false, .tree_sitter);
    defer ts.deinit();

    // The differ's core guarantee, on shapes the fixture trees do not contain.
    var h_defs: KeySet = .empty;
    defer h_defs.deinit(gpa);
    try collectDefs(gpa, &heuristic, &h_defs);
    var t_defs: KeySet = .empty;
    defer t_defs.deinit(gpa);
    try collectDefs(gpa, &ts, &t_defs);
    var lost: u32 = 0;
    var it = h_defs.keyIterator();
    while (it.next()) |k| {
        if (t_defs.contains(k.*)) continue;
        lost += 1;
        var buf: [280]u8 = undefined;
        std.debug.print("navgraph differ: lost {s}\n", .{k.format(&buf)});
    }
    try testing.expectEqual(@as(u32, 0), lost);

    // F3/F7: fields the heuristic indexes for neither language.
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "Store", "extra"));
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "Store", "#secret"));

    // F4: a member declared and then assigned on `this`/`self` is one field, and
    // an overload signature is not a second function.
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "Store", "cache"));
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "Store", "total"));
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "Repo", "url"));
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "", "overload"));
    // A get/set pair is two real members; both backends keep both.
    try testing.expectEqual(@as(u32, 2), countMembers(&ts, "Store", "size"));
    try testing.expectEqual(countMembers(&heuristic, "Store", "size"), countMembers(&ts, "Store", "size"));
    try testing.expectEqual(@as(u32, 2), countMembers(&ts, "Repo", "host"));

    // F6: a function-valued binding keeps the kind the heuristic gives it.
    for ([_][]const u8{ "arrowFn", "exprFn", "genHelper" }) |name| {
        try testing.expectEqual(kindOf(&heuristic, name), kindOf(&ts, name));
    }
    try testing.expectEqual(model.SymbolKind.function, kindOf(&ts, "arrowFn").?);
    try testing.expectEqual(model.SymbolKind.variable, kindOf(&ts, "genHelper").?);
}

/// The symbol named `name` whose parent is named `parent` (`""` for
/// parentless), distinct from `symbolNamed`, which cannot disambiguate a name
/// repeated under different parents (`save` below appears three times).
fn symbolIn(idx: *const index.Index, parent: []const u8, name: []const u8) ?model.Symbol {
    for (idx.graph.symbols) |sym| {
        if (!std.mem.eql(u8, sym.name, name)) continue;
        if (std.mem.eql(u8, parentName(idx, sym), parent)) return sym;
    }
    return null;
}

test "export does not reach through an interface or object-literal body either" {
    // F2/F3/F6 (round 2). `isMemberList` stopped the `export`-inheritance walk
    // at class/type-alias/enum bodies but not at an interface body, so
    // `export interface IFace { a; m() {} }` reported `a`/`m` as exported while
    // the equivalent `export type TAlias = { c }` reported `c` as not — one
    // rule, two answers for the same shape. `object` (an object literal) had
    // the same gap, and additionally left its methods parentless, so
    // `export const handlers = { save() {} }` yielded a module-scope, exported
    // `save` that collided with an unrelated top-level `function save() {}`.
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "e.ts", .data =
        \\export const handlers = { save(x: number) { return x; }, load() { return 0; } };
        \\export class Real { save(x: number) { return x; } }
        \\function save(n: number) { return n; }
        \\
        \\export interface IFace { a: number; m(): void; }
        \\interface Priv { b: number; n(): void; }
        \\export type TAlias = { c: number };
        \\export enum E { X }
        \\export class C { d = 1; p(): void {} }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var ts = try index.build(gpa, io, root, false, .tree_sitter);
    defer ts.deinit();

    // The object literal's methods are parented to the binding, not left
    // dangling at module scope — the fix that closes the false collision.
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "handlers", "save"));
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "handlers", "load"));
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "Real", "save"));
    // The module-private function is the only parentless `save` left, so
    // `collections`'s default (parentless-only) collision scan sees one `save`
    // per scope rather than a name shared across scopes.
    try testing.expectEqual(@as(u32, 1), countMembers(&ts, "", "save"));

    // Every member-list shape agrees: `export` on the container does not mark
    // the member. Interface members previously disagreed (reported `true`).
    const members = [_]struct { parent: []const u8, name: []const u8 }{
        .{ .parent = "handlers", .name = "save" },
        .{ .parent = "handlers", .name = "load" },
        .{ .parent = "IFace", .name = "a" },
        .{ .parent = "IFace", .name = "m" },
        .{ .parent = "TAlias", .name = "c" },
        .{ .parent = "E", .name = "X" },
        .{ .parent = "C", .name = "d" },
        .{ .parent = "C", .name = "p" },
    };
    for (members) |m| {
        const sym = symbolIn(&ts, m.parent, m.name) orelse {
            std.debug.print("missing {s}.{s}\n", .{ m.parent, m.name });
            return error.TestUnexpectedResult;
        };
        try testing.expect(!sym.exported);
    }
    // A non-exported interface's members stay non-exported too (no export
    // anywhere on the ancestor chain).
    try testing.expect(!(symbolIn(&ts, "Priv", "b") orelse return error.TestUnexpectedResult).exported);
    try testing.expect(!(symbolIn(&ts, "Priv", "n") orelse return error.TestUnexpectedResult).exported);
    // The containers themselves still export normally.
    try testing.expect((symbolIn(&ts, "", "IFace") orelse return error.TestUnexpectedResult).exported);
    try testing.expect((symbolIn(&ts, "", "TAlias") orelse return error.TestUnexpectedResult).exported);
    try testing.expect((symbolIn(&ts, "", "E") orelse return error.TestUnexpectedResult).exported);
    try testing.expect((symbolIn(&ts, "", "C") orelse return error.TestUnexpectedResult).exported);

    // `collisions`'s default (parentless-only) scan sees no group at all: the
    // one remaining `save` name-collision candidate is a single symbol.
    const opts = navgraph.query.Options{};
    const ids = try navgraph.query.collectCollisionSymbols(&ts, "", opts);
    defer gpa.free(ids);
    var groups: u32 = 0;
    var i: usize = 0;
    while (i < ids.len) {
        var end = i + 1;
        const name = ts.graph.symbols[ids[i]].name;
        while (end < ids.len and std.mem.eql(u8, ts.graph.symbols[ids[end]].name, name)) end += 1;
        if (end - i > 1) groups += 1;
        i = end;
    }
    try testing.expectEqual(@as(u32, 0), groups);
}

// ---------------------------------------------------------------------------
// Attribution cost
// ---------------------------------------------------------------------------

fn writeDefs(dir: std.Io.Dir, io: std.Io, name: []const u8, count: u32) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try body.print(testing.allocator, "def f{d}(a, b):\n    return g{d}(a) + b\n\n", .{ i, i });
    }
    try dir.writeFile(io, .{ .sub_path = name, .data = body.items });
}

/// Builds `root` and returns the attribution probe counts recorded during that
/// one build (`ts_backend.probe_count`/`probe_sites`), reset first so the
/// result reflects only this build.
fn probeCounts(gpa: std.mem.Allocator, root: []const u8) !struct { probes: u64, sites: u64 } {
    ts_backend.probe_count = 0;
    ts_backend.probe_sites = 0;
    var idx = try index.build(gpa, testing.io, root, false, .tree_sitter);
    idx.deinit();
    return .{ .probes = ts_backend.probe_count, .sites = ts_backend.probe_sites };
}

test "reference attribution stays linear in one file's definition count" {
    // F1 (round 2). Owner attribution scanned every definition in the file for
    // every reference site and every local binding, so ONE large module cost
    // O(defs x sites) while the same definitions spread over many files did
    // not.
    //
    // This used to be a same-run wall-clock ratio (`big_ms <= 5 * small_ms +
    // 50`). It does not reproduce: instrumented sampling of this exact code,
    // Debug, 16 cores, load 1.7-2.8, found the *linear* range is 1.72x .. 7.66x
    // (not the documented 2.60x .. 2.71x) because the small corpus alone swings
    // bimodally between 160ms and 365ms, and the two sizes are measured seconds
    // apart. That range overlaps the *pre-fix quadratic* range of 7.86x ..
    // 12.30x, so no wall-clock threshold separates the two populations at this
    // corpus size — the built test binary failed 2 runs in 8 (25%) at load ~2.5.
    //
    // Count probes instead: `enclosingCallable`'s binary search plus its
    // `nearest`-chain walk costs O(log n + depth) per site, deterministically,
    // with zero dependency on machine load. Measured `per_site` (probes /
    // sites) rose by exactly 1.00 per doubling of the corpus — textbook
    // log2(n) — and was byte-identical across repeated runs at every size. The
    // pre-fix per-site linear scan would have cost ~1.9e8 probes at 8 000 defs
    // against the ~6.7e5 measured here: a 286x separation, vs. the ~1.0x a wall
    // clock resolves.
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    const sizes = [_]u32{ 1000, 2000, 4000, 8000, 16000 };
    for (sizes) |defs| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try writeDefs(tmp.dir, testing.io, "all.py", defs);
        var path_buf: [256]u8 = undefined;
        const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

        // Run twice: a probe count is a pure function of the corpus, not a
        // sample — the property a wall clock could never have.
        const first = try probeCounts(gpa, root);
        const second = try probeCounts(gpa, root);
        try testing.expectEqual(first.probes, second.probes);
        try testing.expectEqual(first.sites, second.sites);
        try testing.expect(first.sites > 0);

        // log2(n) + 8: generous headroom over the measured ~log2(n)+1, but
        // orders of magnitude below the pre-fix O(n)-per-site scan.
        try testing.expect(first.probes <= first.sites * (std.math.log2_int(u32, defs) + 8));
    }
}

// ---------------------------------------------------------------------------
// Ownership
// ---------------------------------------------------------------------------

fn parentName(idx: *const index.Index, sym: model.Symbol) []const u8 {
    return if (sym.parent == model.invalid_symbol) "" else idx.graph.symbols[sym.parent].name;
}

fn symbolNamed(idx: *const index.Index, name: []const u8) ?model.Symbol {
    for (idx.graph.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, name)) return sym;
    }
    return null;
}

test "a container declared inside a function belongs to it; an inline object type owns nothing" {
    // F5: `resolveParents` claimed to match the heuristic and did not — a class
    // declared in a function came back parentless, so `hierarchy` and the `def`
    // path rendered it as a top-level type.
    // F11: the anonymous-inline-object-type exclusion in `dropUnowned` was
    // correct but untested; a parentless member would let a bare name in some
    // other body bind to it.
    if (!ts_backend.any_grammar) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data =
        \\def free():
        \\    class Local:
        \\        def m(self):
        \\            return 1
        \\    return Local
        \\
        \\def outer():
        \\    def inner():
        \\        return 1
        \\    return inner()
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.ts", .data =
        \\export class Widget {
        \\  render(props: { title: string; hidden: boolean }): void {}
        \\}
        \\
        \\export type Shape = { side: number };
    });

    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var heuristic = try index.build(gpa, io, root, false, .heuristic);
    defer heuristic.deinit();
    var ts = try index.build(gpa, io, root, false, .tree_sitter);
    defer ts.deinit();

    // F5: the class takes the function as its parent, in both backends…
    try testing.expectEqualStrings("free", parentName(&ts, symbolNamed(&ts, "Local").?));
    try testing.expectEqualStrings("free", parentName(&heuristic, symbolNamed(&heuristic, "Local").?));
    // …while a nested *function* stays parentless and keeps resolving by name.
    try testing.expectEqualStrings("", parentName(&ts, symbolNamed(&ts, "inner").?));
    try testing.expectEqualStrings("", parentName(&heuristic, symbolNamed(&heuristic, "inner").?));

    // F11: members of an inline object type in a signature belong to no named
    // type and are dropped; a named type alias's members are kept.
    try testing.expectEqual(@as(?model.Symbol, null), symbolNamed(&ts, "title"));
    try testing.expectEqual(@as(?model.Symbol, null), symbolNamed(&ts, "hidden"));
    const side = symbolNamed(&ts, "side") orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("Shape", parentName(&ts, side));
}
