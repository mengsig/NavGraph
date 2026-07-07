//! Heuristic symbol + reference extraction from a token stream.
//!
//! This is not a full parser. It recognises the common shapes of definitions
//! (functions, methods, classes, structs, types, constants, imports) and the
//! call/reference sites inside their bodies. The goal is high recall on real
//! code with predictable, fast, allocation-light behaviour — good enough to give
//! an agent an accurate map of a repository without a per-language grammar.

const std = @import("std");
const language = @import("language.zig");
const lexer = @import("lexer.zig");
const model = @import("model.zig");
const api = @import("api.zig");

const Token = lexer.Token;
const AllocError = std.mem.Allocator.Error;
const SymbolKind = model.SymbolKind;
const Reference = model.Reference;
const RefKind = model.RefKind;
const Binding = model.Binding;
const Mods = model.Mods;

/// A symbol as discovered within a single file, before global ids are assigned.
pub const ParsedSymbol = struct {
    name: []const u8,
    kind: SymbolKind,
    line: u32,
    span_start: u32,
    span_end: u32,
    sig_end: u32,
    doc: []const u8,
    exported: bool,
    /// Accessor/dispatch/async modifiers (see `model.Mods`).
    modifiers: model.Mods = .{},
    /// Index (into the per-file parse output) of the enclosing symbol, if any.
    parent_local: ?u32,
    refs: []Reference,
    bindings: []const Binding = &.{},
    /// For an `import` symbol: the raw module string (see `model.Symbol`).
    import_path: []const u8 = "",
};

/// References plus local bindings collected from one symbol body.
const BodyInfo = struct {
    refs: []Reference,
    bindings: []const Binding,
};

const sentinel: u32 = std.math.maxInt(u32);

const Ctx = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    cfg: language.Config,
    toks: []const Token,
    /// For every token that is an opening bracket, the index of the matching
    /// close bracket; `sentinel` otherwise.
    close: []u32,
    out: *std.ArrayList(ParsedSymbol),
    /// Keyword set used by the C-family scanners (C/C++ vs C#) to skip control
    /// keywords when reading references and detecting member functions.
    ckw: KeywordSet = c_keywords,

    fn ch(self: *const Ctx, i: u32) u8 {
        const t = self.toks[i];
        return self.source[t.start];
    }

    fn isPunct(self: *const Ctx, i: u32, c: u8) bool {
        return self.toks[i].kind == .punct and self.ch(i) == c;
    }

    fn identEql(self: *const Ctx, i: u32, name: []const u8) bool {
        const t = self.toks[i];
        return t.kind == .identifier and std.mem.eql(u8, t.text(self.source), name);
    }

    fn textOf(self: *const Ctx, i: u32) []const u8 {
        return self.toks[i].text(self.source);
    }
};

/// Parse `source` for `lang`, appending discovered symbols to `out`.
/// `arena` owns the reference slices and lives as long as the graph.
pub fn parse(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    lang: language.Language,
    out: *std.ArrayList(ParsedSymbol),
) !void {
    std.debug.assert(source.len <= std.math.maxInt(u32));
    const cfg = language.configFor(lang);
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try lexer.tokenize(gpa, source, cfg, &toks);
    std.debug.assert(toks.items.len >= 1); // always an eof token

    const close = try buildMatches(gpa, source, toks.items);
    defer gpa.free(close);

    var ctx = Ctx{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .cfg = cfg,
        .toks = toks.items,
        .close = close,
        .out = out,
        .ckw = if (lang == .csharp) cs_keywords else c_keywords,
    };
    const n: u32 = @intCast(toks.items.len - 1); // exclude eof from scans
    switch (lang.family()) {
        .zig => try parseZigScope(&ctx, 0, n, null),
        .c, .csharp => try parseCScope(&ctx, 0, n, null),
        .js => try parseJsScope(&ctx, 0, n, null),
        .python => try parsePython(&ctx),
        .other => {},
    }
    try detectApi(&ctx, n);
}

// ---------------------------------------------------------------------------
// Cross-language API linking (see api.zig)
// ---------------------------------------------------------------------------

/// Post-pass: emit a `route` symbol for each HTTP route definition and attach a
/// `route_call` reference to every enclosing symbol that makes an HTTP client
/// call. `index.zig` later resolves those references to matching routes.
fn detectApi(ctx: *Ctx, n: u32) !void {
    const route_start: u32 = @intCast(ctx.out.items.len);
    // First pass: collect router variables that carry a mount prefix
    // (`admin_router = APIRouter(prefix="/api/admin")`).
    var prefixes = std.StringHashMap([]const u8).init(ctx.gpa);
    defer prefixes.deinit();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (api.matchRouterDecl(ctx.toks, ctx.source, i)) |rd|
            try prefixes.put(rd.name, rd.prefix);
    }
    i = 0;
    while (i < n) : (i += 1) {
        if (api.matchRouteDef(ctx.toks, ctx.source, i)) |rd| try emitRoute(ctx, rd, n, &prefixes);
    }
    var wrappers = try detectWrappers(ctx, route_start, n);
    defer wrappers.deinit();
    try attachClientCalls(ctx, route_start, n, &wrappers);
}

/// Names of request-wrapper functions in this file: a function whose body issues
/// a `fetch`/`axios` with a fully-dynamic URL (`` fetch(`${BASE}${path}`) ``).
/// A call to such a function forwards a path to fetch, so it is treated as a
/// client call to that path — this is what links a frontend that routes every
/// request through a generic `request(path)` helper to its backend routes.
fn detectWrappers(ctx: *Ctx, sym_hi: u32, n: u32) !std.StringHashMap(void) {
    var wrappers = std.StringHashMap(void).init(ctx.gpa);
    errdefer wrappers.deinit();
    if (ctx.cfg.language.family() != .js) return wrappers;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (!api.isDynamicFetch(ctx.toks, ctx.source, i)) continue;
        const owner = enclosingSymbol(ctx, ctx.toks[i].start, sym_hi) orelse continue;
        const sym = ctx.out.items[owner];
        if (sym.kind != .function and sym.kind != .method) continue;
        try wrappers.put(sym.name, {});
    }
    return wrappers;
}

/// The route endpoint with its router's mount prefix applied, when the receiver
/// (`admin_router`) was declared with one. Falls back to the bare endpoint.
fn prefixedEndpoint(ctx: *Ctx, rd: api.RouteDef, prefixes: *const std.StringHashMap([]const u8)) !api.Endpoint {
    const raw = ctx.textOf(rd.recv_i);
    const recv = if (raw.len != 0 and raw[0] == '@') raw[1..] else raw;
    const prefix = prefixes.get(recv) orelse return normEmptyPath(rd.endpoint);
    if (prefix.len == 0) return normEmptyPath(rd.endpoint);
    const path = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ prefix, rd.endpoint.path });
    return .{ .method = rd.endpoint.method, .path = path };
}

/// An unprefixed empty route path (`@app.get("")`) normalizes to "/".
fn normEmptyPath(ep: api.Endpoint) api.Endpoint {
    return if (ep.path.len == 0) .{ .method = ep.method, .path = "/" } else ep;
}

fn apiKey(ctx: *Ctx, ep: api.Endpoint) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ ep.method, ep.path });
}

fn emitRoute(ctx: *Ctx, rd: api.RouteDef, n: u32, prefixes: *const std.StringHashMap([]const u8)) !void {
    const close = ctx.close[rd.open_i];
    const span_start = lineStartOffset(ctx, rd.recv_i);
    const span_end = if (close != sentinel) ctx.toks[close].end else ctx.toks[rd.open_i].end;
    std.debug.assert(span_start <= span_end);
    var refs: []Reference = &.{};
    if (routeHandler(ctx, rd, n)) |name| {
        const r = try ctx.arena.alloc(Reference, 1);
        r[0] = .{ .name = name, .line = ctx.toks[rd.recv_i].line, .kind = .call };
        refs = r;
    }
    _ = try emit(ctx, .{
        .name = try apiKey(ctx, try prefixedEndpoint(ctx, rd, prefixes)),
        .kind = .route,
        .line = ctx.toks[rd.recv_i].line,
        .span_start = span_start,
        .span_end = span_end,
        .sig_end = span_end,
        .doc = "",
        .exported = true,
        .parent_local = null,
        .refs = refs,
    });
}

/// The handler name a route dispatches to: an Express identifier argument after
/// the path, or the `def`/`function` that follows a decorator.
fn routeHandler(ctx: *const Ctx, rd: api.RouteDef, n: u32) ?[]const u8 {
    // Decorator form (`@app.get(...)` immediately above a `def`/`function`): the
    // handler is the following definition. A decorator's own keyword arguments
    // (FastAPI's `response_model=Model`, `status_code=201`, …) are NOT handlers,
    // so we must never read a positional-looking identifier from the arg list
    // here — always scan forward to the real definition.
    if (routeIsDecorator(ctx, rd)) {
        const from = if (ctx.close[rd.open_i] != sentinel) ctx.close[rd.open_i] + 1 else rd.open_i + 1;
        var j = from;
        var scanned: u32 = 0;
        while (j < n and scanned < 24) : ({
            j += 1;
            scanned += 1;
        }) {
            if ((ctx.identEql(j, "def") or ctx.identEql(j, "function")) and
                j + 1 < n and ctx.toks[j + 1].kind == .identifier) return ctx.textOf(j + 1);
        }
        return null;
    }
    // Call-form route (`router.get("/x", listItems)`): the handler is a bare
    // identifier argument after the path. Exclude a Python-style keyword argument
    // (`name=value`) so decorator-less `.add_api_route`-ish kwargs aren't bound,
    // and reject an inline arrow/anonymous handler (`(req, res) => {...}`).
    const path_i = rd.open_i + 1;
    if (path_i + 3 < n and ctx.isPunct(path_i + 1, ',') and ctx.toks[path_i + 2].kind == .identifier) {
        const name = ctx.textOf(path_i + 2);
        if (!isDefKeyword(name) and !ctx.isPunct(path_i + 3, '=')) return name;
    }
    return null;
}

/// Whether the route at `rd` is decorator-form: `@recv.verb(...)` (the `@` is
/// glued to the receiver by the Python lexer, or a separate token before it).
fn routeIsDecorator(ctx: *const Ctx, rd: api.RouteDef) bool {
    const recv = ctx.textOf(rd.recv_i);
    if (recv.len != 0 and recv[0] == '@') return true;
    return rd.recv_i >= 1 and ctx.isPunct(rd.recv_i - 1, '@');
}

fn isDefKeyword(name: []const u8) bool {
    return std.mem.eql(u8, name, "async") or std.mem.eql(u8, name, "function") or
        std.mem.eql(u8, name, "def");
}

fn attachClientCalls(ctx: *Ctx, sym_hi: u32, n: u32, wrappers: *const std.StringHashMap(void)) !void {
    var extra = std.AutoHashMap(u32, std.ArrayList(Reference)).init(ctx.gpa);
    defer {
        var vit = extra.valueIterator();
        while (vit.next()) |v| v.deinit(ctx.gpa);
        extra.deinit();
    }
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ep = api.matchClientCall(ctx.toks, ctx.source, i) orelse
            api.matchWrapperCall(ctx.toks, ctx.source, i, wrappers) orelse continue;
        const owner = enclosingSymbol(ctx, ctx.toks[i].start, sym_hi) orelse continue;
        try addClientRef(ctx, &extra, owner, ep, ctx.toks[i].line);
    }
    try mergeExtraRefs(ctx, &extra);
}

fn addClientRef(
    ctx: *Ctx,
    extra: *std.AutoHashMap(u32, std.ArrayList(Reference)),
    owner: u32,
    ep: api.Endpoint,
    line: u32,
) !void {
    const gop = try extra.getOrPut(owner);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    const key = try apiKey(ctx, ep);
    for (gop.value_ptr.items) |r| if (std.mem.eql(u8, r.name, key)) return; // dedup
    try gop.value_ptr.append(ctx.gpa, .{ .name = key, .line = line, .kind = .route_call });
}

/// Rebuild each owner's ref slice as `old ++ client refs` (arena-owned).
fn mergeExtraRefs(ctx: *Ctx, extra: *std.AutoHashMap(u32, std.ArrayList(Reference))) !void {
    var it = extra.iterator();
    while (it.next()) |e| {
        const owner = e.key_ptr.*;
        const add = e.value_ptr.items;
        std.debug.assert(owner < ctx.out.items.len);
        const old = ctx.out.items[owner].refs;
        const merged = try ctx.arena.alloc(Reference, old.len + add.len);
        @memcpy(merged[0..old.len], old);
        @memcpy(merged[old.len..], add);
        ctx.out.items[owner].refs = merged;
    }
}

/// Innermost already-parsed symbol whose byte span contains `off` (indices
/// `[0, hi)` so freshly-appended route symbols are excluded).
fn enclosingSymbol(ctx: *const Ctx, off: u32, hi: u32) ?u32 {
    var best: ?u32 = null;
    var best_start: u32 = 0;
    var idx: u32 = 0;
    while (idx < hi) : (idx += 1) {
        const s = ctx.out.items[idx];
        if (off < s.span_start or off >= s.span_end) continue;
        if (best == null or s.span_start >= best_start) {
            best = idx;
            best_start = s.span_start;
        }
    }
    return best;
}

/// Build the bracket-matching table for `()`, `{}`, `[]`.
fn buildMatches(gpa: std.mem.Allocator, source: []const u8, toks: []const Token) ![]u32 {
    const close = try gpa.alloc(u32, toks.len);
    @memset(close, sentinel);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    for (toks, 0..) |t, i| {
        if (t.kind != .punct) continue;
        const c = source[t.start];
        switch (c) {
            '(', '{', '[' => try stack.append(gpa, @intCast(i)),
            ')', '}', ']' => {
                const open_i = stack.pop() orelse continue;
                if (bracketMatches(source[toks[open_i].start], c)) {
                    close[open_i] = @intCast(i);
                }
            },
            else => {},
        }
    }
    return close;
}

fn bracketMatches(open: u8, cl: u8) bool {
    return (open == '(' and cl == ')') or
        (open == '{' and cl == '}') or
        (open == '[' and cl == ']');
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn isComment(ctx: *const Ctx, i: u32) bool {
    return ctx.toks[i].kind == .comment;
}

/// The doc comment immediately preceding the definition token at `def_i`, as a
/// raw slice of the source (markers included). Empty when there is none.
fn collectDoc(ctx: *const Ctx, def_i: u32) []const u8 {
    if (def_i == 0) return "";
    const want_doc_only = ctx.cfg.doc_style == .zig_slashes;
    var first: u32 = def_i;
    var expected_line: u32 = ctx.toks[def_i].line;
    var i: i64 = @as(i64, def_i) - 1;
    while (i >= 0) : (i -= 1) {
        const idx: u32 = @intCast(i);
        if (!isComment(ctx, idx)) break;
        if (want_doc_only and !ctx.toks[idx].is_doc) break;
        if (ctx.toks[idx].line + 1 != expected_line) break;
        expected_line = ctx.toks[idx].line;
        first = idx;
    }
    if (first == def_i) return "";
    return ctx.source[ctx.toks[first].start..ctx.toks[def_i - 1].end];
}

/// Line-start offset of the token at index `i` (column 0 of its line).
fn lineStartOffset(ctx: *const Ctx, i: u32) u32 {
    const t = ctx.toks[i];
    std.debug.assert(t.start >= t.col);
    return t.start - t.col;
}

/// The first non-comment token at or after `i`. A statement's `stmt_start` can
/// point at a leading doc comment (kept so `collectDoc` can find it); using this
/// for `span_start` excludes that comment from the definition's span, so the span
/// begins on the definition's own line (keeping `line`..`endLine` accurate and
/// not duplicating the doc in `-v full`).
fn firstCodeToken(ctx: *const Ctx, i: u32) u32 {
    var j = i;
    while (j < ctx.toks.len and ctx.toks[j].kind == .comment) j += 1;
    return j;
}

const KeywordSet = std.StaticStringMap(void);

/// Collect deduplicated references from the token range [lo, hi).
fn collectRefs(ctx: *Ctx, params_open: u32, lo: u32, hi: u32, self_name: []const u8, kw: KeywordSet) !BodyInfo {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= ctx.toks.len);
    var seen: std.StringHashMap(u32) = .init(ctx.gpa);
    defer {
        var kit = seen.keyIterator();
        while (kit.next()) |k| ctx.gpa.free(k.*);
        seen.deinit();
    }
    var refs: std.ArrayList(Reference) = .empty;
    defer refs.deinit(ctx.gpa);
    // Distinct call-site lines per ref, aligned index-for-index with `refs`, so a
    // reference to the same name on several lines keeps all of them (not just the
    // first). Attached to each ref below and duped into the arena.
    var line_lists: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (line_lists.items) |*ll| ll.deinit(ctx.gpa);
        line_lists.deinit(ctx.gpa);
    }

    var i = lo;
    while (i < hi) : (i += 1) {
        const t = ctx.toks[i];
        if (t.kind != .identifier) continue;
        const name = t.text(ctx.source);
        if (name.len < 2 or kw.has(name)) continue;
        const qualifier = memberQualifier(ctx, i, lo);
        // Skip only a *bare* self-reference (recursion noise). A qualified call
        // like `other.foo()` from inside `foo` is a real edge to keep.
        if (qualifier.len == 0 and std.mem.eql(u8, name, self_name)) continue;
        const is_call = i + 1 < hi and ctx.isPunct(i + 1, '(');
        try recordRef(ctx, &refs, &line_lists, &seen, name, qualifier, t.line, is_call);
    }
    // Keep the distinct-line list only when a ref spans more than one line; a
    // single-site ref falls back to `line` and needs no allocation.
    for (refs.items, line_lists.items) |*r, ll| {
        if (ll.items.len > 1) r.lines = try ctx.arena.dupe(u32, ll.items);
    }
    return .{
        .refs = try ctx.arena.dupe(Reference, refs.items),
        .bindings = try collectBindings(ctx, params_open, lo, hi),
    };
}

/// If token `i` is the trailing member of a member access, return the receiver
/// identifier; otherwise "". Recognizes `recv.name` (all languages) and the
/// C/C++ two-punct operators `recv->name` and `Scope::name`, so instance and
/// static dispatch there is visible to resolution. `lo` bounds the body start.
fn memberQualifier(ctx: *const Ctx, i: u32, lo: u32) []const u8 {
    // `recv.name`
    if (i >= lo + 2 and ctx.isPunct(i - 1, '.') and ctx.toks[i - 2].kind == .identifier)
        return ctx.textOf(i - 2);
    // Two-punct member operators, receiver two tokens back:
    //   `recv?.name` / `recv!.name` — JS/TS optional-chaining & non-null assertion
    //   `recv->name`                — C/C++ pointer member
    //   `Scope::name`               — C++ scope resolution
    if (i >= lo + 3 and ctx.toks[i - 3].kind == .identifier) {
        if (ctx.isPunct(i - 1, '.') and (ctx.isPunct(i - 2, '?') or ctx.isPunct(i - 2, '!')))
            return ctx.textOf(i - 3);
        if (ctx.isPunct(i - 1, '>') and ctx.isPunct(i - 2, '-')) return ctx.textOf(i - 3);
        if (ctx.isPunct(i - 1, ':') and ctx.isPunct(i - 2, ':')) return ctx.textOf(i - 3);
    }
    return "";
}

fn recordRef(
    ctx: *Ctx,
    refs: *std.ArrayList(Reference),
    line_lists: *std.ArrayList(std.ArrayList(u32)),
    seen: *std.StringHashMap(u32),
    name: []const u8,
    qualifier: []const u8,
    line: u32,
    is_call: bool,
) !void {
    // Dedup on (qualifier, name) so `a.foo()` and `b.foo()` stay distinct.
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ qualifier, name }) catch name;
    if (seen.get(key)) |idx| {
        var r = &refs.items[idx];
        r.count += 1;
        if (is_call) r.kind = .call;
        // Record a new distinct call-site line. Tokens are scanned in source
        // order, so lines are non-decreasing — compare against the last kept.
        const ll = &line_lists.items[idx];
        if (ll.items.len == 0 or ll.items[ll.items.len - 1] != line) try ll.append(ctx.gpa, line);
        return;
    }
    try seen.put(try ctx.gpa.dupe(u8, key), @intCast(refs.items.len));
    try refs.append(ctx.gpa, .{
        .name = name,
        .qualifier = qualifier,
        .line = line,
        .kind = if (is_call) .call else .read,
        .count = 1,
    });
    var ll: std.ArrayList(u32) = .empty;
    try ll.append(ctx.gpa, line);
    try line_lists.append(ctx.gpa, ll);
}

/// Factory-method names whose receiver is the constructed type: `T.init(...)`.
const factory_names = std.StaticStringMap(void).initComptime(.{
    .{"init"}, .{"create"}, .{"new"}, .{"from"}, .{"default"}, .{"make"},
});

/// Scan a body for `const/var/let NAME [: T] = ...` and `NAME = T(...)` and
/// record inferred `NAME -> T` bindings used for receiver resolution.
fn collectBindings(ctx: *Ctx, params_open: u32, lo: u32, hi: u32) ![]const Binding {
    var list: std.ArrayList(Binding) = .empty;
    defer list.deinit(ctx.gpa);
    if (params_open != sentinel) try collectParamBindings(ctx, params_open, &list);
    var i = lo;
    while (i < hi) : (i += 1) {
        const b = detectBinding(ctx, i, hi, lo) orelse continue;
        try list.append(ctx.gpa, b);
    }
    return ctx.arena.dupe(Binding, list.items);
}

/// Record `name -> Type` for each typed parameter `name: Type` in `(...)`.
fn collectParamBindings(ctx: *Ctx, open: u32, list: *std.ArrayList(Binding)) !void {
    const close = ctx.close[open];
    if (close == sentinel) return;
    var expect_name = true;
    var i = open + 1;
    while (i < close) {
        if (ctx.isPunct(i, '(') or ctx.isPunct(i, '[') or ctx.isPunct(i, '{')) {
            const c = ctx.close[i];
            i = if (c == sentinel or c >= close) i + 1 else c + 1;
            expect_name = false;
            continue;
        }
        if (ctx.isPunct(i, ',')) {
            expect_name = true;
            i += 1;
            continue;
        }
        if (expect_name and ctx.toks[i].kind == .identifier and ctx.isPunct(i + 1, ':')) {
            if (typeFromChain(ctx, i + 2, close)) |ty| {
                try list.append(ctx.gpa, .{ .name = ctx.textOf(i), .type_name = ty });
            }
        }
        expect_name = false;
        i += 1;
    }
}

fn detectBinding(ctx: *const Ctx, i: u32, hi: u32, lo: u32) ?Binding {
    const t = ctx.toks[i];
    if (t.kind != .identifier) return null;
    const is_decl = ctx.identEql(i, "const") or ctx.identEql(i, "var") or ctx.identEql(i, "let");
    if (is_decl) {
        if (i + 1 >= hi or ctx.toks[i + 1].kind != .identifier) return null;
        const ty = inferDeclType(ctx, i + 1, hi) orelse return null;
        return .{ .name = ctx.textOf(i + 1), .type_name = ty };
    }
    // Bare assignment at line start: `name = Type(...)` (python/js).
    const first_on_line = i == lo or ctx.toks[i - 1].line != t.line;
    if (!first_on_line or !ctx.isPunct(i + 1, '=') or ctx.isPunct(i + 2, '=')) return null;
    const ty = typeFromRhs(ctx, i + 2, hi) orelse return null;
    return .{ .name = ctx.textOf(i), .type_name = ty };
}

/// Type for `NAME : T = ...` (annotation) or `NAME = T(...)` (initializer).
fn inferDeclType(ctx: *const Ctx, name_i: u32, hi: u32) ?[]const u8 {
    const j = name_i + 1;
    if (ctx.isPunct(j, ':')) return typeFromChain(ctx, j + 1, hi);
    if (ctx.isPunct(j, '=')) return typeFromRhs(ctx, j + 1, hi);
    return null;
}

/// Last identifier of a leading dotted chain `A(.B)*`, skipping `*?[]&` prefixes.
fn typeFromChain(ctx: *const Ctx, start: u32, hi: u32) ?[]const u8 {
    var i = start;
    while (i < hi and ctx.toks[i].kind != .identifier) : (i += 1) {
        if (ctx.isPunct(i, '(') or ctx.isPunct(i, '=') or ctx.isPunct(i, ';')) return null;
    }
    var last: ?u32 = null;
    while (i < hi and ctx.toks[i].kind == .identifier) {
        last = i;
        if (!ctx.isPunct(i + 1, '.')) break;
        i += 2;
    }
    return if (last) |l| ctx.textOf(l) else null;
}

/// Type produced by an initializer expression: the constructed type in
/// `T(...)`, `T{...}`, `new T(...)`, or `T.init(...)` (factory).
fn typeFromRhs(ctx: *const Ctx, start: u32, hi: u32) ?[]const u8 {
    var i = start;
    while (i < hi and isRhsSkip(ctx, i)) : (i += 1) {}
    var segs: [8]u32 = undefined;
    var n: usize = 0;
    while (i < hi and ctx.toks[i].kind == .identifier and n < segs.len) {
        segs[n] = i;
        n += 1;
        if (!ctx.isPunct(i + 1, '.')) break;
        i += 2;
    }
    if (n == 0) return null;
    const after = segs[n - 1] + 1;
    if (ctx.isPunct(after, '{')) return ctx.textOf(segs[n - 1]);
    if (!ctx.isPunct(after, '(')) return null;
    if (n >= 2 and factory_names.has(ctx.textOf(segs[n - 1]))) return ctx.textOf(segs[n - 2]);
    return ctx.textOf(segs[n - 1]);
}

fn isRhsSkip(ctx: *const Ctx, i: u32) bool {
    return ctx.identEql(i, "new") or ctx.identEql(i, "try") or
        ctx.identEql(i, "await") or ctx.identEql(i, "comptime");
}

fn emit(ctx: *Ctx, sym: ParsedSymbol) !u32 {
    std.debug.assert(sym.span_start <= sym.sig_end);
    std.debug.assert(sym.sig_end <= sym.span_end);
    const idx: u32 = @intCast(ctx.out.items.len);
    try ctx.out.append(ctx.gpa, sym);
    return idx;
}

// ---------------------------------------------------------------------------
// Zig
// ---------------------------------------------------------------------------

const zig_keywords = KeywordSet.initComptime(.{
    .{"const"}, .{"var"},   .{"fn"},     .{"pub"},    .{"return"}, .{"if"},
    .{"else"},  .{"while"}, .{"for"},    .{"switch"}, .{"struct"}, .{"enum"},
    .{"union"}, .{"try"},   .{"catch"},  .{"defer"},  .{"errdefer"}, .{"comptime"},
    .{"inline"},.{"and"},   .{"or"},     .{"orelse"}, .{"test"},   .{"error"},
    .{"break"}, .{"continue"}, .{"opaque"}, .{"extern"}, .{"export"}, .{"usingnamespace"},
    .{"anytype"}, .{"void"}, .{"unreachable"},
});

fn parseZigScope(ctx: *Ctx, lo: u32, hi: u32, parent: ?u32) AllocError!void {
    var i = lo;
    var at_stmt = true;
    while (i < hi) {
        const t = ctx.toks[i];
        if (t.kind == .comment) {
            i += 1;
            continue;
        }
        if (t.kind == .punct) {
            const c = ctx.ch(i);
            if (c == '{' or c == '(' or c == '[') {
                i = skipBracket(ctx, i);
                at_stmt = c == '{';
                continue;
            }
            at_stmt = c == ';' or c == '}' or c == ',';
            i += 1;
            continue;
        }
        if (at_stmt and t.kind == .identifier) {
            const consumed = try parseZigDecl(ctx, i, hi, parent);
            if (consumed > i) {
                i = consumed;
                at_stmt = true;
                continue;
            }
        }
        at_stmt = false;
        i += 1;
    }
}

/// Returns the token index just past the declaration starting at/near `i`, or
/// `i` itself when no declaration was recognised.
fn parseZigDecl(ctx: *Ctx, i: u32, hi: u32, parent: ?u32) !u32 {
    const exported = ctx.identEql(i, "pub");
    var k = i;
    while (k < hi and isZigModifier(ctx, k)) k += 1;
    if (k >= hi or ctx.toks[k].kind != .identifier) return i;

    if (ctx.identEql(k, "fn")) return parseZigFn(ctx, i, k, hi, parent, exported);
    if (ctx.identEql(k, "const") or ctx.identEql(k, "var")) {
        return parseZigConst(ctx, i, k, hi, parent, exported);
    }
    return i;
}

fn isZigModifier(ctx: *const Ctx, i: u32) bool {
    return ctx.identEql(i, "pub") or ctx.identEql(i, "export") or
        ctx.identEql(i, "extern") or ctx.identEql(i, "inline") or
        ctx.identEql(i, "threadlocal") or ctx.identEql(i, "comptime");
}

fn parseZigFn(ctx: *Ctx, start_i: u32, fn_i: u32, hi: u32, parent: ?u32, exported: bool) !u32 {
    if (fn_i + 1 >= hi or ctx.toks[fn_i + 1].kind != .identifier) return start_i;
    const name_i = fn_i + 1;
    if (fn_i + 2 >= hi or !ctx.isPunct(fn_i + 2, '(')) return start_i;
    const params_close = ctx.close[fn_i + 2];
    if (params_close == sentinel) return start_i;

    const body_open = findNext(ctx, params_close + 1, hi, '{');
    const kind: SymbolKind = if (parent != null) .method else .function;
    const span_start = lineStartOffset(ctx, start_i);
    var sig_end: u32 = undefined;
    var span_end: u32 = undefined;
    var body_lo: u32 = 0;
    var body_hi: u32 = 0;
    if (body_open != sentinel and ctx.close[body_open] != sentinel) {
        const body_close = ctx.close[body_open];
        sig_end = ctx.toks[body_open].start;
        span_end = ctx.toks[body_close].end;
        body_lo = body_open + 1;
        body_hi = body_close;
    } else {
        const semi = findNext(ctx, params_close + 1, hi, ';');
        const end_i = if (semi != sentinel) semi else params_close;
        sig_end = ctx.toks[end_i].end;
        span_end = sig_end;
    }
    const body = try collectRefs(ctx, fn_i + 2, body_lo, body_hi, ctx.textOf(name_i), zig_keywords);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = span_start,
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return if (span_end > ctx.toks[start_i].start) tokenAfterOffset(ctx, span_end, hi) else start_i + 1;
}

fn parseZigConst(ctx: *Ctx, start_i: u32, kw_i: u32, hi: u32, parent: ?u32, exported: bool) !u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return start_i;
    const name_i = kw_i + 1;
    const eq_i = findNext(ctx, name_i + 1, hi, '=');
    const semi_i = findNext(ctx, name_i + 1, hi, ';');
    const span_start = lineStartOffset(ctx, start_i);

    // Detect container types: `= struct {` / enum / union / opaque.
    const container = detectZigContainer(ctx, eq_i, hi);
    if (container.open != sentinel) {
        return emitZigContainer(ctx, .{
            .start_i = start_i,
            .name_i = name_i,
            .open = container.open,
            .kind = container.kind,
            .parent = parent,
            .exported = exported,
            .hi = hi,
        });
    }

    const end_i = if (semi_i != sentinel) semi_i else name_i;
    const span_end = ctx.toks[end_i].end;

    // `const NAME = @import("PATH");` — a module binding, not a plain const.
    if (zigImportPath(ctx, eq_i, hi)) |mod_path| {
        _ = try emit(ctx, importSymbol(ctx.textOf(name_i), mod_path, ctx.toks[name_i].line, span_start, span_end));
        return tokenAfterOffset(ctx, span_end, hi);
    }

    const is_fn_val = eq_i != sentinel and eq_i + 1 < hi and ctx.identEql(eq_i + 1, "fn");
    const kind: SymbolKind = if (is_fn_val) .function else if (ctx.identEql(kw_i, "const")) .constant else .variable;
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = span_start,
        .span_end = span_end,
        .sig_end = span_end,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    return tokenAfterOffset(ctx, span_end, hi);
}

/// If the RHS at `= @import("PATH")` is a Zig import, return `PATH`.
fn zigImportPath(ctx: *const Ctx, eq_i: u32, hi: u32) ?[]const u8 {
    if (eq_i == sentinel or eq_i + 3 >= hi) return null;
    if (!ctx.identEql(eq_i + 1, "@import")) return null;
    if (!ctx.isPunct(eq_i + 2, '(') or ctx.toks[eq_i + 3].kind != .string) return null;
    return stripQuotes(ctx.textOf(eq_i + 3));
}

/// Build a `.import` ParsedSymbol binding `name` to module `path`.
fn importSymbol(name: []const u8, path: []const u8, line: u32, span_start: u32, span_end: u32) ParsedSymbol {
    std.debug.assert(span_start <= span_end);
    return .{
        .name = name,
        .kind = .import,
        .line = line,
        .span_start = span_start,
        .span_end = span_end,
        .sig_end = span_end,
        .doc = "",
        .exported = false,
        .parent_local = null,
        .refs = &.{},
        .import_path = path,
    };
}

const ZigContainer = struct { open: u32, kind: SymbolKind };

fn detectZigContainer(ctx: *const Ctx, eq_i: u32, hi: u32) ZigContainer {
    if (eq_i == sentinel) return .{ .open = sentinel, .kind = .type };
    var j = eq_i + 1;
    // Allow `packed`/`extern` before struct/union/enum.
    while (j < hi and (ctx.identEql(j, "packed") or ctx.identEql(j, "extern"))) j += 1;
    if (j >= hi) return .{ .open = sentinel, .kind = .type };
    const kind: SymbolKind = if (ctx.identEql(j, "struct"))
        .@"struct"
    else if (ctx.identEql(j, "enum"))
        .@"enum"
    else if (ctx.identEql(j, "union"))
        .@"struct"
    else if (ctx.identEql(j, "opaque"))
        .@"struct"
    else
        return .{ .open = sentinel, .kind = .type };
    const open = findNext(ctx, j + 1, hi, '{');
    return .{ .open = open, .kind = kind };
}

const EmitContainer = struct {
    start_i: u32,
    name_i: u32,
    open: u32,
    kind: SymbolKind,
    parent: ?u32,
    exported: bool,
    hi: u32,
};

fn emitZigContainer(ctx: *Ctx, a: EmitContainer) !u32 {
    const close = ctx.close[a.open];
    if (close == sentinel) return a.start_i + 1;
    const span_start = lineStartOffset(ctx, a.start_i);
    const my_idx = try emit(ctx, .{
        .name = ctx.textOf(a.name_i),
        .kind = a.kind,
        .line = ctx.toks[a.name_i].line,
        .span_start = span_start,
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[a.open].start,
        .doc = collectDoc(ctx, a.start_i),
        .exported = a.exported,
        .parent_local = a.parent,
        .refs = &.{},
    });
    try parseZigScope(ctx, a.open + 1, close, my_idx);
    return close + 1;
}

// ---------------------------------------------------------------------------
// Scan utilities
// ---------------------------------------------------------------------------

/// Skip a matched bracket starting at `i`; returns the index just past it.
fn skipBracket(ctx: *const Ctx, i: u32) u32 {
    const c = ctx.close[i];
    return if (c == sentinel) i + 1 else c + 1;
}

/// Find the next top-level punctuation `c` in [from, hi), skipping nested
/// brackets. Returns `sentinel` when not found.
fn findNext(ctx: *const Ctx, from: u32, hi: u32, c: u8) u32 {
    var i = from;
    while (i < hi) {
        if (ctx.isPunct(i, c)) return i;
        if (ctx.isPunct(i, '(') or ctx.isPunct(i, '{') or ctx.isPunct(i, '[')) {
            i = skipBracket(ctx, i);
            continue;
        }
        i += 1;
    }
    return sentinel;
}

/// Index of the first token starting at or after `offset`, bounded by `hi`.
fn tokenAfterOffset(ctx: *const Ctx, offset: u32, hi: u32) u32 {
    var lo: u32 = 0;
    var high: u32 = @intCast(ctx.toks.len);
    while (lo < high) {
        const mid = lo + (high - lo) / 2;
        if (ctx.toks[mid].start < offset) lo = mid + 1 else high = mid;
    }
    return @min(@max(lo, 0), hi);
}

// ---------------------------------------------------------------------------
// C / C++
// ---------------------------------------------------------------------------

const c_keywords = KeywordSet.initComptime(.{
    .{"if"},     .{"else"},   .{"for"},    .{"while"},  .{"return"}, .{"switch"},
    .{"case"},   .{"break"},  .{"continue"}, .{"struct"}, .{"enum"}, .{"union"},
    .{"typedef"}, .{"static"}, .{"const"},  .{"void"},   .{"int"},   .{"char"},
    .{"float"},  .{"double"}, .{"unsigned"}, .{"signed"}, .{"long"}, .{"short"},
    .{"sizeof"}, .{"goto"},   .{"do"},     .{"extern"}, .{"inline"}, .{"register"},
    .{"volatile"}, .{"class"}, .{"public"}, .{"private"}, .{"namespace"}, .{"template"},
});

/// C# control/type/modifier keywords — kept apart from `c_keywords` so the shared
/// C-family scanners skip C#-specific keywords when reading a body's references
/// and detecting member functions.
const cs_keywords = KeywordSet.initComptime(.{
    .{"if"},      .{"else"},    .{"for"},      .{"foreach"}, .{"while"},   .{"do"},
    .{"return"},  .{"switch"},  .{"case"},     .{"break"},   .{"continue"}, .{"goto"},
    .{"using"},   .{"namespace"}, .{"class"},  .{"struct"},  .{"interface"}, .{"enum"},
    .{"record"},  .{"public"},  .{"private"},  .{"protected"}, .{"internal"}, .{"static"},
    .{"readonly"}, .{"const"},  .{"virtual"},  .{"override"}, .{"abstract"}, .{"sealed"},
    .{"async"},   .{"await"},   .{"new"},      .{"this"},    .{"base"},    .{"var"},
    .{"void"},    .{"int"},     .{"string"},   .{"bool"},    .{"double"},  .{"float"},
    .{"long"},    .{"short"},   .{"byte"},     .{"char"},    .{"object"},  .{"decimal"},
    .{"true"},    .{"false"},   .{"null"},     .{"is"},      .{"as"},      .{"typeof"},
    .{"try"},     .{"catch"},   .{"finally"},  .{"throw"},   .{"yield"},   .{"ref"},
    .{"out"},     .{"in"},      .{"where"},    .{"get"},     .{"set"},     .{"partial"},
});

fn parseCScope(ctx: *Ctx, lo: u32, hi: u32, parent: ?u32) AllocError!void {
    var stmt_start = lo;
    var i = lo;
    while (i < hi) {
        if (ctx.isPunct(i, '#')) {
            i = try parseCPreproc(ctx, i, hi);
            stmt_start = i;
            continue;
        }
        if (ctx.isPunct(i, ';') or ctx.isPunct(i, '}')) {
            i += 1;
            stmt_start = i;
            continue;
        }
        if (ctx.cfg.language == .csharp) {
            // `using X;` / `global using X;` directives are C#'s imports.
            var u = i;
            if (ctx.identEql(u, "global")) u += 1;
            if (ctx.identEql(u, "using") and !ctx.isPunct(u + 1, '(')) {
                i = try parseCsUsing(ctx, u, hi);
                stmt_start = i;
                continue;
            }
        }
        if (ctx.identEql(i, "namespace")) {
            const adv = try parseCppNamespace(ctx, i, hi, parent);
            if (adv > i) {
                i = adv;
                stmt_start = i;
                continue;
            }
        }
        if (ctx.identEql(i, "struct") or ctx.identEql(i, "enum") or
            ctx.identEql(i, "union") or ctx.identEql(i, "class") or
            ctx.identEql(i, "interface"))
        {
            const adv = try parseCRecord(ctx, stmt_start, i, hi, parent);
            if (adv > i) {
                i = adv;
                stmt_start = i;
                continue;
            }
        }
        if (ctx.toks[i].kind == .identifier and i + 1 < hi and ctx.isPunct(i + 1, '(')) {
            const adv = try tryCFunction(ctx, stmt_start, i, hi, parent);
            if (adv > i) {
                i = adv;
                stmt_start = i;
                continue;
            }
        }
        if (ctx.isPunct(i, '{') or ctx.isPunct(i, '(') or ctx.isPunct(i, '[')) {
            i = skipBracket(ctx, i);
            continue;
        }
        i += 1;
    }
}

fn parseCPreproc(ctx: *Ctx, hash_i: u32, hi: u32) !u32 {
    // `#define NAME` → macro. Consume to end of (possibly continued) line.
    if (hash_i + 2 < hi and ctx.identEql(hash_i + 1, "define") and ctx.toks[hash_i + 2].kind == .identifier) {
        const name_i = hash_i + 2;
        const line_start = lineStartOffset(ctx, hash_i);
        const end = lineEndOffset(ctx, ctx.toks[name_i].start);
        _ = try emit(ctx, .{
            .name = ctx.textOf(name_i),
            .kind = .macro,
            .line = ctx.toks[name_i].line,
            .span_start = line_start,
            .span_end = end,
            .sig_end = end,
            .doc = collectDoc(ctx, hash_i),
            .exported = true,
            .parent_local = null,
            .refs = &.{},
        });
    }
    // Skip the whole preprocessor line.
    const line = ctx.toks[hash_i].line;
    var i = hash_i + 1;
    while (i < hi and ctx.toks[i].line == line) i += 1;
    return i;
}

/// A C# `using` directive: `using System;`, `using System.Text;`, `using static
/// System.Math;`, or an alias `using Json = System.Text.Json;`. Emits an import
/// symbol whose `import_path` is the referenced namespace/type and whose binding
/// is the alias name (empty for a plain directive). `kw_i` is the `using` token.
fn parseCsUsing(ctx: *Ctx, kw_i: u32, hi: u32) AllocError!u32 {
    const line = ctx.toks[kw_i].line;
    var start = kw_i + 1;
    if (ctx.identEql(start, "static")) start += 1;
    // Scan to the terminating `;` (staying on the same line as a safety bound).
    var semi = start;
    while (semi < hi and !ctx.isPunct(semi, ';') and ctx.toks[semi].line == line) semi += 1;
    if (semi <= start) return semi + 1;
    var alias: []const u8 = "";
    var path_start = start;
    if (ctx.toks[start].kind == .identifier and start + 1 < semi and ctx.isPunct(start + 1, '=')) {
        alias = ctx.textOf(start);
        path_start = start + 2;
    }
    if (path_start < semi and ctx.toks[path_start].kind == .identifier) {
        const path = ctx.source[ctx.toks[path_start].start..ctx.toks[semi - 1].end];
        _ = try emit(ctx, importSymbol(alias, path, line, lineStartOffset(ctx, kw_i), ctx.toks[semi - 1].end));
    }
    return if (semi < hi) semi + 1 else semi;
}

/// `namespace [A::B] { ... }` — recurse transparently so members stay top-level,
/// and emit the (last-named) namespace as a module symbol for outline visibility.
/// Returns `kw_i` (no advance) for `using namespace X;` and other non-block forms.
fn parseCppNamespace(ctx: *Ctx, kw_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    var open = kw_i + 1;
    var name_i: ?u32 = null;
    if (open < hi and ctx.toks[open].kind == .identifier) {
        name_i = open;
        open += 1;
    }
    // Qualified name: C++ `namespace A::B { ... }` or C# `namespace A.B { ... }`.
    while (open < hi) {
        const sep: u32 = if (open + 1 < hi and ctx.isPunct(open, ':') and ctx.isPunct(open + 1, ':'))
            2
        else if (ctx.cfg.language == .csharp and ctx.isPunct(open, '.'))
            1
        else
            break;
        open += sep;
        if (open < hi and ctx.toks[open].kind == .identifier) {
            name_i = open;
            open += 1;
        }
    }
    // C# file-scoped namespace: `namespace App.Web;` — emit a module symbol and
    // let the remaining top-level declarations parse as its (transparent) members.
    if (ctx.cfg.language == .csharp and open < hi and ctx.isPunct(open, ';')) {
        if (name_i) |ni| {
            _ = try emit(ctx, .{
                .name = ctx.textOf(ni),
                .kind = .module,
                .line = ctx.toks[ni].line,
                .span_start = lineStartOffset(ctx, kw_i),
                .span_end = ctx.toks[open].end,
                .sig_end = ctx.toks[open].start,
                .doc = collectDoc(ctx, kw_i),
                .exported = true,
                .parent_local = parent,
                .refs = &.{},
            });
        }
        return open + 1;
    }
    if (open >= hi or !ctx.isPunct(open, '{')) return kw_i;
    const close = ctx.close[open];
    if (close == sentinel) return kw_i;
    if (name_i) |ni| {
        _ = try emit(ctx, .{
            .name = ctx.textOf(ni),
            .kind = .module,
            .line = ctx.toks[ni].line,
            .span_start = lineStartOffset(ctx, kw_i),
            .span_end = ctx.toks[close].end,
            .sig_end = ctx.toks[open].start,
            .doc = collectDoc(ctx, kw_i),
            .exported = true,
            .parent_local = parent,
            .refs = &.{},
        });
    }
    try parseCScope(ctx, open + 1, close, parent); // transparent scope
    return close + 1;
}

fn parseCRecord(ctx: *Ctx, stmt_start: u32, kw_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return kw_i;
    const name_i = kw_i + 1;
    // The body `{` must come before any `;` (forward decl / typed variable) and
    // before any `(` (a function returning the type). Inheritance is allowed:
    // `class C : public B { ... }`.
    const open = findNext(ctx, name_i + 1, hi, '{');
    if (open == sentinel or ctx.close[open] == sentinel) return kw_i;
    const semi = findNext(ctx, name_i + 1, hi, ';');
    if (semi != sentinel and semi < open) return kw_i;
    const paren = findNext(ctx, name_i + 1, hi, '(');
    if (paren != sentinel and paren < open) return kw_i;
    const close = ctx.close[open];
    const kind: SymbolKind = if (ctx.identEql(kw_i, "enum"))
        .@"enum"
    else if (ctx.identEql(kw_i, "class"))
        .class
    else if (ctx.identEql(kw_i, "interface"))
        .interface
    else
        .@"struct";
    const my_idx = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, firstCodeToken(ctx, stmt_start)),
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[open].start,
        .doc = collectDoc(ctx, stmt_start),
        .exported = true,
        .parent_local = parent,
        .refs = &.{},
    });
    // C++ class/struct bodies hold methods; C# class/struct/interface bodies do
    // too. Parse them as members (enums do not hold methods).
    const parses_members = ctx.cfg.language == .cpp or ctx.cfg.language == .csharp;
    if (parses_members and kind != .@"enum") {
        try parseCppMembers(ctx, open + 1, close, my_idx);
    }
    return close + 1;
}

/// Parse the members of a C++ class/struct body [lo, hi): method definitions and
/// declarations, plus nested records. Fields and member initializers are skipped.
fn parseCppMembers(ctx: *Ctx, lo: u32, hi: u32, parent: u32) AllocError!void {
    var i = lo;
    var stmt_start = lo;
    while (i < hi) {
        if (ctx.isPunct(i, ';') or ctx.isPunct(i, '}') or ctx.isPunct(i, ':')) {
            i += 1;
            stmt_start = i;
            continue;
        }
        if (ctx.identEql(i, "struct") or ctx.identEql(i, "class") or
            ctx.identEql(i, "enum") or ctx.identEql(i, "union") or
            ctx.identEql(i, "interface"))
        {
            const adv = try parseCRecord(ctx, stmt_start, i, hi, parent);
            if (adv > i) {
                i = adv;
                stmt_start = i;
                continue;
            }
        }
        // A member function: `NAME ( ... )` where NAME is not a keyword and there
        // is no `=` since the member-statement start (a field initializer
        // `int x = f();` must not be read as a method named `f`).
        if (ctx.toks[i].kind == .identifier and !ctx.ckw.has(ctx.textOf(i)) and
            i + 1 < hi and ctx.isPunct(i + 1, '(') and !hasAssignBetween(ctx, stmt_start, i))
        {
            const adv = try tryCppMethod(ctx, i, hi, parent);
            if (adv > i) {
                i = adv;
                stmt_start = i;
                continue;
            }
        }
        if (ctx.isPunct(i, '{') or ctx.isPunct(i, '(') or ctx.isPunct(i, '[')) {
            i = skipBracket(ctx, i);
            continue;
        }
        i += 1;
    }
}

fn hasAssignBetween(ctx: *const Ctx, lo: u32, hi: u32) bool {
    var j = lo;
    while (j < hi) : (j += 1) {
        if (ctx.toks[j].kind == .punct and ctx.ch(j) == '=') return true;
    }
    return false;
}

/// A C++ member function (definition `{...}` or declaration `;`) whose name is at
/// `name_i` and params open at `name_i + 1`. Returns the index just past it.
fn tryCppMethod(ctx: *Ctx, name_i: u32, hi: u32, parent: u32) AllocError!u32 {
    const params_open = name_i + 1;
    const params_close = ctx.close[params_open];
    if (params_close == sentinel) return name_i;
    const body_open = cBodyOpen(ctx, params_close, hi);
    if (body_open != sentinel) {
        const body_close = ctx.close[body_open];
        if (body_close == sentinel) return name_i;
        const body = try collectRefs(ctx, params_open, body_open + 1, body_close, ctx.textOf(name_i), ctx.ckw);
        _ = try emit(ctx, .{
            .name = ctx.textOf(name_i),
            .kind = .method,
            .line = ctx.toks[name_i].line,
            .span_start = lineStartOffset(ctx, name_i),
            .span_end = ctx.toks[body_close].end,
            .sig_end = ctx.toks[body_open].start,
            .doc = collectDoc(ctx, name_i),
            .exported = true,
            .parent_local = parent,
            .refs = body.refs,
            .bindings = body.bindings,
        });
        return body_close + 1;
    }
    // Declaration `NAME(params) [qualifiers] ;`
    const semi = declEnd(ctx, params_close, hi);
    if (semi == sentinel) return name_i;
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .method,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, name_i),
        .span_end = ctx.toks[semi].end,
        .sig_end = ctx.toks[params_close].end,
        .doc = collectDoc(ctx, name_i),
        .exported = true,
        .parent_local = parent,
        .refs = &.{},
    });
    return semi + 1;
}

/// The `{` opening a function body after a parameter list closing at
/// `params_close`, skipping trailing qualifiers (`const`, `noexcept`,
/// `override`, `final`) and a C++ constructor member-initializer list
/// (`: a(1), b(2)`). `sentinel` when the next token is not such a body.
fn cBodyOpen(ctx: *const Ctx, params_close: u32, hi: u32) u32 {
    var j = params_close + 1;
    var guard: u32 = 0;
    while (j < hi and guard < 6) : ({
        j += 1;
        guard += 1;
    }) {
        if (ctx.isPunct(j, '{')) return j;
        // Constructor init list `C(...) : field(x) { ... }` (C++) or a C# member
        // initializer / generic constraint `M<T>(...) where T : X { ... }`: the
        // body is the next top-level `{` (bracket-aware, so `field(x)` is skipped).
        if ((ctx.cfg.language == .cpp or ctx.cfg.language == .csharp) and
            ctx.isPunct(j, ':') and !ctx.isPunct(j + 1, ':'))
        {
            return findNext(ctx, j + 1, hi, '{');
        }
        if (ctx.toks[j].kind == .identifier) continue; // const / noexcept / override / final
        return sentinel;
    }
    return sentinel;
}

/// Index of the terminating `;` of a member declaration whose params close at
/// `params_close`, allowing trailing qualifiers and a `= 0` / `= default`.
/// `sentinel` when no plain declaration terminator follows.
fn declEnd(ctx: *const Ctx, params_close: u32, hi: u32) u32 {
    var j = params_close + 1;
    var guard: u32 = 0;
    while (j < hi and guard < 8) : ({
        j += 1;
        guard += 1;
    }) {
        if (ctx.isPunct(j, ';')) return j;
        const ok = ctx.toks[j].kind == .identifier or ctx.toks[j].kind == .number or
            ctx.isPunct(j, '=');
        if (!ok) return sentinel;
    }
    return sentinel;
}

fn tryCFunction(ctx: *Ctx, stmt_start: u32, name_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    const params_open = name_i + 1;
    const params_close = ctx.close[params_open];
    if (params_close == sentinel) return name_i;
    // Guard: the token before the name must not itself be a call keyword.
    if (ctx.ckw.has(ctx.textOf(name_i))) return name_i;
    // A definition has `{` right after the parameter list (allowing C++ trailing
    // qualifiers); otherwise it is a declaration or a call, which we ignore here.
    const body_open = cBodyOpen(ctx, params_close, hi);
    if (body_open == sentinel) return name_i;
    const body_close = ctx.close[body_open];
    if (body_close == sentinel) return name_i;
    const body = try collectRefs(ctx, params_open, body_open + 1, body_close, ctx.textOf(name_i), ctx.ckw);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (parent != null) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, firstCodeToken(ctx, stmt_start)),
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = collectDoc(ctx, stmt_start),
        // A `static` free function has internal linkage — not exported/public.
        .exported = parent != null or !hasKeywordBetween(ctx, stmt_start, name_i, "static"),
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return body_close + 1;
}

/// Whether keyword `kw` appears as a token in [lo, name_i) — used to detect a
/// leading `static` linkage qualifier on a C function definition.
fn hasKeywordBetween(ctx: *const Ctx, lo: u32, name_i: u32, kw: []const u8) bool {
    var j = lo;
    while (j < name_i) : (j += 1) {
        if (ctx.identEql(j, kw)) return true;
    }
    return false;
}

fn lineEndOffset(ctx: *const Ctx, from: u32) u32 {
    var p = from;
    while (p < ctx.source.len and ctx.source[p] != '\n') p += 1;
    return p;
}

// ---------------------------------------------------------------------------
// JavaScript / TypeScript
// ---------------------------------------------------------------------------

const js_keywords = KeywordSet.initComptime(.{
    .{"const"},  .{"let"},    .{"var"},    .{"function"}, .{"return"}, .{"if"},
    .{"else"},   .{"for"},    .{"while"},  .{"switch"},   .{"case"},   .{"break"},
    .{"continue"}, .{"class"}, .{"extends"}, .{"new"},    .{"async"},  .{"await"},
    .{"import"}, .{"export"}, .{"from"},   .{"default"},  .{"typeof"}, .{"instanceof"},
    .{"this"},   .{"super"},  .{"try"},    .{"catch"},    .{"finally"}, .{"throw"},
    .{"yield"},  .{"static"}, .{"get"},    .{"set"},      .{"of"},     .{"in"},
    .{"true"},   .{"false"},  .{"null"},   .{"undefined"}, .{"void"},  .{"delete"},
    .{"interface"}, .{"type"}, .{"enum"},  .{"public"},   .{"private"}, .{"readonly"},
});

fn parseJsScope(ctx: *Ctx, lo: u32, hi: u32, parent: ?u32) AllocError!void {
    var i = lo;
    var at_stmt = true;
    while (i < hi) {
        const t = ctx.toks[i];
        if (t.kind == .comment) {
            i += 1;
            continue;
        }
        if (t.kind == .punct) {
            const c = ctx.ch(i);
            if (c == '{' or c == '(' or c == '[') {
                i = skipBracket(ctx, i);
                at_stmt = c == '{';
                continue;
            }
            at_stmt = c == ';' or c == '}' or c == '{';
            i += 1;
            continue;
        }
        if (at_stmt and ctx.identEql(i, "import")) {
            i = try parseJsImport(ctx, i, hi);
            at_stmt = true;
            continue;
        }
        if (at_stmt and ctx.identEql(i, "export")) {
            const adv = try parseJsReexport(ctx, i, hi);
            if (adv > i) {
                i = adv;
                at_stmt = true;
                continue;
            }
        }
        if (at_stmt) {
            const adv = try parseJsDecl(ctx, i, hi, parent);
            if (adv > i) {
                i = adv;
                at_stmt = true;
                continue;
            }
        }
        at_stmt = false;
        i += 1;
    }
}

fn parseJsImport(ctx: *Ctx, i: u32, hi: u32) !u32 {
    const line = ctx.toks[i].line;
    var j = i + 1;
    var module: []const u8 = "";
    while (j < hi and ctx.toks[j].line == line) : (j += 1) {
        if (ctx.toks[j].kind == .string) module = stripQuotes(ctx.textOf(j));
    }
    if (module.len != 0) {
        const binding = jsImportBinding(ctx, i, j);
        _ = try emit(ctx, importSymbol(binding, module, line, lineStartOffset(ctx, i), ctx.toks[j - 1].end));
    }
    return j;
}

/// Re-export forms that pull from another module: `export { a } from "mod"`,
/// `export * from "mod"`, `export * as ns from "mod"` and their `export type`
/// variants. Emits a module import edge (binding is the `* as ns` name, else "").
/// Returns `i` unchanged for a plain `export const/function/class/{...}` (no
/// `from`), which `parseJsDecl` then handles.
fn parseJsReexport(ctx: *Ctx, i: u32, hi: u32) !u32 {
    var j = i + 1;
    if (ctx.identEql(j, "type")) j += 1; // `export type { X } from "mod"`
    var binding: []const u8 = "";
    if (ctx.isPunct(j, '{')) {
        const close = ctx.close[j];
        if (close == sentinel) return i;
        j = close + 1;
    } else if (ctx.isPunct(j, '*')) {
        j += 1;
        if (ctx.identEql(j, "as") and j + 1 < hi and ctx.toks[j + 1].kind == .identifier) {
            binding = ctx.textOf(j + 1);
            j += 2;
        }
    } else {
        return i; // not a re-export form
    }
    if (!ctx.identEql(j, "from") or j + 1 >= hi or ctx.toks[j + 1].kind != .string) return i;
    const mod = stripQuotes(ctx.textOf(j + 1));
    if (mod.len == 0) return i;
    _ = try emit(ctx, importSymbol(binding, mod, ctx.toks[i].line, lineStartOffset(ctx, i), ctx.toks[j + 1].end));
    return j + 2;
}

/// The namespace/default binding of an ES import (`import X ...` or
/// `import * as X ...`), used to resolve `X.member()`. Named imports
/// (`import { a } ...`) are called bare, so they need no binding here → "".
fn jsImportBinding(ctx: *const Ctx, import_i: u32, end_j: u32) []const u8 {
    var first = import_i + 1;
    // `import type { ... }` / `import type * as ns` — the `type` keyword is not a
    // binding; skip it so a type-only import doesn't bind the name "type".
    if (ctx.identEql(first, "type") and first + 1 < end_j and
        (ctx.isPunct(first + 1, '{') or ctx.isPunct(first + 1, '*'))) first += 1;
    if (first >= end_j) return "";
    // `import * as NAME from ...`
    if (ctx.isPunct(first, '*') and first + 2 < end_j and ctx.identEql(first + 1, "as") and
        ctx.toks[first + 2].kind == .identifier) return ctx.textOf(first + 2);
    // `import NAME from ...` (default) — a leading identifier, not `{`.
    if (ctx.toks[first].kind == .identifier and !ctx.identEql(first, "from")) return ctx.textOf(first);
    return "";
}

fn parseJsDecl(ctx: *Ctx, i: u32, hi: u32, parent: ?u32) !u32 {
    const exported = ctx.identEql(i, "export");
    var k = i;
    while (k < hi and (ctx.identEql(k, "export") or ctx.identEql(k, "default"))) k += 1;
    if (k >= hi) return i;

    if (ctx.identEql(k, "class")) return parseJsClass(ctx, i, k, hi, parent, exported);
    if (ctx.identEql(k, "function") or (ctx.identEql(k, "async") and ctx.identEql(k + 1, "function"))) {
        const is_async = ctx.identEql(k, "async");
        const fn_i = if (is_async) k + 1 else k;
        return parseJsFunction(ctx, i, fn_i, hi, parent, exported, .{ .is_async = is_async });
    }
    if (ctx.identEql(k, "const") or ctx.identEql(k, "let") or ctx.identEql(k, "var")) {
        return parseJsBinding(ctx, i, k, hi, parent, exported);
    }
    // TypeScript type-level declarations. Gated to ts/tsx so a stray `type`/
    // `interface` identifier in plain JS is never mistaken for one.
    if (ctx.cfg.language == .typescript or ctx.cfg.language == .tsx) {
        if (ctx.identEql(k, "interface") or ctx.identEql(k, "enum")) {
            return parseTsContainer(ctx, i, k, hi, parent, exported);
        }
        if (ctx.identEql(k, "type")) {
            const adv = try parseTsTypeAlias(ctx, i, k, hi, parent, exported);
            if (adv > i) return adv;
        }
    }
    if (parent != null) return parseJsMember(ctx, i, k, hi, parent.?);
    return i;
}

/// A `require("PATH")` module string at the RHS of `= require(...)` (`eq_i` is the
/// `=` token), or null when the initializer is not a CommonJS require.
fn jsRequirePath(ctx: *const Ctx, eq_i: u32, hi: u32) ?[]const u8 {
    if (eq_i == sentinel or eq_i + 3 >= hi) return null;
    if (!ctx.identEql(eq_i + 1, "require")) return null;
    if (!ctx.isPunct(eq_i + 2, '(') or ctx.toks[eq_i + 3].kind != .string) return null;
    return stripQuotes(ctx.textOf(eq_i + 3));
}

/// TS `interface NAME {...}` / `enum NAME {...}` → an interface/enum symbol.
fn parseTsContainer(ctx: *Ctx, start_i: u32, kw_i: u32, hi: u32, parent: ?u32, exported: bool) !u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return start_i;
    const name_i = kw_i + 1;
    const open = findNext(ctx, name_i + 1, hi, '{');
    if (open == sentinel or ctx.close[open] == sentinel) return start_i;
    const close = ctx.close[open];
    const kind: SymbolKind = if (ctx.identEql(kw_i, "enum")) .@"enum" else .interface;
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[open].start,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    return close + 1;
}

/// TS `type NAME = ...;` → a type-alias symbol. Returns `start_i` when the RHS is
/// absent (so `type` used as a plain identifier is not swallowed).
fn parseTsTypeAlias(ctx: *Ctx, start_i: u32, kw_i: u32, hi: u32, parent: ?u32, exported: bool) !u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return start_i;
    const name_i = kw_i + 1;
    const eq = findNext(ctx, name_i + 1, hi, '=');
    if (eq == sentinel) return start_i;
    const semi = findNext(ctx, eq + 1, hi, ';');
    const end_i = if (ctx.isPunct(eq + 1, '{') and ctx.close[eq + 1] != sentinel)
        ctx.close[eq + 1]
    else if (semi != sentinel) semi else eq + 1;
    const span_end = ctx.toks[end_i].end;
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .type,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = span_end,
        .sig_end = span_end,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    return tokenAfterOffset(ctx, span_end, hi);
}

/// Skip a `<...>` generic list, returning the index after `>` (or `i` unchanged
/// if `i` is not `<` or the list looks unbalanced).
fn jsSkipGenerics(ctx: *const Ctx, i: u32, hi: u32) u32 {
    if (!ctx.isPunct(i, '<')) return i;
    var depth: i32 = 0;
    var j = i;
    while (j < hi) : (j += 1) {
        if (ctx.isPunct(j, '{') or ctx.isPunct(j, ';')) return i;
        if (ctx.isPunct(j, '<')) depth += 1;
        if (ctx.isPunct(j, '>')) {
            depth -= 1;
            if (depth <= 0) return j + 1;
        }
    }
    return i;
}

/// Body `{` of a JS/TS callable whose params close at `pclose`, skipping an
/// optional TS return-type annotation `): T {`. Sentinel for a bodyless
/// declaration (`): T;`) or when no body follows.
fn jsBodyOpen(ctx: *const Ctx, pclose: u32, hi: u32) u32 {
    var b = pclose + 1;
    if (b < hi and ctx.isPunct(b, ':')) {
        b += 1;
        while (b < hi) : (b += 1) {
            if (ctx.isPunct(b, '{')) break;
            if (ctx.isPunct(b, ';')) return sentinel;
            if (ctx.isPunct(b, '(') or ctx.isPunct(b, '[')) {
                const c = ctx.close[b];
                if (c != sentinel) b = c;
            }
        }
    }
    if (b < hi and ctx.isPunct(b, '{')) return b;
    return sentinel;
}

fn parseJsFunction(ctx: *Ctx, start_i: u32, fn_i: u32, hi: u32, parent: ?u32, exported: bool, mods: Mods) !u32 {
    if (fn_i + 1 >= hi or ctx.toks[fn_i + 1].kind != .identifier) return start_i;
    const name_i = fn_i + 1;
    const popen = jsSkipGenerics(ctx, name_i + 1, hi);
    if (!ctx.isPunct(popen, '(')) return start_i;
    const pclose = ctx.close[popen];
    if (pclose == sentinel) return start_i;
    const body_open = jsBodyOpen(ctx, pclose, hi);
    if (body_open == sentinel or ctx.close[body_open] == sentinel) return start_i;
    const body_close = ctx.close[body_open];
    const body = try collectRefs(ctx, popen, body_open + 1, body_close, ctx.textOf(name_i), js_keywords);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (parent != null) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .modifiers = mods,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return body_close + 1;
}

fn parseJsClass(ctx: *Ctx, start_i: u32, class_i: u32, hi: u32, parent: ?u32, exported: bool) !u32 {
    if (class_i + 1 >= hi or ctx.toks[class_i + 1].kind != .identifier) return start_i;
    const name_i = class_i + 1;
    const open = findNext(ctx, name_i + 1, hi, '{');
    if (open == sentinel or ctx.close[open] == sentinel) return start_i;
    const close = ctx.close[open];
    const my_idx = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .class,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[open].start,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    try parseJsScope(ctx, open + 1, close, my_idx);
    return close + 1;
}

fn parseJsBinding(ctx: *Ctx, start_i: u32, kw_i: u32, hi: u32, parent: ?u32, exported: bool) !u32 {
    // Destructured CommonJS import: `const { a, b } = require("mod")`. Only the
    // module edge is recorded (the destructured names are called bare).
    if (kw_i + 1 < hi and (ctx.isPunct(kw_i + 1, '{') or ctx.isPunct(kw_i + 1, '['))) {
        const brace_close = ctx.close[kw_i + 1];
        if (brace_close != sentinel) {
            const eq = findNext(ctx, brace_close + 1, hi, '=');
            if (jsRequirePath(ctx, eq, hi)) |mod| {
                const semi = findNext(ctx, brace_close + 1, hi, ';');
                const end_i = if (semi != sentinel) semi else eq + 4;
                const span_end = ctx.toks[end_i].end;
                _ = try emit(ctx, importSymbol("", mod, ctx.toks[kw_i].line, lineStartOffset(ctx, start_i), span_end));
                return tokenAfterOffset(ctx, span_end, hi);
            }
        }
        return start_i;
    }
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return start_i;
    const name_i = kw_i + 1;
    const eq_i = findNext(ctx, name_i + 1, hi, '=');
    const semi_i = findNext(ctx, name_i + 1, hi, ';');

    // `const NAME = require("mod")` — a CommonJS import binding (name → module).
    if (jsRequirePath(ctx, eq_i, hi)) |mod| {
        const end_i = if (semi_i != sentinel) semi_i else eq_i + 4;
        const span_end = ctx.toks[end_i].end;
        _ = try emit(ctx, importSymbol(ctx.textOf(name_i), mod, ctx.toks[name_i].line, lineStartOffset(ctx, start_i), span_end));
        return tokenAfterOffset(ctx, span_end, hi);
    }
    // `const f = async () => …` / `const f = async x => …`: the arrow is async.
    const arrow_mods = Mods{ .is_async = eq_i != sentinel and eq_i + 1 < hi and ctx.identEql(eq_i + 1, "async") };
    const arrow_body = detectJsArrow(ctx, eq_i, hi, semi_i);
    if (arrow_body.open != sentinel) {
        return emitJsArrow(ctx, start_i, name_i, arrow_body, parent, exported, arrow_mods, hi);
    }
    // Expression-bodied arrow: `const C = () => (<JSX>…)`, `const f = x => g(x)`.
    // These carry real call sites (a React component's whole render is here), so
    // treat them as functions and collect refs — not as an opaque variable.
    if (arrow_body.is_fn and arrow_body.arrow_i != sentinel) {
        return emitJsArrowExpr(ctx, start_i, name_i, arrow_body.arrow_i, parent, exported, arrow_mods, hi);
    }
    const end_i = if (semi_i != sentinel) semi_i else name_i;
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .variable,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[end_i].end,
        .sig_end = ctx.toks[end_i].end,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    return tokenAfterOffset(ctx, ctx.toks[end_i].end, hi);
}

const JsArrow = struct { open: u32, arrow_i: u32, is_fn: bool };

/// Detect an arrow function on a binding's RHS. `open` is the block-body `{`
/// index (sentinel for an expression body); `arrow_i` is the `=>` token's `=`
/// index; `is_fn` is true once a top-level `=>` is seen.
fn detectJsArrow(ctx: *const Ctx, eq_i: u32, hi: u32, semi_i: u32) JsArrow {
    if (eq_i == sentinel) return .{ .open = sentinel, .arrow_i = sentinel, .is_fn = false };
    const limit = if (semi_i != sentinel) semi_i else hi;
    var i = eq_i + 1;
    var saw_arrow = false;
    var arrow_i: u32 = sentinel;
    while (i < limit) {
        if (ctx.isPunct(i, '(') or ctx.isPunct(i, '[')) {
            i = skipBracket(ctx, i);
            continue;
        }
        if (ctx.toks[i].kind == .punct and ctx.ch(i) == '=' and i + 1 < limit and ctx.isPunct(i + 1, '>')) {
            saw_arrow = true;
            arrow_i = i;
            i += 2;
            continue;
        }
        if (saw_arrow and ctx.isPunct(i, '{')) return .{ .open = i, .arrow_i = arrow_i, .is_fn = true };
        if (ctx.isPunct(i, '{')) {
            i = skipBracket(ctx, i);
            continue;
        }
        i += 1;
    }
    return .{ .open = sentinel, .arrow_i = arrow_i, .is_fn = saw_arrow };
}

fn emitJsArrow(ctx: *Ctx, start_i: u32, name_i: u32, arrow: JsArrow, parent: ?u32, exported: bool, mods: Mods, hi: u32) !u32 {
    const close = ctx.close[arrow.open];
    if (close == sentinel) return start_i + 1;
    const popen = findNext(ctx, name_i + 1, arrow.open, '(');
    const params_open = if (popen != sentinel and ctx.close[popen] != sentinel and
        ctx.close[popen] < arrow.open) popen else sentinel;
    const body = try collectRefs(ctx, params_open, arrow.open + 1, close, ctx.textOf(name_i), js_keywords);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (parent != null) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[arrow.open].start,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .modifiers = mods,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    _ = hi;
    return close + 1;
}

/// Emit an expression-bodied arrow `const NAME = (params) => EXPR` as a function
/// and collect the call/read refs in EXPR. `arrow_i` is the `=>`'s `=` token.
fn emitJsArrowExpr(ctx: *Ctx, start_i: u32, name_i: u32, arrow_i: u32, parent: ?u32, exported: bool, mods: Mods, hi: u32) !u32 {
    const body_start = arrow_i + 2; // skip `=` and `>`
    if (body_start >= hi) return start_i;
    const end = arrowExprEnd(ctx, body_start, hi);
    // Params: the `(...)` between the name and `=>`, so param names bind rather
    // than resolve globally. A bare single param (`x => …`) has none to skip.
    const popen = findNext(ctx, name_i + 1, arrow_i, '(');
    const params_open = if (popen != sentinel and ctx.close[popen] != sentinel and
        ctx.close[popen] < arrow_i) popen else sentinel;
    const body = try collectRefs(ctx, params_open, body_start, end, ctx.textOf(name_i), js_keywords);
    const last_tok = if (end > body_start) end - 1 else body_start;
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (parent != null) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[last_tok].end,
        .sig_end = ctx.toks[body_start].start,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .modifiers = mods,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return end;
}

/// The exclusive end token of an arrow's expression body: a bracket-balanced
/// forward scan from `start` that stops at the first top-level `;`, `,` or a
/// closing bracket belonging to an enclosing scope (or `hi`).
fn arrowExprEnd(ctx: *const Ctx, start: u32, hi: u32) u32 {
    var i = start;
    while (i < hi) {
        if (ctx.toks[i].kind == .punct) {
            const c = ctx.ch(i);
            if (c == '(' or c == '{' or c == '[') {
                const close = ctx.close[i];
                if (close == sentinel or close >= hi) return hi;
                i = close + 1;
                continue;
            }
            if (c == ';' or c == ',' or c == ')' or c == ']' or c == '}') return i;
        }
        i += 1;
    }
    return hi;
}

/// Class members: methods `name(...) { }` and accessors.
fn parseJsMember(ctx: *Ctx, start_i: u32, k: u32, hi: u32, parent: u32) !u32 {
    var m = k;
    var mods = Mods{};
    // Skip method modifiers, but only when they prefix a name — `get x()` is an
    // accessor, whereas `get()`/`get<T>()` is a method literally named `get`.
    // Capture them so a getter renders as `get x`, not a bare `method x` (which
    // reads as a bug), and a `static`/`async` member is labelled as such.
    while (m + 1 < hi and ctx.toks[m + 1].kind == .identifier and
        (ctx.identEql(m, "static") or ctx.identEql(m, "async") or
            ctx.identEql(m, "get") or ctx.identEql(m, "set") or ctx.identEql(m, "readonly"))) : (m += 1)
    {
        if (ctx.identEql(m, "static")) mods.is_static = true;
        if (ctx.identEql(m, "async")) mods.is_async = true;
        if (ctx.identEql(m, "get")) mods.getter = true;
        if (ctx.identEql(m, "set")) mods.setter = true;
    }
    if (m >= hi or ctx.toks[m].kind != .identifier) return start_i;
    const popen = jsSkipGenerics(ctx, m + 1, hi);
    if (!ctx.isPunct(popen, '(')) return start_i;
    const pclose = ctx.close[popen];
    if (pclose == sentinel) return start_i;
    const body_open = jsBodyOpen(ctx, pclose, hi);
    if (body_open == sentinel) return start_i;
    const body_close = ctx.close[body_open];
    if (body_close == sentinel) return start_i;
    const body = try collectRefs(ctx, popen, body_open + 1, body_close, ctx.textOf(m), js_keywords);
    _ = try emit(ctx, .{
        .name = ctx.textOf(m),
        .kind = .method,
        .line = ctx.toks[m].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = collectDoc(ctx, start_i),
        .exported = false,
        .modifiers = mods,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return body_close + 1;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'' or s[0] == '`')) {
        return s[1 .. s.len - 1];
    }
    return s;
}

// ---------------------------------------------------------------------------
// Python
// ---------------------------------------------------------------------------

const py_keywords = KeywordSet.initComptime(.{
    .{"def"},    .{"class"},  .{"return"}, .{"if"},     .{"elif"},   .{"else"},
    .{"for"},    .{"while"},  .{"import"}, .{"from"},   .{"as"},     .{"with"},
    .{"try"},    .{"except"}, .{"finally"}, .{"raise"}, .{"pass"},   .{"break"},
    .{"continue"}, .{"and"},  .{"or"},     .{"not"},    .{"in"},     .{"is"},
    .{"lambda"}, .{"yield"},  .{"await"},  .{"async"},  .{"global"}, .{"nonlocal"},
    .{"True"},   .{"False"},  .{"None"},   .{"self"},   .{"del"},    .{"assert"},
});

const PyScope = struct { indent: u32, local_idx: u32, is_class: bool };

fn isLineStart(ctx: *const Ctx, i: u32) bool {
    return i == 0 or ctx.toks[i - 1].line != ctx.toks[i].line;
}

fn parsePython(ctx: *Ctx) !void {
    const hi: u32 = @intCast(ctx.toks.len - 1);
    var stack: std.ArrayList(PyScope) = .empty;
    defer stack.deinit(ctx.gpa);
    // Modifiers accrued from `@decorator` lines pending the next `def` — cleared
    // by any non-decorator statement so a decorator never leaks past its target.
    var pending = Mods{};
    var i: u32 = 0;
    while (i < hi) : (i += 1) {
        if (!isLineStart(ctx, i) or ctx.toks[i].kind != .identifier) continue;
        // A decorator line (`@property`, `@app.get("/x")`, `@x.setter`): the `@`
        // is glued to the first identifier by the lexer. Record any modifier it
        // implies and keep it pending for the following def.
        const txt = ctx.textOf(i);
        if (txt.len != 0 and txt[0] == '@') {
            applyPyDecorator(ctx, i, &pending);
            continue;
        }
        const indent = ctx.toks[i].col;
        popPyScopes(&stack, indent);
        const enclosing: ?PyScope = if (stack.items.len != 0) stack.items[stack.items.len - 1] else null;
        const parent: ?u32 = if (enclosing) |e| e.local_idx else null;
        if (ctx.identEql(i, "def") or (ctx.identEql(i, "async") and i + 1 < hi and ctx.identEql(i + 1, "def"))) {
            const def_i = if (ctx.identEql(i, "async")) i + 1 else i;
            const is_method = if (enclosing) |e| e.is_class else false;
            var mods = pending;
            mods.is_async = ctx.identEql(i, "async");
            const idx = try parsePyDef(ctx, i, def_i, hi, if (is_method) parent else null, is_method, mods);
            if (idx != sentinel) try stack.append(ctx.gpa, .{ .indent = indent, .local_idx = idx, .is_class = false });
            pending = .{};
        } else if (ctx.identEql(i, "class")) {
            const idx = try parsePyClass(ctx, i, hi, parent);
            if (idx != sentinel) try stack.append(ctx.gpa, .{ .indent = indent, .local_idx = idx, .is_class = true });
            pending = .{};
        } else if (ctx.identEql(i, "import") or ctx.identEql(i, "from")) {
            try parsePyImport(ctx, i, hi);
            pending = .{};
        } else if (isPyKeyword(ctx, i)) {
            pending = .{};
            continue;
        } else {
            pending = .{};
            const in_func = if (enclosing) |e| !e.is_class else false;
            if (!in_func) try tryPyAssign(ctx, i, hi, parent);
        }
    }
}

/// Fold the modifier a Python `@decorator` at token `i` implies into `pending`.
/// Recognizes the accessor/dispatch decorators (`@property`, `@staticmethod`,
/// `@classmethod`, `@abstractmethod`) in both bare (`@property`) and dotted
/// (`@abc.abstractmethod`, `@value.setter`, `@functools.cached_property`) forms;
/// unrecognized decorators (framework/route) leave `pending` untouched.
fn applyPyDecorator(ctx: *const Ctx, i: u32, pending: *Mods) void {
    const txt = ctx.textOf(i);
    std.debug.assert(txt.len >= 1 and txt[0] == '@');
    const head = txt[1..];
    if (std.mem.eql(u8, head, "property") or std.mem.eql(u8, head, "cached_property")) {
        pending.getter = true;
    } else if (std.mem.eql(u8, head, "staticmethod")) {
        pending.is_static = true;
    } else if (std.mem.eql(u8, head, "classmethod")) {
        pending.classmethod = true;
    } else if (std.mem.eql(u8, head, "abstractmethod")) {
        pending.abstract = true;
    } else if (ctx.isPunct(i + 1, '.') and i + 2 < ctx.toks.len and ctx.toks[i + 2].kind == .identifier) {
        const tail = ctx.textOf(i + 2);
        if (std.mem.eql(u8, tail, "abstractmethod")) {
            pending.abstract = true;
        } else if (std.mem.eql(u8, tail, "setter")) {
            pending.setter = true;
        } else if (std.mem.eql(u8, tail, "cached_property") or std.mem.eql(u8, tail, "property")) {
            pending.getter = true;
        }
    }
}

fn isPyKeyword(ctx: *const Ctx, i: u32) bool {
    return py_keywords.has(ctx.textOf(i));
}

const PyModule = struct { path: []const u8, after: u32 };

/// A dotted module path `a.b.c` starting at token `start` (same line), plus the
/// token index just past it. Null when `start` is not an identifier.
fn pyModulePath(ctx: *const Ctx, start: u32, hi: u32, line: u32) ?PyModule {
    if (start >= hi or ctx.toks[start].line != line or ctx.toks[start].kind != .identifier) return null;
    var last = start;
    while (last + 2 < hi and ctx.isPunct(last + 1, '.') and
        ctx.toks[last + 2].kind == .identifier and ctx.toks[last + 2].line == line) : (last += 2)
    {}
    return .{ .path = ctx.source[ctx.toks[start].start..ctx.toks[last].end], .after = last + 1 };
}

/// Emit `.import` symbols for `import a[, b as c]` and `from mod import ...`.
/// Named `from` targets are bare-callable, so only the module edge is recorded.
fn parsePyImport(ctx: *Ctx, i: u32, hi: u32) !void {
    const line = ctx.toks[i].line;
    const span_start = lineStartOffset(ctx, i);
    if (ctx.identEql(i, "from")) {
        // Relative imports carry leading dots (`from ..services.user_service import
        // X` → module string "..services.user_service"). The dots are separate
        // punct tokens; capture them so `imports.pyCandidates` can resolve them.
        const first = i + 1;
        var j = first;
        while (j < hi and ctx.toks[j].line == line and ctx.isPunct(j, '.')) j += 1;
        const has_dots = j > first;
        var last: u32 = if (has_dots) j - 1 else j;
        if (j < hi and ctx.toks[j].line == line and ctx.toks[j].kind == .identifier and !ctx.identEql(j, "import")) {
            const m = pyModulePath(ctx, j, hi, line) orelse return;
            last = m.after - 1;
        } else if (!has_dots) {
            return; // malformed `from` with no module
        }
        const path = ctx.source[ctx.toks[first].start..ctx.toks[last].end];
        _ = try emit(ctx, importSymbol("", path, line, span_start, ctx.toks[last].end));
        return;
    }
    var j = i + 1;
    while (j < hi and ctx.toks[j].line == line) {
        const m = pyModulePath(ctx, j, hi, line) orelse break;
        const bind = pyImportBinding(ctx, m, hi);
        _ = try emit(ctx, importSymbol(bind.name, m.path, line, span_start, ctx.toks[m.after - 1].end));
        j = bind.after;
        while (j < hi and ctx.toks[j].line == line and !ctx.isPunct(j, ',')) j += 1;
        if (j >= hi or !ctx.isPunct(j, ',')) break;
        j += 1;
    }
}

const PyBinding = struct { name: []const u8, after: u32 };

/// The name a Python `import` binds: an explicit `as ALIAS`, else the module
/// itself when it is a single (non-dotted) segment, else "" (dotted).
fn pyImportBinding(ctx: *const Ctx, m: PyModule, hi: u32) PyBinding {
    if (m.after + 1 < hi and ctx.identEql(m.after, "as") and ctx.toks[m.after + 1].kind == .identifier) {
        return .{ .name = ctx.textOf(m.after + 1), .after = m.after + 2 };
    }
    const dotted = std.mem.indexOfScalar(u8, m.path, '.') != null;
    return .{ .name = if (dotted) "" else m.path, .after = m.after };
}

fn popPyScopes(stack: *std.ArrayList(PyScope), indent: u32) void {
    while (stack.items.len != 0 and stack.items[stack.items.len - 1].indent >= indent) {
        _ = stack.pop();
    }
}

/// End of an indented block: first line-start token at column <= `indent`.
fn pyBlockEnd(ctx: *const Ctx, def_i: u32, indent: u32, hi: u32) u32 {
    const def_line = ctx.toks[def_i].line;
    var j = def_i + 1;
    while (j < hi) : (j += 1) {
        if (!isLineStart(ctx, j)) continue;
        if (ctx.toks[j].line == def_line) continue;
        if (ctx.toks[j].col <= indent) return j;
    }
    return hi;
}

fn parsePyDef(ctx: *Ctx, start_i: u32, def_i: u32, hi: u32, parent: ?u32, is_method: bool, mods: Mods) !u32 {
    if (def_i + 1 >= hi or ctx.toks[def_i + 1].kind != .identifier) return sentinel;
    const name_i = def_i + 1;
    const indent = ctx.toks[start_i].col;
    // Find the signature-terminating colon first (bracket-aware), then measure
    // the block from the colon's line. A multi-line signature whose closing
    // paren dedents to the def's column would otherwise end the block early.
    const colon = findNext(ctx, name_i + 1, hi, ':');
    const block_from = if (colon != sentinel) colon else start_i;
    const term = pyBlockEnd(ctx, block_from, indent, hi);
    const span_end = if (term < hi) lineStartTrimEnd(ctx, term) else @as(u32, @intCast(ctx.source.len));
    const sig_end = if (colon != sentinel) ctx.toks[colon].end else ctx.toks[name_i].end;
    const body_lo = if (colon != sentinel) colon + 1 else name_i + 1;
    std.debug.assert(body_lo <= term);
    const body = try collectRefs(ctx, name_i + 1, body_lo, term, ctx.textOf(name_i), py_keywords);
    return emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (is_method) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = collectDoc(ctx, start_i),
        .exported = ctx.source[ctx.toks[name_i].start] != '_',
        .modifiers = mods,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
}

fn parsePyClass(ctx: *Ctx, start_i: u32, hi: u32, parent: ?u32) !u32 {
    if (start_i + 1 >= hi or ctx.toks[start_i + 1].kind != .identifier) return sentinel;
    const name_i = start_i + 1;
    const indent = ctx.toks[start_i].col;
    const colon = findNext(ctx, name_i + 1, hi, ':');
    const block_from = if (colon != sentinel) colon else start_i;
    const term = pyBlockEnd(ctx, block_from, indent, hi);
    const span_end = if (term < hi) lineStartTrimEnd(ctx, term) else @as(u32, @intCast(ctx.source.len));
    const sig_end = if (colon != sentinel) ctx.toks[colon].end else ctx.toks[name_i].end;
    return emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .class,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = collectDoc(ctx, start_i),
        .exported = ctx.source[ctx.toks[name_i].start] != '_',
        .parent_local = parent,
        .refs = &.{},
    });
}

fn tryPyAssign(ctx: *Ctx, i: u32, hi: u32, parent: ?u32) !void {
    // `NAME = ...` or `NAME: TYPE = ...` at line start → module/class variable.
    if (i + 1 >= hi) return;
    var j = i + 1;
    if (ctx.isPunct(j, ':')) { // annotation
        while (j < hi and !ctx.isPunct(j, '=') and ctx.toks[j].line == ctx.toks[i].line) j += 1;
    }
    if (j >= hi or !ctx.isPunct(j, '=')) return;
    if (j + 1 < hi and ctx.isPunct(j + 1, '=')) return; // comparison ==
    const first_line_end = lineEndOffset(ctx, ctx.toks[i].start);
    // A bracketed multi-line initializer (`NAME = [ … ]` / `{ … }` / `( … )`)
    // spans past line 1: capture the whole literal so `def NAME -v full` shows
    // its contents (the value-resolution gap a trial hit on `GP_GROUPS`). The
    // signature stays the first line, so the `sig` view still collapses to the
    // head. Only a *direct* bracket literal extends — `NAME = f([…])` does not.
    var span_end = first_line_end;
    if (j + 1 < hi and (ctx.isPunct(j + 1, '[') or ctx.isPunct(j + 1, '{') or ctx.isPunct(j + 1, '('))) {
        const close = ctx.close[j + 1];
        if (close != sentinel and close < hi) span_end = @max(span_end, ctx.toks[close].end);
    }
    _ = try emit(ctx, .{
        .name = ctx.textOf(i),
        .kind = if (parent != null) .field else .variable,
        .line = ctx.toks[i].line,
        .span_start = lineStartOffset(ctx, i),
        .span_end = span_end,
        .sig_end = first_line_end,
        .doc = "",
        .exported = ctx.source[ctx.toks[i].start] != '_',
        .parent_local = parent,
        .refs = &.{},
    });
}

fn lineStartTrimEnd(ctx: *const Ctx, term: u32) u32 {
    // span end is the byte just before the terminating token's line begins.
    const ls = lineStartOffset(ctx, term);
    return if (ls == 0) 0 else ls - 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(src: []const u8, lang: language.Language) !std.ArrayList(ParsedSymbol) {
    var out: std.ArrayList(ParsedSymbol) = .empty;
    // arena leaks into the test allocator's checking; use testing allocator via arena.
    const arena = testing.allocator;
    try parse(testing.allocator, arena, src, lang, &out);
    return out;
}

fn findSym(list: []const ParsedSymbol, name: []const u8) ?ParsedSymbol {
    for (list) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

test "zig: functions, struct, methods, refs" {
    const src =
        \\const std = @import("std");
        \\
        \\/// Adds two numbers.
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\
        \\pub const Calc = struct {
        \\    total: i32,
        \\    pub fn tally(self: *Calc) i32 {
        \\        return add(self.total, 1);
        \\    }
        \\};
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    const add = findSym(out.items, "add").?;
    try testing.expectEqual(SymbolKind.function, add.kind);
    try testing.expect(add.exported);
    try testing.expect(std.mem.indexOf(u8, add.doc, "Adds two numbers") != null);
    const calc = findSym(out.items, "Calc").?;
    try testing.expectEqual(SymbolKind.@"struct", calc.kind);
    const tally = findSym(out.items, "tally").?;
    try testing.expectEqual(SymbolKind.method, tally.kind);
    try testing.expect(tally.parent_local != null);
    var found_add_ref = false;
    for (tally.refs) |r| {
        if (std.mem.eql(u8, r.name, "add")) {
            found_add_ref = true;
            try testing.expectEqual(RefKind.call, r.kind);
        }
    }
    try testing.expect(found_add_ref);
}

test "python: def, class, method, refs" {
    const src =
        \\import os
        \\
        \\def helper(x):
        \\    return x * 2
        \\
        \\class Server:
        \\    def start(self):
        \\        return helper(self.port)
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "helper") != null);
    const server = findSym(out.items, "Server").?;
    try testing.expectEqual(SymbolKind.class, server.kind);
    const start = findSym(out.items, "start").?;
    try testing.expectEqual(SymbolKind.method, start.kind);
    try testing.expect(start.parent_local != null);
    var found = false;
    for (start.refs) |r| {
        if (std.mem.eql(u8, r.name, "helper")) found = true;
    }
    try testing.expect(found);
}

test "python: multi-line signature with dedented close paren does not crash" {
    // Regression: the closing `)` aligned to the def's column used to end the
    // block before the `:` was seen, producing body_lo > term (lo > hi).
    const src =
        \\def combine(
        \\    x,
        \\    y,
        \\):
        \\    return helper(x, y)
        \\
        \\
        \\class Node(
        \\    Base,
        \\):
        \\    def run(self):
        \\        return combine(1, 2)
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    const combine = findSym(out.items, "combine").?;
    try testing.expectEqual(SymbolKind.function, combine.kind);
    const node = findSym(out.items, "Node").?;
    try testing.expectEqual(SymbolKind.class, node.kind);
    const run = findSym(out.items, "run").?;
    try testing.expectEqual(SymbolKind.method, run.kind);
    var calls_combine = false;
    for (run.refs) |r| {
        if (std.mem.eql(u8, r.name, "combine")) calls_combine = true;
    }
    try testing.expect(calls_combine);
    var calls_helper = false;
    for (combine.refs) |r| {
        if (std.mem.eql(u8, r.name, "helper")) calls_helper = true;
    }
    try testing.expect(calls_helper);
}

test "js: function, arrow, class method" {
    const src =
        \\import { thing } from './mod';
        \\export function main() {
        \\  return helper();
        \\}
        \\const helper = () => {
        \\  return thing();
        \\};
        \\class Widget {
        \\  render() {
        \\    return main();
        \\  }
        \\}
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    const main_fn = findSym(out.items, "main").?;
    try testing.expectEqual(SymbolKind.function, main_fn.kind);
    try testing.expect(main_fn.exported);
    const helper = findSym(out.items, "helper").?;
    try testing.expectEqual(SymbolKind.function, helper.kind);
    const render = findSym(out.items, "render").?;
    try testing.expectEqual(SymbolKind.method, render.kind);
}

test "js: expression-body arrow is a function and captures its calls" {
    // React components are commonly `const C = () => (<JSX>{call()}</JSX>)`.
    // The whole render lives in the expression body — it must be a function
    // whose call sites are collected, not an opaque variable.
    const src =
        \\import { getMission, getStatus } from './api';
        \\export const Sidebar = () => (
        \\  <div>{getMission()}{getStatus('x')}</div>
        \\);
        \\export const label = (s) => `n:${s}`;
    ;
    var out = try parseForTest(src, .tsx);
    defer freeRefs(&out);
    const sidebar = findSym(out.items, "Sidebar").?;
    try testing.expectEqual(SymbolKind.function, sidebar.kind);
    var saw_mission = false;
    var saw_status = false;
    for (sidebar.refs) |r| {
        if (std.mem.eql(u8, r.name, "getMission")) saw_mission = true;
        if (std.mem.eql(u8, r.name, "getStatus")) saw_status = true;
    }
    try testing.expect(saw_mission);
    try testing.expect(saw_status);
    // A call-free expression-body arrow is still recognized as a function.
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "label").?.kind);
}

test "js: accessor and dispatch modifiers are captured (get/set/static/async)" {
    const src =
        \\class Store {
        \\  get value() { return this._v; }
        \\  set value(x) { this._v = x; }
        \\  static make() { return new Store(); }
        \\  async load() { return this.value; }
        \\  plain() { return 1; }
        \\}
        \\async function boot() { return 1; }
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    // Two methods named `value` (getter + setter) share a name; distinguish by mod.
    var saw_get = false;
    var saw_set = false;
    for (out.items) |s| {
        if (!std.mem.eql(u8, s.name, "value")) continue;
        if (s.modifiers.getter) saw_get = true;
        if (s.modifiers.setter) saw_set = true;
    }
    try testing.expect(saw_get);
    try testing.expect(saw_set);
    try testing.expect(findSym(out.items, "make").?.modifiers.is_static);
    try testing.expect(findSym(out.items, "load").?.modifiers.is_async);
    try testing.expect(!findSym(out.items, "plain").?.modifiers.any());
    try testing.expect(findSym(out.items, "boot").?.modifiers.is_async);
}

test "python: @property/@staticmethod/@classmethod/@x.setter/async def modifiers" {
    const src =
        \\class Api:
        \\    @property
        \\    def value(self):
        \\        return self._v
        \\    @value.setter
        \\    def value(self, x):
        \\        self._v = x
        \\    @staticmethod
        \\    def make():
        \\        return 1
        \\    @classmethod
        \\    def build(cls):
        \\        return 2
        \\    async def load(self):
        \\        return 3
        \\    def plain(self):
        \\        return 4
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    var saw_get = false;
    var saw_set = false;
    for (out.items) |s| {
        if (!std.mem.eql(u8, s.name, "value")) continue;
        if (s.modifiers.getter) saw_get = true;
        if (s.modifiers.setter) saw_set = true;
    }
    try testing.expect(saw_get);
    try testing.expect(saw_set);
    try testing.expect(findSym(out.items, "make").?.modifiers.is_static);
    try testing.expect(findSym(out.items, "build").?.modifiers.classmethod);
    try testing.expect(findSym(out.items, "load").?.modifiers.is_async);
    // A plain method carries no modifiers, and an unrecognized decorator does not
    // leak onto the next def.
    try testing.expect(!findSym(out.items, "plain").?.modifiers.any());
}

test "python: a multi-line list/dict initializer spans the whole literal" {
    const src =
        \\GP_GROUPS = [
        \\    "stations",
        \\    "visual",
        \\]
        \\def use():
        \\    return GP_GROUPS
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    const gp = findSym(out.items, "GP_GROUPS").?;
    // The full definition body reaches the closing bracket (line 4), so `-v full`
    // shows the literal's contents rather than truncating at line 1.
    const body = src[gp.span_start..gp.span_end];
    try testing.expect(std.mem.indexOf(u8, body, "stations") != null);
    try testing.expect(std.mem.indexOf(u8, body, "visual") != null);
    // The signature stays the first line (so the collapsed `sig` view is short).
    try testing.expect(std.mem.indexOf(u8, src[gp.span_start..gp.sig_end], "stations") == null);
}

test "python: f-string interpolation exposes the calls inside it" {
    const src =
        \\def helper(x):
        \\    return x
        \\def use(v):
        \\    return f"got {helper(v)!r} done"
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    const use = findSym(out.items, "use").?;
    var saw = false;
    for (use.refs) |r| {
        if (std.mem.eql(u8, r.name, "helper")) {
            saw = true;
            try testing.expectEqual(RefKind.call, r.kind);
        }
    }
    try testing.expect(saw);
}

test "cpp: -> and :: member calls record the receiver as the qualifier" {
    const src =
        \\struct Engine { void spin(); };
        \\void run(Engine* e) {
        \\    e->spin();
        \\    Engine::boot();
        \\}
    ;
    var out = try parseForTest(src, .cpp);
    defer freeRefs(&out);
    const run = findSym(out.items, "run").?;
    var arrow_q: []const u8 = "";
    var scope_q: []const u8 = "";
    for (run.refs) |r| {
        if (std.mem.eql(u8, r.name, "spin")) arrow_q = r.qualifier;
        if (std.mem.eql(u8, r.name, "boot")) scope_q = r.qualifier;
    }
    try testing.expectEqualStrings("e", arrow_q);
    try testing.expectEqualStrings("Engine", scope_q);
}

test "ts: optional-chaining and non-null member calls record the receiver" {
    const src =
        \\function a(s: any) { return s?.runJob(1); }
        \\function b(s: any) { return s!.runJob(2); }
    ;
    var out = try parseForTest(src, .typescript);
    defer freeRefs(&out);
    inline for (.{ "a", "b" }) |fname| {
        const f = findSym(out.items, fname).?;
        var q: []const u8 = "";
        for (f.refs) |r| {
            if (std.mem.eql(u8, r.name, "runJob")) q = r.qualifier;
        }
        try testing.expectEqualStrings("s", q);
    }
}

test "c: function and macro" {
    const src =
        \\#define MAX 100
        \\int add(int a, int b) {
        \\    return a + b;
        \\}
        \\int main(void) {
        \\    return add(MAX, 1);
        \\}
    ;
    var out = try parseForTest(src, .c);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "MAX") != null);
    const add = findSym(out.items, "add").?;
    try testing.expectEqual(SymbolKind.function, add.kind);
    const main_fn = findSym(out.items, "main").?;
    var found = false;
    for (main_fn.refs) |r| {
        if (std.mem.eql(u8, r.name, "add")) found = true;
    }
    try testing.expect(found);
}

test "c: static functions have internal linkage (not exported)" {
    const src =
        \\int public_fn(void) { return 1; }
        \\static int private_fn(void) { return 2; }
    ;
    var out = try parseForTest(src, .c);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "public_fn").?.exported);
    try testing.expect(!findSym(out.items, "private_fn").?.exported);
}

test "zig: captures member qualifiers and local/param bindings" {
    const src =
        \\pub fn run(ctx: *Ctx) void {
        \\    var list = std.ArrayList(u8).init(ctx);
        \\    ctx.begin();
        \\    list.append(1);
        \\}
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    const run = findSym(out.items, "run").?;

    var saw_ctx_begin = false;
    for (run.refs) |r| {
        if (std.mem.eql(u8, r.name, "begin")) {
            try testing.expectEqualStrings("ctx", r.qualifier);
            saw_ctx_begin = true;
        }
    }
    try testing.expect(saw_ctx_begin);

    // Param `ctx: *Ctx` and local `list = std.ArrayList(...)` are typed.
    try testing.expectEqualStrings("Ctx", bindingType(run.bindings, "ctx").?);
    try testing.expectEqualStrings("ArrayList", bindingType(run.bindings, "list").?);
}

test "ts: methods with return types and generics are parsed and typed" {
    const src =
        \\class Cache {
        \\  clear(): void {}
        \\  get<T>(k: string): T { return this.clear(); }
        \\}
        \\function handler(c: Cache): void {
        \\  c.clear();
        \\}
    ;
    var out = try parseForTest(src, .typescript);
    defer freeRefs(&out);

    // Return-type-annotated and generic methods must still be indexed.
    const clear = findSym(out.items, "clear").?;
    try testing.expectEqual(SymbolKind.method, clear.kind);
    try testing.expect(findSym(out.items, "get") != null);

    // The typed param `c: Cache` yields a receiver binding; `c.clear()` is a
    // qualified ref that later resolves to Cache.clear.
    const handler = findSym(out.items, "handler").?;
    try testing.expectEqualStrings("Cache", bindingType(handler.bindings, "c").?);
    var saw = false;
    for (handler.refs) |r| {
        if (std.mem.eql(u8, r.name, "clear")) {
            try testing.expectEqualStrings("c", r.qualifier);
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "cpp: classes, namespaces, methods, and ctor init-lists" {
    const src =
        \\namespace geo {
        \\class Shape {
        \\public:
        \\    double area() const;
        \\    const char* name() const { return "s"; }
        \\};
        \\class Circle : public Shape {
        \\public:
        \\    Circle(double r) : radius_(r) {}
        \\    double area() const { return 3.14 * radius_; }
        \\private:
        \\    double radius_;
        \\};
        \\template<typename T> T max_of(T a, T b) { return a > b ? a : b; }
        \\double total_area(const Shape& s) { return s.area(); }
        \\}
    ;
    var out = try parseForTest(src, .cpp);
    defer freeRefs(&out);
    // Namespace surfaces as a module; both classes and their methods are indexed.
    try testing.expect(findSym(out.items, "geo") != null);
    const shape = findSym(out.items, "Shape").?;
    try testing.expectEqual(SymbolKind.class, shape.kind);
    try testing.expect(findSym(out.items, "Circle") != null);
    try testing.expect(findSym(out.items, "area") != null);
    try testing.expect(findSym(out.items, "name") != null);
    // Namespace-scoped free/template functions are visible (not swallowed).
    try testing.expect(findSym(out.items, "max_of") != null);
    try testing.expect(findSym(out.items, "total_area") != null);
    // The ctor member-initializer `radius_(r)` must NOT become a function.
    for (out.items) |s| {
        if (std.mem.eql(u8, s.name, "radius_")) try testing.expect(s.kind != .function and s.kind != .method);
    }
}

test "ts: interface, enum, and type alias are indexed" {
    const src =
        \\export interface User { id: number; name: string; }
        \\export type Id = number;
        \\export enum Role { Admin, Editor }
        \\export function make(): User { return { id: 1, name: "x" }; }
    ;
    var out = try parseForTest(src, .typescript);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.interface, findSym(out.items, "User").?.kind);
    try testing.expectEqual(SymbolKind.type, findSym(out.items, "Id").?.kind);
    try testing.expectEqual(SymbolKind.@"enum", findSym(out.items, "Role").?.kind);
    try testing.expect(findSym(out.items, "make") != null);
}

test "ts: interface/type/enum are NOT extracted from plain JS" {
    // These are TS-only; a `.js` file must not spuriously emit them.
    const src =
        \\function type(x) { return x; }
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "type") != null); // a function named `type`
}

test "js: require() emits a CommonJS import binding; destructured emits module edge" {
    const src =
        \\const db = require('./db');
        \\const { readFile } = require('fs');
        \\function run() { return db.all(); }
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    var db_binding = false;
    var fs_edge = false;
    for (out.items) |s| {
        if (s.kind != .import) continue;
        if (std.mem.eql(u8, s.name, "db") and std.mem.eql(u8, s.import_path, "./db")) db_binding = true;
        if (std.mem.eql(u8, s.import_path, "fs")) fs_edge = true;
    }
    try testing.expect(db_binding);
    try testing.expect(fs_edge);
}

test "ts: export-from re-export records a module import edge" {
    const src =
        \\export { ApiClient } from './client';
        \\export type { User } from './client';
        \\export * from './helpers';
    ;
    var out = try parseForTest(src, .typescript);
    defer freeRefs(&out);
    var to_client = false;
    var to_helpers = false;
    for (out.items) |s| {
        if (s.kind != .import) continue;
        if (std.mem.eql(u8, s.import_path, "./client")) to_client = true;
        if (std.mem.eql(u8, s.import_path, "./helpers")) to_helpers = true;
    }
    try testing.expect(to_client);
    try testing.expect(to_helpers);
}

test "python: relative imports keep their leading dots in the module path" {
    const src =
        \\from ..services.user_service import UserService
        \\from .routes import router
        \\from . import models
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    var rel2 = false;
    var rel1 = false;
    var dot_only = false;
    for (out.items) |s| {
        if (s.kind != .import) continue;
        if (std.mem.eql(u8, s.import_path, "..services.user_service")) rel2 = true;
        if (std.mem.eql(u8, s.import_path, ".routes")) rel1 = true;
        if (std.mem.eql(u8, s.import_path, ".")) dot_only = true;
    }
    try testing.expect(rel2);
    try testing.expect(rel1);
    try testing.expect(dot_only);
}

test "c#: namespace, class, interface, enum, methods and constructor" {
    const src =
        \\using System;
        \\using System.Collections.Generic;
        \\
        \\namespace Shop.Domain;
        \\
        \\public interface IRepository
        \\{
        \\    void Save(int id);
        \\}
        \\
        \\public enum Status { Pending, Shipped }
        \\
        \\public class Order
        \\{
        \\    public Order(int id) { Id = id; }
        \\    public void AddItem(int sku) { this.Recount(); }
        \\    private int Recount() { return 0; }
        \\}
    ;
    var out = try parseForTest(src, .csharp);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.module, findSym(out.items, "Domain").?.kind);
    try testing.expectEqual(SymbolKind.interface, findSym(out.items, "IRepository").?.kind);
    try testing.expectEqual(SymbolKind.@"enum", findSym(out.items, "Status").?.kind);
    try testing.expectEqual(SymbolKind.class, findSym(out.items, "Order").?.kind);
    // Constructor, interface method and class methods are all captured as methods.
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "Save").?.kind);
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "AddItem").?.kind);
    const recount = findSym(out.items, "Recount").?;
    try testing.expectEqual(SymbolKind.method, recount.kind);

    // `this.Recount()` is a qualified member call: the receiver is captured so
    // resolution can bind it to the sibling method.
    const add = findSym(out.items, "AddItem").?;
    var saw = false;
    for (add.refs) |r| {
        if (std.mem.eql(u8, r.name, "Recount")) {
            try testing.expectEqualStrings("this", r.qualifier);
            saw = true;
        }
    }
    try testing.expect(saw);
}

test "c#: using directives (plain, static, alias) become imports" {
    const src =
        \\using System;
        \\using static System.Math;
        \\using Json = System.Text.Json;
        \\namespace App;
        \\class C { void M() {} }
    ;
    var out = try parseForTest(src, .csharp);
    defer freeRefs(&out);
    var plain = false;
    var static_ns = false;
    var alias = false;
    for (out.items) |s| {
        if (s.kind != .import) continue;
        if (std.mem.eql(u8, s.import_path, "System")) plain = true;
        if (std.mem.eql(u8, s.import_path, "System.Math")) static_ns = true;
        if (std.mem.eql(u8, s.import_path, "System.Text.Json")) {
            alias = true;
            try testing.expectEqualStrings("Json", s.name);
        }
    }
    try testing.expect(plain);
    try testing.expect(static_ns);
    try testing.expect(alias);
}

fn bindingType(bindings: []const Binding, name: []const u8) ?[]const u8 {
    for (bindings) |b| if (std.mem.eql(u8, b.name, name)) return b.type_name;
    return null;
}

fn freeRefs(out: *std.ArrayList(ParsedSymbol)) void {
    for (out.items) |s| {
        for (s.refs) |ref| if (ref.lines.len != 0) testing.allocator.free(ref.lines);
        if (s.refs.len != 0) testing.allocator.free(s.refs);
        if (s.bindings.len != 0) testing.allocator.free(s.bindings);
    }
    out.deinit(testing.allocator);
}
