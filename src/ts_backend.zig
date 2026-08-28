//! Tree-sitter backend: a second implementation of the `parser.parse` seam.
//!
//! Bindings are hand-written `extern fn` declarations rather than `@cImport`, so
//! nothing here needs the C headers at Zig-compile time and cross-compiling to
//! macOS/musl/aarch64 stays a plain `-Dtarget=` away.
//!
//! Two mistakes cost the spike a day each and are structurally prevented here:
//!   * `ts_query_new` walks the whole grammar (~14 ms). Compiling a query per
//!     file made extraction 37x slower — queries live in `Compiled`, built once
//!     per language and reused for every file.
//!   * `ts_query_capture_name_for_id` returns memory owned by the `TSQuery`.
//!     Capture names are mapped to enums at compile time and the C strings are
//!     never retained, so a later `ts_query_delete` cannot corrupt kinds.

const std = @import("std");
const build_options = @import("build_options");
const language = @import("language.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");

const Language = language.Language;
const ParsedSymbol = parser.ParsedSymbol;
const Reference = model.Reference;
const Binding = model.Binding;
const SymbolKind = model.SymbolKind;
const Mods = model.Mods;

pub const Error = std.mem.Allocator.Error || error{
    QueryCompileFailed,
    LanguageAbiUnsupported,
    ParserInitFailed,
    TreeSitterParseFailed,
};

/// What a tree-sitter parse produced for one file.
pub const Outcome = enum {
    /// Symbols were appended; the parse tree had no ERROR/MISSING node.
    extracted,
    /// The tree contained an ERROR or MISSING node. Nothing was appended and
    /// the caller must fall back — a partial symbol set is worse than none.
    error_node,
};

/// Whether this build linked a grammar for `lang`.
pub fn supports(lang: Language) bool {
    return switch (lang) {
        .python => build_options.ts_python,
        .typescript => build_options.ts_typescript,
        .tsx => build_options.ts_tsx,
        else => false,
    };
}

/// Whether this build linked any grammar at all.
pub const any_grammar = build_options.ts_python or build_options.ts_typescript or build_options.ts_tsx;

// ---------------------------------------------------------------------------
// C API bindings
// ---------------------------------------------------------------------------

const TSLanguage = opaque {};
const TSParser = opaque {};
const TSTree = opaque {};
const TSQuery = opaque {};
const TSQueryCursor = opaque {};

const TSPoint = extern struct { row: u32, column: u32 };

const TSNode = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const TSTree,
};

const TSQueryCapture = extern struct { node: TSNode, index: u32 };

const TSQueryMatch = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*]const TSQueryCapture,
};

const TSQueryError = enum(c_uint) { none, syntax, node_type, field, capture, structure, language, _ };

extern fn ts_parser_new() ?*TSParser;
extern fn ts_parser_delete(self: *TSParser) void;
extern fn ts_parser_set_language(self: *TSParser, lang: *const TSLanguage) bool;
extern fn ts_parser_parse_string(self: *TSParser, old: ?*const TSTree, string: [*]const u8, len: u32) ?*TSTree;
extern fn ts_tree_delete(self: *TSTree) void;
extern fn ts_tree_root_node(self: *const TSTree) TSNode;
extern fn ts_node_has_error(self: TSNode) bool;
extern fn ts_node_is_null(self: TSNode) bool;
extern fn ts_node_start_byte(self: TSNode) u32;
extern fn ts_node_end_byte(self: TSNode) u32;
extern fn ts_node_start_point(self: TSNode) TSPoint;
extern fn ts_node_type(self: TSNode) [*:0]const u8;
extern fn ts_node_parent(self: TSNode) TSNode;
extern fn ts_node_child_by_field_name(self: TSNode, name: [*]const u8, len: u32) TSNode;
extern fn ts_node_named_child(self: TSNode, i: u32) TSNode;
extern fn ts_node_named_child_count(self: TSNode) u32;
extern fn ts_query_new(lang: *const TSLanguage, src: [*]const u8, len: u32, err_off: *u32, err_type: *TSQueryError) ?*TSQuery;
extern fn ts_query_delete(self: *TSQuery) void;
extern fn ts_query_capture_count(self: *const TSQuery) u32;
extern fn ts_query_capture_name_for_id(self: *const TSQuery, i: u32, len: *u32) [*]const u8;
extern fn ts_query_cursor_new() ?*TSQueryCursor;
extern fn ts_query_cursor_delete(self: *TSQueryCursor) void;
extern fn ts_query_cursor_exec(self: *TSQueryCursor, q: *const TSQuery, node: TSNode) void;
extern fn ts_query_cursor_next_match(self: *TSQueryCursor, out: *TSQueryMatch) bool;
extern fn ts_language_abi_version(self: *const TSLanguage) u32;

// Generated grammars. Referenced only under a comptime-false-eliminable branch,
// so a `-Dtree-sitter=none` build links none of them.
extern fn tree_sitter_python() *const TSLanguage;
extern fn tree_sitter_typescript() *const TSLanguage;
extern fn tree_sitter_tsx() *const TSLanguage;

/// Runtime ABI window (`TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION` ..
/// `TREE_SITTER_LANGUAGE_VERSION`). Checked rather than assumed: a grammar bump
/// that outruns the pinned runtime must fail loudly, not parse to garbage.
const min_abi: u32 = 13;
const max_abi: u32 = 15;

fn nodeText(source: []const u8, node: TSNode) []const u8 {
    const start = ts_node_start_byte(node);
    const end = ts_node_end_byte(node);
    std.debug.assert(start <= end and end <= source.len);
    return source[start..end];
}

fn nodeLine(node: TSNode) u32 {
    return ts_node_start_point(node).row + 1;
}

fn fieldChild(node: TSNode, name: []const u8) ?TSNode {
    const child = ts_node_child_by_field_name(node, name.ptr, @intCast(name.len));
    return if (ts_node_is_null(child)) null else child;
}

// ---------------------------------------------------------------------------
// Query capture vocabulary (NavGraph-owned; see queries/<lang>/*.scm)
// ---------------------------------------------------------------------------

const DefCap = enum {
    def_function,
    def_method,
    def_class,
    def_struct,
    def_enum,
    def_interface,
    def_type,
    def_variable,
    def_constant,
    def_field,
    def_import,
    name,
    doc,
    type,
    init,
    recv,
    path,
    from_path,
    decorators,
    exported,
    mod_static,
    mod_async,
    mod_getter,
    mod_setter,
    mod_abstract,
    ignored,

    fn kind(self: DefCap) ?SymbolKind {
        return switch (self) {
            .def_function => .function,
            .def_method => .method,
            .def_class => .class,
            .def_struct => .@"struct",
            .def_enum => .@"enum",
            .def_interface => .interface,
            .def_type => .type,
            .def_variable => .variable,
            .def_constant => .constant,
            .def_field => .field,
            .def_import => .import,
            else => null,
        };
    }
};

const RefCap = enum { ref, ref_call, ref_write, ref_readwrite, qualifier, ignored };

const BindCap = enum { bind_name, bind_type, ignored };

/// Map a capture name to `Cap`, or `.ignored`. A leading `_` marks a capture the
/// query needs structurally but the extractor does not consume.
fn capFromName(comptime Cap: type, name: []const u8) Cap {
    inline for (@typeInfo(Cap).@"enum".fields) |f| {
        if (comptime !std.mem.eql(u8, f.name, "ignored")) {
            if (std.mem.eql(u8, name, comptime dotted(f.name))) return @field(Cap, f.name);
        }
    }
    return .ignored;
}

/// The `.scm` spelling of an enum field: `def_function` -> "def.function".
fn dotted(comptime field: []const u8) []const u8 {
    comptime {
        var buf: [field.len]u8 = undefined;
        for (field, 0..) |ch, i| buf[i] = if (ch == '_') '.' else ch;
        const frozen = buf;
        return &frozen;
    }
}

/// One compiled query plus its capture-id → enum table. The table is the fix for
/// the capture-name use-after-free: names are resolved once, here, and the C
/// strings are never stored.
fn Query(comptime Cap: type) type {
    return struct {
        const Self = @This();

        query: *TSQuery,
        caps: []Cap,

        fn compile(gpa: std.mem.Allocator, lang: *const TSLanguage, source: []const u8) Error!Self {
            var err_off: u32 = 0;
            var err_type: TSQueryError = .none;
            const q = ts_query_new(lang, source.ptr, @intCast(source.len), &err_off, &err_type) orelse {
                std.debug.print(
                    "navgraph: tree-sitter query failed to compile at byte {d} ({t})\n",
                    .{ err_off, err_type },
                );
                return error.QueryCompileFailed;
            };
            errdefer ts_query_delete(q);
            const n = ts_query_capture_count(q);
            const caps = try gpa.alloc(Cap, n);
            for (caps, 0..) |*slot, i| {
                var len: u32 = 0;
                const raw = ts_query_capture_name_for_id(q, @intCast(i), &len);
                slot.* = capFromName(Cap, raw[0..len]);
            }
            return .{ .query = q, .caps = caps };
        }

        fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.caps);
            ts_query_delete(self.query);
        }

        fn capOf(self: Self, index: u32) Cap {
            std.debug.assert(index < self.caps.len);
            return self.caps[index];
        }
    };
}

/// Everything a language needs to extract, built once and reused for every file.
const Compiled = struct {
    lang: *const TSLanguage,
    ts_parser: *TSParser,
    defs: Query(DefCap),
    refs: Query(RefCap),
    locals: Query(BindCap),

    fn init(gpa: std.mem.Allocator, lang: *const TSLanguage, q: QuerySet) Error!Compiled {
        const abi = ts_language_abi_version(lang);
        if (abi < min_abi or abi > max_abi) return error.LanguageAbiUnsupported;
        const p = ts_parser_new() orelse return error.ParserInitFailed;
        errdefer ts_parser_delete(p);
        if (!ts_parser_set_language(p, lang)) return error.LanguageAbiUnsupported;

        var defs = try Query(DefCap).compile(gpa, lang, q.defs);
        errdefer defs.deinit(gpa);
        var refs = try Query(RefCap).compile(gpa, lang, q.refs);
        errdefer refs.deinit(gpa);
        const locals = try Query(BindCap).compile(gpa, lang, q.locals);
        return .{ .lang = lang, .ts_parser = p, .defs = defs, .refs = refs, .locals = locals };
    }

    fn deinit(self: *Compiled, gpa: std.mem.Allocator) void {
        self.locals.deinit(gpa);
        self.refs.deinit(gpa);
        self.defs.deinit(gpa);
        ts_parser_delete(self.ts_parser);
    }
};

const QuerySet = struct { defs: []const u8, refs: []const u8, locals: []const u8 };

const py_queries = QuerySet{
    .defs = @embedFile("queries/python/defs.scm"),
    .refs = @embedFile("queries/python/refs.scm"),
    .locals = @embedFile("queries/python/locals.scm"),
};
const ts_queries = QuerySet{
    .defs = @embedFile("queries/typescript/defs.scm"),
    .refs = @embedFile("queries/typescript/refs.scm"),
    .locals = @embedFile("queries/typescript/locals.scm"),
};

/// Per-process holder of the compiled grammars. Owned by the index build, not a
/// global: the lifetime is explicit and two concurrent builds cannot share it.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    slots: [std.meta.fields(Language).len]?Compiled = @splat(null),
    cursor: ?*TSQueryCursor = null,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        if (comptime !any_grammar) return; // nothing was ever compiled
        for (&self.slots) |*slot| {
            if (slot.*) |*c| c.deinit(self.gpa);
            slot.* = null;
        }
        if (self.cursor) |c| ts_query_cursor_delete(c);
        self.cursor = null;
    }

    fn compiled(self: *Registry, lang: Language) Error!*Compiled {
        const slot = &self.slots[@intFromEnum(lang)];
        if (slot.* == null) {
            const raw: *const TSLanguage, const queries: QuerySet = switch (lang) {
                .python => if (build_options.ts_python)
                    .{ tree_sitter_python(), py_queries }
                else
                    unreachable,
                .typescript => if (build_options.ts_typescript)
                    .{ tree_sitter_typescript(), ts_queries }
                else
                    unreachable,
                .tsx => if (build_options.ts_tsx)
                    .{ tree_sitter_tsx(), ts_queries }
                else
                    unreachable,
                else => unreachable,
            };
            slot.* = try Compiled.init(self.gpa, raw, queries);
        }
        return &slot.*.?;
    }

    fn queryCursor(self: *Registry) Error!*TSQueryCursor {
        if (self.cursor == null) self.cursor = ts_query_cursor_new() orelse return error.ParserInitFailed;
        return self.cursor.?;
    }
};

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// A definition discovered by `defs.scm`, before parents and refs are attached.
const Def = struct {
    node: TSNode,
    kind: SymbolKind,
    name: []const u8,
    line: u32,
    span_start: u32,
    span_end: u32,
    sig_end: u32,
    doc: []const u8,
    exported: bool,
    modifiers: Mods,
    declared_type: []const u8,
    import_path: []const u8,
    /// A `self.x = …` capture: its owner is the enclosing class, not the
    /// constructor it is written in.
    self_field: bool,
    /// Nearest enclosing captured definition of any kind. Filled after all defs
    /// are known; distinct from `parent_local`, which follows the heuristic
    /// backend's narrower rule (see `resolveParents`).
    nearest: ?u32 = null,
    parent_local: ?u32 = null,
};

/// One reference occurrence, keyed by its byte offset so several query patterns
/// can refine the same identifier without double-counting it.
const Site = struct {
    name: []const u8,
    qualifier: []const u8 = "",
    /// Identifier heading the receiver chain when the qualifier is itself a
    /// member (`o.store.Get()` -> "o"); "" when the qualifier heads it.
    receiver_root: []const u8 = "",
    line: u32,
    call: bool = false,
    write: bool = false,
    suppress_read: bool = false,
};

/// Parse `source` with the grammar for `lang` and append the discovered symbols.
/// Returns `.error_node` (appending nothing) when the tree is not clean, so the
/// caller can fall back to the heuristic scanner for this file.
pub fn parse(
    reg: *Registry,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    lang: Language,
    out: *std.ArrayList(ParsedSymbol),
) Error!Outcome {
    std.debug.assert(supports(lang));
    std.debug.assert(source.len <= std.math.maxInt(u32));
    const c = try reg.compiled(lang);
    const cursor = try reg.queryCursor();

    const tree = ts_parser_parse_string(c.ts_parser, null, source.ptr, @intCast(source.len)) orelse
        return error.TreeSitterParseFailed;
    defer ts_tree_delete(tree);
    const root = ts_tree_root_node(tree);
    if (ts_node_has_error(root)) return .error_node;

    var defs: std.ArrayList(Def) = .empty;
    defer defs.deinit(gpa);
    try collectDefs(c, cursor, gpa, source, lang, root, &defs);
    sortDefs(defs.items);

    var by_node: std.AutoHashMapUnmanaged(usize, u32) = .empty;
    defer by_node.deinit(gpa);
    for (defs.items, 0..) |d, i| try by_node.put(gpa, nodeKey(d.node), @intCast(i));
    refineFunctionValued(source, defs.items);
    resolveParents(&by_node, defs.items);
    refineKinds(defs.items);
    try dropUnowned(&defs, gpa, &by_node);
    try mergeDuplicates(&defs, gpa, &by_node);

    const base: u32 = @intCast(out.items.len);
    try out.ensureUnusedCapacity(gpa, defs.items.len);
    for (defs.items) |d| {
        out.appendAssumeCapacity(.{
            .name = d.name,
            .kind = d.kind,
            .line = d.line,
            .span_start = d.span_start,
            .span_end = d.span_end,
            .sig_end = d.sig_end,
            .doc = d.doc,
            .exported = d.exported,
            .modifiers = d.modifiers,
            .parent_local = if (d.kind == .import) null else if (d.parent_local) |p| base + p else null,
            .refs = &.{},
            .import_path = d.import_path,
            .declared_type = d.declared_type,
        });
    }
    try attachRefs(c, cursor, gpa, arena, source, root, defs.items, out.items[base..]);
    try attachBindings(c, cursor, gpa, arena, source, root, defs.items, out.items[base..]);
    return .extracted;
}

fn nodeKey(node: TSNode) usize {
    return @intFromPtr(node.id);
}

/// Outer-before-inner, source order. Deterministic ordering matters: the on-disk
/// cache round-trips this list and a warm build must reproduce it exactly.
fn sortDefs(defs: []Def) void {
    std.mem.sort(Def, defs, {}, struct {
        fn lt(_: void, a: Def, b: Def) bool {
            if (a.span_start != b.span_start) return a.span_start < b.span_start;
            if (a.span_end != b.span_end) return a.span_end > b.span_end;
            return a.line < b.line;
        }
    }.lt);
}

/// Fill `nearest` (the innermost enclosing definition of any kind) and
/// `parent_local`.
///
/// `parent_local` deliberately matches the heuristic backend: a definition is
/// owned by an enclosing *container* (class/struct/interface/enum), never by an
/// enclosing function, so a nested helper stays parentless and keeps resolving
/// by its bare name. A `self.x` field is the exception — it belongs to the class
/// it is written on, not to the constructor that assigns it.
fn resolveParents(by_node: *const std.AutoHashMapUnmanaged(usize, u32), defs: []Def) void {
    for (defs) |*d| d.nearest = nearestDef(by_node, d.node);
    for (defs) |*d| {
        if (d.self_field) {
            d.parent_local = nearestContainer(by_node, d.node, defs);
            continue;
        }
        const near = d.nearest orelse continue;
        d.parent_local = if (isContainerKind(defs[near].kind)) near else null;
    }
}

fn nearestDef(by_node: *const std.AutoHashMapUnmanaged(usize, u32), node: TSNode) ?u32 {
    var cur = ts_node_parent(node);
    while (!ts_node_is_null(cur)) : (cur = ts_node_parent(cur)) {
        if (by_node.get(nodeKey(cur))) |idx| return idx;
    }
    return null;
}

fn nearestContainer(
    by_node: *const std.AutoHashMapUnmanaged(usize, u32),
    node: TSNode,
    defs: []const Def,
) ?u32 {
    var cur = ts_node_parent(node);
    while (!ts_node_is_null(cur)) : (cur = ts_node_parent(cur)) {
        const idx = by_node.get(nodeKey(cur)) orelse continue;
        if (isContainerKind(defs[idx].kind)) return idx;
    }
    return null;
}

fn collectDefs(
    c: *Compiled,
    cursor: *TSQueryCursor,
    gpa: std.mem.Allocator,
    source: []const u8,
    lang: Language,
    root: TSNode,
    out: *std.ArrayList(Def),
) Error!void {
    // Patterns deliberately overlap (a broad one for the definition, narrower
    // ones adding @type/@init), so several matches can name the same node. They
    // are merged rather than duplicated.
    var index: std.AutoHashMapUnmanaged(usize, u32) = .empty;
    defer index.deinit(gpa);
    var exported_nodes: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer exported_nodes.deinit(gpa);

    ts_query_cursor_exec(cursor, c.defs.query, root);
    var m: TSQueryMatch = undefined;
    while (ts_query_cursor_next_match(cursor, &m)) {
        var def_node: ?TSNode = null;
        var kind: SymbolKind = .unknown;
        var name_node: ?TSNode = null;
        var type_node: ?TSNode = null;
        var init_node: ?TSNode = null;
        var doc_node: ?TSNode = null;
        var path_node: ?TSNode = null;
        var decorators: ?TSNode = null;
        var recv_node: ?TSNode = null;
        var recv_ok = true;
        var binds_nothing = false;
        var mods = Mods{};

        for (m.captures[0..m.capture_count]) |cap| {
            const node = cap.node;
            switch (c.defs.capOf(cap.index)) {
                .name => name_node = node,
                .doc => doc_node = node,
                .type => type_node = node,
                .init => init_node = node,
                .path => path_node = node,
                .from_path => {
                    path_node = node;
                    binds_nothing = true;
                },
                .decorators => decorators = node,
                .exported => try exported_nodes.put(gpa, nodeKey(node), {}),
                .recv => {
                    recv_node = node;
                    recv_ok = isSelfReceiver(nodeText(source, node));
                },
                .mod_static => mods.is_static = true,
                .mod_async => mods.is_async = true,
                .mod_getter => mods.getter = true,
                .mod_setter => mods.setter = true,
                .mod_abstract => mods.abstract = true,
                .ignored => {},
                else => |cp| {
                    def_node = node;
                    kind = cp.kind().?;
                },
            }
        }
        if (!recv_ok) continue;
        const def = def_node orelse continue;
        const path = if (path_node) |p| stripQuotes(nodeText(source, p)) else "";
        const name = if (name_node) |n|
            nodeText(source, n)
        else if (kind == .import)
            (if (binds_nothing) "" else importBinding(path))
        else
            continue;
        if (name.len == 0 and kind != .import) continue;

        if (decorators) |d| applyDecorators(source, d, &mods);
        const declared = declaredType(source, type_node, init_node);
        if (index.get(nodeKey(def))) |existing| {
            const prev = &out.items[existing];
            prev.modifiers = @bitCast(@as(u8, @bitCast(prev.modifiers)) | @as(u8, @bitCast(mods)));
            if (prev.declared_type.len == 0) prev.declared_type = declared;
            if (prev.import_path.len == 0) prev.import_path = path;
            if (prev.doc.len == 0) prev.doc = docOf(source, doc_node);
            // A broad pattern may have matched first and left the name empty
            // (`import x from "y"`: one pattern sees only the module string).
            if (prev.name.len == 0 and name.len != 0) {
                prev.name = name;
                if (name_node) |n| prev.line = nodeLine(n);
            }
            continue;
        }
        const span_start = lineStart(source, ts_node_start_byte(def));
        const span_end = ts_node_end_byte(def);
        var sig_end = if (fieldChild(def, "body")) |body| ts_node_start_byte(body) else span_end;
        sig_end = std.math.clamp(sig_end, span_start, span_end);
        try index.put(gpa, nodeKey(def), @intCast(out.items.len));
        try out.append(gpa, .{
            .node = def,
            .kind = kind,
            .name = name,
            .line = if (name_node) |n| nodeLine(n) else nodeLine(def),
            .span_start = span_start,
            .span_end = span_end,
            .sig_end = sig_end,
            .doc = docOf(source, doc_node),
            .exported = defaultExported(lang, kind, name),
            .modifiers = mods,
            .declared_type = declared,
            .import_path = path,
            .self_field = kind == .field and recv_node != null,
        });
    }
    // `export` marks a declaration node, which is the definition's *parent*, so
    // it is resolved after every definition is known.
    for (out.items) |*d| {
        if (exported_nodes.contains(nodeKey(d.node)) or
            hasExportedAncestor(&exported_nodes, d.node)) d.exported = true;
    }
}

/// Visibility before any `export` marker is applied. Python spells visibility
/// with a leading underscore; TypeScript spells it with the `export` keyword, so
/// guessing from the name shape reports every module-private const, let, var and
/// function — and every class member — as public API.
fn defaultExported(lang: Language, kind: SymbolKind, name: []const u8) bool {
    if (kind == .import or name.len == 0) return false;
    return switch (lang) {
        .python => name[0] != '_',
        else => false,
    };
}

/// True when an ancestor of `node` was captured as an `export`ed declaration,
/// without crossing into a member list on the way. `export class C { m() {} }`
/// exports `C`, not `C.m` — which is what the heuristic scanner reports too.
fn hasExportedAncestor(marked: *const std.AutoHashMapUnmanaged(usize, void), node: TSNode) bool {
    var cur = ts_node_parent(node);
    while (!ts_node_is_null(cur)) : (cur = ts_node_parent(cur)) {
        if (marked.contains(nodeKey(cur))) return true;
        if (isMemberList(cur)) return false;
    }
    return false;
}

/// A node whose children are members of the enclosing declaration rather than
/// declarations in their own right.
fn isMemberList(node: TSNode) bool {
    const t = std.mem.span(ts_node_type(node));
    inline for (.{ "class_body", "statement_block", "object_type", "enum_body", "block" }) |name| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

/// The name a bare `import a.b.c` binds: the module itself when it is a single
/// segment, else nothing (matching the heuristic backend).
fn importBinding(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    if (std.mem.indexOfScalar(u8, path, '.') != null) return "";
    if (std.mem.indexOfAny(u8, path, "/\\") != null) return "";
    return path;
}

/// A binding whose initializer is a function expression is a function, not a
/// variable — `export const Badge = (p) => …` is how most TSX components are
/// written, and the heuristic scanner indexes them as functions. The signature
/// ends where the function's body begins so its calls are attributed to it.
fn refineFunctionValued(source: []const u8, defs: []Def) void {
    _ = source;
    for (defs) |*d| {
        if (d.kind != .variable and d.kind != .constant) continue;
        const value = declaratorValue(d.node) orelse continue;
        const ty = std.mem.span(ts_node_type(value));
        // Arrow functions only, deliberately: the heuristic scanner reports
        // `const f = function () {}` and `function* () {}` as variables, and a
        // kind that disagrees between backends is a definition lost to the one
        // that renamed it.
        if (!std.mem.eql(u8, ty, "arrow_function")) continue;
        d.kind = .function;
        d.declared_type = "";
        if (fieldChild(value, "body")) |body|
            d.sig_end = std.math.clamp(ts_node_start_byte(body), d.span_start, d.span_end);
    }
}

/// The initializer of a single-declarator `const`/`let`/`var` statement.
fn declaratorValue(decl: TSNode) ?TSNode {
    const n = ts_node_named_child_count(decl);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const child = ts_node_named_child(decl, i);
        if (!std.mem.eql(u8, std.mem.span(ts_node_type(child)), "variable_declarator")) continue;
        return fieldChild(child, "value");
    }
    return null;
}

/// Kinds the grammar cannot decide alone, resolved from the enclosing scope
/// exactly as the heuristic scanner resolves them: a function inside a class is
/// a method, a binding inside a class body is a field.
fn refineKinds(defs: []Def) void {
    for (defs) |*d| {
        const parent = d.parent_local orelse continue;
        const container = isContainerKind(defs[parent].kind);
        if (d.kind == .function and container) d.kind = .method;
        if (d.kind == .variable and container) d.kind = .field;
    }
}

/// Kinds that own members. Deliberately the same set as `index.zig`'s
/// `isContainer`: a symbol parented to one of these is a member, and bare-name
/// resolution skips members. A field left parentless would compete with
/// top-level definitions of the same name and dissolve their exact edges.
fn isContainerKind(kind: SymbolKind) bool {
    return switch (kind) {
        .class, .@"struct", .interface, .@"enum", .type => true,
        else => false,
    };
}

/// Drop what the grammar sees but NavGraph does not index as a definition:
///   * a binding inside a function body — that is a local variable, and the
///     heuristic scanner does not index those either;
///   * an ownerless field — the members of an anonymous object type written
///     inline in a signature (`(props: { post: Post })`, a multi-line return
///     type). They belong to no named type, and leaving them parentless would
///     let a bare name in the body bind to one.
/// `self.x` fields are owned by their class and are unaffected.
fn dropUnowned(
    defs: *std.ArrayList(Def),
    gpa: std.mem.Allocator,
    by_node: *std.AutoHashMapUnmanaged(usize, u32),
) Error!void {
    var kept: usize = 0;
    for (defs.items) |d| {
        if (d.kind == .variable or d.kind == .constant) {
            if (d.nearest) |near| {
                if (isCallableKind(defs.items[near].kind)) continue;
            }
        }
        if (d.kind == .field and d.parent_local == null) continue;
        defs.items[kept] = d;
        kept += 1;
    }
    if (kept == defs.items.len) return;
    defs.shrinkRetainingCapacity(kept);
    try reindex(defs.items, gpa, by_node);
}

/// Local indices moved: rebuild the node index and re-resolve every parent.
fn reindex(
    defs: []Def,
    gpa: std.mem.Allocator,
    by_node: *std.AutoHashMapUnmanaged(usize, u32),
) Error!void {
    by_node.clearRetainingCapacity();
    for (defs, 0..) |d, i| try by_node.put(gpa, nodeKey(d.node), @intCast(i));
    resolveParents(by_node, defs);
}

/// Collapse definitions that name the same member twice:
///   * a field written on `self`/`this` in several places (`__init__` and a
///     setter) is one field, not one per assignment;
///   * an overload signature is not a second function — a bodyless declaration
///     yields to the implementation that shares its name.
/// Both make `def A.b` ambiguous and `collisions` report a duplicate that is
/// not one; the heuristic scanner reports one symbol for each shape. Two
/// definitions that both have bodies (a `get`/`set` pair) are left alone —
/// those are two real members and the heuristic keeps both.
fn mergeDuplicates(
    defs: *std.ArrayList(Def),
    gpa: std.mem.Allocator,
    by_node: *std.AutoHashMapUnmanaged(usize, u32),
) Error!void {
    if (defs.items.len < 2) return;
    const order = try gpa.alloc(u32, defs.items.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const items = defs.items;
    std.mem.sort(u32, order, items, struct {
        fn lt(d: []const Def, a: u32, b: u32) bool {
            const x = d[a];
            const y = d[b];
            const xp = x.parent_local orelse std.math.maxInt(u32);
            const yp = y.parent_local orelse std.math.maxInt(u32);
            if (xp != yp) return xp < yp;
            if (x.kind != y.kind) return @intFromEnum(x.kind) < @intFromEnum(y.kind);
            const c = std.mem.order(u8, x.name, y.name);
            if (c != .eq) return c == .lt;
            return a < b;
        }
    }.lt);

    const drop = try gpa.alloc(bool, items.len);
    defer gpa.free(drop);
    @memset(drop, false);

    var run_start: usize = 0;
    while (run_start < order.len) {
        var run_end = run_start + 1;
        while (run_end < order.len and sameMember(items[order[run_start]], items[order[run_end]])) run_end += 1;
        mergeRun(items, order[run_start..run_end], drop);
        run_start = run_end;
    }

    var kept: usize = 0;
    for (items, 0..) |d, i| {
        if (drop[i]) continue;
        items[kept] = d;
        kept += 1;
    }
    if (kept == items.len) return;
    defs.shrinkRetainingCapacity(kept);
    try reindex(defs.items, gpa, by_node);
}

fn sameMember(a: Def, b: Def) bool {
    const ap = a.parent_local orelse std.math.maxInt(u32);
    const bp = b.parent_local orelse std.math.maxInt(u32);
    return ap == bp and a.kind == b.kind and std.mem.eql(u8, a.name, b.name);
}

/// `run` holds the indices of definitions naming one member, in source order.
fn mergeRun(defs: []Def, run: []const u32, drop: []bool) void {
    if (run.len < 2) return;
    if (defs[run[0]].kind == .field) {
        const keep = &defs[run[0]];
        for (run[1..]) |i| {
            const other = defs[i];
            if (keep.declared_type.len == 0) keep.declared_type = other.declared_type;
            if (keep.doc.len == 0) keep.doc = other.doc;
            keep.modifiers = @bitCast(@as(u8, @bitCast(keep.modifiers)) | @as(u8, @bitCast(other.modifiers)));
            drop[i] = true;
        }
        return;
    }
    if (!isCallableKind(defs[run[0]].kind)) return;
    var has_implementation = false;
    for (run) |i| has_implementation = has_implementation or hasBody(defs[i]);
    if (!has_implementation) return; // interface overloads: all declarations, keep them
    for (run) |i| {
        if (!hasBody(defs[i])) drop[i] = true;
    }
}

fn hasBody(d: Def) bool {
    return fieldChild(d.node, "body") != null;
}

fn isCallableKind(kind: SymbolKind) bool {
    return kind == .function or kind == .method;
}

fn isSelfReceiver(text: []const u8) bool {
    return std.mem.eql(u8, text, "self") or std.mem.eql(u8, text, "this") or std.mem.eql(u8, text, "cls");
}

fn docOf(source: []const u8, node: ?TSNode) []const u8 {
    const n = node orelse return "";
    return nodeText(source, n);
}

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and (text[0] == '"' or text[0] == '\'') and text[text.len - 1] == text[0])
        return text[1 .. text.len - 1];
    return text;
}

/// Byte offset of the start of the line containing `offset`.
fn lineStart(source: []const u8, offset: u32) u32 {
    if (offset == 0) return 0;
    const nl = std.mem.lastIndexOfScalar(u8, source[0..offset], '\n') orelse return 0;
    return @intCast(nl + 1);
}

/// The declared type: an explicit annotation when present, else the constructor
/// named by a direct `Type(...)` / `new Type(...)` initializer.
fn declaredType(source: []const u8, type_node: ?TSNode, init_node: ?TSNode) []const u8 {
    if (type_node) |t| return typeHead(nodeText(source, t));
    const init = init_node orelse return "";
    const callee = calleeName(source, init) orelse return "";
    return callee;
}

/// The nominal head of a type expression: `List[Item]` -> `List`, `Foo<Bar>` ->
/// `Foo`, `a.b.C` -> `C`. Matches how the resolver keys receiver types.
fn typeHead(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        const ch = text[end];
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.') break;
    }
    const head = std.mem.trim(u8, text[0..end], " \t");
    if (std.mem.lastIndexOfScalar(u8, head, '.')) |dot| return head[dot + 1 ..];
    return head;
}

/// The constructor name of `Type(...)` / `new Type(...)`, else null.
fn calleeName(source: []const u8, node: TSNode) ?[]const u8 {
    const ty = std.mem.span(ts_node_type(node));
    if (std.mem.eql(u8, ty, "new_expression")) {
        const ctor = fieldChild(node, "constructor") orelse return null;
        return typeHead(nodeText(source, ctor));
    }
    if (std.mem.eql(u8, ty, "call") or std.mem.eql(u8, ty, "call_expression")) {
        const fun = fieldChild(node, "function") orelse return null;
        return typeHead(nodeText(source, fun));
    }
    return null;
}

/// Fold Python's accessor/dispatch decorators into `mods`. Unrecognized
/// decorators (routes, framework glue) leave the modifiers untouched.
fn applyDecorators(source: []const u8, decorated: TSNode, mods: *Mods) void {
    const n = ts_node_named_child_count(decorated);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const child = ts_node_named_child(decorated, i);
        if (!std.mem.eql(u8, std.mem.span(ts_node_type(child)), "decorator")) continue;
        const text = std.mem.trim(u8, nodeText(source, child), "@ \t");
        const tail = if (std.mem.lastIndexOfScalar(u8, text, '.')) |d| text[d + 1 ..] else text;
        const head = tail[0 .. std.mem.indexOfScalar(u8, tail, '(') orelse tail.len];
        if (std.mem.eql(u8, head, "property") or std.mem.eql(u8, head, "cached_property")) {
            mods.getter = true;
        } else if (std.mem.eql(u8, head, "setter")) {
            mods.setter = true;
        } else if (std.mem.eql(u8, head, "staticmethod")) {
            mods.is_static = true;
        } else if (std.mem.eql(u8, head, "classmethod")) {
            mods.classmethod = true;
        } else if (std.mem.eql(u8, head, "abstractmethod")) {
            mods.abstract = true;
        }
    }
}

// ---------------------------------------------------------------------------
// References
// ---------------------------------------------------------------------------

/// Index of the innermost callable definition owning byte `offset`, or null when
/// the site sits at file scope (which the heuristic backend also drops).
fn ownerOf(defs: []const Def, offset: u32) ?u32 {
    return enclosingCallable(defs, offset, .body_only);
}

/// Where a reference site must sit to belong to a callable: in its body, or
/// anywhere in it including the signature (a parameter is declared there).
const SiteScope = enum { body_only, with_signature };

/// The innermost callable containing `offset`, found in time linear in nesting
/// depth rather than in the file's definition count — the per-site linear scan
/// this replaces made a single 12 000-definition module quadratic.
///
/// `defs` is sorted outer-before-inner by `span_start` (`sortDefs`) and spans
/// nest, so every definition containing `offset` is an ancestor of the last
/// definition opened at or before it, i.e. on that one's `nearest` chain.
fn enclosingCallable(defs: []const Def, offset: u32, scope: SiteScope) ?u32 {
    var cur = lastOpenedAt(defs, offset);
    while (cur) |i| {
        const d = defs[i];
        if (d.kind == .function or d.kind == .method) {
            const from = switch (scope) {
                .body_only => d.sig_end,
                .with_signature => d.span_start,
            };
            if (offset >= from and offset < d.span_end) return i;
        }
        const next = d.nearest orelse return null;
        // Enclosing definitions sort earlier, so the walk strictly ascends and
        // cannot loop.
        std.debug.assert(next < i);
        cur = next;
    }
    return null;
}

/// Index of the last definition whose span starts at or before `offset`.
fn lastOpenedAt(defs: []const Def, offset: u32) ?u32 {
    var lo: usize = 0;
    var hi: usize = defs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (defs[mid].span_start <= offset) lo = mid + 1 else hi = mid;
    }
    return if (lo == 0) null else @intCast(lo - 1);
}

/// The `object`/`property` pair of a member access (`a.b`), whichever field
/// names the grammar uses: Python spells it `attribute`, TS `property`.
fn memberProperty(node: TSNode) ?TSNode {
    return fieldChild(node, "property") orelse fieldChild(node, "attribute");
}

/// Identifier heading the receiver chain of a member access, mirroring the
/// heuristic backend's `receiverChainRoot`: `o.store.Get()` -> "o", and "" when
/// the qualifier already heads the chain (`store.Get()`) or the head is not a
/// plain identifier (`make().store.Get()`). `model.Reference.receiver_root`
/// carries it so the resolver can tell a field access from a bare module
/// qualifier; dropping it lets the enclosing type's field table answer for
/// another object's field.
fn chainRoot(source: []const u8, node: TSNode) []const u8 {
    const parent = ts_node_parent(node);
    if (ts_node_is_null(parent)) return "";
    const property = memberProperty(parent) orelse return "";
    // `node` is the receiver, not the member being named: it heads its own chain.
    if (ts_node_start_byte(property) != ts_node_start_byte(node)) return "";

    var object = fieldChild(parent, "object") orelse return "";
    var depth: u32 = 0;
    while (memberProperty(object) != null) : (depth += 1) {
        // Grammars nest member accesses linearly; the bound only guards against
        // a malformed tree turning this into a hang.
        if (depth > max_chain_depth) return "";
        object = fieldChild(object, "object") orelse return "";
    }
    if (depth == 0) return ""; // the immediate qualifier heads the chain
    const kind = std.mem.span(ts_node_type(object));
    if (!std.mem.eql(u8, kind, "identifier") and !std.mem.eql(u8, kind, "this")) return "";
    return nodeText(source, object);
}

const max_chain_depth: u32 = 64;

fn attachRefs(
    c: *Compiled,
    cursor: *TSQueryCursor,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    root: TSNode,
    defs: []const Def,
    symbols: []ParsedSymbol,
) Error!void {
    std.debug.assert(defs.len == symbols.len);
    var sites: std.AutoHashMapUnmanaged(u32, Site) = .empty;
    defer sites.deinit(gpa);

    ts_query_cursor_exec(cursor, c.refs.query, root);
    var m: TSQueryMatch = undefined;
    while (ts_query_cursor_next_match(cursor, &m)) {
        var target: ?TSNode = null;
        var qualifier: []const u8 = "";
        var call = false;
        var write = false;
        var suppress_read = false;
        for (m.captures[0..m.capture_count]) |cap| {
            switch (c.refs.capOf(cap.index)) {
                .ref => target = cap.node,
                .ref_call => {
                    target = cap.node;
                    call = true;
                },
                .ref_write => {
                    target = cap.node;
                    write = true;
                    suppress_read = true;
                },
                .ref_readwrite => {
                    target = cap.node;
                    write = true;
                },
                .qualifier => qualifier = nodeText(source, cap.node),
                .ignored => {},
            }
        }
        const node = target orelse continue;
        const name = nodeText(source, node);
        if (name.len < 2) continue; // the heuristic backend also skips 1-char names
        const gop = try sites.getOrPut(gpa, ts_node_start_byte(node));
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .name = name,
                .receiver_root = chainRoot(source, node),
                .line = nodeLine(node),
            };
        }
        const site = gop.value_ptr;
        if (qualifier.len != 0) site.qualifier = qualifier;
        site.call = site.call or call;
        site.write = site.write or write;
        site.suppress_read = site.suppress_read or suppress_read;
    }

    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(gpa);
    try offsets.ensureTotalCapacity(gpa, sites.count());
    var it = sites.keyIterator();
    while (it.next()) |k| offsets.appendAssumeCapacity(k.*);
    std.mem.sort(u32, offsets.items, {}, std.sort.asc(u32));

    var acc = RefAccumulator.init(gpa, arena, symbols.len);
    defer acc.deinit();
    for (offsets.items) |offset| {
        const owner = ownerOf(defs, offset) orelse continue;
        const site = sites.get(offset).?;
        // A bare self-reference is recursion noise, exactly as in the heuristic.
        if (site.qualifier.len == 0 and std.mem.eql(u8, site.name, defs[owner].name)) continue;
        if (!site.suppress_read)
            try acc.record(owner, site, offset, site.call, false);
        if (site.write)
            try acc.record(owner, site, offset, false, true);
    }
    try acc.finish(symbols);
}

/// Groups reference occurrences into one `Reference` per (owner, qualifier,
/// name, direction), mirroring the heuristic backend's aggregation so both
/// produce comparable edges.
const RefAccumulator = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    /// (owner << 1 | write) -> index into `refs`, keyed further by name.
    seen: std.StringHashMapUnmanaged(u32),
    refs: std.ArrayList(Reference),
    owners: std.ArrayList(u32),
    lines: std.ArrayList(std.ArrayList(u32)),
    offsets: std.ArrayList(std.ArrayList(u32)),
    keys: std.ArrayList([]u8),
    symbol_count: usize,

    fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator, symbol_count: usize) RefAccumulator {
        return .{
            .gpa = gpa,
            .arena = arena,
            .seen = .empty,
            .refs = .empty,
            .owners = .empty,
            .lines = .empty,
            .offsets = .empty,
            .keys = .empty,
            .symbol_count = symbol_count,
        };
    }

    fn deinit(self: *RefAccumulator) void {
        for (self.keys.items) |k| self.gpa.free(k);
        self.keys.deinit(self.gpa);
        for (self.lines.items) |*l| l.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        for (self.offsets.items) |*o| o.deinit(self.gpa);
        self.offsets.deinit(self.gpa);
        self.owners.deinit(self.gpa);
        self.refs.deinit(self.gpa);
        self.seen.deinit(self.gpa);
    }

    fn record(
        self: *RefAccumulator,
        owner: u32,
        site: Site,
        offset: u32,
        is_call: bool,
        write: bool,
    ) !void {
        std.debug.assert(owner < self.symbol_count);
        // The chain root participates in deduplication for the same reason the
        // heuristic includes it: `a.store.Get()` and `o.store.Get()` reach
        // different objects and must resolve independently.
        const key = try std.fmt.allocPrint(self.gpa, "{d}\x00{s}\x00{s}\x00{s}\x00{c}", .{
            owner, site.receiver_root, site.qualifier, site.name, if (write) @as(u8, 'w') else 'r',
        });
        if (self.seen.get(key)) |idx| {
            self.gpa.free(key);
            self.refs.items[idx].count += 1;
            if (is_call) self.refs.items[idx].kind = .call;
            const ll = &self.lines.items[idx];
            if (ll.items.len == 0 or ll.items[ll.items.len - 1] != site.line) try ll.append(self.gpa, site.line);
            try self.offsets.items[idx].append(self.gpa, offset);
            return;
        }
        {
            errdefer self.gpa.free(key);
            try self.keys.append(self.gpa, key);
        }
        // `keys` owns `key` from here, so any later failure still frees it.
        var line_list: std.ArrayList(u32) = .empty;
        errdefer line_list.deinit(self.gpa);
        try line_list.append(self.gpa, site.line);
        var offset_list: std.ArrayList(u32) = .empty;
        errdefer offset_list.deinit(self.gpa);
        try offset_list.append(self.gpa, offset);

        // Reserve every parallel slot before publishing: the appends below must
        // not fail partway and leave `refs`/`owners`/`lines` out of step.
        try self.seen.ensureUnusedCapacity(self.gpa, 1);
        try self.refs.ensureUnusedCapacity(self.gpa, 1);
        try self.owners.ensureUnusedCapacity(self.gpa, 1);
        try self.lines.ensureUnusedCapacity(self.gpa, 1);
        try self.offsets.ensureUnusedCapacity(self.gpa, 1);
        self.seen.putAssumeCapacity(key, @intCast(self.refs.items.len));
        self.refs.appendAssumeCapacity(.{
            .name = site.name,
            .qualifier = site.qualifier,
            .receiver_root = site.receiver_root,
            .line = site.line,
            .kind = if (is_call) .call else .read,
            .write = write,
            .count = 1,
        });
        self.owners.appendAssumeCapacity(owner);
        self.lines.appendAssumeCapacity(line_list);
        self.offsets.appendAssumeCapacity(offset_list);
    }

    /// Split the flat accumulation into one arena-owned slice per symbol.
    fn finish(self: *RefAccumulator, symbols: []ParsedSymbol) !void {
        for (self.refs.items, self.lines.items, self.offsets.items) |*r, ll, ol| {
            if (ll.items.len > 1) r.lines = try self.arena.dupe(u32, ll.items);
            std.debug.assert(ol.items.len == r.count);
            r.offsets = try self.arena.dupe(u32, ol.items);
        }
        var counts = try self.gpa.alloc(u32, symbols.len);
        defer self.gpa.free(counts);
        @memset(counts, 0);
        for (self.owners.items) |o| counts[o] += 1;
        for (symbols, counts) |*sym, n| {
            sym.refs = if (n == 0) &.{} else try self.arena.alloc(Reference, n);
        }
        var filled = try self.gpa.alloc(u32, symbols.len);
        defer self.gpa.free(filled);
        @memset(filled, 0);
        for (self.refs.items, self.owners.items) |r, o| {
            symbols[o].refs[filled[o]] = r;
            filled[o] += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Local bindings
// ---------------------------------------------------------------------------

fn attachBindings(
    c: *Compiled,
    cursor: *TSQueryCursor,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    root: TSNode,
    defs: []const Def,
    symbols: []ParsedSymbol,
) Error!void {
    std.debug.assert(defs.len == symbols.len);
    var per_owner = try gpa.alloc(std.ArrayList(Binding), symbols.len);
    defer {
        for (per_owner) |*l| l.deinit(gpa);
        gpa.free(per_owner);
    }
    for (per_owner) |*l| l.* = .empty;

    ts_query_cursor_exec(cursor, c.locals.query, root);
    var m: TSQueryMatch = undefined;
    while (ts_query_cursor_next_match(cursor, &m)) {
        var name_node: ?TSNode = null;
        var type_node: ?TSNode = null;
        for (m.captures[0..m.capture_count]) |cap| {
            switch (c.locals.capOf(cap.index)) {
                .bind_name => name_node = cap.node,
                .bind_type => type_node = cap.node,
                .ignored => {},
            }
        }
        const n = name_node orelse continue;
        const offset = ts_node_start_byte(n);
        // A parameter sits in the signature, before `sig_end`; nudge lookup into
        // the owning body so both parameters and body locals find their owner.
        const owner = ownerOf(defs, offset) orelse ownerOfSignature(defs, offset) orelse continue;
        const type_name = if (type_node) |t| blk: {
            const ty = std.mem.span(ts_node_type(t));
            break :blk if (std.mem.eql(u8, ty, "new_expression") or std.mem.eql(u8, ty, "call") or
                std.mem.eql(u8, ty, "call_expression"))
                (calleeName(source, t) orelse "")
            else
                typeHead(nodeText(source, t));
        } else "";
        try per_owner[owner].append(gpa, .{ .name = nodeText(source, n), .type_name = type_name });
    }

    for (symbols, per_owner) |*sym, list| {
        if (list.items.len == 0) continue;
        sym.bindings = try arena.dupe(Binding, list.items);
    }
}

/// Owner lookup for a site inside a definition's *signature* (a parameter).
/// Like `ownerOf`, but a site in the signature counts: a parameter belongs to
/// the callable that declares it.
fn ownerOfSignature(defs: []const Def, offset: u32) ?u32 {
    return enclosingCallable(defs, offset, .with_signature);
}
