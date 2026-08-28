const std = @import("std");
const lexer = @import("lexer.zig");
const language = @import("language.zig");
const model = @import("model.zig");
const index_mod = @import("index.zig");

const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;
const Token = lexer.Token;

pub const RaiseSite = struct {
    owner: SymbolId,
    type_name: []const u8,
    line: u32,
    offset: u32,
    exact: bool,
};

pub const CatchSite = struct {
    owner: SymbolId,
    type_name: []const u8,
    line: u32,
    offset: u32,
    protected_lo: u32,
    protected_hi: u32,
    catch_all: bool,
    exact: bool,
};

pub const Analysis = struct {
    gpa: std.mem.Allocator,
    raises: []RaiseSite,
    catches: []CatchSite,

    pub fn deinit(self: *Analysis) void {
        std.debug.assert(self.raises.len <= std.math.maxInt(u32));
        std.debug.assert(self.catches.len <= std.math.maxInt(u32));
        self.gpa.free(self.raises);
        self.gpa.free(self.catches);
        self.* = undefined;
    }
};

pub fn collect(gpa: std.mem.Allocator, idx: *const Index) !Analysis {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var raises: std.ArrayList(RaiseSite) = .empty;
    defer raises.deinit(gpa);
    var catches: std.ArrayList(CatchSite) = .empty;
    defer catches.deinit(gpa);
    for (idx.graph.files) |file| {
        var toks: std.ArrayList(Token) = .empty;
        defer toks.deinit(gpa);
        try lexer.tokenize(gpa, file.text, language.configFor(file.language), &toks);
        try scanFile(idx, file.id, toks.items, file.text, &raises, &catches);
    }
    const raise_sites = try raises.toOwnedSlice(gpa);
    errdefer gpa.free(raise_sites);
    const catch_sites = try catches.toOwnedSlice(gpa);
    return .{
        .gpa = gpa,
        .raises = raise_sites,
        .catches = catch_sites,
    };
}

fn scanFile(idx: *const Index, file: model.FileId, toks: []const Token, src: []const u8, raises: *std.ArrayList(RaiseSite), catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(file < idx.graph.files.len);
    std.debug.assert(src.len <= std.math.maxInt(u32));
    const lang = idx.graph.files[file].language;
    for (toks, 0..) |tok, i| {
        if (tok.kind != .identifier) continue;
        const word = tok.text(src);
        switch (lang.family()) {
            .python => if (std.mem.eql(u8, word, "raise"))
                try appendKeywordRaise(idx, file, toks, src, i, raises)
            else if (std.mem.eql(u8, word, "try"))
                try appendPythonCatches(idx, file, toks, src, i, catches),
            .js, .csharp, .java => if (std.mem.eql(u8, word, "throw"))
                try appendKeywordRaise(idx, file, toks, src, i, raises)
            else if (std.mem.eql(u8, word, "try"))
                try appendBraceCatches(idx, file, toks, src, i, catches),
            .c => if (lang == .cpp and std.mem.eql(u8, word, "throw"))
                try appendKeywordRaise(idx, file, toks, src, i, raises)
            else if (lang == .cpp and std.mem.eql(u8, word, "try"))
                try appendBraceCatches(idx, file, toks, src, i, catches),
            .ruby => if (std.mem.eql(u8, word, "raise") or std.mem.eql(u8, word, "fail"))
                try appendKeywordRaise(idx, file, toks, src, i, raises)
            else if (std.mem.eql(u8, word, "begin"))
                try appendRubyCatches(idx, file, toks, src, i, catches)
            else if (std.mem.eql(u8, word, "rescue") and lineStart(toks, i))
                try appendRubyMethodCatch(idx, file, toks, src, i, catches),
            .go => if (std.mem.eql(u8, word, "panic") and isCall(toks, src, i))
                try appendRaise(idx, file, tok, "panic", true, raises)
            else if (std.mem.eql(u8, word, "recover") and isCall(toks, src, i))
                try appendWholeOwnerCatch(idx, file, tok, "*", false, catches),
            .rust => if ((std.mem.eql(u8, word, "panic") or std.mem.eql(u8, word, "unwrap") or std.mem.eql(u8, word, "expect")) and callLike(toks, src, i))
                try appendRaise(idx, file, tok, "panic", std.mem.eql(u8, word, "panic"), raises),
            .zig => if (std.mem.eql(u8, word, "error") and i + 2 < toks.len and punctEq(toks[i + 1], src, '.') and toks[i + 2].kind == .identifier)
                try appendRaise(idx, file, toks[i + 2], toks[i + 2].text(src), zigErrorIsPropagation(toks, src, i), raises)
            else if (std.mem.eql(u8, word, "catch"))
                try appendWholeOwnerCatch(idx, file, tok, "*", false, catches),
            else => {},
        }
    }
}

fn appendKeywordRaise(idx: *const Index, file: model.FileId, toks: []const Token, src: []const u8, i: usize, raises: *std.ArrayList(RaiseSite)) !void {
    std.debug.assert(i < toks.len);
    std.debug.assert(toks[i].kind == .identifier);
    var j = i + 1;
    if (j < toks.len and tokenEq(toks[j], src, "new")) j += 1;
    const same_line = j < toks.len and toks[j].line == toks[i].line;
    if (!same_line or toks[j].kind != .identifier) {
        try appendRaise(idx, file, toks[i], "*", false, raises);
        return;
    }
    const name = qualifiedTail(toks, src, j);
    try appendRaise(idx, file, toks[j], name, looksTypeName(name), raises);
}

fn appendRaise(idx: *const Index, file: model.FileId, tok: Token, type_name: []const u8, exact: bool, raises: *std.ArrayList(RaiseSite)) !void {
    std.debug.assert(type_name.len > 0);
    std.debug.assert(tok.start <= idx.graph.files[file].text.len);
    const owner = ownerAt(idx, file, tok.start) orelse return;
    for (raises.items) |site| if (site.owner == owner and site.offset == tok.start and std.mem.eql(u8, site.type_name, type_name)) return;
    try raises.append(idx.gpa, .{ .owner = owner, .type_name = type_name, .line = tok.line, .offset = tok.start, .exact = exact });
}

fn appendPythonCatches(idx: *const Index, file: model.FileId, toks: []const Token, src: []const u8, try_i: usize, catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(try_i < toks.len);
    std.debug.assert(tokenEq(toks[try_i], src, "try"));
    const colon = findPunctOnLine(toks, src, try_i + 1, toks[try_i].line, ':') orelse return;
    const first = nextClause(toks, src, colon + 1, toks[try_i].col, "except") orelse return;
    const owner = ownerAt(idx, file, toks[try_i].start) orelse return;
    var clause = first;
    while (clause < toks.len and tokenEq(toks[clause], src, "except") and toks[clause].col == toks[try_i].col) {
        const end = pythonHeaderColon(toks, src, clause + 1, toks[clause].col) orelse break;
        try appendCatchTypes(idx, owner, toks, src, clause, clause + 1, end, toks[colon].end, toks[first].start, true, catches);
        clause = nextDedentedClause(toks, clause + 1, toks[try_i].col) orelse break;
    }
}

fn appendBraceCatches(idx: *const Index, file: model.FileId, toks: []const Token, src: []const u8, try_i: usize, catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(try_i < toks.len);
    std.debug.assert(tokenEq(toks[try_i], src, "try"));
    const open = findPunct(toks, src, try_i + 1, '{') orelse return;
    const close = matchingClose(toks, src, open, '{', '}') orelse return;
    const owner = ownerAt(idx, file, toks[try_i].start) orelse return;
    const lang = idx.graph.files[file].language;
    var cursor = close + 1;
    while (cursor < toks.len) {
        cursor = nextCode(toks, cursor) orelse return;
        if (!tokenEq(toks[cursor], src, "catch")) return;
        const body_open = findPunct(toks, src, cursor + 1, '{') orelse return;
        const body_close = matchingClose(toks, src, body_open, '{', '}') orelse return;
        const header_open = findPunctBefore(toks, src, cursor + 1, body_open, '(');
        if (header_open) |ho| {
            const hc = matchingClose(toks, src, ho, '(', ')') orelse return;
            const filtered = lang == .csharp and hasToken(toks, src, hc + 1, body_open, "when");
            try appendCatchTypes(idx, owner, toks, src, cursor, ho + 1, hc, toks[open].end, toks[close].start, !filtered, catches);
        } else {
            try appendCatch(idx, owner, toks[cursor], "*", toks[open].end, toks[close].start, true, catches);
        }
        cursor = body_close + 1;
    }
}

fn appendRubyCatches(idx: *const Index, file: model.FileId, toks: []const Token, src: []const u8, begin_i: usize, catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(begin_i < toks.len);
    std.debug.assert(tokenEq(toks[begin_i], src, "begin"));
    const first = nextClause(toks, src, begin_i + 1, toks[begin_i].col, "rescue") orelse return;
    const owner = ownerAt(idx, file, toks[begin_i].start) orelse return;
    var clause = first;
    while (clause < toks.len and tokenEq(toks[clause], src, "rescue") and toks[clause].col == toks[begin_i].col) {
        var end = clause + 1;
        while (end < toks.len and toks[end].line == toks[clause].line) : (end += 1) {}
        try appendCatchTypes(idx, owner, toks, src, clause, clause + 1, end, toks[begin_i].end, toks[first].start, true, catches);
        clause = nextDedentedClause(toks, clause + 1, toks[begin_i].col) orelse break;
    }
}

fn appendRubyMethodCatch(idx: *const Index, file: model.FileId, toks: []const Token, src: []const u8, rescue_i: usize, catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(rescue_i < toks.len);
    std.debug.assert(tokenEq(toks[rescue_i], src, "rescue"));
    const owner = ownerAt(idx, file, toks[rescue_i].start) orelse return;
    const sym = idx.graph.symbols[owner];
    if (toks[rescue_i].start <= sym.sig_end) return;
    var end = rescue_i + 1;
    while (end < toks.len and toks[end].line == toks[rescue_i].line) : (end += 1) {}
    try appendCatchTypes(idx, owner, toks, src, rescue_i, rescue_i + 1, end, sym.sig_end, toks[rescue_i].start, true, catches);
}

fn appendCatchTypes(idx: *const Index, owner: SymbolId, toks: []const Token, src: []const u8, catch_i: usize, lo: usize, hi: usize, protected_lo: u32, protected_hi: u32, exact: bool, catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    const lang = idx.graph.files[idx.graph.symbols[owner].file].language;
    if (lang == .ruby) {
        try appendRubyCatchTypes(idx, owner, toks, src, catch_i, lo, hi, protected_lo, protected_hi, exact, catches);
        return;
    }
    if (lang.family() == .js) {
        try appendCatch(idx, owner, toks[catch_i], "*", protected_lo, protected_hi, exact, catches);
        return;
    }
    if (lang == .cpp or lang == .csharp or lang == .java) {
        const name = braceCatchType(toks, src, lo, hi);
        try appendCatch(idx, owner, toks[catch_i], name orelse "*", protected_lo, protected_hi, exact, catches);
        return;
    }
    var found = false;
    var after_as = false;
    for (toks[lo..hi]) |tok| {
        if (tokenEq(tok, src, "as")) {
            after_as = true;
            continue;
        }
        if (after_as or tok.kind != .identifier) continue;
        const name = tok.text(src);
        if (!looksTypeName(name) or catchKeyword(name)) continue;
        try appendCatch(idx, owner, toks[catch_i], name, protected_lo, protected_hi, exact, catches);
        found = true;
    }
    if (!found) try appendCatch(idx, owner, toks[catch_i], "*", protected_lo, protected_hi, exact, catches);
}

fn appendRubyCatchTypes(idx: *const Index, owner: SymbolId, toks: []const Token, src: []const u8, catch_i: usize, lo: usize, hi: usize, protected_lo: u32, protected_hi: u32, exact: bool, catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    const header_hi = rubyBindingStart(toks, src, lo, hi) orelse hi;
    var segment_lo = lo;
    var found = false;
    for (toks[lo..header_hi], lo..) |tok, i| {
        if (!punctEq(tok, src, ',')) continue;
        found = try appendRubyCatchSegment(idx, owner, toks, src, catch_i, segment_lo, i, protected_lo, protected_hi, exact, catches) or found;
        segment_lo = i + 1;
    }
    found = try appendRubyCatchSegment(idx, owner, toks, src, catch_i, segment_lo, header_hi, protected_lo, protected_hi, exact, catches) or found;
    if (!found) try appendCatch(idx, owner, toks[catch_i], "StandardError", protected_lo, protected_hi, exact, catches);
}

fn appendRubyCatchSegment(idx: *const Index, owner: SymbolId, toks: []const Token, src: []const u8, catch_i: usize, lo: usize, hi: usize, protected_lo: u32, protected_hi: u32, exact: bool, catches: *std.ArrayList(CatchSite)) !bool {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var first: ?usize = null;
    for (toks[lo..hi], lo..) |tok, i| {
        if (tok.kind == .identifier) {
            first = i;
            break;
        }
    }
    const first_i = first orelse return false;
    const first_name = toks[first_i].text(src);
    const name = if (looksTypeName(first_name)) qualifiedTail(toks[0..hi], src, first_i) else first_name;
    const static_type = looksTypeName(name) and rubyStaticType(toks, src, lo, hi);
    try appendCatch(idx, owner, toks[catch_i], name, protected_lo, protected_hi, exact and static_type, catches);
    return true;
}

fn rubyBindingStart(toks: []const Token, src: []const u8, lo: usize, hi: usize) ?usize {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var i = lo;
    while (i + 1 < hi) : (i += 1) {
        if (punctEq(toks[i], src, '=') and punctEq(toks[i + 1], src, '>')) return i;
    }
    return null;
}

fn rubyStaticType(toks: []const Token, src: []const u8, lo: usize, hi: usize) bool {
    std.debug.assert(lo < hi);
    std.debug.assert(hi <= toks.len);
    for (toks[lo..hi]) |tok| switch (tok.kind) {
        .identifier => if (!looksTypeName(tok.text(src))) return false,
        .punct => if (!punctEq(tok, src, ':')) return false,
        .comment, .eof => {},
        else => return false,
    };
    return true;
}

fn braceCatchType(toks: []const Token, src: []const u8, lo: usize, hi: usize) ?[]const u8 {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var previous: ?usize = null;
    var last: ?usize = null;
    var depth: i32 = 0;
    for (toks[lo..hi], lo..) |tok, i| {
        if (depth == 0 and (punctEq(tok, src, '&') or punctEq(tok, src, '*'))) break;
        if (depth == 0 and tok.kind == .identifier and !typeModifier(tok.text(src))) {
            previous = last;
            last = i;
        }
        depth += typeDepthDelta(tok, src);
    }
    const candidate = last orelse return null;
    if (previous == null or qualifiedIdentifier(toks, src, lo, candidate)) return toks[candidate].text(src);
    return toks[previous.?].text(src);
}

fn qualifiedIdentifier(toks: []const Token, src: []const u8, lo: usize, i: usize) bool {
    std.debug.assert(lo <= i and i < toks.len);
    if (i > lo and punctEq(toks[i - 1], src, '.')) return true;
    return i >= lo + 2 and punctEq(toks[i - 1], src, ':') and punctEq(toks[i - 2], src, ':');
}

fn typeModifier(name: []const u8) bool {
    inline for (.{ "const", "volatile", "typename", "class", "struct", "auto", "final", "ref", "out", "in" }) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

fn typeDepthDelta(tok: Token, src: []const u8) i32 {
    if (tok.kind != .punct or tok.end != tok.start + 1) return 0;
    return switch (src[tok.start]) {
        '<', '(', '[', '{' => 1,
        '>', ')', ']', '}' => -1,
        else => 0,
    };
}

fn appendCatch(idx: *const Index, owner: SymbolId, tok: Token, type_name: []const u8, protected_lo: u32, protected_hi: u32, exact: bool, catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(owner < idx.graph.symbols.len);
    std.debug.assert(protected_lo <= protected_hi);
    for (catches.items) |site| {
        if (site.owner == owner and site.offset == tok.start and std.mem.eql(u8, site.type_name, type_name)) return;
    }
    try catches.append(idx.gpa, .{
        .owner = owner,
        .type_name = type_name,
        .line = tok.line,
        .offset = tok.start,
        .protected_lo = protected_lo,
        .protected_hi = protected_hi,
        .catch_all = std.mem.eql(u8, type_name, "*"),
        .exact = exact,
    });
}

fn appendWholeOwnerCatch(idx: *const Index, file: model.FileId, tok: Token, type_name: []const u8, exact: bool, catches: *std.ArrayList(CatchSite)) !void {
    std.debug.assert(type_name.len > 0);
    std.debug.assert(file < idx.graph.files.len);
    const owner = ownerAt(idx, file, tok.start) orelse return;
    const sym = idx.graph.symbols[owner];
    try appendCatch(idx, owner, tok, type_name, sym.span_start, sym.span_end, exact, catches);
}

fn ownerAt(idx: *const Index, file: model.FileId, offset: u32) ?SymbolId {
    std.debug.assert(file < idx.graph.files.len);
    std.debug.assert(offset <= idx.graph.files[file].text.len);
    const source_file = idx.graph.files[file];
    var best: ?SymbolId = null;
    var best_span: u32 = std.math.maxInt(u32);
    var id = source_file.sym_start;
    while (id < source_file.sym_end) : (id += 1) {
        const sym = idx.graph.symbols[id];
        if (!isCallable(sym.kind) or offset < sym.span_start or offset >= sym.span_end) continue;
        const span = sym.span_end - sym.span_start;
        if (span < best_span) {
            best = id;
            best_span = span;
        }
    }
    return best;
}

fn isCallable(kind: model.SymbolKind) bool {
    return switch (kind) {
        .function, .method, .test_case, .macro => true,
        else => false,
    };
}

fn nextClause(toks: []const Token, src: []const u8, from: usize, col: u32, name: []const u8) ?usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(name.len > 0);
    var i = from;
    while (i < toks.len) : (i += 1) {
        if (toks[i].kind == .comment or toks[i].kind == .eof) continue;
        if (!lineStart(toks, i) or toks[i].col > col) continue;
        if (toks[i].col < col) return null;
        return if (tokenEq(toks[i], src, name)) i else null;
    }
    return null;
}

fn nextDedentedClause(toks: []const Token, from: usize, col: u32) ?usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(col <= std.math.maxInt(u32));
    var i = from;
    while (i < toks.len) : (i += 1) {
        if (toks[i].kind == .comment or toks[i].kind == .eof) continue;
        if (lineStart(toks, i) and toks[i].col <= col) return i;
    }
    return null;
}

fn matchingClose(toks: []const Token, src: []const u8, open: usize, lhs: u8, rhs: u8) ?usize {
    std.debug.assert(open < toks.len);
    std.debug.assert(punctEq(toks[open], src, lhs));
    var depth: i32 = 0;
    for (toks[open..], open..) |tok, i| {
        if (punctEq(tok, src, lhs)) depth += 1;
        if (punctEq(tok, src, rhs)) depth -= 1;
        if (depth == 0) return i;
    }
    return null;
}

fn findPunct(toks: []const Token, src: []const u8, from: usize, needle: u8) ?usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(src.len <= std.math.maxInt(u32));
    for (toks[from..], from..) |tok, i| if (punctEq(tok, src, needle)) return i;
    return null;
}

fn findPunctBefore(toks: []const Token, src: []const u8, lo: usize, hi: usize, needle: u8) ?usize {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    for (toks[lo..hi], lo..) |tok, i| if (punctEq(tok, src, needle)) return i;
    return null;
}

fn findPunctOnLine(toks: []const Token, src: []const u8, from: usize, line: u32, needle: u8) ?usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(line > 0);
    var i = from;
    while (i < toks.len and toks[i].line == line) : (i += 1) if (punctEq(toks[i], src, needle)) return i;
    return null;
}

fn pythonHeaderColon(toks: []const Token, src: []const u8, from: usize, clause_col: u32) ?usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(src.len == 0 or toks.len > 0);
    var depth: i32 = 0;
    for (toks[from..], from..) |tok, i| {
        if (tok.kind == .comment) continue;
        if (depth == 0 and punctEq(tok, src, ':')) return i;
        if (depth == 0 and tok.kind == .identifier and tok.col <= clause_col) return null;
        if (tok.kind != .punct or tok.end != tok.start + 1) continue;
        depth += switch (src[tok.start]) {
            '(', '[', '{' => 1,
            ')', ']', '}' => -1,
            else => 0,
        };
        if (depth < 0) return null;
    }
    return null;
}

fn hasToken(toks: []const Token, src: []const u8, lo: usize, hi: usize, name: []const u8) bool {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    for (toks[lo..hi]) |tok| if (tokenEq(tok, src, name)) return true;
    return false;
}

fn nextCode(toks: []const Token, from: usize) ?usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(toks.len <= std.math.maxInt(u32));
    var i = from;
    while (i < toks.len and (toks[i].kind == .comment or toks[i].kind == .eof)) : (i += 1) {}
    return if (i < toks.len) i else null;
}

fn qualifiedTail(toks: []const Token, src: []const u8, first: usize) []const u8 {
    std.debug.assert(first < toks.len);
    std.debug.assert(toks[first].kind == .identifier);
    var result = toks[first].text(src);
    var i = first;
    while (i + 2 < toks.len) {
        var next = i + 2;
        if (punctEq(toks[i + 1], src, ':')) {
            if (i + 3 >= toks.len or !punctEq(toks[i + 2], src, ':')) break;
            next = i + 3;
        } else if (!punctEq(toks[i + 1], src, '.')) break;
        if (next >= toks.len or toks[next].kind != .identifier or tokenEq(toks[next], src, "new")) break;
        result = toks[next].text(src);
        i = next;
    }
    return result;
}

fn lineStart(toks: []const Token, i: usize) bool {
    return i == 0 or toks[i - 1].line != toks[i].line;
}

fn isCall(toks: []const Token, src: []const u8, i: usize) bool {
    return i + 1 < toks.len and punctEq(toks[i + 1], src, '(');
}

fn callLike(toks: []const Token, src: []const u8, i: usize) bool {
    return isCall(toks, src, i) or (i + 1 < toks.len and punctEq(toks[i + 1], src, '!'));
}

fn tokenEq(tok: Token, src: []const u8, text: []const u8) bool {
    return tok.kind == .identifier and std.mem.eql(u8, tok.text(src), text);
}

fn punctEq(tok: Token, src: []const u8, c: u8) bool {
    return tok.kind == .punct and tok.end == tok.start + 1 and src[tok.start] == c;
}

fn zigErrorIsPropagation(toks: []const Token, src: []const u8, error_i: usize) bool {
    std.debug.assert(error_i < toks.len);
    std.debug.assert(tokenEq(toks[error_i], src, "error"));
    var i = error_i;
    while (i > 0) {
        i -= 1;
        if (toks[i].kind == .comment or punctEq(toks[i], src, '(')) continue;
        return tokenEq(toks[i], src, "return");
    }
    return false;
}

fn looksTypeName(name: []const u8) bool {
    std.debug.assert(name.len <= std.math.maxInt(u32));
    if (name.len == 0) return false;
    return std.ascii.isUpper(name[0]);
}

fn catchKeyword(name: []const u8) bool {
    inline for (.{ "except", "catch", "const", "ref", "in", "out", "when", "rescue" }) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

test "collects Python raises and typed/catch-all protected ranges" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "service.py", .data =
        \\def handled():
        \\    try:
        \\        raise ValueError("bad")
        \\    # handler comment
        \\    except ValueError:
        \\        return None
        \\def open_gap():
        \\    raise RuntimeError("boom")
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 2), analysis.raises.len);
    try testing.expectEqual(@as(usize, 1), analysis.catches.len);
    try testing.expect(std.mem.eql(u8, analysis.catches[0].type_name, "ValueError"));
    try testing.expect(analysis.catches[0].protected_lo < analysis.raises[0].offset);
    try testing.expect(analysis.raises[0].offset < analysis.catches[0].protected_hi);
}

test "collects multiline Python except tuples" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "multiline.py", .data =
        \\def run():
        \\    try:
        \\        raise ValueError("bad")
        \\    except (
        \\        ValueError,
        \\        TypeError,
        \\    ):
        \\        return None
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 1), analysis.raises.len);
    try testing.expectEqual(@as(usize, 2), analysis.catches.len);
    try testing.expectEqualStrings("ValueError", analysis.catches[0].type_name);
    try testing.expectEqualStrings("TypeError", analysis.catches[1].type_name);
}

test "collects brace-language throws and catch-all handlers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "service.ts", .data =
        \\function run() {
        \\  try { throw new OrderError(); }
        \\  catch (err) { return null; }
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 1), analysis.raises.len);
    try testing.expectEqual(@as(usize, 1), analysis.catches.len);
    try testing.expect(std.mem.eql(u8, analysis.raises[0].type_name, "OrderError"));
    try testing.expect(analysis.catches[0].catch_all);
}

test "collects qualified lowercase C++ exception types" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "service.cpp", .data =
        \\void run() {
        \\  try { throw std::runtime_error("bad"); }
        \\  catch (const std::runtime_error& err) {}
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 1), analysis.raises.len);
    try testing.expectEqual(@as(usize, 1), analysis.catches.len);
    try testing.expectEqualStrings("runtime_error", analysis.raises[0].type_name);
    try testing.expectEqualStrings("runtime_error", analysis.catches[0].type_name);
    try testing.expect(!analysis.catches[0].catch_all);
}

test "collects method-level Ruby rescue and preserves the raised class" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "service.rb", .data =
        \\class MyError < StandardError; end
        \\def run
        \\  raise Errors::MyError.new("bad")
        \\rescue StandardError
        \\  nil
        \\end
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 1), analysis.raises.len);
    try testing.expectEqual(@as(usize, 1), analysis.catches.len);
    try testing.expectEqualStrings("MyError", analysis.raises[0].type_name);
    try testing.expectEqualStrings("StandardError", analysis.catches[0].type_name);
    try testing.expect(analysis.catches[0].protected_lo < analysis.raises[0].offset);
}

test "Ruby bare rescues mean StandardError and dynamic rescue expressions stay inexact" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "rescue.rb", .data =
        \\def bare
        \\  raise StandardError.new
        \\rescue
        \\  nil
        \\end
        \\def bound
        \\  raise StandardError.new
        \\rescue => error
        \\  nil
        \\end
        \\def dynamic(handler)
        \\  raise StandardError.new
        \\rescue handler
        \\  nil
        \\end
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 3), analysis.catches.len);
    try testing.expectEqualStrings("StandardError", analysis.catches[0].type_name);
    try testing.expectEqualStrings("StandardError", analysis.catches[1].type_name);
    try testing.expect(!analysis.catches[0].catch_all and !analysis.catches[1].catch_all);
    try testing.expect(analysis.catches[0].exact and analysis.catches[1].exact);
    try testing.expectEqualStrings("handler", analysis.catches[2].type_name);
    try testing.expect(!analysis.catches[2].catch_all and !analysis.catches[2].exact);
}

test "C# catch filters are conditional and therefore inexact" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Service.cs", .data =
        \\class OrderError : Exception {}
        \\class Service {
        \\  void Run() {
        \\    try { throw new OrderError(); }
        \\    catch (OrderError error) when (ShouldHandle(error)) {}
        \\  }
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 1), analysis.catches.len);
    try testing.expectEqualStrings("OrderError", analysis.catches[0].type_name);
    try testing.expect(!analysis.catches[0].catch_all);
    try testing.expect(!analysis.catches[0].exact);
}

test "dynamic error values and C throw identifiers are not exact raises" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dynamic.py", .data =
        \\def run(error):
        \\    raise error
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.c", .data =
        \\int throw(int value) { return value; }
        \\int run(void) { int throw_value = 0; return throw(throw_value); }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 1), analysis.raises.len);
    try testing.expectEqualStrings("error", analysis.raises[0].type_name);
    try testing.expect(!analysis.raises[0].exact);
}

test "marks ordinary Zig error values heuristic but returned errors exact" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "service.zig", .data =
        \\fn compare(err: anyerror) bool { return err == error.NotFound; }
        \\fn fail() !void { return error.NotFound; }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var analysis = try collect(testing.allocator, &idx);
    defer analysis.deinit();
    try testing.expectEqual(@as(usize, 2), analysis.raises.len);
    try testing.expect(!analysis.raises[0].exact);
    try testing.expect(analysis.raises[1].exact);
}
