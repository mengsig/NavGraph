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

const Token = lexer.Token;
const AllocError = std.mem.Allocator.Error;
const SymbolKind = model.SymbolKind;
const Reference = model.Reference;
const RefKind = model.RefKind;

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
    /// Index (into the per-file parse output) of the enclosing symbol, if any.
    parent_local: ?u32,
    refs: []Reference,
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
    };
    const n: u32 = @intCast(toks.items.len - 1); // exclude eof from scans
    switch (lang.family()) {
        .zig => try parseZigScope(&ctx, 0, n, null),
        .c => try parseCScope(&ctx, 0, n, null),
        .js => try parseJsScope(&ctx, 0, n, null),
        .python => try parsePython(&ctx),
        .other => {},
    }
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

const KeywordSet = std.StaticStringMap(void);

/// Collect deduplicated references from the token range [lo, hi).
fn collectRefs(ctx: *Ctx, lo: u32, hi: u32, self_name: []const u8, kw: KeywordSet) ![]Reference {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= ctx.toks.len);
    var seen: std.StringHashMap(u32) = .init(ctx.gpa);
    defer seen.deinit();
    var refs: std.ArrayList(Reference) = .empty;
    defer refs.deinit(ctx.gpa);

    var i = lo;
    while (i < hi) : (i += 1) {
        const t = ctx.toks[i];
        if (t.kind != .identifier) continue;
        const name = t.text(ctx.source);
        if (name.len < 2 or kw.has(name)) continue;
        if (std.mem.eql(u8, name, self_name)) continue;
        const is_call = i + 1 < hi and ctx.isPunct(i + 1, '(');
        try recordRef(ctx, &refs, &seen, name, t.line, is_call);
    }
    return ctx.arena.dupe(Reference, refs.items);
}

fn recordRef(
    ctx: *Ctx,
    refs: *std.ArrayList(Reference),
    seen: *std.StringHashMap(u32),
    name: []const u8,
    line: u32,
    is_call: bool,
) !void {
    if (seen.get(name)) |idx| {
        var r = &refs.items[idx];
        r.count += 1;
        if (is_call) r.kind = .call;
        return;
    }
    try seen.put(name, @intCast(refs.items.len));
    try refs.append(ctx.gpa, .{
        .name = name,
        .line = line,
        .kind = if (is_call) .call else .read,
        .count = 1,
    });
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
    const refs = try collectRefs(ctx, body_lo, body_hi, ctx.textOf(name_i), zig_keywords);
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
        .refs = refs,
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

fn parseCScope(ctx: *Ctx, lo: u32, hi: u32, parent: ?u32) !void {
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
        if (ctx.identEql(i, "struct") or ctx.identEql(i, "enum") or ctx.identEql(i, "union")) {
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

fn parseCRecord(ctx: *Ctx, stmt_start: u32, kw_i: u32, hi: u32, parent: ?u32) !u32 {
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return kw_i;
    const name_i = kw_i + 1;
    if (kw_i + 2 >= hi or !ctx.isPunct(kw_i + 2, '{')) return kw_i;
    const open = kw_i + 2;
    const close = ctx.close[open];
    if (close == sentinel) return kw_i;
    const kind: SymbolKind = if (ctx.identEql(kw_i, "enum")) .@"enum" else .@"struct";
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = kind,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, stmt_start),
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[open].start,
        .doc = collectDoc(ctx, stmt_start),
        .exported = true,
        .parent_local = parent,
        .refs = &.{},
    });
    return close + 1;
}

fn tryCFunction(ctx: *Ctx, stmt_start: u32, name_i: u32, hi: u32, parent: ?u32) !u32 {
    const params_open = name_i + 1;
    const params_close = ctx.close[params_open];
    if (params_close == sentinel) return name_i;
    // A definition has `{` right after the parameter list; otherwise it is a
    // declaration or a call, which we ignore at this level.
    if (params_close + 1 >= hi or !ctx.isPunct(params_close + 1, '{')) return name_i;
    // Guard: the token before the name must not itself be a call keyword.
    if (c_keywords.has(ctx.textOf(name_i))) return name_i;
    const body_open = params_close + 1;
    const body_close = ctx.close[body_open];
    if (body_close == sentinel) return name_i;
    const refs = try collectRefs(ctx, body_open + 1, body_close, ctx.textOf(name_i), c_keywords);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (parent != null) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, stmt_start),
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = collectDoc(ctx, stmt_start),
        .exported = true,
        .parent_local = parent,
        .refs = refs,
    });
    return body_close + 1;
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
        _ = try emit(ctx, .{
            .name = module,
            .kind = .import,
            .line = line,
            .span_start = lineStartOffset(ctx, i),
            .span_end = ctx.toks[j - 1].end,
            .sig_end = ctx.toks[j - 1].end,
            .doc = "",
            .exported = false,
            .parent_local = null,
            .refs = &.{},
        });
    }
    return j;
}

fn parseJsDecl(ctx: *Ctx, i: u32, hi: u32, parent: ?u32) !u32 {
    const exported = ctx.identEql(i, "export");
    var k = i;
    while (k < hi and (ctx.identEql(k, "export") or ctx.identEql(k, "default"))) k += 1;
    if (k >= hi) return i;

    if (ctx.identEql(k, "class")) return parseJsClass(ctx, i, k, hi, parent, exported);
    if (ctx.identEql(k, "function") or (ctx.identEql(k, "async") and ctx.identEql(k + 1, "function"))) {
        const fn_i = if (ctx.identEql(k, "async")) k + 1 else k;
        return parseJsFunction(ctx, i, fn_i, hi, parent, exported);
    }
    if (ctx.identEql(k, "const") or ctx.identEql(k, "let") or ctx.identEql(k, "var")) {
        return parseJsBinding(ctx, i, k, hi, parent, exported);
    }
    if (parent != null) return parseJsMember(ctx, i, k, hi, parent.?);
    return i;
}

fn parseJsFunction(ctx: *Ctx, start_i: u32, fn_i: u32, hi: u32, parent: ?u32, exported: bool) !u32 {
    if (fn_i + 1 >= hi or ctx.toks[fn_i + 1].kind != .identifier) return start_i;
    const name_i = fn_i + 1;
    if (!ctx.isPunct(name_i + 1, '(')) return start_i;
    const pclose = ctx.close[name_i + 1];
    if (pclose == sentinel) return start_i;
    const body_open = findNext(ctx, pclose + 1, hi, '{');
    if (body_open == sentinel or ctx.close[body_open] == sentinel) return start_i;
    const body_close = ctx.close[body_open];
    const refs = try collectRefs(ctx, body_open + 1, body_close, ctx.textOf(name_i), js_keywords);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (parent != null) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .parent_local = parent,
        .refs = refs,
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
    if (kw_i + 1 >= hi or ctx.toks[kw_i + 1].kind != .identifier) return start_i;
    const name_i = kw_i + 1;
    const eq_i = findNext(ctx, name_i + 1, hi, '=');
    const semi_i = findNext(ctx, name_i + 1, hi, ';');
    const arrow_body = detectJsArrow(ctx, eq_i, hi, semi_i);
    if (arrow_body.open != sentinel) {
        return emitJsArrow(ctx, start_i, name_i, arrow_body, parent, exported, hi);
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

const JsArrow = struct { open: u32, is_fn: bool };

/// Detect `= ... => {` arrow functions with block bodies before the statement
/// terminator. Returns the block `{` index when found.
fn detectJsArrow(ctx: *const Ctx, eq_i: u32, hi: u32, semi_i: u32) JsArrow {
    if (eq_i == sentinel) return .{ .open = sentinel, .is_fn = false };
    const limit = if (semi_i != sentinel) semi_i else hi;
    var i = eq_i + 1;
    var saw_arrow = false;
    while (i < limit) {
        if (ctx.isPunct(i, '(') or ctx.isPunct(i, '[')) {
            i = skipBracket(ctx, i);
            continue;
        }
        if (ctx.toks[i].kind == .punct and ctx.ch(i) == '=' and i + 1 < limit and ctx.isPunct(i + 1, '>')) {
            saw_arrow = true;
            i += 2;
            continue;
        }
        if (saw_arrow and ctx.isPunct(i, '{')) return .{ .open = i, .is_fn = true };
        if (ctx.isPunct(i, '{')) {
            i = skipBracket(ctx, i);
            continue;
        }
        i += 1;
    }
    return .{ .open = sentinel, .is_fn = saw_arrow };
}

fn emitJsArrow(ctx: *Ctx, start_i: u32, name_i: u32, arrow: JsArrow, parent: ?u32, exported: bool, hi: u32) !u32 {
    const close = ctx.close[arrow.open];
    if (close == sentinel) return start_i + 1;
    const refs = try collectRefs(ctx, arrow.open + 1, close, ctx.textOf(name_i), js_keywords);
    _ = try emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (parent != null) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[close].end,
        .sig_end = ctx.toks[arrow.open].start,
        .doc = collectDoc(ctx, start_i),
        .exported = exported,
        .parent_local = parent,
        .refs = refs,
    });
    _ = hi;
    return close + 1;
}

/// Class members: methods `name(...) { }` and accessors.
fn parseJsMember(ctx: *Ctx, start_i: u32, k: u32, hi: u32, parent: u32) !u32 {
    var m = k;
    while (m < hi and (ctx.identEql(m, "static") or ctx.identEql(m, "async") or
        ctx.identEql(m, "get") or ctx.identEql(m, "set") or ctx.identEql(m, "readonly"))) m += 1;
    if (m >= hi or ctx.toks[m].kind != .identifier) return start_i;
    if (!ctx.isPunct(m + 1, '(')) return start_i;
    const pclose = ctx.close[m + 1];
    if (pclose == sentinel) return start_i;
    if (!ctx.isPunct(pclose + 1, '{')) return start_i;
    const body_open = pclose + 1;
    const body_close = ctx.close[body_open];
    if (body_close == sentinel) return start_i;
    const refs = try collectRefs(ctx, body_open + 1, body_close, ctx.textOf(m), js_keywords);
    _ = try emit(ctx, .{
        .name = ctx.textOf(m),
        .kind = .method,
        .line = ctx.toks[m].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = ctx.toks[body_close].end,
        .sig_end = ctx.toks[body_open].start,
        .doc = collectDoc(ctx, start_i),
        .exported = false,
        .parent_local = parent,
        .refs = refs,
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
    var i: u32 = 0;
    while (i < hi) : (i += 1) {
        if (!isLineStart(ctx, i) or ctx.toks[i].kind != .identifier) continue;
        const indent = ctx.toks[i].col;
        popPyScopes(&stack, indent);
        const enclosing: ?PyScope = if (stack.items.len != 0) stack.items[stack.items.len - 1] else null;
        const parent: ?u32 = if (enclosing) |e| e.local_idx else null;
        if (ctx.identEql(i, "def") or (ctx.identEql(i, "async") and i + 1 < hi and ctx.identEql(i + 1, "def"))) {
            const def_i = if (ctx.identEql(i, "async")) i + 1 else i;
            const is_method = if (enclosing) |e| e.is_class else false;
            const idx = try parsePyDef(ctx, i, def_i, hi, if (is_method) parent else null, is_method);
            if (idx != sentinel) try stack.append(ctx.gpa, .{ .indent = indent, .local_idx = idx, .is_class = false });
        } else if (ctx.identEql(i, "class")) {
            const idx = try parsePyClass(ctx, i, hi, parent);
            if (idx != sentinel) try stack.append(ctx.gpa, .{ .indent = indent, .local_idx = idx, .is_class = true });
        } else if (isPyKeyword(ctx, i)) {
            continue;
        } else {
            const in_func = if (enclosing) |e| !e.is_class else false;
            if (!in_func) try tryPyAssign(ctx, i, hi, parent);
        }
    }
}

fn isPyKeyword(ctx: *const Ctx, i: u32) bool {
    return py_keywords.has(ctx.textOf(i));
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

fn parsePyDef(ctx: *Ctx, start_i: u32, def_i: u32, hi: u32, parent: ?u32, is_method: bool) !u32 {
    if (def_i + 1 >= hi or ctx.toks[def_i + 1].kind != .identifier) return sentinel;
    const name_i = def_i + 1;
    const indent = ctx.toks[start_i].col;
    const term = pyBlockEnd(ctx, start_i, indent, hi);
    const span_end = if (term < hi) lineStartTrimEnd(ctx, term) else @as(u32, @intCast(ctx.source.len));
    const colon = findNext(ctx, name_i + 1, hi, ':');
    const sig_end = if (colon != sentinel) ctx.toks[colon].end else ctx.toks[name_i].end;
    const body_lo = if (colon != sentinel) colon + 1 else name_i + 1;
    const refs = try collectRefs(ctx, body_lo, term, ctx.textOf(name_i), py_keywords);
    return emit(ctx, .{
        .name = ctx.textOf(name_i),
        .kind = if (is_method) .method else .function,
        .line = ctx.toks[name_i].line,
        .span_start = lineStartOffset(ctx, start_i),
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = collectDoc(ctx, start_i),
        .exported = ctx.source[ctx.toks[name_i].start] != '_',
        .parent_local = parent,
        .refs = refs,
    });
}

fn parsePyClass(ctx: *Ctx, start_i: u32, hi: u32, parent: ?u32) !u32 {
    if (start_i + 1 >= hi or ctx.toks[start_i + 1].kind != .identifier) return sentinel;
    const name_i = start_i + 1;
    const indent = ctx.toks[start_i].col;
    const term = pyBlockEnd(ctx, start_i, indent, hi);
    const span_end = if (term < hi) lineStartTrimEnd(ctx, term) else @as(u32, @intCast(ctx.source.len));
    const colon = findNext(ctx, name_i + 1, hi, ':');
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
    _ = try emit(ctx, .{
        .name = ctx.textOf(i),
        .kind = if (parent != null) .field else .variable,
        .line = ctx.toks[i].line,
        .span_start = lineStartOffset(ctx, i),
        .span_end = lineEndOffset(ctx, ctx.toks[i].start),
        .sig_end = lineEndOffset(ctx, ctx.toks[i].start),
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

fn freeRefs(out: *std.ArrayList(ParsedSymbol)) void {
    for (out.items) |s| {
        if (s.refs.len != 0) testing.allocator.free(s.refs);
    }
    out.deinit(testing.allocator);
}
