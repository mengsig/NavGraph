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
    /// Transient (never cached): a Go method's receiver type name
    /// (`func (m *Metrics) Provision(…)` → "Metrics"). The Go post-pass
    /// (`attachGoReceivers`) resolves it to `parent_local` when the type is
    /// declared in the same file, then it is dead weight.
    receiver: []const u8 = "",
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

/// Parse-health signal for one file. `desync_from` is set when the tokenizer
/// likely lost sync — an unterminated string/char literal ran to end-of-file,
/// swallowing the code after it — with the 1-based line range that was lost.
pub const ParseHealth = model.ParseHealth;

/// Parse `source` for `lang`, appending discovered symbols to `out`. Returns a
/// `ParseHealth` so callers can warn about a tokenizer desync (a confidently
/// wrong, silently-truncated parse is the worst failure mode for an agent).
/// `arena` owns the reference slices and lives as long as the graph.
pub fn parse(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    lang: language.Language,
    out: *std.ArrayList(ParsedSymbol),
) !ParseHealth {
    std.debug.assert(source.len <= std.math.maxInt(u32));
    const cfg = language.configFor(lang);
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try lexer.tokenize(gpa, source, cfg, &toks);
    std.debug.assert(toks.items.len >= 1); // always an eof token
    const health = scanHealth(source, toks.items);

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
        .ckw = switch (lang) {
            .csharp => cs_keywords,
            .go => go_keywords,
            .rust => rust_keywords,
            .ruby => ruby_keywords,
            else => c_keywords,
        },
    };
    const n: u32 = @intCast(toks.items.len - 1); // exclude eof from scans
    switch (lang.family()) {
        .zig => try parseZigScope(&ctx, 0, n, null),
        .c, .csharp => try parseCScope(&ctx, 0, n, null),
        .js => try parseJsScope(&ctx, 0, n, null),
        .python => try parsePython(&ctx),
        .lua => try parseLuaScope(&ctx, 0, n, null),
        .go => {
            try parseGoScope(&ctx, 0, n, null);
            attachGoReceivers(&ctx);
        },
        .rust => try parseRustScope(&ctx, 0, n, null, false),
        .ruby => try parseRubyScope(&ctx, 0, n, null),
        .other => {},
    }
    try detectApi(&ctx, n);
    return health;
}

/// Detect a tokenizer desync: an unterminated single-line string/char literal
/// (opened by `"` or `'`) that ran to end-of-file. Its closing delimiter is
/// missing, so every symbol after the opener was swallowed. Triple-quoted and
/// template literals legitimately reach EOF, so only plain-quote openers whose
/// final byte is not their own (unescaped) closing quote count.
fn scanHealth(source: []const u8, toks: []const Token) ParseHealth {
    if (source.len == 0) return .{};
    for (toks) |t| {
        if (t.kind != .string or t.end != source.len) continue;
        std.debug.assert(t.start < source.len);
        const open = source[t.start];
        if (open != '"' and open != '\'') continue; // not a plain-quote literal
        if (t.end - t.start >= 3 and source[t.start + 1] == open and source[t.start + 2] == open) continue; // triple-quoted
        if (t.end - t.start >= 2 and source[t.end - 1] == open) continue; // properly closed
        var last_line = t.line;
        var i = t.start;
        while (i < source.len) : (i += 1) {
            if (source[i] == '\n') last_line += 1;
        }
        return .{ .desync_from = t.line, .desync_to = last_line };
    }
    return .{};
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
    // Router mounts (`app.include_router(mod.router, prefix="/v1")`): recorded as
    // `.route_mount` symbols so `index` can prefix the mounted module's routes
    // across files (the routes live in a different file than the mount).
    i = 0;
    while (i < n) : (i += 1) {
        if (api.matchIncludeRouter(ctx.toks, ctx.source, i)) |m| try emitMount(ctx, m, i);
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

/// Emit a `.route_mount` symbol for a router mount. `name` carries the mount
/// prefix and `import_path` the module qualifier of the mounted router
/// (`orders.router` → "orders", bare → ""); `index` resolves the mounted module
/// to a file and prefixes its routes.
fn emitMount(ctx: *Ctx, m: api.RouterMount, recv_i: u32) !void {
    const span_start = lineStartOffset(ctx, recv_i);
    const span_end = ctx.toks[recv_i].end;
    std.debug.assert(span_start <= span_end);
    _ = try emit(ctx, .{
        .name = try ctx.arena.dupe(u8, m.prefix),
        .kind = .route_mount,
        .line = ctx.toks[recv_i].line,
        .span_start = span_start,
        .span_end = span_end,
        .sig_end = span_end,
        .doc = "",
        .exported = false,
        .parent_local = null,
        .refs = &.{},
        .import_path = try ctx.arena.dupe(u8, m.module),
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

fn collectPyDoc(ctx: *const Ctx, def_i: u32, body_lo: u32, body_hi: u32) []const u8 {
    std.debug.assert(body_lo <= body_hi);
    const leading = collectDoc(ctx, def_i);
    if (leading.len != 0) return leading;
    var i = body_lo;
    while (i < body_hi and isComment(ctx, i)) : (i += 1) {}
    if (i < body_hi and ctx.toks[i].kind == .string) return ctx.toks[i].text(ctx.source);
    return "";
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
    var offset_lists: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (offset_lists.items) |*ol| ol.deinit(ctx.gpa);
        offset_lists.deinit(ctx.gpa);
    }

    var i = lo;
    while (i < hi) : (i += 1) {
        const t = ctx.toks[i];
        if (t.kind != .identifier) continue;
        const name = t.text(ctx.source);
        if (name.len < 2 or kw.has(name)) continue;
        const member_qualifier = memberQualifier(ctx, i, lo);
        const assignment = assignmentAccess(ctx, i, hi);
        const qualifier = if (assignment.write and member_qualifier.len == 0)
            enclosingCallQualifier(ctx, i, lo)
        else
            member_qualifier;
        // Skip only a *bare* self-reference (recursion noise). A qualified call
        // like `other.foo()` from inside `foo` is a real edge to keep.
        if (qualifier.len == 0 and std.mem.eql(u8, name, self_name)) continue;
        // A JS/TS object-literal property key (`{ count: ... }`) names a field,
        // not a reference to a same-named binding — don't emit an edge for it.
        if (member_qualifier.len == 0 and isJsObjectKey(ctx, i, lo, hi)) continue;
        const is_call = i + 1 < hi and ctx.isPunct(i + 1, '(');
        if (assignment.read) {
            try recordRef(ctx, &refs, &line_lists, &offset_lists, &seen, name, qualifier, t.line, t.start, is_call, false);
        }
        if (assignment.write) {
            try recordRef(ctx, &refs, &line_lists, &offset_lists, &seen, name, qualifier, t.line, t.start, false, true);
        }
    }
    // Keep the distinct-line list only when a ref spans more than one line; a
    // single-site ref falls back to `line` and needs no allocation.
    for (refs.items, line_lists.items, offset_lists.items) |*r, ll, ol| {
        if (ll.items.len > 1) r.lines = try ctx.arena.dupe(u32, ll.items);
        std.debug.assert(ol.items.len == r.count);
        r.offsets = try ctx.arena.dupe(u32, ol.items);
    }
    return .{
        .refs = try ctx.arena.dupe(Reference, refs.items),
        .bindings = try collectBindings(ctx, params_open, lo, hi),
    };
}

/// Classify a direct assignment target. Augmented assignment is both a read and
/// a write; comparisons remain reads.
fn assignmentAccess(ctx: *const Ctx, i: u32, hi: u32) struct { read: bool, write: bool } {
    std.debug.assert(i < hi);
    std.debug.assert(hi <= ctx.toks.len);
    if (i + 1 >= hi) return .{ .read = true, .write = false };
    if (ctx.isPunct(i + 1, '=') and (i + 2 >= hi or !ctx.isPunct(i + 2, '=')))
        return .{ .read = false, .write = true };
    if (i + 2 < hi and ctx.cfg.language.family() == .go and ctx.isPunct(i + 1, ':') and ctx.isPunct(i + 2, '='))
        return .{ .read = false, .write = true };
    if (i + 2 < hi and ((ctx.isPunct(i + 1, '+') and ctx.isPunct(i + 2, '+')) or
        (ctx.isPunct(i + 1, '-') and ctx.isPunct(i + 2, '-'))))
    {
        return .{ .read = true, .write = true };
    }
    const compound = ctx.isPunct(i + 1, '+') or ctx.isPunct(i + 1, '-') or
        ctx.isPunct(i + 1, '*') or ctx.isPunct(i + 1, '/') or ctx.isPunct(i + 1, '%') or
        ctx.isPunct(i + 1, '&') or ctx.isPunct(i + 1, '|') or ctx.isPunct(i + 1, '^');
    if (i + 2 < hi and compound and ctx.isPunct(i + 2, '=')) return .{ .read = true, .write = true };
    if (i + 3 < hi and compound and ctx.ch(i + 1) == ctx.ch(i + 2) and ctx.isPunct(i + 3, '='))
        return .{ .read = true, .write = true };
    return .{ .read = true, .write = false };
}

fn enclosingCallQualifier(ctx: *const Ctx, i: u32, lo: u32) []const u8 {
    std.debug.assert(lo <= i);
    std.debug.assert(i < ctx.toks.len);
    var depth: u32 = 0;
    var j = i;
    while (j > lo) {
        j -= 1;
        if (ctx.isPunct(j, ')') or ctx.isPunct(j, ']') or ctx.isPunct(j, '}')) {
            depth += 1;
            continue;
        }
        const opening = ctx.isPunct(j, '(') or ctx.isPunct(j, '[') or ctx.isPunct(j, '{');
        if (!opening) continue;
        if (depth > 0) {
            depth -= 1;
            continue;
        }
        if (!ctx.isPunct(j, '(')) return "";
        if (j > lo and ctx.toks[j - 1].kind == .identifier) return ctx.textOf(j - 1);
        return "";
    }
    return "";
}

/// If token `i` is the trailing member of a member access, return the receiver
/// identifier; otherwise "".
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

/// Whether token `i` is a JS/TS object-literal property key: an identifier
/// preceded by `{` or `,` and followed by `:` (`{ key: v }`, `, key: v`). Such a
/// key names a field, not a reference to a same-named binding, so it must not
/// become a call/read edge. Gated to the JS family: in Python `{name: v}` the key
/// `name` *is* a variable reference and must stay an edge.
fn isJsObjectKey(ctx: *const Ctx, i: u32, lo: u32, hi: u32) bool {
    if (ctx.cfg.language.family() != .js) return false;
    if (i <= lo or i + 1 >= hi) return false;
    if (!ctx.isPunct(i + 1, ':')) return false;
    return ctx.isPunct(i - 1, '{') or ctx.isPunct(i - 1, ',');
}

fn recordRef(
    ctx: *Ctx,
    refs: *std.ArrayList(Reference),
    line_lists: *std.ArrayList(std.ArrayList(u32)),
    offset_lists: *std.ArrayList(std.ArrayList(u32)),
    seen: *std.StringHashMap(u32),
    name: []const u8,
    qualifier: []const u8,
    line: u32,
    offset: u32,
    is_call: bool,
    write: bool,
) !void {
    std.debug.assert(name.len > 0);
    std.debug.assert(offset < ctx.source.len);
    std.debug.assert(!is_call or !write);
    // Direction participates in deduplication so a read and write of the same
    // member retain separate source lines and access modes.
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}\x00{c}", .{ qualifier, name, if (write) @as(u8, 'w') else 'r' }) catch name;
    if (seen.get(key)) |idx| {
        var r = &refs.items[idx];
        r.count += 1;
        if (is_call) r.kind = .call;
        // Record a new distinct call-site line. Tokens are scanned in source
        // order, so lines are non-decreasing — compare against the last kept.
        const ll = &line_lists.items[idx];
        if (ll.items.len == 0 or ll.items[ll.items.len - 1] != line) try ll.append(ctx.gpa, line);
        try offset_lists.items[idx].append(ctx.gpa, offset);
        return;
    }
    try seen.put(try ctx.gpa.dupe(u8, key), @intCast(refs.items.len));
    try refs.append(ctx.gpa, .{
        .name = name,
        .qualifier = qualifier,
        .line = line,
        .kind = if (is_call) .call else .read,
        .write = write,
        .count = 1,
    });
    var ll: std.ArrayList(u32) = .empty;
    try ll.append(ctx.gpa, line);
    try line_lists.append(ctx.gpa, ll);
    var ol: std.ArrayList(u32) = .empty;
    try ol.append(ctx.gpa, offset);
    try offset_lists.append(ctx.gpa, ol);
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
        if (expect_name and ctx.toks[i].kind == .identifier) {
            // Record every parameter name so a bare reference to it in the body
            // is treated as a local, not a same-named global. Capture the
            // annotated type (`name: T`) when present for receiver resolution;
            // an untyped param still shadows the global (empty type).
            var ty: []const u8 = "";
            if (ctx.isPunct(i + 1, ':')) {
                if (typeFromChain(ctx, i + 2, close)) |t| ty = t;
            }
            try list.append(ctx.gpa, .{ .name = ctx.textOf(i), .type_name = ty });
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
        // Capture the name even when no type can be inferred: an untyped local
        // (`const x = f()`) still shadows a same-named global for bare-reference
        // resolution (empty type just means "no receiver type known").
        const ty = inferDeclType(ctx, i + 1, hi) orelse "";
        return .{ .name = ctx.textOf(i + 1), .type_name = ty };
    }
    // Python `for NAME in …`, `with … as NAME`, `except … as NAME`: loop and
    // context variables are locals; an unrecorded one used to leak as a bare
    // ref and bind cross-file to any same-named global (a trial's
    // `for envvar in self.envvar:` pointed at an unrelated example script's
    // `envvar`). Python-gated: `as` is an expression operator in C# and an
    // import alias elsewhere.
    if (ctx.cfg.language.family() == .python and
        (ctx.identEql(i, "for") or ctx.identEql(i, "as")))
    {
        if (i + 1 < hi and ctx.toks[i + 1].kind == .identifier) {
            return .{ .name = ctx.textOf(i + 1), .type_name = "" };
        }
        return null;
    }
    const first_on_line = i == lo or ctx.toks[i - 1].line != t.line;
    if (!first_on_line) return null;
    // Go short declaration `name := …` (tokens `:` `=`).
    if (ctx.isPunct(i + 1, ':') and ctx.isPunct(i + 2, '=')) {
        return .{ .name = ctx.textOf(i), .type_name = typeFromRhs(ctx, i + 3, hi) orelse "" };
    }
    // Bare assignment at line start: `name = RHS` (python/js). Typed when the
    // RHS constructs a known type; still recorded untyped otherwise so the
    // local shadows same-named globals.
    if (!ctx.isPunct(i + 1, '=') or ctx.isPunct(i + 2, '=')) return null;
    const ty = typeFromRhs(ctx, i + 2, hi) orelse "";
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
    .{"const"},   .{"var"},      .{"fn"},          .{"pub"},    .{"return"},   .{"if"},
    .{"else"},    .{"while"},    .{"for"},         .{"switch"}, .{"struct"},   .{"enum"},
    .{"union"},   .{"try"},      .{"catch"},       .{"defer"},  .{"errdefer"}, .{"comptime"},
    .{"inline"},  .{"and"},      .{"or"},          .{"orelse"}, .{"test"},     .{"error"},
    .{"break"},   .{"continue"}, .{"opaque"},      .{"extern"}, .{"export"},   .{"usingnamespace"},
    .{"anytype"}, .{"void"},     .{"unreachable"},
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
    if (ctx.identEql(k, "test")) return parseZigTest(ctx, i, k, hi, parent);
    return i;
}

/// A Zig `test "name" { ... }` block (or `test ident {}` / `test {}`). Emitted as
/// a `.test_case` symbol whose body references are collected like any function's,
/// so `callers foo` can show the tests that exercise `foo` and `coverage` can
/// measure test reach. The name is the test string / identifier, or "test".
fn parseZigTest(ctx: *Ctx, start_i: u32, test_i: u32, hi: u32, parent: ?u32) !u32 {
    var name: []const u8 = "test";
    var j = test_i + 1;
    if (j < hi and ctx.toks[j].kind == .string) {
        name = stripQuotes(ctx.textOf(j));
        j += 1;
    } else if (j < hi and ctx.toks[j].kind == .identifier) {
        name = ctx.textOf(j);
        j += 1;
        while (j + 1 < hi and ctx.isPunct(j, '.') and ctx.toks[j + 1].kind == .identifier) j += 2;
    }
    const body_open = findNext(ctx, j, hi, '{');
    if (body_open == sentinel or ctx.close[body_open] == sentinel) return start_i;
    // A braceless `test` (a syntax error mid-edit) must not swallow the *next*
    // declaration's `{}` body: if a top-level decl keyword intervenes before the
    // brace, treat this `test` as malformed and consume only the keyword.
    var g = j;
    while (g < body_open) : (g += 1) {
        if (isLineStart(ctx, g) and (ctx.identEql(g, "fn") or ctx.identEql(g, "pub") or
            ctx.identEql(g, "const") or ctx.identEql(g, "var") or ctx.identEql(g, "test")))
            return start_i + 1;
    }
    const body_close = ctx.close[body_open];
    const span_start = lineStartOffset(ctx, start_i);
    const body = try collectRefs(ctx, sentinel, body_open + 1, body_close, "", zig_keywords);
    _ = try emit(ctx, .{
        .name = if (name.len == 0) "test" else name,
        .kind = .test_case,
        .line = ctx.toks[test_i].line,
        .span_start = span_start,
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = "",
        .exported = false,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return tokenAfterOffset(ctx, ctx.toks[body_close].end, hi);
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
    .{"if"},       .{"else"},   .{"for"},      .{"while"},   .{"return"},    .{"switch"},
    .{"case"},     .{"break"},  .{"continue"}, .{"struct"},  .{"enum"},      .{"union"},
    .{"typedef"},  .{"static"}, .{"const"},    .{"void"},    .{"int"},       .{"char"},
    .{"float"},    .{"double"}, .{"unsigned"}, .{"signed"},  .{"long"},      .{"short"},
    .{"sizeof"},   .{"goto"},   .{"do"},       .{"extern"},  .{"inline"},    .{"register"},
    .{"volatile"}, .{"class"},  .{"public"},   .{"private"}, .{"namespace"}, .{"template"},
});

/// C# control/type/modifier keywords — kept apart from `c_keywords` so the shared
/// C-family scanners skip C#-specific keywords when reading a body's references
/// and detecting member functions.
const cs_keywords = KeywordSet.initComptime(.{
    .{"if"},       .{"else"},      .{"for"},     .{"foreach"},   .{"while"},     .{"do"},
    .{"return"},   .{"switch"},    .{"case"},    .{"break"},     .{"continue"},  .{"goto"},
    .{"using"},    .{"namespace"}, .{"class"},   .{"struct"},    .{"interface"}, .{"enum"},
    .{"record"},   .{"public"},    .{"private"}, .{"protected"}, .{"internal"},  .{"static"},
    .{"readonly"}, .{"const"},     .{"virtual"}, .{"override"},  .{"abstract"},  .{"sealed"},
    .{"async"},    .{"await"},     .{"new"},     .{"this"},      .{"base"},      .{"var"},
    .{"void"},     .{"int"},       .{"string"},  .{"bool"},      .{"double"},    .{"float"},
    .{"long"},     .{"short"},     .{"byte"},    .{"char"},      .{"object"},    .{"decimal"},
    .{"true"},     .{"false"},     .{"null"},    .{"is"},        .{"as"},        .{"typeof"},
    .{"try"},      .{"catch"},     .{"finally"}, .{"throw"},     .{"yield"},     .{"ref"},
    .{"out"},      .{"in"},        .{"where"},   .{"get"},       .{"set"},       .{"partial"},
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
            const adv = try tryCppMethod(ctx, stmt_start, i, hi, parent);
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
fn tryCppMethod(ctx: *Ctx, stmt_start: u32, name_i: u32, hi: u32, parent: u32) AllocError!u32 {
    const params_open = name_i + 1;
    const params_close = ctx.close[params_open];
    if (params_close == sentinel) return name_i;
    const exported = memberExported(ctx, stmt_start, name_i);
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
            .exported = exported,
            .parent_local = parent,
            .refs = body.refs,
            .bindings = body.bindings,
        });
        return body_close + 1;
    }
    // C# expression-bodied member: `M(...) => expr;` — the expression is the body,
    // so its calls/reads are collected. (C# only; C/C++ have no such form.)
    if (ctx.cfg.language == .csharp) {
        const arrow = csArrowBody(ctx, params_close, hi);
        if (arrow != sentinel) {
            const semi_a = findNext(ctx, arrow + 2, hi, ';');
            if (semi_a != sentinel) {
                const body = try collectRefs(ctx, params_open, arrow + 2, semi_a, ctx.textOf(name_i), ctx.ckw);
                _ = try emit(ctx, .{
                    .name = ctx.textOf(name_i),
                    .kind = .method,
                    .line = ctx.toks[name_i].line,
                    .span_start = lineStartOffset(ctx, name_i),
                    .span_end = ctx.toks[semi_a].end,
                    .sig_end = ctx.toks[arrow].start,
                    .doc = collectDoc(ctx, name_i),
                    .exported = exported,
                    .parent_local = parent,
                    .refs = body.refs,
                    .bindings = body.bindings,
                });
                return semi_a + 1;
            }
        }
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
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    return semi + 1;
}

/// Visibility of a C-family member for `--no-public`. C# has explicit access
/// modifiers, so a member marked `private`/`protected`/`internal` is not public
/// API and must not be hidden by `unused --no-public`. C/C++ members carry no
/// such keyword here and stay exported (`true`); a bare C# member (no modifier)
/// also stays `true` to avoid over-hiding (its default depends on the container).
fn memberExported(ctx: *const Ctx, stmt_start: u32, name_i: u32) bool {
    if (ctx.cfg.language != .csharp) return true;
    return !(hasKeywordBetween(ctx, stmt_start, name_i, "private") or
        hasKeywordBetween(ctx, stmt_start, name_i, "protected") or
        hasKeywordBetween(ctx, stmt_start, name_i, "internal"));
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

/// A C# expression-bodied member arrow `=>` following the parameter list closing
/// at `params_close` (allowing a couple of trailing qualifier idents). Returns the
/// index of the `=` of `=>`, or `sentinel`.
fn csArrowBody(ctx: *const Ctx, params_close: u32, hi: u32) u32 {
    var j = params_close + 1;
    var guard: u32 = 0;
    while (j + 1 < hi and guard < 4) : ({
        j += 1;
        guard += 1;
    }) {
        if (ctx.isPunct(j, '=') and ctx.isPunct(j + 1, '>')) return j;
        if (ctx.toks[j].kind == .identifier) continue;
        return sentinel;
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
    .{"const"},     .{"let"},    .{"var"},     .{"function"},  .{"return"},  .{"if"},
    .{"else"},      .{"for"},    .{"while"},   .{"switch"},    .{"case"},    .{"break"},
    .{"continue"},  .{"class"},  .{"extends"}, .{"new"},       .{"async"},   .{"await"},
    .{"import"},    .{"export"}, .{"from"},    .{"default"},   .{"typeof"},  .{"instanceof"},
    .{"this"},      .{"super"},  .{"try"},     .{"catch"},     .{"finally"}, .{"throw"},
    .{"yield"},     .{"static"}, .{"get"},     .{"set"},       .{"of"},      .{"in"},
    .{"true"},      .{"false"},  .{"null"},    .{"undefined"}, .{"void"},    .{"delete"},
    .{"interface"}, .{"type"},   .{"enum"},    .{"public"},    .{"private"}, .{"readonly"},
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
    .{"def"},      .{"class"},  .{"return"},  .{"if"},    .{"elif"},   .{"else"},
    .{"for"},      .{"while"},  .{"import"},  .{"from"},  .{"as"},     .{"with"},
    .{"try"},      .{"except"}, .{"finally"}, .{"raise"}, .{"pass"},   .{"break"},
    .{"continue"}, .{"and"},    .{"or"},      .{"not"},   .{"in"},     .{"is"},
    .{"lambda"},   .{"yield"},  .{"await"},   .{"async"}, .{"global"}, .{"nonlocal"},
    .{"True"},     .{"False"},  .{"None"},    .{"self"},  .{"del"},    .{"assert"},
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
        .doc = collectPyDoc(ctx, start_i, body_lo, term),
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
    const body_lo = if (colon != sentinel) colon + 1 else name_i + 1;
    return emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .class,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = collectPyDoc(ctx, start_i, body_lo, term),
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
// Lua
// ---------------------------------------------------------------------------

const lua_keywords = KeywordSet.initComptime(.{
    .{"and"},   .{"break"}, .{"do"},       .{"else"},  .{"elseif"}, .{"end"},
    .{"false"}, .{"for"},   .{"function"}, .{"goto"},  .{"if"},     .{"in"},
    .{"local"}, .{"nil"},   .{"not"},      .{"or"},    .{"repeat"}, .{"return"},
    .{"then"},  .{"true"},  .{"until"},    .{"while"}, .{"self"},
});

/// The name a Lua function definition binds: `function a.b:c(...)` yields the
/// last segment `c`, whether the final separator was a `:` (implicit `self`),
/// whether any receiver preceded it, and the params `(` index.
const LuaName = struct { name_i: u32, is_member: bool, is_method: bool, open_i: u32 };

fn luaFuncName(ctx: *const Ctx, start: u32, hi: u32) ?LuaName {
    if (start >= hi or ctx.toks[start].kind != .identifier) return null;
    var last = start;
    var is_member = false;
    var is_method = false;
    while (ctx.isPunct(last + 1, '.') or ctx.isPunct(last + 1, ':')) {
        if (last + 2 >= hi or ctx.toks[last + 2].kind != .identifier) break;
        is_method = ctx.isPunct(last + 1, ':');
        is_member = true;
        last += 2;
        if (is_method) break; // `:` is only valid as the final separator
    }
    const open = if (ctx.isPunct(last + 1, '(')) last + 1 else sentinel;
    return .{ .name_i = last, .is_member = is_member, .is_method = is_method, .open_i = open };
}

/// Keywords that open an `end`/`until`-terminated Lua block. `for`/`while`
/// headers are excluded: their trailing `do` opens the block and is counted
/// once here, avoiding a double count.
fn luaOpensBlock(ctx: *const Ctx, i: u32) bool {
    return ctx.identEql(i, "function") or ctx.identEql(i, "if") or
        ctx.identEql(i, "do") or ctx.identEql(i, "repeat");
}

/// Index of the `end`/`until` closing the block whose opener sits just before
/// `from`; caller passes the token after the opener's header (depth starts 1).
fn luaBlockEnd(ctx: *const Ctx, from: u32, hi: u32) u32 {
    std.debug.assert(from <= hi);
    var depth: u32 = 1;
    var i = from;
    while (i < hi) : (i += 1) {
        if (ctx.toks[i].kind != .identifier) continue;
        if (luaOpensBlock(ctx, i)) {
            depth += 1;
        } else if (ctx.identEql(i, "end") or ctx.identEql(i, "until")) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return hi;
}

/// The module string of a `require("mod")` / `require "mod"` initializer at
/// `rhs`, or null when the RHS is not a require call.
fn luaRequirePath(ctx: *const Ctx, rhs: u32, hi: u32) ?[]const u8 {
    if (rhs >= hi or !ctx.identEql(rhs, "require")) return null;
    if (ctx.isPunct(rhs + 1, '(') and rhs + 2 < hi and ctx.toks[rhs + 2].kind == .string)
        return stripQuotes(ctx.textOf(rhs + 2));
    if (rhs + 1 < hi and ctx.toks[rhs + 1].kind == .string)
        return stripQuotes(ctx.textOf(rhs + 1));
    return null;
}

fn parseLuaScope(ctx: *Ctx, lo: u32, hi: u32, parent: ?u32) AllocError!void {
    var i = lo;
    while (i < hi) {
        const t = ctx.toks[i];
        if (t.kind != .identifier or !isLineStart(ctx, i)) {
            i += 1;
            continue;
        }
        const adv = try parseLuaStmt(ctx, i, hi, parent);
        i = if (adv > i) adv else i + 1;
    }
}

/// Dispatch a Lua statement whose first token (`i`) starts a line. Returns the
/// token index just past a recognised definition, or `i` when none matched.
fn parseLuaStmt(ctx: *Ctx, i: u32, hi: u32, parent: ?u32) !u32 {
    if (ctx.identEql(i, "function")) return parseLuaFunction(ctx, i, i, hi, parent, false);
    if (ctx.identEql(i, "local")) {
        if (i + 1 < hi and ctx.identEql(i + 1, "function"))
            return parseLuaFunction(ctx, i, i + 1, hi, parent, true);
        return parseLuaAssign(ctx, i, i + 1, hi, parent, true);
    }
    if (lua_keywords.has(ctx.textOf(i))) return i;
    return parseLuaAssign(ctx, i, i, hi, parent, false);
}

fn parseLuaFunction(ctx: *Ctx, start_i: u32, fn_i: u32, hi: u32, parent: ?u32, is_local: bool) !u32 {
    const nm = luaFuncName(ctx, fn_i + 1, hi) orelse return start_i;
    if (nm.open_i == sentinel or ctx.close[nm.open_i] == sentinel) return start_i;
    const params_close = ctx.close[nm.open_i];
    const end_i = luaBlockEnd(ctx, params_close + 1, hi);
    const name = ctx.textOf(nm.name_i);
    const span_end = if (end_i < hi) ctx.toks[end_i].end else @as(u32, @intCast(ctx.source.len));
    const body = try collectRefs(ctx, nm.open_i, params_close + 1, end_i, name, lua_keywords);
    _ = try emit(ctx, .{
        .name = name,
        .kind = if (nm.is_member) .method else .function,
        .line = ctx.toks[nm.name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = span_end,
        .sig_end = ctx.toks[params_close].end,
        .doc = collectDoc(ctx, start_i),
        .exported = !is_local,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return if (end_i < hi) end_i + 1 else hi;
}

/// Parse `[local] NAME[.field|:method]* = RHS`. `ns` is the first target token
/// (after `local` when present). Handles require-imports, function-expression
/// values, and plain variable/table bindings.
fn parseLuaAssign(ctx: *Ctx, start_i: u32, ns: u32, hi: u32, parent: ?u32, is_local: bool) !u32 {
    if (ns >= hi or ctx.toks[ns].kind != .identifier) return start_i;
    var name_i = ns;
    var is_member = false;
    while (ctx.isPunct(name_i + 1, '.') or ctx.isPunct(name_i + 1, ':')) {
        if (name_i + 2 >= hi or ctx.toks[name_i + 2].kind != .identifier) break;
        is_member = true;
        name_i += 2;
    }
    // Only a simple binding: the `=` must directly follow the lvalue name chain.
    // A call/index lvalue (`f(x).y =`, `t[k] =`) or a comparison (`==`, `~=`,
    // `<=`, `>=` — whose `=` sits inside an expression) is not a definition.
    if (!ctx.isPunct(name_i + 1, '=') or ctx.isPunct(name_i + 2, '=')) return start_i;
    const rhs = name_i + 2;
    if (!is_member) {
        if (luaRequirePath(ctx, rhs, hi)) |path| return emitLuaImport(ctx, start_i, name_i, path, hi);
    }
    if (rhs < hi and ctx.identEql(rhs, "function"))
        return parseLuaFuncExpr(ctx, start_i, name_i, rhs, hi, parent, is_local, is_member);
    return parseLuaVar(ctx, start_i, name_i, rhs, hi, parent, is_local, is_member);
}

fn emitLuaImport(ctx: *Ctx, start_i: u32, name_i: u32, path: []const u8, hi: u32) !u32 {
    const span_end = lineEndOffset(ctx, ctx.toks[start_i].start);
    _ = try emit(ctx, importSymbol(ctx.textOf(name_i), path, ctx.toks[name_i].line, lineStartOffset(ctx, start_i), span_end));
    return tokenAfterOffset(ctx, span_end, hi);
}

fn parseLuaFuncExpr(ctx: *Ctx, start_i: u32, name_i: u32, fn_kw: u32, hi: u32, parent: ?u32, is_local: bool, is_member: bool) !u32 {
    const open = if (ctx.isPunct(fn_kw + 1, '(')) fn_kw + 1 else sentinel;
    if (open == sentinel or ctx.close[open] == sentinel) return start_i;
    const params_close = ctx.close[open];
    const end_i = luaBlockEnd(ctx, params_close + 1, hi);
    const name = ctx.textOf(name_i);
    const span_end = if (end_i < hi) ctx.toks[end_i].end else @as(u32, @intCast(ctx.source.len));
    const body = try collectRefs(ctx, open, params_close + 1, end_i, name, lua_keywords);
    _ = try emit(ctx, .{
        .name = name,
        .kind = if (is_member) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = span_end,
        .sig_end = ctx.toks[params_close].end,
        .doc = collectDoc(ctx, start_i),
        .exported = !is_local,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return if (end_i < hi) end_i + 1 else hi;
}

fn parseLuaVar(ctx: *Ctx, start_i: u32, name_i: u32, rhs: u32, hi: u32, parent: ?u32, is_local: bool, is_member: bool) !u32 {
    const first_line_end = lineEndOffset(ctx, ctx.toks[start_i].start);
    const line = ctx.toks[name_i].line;
    var span_end = first_line_end;
    // A direct table literal `= { ... }` has its function fields extracted below.
    const table_open: u32 = if (rhs < hi and ctx.isPunct(rhs, '{') and ctx.close[rhs] != sentinel) rhs else sentinel;
    // Extend the span across any bracketed value that continues onto later lines
    // (`= f({ ... })`, `= {\n ... \n}`), so the multi-line body is not rescanned
    // as if it were top-level statements (the source of phantom symbols).
    var j = rhs;
    while (j < hi and ctx.toks[j].line == line) {
        const opener = ctx.isPunct(j, '(') or ctx.isPunct(j, '{') or ctx.isPunct(j, '[');
        if (opener and ctx.close[j] != sentinel) {
            span_end = @max(span_end, ctx.toks[ctx.close[j]].end);
            j = ctx.close[j] + 1;
        } else j += 1;
    }
    const idx = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (is_member) .field else .variable,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = span_end,
        .sig_end = first_line_end,
        .doc = collectDoc(ctx, start_i),
        .exported = !is_local,
        .parent_local = parent,
        .refs = &.{},
    });
    if (table_open != sentinel) try parseLuaTableFields(ctx, table_open, ctx.close[table_open], idx);
    return tokenAfterOffset(ctx, span_end, hi);
}

/// Emit a `method` for each `NAME = function(...) ... end` field of the table
/// constructor `(open, close)` — the module-table pattern `local M = { f = ... }`.
fn parseLuaTableFields(ctx: *Ctx, open: u32, close: u32, parent: u32) !void {
    std.debug.assert(open < close);
    var i = open + 1;
    while (i < close) : (i += 1) {
        if (ctx.toks[i].kind != .identifier) continue;
        if (!ctx.isPunct(i + 1, '=') or !ctx.identEql(i + 2, "function")) continue;
        const fn_kw = i + 2;
        const p_open = if (ctx.isPunct(fn_kw + 1, '(')) fn_kw + 1 else sentinel;
        if (p_open == sentinel or ctx.close[p_open] == sentinel) continue;
        const p_close = ctx.close[p_open];
        const end_i = luaBlockEnd(ctx, p_close + 1, close);
        const name = ctx.textOf(i);
        const span_end = if (end_i < close) ctx.toks[end_i].end else ctx.toks[p_close].end;
        const body = try collectRefs(ctx, p_open, p_close + 1, end_i, name, lua_keywords);
        _ = try emit(ctx, .{
            .name = name,
            .kind = .method,
            .line = ctx.toks[i].line,
            .span_start = lineStartOffset(ctx, i),
            .span_end = span_end,
            .sig_end = ctx.toks[p_close].end,
            .doc = collectDoc(ctx, i),
            .exported = true,
            .parent_local = parent,
            .refs = body.refs,
            .bindings = body.bindings,
        });
        i = end_i;
    }
}

// ---------------------------------------------------------------------------
// Go
// ---------------------------------------------------------------------------

const go_keywords = KeywordSet.initComptime(.{
    .{"break"}, .{"case"},   .{"chan"},        .{"const"},     .{"continue"}, .{"default"},
    .{"defer"}, .{"else"},   .{"fallthrough"}, .{"for"},       .{"func"},     .{"go"},
    .{"goto"},  .{"if"},     .{"import"},      .{"interface"}, .{"map"},      .{"package"},
    .{"range"}, .{"return"}, .{"select"},      .{"struct"},    .{"switch"},   .{"type"},
    .{"var"},   .{"nil"},    .{"true"},        .{"false"},
});

/// A Go identifier is exported when its first letter is upper-case.
fn goExported(name: []const u8) bool {
    return name.len != 0 and name[0] >= 'A' and name[0] <= 'Z';
}

/// Last `/`-separated segment of an import path (`net/http` → `http`).
fn lastPathSegment(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn parseGoScope(ctx: *Ctx, lo: u32, hi: u32, parent: ?u32) AllocError!void {
    var i = lo;
    while (i < hi) {
        // `package caddy` — emitted as a `.module` symbol so package-qualified
        // calls (`caddy.Load(...)`) can resolve to this file's top-level defs.
        if (parent == null and ctx.identEql(i, "package") and isLineStart(ctx, i) and
            i + 1 < hi and ctx.toks[i + 1].kind == .identifier)
        {
            _ = try emit(ctx, .{
                .name = ctx.textOf(i + 1),
                .kind = .module,
                .line = ctx.toks[i].line,
                .span_start = lineStartOffset(ctx, i),
                .span_end = ctx.toks[i + 1].end,
                .sig_end = ctx.toks[i + 1].end,
                .doc = "",
                .exported = true,
                .parent_local = null,
                .refs = &.{},
            });
            i += 2;
            continue;
        }
        if (ctx.identEql(i, "func")) {
            const adv = try parseGoFunc(ctx, i, hi, parent);
            if (adv > i) {
                i = adv;
                continue;
            }
        }
        if (ctx.identEql(i, "type") and isLineStart(ctx, i)) {
            const adv = try parseGoType(ctx, i, hi, parent);
            if (adv > i) {
                i = adv;
                continue;
            }
        }
        if (ctx.identEql(i, "import") and isLineStart(ctx, i)) {
            const adv = try parseGoImport(ctx, i, hi);
            if (adv > i) {
                i = adv;
                continue;
            }
        }
        if ((ctx.identEql(i, "const") or ctx.identEql(i, "var")) and isLineStart(ctx, i)) {
            const adv = try parseGoConstVar(ctx, i, hi, parent);
            if (adv > i) {
                i = adv;
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

/// Package-level Go `const`/`var`, single (`const MaxN = 10`, `var total int`) or
/// grouped (`const ( A = 1\n B = 2 )`). Each declared name becomes a
/// constant/variable symbol; exportedness follows Go's capitalization rule.
fn parseGoConstVar(ctx: *Ctx, kw_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    const kind: SymbolKind = if (ctx.identEql(kw_i, "const")) .constant else .variable;
    // Grouped form: `const ( ... )` — emit each declaration's leading name.
    if (kw_i + 1 < hi and ctx.isPunct(kw_i + 1, '(')) {
        const close = ctx.close[kw_i + 1];
        if (close == sentinel) return kw_i;
        var j = kw_i + 2;
        while (j < close) {
            // Skip a bracketed value (`= newClient( … )`, `[]T{ … }`) whole, so its
            // continuation lines aren't mistaken for new declarations.
            if (ctx.isPunct(j, '(') or ctx.isPunct(j, '[') or ctx.isPunct(j, '{')) {
                const nb = skipBracket(ctx, j);
                j = if (nb > j) nb else j + 1;
                continue;
            }
            // A declaration is a line-leading identifier — unless the previous line
            // ended on a continuation token (a trailing operator like `base +`),
            // which makes this line part of the prior value, not a new name.
            if (ctx.toks[j].kind == .identifier and isLineStart(ctx, j) and
                (j == kw_i + 2 or !goLineContinues(ctx, j - 1)))
            {
                try emitGoValue(ctx, j, kind, parent);
            }
            j += 1;
        }
        return close + 1;
    }
    // Single form: `const NAME ...` / `var NAME ...`.
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return kw_i;
    try emitGoValue(ctx, kw_i + 1, kind, parent);
    return kw_i + 2;
}

/// Whether Go token `prev` ends a line that continues onto the next — a trailing
/// binary operator or separator — so the next line-leading identifier belongs to
/// this value, not a new declaration.
fn goLineContinues(ctx: *const Ctx, prev: u32) bool {
    if (ctx.toks[prev].kind != .punct) return false;
    return switch (ctx.ch(prev)) {
        '+', '-', '*', '/', '%', '&', '|', '^', '=', '<', '>', ',', '.' => true,
        else => false,
    };
}

fn emitGoValue(ctx: *Ctx, name_i: u32, kind: SymbolKind, parent: ?u32) AllocError!void {
    const name = ctx.textOf(name_i);
    const span_end = lineEndOffset(ctx, ctx.toks[name_i].start);
    _ = try emit(ctx, .{
        .name = name,
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, name_i),
        .span_end = span_end,
        .sig_end = span_end,
        .doc = "",
        .exported = goExported(name),
        .parent_local = parent,
        .refs = &.{},
    });
}

fn parseGoFunc(ctx: *Ctx, func_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    var j = func_i + 1;
    var is_method = false;
    var receiver: []const u8 = "";
    // Optional receiver: `func (r T) Name(...)`.
    if (j < hi and ctx.isPunct(j, '(')) {
        const rc = ctx.close[j];
        if (rc == sentinel) return func_i;
        receiver = goReceiverType(ctx, j, rc);
        j = rc + 1;
        is_method = true;
    }
    if (j >= hi or ctx.toks[j].kind != .identifier) return func_i;
    const name_i = j;
    var p = name_i + 1;
    // Type parameters `func F[T any](...)` precede the value parameters.
    if (ctx.isPunct(p, '[')) {
        const c = ctx.close[p];
        if (c == sentinel) return func_i;
        p = c + 1;
    }
    if (!ctx.isPunct(p, '(') or ctx.close[p] == sentinel) return func_i;
    const params_open = p;
    const params_close = ctx.close[p];
    const body_open = goBodyOpen(ctx, params_close, hi);
    if (body_open == sentinel or ctx.close[body_open] == sentinel) return func_i;
    const body_close = ctx.close[body_open];
    const name = ctx.textOf(name_i);
    const body = try collectRefs(ctx, params_open, body_open + 1, body_close, name, go_keywords);
    _ = try emit(ctx, .{
        .name = name,
        .kind = if (is_method) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, func_i),
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = collectDoc(ctx, func_i),
        .exported = goExported(name),
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
        .receiver = receiver,
    });
    return body_close + 1;
}

/// A Go-modules major-version import segment: `v2`, `v10`, ….
fn isGoVersionSegment(s: []const u8) bool {
    if (s.len < 2 or s[0] != 'v') return false;
    for (s[1..]) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The receiver *type* name of a Go method: in `(m *Metrics)` the second
/// identifier ("Metrics"); in the nameless form `(Metrics)` the only one.
/// Generic receivers `(m *Metrics[T])` still yield "Metrics" (the type
/// parameter comes after and is ignored).
fn goReceiverType(ctx: *const Ctx, open: u32, close: u32) []const u8 {
    var first: []const u8 = "";
    var k = open + 1;
    while (k < close) : (k += 1) {
        if (ctx.isPunct(k, '[')) break; // type params — done
        if (ctx.toks[k].kind != .identifier) continue;
        if (first.len == 0) {
            first = ctx.textOf(k);
        } else {
            return ctx.textOf(k); // `name *Type` — the second identifier
        }
    }
    return first;
}

/// Go post-pass: attach each method to its receiver type when that type is
/// declared in the same file (`func (m *Metrics) Provision` → parent = the
/// `Metrics` symbol), regardless of declaration order. Makes the
/// `Metrics.Provision` pin, qualified rendering, and type-scoped queries work
/// for Go the way they do for class languages.
fn attachGoReceivers(ctx: *Ctx) void {
    for (ctx.out.items, 0..) |*sym, i| {
        if (sym.kind != .method or sym.receiver.len == 0 or sym.parent_local != null) continue;
        for (ctx.out.items, 0..) |cand, ci| {
            if (ci == i) continue;
            switch (cand.kind) {
                .@"struct", .class, .interface, .type, .@"enum" => {},
                else => continue,
            }
            if (std.mem.eql(u8, cand.name, sym.receiver)) {
                sym.parent_local = @intCast(ci);
                break;
            }
        }
    }
}

/// The `{` opening a Go function body after its parameter list closes at
/// `params_close`, skipping the return type — including `interface{}`/`struct{}`
/// (whose braces are not the body), named/multiple returns `(...)`, and slice/map
/// types `[]T`. `sentinel` when a declaration has no body or another top-level
/// keyword is reached first.
fn goBodyOpen(ctx: *const Ctx, params_close: u32, hi: u32) u32 {
    var j = params_close + 1;
    while (j < hi) {
        if (ctx.isPunct(j, '{')) return j;
        if (ctx.identEql(j, "func") or ctx.identEql(j, "type") or
            ctx.identEql(j, "var") or ctx.identEql(j, "const")) return sentinel;
        if ((ctx.identEql(j, "interface") or ctx.identEql(j, "struct")) and ctx.isPunct(j + 1, '{')) {
            j = skipBracket(ctx, j + 1);
            continue;
        }
        if (ctx.isPunct(j, '(') or ctx.isPunct(j, '[')) {
            j = skipBracket(ctx, j);
            continue;
        }
        j += 1;
    }
    return sentinel;
}

fn parseGoType(ctx: *Ctx, type_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    const name_i = type_i + 1;
    if (name_i >= hi or ctx.toks[name_i].kind != .identifier) return type_i;
    const name = ctx.textOf(name_i);
    var p = name_i + 1;
    if (ctx.isPunct(p, '[')) {
        const c = ctx.close[p];
        if (c != sentinel) p = c + 1;
    }
    if (ctx.isPunct(p, '=')) p += 1; // `type Name = Underlying` alias
    if ((ctx.identEql(p, "struct") or ctx.identEql(p, "interface")) and ctx.isPunct(p + 1, '{')) {
        const open = p + 1;
        const close = ctx.close[open];
        if (close == sentinel) return type_i;
        const is_iface = ctx.identEql(p, "interface");
        const my = try emit(ctx, .{
            .name = name,
            .kind = if (is_iface) .interface else .@"struct",
            .line = ctx.toks[name_i].line,
            .span_start = lineStartOffset(ctx, type_i),
            .span_end = ctx.toks[close].end,
            .sig_end = ctx.toks[open].start,
            .doc = collectDoc(ctx, type_i),
            .exported = goExported(name),
            .parent_local = parent,
            .refs = &.{},
        });
        if (is_iface) try parseGoInterfaceMethods(ctx, open + 1, close, my);
        return close + 1;
    }
    // Defined type or alias to a non-container type: span the declaration line.
    const end = lineEndOffset(ctx, ctx.toks[name_i].start);
    _ = try emit(ctx, .{
        .name = name,
        .kind = .type,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, type_i),
        .span_end = end,
        .sig_end = end,
        .doc = collectDoc(ctx, type_i),
        .exported = goExported(name),
        .parent_local = parent,
        .refs = &.{},
    });
    return tokenAfterOffset(ctx, end, hi);
}

/// Emit a `method` for each `Name(params) ret` signature line in a Go interface
/// body [lo, hi). Embedded interfaces (a bare type name, no `(`) are skipped.
fn parseGoInterfaceMethods(ctx: *Ctx, lo: u32, hi: u32, parent: u32) AllocError!void {
    var i = lo;
    while (i < hi) : (i += 1) {
        if (ctx.toks[i].kind != .identifier or !isLineStart(ctx, i)) continue;
        if (go_keywords.has(ctx.textOf(i)) or !ctx.isPunct(i + 1, '(')) continue;
        const pc = ctx.close[i + 1];
        if (pc == sentinel) continue;
        const name = ctx.textOf(i);
        _ = try emit(ctx, .{
            .name = name,
            .kind = .method,
            .line = ctx.toks[i].line,
            .span_start = lineStartOffset(ctx, i),
            .span_end = ctx.toks[pc].end,
            .sig_end = ctx.toks[pc].end,
            .doc = collectDoc(ctx, i),
            .exported = goExported(name),
            .parent_local = parent,
            .refs = &.{},
        });
        i = pc;
    }
}

fn parseGoImport(ctx: *Ctx, import_i: u32, hi: u32) AllocError!u32 {
    const j = import_i + 1;
    if (ctx.isPunct(j, '(')) {
        const close = ctx.close[j];
        if (close == sentinel) return import_i;
        var k = j + 1;
        while (k < close) : (k += 1) {
            if (ctx.toks[k].kind != .string) continue;
            try emitGoImport(ctx, k);
        }
        return close + 1;
    }
    // Single: `import [alias|.|_] "path"`.
    var k = j;
    if (k < hi and (ctx.toks[k].kind == .identifier or ctx.isPunct(k, '.'))) k += 1;
    if (k >= hi or ctx.toks[k].kind != .string) return import_i;
    try emitGoImport(ctx, k);
    return tokenAfterOffset(ctx, ctx.toks[k].end, hi);
}

/// Emit an import for the path string at `str_i`, binding it to the preceding
/// alias identifier when one sits on the same line, else the path's last
/// segment — skipping a Go-modules major-version suffix (`…/caddy/v2` binds as
/// `caddy`, the real package name, not `v2`).
fn emitGoImport(ctx: *Ctx, str_i: u32) AllocError!void {
    const path = stripQuotes(ctx.textOf(str_i));
    if (path.len == 0) return;
    var binding = lastPathSegment(path);
    if (isGoVersionSegment(binding) and path.len > binding.len + 1) {
        binding = lastPathSegment(path[0 .. path.len - binding.len - 1]);
    }
    var span_start_tok = str_i;
    // A preceding same-line identifier is an import alias (`alias "path"`) — but
    // NOT the `import` keyword itself of a single, ungrouped `import "fmt"`, which
    // would otherwise bind the import under the name "import".
    if (str_i > 0 and ctx.toks[str_i - 1].kind == .identifier and
        ctx.toks[str_i - 1].line == ctx.toks[str_i].line and
        !ctx.identEql(str_i - 1, "import"))
    {
        binding = ctx.textOf(str_i - 1);
        span_start_tok = str_i - 1;
    }
    _ = try emit(ctx, importSymbol(binding, path, ctx.toks[str_i].line, lineStartOffset(ctx, span_start_tok), ctx.toks[str_i].end));
}

// ---------------------------------------------------------------------------
// Rust
// ---------------------------------------------------------------------------

const rust_keywords = KeywordSet.initComptime(.{
    .{"as"},    .{"break"}, .{"const"},  .{"continue"}, .{"crate"}, .{"dyn"},
    .{"else"},  .{"enum"},  .{"extern"}, .{"false"},    .{"fn"},    .{"for"},
    .{"if"},    .{"impl"},  .{"in"},     .{"let"},      .{"loop"},  .{"match"},
    .{"mod"},   .{"move"},  .{"mut"},    .{"pub"},      .{"ref"},   .{"return"},
    .{"self"},  .{"Self"},  .{"static"}, .{"struct"},   .{"super"}, .{"trait"},
    .{"true"},  .{"type"},  .{"union"},  .{"unsafe"},   .{"use"},   .{"where"},
    .{"while"}, .{"async"}, .{"await"},
});

/// Whether `pub` appears as a modifier in [lo, kw_i) — the export marker.
fn rustHasPubBetween(ctx: *const Ctx, lo: u32, kw_i: u32) bool {
    var j = lo;
    while (j < kw_i) : (j += 1) {
        if (ctx.identEql(j, "pub")) return true;
    }
    return false;
}

/// Skip a `<...>` generic clause starting at `i`, returning the index just past
/// the matching `>`. A `->` return arrow inside a bound is not counted as a
/// closing `>`. Returns `i` unchanged when `i` is not a `<`.
fn skipRustGenerics(ctx: *const Ctx, i: u32, hi: u32) u32 {
    if (!ctx.isPunct(i, '<')) return i;
    var depth: u32 = 0;
    var j = i;
    while (j < hi) : (j += 1) {
        if (ctx.isPunct(j, '<')) {
            depth += 1;
        } else if (ctx.isPunct(j, '>')) {
            if (j > i and ctx.isPunct(j - 1, '-')) continue; // `->` arrow
            depth -= 1;
            if (depth == 0) return j + 1;
        }
    }
    return i;
}

/// The `{` opening a Rust item body after `from`, skipping a return type and
/// `where` clause. `sentinel` when the item is a declaration terminated by `;`
/// (a trait method signature) before any `{`.
fn rustBodyOpen(ctx: *const Ctx, from: u32, hi: u32) u32 {
    var j = from;
    while (j < hi) {
        if (ctx.isPunct(j, '{')) return j;
        if (ctx.isPunct(j, ';')) return sentinel;
        if (ctx.isPunct(j, '(') or ctx.isPunct(j, '[')) {
            j = skipBracket(ctx, j);
            continue;
        }
        j += 1;
    }
    return sentinel;
}

fn parseRustScope(ctx: *Ctx, lo: u32, hi: u32, parent: ?u32, methods: bool) AllocError!void {
    var i = lo;
    var stmt_start = lo;
    while (i < hi) {
        // Reset the statement start only at real terminators; a `(`/`[`/`{` may be
        // a visibility qualifier (`pub(crate)`) or attribute (`#[derive(..)]`)
        // that still precedes the item keyword, so it must not clear `pub`.
        if (ctx.isPunct(i, ';') or ctx.isPunct(i, '}')) {
            i += 1;
            stmt_start = i;
            continue;
        }
        if (ctx.isPunct(i, '{') or ctx.isPunct(i, '(') or ctx.isPunct(i, '[')) {
            i = skipBracket(ctx, i);
            continue;
        }
        // `macro_rules! name { ... }`
        if (ctx.identEql(i, "macro_rules") and ctx.isPunct(i + 1, '!')) {
            const adv = try parseRustMacro(ctx, stmt_start, i, hi, parent);
            if (adv > i) {
                i = adv;
                stmt_start = i;
                continue;
            }
        }
        if (ctx.toks[i].kind == .identifier and rustItemKeyword(ctx, i)) {
            const adv = try parseRustItem(ctx, stmt_start, i, hi, parent, methods);
            if (adv > i) {
                i = adv;
                stmt_start = i;
                continue;
            }
        }
        i += 1;
    }
}

fn rustItemKeyword(ctx: *const Ctx, i: u32) bool {
    return ctx.identEql(i, "fn") or ctx.identEql(i, "struct") or ctx.identEql(i, "enum") or
        ctx.identEql(i, "union") or ctx.identEql(i, "trait") or ctx.identEql(i, "impl") or
        ctx.identEql(i, "mod") or ctx.identEql(i, "type") or ctx.identEql(i, "use") or
        ctx.identEql(i, "const") or ctx.identEql(i, "static");
}

fn parseRustItem(ctx: *Ctx, stmt_start: u32, kw_i: u32, hi: u32, parent: ?u32, methods: bool) AllocError!u32 {
    const exported = rustHasPubBetween(ctx, stmt_start, kw_i);
    // Doc/span begin at the statement's first code token (`pub`/`async`), so the
    // comment on the line above is attributed, not skipped past a modifier.
    const doc_i = firstCodeToken(ctx, stmt_start);
    if (ctx.identEql(kw_i, "fn")) return parseRustFn(ctx, doc_i, kw_i, hi, parent, exported, methods);
    if (ctx.identEql(kw_i, "use")) return parseRustUse(ctx, kw_i, hi);
    if (ctx.identEql(kw_i, "mod")) return parseRustMod(ctx, doc_i, kw_i, hi, parent);
    if (ctx.identEql(kw_i, "impl")) return parseRustImpl(ctx, kw_i, hi);
    if (ctx.identEql(kw_i, "const") or ctx.identEql(kw_i, "static")) {
        // A `const fn` / `const unsafe fn` is a function modifier, not an item;
        // let the loop reach the `fn`.
        if (rustConstIsFnModifier(ctx, kw_i, hi)) return kw_i;
        return parseRustConst(ctx, doc_i, kw_i, hi, parent, exported);
    }
    if (ctx.identEql(kw_i, "type")) return parseRustTypeAlias(ctx, doc_i, kw_i, hi, parent, exported);
    // struct / enum / union / trait
    return parseRustRecord(ctx, doc_i, kw_i, hi, parent, exported);
}

fn rustConstIsFnModifier(ctx: *const Ctx, kw_i: u32, hi: u32) bool {
    var j = kw_i + 1;
    while (j < hi and j < kw_i + 4) : (j += 1) {
        if (ctx.identEql(j, "fn")) return true;
        if (!ctx.identEql(j, "unsafe") and !ctx.identEql(j, "extern")) return false;
    }
    return false;
}

fn parseRustFn(ctx: *Ctx, doc_i: u32, fn_i: u32, hi: u32, parent: ?u32, exported: bool, methods: bool) AllocError!u32 {
    if (fn_i + 1 >= hi or ctx.toks[fn_i + 1].kind != .identifier) return fn_i;
    const name_i = fn_i + 1;
    const name = ctx.textOf(name_i);
    const p = skipRustGenerics(ctx, name_i + 1, hi);
    if (!ctx.isPunct(p, '(') or ctx.close[p] == sentinel) return fn_i;
    const params_open = p;
    const params_close = ctx.close[p];
    const body_open = rustBodyOpen(ctx, params_close + 1, hi);
    const kind: SymbolKind = if (methods) .method else .function;
    if (body_open == sentinel) {
        // Trait method signature (no body): `fn f(&self) -> T;`.
        const semi = findNext(ctx, params_close + 1, hi, ';');
        const end = if (semi != sentinel) ctx.toks[semi].end else ctx.toks[params_close].end;
        _ = try emit(ctx, .{
            .name = name,
            .kind = kind,
            .line = ctx.toks[name_i].line,
            .span_start = lineStartOffset(ctx, doc_i),
            .span_end = end,
            .sig_end = end,
            .doc = collectDoc(ctx, doc_i),
            .exported = exported,
            .parent_local = parent,
            .refs = &.{},
        });
        return if (semi != sentinel) semi + 1 else params_close + 1;
    }
    const body_close = ctx.close[body_open];
    if (body_close == sentinel) return fn_i;
    const body = try collectRefs(ctx, params_open, body_open + 1, body_close, name, rust_keywords);
    _ = try emit(ctx, .{
        .name = name,
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, doc_i),
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = collectDoc(ctx, doc_i),
        .exported = exported,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return body_close + 1;
}

fn parseRustRecord(ctx: *Ctx, doc_i: u32, kw_i: u32, hi: u32, parent: ?u32, exported: bool) AllocError!u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return kw_i;
    const name_i = kw_i + 1;
    const name = ctx.textOf(name_i);
    const kind: SymbolKind = if (ctx.identEql(kw_i, "enum"))
        .@"enum"
    else if (ctx.identEql(kw_i, "trait"))
        .interface
    else
        .@"struct";
    const p = skipRustGenerics(ctx, name_i + 1, hi);
    const open = rustBodyOpen(ctx, p, hi);
    if (open == sentinel) {
        // Unit or tuple struct: `struct Name;` / `struct Name(T);`.
        const end = lineEndOffset(ctx, ctx.toks[name_i].start);
        _ = try emit(ctx, .{
            .name = name,
            .kind = kind,
            .line = ctx.toks[name_i].line,
            .span_start = lineStartOffset(ctx, doc_i),
            .span_end = end,
            .sig_end = end,
            .doc = collectDoc(ctx, doc_i),
            .exported = exported,
            .parent_local = parent,
            .refs = &.{},
        });
        return tokenAfterOffset(ctx, end, hi);
    }
    const close = ctx.close[open];
    if (close == sentinel) return kw_i;
    const my = try emit(ctx, .{
        .name = name,
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, doc_i),
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[open].start,
        .doc = collectDoc(ctx, doc_i),
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    // A trait body holds method signatures and default methods.
    if (kind == .interface) try parseRustScope(ctx, open + 1, close, my, true);
    return close + 1;
}

fn parseRustImpl(ctx: *Ctx, impl_i: u32, hi: u32) AllocError!u32 {
    const open = rustImplBodyOpen(ctx, impl_i + 1, hi);
    if (open == sentinel or ctx.close[open] == sentinel) return impl_i;
    const close = ctx.close[open];
    // Nest methods under the implemented type when it is a known container, so
    // outline groups them; otherwise leave them parentless but still methods.
    const type_name = rustImplTypeName(ctx, impl_i + 1, open);
    const parent = if (type_name.len != 0) findEmittedContainer(ctx, type_name) else null;
    try parseRustScope(ctx, open + 1, close, parent, true);
    return close + 1;
}

/// The `{` that opens an `impl ... { }` body, skipping generics, the `for` type,
/// and any `where` clause. Angle/paren groups are stepped over.
fn rustImplBodyOpen(ctx: *const Ctx, from: u32, hi: u32) u32 {
    var j = from;
    while (j < hi) {
        if (ctx.isPunct(j, '{')) return j;
        if (ctx.isPunct(j, '<')) {
            const after = skipRustGenerics(ctx, j, hi);
            j = if (after > j) after else j + 1;
            continue;
        }
        if (ctx.isPunct(j, '(') or ctx.isPunct(j, '[')) {
            j = skipBracket(ctx, j);
            continue;
        }
        j += 1;
    }
    return sentinel;
}

/// The last path segment of the type an `impl` targets: the identifier after
/// `for` in `impl Trait for Type`, else the first path's last segment.
fn rustImplTypeName(ctx: *const Ctx, from: u32, open: u32) []const u8 {
    // Skip the impl's own generic-parameter clause so `impl<'a> Lexer<'a>` binds
    // to `Lexer`, not the lifetime `'a` (the old last-identifier scan grabbed the
    // final ident before `{`, which for a generic-parameterized impl is inside the
    // `<…>` — orphaning every method to the top level).
    var j = skipRustGenerics(ctx, from, open);
    var type_ident: []const u8 = "";
    var for_ident: []const u8 = "";
    var after_for = false;
    while (j < open) : (j += 1) {
        // A type's own generic arguments (`Lexer<'a>`, `Vec<T>`) are not the name.
        if (ctx.isPunct(j, '<')) {
            const nj = skipRustGenerics(ctx, j, open);
            if (nj > j) {
                j = nj - 1; // the loop's `j += 1` re-advances past the `>`
                continue;
            }
        }
        if (ctx.identEql(j, "for")) {
            after_for = true;
            continue;
        }
        if (ctx.toks[j].kind == .identifier and !rust_keywords.has(ctx.textOf(j))) {
            // The impl'd type is the first identifier; `impl Trait for Type` names
            // the type after `for` instead.
            if (after_for) {
                if (for_ident.len == 0) for_ident = ctx.textOf(j);
            } else if (type_ident.len == 0) {
                type_ident = ctx.textOf(j);
            }
        }
    }
    return if (after_for and for_ident.len != 0) for_ident else type_ident;
}

/// Index of an already-emitted struct/enum/interface named `name`, for nesting
/// an `impl`'s methods; null when none was parsed (yet) in this file.
fn findEmittedContainer(ctx: *const Ctx, name: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < ctx.out.items.len) : (i += 1) {
        const s = ctx.out.items[i];
        const is_container = s.kind == .@"struct" or s.kind == .@"enum" or
            s.kind == .interface or s.kind == .class;
        if (is_container and std.mem.eql(u8, s.name, name)) return i;
    }
    return null;
}

fn parseRustMod(ctx: *Ctx, doc_i: u32, mod_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    if (mod_i + 1 >= hi or ctx.toks[mod_i + 1].kind != .identifier) return mod_i;
    const name_i = mod_i + 1;
    const name = ctx.textOf(name_i);
    if (ctx.isPunct(name_i + 1, '{')) {
        const open = name_i + 1;
        const close = ctx.close[open];
        if (close == sentinel) return mod_i;
        const my = try emit(ctx, .{
            .name = name,
            .kind = .module,
            .line = ctx.toks[name_i].line,
            .span_start = lineStartOffset(ctx, doc_i),
            .span_end = ctx.toks[close].end,
            .sig_end = ctx.toks[open].start,
            .doc = collectDoc(ctx, doc_i),
            .exported = true,
            .parent_local = parent,
            .refs = &.{},
        });
        try parseRustScope(ctx, open + 1, close, my, false);
        return close + 1;
    }
    // `mod name;` declares a submodule living in `name.rs` — record as an import.
    if (ctx.isPunct(name_i + 1, ';')) {
        _ = try emit(ctx, importSymbol(name, name, ctx.toks[name_i].line, lineStartOffset(ctx, doc_i), ctx.toks[name_i + 1].end));
        return name_i + 2;
    }
    return mod_i;
}

fn parseRustUse(ctx: *Ctx, use_i: u32, hi: u32) AllocError!u32 {
    const semi = findNext(ctx, use_i + 1, hi, ';');
    if (semi == sentinel) return use_i;
    const path = std.mem.trim(u8, ctx.source[ctx.toks[use_i + 1].start..ctx.toks[semi].start], " \t\r\n");
    const span_start = lineStartOffset(ctx, use_i);
    const line = ctx.toks[use_i].line;
    const brace = findNext(ctx, use_i + 1, semi, '{');
    if (brace != sentinel and ctx.close[brace] != sentinel) {
        const bclose = ctx.close[brace];
        var k = brace + 1;
        while (k < bclose) : (k += 1) {
            if (ctx.toks[k].kind != .identifier or rust_keywords.has(ctx.textOf(k))) continue;
            // A leaf item, not a path segment: not followed by `::`.
            if (ctx.isPunct(k + 1, ':')) continue;
            _ = try emit(ctx, importSymbol(ctx.textOf(k), path, line, span_start, ctx.toks[k].end));
        }
        return semi + 1;
    }
    // Single path: binding is the alias (`as X`) or the final segment.
    const binding_i = rustUseBinding(ctx, use_i + 1, semi);
    if (binding_i != sentinel) {
        _ = try emit(ctx, importSymbol(ctx.textOf(binding_i), path, line, span_start, ctx.toks[semi].start));
    }
    return semi + 1;
}

/// The token that a single `use` path binds: the identifier after `as`, else the
/// last identifier before the terminating `;`. `sentinel` when none.
fn rustUseBinding(ctx: *const Ctx, from: u32, semi: u32) u32 {
    var j = from;
    var last: u32 = sentinel;
    while (j < semi) : (j += 1) {
        if (ctx.identEql(j, "as") and j + 1 < semi and ctx.toks[j + 1].kind == .identifier) return j + 1;
        if (ctx.toks[j].kind == .identifier and !rust_keywords.has(ctx.textOf(j))) last = j;
    }
    return last;
}

fn parseRustConst(ctx: *Ctx, doc_i: u32, kw_i: u32, hi: u32, parent: ?u32, exported: bool) AllocError!u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return kw_i;
    const name_i = kw_i + 1;
    const semi = findNext(ctx, name_i + 1, hi, ';');
    const end = if (semi != sentinel) ctx.toks[semi].end else lineEndOffset(ctx, ctx.toks[name_i].start);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .constant,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, doc_i),
        .span_end = end,
        .sig_end = end,
        .doc = collectDoc(ctx, doc_i),
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    return if (semi != sentinel) semi + 1 else tokenAfterOffset(ctx, end, hi);
}

fn parseRustTypeAlias(ctx: *Ctx, doc_i: u32, kw_i: u32, hi: u32, parent: ?u32, exported: bool) AllocError!u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return kw_i;
    const name_i = kw_i + 1;
    const semi = findNext(ctx, name_i + 1, hi, ';');
    const end = if (semi != sentinel) ctx.toks[semi].end else lineEndOffset(ctx, ctx.toks[name_i].start);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .type,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, doc_i),
        .span_end = end,
        .sig_end = end,
        .doc = collectDoc(ctx, doc_i),
        .exported = exported,
        .parent_local = parent,
        .refs = &.{},
    });
    return if (semi != sentinel) semi + 1 else tokenAfterOffset(ctx, end, hi);
}

fn parseRustMacro(ctx: *Ctx, stmt_start: u32, kw_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    _ = stmt_start;
    if (kw_i + 2 >= hi or ctx.toks[kw_i + 2].kind != .identifier) return kw_i;
    const name_i = kw_i + 2;
    const open = findNext(ctx, name_i + 1, hi, '{');
    if (open == sentinel or ctx.close[open] == sentinel) return kw_i;
    const close = ctx.close[open];
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = .macro,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, kw_i),
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[open].start,
        .doc = collectDoc(ctx, kw_i),
        .exported = true,
        .parent_local = parent,
        .refs = &.{},
    });
    return close + 1;
}

// ---------------------------------------------------------------------------
// Ruby
// ---------------------------------------------------------------------------

const ruby_keywords = KeywordSet.initComptime(.{
    .{"def"},    .{"end"},    .{"if"},    .{"elsif"},   .{"else"},             .{"unless"},
    .{"while"},  .{"until"},  .{"for"},   .{"in"},      .{"do"},               .{"begin"},
    .{"rescue"}, .{"ensure"}, .{"retry"}, .{"return"},  .{"yield"},            .{"then"},
    .{"case"},   .{"when"},   .{"class"}, .{"module"},  .{"self"},             .{"nil"},
    .{"true"},   .{"false"},  .{"and"},   .{"or"},      .{"not"},              .{"super"},
    .{"break"},  .{"next"},   .{"redo"},  .{"require"}, .{"require_relative"},
});

/// Whether the `do` at `i` merely re-marks a block already opened by a
/// same-line, line-leading `while`/`until`/`for` (avoiding a double count).
fn rubyDoIsRedundant(ctx: *const Ctx, i: u32) bool {
    const line = ctx.toks[i].line;
    var j = i;
    while (j > 0 and ctx.toks[j - 1].line == line) j -= 1;
    return ctx.identEql(j, "while") or ctx.identEql(j, "until") or ctx.identEql(j, "for");
}

/// Whether the identifier at `i` opens an `end`-terminated Ruby block.
/// `if`/`unless`/`while`/`until`/`for` open only at line start (mid-line they are
/// statement modifiers with no `end`); `do` opens unless it is redundant.
fn rubyOpensBlock(ctx: *const Ctx, i: u32) bool {
    if (ctx.identEql(i, "def") or ctx.identEql(i, "class") or ctx.identEql(i, "module") or
        ctx.identEql(i, "case") or ctx.identEql(i, "begin")) return true;
    if (ctx.identEql(i, "do")) return !rubyDoIsRedundant(ctx, i);
    if (ctx.identEql(i, "if") or ctx.identEql(i, "unless") or ctx.identEql(i, "while") or
        ctx.identEql(i, "until") or ctx.identEql(i, "for")) return isLineStart(ctx, i);
    return false;
}

/// Index of the `end` closing a block whose opener precedes `from` (depth starts
/// at 1). `hi` when unterminated.
fn rubyBlockEnd(ctx: *const Ctx, from: u32, hi: u32) u32 {
    var depth: u32 = 1;
    var i = from;
    while (i < hi) : (i += 1) {
        if (ctx.toks[i].kind != .identifier) continue;
        if (ctx.identEql(i, "end")) {
            depth -= 1;
            if (depth == 0) return i;
        } else if (rubyOpensBlock(ctx, i)) {
            depth += 1;
        }
    }
    return hi;
}

fn parseRubyScope(ctx: *Ctx, lo: u32, hi: u32, parent: ?u32) AllocError!void {
    var i = lo;
    while (i < hi) {
        if (ctx.toks[i].kind != .identifier or !isLineStart(ctx, i)) {
            i += 1;
            continue;
        }
        const adv = try parseRubyStmt(ctx, i, hi, parent);
        i = if (adv > i) adv else i + 1;
    }
}

fn parseRubyStmt(ctx: *Ctx, i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    if (ctx.identEql(i, "def")) return parseRubyDef(ctx, i, hi, parent);
    if (ctx.identEql(i, "class")) return parseRubyContainer(ctx, i, hi, parent, .class);
    if (ctx.identEql(i, "module")) return parseRubyContainer(ctx, i, hi, parent, .module);
    if (ctx.identEql(i, "require") or ctx.identEql(i, "require_relative"))
        return parseRubyRequire(ctx, i, hi);
    return i;
}

fn parseRubyDef(ctx: *Ctx, def_i: u32, hi: u32, parent: ?u32) AllocError!u32 {
    var j = def_i + 1;
    var is_singleton = false;
    // `def self.name` / `def Recv.name` — a class-level method.
    if (j + 1 < hi and ctx.toks[j].kind == .identifier and ctx.isPunct(j + 1, '.')) {
        is_singleton = true;
        j += 2;
    }
    if (j >= hi or ctx.toks[j].kind != .identifier) return def_i;
    const name_i = j;
    const name = ctx.textOf(name_i);
    var after = name_i + 1;
    if (ctx.isPunct(after, '(')) {
        const pc = ctx.close[after];
        if (pc == sentinel) return def_i;
        after = pc + 1;
    }
    const kind: SymbolKind = if (parent != null or is_singleton) .method else .function;
    // Endless method (Ruby 3): `def foo = expr` — a single-line body.
    if (ctx.isPunct(after, '=') and !ctx.isPunct(after + 1, '=')) {
        const end = lineEndOffset(ctx, ctx.toks[def_i].start);
        const body_hi = tokenAfterOffset(ctx, end, hi);
        const body = try collectRefs(ctx, sentinel, after + 1, body_hi, name, ruby_keywords);
        _ = try emit(ctx, .{
            .name = name,
            .kind = kind,
            .line = ctx.toks[name_i].line,
            .span_start = lineStartOffset(ctx, def_i),
            .span_end = end,
            .sig_end = end,
            .doc = collectDoc(ctx, def_i),
            .exported = true,
            .parent_local = parent,
            .refs = body.refs,
            .bindings = body.bindings,
        });
        return body_hi;
    }
    const end_i = rubyBlockEnd(ctx, after, hi);
    const span_end = if (end_i < hi) ctx.toks[end_i].end else @as(u32, @intCast(ctx.source.len));
    const sig_end = @min(lineEndOffset(ctx, ctx.toks[def_i].start), span_end);
    const body = try collectRefs(ctx, sentinel, after, end_i, name, ruby_keywords);
    _ = try emit(ctx, .{
        .name = name,
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, def_i),
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = collectDoc(ctx, def_i),
        .exported = true,
        .parent_local = parent,
        .refs = body.refs,
        .bindings = body.bindings,
    });
    return if (end_i < hi) end_i + 1 else hi;
}

fn parseRubyContainer(ctx: *Ctx, kw_i: u32, hi: u32, parent: ?u32, kind: SymbolKind) AllocError!u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return kw_i; // e.g. `class << self`
    const name_i = kw_i + 1;
    const end_i = rubyBlockEnd(ctx, name_i + 1, hi);
    const span_end = if (end_i < hi) ctx.toks[end_i].end else @as(u32, @intCast(ctx.source.len));
    const sig_end = @min(lineEndOffset(ctx, ctx.toks[kw_i].start), span_end);
    const my = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, kw_i),
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = collectDoc(ctx, kw_i),
        .exported = true,
        .parent_local = parent,
        .refs = &.{},
    });
    try parseRubyScope(ctx, name_i + 1, end_i, my);
    return if (end_i < hi) end_i + 1 else hi;
}

fn parseRubyRequire(ctx: *Ctx, req_i: u32, hi: u32) AllocError!u32 {
    var j = req_i + 1;
    if (ctx.isPunct(j, '(')) j += 1;
    if (j >= hi or ctx.toks[j].kind != .string) return req_i;
    const path = stripQuotes(ctx.textOf(j));
    if (path.len == 0) return req_i;
    const binding = rubyRequireBase(path);
    const end = lineEndOffset(ctx, ctx.toks[req_i].start);
    _ = try emit(ctx, importSymbol(binding, path, ctx.toks[req_i].line, lineStartOffset(ctx, req_i), end));
    return tokenAfterOffset(ctx, end, hi);
}

/// The bound name of a Ruby require path: its last `/` segment (`lib/user` →
/// `user`), which is the constant/file the require introduces.
fn rubyRequireBase(path: []const u8) []const u8 {
    return lastPathSegment(path);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(src: []const u8, lang: language.Language) !std.ArrayList(ParsedSymbol) {
    var out: std.ArrayList(ParsedSymbol) = .empty;
    // arena leaks into the test allocator's checking; use testing allocator via arena.
    const arena = testing.allocator;
    _ = try parse(testing.allocator, arena, src, lang, &out);
    return out;
}

test "parse-health: an unterminated string that runs to EOF is reported" {
    var out: std.ArrayList(ParsedSymbol) = .empty;
    defer out.deinit(testing.allocator);
    // The opening quote is never closed, so the tokenizer swallows to EOF.
    const src =
        \\function ok() { return 1; }
        \\const bad = "never closed
        \\function hidden() { return 2; }
    ;
    const health = try parse(testing.allocator, testing.allocator, src, .javascript, &out);
    try testing.expect(health.desync_from != null);
    try testing.expectEqual(@as(u32, 2), health.desync_from.?);
    try testing.expect(health.desync_to >= 3);
}

test "parse-health: a well-formed file reports no desync" {
    var out: std.ArrayList(ParsedSymbol) = .empty;
    defer out.deinit(testing.allocator);
    const src =
        \\const re = /("(?:[^"\\]|\\.)*")/g;
        \\function fine() { return "closed string"; }
    ;
    const health = try parse(testing.allocator, testing.allocator, src, .javascript, &out);
    try testing.expect(health.desync_from == null);
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

test "lua: local/global functions, table methods, refs and export flags" {
    const src =
        \\local M = {}
        \\
        \\--- Adds two numbers.
        \\local function addPrivate(a, b)
        \\  return a + b
        \\end
        \\
        \\function M.publicAdd(a, b)
        \\  return addPrivate(a, b)
        \\end
        \\
        \\function M:method(x)
        \\  return self.value + x
        \\end
    ;
    var out = try parseForTest(src, .lua);
    defer freeRefs(&out);
    const priv = findSym(out.items, "addPrivate").?;
    try testing.expectEqual(SymbolKind.function, priv.kind);
    try testing.expect(!priv.exported); // `local` → file-private
    try testing.expect(std.mem.indexOf(u8, priv.doc, "Adds two numbers") != null);
    const pub_add = findSym(out.items, "publicAdd").?;
    try testing.expectEqual(SymbolKind.method, pub_add.kind);
    try testing.expect(pub_add.exported); // table function → public
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "method").?.kind);
    var found = false;
    for (pub_add.refs) |r| {
        if (std.mem.eql(u8, r.name, "addPrivate")) {
            found = true;
            try testing.expectEqual(RefKind.call, r.kind);
        }
    }
    try testing.expect(found);
}

test "lua: require() emits an import; a block comment hides code inside it" {
    const src =
        \\local util = require("lib.util")
        \\--[[ a multiline comment
        \\function ghost() return 1 end
        \\]]
        \\local function real() return util.clamp(1) end
    ;
    var out = try parseForTest(src, .lua);
    defer freeRefs(&out);
    const imp = findSym(out.items, "util").?;
    try testing.expectEqual(SymbolKind.import, imp.kind);
    try testing.expectEqualStrings("lib.util", imp.import_path);
    // Code inside `--[[ ]]` must not surface as a symbol.
    try testing.expect(findSym(out.items, "ghost") == null);
    try testing.expect(findSym(out.items, "real") != null);
}

test "lua: function fields of a table constructor become methods" {
    const src =
        \\local T = {
        \\  run = function(self, n)
        \\    return n + 1
        \\  end,
        \\  dead = function()
        \\    return 42
        \\  end,
        \\}
    ;
    var out = try parseForTest(src, .lua);
    defer freeRefs(&out);
    const t = findSym(out.items, "T").?;
    try testing.expectEqual(SymbolKind.variable, t.kind);
    const run = findSym(out.items, "run").?;
    try testing.expectEqual(SymbolKind.method, run.kind);
    try testing.expect(run.parent_local != null);
    try testing.expect(findSym(out.items, "dead") != null);
}

test "go: funcs, methods, structs, interfaces, imports, and refs" {
    const src =
        \\package main
        \\
        \\import (
        \\    "fmt"
        \\    ndb "database/sql"
        \\)
        \\
        \\// Add returns the sum.
        \\func Add(a, b int) int {
        \\    return a + b
        \\}
        \\
        \\type Server struct {
        \\    port int
        \\}
        \\
        \\type Handler interface {
        \\    Serve(w int) error
        \\}
        \\
        \\func (s *Server) Start() int {
        \\    return Add(s.port, 1)
        \\}
        \\
        \\func makeIface() interface{} { return nil }
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);

    const add = findSym(out.items, "Add").?;
    try testing.expectEqual(SymbolKind.function, add.kind);
    try testing.expect(add.exported); // upper-case first letter
    try testing.expect(std.mem.indexOf(u8, add.doc, "returns the sum") != null);

    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Server").?.kind);
    try testing.expectEqual(SymbolKind.interface, findSym(out.items, "Handler").?.kind);
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "Serve").?.kind);

    const start = findSym(out.items, "Start").?;
    try testing.expectEqual(SymbolKind.method, start.kind);
    var saw_add = false;
    for (start.refs) |r| {
        if (std.mem.eql(u8, r.name, "Add")) saw_add = true;
    }
    try testing.expect(saw_add);

    // `interface{}` in the return type must not be mistaken for the body.
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "makeIface").?.kind);

    // Aliased and plain imports both bind.
    const fmt_imp = findSym(out.items, "fmt").?;
    try testing.expectEqual(SymbolKind.import, fmt_imp.kind);
    try testing.expectEqualStrings("database/sql", findSym(out.items, "ndb").?.import_path);
}

test "rust: fn, struct, trait, impl methods, use, and lifetimes" {
    const src =
        \\use crate::util::{parse, Helper};
        \\
        \\/// A widget.
        \\pub struct Widget {
        \\    name: String,
        \\}
        \\
        \\pub trait Draw {
        \\    fn draw(&self) -> u32;
        \\}
        \\
        \\impl Widget {
        \\    pub fn render(&self, s: &'a str) -> u32 {
        \\        return parse(s);
        \\    }
        \\}
        \\
        \\fn helper<T: Clone>(x: T) -> T { x }
    ;
    var out = try parseForTest(src, .rust);
    defer freeRefs(&out);

    const widget = findSym(out.items, "Widget").?;
    try testing.expectEqual(SymbolKind.@"struct", widget.kind);
    try testing.expect(widget.exported);
    try testing.expect(std.mem.indexOf(u8, widget.doc, "A widget") != null);

    try testing.expectEqual(SymbolKind.interface, findSym(out.items, "Draw").?.kind);
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "draw").?.kind);

    const render = findSym(out.items, "render").?;
    try testing.expectEqual(SymbolKind.method, render.kind);
    // The lifetime `&'a str` must not swallow the rest of the signature/body.
    var saw_parse = false;
    for (render.refs) |r| {
        if (std.mem.eql(u8, r.name, "parse")) {
            saw_parse = true;
            try testing.expectEqual(RefKind.call, r.kind);
        }
    }
    try testing.expect(saw_parse);

    // Generic free function is a function, not a method.
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "helper").?.kind);

    // `use` leaves bind as imports.
    try testing.expectEqual(SymbolKind.import, findSym(out.items, "parse").?.kind);
    try testing.expect(findSym(out.items, "Helper") != null);
}

test "ruby: class, methods, self-method, require_relative, and refs" {
    const src =
        \\require_relative "lib/util"
        \\
        \\class Server
        \\  def start
        \\    data = fetch
        \\    data.each do |row|
        \\      process(row)
        \\    end
        \\  end
        \\
        \\  def self.build
        \\    new
        \\  end
        \\end
        \\
        \\def top_level
        \\  1
        \\end
    ;
    var out = try parseForTest(src, .ruby);
    defer freeRefs(&out);

    const server = findSym(out.items, "Server").?;
    try testing.expectEqual(SymbolKind.class, server.kind);

    const start = findSym(out.items, "start").?;
    try testing.expectEqual(SymbolKind.method, start.kind);
    try testing.expect(start.parent_local != null);
    // The `do ... end` block inside must not truncate the method early: `process`
    // is a ref of `start`.
    var saw_process = false;
    for (start.refs) |r| {
        if (std.mem.eql(u8, r.name, "process")) saw_process = true;
    }
    try testing.expect(saw_process);

    // A singleton `def self.build` is a method.
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "build").?.kind);

    // A top-level def is a function, not a method.
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "top_level").?.kind);

    // require_relative binds an import.
    const imp = findSym(out.items, "util").?;
    try testing.expectEqual(SymbolKind.import, imp.kind);
    try testing.expectEqualStrings("lib/util", imp.import_path);
}

fn countKind(list: []const ParsedSymbol, kind: SymbolKind) usize {
    var n: usize = 0;
    for (list) |s| {
        if (s.kind == kind) n += 1;
    }
    return n;
}

fn hasRef(sym: ParsedSymbol, name: []const u8) bool {
    for (sym.refs) |r| if (std.mem.eql(u8, r.name, name)) return true;
    return false;
}

fn hasCallRef(sym: ParsedSymbol, name: []const u8) bool {
    for (sym.refs) |r| if (r.kind == .call and std.mem.eql(u8, r.name, name)) return true;
    return false;
}

test "go: grouped imports with alias, blank, and dot forms all bind" {
    const src =
        \\package main
        \\import (
        \\    "fmt"
        \\    ndb "database/sql"
        \\    _ "github.com/lib/pq"
        \\    . "math"
        \\)
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    // Plain import binds under its last path segment.
    try testing.expectEqualStrings("fmt", findSym(out.items, "fmt").?.import_path);
    // Aliased import binds under the alias.
    try testing.expectEqualStrings("database/sql", findSym(out.items, "ndb").?.import_path);
    // Blank (`_`) and dot (`.`) imports still record their paths.
    try testing.expectEqualStrings("github.com/lib/pq", findSym(out.items, "_").?.import_path);
    try testing.expectEqual(@as(usize, 4), countKind(out.items, .import));
}

test "go: unexported names are private; backtick raw strings do not swallow code" {
    const src =
        \\package main
        \\// helper is package-private.
        \\func helper() string {
        \\    return `a raw ) string } with braces`
        \\}
        \\func Exported() string { return helper() }
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    const helper = findSym(out.items, "helper").?;
    try testing.expectEqual(SymbolKind.function, helper.kind);
    try testing.expect(!helper.exported); // lower-case first letter
    // The raw string's `)`/`}` must not corrupt spans; Exported still parses and
    // calls helper.
    const exp = findSym(out.items, "Exported").?;
    try testing.expect(exp.exported);
    try testing.expect(hasCallRef(exp, "helper"));
}

test "go: generic function, defined type, and value + pointer receivers" {
    const src =
        \\package main
        \\type ID int
        \\func Map[T any, U any](s []T, f func(T) U) []U { return nil }
        \\type Box struct { v int }
        \\func (b Box) Get() int { return b.v }
        \\func (b *Box) Set(x int) { b.v = x }
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.type, findSym(out.items, "ID").?.kind);
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "Map").?.kind);
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Box").?.kind);
    // Both a value receiver and a pointer receiver yield methods.
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "Get").?.kind);
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "Set").?.kind);
    try testing.expectEqual(@as(usize, 2), countKind(out.items, .method));
}

test "rust: enum, const, static, type alias, and macro_rules with visibility" {
    const src =
        \\pub enum Color { Red, Green }
        \\const MAX: u32 = 10;
        \\pub static NAME: &str = "x";
        \\pub type Bytes = Vec<u8>;
        \\macro_rules! twice { ($x:expr) => { $x * 2 }; }
    ;
    var out = try parseForTest(src, .rust);
    defer freeRefs(&out);
    const color = findSym(out.items, "Color").?;
    try testing.expectEqual(SymbolKind.@"enum", color.kind);
    try testing.expect(color.exported);
    try testing.expectEqual(SymbolKind.constant, findSym(out.items, "MAX").?.kind);
    try testing.expect(!findSym(out.items, "MAX").?.exported);
    try testing.expect(findSym(out.items, "NAME").?.exported);
    try testing.expectEqual(SymbolKind.type, findSym(out.items, "Bytes").?.kind);
    try testing.expectEqual(SymbolKind.macro, findSym(out.items, "twice").?.kind);
}

test "rust: multiple impl blocks and a trait impl all contribute methods to the type" {
    const src =
        \\pub struct Widget;
        \\pub trait Draw { fn draw(&self); }
        \\impl Widget {
        \\    pub fn new() -> Widget { Widget }
        \\    fn helper(&self) -> u32 { 1 }
        \\}
        \\impl Draw for Widget {
        \\    fn draw(&self) { self.helper(); }
        \\}
    ;
    var out = try parseForTest(src, .rust);
    defer freeRefs(&out);
    const widget = findSym(out.items, "Widget").?;
    try testing.expectEqual(SymbolKind.@"struct", widget.kind);
    // new, helper (from impl Widget) and draw (from impl Draw for Widget) are all
    // methods nested under Widget's symbol; the trait's own draw signature also
    // exists.
    const new = findSym(out.items, "new").?;
    try testing.expectEqual(SymbolKind.method, new.kind);
    try testing.expect(new.parent_local != null);
    try testing.expect(findSym(out.items, "helper").?.parent_local != null);
    try testing.expect(countKind(out.items, .method) >= 3);
}

test "rust: where-clause and Fn() bounds do not break the fn body" {
    const src =
        \\pub fn run<T>(items: Vec<T>, cb: impl Fn(T) -> u32) -> u32
        \\where
        \\    T: Clone,
        \\{
        \\    return finalize(items);
        \\}
    ;
    var out = try parseForTest(src, .rust);
    defer freeRefs(&out);
    const run = findSym(out.items, "run").?;
    try testing.expectEqual(SymbolKind.function, run.kind);
    try testing.expect(run.exported);
    // The generic/where header must be skipped so the body ref is captured.
    try testing.expect(hasCallRef(run, "finalize"));
}

test "ruby: module nesting, self methods, and require forms" {
    const src =
        \\require "json"
        \\require_relative "lib/util"
        \\module Api
        \\  class Client
        \\    def fetch
        \\      parse(get)
        \\    end
        \\    def self.build
        \\      new
        \\    end
        \\  end
        \\end
    ;
    var out = try parseForTest(src, .ruby);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.module, findSym(out.items, "Api").?.kind);
    try testing.expectEqual(SymbolKind.class, findSym(out.items, "Client").?.kind);
    const fetch = findSym(out.items, "fetch").?;
    try testing.expectEqual(SymbolKind.method, fetch.kind);
    try testing.expect(fetch.parent_local != null);
    try testing.expect(hasCallRef(fetch, "parse"));
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "build").?.kind);
    // A plain `require` and a `require_relative` both bind imports.
    try testing.expectEqualStrings("json", findSym(out.items, "json").?.import_path);
    try testing.expectEqualStrings("lib/util", findSym(out.items, "util").?.import_path);
}

test "ruby: if/unless modifiers and do/end blocks do not truncate a method" {
    const src =
        \\def guard
        \\  return early if done
        \\  items.each do |i|
        \\    transform(i)
        \\  end
        \\  finish
        \\end
        \\
        \\def after
        \\  1
        \\end
    ;
    var out = try parseForTest(src, .ruby);
    defer freeRefs(&out);
    const guard = findSym(out.items, "guard").?;
    try testing.expectEqual(SymbolKind.function, guard.kind);
    // The `if` modifier opened no block and the `do…end` was balanced, so the
    // whole body belongs to `guard`: the post-block `finish` and the in-block
    // `transform` are both its refs.
    try testing.expect(hasCallRef(guard, "transform"));
    try testing.expect(hasRef(guard, "finish"));
    // The following def is a separate, intact symbol (the block matching did not
    // consume its `end`).
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "after").?.kind);
}

test "ruby: endless methods and bang/question method names" {
    const src =
        \\class Record
        \\  def valid?
        \\    check
        \\  end
        \\  def save!
        \\    persist
        \\  end
        \\  def double(x) = x * 2
        \\end
    ;
    var out = try parseForTest(src, .ruby);
    defer freeRefs(&out);
    // `?`/`!` lex as punct, so the method name is the identifier stem.
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "valid").?.kind);
    try testing.expect(hasRef(findSym(out.items, "valid").?, "check"));
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "save").?.kind);
    // An endless method is a single-line method.
    const double = findSym(out.items, "double").?;
    try testing.expectEqual(SymbolKind.method, double.kind);
    try testing.expect(double.parent_local != null);
}

test "zig: enum and tagged union are indexed; a test block is a test_case symbol with body refs" {
    const src =
        \\pub const Dir = enum { north, south };
        \\pub const Payload = union(enum) { a: u8, b: u16 };
        \\test "adds" {
        \\    try std.testing.expect(add(1) == 1);
        \\}
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.@"enum", findSym(out.items, "Dir").?.kind);
    // A `union(enum)` is modeled as a struct-like container.
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Payload").?.kind);
    // The `test "adds"` block is now a first-class `.test_case` symbol named by
    // its test string, and its body call `add(1)` is recorded as a reference, so
    // `callers add` can show the test. `add` itself is still not a definition.
    const t = findSym(out.items, "adds").?;
    try testing.expectEqual(SymbolKind.test_case, t.kind);
    try testing.expect(hasCallRef(t, "add"));
    try testing.expect(findSym(out.items, "add") == null);
}

test "python: subclass async method captures nested fn and call refs" {
    const src =
        \\class Base:
        \\    pass
        \\class Derived(Base):
        \\    async def load(self):
        \\        def inner():
        \\            return fetch()
        \\        return inner()
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    const derived = findSym(out.items, "Derived").?;
    try testing.expectEqual(SymbolKind.class, derived.kind);
    const load = findSym(out.items, "load").?;
    try testing.expectEqual(SymbolKind.method, load.kind);
    try testing.expect(load.parent_local != null);
    // The async method sees both its nested-fn call and the inner fetch.
    try testing.expect(hasCallRef(load, "inner"));
    try testing.expect(hasCallRef(load, "fetch"));
    // The nested function is itself indexed and calls fetch.
    const inner = findSym(out.items, "inner").?;
    try testing.expectEqual(SymbolKind.function, inner.kind);
    try testing.expect(hasCallRef(inner, "fetch"));
}

test "ts: an exported arrow-const is a function that captures its call" {
    const src =
        \\export const build = (n: number): number => compute(n);
    ;
    var out = try parseForTest(src, .typescript);
    defer freeRefs(&out);
    const build = findSym(out.items, "build").?;
    try testing.expectEqual(SymbolKind.function, build.kind);
    try testing.expect(build.exported);
    try testing.expect(hasCallRef(build, "compute"));
}

test "cpp: template function and out-of-line Class::method are both indexed" {
    const src =
        \\template <typename T>
        \\T maxOf(T a, T b) { return a > b ? a : b; }
        \\int Widget::render() { return helper(); }
    ;
    var out = try parseForTest(src, .cpp);
    defer freeRefs(&out);
    // The `template<...>` header must be skipped, not confuse the parser.
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "maxOf").?.kind);
    // An out-of-line member definition is indexed and its body call captured.
    const render = findSym(out.items, "render").?;
    try testing.expect(hasCallRef(render, "helper"));
}

fn bindingType(bindings: []const Binding, name: []const u8) ?[]const u8 {
    for (bindings) |b| if (std.mem.eql(u8, b.name, name)) return b.type_name;
    return null;
}

fn freeRefs(out: *std.ArrayList(ParsedSymbol)) void {
    for (out.items) |s| {
        for (s.refs) |ref| {
            if (ref.lines.len != 0) testing.allocator.free(ref.lines);
            if (ref.offsets.len != 0) testing.allocator.free(ref.offsets);
        }
        if (s.refs.len != 0) testing.allocator.free(s.refs);
        if (s.bindings.len != 0) testing.allocator.free(s.bindings);
    }
    out.deinit(testing.allocator);
}

// ===========================================================================
// APPENDED TESTS — parser.zig hardening
// ===========================================================================

// --- Universal edge cases -------------------------------------------------

test "edge: empty source yields no symbols across languages" {
    inline for (.{
        language.Language.zig,        language.Language.c,
        language.Language.cpp,        language.Language.csharp,
        language.Language.python,     language.Language.javascript,
        language.Language.typescript, language.Language.tsx,
        language.Language.lua,        language.Language.go,
        language.Language.rust,       language.Language.ruby,
    }) |lang| {
        var out = try parseForTest("", lang);
        defer freeRefs(&out);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "edge: a comment-only file produces no symbols" {
    var z = try parseForTest("// just a comment\n// another\n", .zig);
    defer freeRefs(&z);
    try testing.expectEqual(@as(usize, 0), z.items.len);

    var p = try parseForTest("# a python comment\n# more\n", .python);
    defer freeRefs(&p);
    try testing.expectEqual(@as(usize, 0), p.items.len);
}

test "edge: keywords inside a string literal do not create symbols" {
    const src =
        \\const s = "pub fn ghost() void {}";
        \\pub fn real() void { return 1; }
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    // The string body must not be scanned as code.
    try testing.expect(findSym(out.items, "ghost") == null);
    // The binding it belongs to is a plain constant, and real() is a function.
    try testing.expectEqual(SymbolKind.constant, findSym(out.items, "s").?.kind);
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "real").?.kind);
}

test "edge: unterminated function body does not crash and still emits the symbol" {
    // No matching `}` for the body — the parser falls back to the declaration path.
    const src = "pub fn broken() void {";
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    const broken = findSym(out.items, "broken").?;
    try testing.expectEqual(SymbolKind.function, broken.kind);
}

test "edge: unterminated parameter list does not crash and emits nothing" {
    const src = "pub fn broken(a: i32";
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    // With no matching `)` the declaration is abandoned (no phantom symbol).
    try testing.expect(findSym(out.items, "broken") == null);
}

test "edge: truncated python/js/rust input parses without crashing" {
    inline for (.{
        .{ "def foo(", language.Language.python },
        .{ "function bar(", language.Language.javascript },
        .{ "pub fn baz(", language.Language.rust },
        .{ "class C {", language.Language.javascript },
    }) |case| {
        var out = try parseForTest(case[0], case[1]);
        freeRefs(&out); // just proving it neither crashes nor leaks.
    }
}

// --- Zig ------------------------------------------------------------------

test "zig: @import const binds a module import edge" {
    const src =
        \\const std = @import("std");
        \\const other = @import("./other.zig");
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    const std_imp = findSym(out.items, "std").?;
    try testing.expectEqual(SymbolKind.import, std_imp.kind);
    try testing.expectEqualStrings("std", std_imp.import_path);
    try testing.expectEqualStrings("./other.zig", findSym(out.items, "other").?.import_path);
}

test "zig: top-level var is a variable, non-fn const is a constant" {
    const src =
        \\var counter: u32 = 0;
        \\const MAX: u32 = 100;
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.variable, findSym(out.items, "counter").?.kind);
    try testing.expectEqual(SymbolKind.constant, findSym(out.items, "MAX").?.kind);
    // Neither is `pub`, so both are file-private.
    try testing.expect(!findSym(out.items, "counter").?.exported);
    try testing.expect(!findSym(out.items, "MAX").?.exported);
}

test "zig: opaque and packed/extern struct containers are struct-kinded" {
    const src =
        \\pub const Handle = opaque {};
        \\const Flags = packed struct { a: bool, b: bool };
        \\const Raw = extern struct { x: i32 };
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Handle").?.kind);
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Flags").?.kind);
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Raw").?.kind);
}

test "zig: pub controls the exported flag on functions" {
    const src =
        \\pub fn visible() void {}
        \\fn hidden() void {}
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "visible").?.exported);
    try testing.expect(!findSym(out.items, "hidden").?.exported);
}

test "zig: nested struct declaration yields a parented method" {
    const src =
        \\pub const Outer = struct {
        \\    const Inner = struct {
        \\        pub fn run(self: *Inner) void { return; }
        \\    };
        \\};
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    const outer = findSym(out.items, "Outer").?;
    try testing.expectEqual(SymbolKind.@"struct", outer.kind);
    const inner = findSym(out.items, "Inner").?;
    try testing.expectEqual(SymbolKind.@"struct", inner.kind);
    try testing.expect(inner.parent_local != null);
    // `run` is nested inside Inner → a method with a parent.
    const run = findSym(out.items, "run").?;
    try testing.expectEqual(SymbolKind.method, run.kind);
    try testing.expect(run.parent_local != null);
}

test "zig: a non-doc line comment is not attached as documentation" {
    const src =
        \\// not a doc comment
        \\pub fn f() void {}
        \\/// real doc
        \\pub fn g() void {}
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    try testing.expectEqual(@as(usize, 0), findSym(out.items, "f").?.doc.len);
    try testing.expect(std.mem.indexOf(u8, findSym(out.items, "g").?.doc, "real doc") != null);
}

test "zig: extern fn declaration without a body is still a function" {
    const src =
        \\pub extern fn c_api(a: i32) i32;
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    const f = findSym(out.items, "c_api").?;
    try testing.expectEqual(SymbolKind.function, f.kind);
    try testing.expect(f.exported); // leading `pub`
}

test "zig: multi-line function signature captures the body call" {
    const src =
        \\pub fn wide(
        \\    a: i32,
        \\    b: i32,
        \\) i32 {
        \\    return add(a, b);
        \\}
    ;
    var out = try parseForTest(src, .zig);
    defer freeRefs(&out);
    const wide = findSym(out.items, "wide").?;
    try testing.expectEqual(SymbolKind.function, wide.kind);
    try testing.expect(hasCallRef(wide, "add"));
    // Signature stops at the body brace: `add` is not part of the collapsed sig.
    try testing.expect(std.mem.indexOf(u8, src[wide.span_start..wide.sig_end], "add") == null);
}

// --- C --------------------------------------------------------------------

test "c: named struct and enum records are indexed with the right kind" {
    const src =
        \\struct Point { int x; int y; };
        \\enum Color { RED, GREEN, BLUE };
        \\int area(struct Point* p) { return p->compute(); }
    ;
    var out = try parseForTest(src, .c);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Point").?.kind);
    try testing.expectEqual(SymbolKind.@"enum", findSym(out.items, "Color").?.kind);
    // The `->` member call records the receiver as the qualifier.
    const area = findSym(out.items, "area").?;
    var q: []const u8 = "";
    for (area.refs) |r| {
        if (std.mem.eql(u8, r.name, "compute")) q = r.qualifier;
    }
    try testing.expectEqualStrings("p", q);
}

test "c: function-like macro with parameters is a macro symbol" {
    const src =
        \\#define SQUARE(x) ((x) * (x))
        \\#define PI 3.14
    ;
    var out = try parseForTest(src, .c);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.macro, findSym(out.items, "SQUARE").?.kind);
    try testing.expectEqual(SymbolKind.macro, findSym(out.items, "PI").?.kind);
    // A macro from a #define has external visibility.
    try testing.expect(findSym(out.items, "SQUARE").?.exported);
}

test "c: a block comment hides the code inside it" {
    const src =
        \\/* int ghost(void) { return 0; } */
        \\int real(void) { return 1; }
    ;
    var out = try parseForTest(src, .c);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "ghost") == null);
    try testing.expectEqual(SymbolKind.function, findSym(out.items, "real").?.kind);
}

// --- C++ ------------------------------------------------------------------

test "cpp: struct body methods are indexed and nested under the struct" {
    const src =
        \\struct Vec {
        \\    double len() const { return 0.0; }
        \\    void scale(double f) { this->normalize(); }
        \\    void normalize();
        \\};
    ;
    var out = try parseForTest(src, .cpp);
    defer freeRefs(&out);
    const vec = findSym(out.items, "Vec").?;
    try testing.expectEqual(SymbolKind.@"struct", vec.kind);
    const len = findSym(out.items, "len").?;
    try testing.expectEqual(SymbolKind.method, len.kind);
    try testing.expect(len.parent_local != null);
    // A declaration-only member is still a method.
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "normalize").?.kind);
    // `this->normalize()` records `this` as the qualifier.
    const scale = findSym(out.items, "scale").?;
    var q: []const u8 = "";
    for (scale.refs) |r| {
        if (std.mem.eql(u8, r.name, "normalize")) q = r.qualifier;
    }
    try testing.expectEqualStrings("this", q);
}

test "cpp: nested namespaces surface as modules and inner functions are found" {
    const src =
        \\namespace outer {
        \\namespace inner {
        \\int deep() { return 1; }
        \\}
        \\int shallow() { return inner::deep(); }
        \\}
    ;
    var out = try parseForTest(src, .cpp);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.module, findSym(out.items, "outer").?.kind);
    try testing.expectEqual(SymbolKind.module, findSym(out.items, "inner").?.kind);
    try testing.expect(findSym(out.items, "deep") != null);
    // `inner::deep()` records `inner` as the scope qualifier.
    const shallow = findSym(out.items, "shallow").?;
    var q: []const u8 = "";
    for (shallow.refs) |r| {
        if (std.mem.eql(u8, r.name, "deep")) q = r.qualifier;
    }
    try testing.expectEqualStrings("inner", q);
}

// --- C# -------------------------------------------------------------------

test "c#: struct with methods and a generic class are indexed" {
    const src =
        \\namespace App;
        \\public struct Point
        \\{
        \\    public int Sum() { return 0; }
        \\}
        \\public class Box<T>
        \\{
        \\    public T Get() { return this.Load(); }
        \\    private T Load() { return default; }
        \\}
    ;
    var out = try parseForTest(src, .csharp);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Point").?.kind);
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "Sum").?.kind);
    try testing.expectEqual(SymbolKind.class, findSym(out.items, "Box").?.kind);
    // Generic method inside a generic class still resolves and records `this`.
    const get = findSym(out.items, "Get").?;
    try testing.expectEqual(SymbolKind.method, get.kind);
    try testing.expect(hasCallRef(get, "Load"));
}

test "c#: a bracketed namespace nests its class" {
    const src =
        \\namespace Shop
        \\{
        \\    public class Cart
        \\    {
        \\        public void Add() {}
        \\    }
        \\}
    ;
    var out = try parseForTest(src, .csharp);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.module, findSym(out.items, "Shop").?.kind);
    const cart = findSym(out.items, "Cart").?;
    try testing.expectEqual(SymbolKind.class, cart.kind);
    // A bracketed C# namespace is a transparent scope: its members are NOT
    // re-parented under the namespace symbol (the class stays top-level).
    try testing.expect(cart.parent_local == null);
    // The method, however, IS parented under its enclosing class.
    try testing.expect(findSym(out.items, "Add").?.parent_local != null);
}

// --- Python ---------------------------------------------------------------

test "python: plain and aliased imports bind their names" {
    const src =
        \\import os
        \\import numpy as np
        \\import a.b.c
        \\import a.b.c as abc
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    // `import os` binds `os` → module os.
    try testing.expectEqualStrings("os", findSym(out.items, "os").?.import_path);
    // `import numpy as np` binds the alias.
    const np = findSym(out.items, "np").?;
    try testing.expectEqual(SymbolKind.import, np.kind);
    try testing.expectEqualStrings("numpy", np.import_path);
    // `import a.b.c as abc` binds the alias to the dotted path.
    try testing.expectEqualStrings("a.b.c", findSym(out.items, "abc").?.import_path);
}

test "python: from-import with parenthesized names records the module edge" {
    const src =
        \\from pkg.sub import (
        \\    one,
        \\    two,
        \\)
        \\def use():
        \\    return one() + two()
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    var saw_mod = false;
    for (out.items) |s| {
        if (s.kind == .import and std.mem.eql(u8, s.import_path, "pkg.sub")) saw_mod = true;
    }
    try testing.expect(saw_mod);
    // The named targets are bare-callable references of use().
    const use = findSym(out.items, "use").?;
    try testing.expect(hasCallRef(use, "one"));
    try testing.expect(hasCallRef(use, "two"));
}

test "python: nested class inside a class is parented" {
    const src =
        \\class Outer:
        \\    class Inner:
        \\        def ping(self):
        \\            return 1
        \\    def outer_method(self):
        \\        return 2
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    const outer = findSym(out.items, "Outer").?;
    try testing.expectEqual(SymbolKind.class, outer.kind);
    const inner = findSym(out.items, "Inner").?;
    try testing.expectEqual(SymbolKind.class, inner.kind);
    try testing.expect(inner.parent_local != null);
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "ping").?.kind);
    try testing.expectEqual(SymbolKind.method, findSym(out.items, "outer_method").?.kind);
}

test "python: a '#' comment and a triple-quoted string do not spawn symbols" {
    const src =
        \\# def ghost_comment(): pass
        \\x = """
        \\def ghost_string(): pass
        \\"""
        \\def real():
        \\    return 1
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "ghost_comment") == null);
    try testing.expect(findSym(out.items, "ghost_string") == null);
    try testing.expect(findSym(out.items, "real") != null);
}

// --- JavaScript / TypeScript ----------------------------------------------

test "js: es-module import bindings — default, namespace, and named" {
    const src =
        \\import React from 'react';
        \\import * as utils from './utils';
        \\import { render } from './dom';
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    // Default import binds the name.
    try testing.expectEqualStrings("react", findSym(out.items, "React").?.import_path);
    // Namespace import binds the alias.
    try testing.expectEqualStrings("./utils", findSym(out.items, "utils").?.import_path);
    // Named import has an empty binding but still records the module edge.
    var saw_dom = false;
    for (out.items) |s| {
        if (s.kind == .import and std.mem.eql(u8, s.import_path, "./dom")) saw_dom = true;
    }
    try testing.expect(saw_dom);
}

test "js: export default function is exported" {
    const src =
        \\export default function boot() { return start(); }
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    const boot = findSym(out.items, "boot").?;
    try testing.expectEqual(SymbolKind.function, boot.kind);
    try testing.expect(boot.exported);
    try testing.expect(hasCallRef(boot, "start"));
}

test "js: async arrow const is a function carrying the async modifier" {
    const src =
        \\export const load = async () => { return fetchData(); };
        \\const sync = () => 1;
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    const load = findSym(out.items, "load").?;
    try testing.expectEqual(SymbolKind.function, load.kind);
    try testing.expect(load.modifiers.is_async);
    try testing.expect(hasCallRef(load, "fetchData"));
    // A non-async arrow carries no dispatch modifier.
    try testing.expect(!findSym(out.items, "sync").?.modifiers.is_async);
}

test "js: a plain const initializer is a variable with no refs" {
    const src =
        \\const config = { timeout: 30 };
        \\let count = 0;
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.variable, findSym(out.items, "config").?.kind);
    try testing.expectEqual(SymbolKind.variable, findSym(out.items, "count").?.kind);
}

test "js: line and block comments hide code from the parser" {
    const src =
        \\// function ghostLine() {}
        \\/* function ghostBlock() {} */
        \\function real() { return 1; }
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "ghostLine") == null);
    try testing.expect(findSym(out.items, "ghostBlock") == null);
    try testing.expect(findSym(out.items, "real") != null);
}

test "ts: a type-only brace import does not bind the literal name 'type'" {
    const src =
        \\import type { User } from './models';
    ;
    var out = try parseForTest(src, .typescript);
    defer freeRefs(&out);
    // The `type` keyword must not become an import binding.
    for (out.items) |s| {
        try testing.expect(!std.mem.eql(u8, s.name, "type"));
    }
    // The named type-only import still records the module edge.
    var saw = false;
    for (out.items) |s| {
        if (s.kind == .import and std.mem.eql(u8, s.import_path, "./models")) saw = true;
    }
    try testing.expect(saw);
}

test "ts: a union type alias is a type symbol" {
    const src =
        \\export type Shape = Circle | Square | Triangle;
    ;
    var out = try parseForTest(src, .typescript);
    defer freeRefs(&out);
    const shape = findSym(out.items, "Shape").?;
    try testing.expectEqual(SymbolKind.type, shape.kind);
    try testing.expect(shape.exported);
}

// --- Lua ------------------------------------------------------------------

test "lua: a colon method is a method and captures its call sites" {
    const src =
        \\local M = {}
        \\function M:run(n)
        \\  return self:helper(n)
        \\end
    ;
    var out = try parseForTest(src, .lua);
    defer freeRefs(&out);
    const run = findSym(out.items, "run").?;
    try testing.expectEqual(SymbolKind.method, run.kind);
    // The `self:helper(n)` call site is captured (colon receivers are not yet
    // recorded as qualifiers, but the call edge is present).
    try testing.expect(hasCallRef(run, "helper"));
}

test "lua: a local variable is private, a global is exported" {
    const src =
        \\local secret = 42
        \\config = 7
    ;
    var out = try parseForTest(src, .lua);
    defer freeRefs(&out);
    const secret = findSym(out.items, "secret").?;
    try testing.expectEqual(SymbolKind.variable, secret.kind);
    try testing.expect(!secret.exported); // `local`
    const config = findSym(out.items, "config").?;
    try testing.expectEqual(SymbolKind.variable, config.kind);
    try testing.expect(config.exported); // global
}

test "lua: a function-expression assigned to a local is a private function" {
    const src =
        \\local handler = function(evt)
        \\  return dispatch(evt)
        \\end
    ;
    var out = try parseForTest(src, .lua);
    defer freeRefs(&out);
    const handler = findSym(out.items, "handler").?;
    try testing.expectEqual(SymbolKind.function, handler.kind);
    try testing.expect(!handler.exported);
    try testing.expect(hasCallRef(handler, "dispatch"));
}

// --- Go -------------------------------------------------------------------

test "go: single-line import records the module edge; type alias and defined type" {
    const src =
        \\package main
        \\import "fmt"
        \\type Celsius = float64
        \\type MyInt int
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    // A single-line `import "fmt"` records the module path (the binding name is a
    // separate concern handled by resolution).
    var saw_fmt = false;
    for (out.items) |s| {
        if (s.kind == .import and std.mem.eql(u8, s.import_path, "fmt")) saw_fmt = true;
    }
    try testing.expect(saw_fmt);
    // Both an alias (`= float64`) and a defined type surface as `type`.
    try testing.expectEqual(SymbolKind.type, findSym(out.items, "Celsius").?.kind);
    try testing.expectEqual(SymbolKind.type, findSym(out.items, "MyInt").?.kind);
}

test "go: package-level const/var declarations are emitted as symbols (single + grouped)" {
    const src =
        \\package main
        \\const MaxSize = 1024
        \\var registry = 0
        \\const (
        \\    A = 1
        \\    B = 2
        \\)
        \\func use() int { return MaxSize }
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.constant, findSym(out.items, "MaxSize").?.kind);
    try testing.expectEqual(SymbolKind.variable, findSym(out.items, "registry").?.kind);
    // Grouped `const ( A = 1\n B = 2 )` members are each emitted.
    try testing.expect(findSym(out.items, "A") != null);
    try testing.expect(findSym(out.items, "B") != null);
    // Functions are still found normally; Go capitalization drives exportedness.
    try testing.expect(findSym(out.items, "use") != null);
    try testing.expect(findSym(out.items, "MaxSize").?.exported); // capital M
    try testing.expect(!findSym(out.items, "registry").?.exported); // lowercase r
}

test "go: a method's pointer receiver is bound so member calls carry a receiver" {
    const src =
        \\package main
        \\type Server struct{ n int }
        \\func (s *Server) Start() { s.boot() }
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    const start = findSym(out.items, "Start").?;
    try testing.expectEqual(SymbolKind.method, start.kind);
    var q: []const u8 = "";
    for (start.refs) |r| {
        if (std.mem.eql(u8, r.name, "boot")) q = r.qualifier;
    }
    try testing.expectEqualStrings("s", q);
}

// --- Rust -----------------------------------------------------------------

test "rust: inline module nests items; a bare mod declaration is an import" {
    const src =
        \\mod util {
        \\    pub fn helper() -> u32 { 1 }
        \\}
        \\mod external;
    ;
    var out = try parseForTest(src, .rust);
    defer freeRefs(&out);
    const util = findSym(out.items, "util").?;
    try testing.expectEqual(SymbolKind.module, util.kind);
    const helper = findSym(out.items, "helper").?;
    try testing.expectEqual(SymbolKind.function, helper.kind);
    try testing.expect(helper.parent_local != null);
    // `mod external;` is a file-module reference → an import edge.
    try testing.expectEqual(SymbolKind.import, findSym(out.items, "external").?.kind);
}

test "rust: unit and tuple structs are struct-kinded" {
    const src =
        \\pub struct Unit;
        \\pub struct Pair(i32, i32);
        \\struct Private;
    ;
    var out = try parseForTest(src, .rust);
    defer freeRefs(&out);
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Unit").?.kind);
    try testing.expect(findSym(out.items, "Unit").?.exported);
    try testing.expectEqual(SymbolKind.@"struct", findSym(out.items, "Pair").?.kind);
    // Visibility is honored: no `pub` → private.
    try testing.expect(!findSym(out.items, "Private").?.exported);
}

test "rust: a const-fn modifier is not mistaken for a plain const" {
    const src =
        \\pub const fn compute() -> u32 { helper() }
        \\const LIMIT: u32 = 5;
    ;
    var out = try parseForTest(src, .rust);
    defer freeRefs(&out);
    // `const fn` is a function, not a constant.
    const compute = findSym(out.items, "compute").?;
    try testing.expectEqual(SymbolKind.function, compute.kind);
    try testing.expect(hasCallRef(compute, "helper"));
    // A real const is still a constant.
    try testing.expectEqual(SymbolKind.constant, findSym(out.items, "LIMIT").?.kind);
}

// --- Ruby -----------------------------------------------------------------

test "ruby: instance method member call records the receiver qualifier" {
    const src =
        \\class Worker
        \\  def run
        \\    queue.push(job)
        \\  end
        \\end
    ;
    var out = try parseForTest(src, .ruby);
    defer freeRefs(&out);
    const run = findSym(out.items, "run").?;
    try testing.expectEqual(SymbolKind.method, run.kind);
    var q: []const u8 = "";
    for (run.refs) |r| {
        if (std.mem.eql(u8, r.name, "push")) q = r.qualifier;
    }
    try testing.expectEqualStrings("queue", q);
}

test "ruby: a method with default-valued params keeps its body refs" {
    const src =
        \\class Api
        \\  def fetch(id, limit = 10)
        \\    build(id)
        \\    paginate(limit)
        \\  end
        \\end
    ;
    var out = try parseForTest(src, .ruby);
    defer freeRefs(&out);
    const fetch = findSym(out.items, "fetch").?;
    try testing.expectEqual(SymbolKind.method, fetch.kind);
    try testing.expect(hasCallRef(fetch, "build"));
    try testing.expect(hasCallRef(fetch, "paginate"));
}

test "scope: JS/TS object-literal keys and untyped params are not global references" {
    // Reproduces the js_express scope-blindness bug. `count:` is a property key
    // and `count` is a parameter — neither is a reference to a top-level `count`.
    const src =
        \\function count() { return 0; }
        \\export function statsHandler(req, res) {
        \\    res.json({ count: size() });
        \\}
        \\export function formatStatus(count) {
        \\    return count > 0;
        \\}
    ;
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    const stats = findSym(out.items, "statsHandler").?;
    try testing.expect(!hasRef(stats, "count")); // object-literal key: not an edge
    try testing.expect(hasCallRef(stats, "size")); // a real call: still an edge
    // The untyped parameter is captured as a (typeless) binding, so a bare
    // `count` use in the body won't bind to the global `count`.
    const fmt = findSym(out.items, "formatStatus").?;
    try testing.expect(bindingType(fmt.bindings, "count") != null);
}

test "scope: Python dict keys ARE references (object-key suppression is JS-only)" {
    // In Python `{item: 2}` the key `item` is a variable read, so it must stay an
    // edge — the object-key suppression is gated to the JS family.
    const src =
        \\def item():
        \\    return 1
        \\def build():
        \\    return {item: 2}
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    const build = findSym(out.items, "build").?;
    try testing.expect(hasRef(build, "item"));
}

test "csharp: explicit access modifiers set member visibility (for --no-public)" {
    const src =
        \\namespace N {
        \\  class C {
        \\    public int Pub() { return 1; }
        \\    private int Priv() { return 2; }
        \\    protected int Prot() { return 3; }
        \\    int Bare() { return 4; }
        \\  }
        \\}
    ;
    var out = try parseForTest(src, .csharp);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "Pub").?.exported);
    try testing.expect(!findSym(out.items, "Priv").?.exported);
    try testing.expect(!findSym(out.items, "Prot").?.exported);
    // A bare member stays exported (conservative: its default depends on the
    // container, so don't over-hide it from `unused --no-public`).
    try testing.expect(findSym(out.items, "Bare").?.exported);
}

test "csharp: expression-bodied method is indexed with its body references" {
    const src =
        \\namespace N {
        \\  class Q {
        \\    public int Expr() => Helper() + 1;
        \\    int Helper() { return 1; }
        \\    public T Gen<T>(T x) => x;
        \\  }
        \\}
    ;
    var out = try parseForTest(src, .csharp);
    defer freeRefs(&out);
    // `Expr() => expr;` is a method (previously dropped: its `=>` body was
    // recognized as neither a `{` body nor a `;` declaration).
    const expr = findSym(out.items, "Expr").?;
    try testing.expectEqual(SymbolKind.method, expr.kind);
    try testing.expect(hasCallRef(expr, "Helper")); // the expression body's call is collected
    try testing.expect(findSym(out.items, "Helper") != null);
}

test "rust: a lifetime/generic-parameterized impl nests its methods under the type" {
    const src =
        \\struct Lexer<'a> { s: &'a str }
        \\impl<'a> Lexer<'a> {
        \\    fn new(s: &'a str) -> Lexer<'a> { return Lexer { s }; }
        \\    fn peek(&self) -> u8 { return 0; }
        \\}
    ;
    var out = try parseForTest(src, .rust);
    defer freeRefs(&out);
    const new_m = findSym(out.items, "new").?;
    try testing.expectEqual(SymbolKind.method, new_m.kind);
    try testing.expect(new_m.parent_local != null);
    // The parent is `Lexer`, not the lifetime `'a` (the old scan grabbed the last
    // identifier before `{`, which lives inside the `<…>`).
    try testing.expectEqualStrings("Lexer", out.items[new_m.parent_local.?].name);
    try testing.expect(findSym(out.items, "peek").?.parent_local != null);
}

test "go: a single-line import binds its path segment, not the `import` keyword" {
    const src =
        \\package m
        \\import "fmt"
        \\func F() { fmt.Println() }
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "fmt") != null); // bound as `fmt`
    try testing.expect(findSym(out.items, "import") == null); // never the keyword
}

test "go: grouped const/var skips multi-line initializers (no phantom symbols)" {
    const src =
        \\package main
        \\var (
        \\    client = newClient(
        \\        config,
        \\        timeout,
        \\    )
        \\    logger = mk
        \\)
        \\const (
        \\    Prefix = base +
        \\        suffix
        \\)
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "client") != null);
    try testing.expect(findSym(out.items, "logger") != null);
    try testing.expect(findSym(out.items, "Prefix") != null);
    // Call arguments and operator-continuation lines are part of the value, not
    // new declarations — they must not become phantom symbols.
    try testing.expect(findSym(out.items, "config") == null);
    try testing.expect(findSym(out.items, "timeout") == null);
    try testing.expect(findSym(out.items, "suffix") == null);
}

test "go: package decl is a module symbol; methods parent to their same-file receiver type" {
    const src =
        \\package metrics
        \\
        \\func (m *Metrics) Provision(x int) error {
        \\    return nil
        \\}
        \\
        \\type Metrics struct {
        \\    n int
        \\}
        \\
        \\func (Metrics) Nameless() {}
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);

    const pkg = findSym(out.items, "metrics").?;
    try testing.expectEqual(SymbolKind.module, pkg.kind);

    // Method declared BEFORE its type still gets parented (post-pass).
    const typ_idx: u32 = blk: {
        for (out.items, 0..) |s, i| {
            if (s.kind == .@"struct" and std.mem.eql(u8, s.name, "Metrics")) break :blk @intCast(i);
        }
        unreachable;
    };
    const prov = findSym(out.items, "Provision").?;
    try testing.expectEqual(typ_idx, prov.parent_local.?);
    // Nameless-receiver form `func (Metrics) X()` parents too.
    const nameless = findSym(out.items, "Nameless").?;
    try testing.expectEqual(typ_idx, nameless.parent_local.?);
}

test "go: a /vN module import binds the real package name, not the version segment" {
    const src =
        \\package main
        \\
        \\import (
        \\    "github.com/caddyserver/caddy/v2"
        \\    "example.com/single/v10"
        \\)
    ;
    var out = try parseForTest(src, .go);
    defer freeRefs(&out);
    try testing.expect(findSym(out.items, "caddy") != null);
    try testing.expect(findSym(out.items, "single") != null);
    try testing.expect(findSym(out.items, "v2") == null);
}

test "write classification covers direct, augmented, increment, and Go declaration assignment" {
    var js = try parseForTest("function run(obj) { obj.value = 1; obj.value += 2; obj.value++; }", .javascript);
    defer freeRefs(&js);
    const run = findSym(js.items, "run").?;
    var reads: u32 = 0;
    var writes: u32 = 0;
    for (run.refs) |ref| {
        if (!std.mem.eql(u8, ref.name, "value")) continue;
        if (ref.write) writes += ref.count else reads += ref.count;
    }
    try testing.expectEqual(@as(u32, 3), writes);
    try testing.expectEqual(@as(u32, 2), reads);

    var go = try parseForTest("package p\nfunc run() { value := 1; _ = value }\n", .go);
    defer freeRefs(&go);
    const go_run = findSym(go.items, "run").?;
    var saw_declaration_write = false;
    for (go_run.refs) |ref| if (std.mem.eql(u8, ref.name, "value") and ref.write) {
        saw_declaration_write = true;
    };
    try testing.expect(saw_declaration_write);
}

test "python: kwarg labels are typed writes and loop/context variables stay local" {
    const src =
        \\def use(envvar, done):
        \\    configure(envvar="PATH")
        \\    for envvar in items:
        \\        touch(envvar)
        \\    with open("f") as handle:
        \\        handle.close()
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    const use = findSym(out.items, "use").?;
    var saw_kwarg_write = false;
    for (use.refs) |r| {
        if (std.mem.eql(u8, r.name, "envvar") and r.line == 2) {
            try testing.expect(r.write);
            try testing.expectEqualStrings("configure", r.qualifier);
            saw_kwarg_write = true;
        }
    }
    try testing.expect(saw_kwarg_write);
    var saw_envvar = false;
    var saw_handle = false;
    for (use.bindings) |b| {
        if (std.mem.eql(u8, b.name, "envvar")) saw_envvar = true;
        if (std.mem.eql(u8, b.name, "handle")) saw_handle = true;
    }
    try testing.expect(saw_envvar); // `for envvar in …`
    try testing.expect(saw_handle); // `with … as handle`
}

test "references retain every exact source offset for rename planning" {
    const src = "function run() { helper(); helper(); }";
    var out = try parseForTest(src, .javascript);
    defer freeRefs(&out);
    const run = findSym(out.items, "run").?;
    const helper = for (run.refs) |ref| {
        if (std.mem.eql(u8, ref.name, "helper")) break ref;
    } else unreachable;
    try testing.expectEqual(helper.count, helper.offsets.len);
    try testing.expectEqual(@as(usize, 2), helper.offsets.len);
    for (helper.offsets) |offset| {
        try testing.expect(offset + helper.name.len <= src.len);
        try testing.expectEqualStrings("helper", src[offset .. offset + helper.name.len]);
    }
}

test "python docstrings attach to function and class symbols" {
    const src =
        \\class Service:
        \\    """Service contract."""
        \\    def run(self):
        \\        """Run one request."""
        \\        return work()
    ;
    var out = try parseForTest(src, .python);
    defer freeRefs(&out);
    try testing.expectEqualStrings("\"\"\"Service contract.\"\"\"", findSym(out.items, "Service").?.doc);
    try testing.expectEqualStrings("\"\"\"Run one request.\"\"\"", findSym(out.items, "run").?.doc);
}
