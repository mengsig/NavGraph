const std = @import("std");
const lexer = @import("lexer.zig");
const language = @import("language.zig");
const model = @import("model.zig");
const index_mod = @import("index.zig");
const query = @import("query.zig");
const render = @import("render.zig");
const json_out = @import("json_out.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;
const Token = lexer.Token;

pub const BaseEdge = struct {
    subtype: SymbolId,
    supertype: SymbolId = invalid,
    name: []const u8,
    exact: bool,
    parameterized: bool = false,
};

pub const Override = struct {
    method: SymbolId,
    base_method: SymbolId,
    depth: u32,
    exact: bool,
};

pub const Descendant = struct {
    id: SymbolId,
    depth: u32,
};

pub const Graph = struct {
    gpa: std.mem.Allocator,
    edges: []BaseEdge,

    pub fn deinit(self: *Graph) void {
        std.debug.assert(self.edges.len <= std.math.maxInt(SymbolId));
        self.gpa.free(self.edges);
        self.* = undefined;
    }

    pub fn mro(self: *const Graph, idx: *const Index, id: SymbolId) ![]SymbolId {
        std.debug.assert(id < idx.graph.symbols.len);
        std.debug.assert(isContainer(idx.graph.symbols[id]));
        const visiting = try self.gpa.alloc(bool, idx.graph.symbols.len);
        defer self.gpa.free(visiting);
        @memset(visiting, false);
        return linearize(self, idx, id, visiting);
    }

    pub fn descendants(self: *const Graph, idx: *const Index, root: SymbolId) ![]Descendant {
        std.debug.assert(root < idx.graph.symbols.len);
        std.debug.assert(isContainer(idx.graph.symbols[root]));
        const seen = try self.gpa.alloc(bool, idx.graph.symbols.len);
        defer self.gpa.free(seen);
        @memset(seen, false);
        var out: std.ArrayList(Descendant) = .empty;
        defer out.deinit(self.gpa);
        seen[root] = true;
        try appendDirectChildren(self, root, 1, seen, &out);
        var head: usize = 0;
        while (head < out.items.len) : (head += 1) {
            const descendant = out.items[head];
            try appendDirectChildren(self, descendant.id, descendant.depth + 1, seen, &out);
        }
        return out.toOwnedSlice(self.gpa);
    }
};

pub fn build(gpa: std.mem.Allocator, idx: *const Index) !Graph {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var edges: std.ArrayList(BaseEdge) = .empty;
    defer edges.deinit(gpa);
    for (idx.graph.symbols) |sym| {
        if (!isContainer(sym)) continue;
        try appendDeclaredBases(gpa, idx, sym, &edges);
    }
    try appendRustImpls(gpa, idx, &edges);
    return .{ .gpa = gpa, .edges = try edges.toOwnedSlice(gpa) };
}

pub fn run(w: *Writer, idx: *const Index, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    if (idx.graph.symbols.len == 0) return noHierarchy(w, selector, opts);
    const storage = try idx.gpa.alloc(SymbolId, idx.graph.symbols.len);
    defer idx.gpa.free(storage);
    const resolved = query.resolveIds(idx, selector, storage);
    const ids = filterContainers(idx, resolved, storage);
    if (ids.len == 0) return noHierarchy(w, selector, opts);
    var graph = try build(idx.gpa, idx);
    defer graph.deinit();
    if (opts.format == .json) return renderJson(w, idx, &graph, ids, opts);
    if (ids.len > 1) try w.print("({d} types match '{s}'; pin with Type@path)\n", .{ ids.len, selector });
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeByte('\n');
        try renderText(w, idx, &graph, id, opts);
    }
    return true;
}

fn appendDeclaredBases(gpa: std.mem.Allocator, idx: *const Index, sym: model.Symbol, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(isContainer(sym));
    std.debug.assert(sym.file < idx.graph.files.len);
    const file = idx.graph.files[sym.file];
    if (file.language == .go and sym.kind == .interface) {
        try appendGoEmbeddings(gpa, idx, sym, edges);
        return;
    }
    const sig = sym.signature(file.text);
    if (sig.len == 0) return;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try lexer.tokenize(gpa, sig, language.configFor(file.language), &toks);
    const name_i = findToken(toks.items, sig, sym.name) orelse return;
    switch (file.language.family()) {
        .python => try appendPythonBases(idx, sym, toks.items, sig, name_i, edges),
        .js => try appendKeywordBases(idx, sym, toks.items, sig, name_i, edges),
        .c, .csharp => try appendColonBases(idx, sym, toks.items, sig, name_i, edges),
        .ruby => try appendRubyBase(idx, sym, toks.items, sig, name_i, edges),
        else => {},
    }
}

fn appendPythonBases(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, name_i: usize, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(name_i < toks.len);
    std.debug.assert(std.mem.eql(u8, toks[name_i].text(src), sym.name));
    const open = findPunct(toks, src, name_i + 1, '(') orelse return;
    const close = matchingClose(toks, src, open, '(', ')') orelse return;
    try appendSegments(idx, sym, toks, src, open + 1, close, edges);
}

fn appendKeywordBases(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, name_i: usize, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(name_i < toks.len);
    std.debug.assert(isContainer(sym));
    var i = name_i + 1;
    while (i < toks.len and toks[i].kind != .eof) : (i += 1) {
        if (!tokenEq(toks, src, i, "extends") and !tokenEq(toks, src, i, "implements")) continue;
        const start = i + 1;
        var end = start;
        while (end < toks.len and toks[end].kind != .eof and !tokenEq(toks, src, end, "extends") and !tokenEq(toks, src, end, "implements")) : (end += 1) {}
        try appendSegments(idx, sym, toks, src, start, end, edges);
        i = if (end > 0) end - 1 else end;
    }
}

fn appendColonBases(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, name_i: usize, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(name_i < toks.len);
    std.debug.assert(isContainer(sym));
    const colon = findPunct(toks, src, name_i + 1, ':') orelse return;
    var end = colon + 1;
    while (end < toks.len and toks[end].kind != .eof and !tokenEq(toks, src, end, "where")) : (end += 1) {}
    try appendSegments(idx, sym, toks, src, colon + 1, end, edges);
}

fn appendRubyBase(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, name_i: usize, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(name_i < toks.len);
    std.debug.assert(isContainer(sym));
    const less = findPunct(toks, src, name_i + 1, '<') orelse return;
    try appendSegment(idx, sym, toks, src, less + 1, toks.len, edges);
}

fn appendSegments(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, lo: usize, hi: usize, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var start = lo;
    var depth: i32 = 0;
    var i = lo;
    while (i < hi) : (i += 1) {
        depth += bracketDelta(toks[i], src);
        if (depth == 0 and punctEq(toks[i], src, ',')) {
            try appendSegment(idx, sym, toks, src, start, i, edges);
            start = i + 1;
        }
    }
    try appendSegment(idx, sym, toks, src, start, hi, edges);
}

fn appendSegment(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, lo: usize, hi: usize, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    const lookup_name = segmentName(toks, src, lo, hi) orelse return;
    const identity = segmentIdentity(toks, src, lo, hi) orelse lookup_name;
    const properties = segmentProperties(toks, src, lo, hi);
    if (!properties.qualified and std.mem.eql(u8, lookup_name, sym.name)) return;
    const target = if (properties.qualified) null else resolveContainer(idx, sym, lookup_name);
    try appendEdge(edges, idx.gpa, .{
        .subtype = sym.id,
        .supertype = target orelse invalid,
        .name = identity,
        .exact = target != null,
        .parameterized = properties.parameterized,
    });
}

const SegmentProperties = struct { qualified: bool = false, parameterized: bool = false };

fn segmentIdentity(toks: []const Token, src: []const u8, lo: usize, hi: usize) ?[]const u8 {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var start = lo;
    while (start < hi and (toks[start].kind == .comment or toks[start].kind == .eof or
        (toks[start].kind == .identifier and baseKeyword(toks[start].text(src))))) : (start += 1)
    {}
    if (start >= hi) return null;
    var end = start;
    var depth: i32 = 0;
    for (toks[start..hi], start..) |tok, i| {
        if (tok.kind == .eof or tok.kind == .comment) continue;
        if (depth == 0 and (punctEq(tok, src, '{') or punctEq(tok, src, ';') or tokenEq(toks, src, i, "where"))) break;
        depth += bracketDelta(tok, src);
        end = i + 1;
    }
    if (end == start) return null;
    return std.mem.trim(u8, src[toks[start].start..toks[end - 1].end], " \t\r\n");
}

fn segmentProperties(toks: []const Token, src: []const u8, lo: usize, hi: usize) SegmentProperties {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var out: SegmentProperties = .{};
    var depth: i32 = 0;
    for (toks[lo..hi]) |tok| {
        if (depth == 0 and (punctEq(tok, src, '.') or punctEq(tok, src, ':'))) out.qualified = true;
        if (depth == 0 and (punctEq(tok, src, '<') or punctEq(tok, src, '['))) out.parameterized = true;
        depth += bracketDelta(tok, src);
    }
    return out;
}

fn segmentName(toks: []const Token, src: []const u8, lo: usize, hi: usize) ?[]const u8 {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var result: ?[]const u8 = null;
    var depth: i32 = 0;
    for (toks[lo..hi]) |tok| {
        if (depth == 0 and punctEq(tok, src, '=')) return null;
        if (depth == 0 and (punctEq(tok, src, '(') or punctEq(tok, src, '|') or punctEq(tok, src, '~'))) return null;
        if (depth == 0 and tok.kind == .identifier and !baseKeyword(tok.text(src))) result = tok.text(src);
        depth += bracketDelta(tok, src);
    }
    return result;
}

fn appendGoEmbeddings(gpa: std.mem.Allocator, idx: *const Index, sym: model.Symbol, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(sym.kind == .interface);
    std.debug.assert(idx.graph.files[sym.file].language == .go);
    const body = sym.body(idx.graph.files[sym.file].text);
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(gpa);
    try lexer.tokenize(gpa, body, language.configFor(.go), &toks);
    var start: usize = 0;
    while (start < toks.items.len) {
        const line = toks.items[start].line;
        var end = start + 1;
        while (end < toks.items.len and toks.items[end].line == line) : (end += 1) {}
        if (!lineHasPunct(toks.items, body, start, end, '('))
            try appendSegment(idx, sym, toks.items, body, start, end, edges);
        start = end;
    }
}

fn appendRustImpls(gpa: std.mem.Allocator, idx: *const Index, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    for (idx.graph.files) |file| {
        if (file.language != .rust) continue;
        var toks: std.ArrayList(Token) = .empty;
        defer toks.deinit(gpa);
        try lexer.tokenize(gpa, file.text, language.configFor(.rust), &toks);
        try scanRustImpls(idx, file.id, toks.items, file.text, edges);
    }
}

fn scanRustImpls(idx: *const Index, file_id: model.FileId, toks: []const Token, src: []const u8, edges: *std.ArrayList(BaseEdge)) !void {
    std.debug.assert(file_id < idx.graph.files.len);
    std.debug.assert(src.len <= std.math.maxInt(u32));
    for (toks, 0..) |tok, i| {
        if (tok.kind != .identifier or !std.mem.eql(u8, tok.text(src), "impl")) continue;
        const open = findPunct(toks, src, i + 1, '{') orelse continue;
        const for_i = findTokenRange(toks, src, i + 1, open, "for") orelse continue;
        if (lineHasPunct(toks, src, i + 1, for_i, '!')) continue;
        const trait_name = segmentName(toks, src, i + 1, for_i) orelse continue;
        const type_end = findTokenRange(toks, src, for_i + 1, open, "where") orelse open;
        const type_name = segmentName(toks, src, for_i + 1, type_end) orelse continue;
        const child = resolveContainerInFile(idx, file_id, type_name) orelse continue;
        const child_sym = idx.graph.symbols[child];
        const target = resolveContainer(idx, child_sym, trait_name);
        try appendEdge(edges, idx.gpa, .{ .subtype = child, .supertype = target orelse invalid, .name = trait_name, .exact = target != null });
    }
}

fn resolveContainer(idx: *const Index, child: model.Symbol, name: []const u8) ?SymbolId {
    std.debug.assert(child.file < idx.graph.files.len);
    std.debug.assert(name.len > 0);
    var local: ?SymbolId = null;
    var local_count: usize = 0;
    var project: ?SymbolId = null;
    var project_count: usize = 0;
    for (idx.lookup(name)) |id| {
        const sym = idx.graph.symbols[id];
        if (!isContainer(sym) or id == child.id) continue;
        if (idx.graph.files[sym.file].language.family() != idx.graph.files[child.file].language.family()) continue;
        project = id;
        project_count += 1;
        if (sym.file == child.file) {
            local = id;
            local_count += 1;
        }
    }
    if (local_count != 0) return if (local_count == 1) local else null;
    return if (project_count == 1) project else null;
}

fn resolveContainerInFile(idx: *const Index, file: model.FileId, name: []const u8) ?SymbolId {
    std.debug.assert(file < idx.graph.files.len);
    std.debug.assert(name.len > 0);
    var found: ?SymbolId = null;
    for (idx.lookup(name)) |id| {
        const sym = idx.graph.symbols[id];
        if (sym.file != file or !isContainer(sym)) continue;
        if (found != null) return null;
        found = id;
    }
    return found;
}

fn appendEdge(edges: *std.ArrayList(BaseEdge), gpa: std.mem.Allocator, edge: BaseEdge) !void {
    std.debug.assert(edge.name.len > 0);
    std.debug.assert(edge.subtype != invalid);
    try edges.append(gpa, edge);
}

fn linearize(graph: *const Graph, idx: *const Index, id: SymbolId, visiting: []bool) ![]SymbolId {
    std.debug.assert(id < idx.graph.symbols.len);
    std.debug.assert(visiting.len == idx.graph.symbols.len);
    if (visiting[id]) return error.InheritanceCycle;
    if (hasDuplicateBase(graph, id)) return error.DuplicateBase;
    visiting[id] = true;
    defer visiting[id] = false;
    const direct = try directBases(graph, idx.gpa, id);
    defer idx.gpa.free(direct);
    if (direct.len == 0) return idx.gpa.dupe(SymbolId, &.{id});
    var seqs = try idx.gpa.alloc(Sequence, direct.len + 1);
    defer idx.gpa.free(seqs);
    var built: usize = 0;
    defer for (seqs[0..built]) |seq| if (seq.owned) idx.gpa.free(seq.items);
    for (direct, 0..) |base, i| {
        seqs[i] = .{ .items = try linearize(graph, idx, base, visiting), .owned = true };
        built += 1;
    }
    seqs[direct.len] = .{ .items = direct, .owned = false };
    built += 1;
    return mergeLinearizations(idx.gpa, id, seqs);
}

const Sequence = struct {
    items: []const SymbolId,
    pos: usize = 0,
    owned: bool,
};

fn mergeLinearizations(gpa: std.mem.Allocator, root: SymbolId, seqs: []Sequence) ![]SymbolId {
    std.debug.assert(seqs.len > 0);
    std.debug.assert(root != invalid);
    var out: std.ArrayList(SymbolId) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, root);
    while (hasSequenceItems(seqs)) {
        const candidate = validHead(seqs) orelse return error.InconsistentHierarchy;
        if (!idIn(out.items, candidate)) try out.append(gpa, candidate);
        for (seqs) |*seq| if (seq.pos < seq.items.len and seq.items[seq.pos] == candidate) {
            seq.pos += 1;
        };
    }
    return out.toOwnedSlice(gpa);
}

fn validHead(seqs: []const Sequence) ?SymbolId {
    std.debug.assert(seqs.len > 0);
    for (seqs) |seq| {
        if (seq.pos >= seq.items.len) continue;
        const head = seq.items[seq.pos];
        var in_tail = false;
        for (seqs) |other| {
            if (other.pos + 1 < other.items.len and idIn(other.items[other.pos + 1 ..], head)) in_tail = true;
        }
        if (!in_tail) return head;
    }
    return null;
}

fn hasDuplicateBase(graph: *const Graph, id: SymbolId) bool {
    std.debug.assert(id != invalid);
    std.debug.assert(graph.edges.len <= std.math.maxInt(SymbolId));
    for (graph.edges, 0..) |edge, i| {
        if (edge.subtype != id) continue;
        for (graph.edges[i + 1 ..]) |other| {
            if (other.subtype != id) continue;
            if (std.mem.eql(u8, edge.name, other.name)) return true;
            if (!edge.parameterized and !other.parameterized and edge.supertype != invalid and edge.supertype == other.supertype) return true;
        }
    }
    return false;
}

fn directBases(graph: *const Graph, gpa: std.mem.Allocator, id: SymbolId) ![]SymbolId {
    std.debug.assert(id != invalid);
    std.debug.assert(graph.edges.len <= std.math.maxInt(SymbolId));
    var bases: std.ArrayList(SymbolId) = .empty;
    defer bases.deinit(gpa);
    for (graph.edges) |edge| {
        if (edge.subtype == id and edge.supertype != invalid and !idIn(bases.items, edge.supertype))
            try bases.append(gpa, edge.supertype);
    }
    return bases.toOwnedSlice(gpa);
}

fn appendDirectChildren(graph: *const Graph, parent: SymbolId, depth: u32, seen: []bool, out: *std.ArrayList(Descendant)) !void {
    std.debug.assert(parent < seen.len);
    std.debug.assert(depth > 0);
    for (graph.edges) |edge| {
        if (edge.supertype != parent or !edge.exact or seen[edge.subtype]) continue;
        seen[edge.subtype] = true;
        try out.append(graph.gpa, .{ .id = edge.subtype, .depth = depth });
    }
}

fn collectOverrides(graph: *const Graph, idx: *const Index, root: SymbolId, descendants: []const Descendant, strict: bool) ![]Override {
    std.debug.assert(root < idx.graph.symbols.len);
    std.debug.assert(isContainer(idx.graph.symbols[root]));
    var out: std.ArrayList(Override) = .empty;
    defer out.deinit(idx.gpa);
    try appendOverridesForType(graph, idx, root, 0, strict, &out);
    for (descendants) |desc| try appendOverridesForType(graph, idx, desc.id, desc.depth, strict, &out);
    return out.toOwnedSlice(idx.gpa);
}

fn appendOverridesForType(graph: *const Graph, idx: *const Index, type_id: SymbolId, depth: u32, strict: bool, out: *std.ArrayList(Override)) !void {
    std.debug.assert(type_id < idx.graph.symbols.len);
    std.debug.assert(isContainer(idx.graph.symbols[type_id]));
    const order = graph.mro(idx, type_id) catch return;
    defer idx.gpa.free(order);
    if (order.len < 2) return;
    for (idx.graph.symbols) |method| {
        if (method.parent != type_id or method.kind != .method) continue;
        const base_method = nearestBaseMethod(idx, method.name, order[1..]) orelse continue;
        const exact = overrideExact(idx, method.id, base_method);
        if (strict and !exact) continue;
        try out.append(idx.gpa, .{ .method = method.id, .base_method = base_method, .depth = depth, .exact = exact });
    }
}

fn overrideExact(idx: *const Index, method: SymbolId, base_method: SymbolId) bool {
    std.debug.assert(method < idx.graph.symbols.len);
    std.debug.assert(base_method < idx.graph.symbols.len);
    const lang = idx.graph.files[idx.graph.symbols[method].file].language;
    return lang != .cpp and lang != .csharp;
}

fn nearestBaseMethod(idx: *const Index, name: []const u8, mro: []const SymbolId) ?SymbolId {
    std.debug.assert(name.len > 0);
    std.debug.assert(mro.len <= idx.graph.symbols.len);
    for (mro) |parent| for (idx.lookup(name)) |id| {
        const sym = idx.graph.symbols[id];
        if (sym.kind == .method and sym.parent == parent) return id;
    };
    return null;
}

fn renderText(w: *Writer, idx: *const Index, graph: *const Graph, root: SymbolId, opts: query.Options) !void {
    std.debug.assert(root < idx.graph.symbols.len);
    std.debug.assert(isContainer(idx.graph.symbols[root]));
    try render.symbol(w, idx, idx.graph.symbols[root], opts.verbosity, 0, true);
    const order = graph.mro(idx, root) catch |err| block: {
        try w.print("\nMRO: invalid ({s})\n", .{@errorName(err)});
        break :block null;
    };
    if (order) |items| {
        defer idx.gpa.free(items);
        try renderMroText(w, idx, items, mroComplete(graph, items));
    }
    try renderExternalBasesText(w, graph, root, opts.strict);
    const descendants = try graph.descendants(idx, root);
    defer idx.gpa.free(descendants);
    try renderDescendantsText(w, idx, descendants, opts.limit);
    if (opts.hierarchy_overrides) {
        const overrides = try collectOverrides(graph, idx, root, descendants, opts.strict);
        defer idx.gpa.free(overrides);
        const subtype_emitted = @min(descendants.len, opts.limit);
        try renderOverridesText(w, idx, overrides, opts.limit - @as(u32, @intCast(subtype_emitted)));
    }
}

fn renderMroText(w: *Writer, idx: *const Index, order: []const SymbolId, complete: bool) !void {
    std.debug.assert(order.len > 0);
    std.debug.assert(order[0] < idx.graph.symbols.len);
    if (complete) try w.writeAll("\nMRO: ") else try w.writeAll("\nMRO (incomplete): ");
    for (order, 0..) |id, i| {
        if (i != 0) try w.writeAll(" → ");
        try w.writeAll(idx.graph.symbols[id].name);
    }
    try w.writeByte('\n');
}

fn mroComplete(graph: *const Graph, order: []const SymbolId) bool {
    std.debug.assert(order.len > 0);
    std.debug.assert(graph.edges.len <= std.math.maxInt(SymbolId));
    for (graph.edges) |edge| {
        if (idIn(order, edge.subtype) and (edge.supertype == invalid or !edge.exact)) return false;
    }
    return true;
}

fn renderExternalBasesText(w: *Writer, graph: *const Graph, root: SymbolId, strict: bool) !void {
    std.debug.assert(root != invalid);
    std.debug.assert(graph.edges.len <= std.math.maxInt(SymbolId));
    for (graph.edges) |edge| {
        if (edge.subtype != root or edge.supertype != invalid or strict) continue;
        try w.print("  ~ external/ambiguous base: {s} ?\n", .{edge.name});
    }
}

fn renderDescendantsText(w: *Writer, idx: *const Index, descendants: []const Descendant, limit: u32) !void {
    std.debug.assert(limit > 0);
    std.debug.assert(descendants.len <= idx.graph.symbols.len);
    try w.print("SUBTYPES ({d}):\n", .{descendants.len});
    for (descendants[0..@min(descendants.len, limit)]) |desc| {
        try w.print("  depth {d}: ", .{desc.depth});
        try render.symbol(w, idx, idx.graph.symbols[desc.id], .names, 0, true);
    }
    if (descendants.len > limit) try w.print("… ({d} more; raise -l to see them)\n", .{descendants.len - limit});
}

fn renderOverridesText(w: *Writer, idx: *const Index, overrides: []const Override, limit: u32) !void {
    std.debug.assert(overrides.len <= idx.graph.symbols.len);
    std.debug.assert(limit <= std.math.maxInt(u32));
    try w.print("OVERRIDES ({d}):\n", .{overrides.len});
    for (overrides[0..@min(overrides.len, limit)]) |item| {
        const method = idx.graph.symbols[item.method];
        const base = idx.graph.symbols[item.base_method];
        try w.print("  {s}.{s} overrides {s}.{s}{s}  {s}:{d}\n", .{
            idx.graph.symbols[method.parent].name, method.name,
            idx.graph.symbols[base.parent].name,   base.name,
            if (item.exact) "" else " ?",          idx.graph.files[method.file].path,
            method.line,
        });
    }
    if (overrides.len > limit) try w.print("… ({d} more; raise -l to see them)\n", .{overrides.len - limit});
}

fn renderJson(w: *Writer, idx: *const Index, graph: *const Graph, ids: []const SymbolId, opts: query.Options) !bool {
    std.debug.assert(ids.len > 0);
    std.debug.assert(opts.format == .json);
    try w.writeByte('[');
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try hierarchyObject(w, idx, graph, id, opts);
    }
    try w.writeAll("]\n");
    return true;
}

fn hierarchyObject(w: *Writer, idx: *const Index, graph: *const Graph, root: SymbolId, opts: query.Options) !void {
    std.debug.assert(root < idx.graph.symbols.len);
    std.debug.assert(isContainer(idx.graph.symbols[root]));
    try w.writeAll("{\"type\":");
    try json_out.symbolObject(w, idx, idx.graph.symbols[root], opts.verbosity);
    var mro_error: ?[]const u8 = null;
    const order = graph.mro(idx, root) catch |err| block: {
        mro_error = @errorName(err);
        break :block try idx.gpa.alloc(SymbolId, 0);
    };
    defer idx.gpa.free(order);
    try w.writeAll(",\"mro\":[");
    if (order.len != 0) try symbolList(w, idx, order);
    try w.writeAll("],\"mro_complete\":");
    try w.print("{}", .{mro_error == null and mroComplete(graph, order)});
    try w.writeAll(",\"mro_error\":");
    if (mro_error) |name| try json_out.writeString(w, name) else try w.writeAll("null");
    try w.writeAll(",\"external_bases\":[");
    try externalBasesJson(w, graph, root, opts.strict);
    const descendants = try graph.descendants(idx, root);
    defer idx.gpa.free(descendants);
    const overrides = if (opts.hierarchy_overrides) try collectOverrides(graph, idx, root, descendants, opts.strict) else null;
    defer if (overrides) |items| idx.gpa.free(items);
    const subtype_limit: u32 = @intCast(@min(descendants.len, opts.limit));
    const remaining = opts.limit - subtype_limit;
    const override_limit: u32 = @intCast(@min(if (overrides) |items| items.len else 0, remaining));
    try w.writeAll("],\"subtypes\":[");
    try descendantsJson(w, idx, descendants, subtype_limit);
    try w.writeAll("],\"overrides\":[");
    try overridesJson(w, idx, overrides orelse &.{}, override_limit);
    const override_count = if (overrides) |items| items.len else 0;
    try w.print("],\"counts\":{{\"subtypes\":{d},\"overrides\":{d}}},\"truncated\":{}}}", .{
        descendants.len,
        override_count,
        descendants.len + override_count > opts.limit,
    });
}

fn symbolList(w: *Writer, idx: *const Index, ids: []const SymbolId) !void {
    std.debug.assert(ids.len > 0);
    std.debug.assert(ids.len <= idx.graph.symbols.len);
    for (ids, 0..) |id, i| {
        if (i != 0) try w.writeByte(',');
        try json_out.symbolObject(w, idx, idx.graph.symbols[id], .names);
    }
}

fn externalBasesJson(w: *Writer, graph: *const Graph, root: SymbolId, strict: bool) !void {
    std.debug.assert(root != invalid);
    std.debug.assert(graph.edges.len <= std.math.maxInt(SymbolId));
    var first = true;
    for (graph.edges) |edge| {
        if (edge.subtype != root or edge.supertype != invalid or strict) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"name\":");
        try json_out.writeString(w, edge.name);
        try w.writeAll(",\"exact\":false}");
    }
}

fn descendantsJson(w: *Writer, idx: *const Index, descendants: []const Descendant, limit: u32) !void {
    std.debug.assert(descendants.len <= idx.graph.symbols.len);
    std.debug.assert(limit <= descendants.len);
    for (descendants[0..@min(descendants.len, limit)], 0..) |desc, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"symbol\":");
        try json_out.symbolObject(w, idx, idx.graph.symbols[desc.id], .names);
        try w.print(",\"depth\":{d},\"exact\":true}}", .{desc.depth});
    }
}

fn overridesJson(w: *Writer, idx: *const Index, overrides: []const Override, limit: u32) !void {
    std.debug.assert(overrides.len <= idx.graph.symbols.len);
    std.debug.assert(limit <= overrides.len);
    for (overrides[0..@min(overrides.len, limit)], 0..) |item, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"method\":");
        try json_out.symbolObject(w, idx, idx.graph.symbols[item.method], .names);
        try w.writeAll(",\"base_method\":");
        try json_out.symbolObject(w, idx, idx.graph.symbols[item.base_method], .names);
        try w.print(",\"depth\":{d},\"exact\":{}}}", .{ item.depth, item.exact });
    }
}

fn noHierarchy(w: *Writer, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(selector.len > 0);
    std.debug.assert(opts.limit > 0);
    if (opts.format == .json) try w.writeAll("[]\n") else try w.print("(no type named '{s}')\n", .{selector});
    return false;
}

fn filterContainers(idx: *const Index, ids: []const SymbolId, out: []SymbolId) []const SymbolId {
    std.debug.assert(ids.len <= idx.graph.symbols.len);
    std.debug.assert(out.len >= ids.len);
    var n: usize = 0;
    for (ids) |id| {
        if (!isContainer(idx.graph.symbols[id])) continue;
        out[n] = id;
        n += 1;
    }
    return out[0..n];
}

fn isContainer(sym: model.Symbol) bool {
    return switch (sym.kind) {
        .class, .@"struct", .interface => true,
        else => false,
    };
}

fn findToken(toks: []const Token, src: []const u8, name: []const u8) ?usize {
    return findTokenRange(toks, src, 0, toks.len, name);
}

fn findTokenRange(toks: []const Token, src: []const u8, lo: usize, hi: usize, name: []const u8) ?usize {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    for (toks[lo..hi], lo..) |tok, i| if (tok.kind == .identifier and std.mem.eql(u8, tok.text(src), name)) return i;
    return null;
}

fn findPunct(toks: []const Token, src: []const u8, from: usize, needle: u8) ?usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(src.len <= std.math.maxInt(u32));
    for (toks[from..], from..) |tok, i| if (punctEq(tok, src, needle)) return i;
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

fn bracketDelta(tok: Token, src: []const u8) i32 {
    if (tok.kind != .punct) return 0;
    const text = tok.text(src);
    if (text.len != 1) return 0;
    return switch (text[0]) {
        '(', '[', '<', '{' => 1,
        ')', ']', '>', '}' => -1,
        else => 0,
    };
}

fn lineHasPunct(toks: []const Token, src: []const u8, lo: usize, hi: usize, needle: u8) bool {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    for (toks[lo..hi]) |tok| if (punctEq(tok, src, needle)) return true;
    return false;
}

fn tokenEq(toks: []const Token, src: []const u8, i: usize, text: []const u8) bool {
    return i < toks.len and toks[i].kind == .identifier and std.mem.eql(u8, toks[i].text(src), text);
}

fn punctEq(tok: Token, src: []const u8, c: u8) bool {
    return tok.kind == .punct and tok.end == tok.start + 1 and src[tok.start] == c;
}

fn baseKeyword(name: []const u8) bool {
    const words = .{ "class", "interface", "struct", "extends", "implements", "public", "private", "protected", "virtual", "final", "abstract", "impl", "for", "where", "metaclass" };
    inline for (words) |word| if (std.mem.eql(u8, name, word)) return true;
    return false;
}

fn hasSequenceItems(seqs: []const Sequence) bool {
    std.debug.assert(seqs.len > 0);
    std.debug.assert(seqs.len <= std.math.maxInt(u32));
    for (seqs) |seq| if (seq.pos < seq.items.len) return true;
    return false;
}

fn idIn(ids: []const SymbolId, id: SymbolId) bool {
    std.debug.assert(ids.len <= std.math.maxInt(SymbolId));
    return std.mem.indexOfScalar(SymbolId, ids, id) != null;
}

test "hierarchy builds a diamond MRO and maps nearest overrides" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "diamond.py", .data =
        \\class Root:
        \\    def run(self): pass
        \\class Left(Root):
        \\    def run(self): pass
        \\class Right(Root):
        \\    pass
        \\class Leaf(Left, Right):
        \\    def run(self): pass
    });
    var path_buf: [256]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root_path, false);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    const leaf = idx.lookup("Leaf")[0];
    const order = try graph.mro(&idx, leaf);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(SymbolId, &.{ leaf, idx.lookup("Left")[0], idx.lookup("Right")[0], idx.lookup("Root")[0] }, order);
    const descendants = try graph.descendants(&idx, idx.lookup("Root")[0]);
    defer testing.allocator.free(descendants);
    try testing.expectEqual(@as(usize, 3), descendants.len);
    const overrides = try collectOverrides(&graph, &idx, idx.lookup("Root")[0], descendants, false);
    defer testing.allocator.free(overrides);
    try testing.expectEqual(@as(usize, 2), overrides.len);
    try testing.expectEqual(idx.lookup("Left")[0], idx.graph.symbols[overrides[1].base_method].parent);

    const leaf_descendants = try graph.descendants(&idx, leaf);
    defer testing.allocator.free(leaf_descendants);
    const leaf_overrides = try collectOverrides(&graph, &idx, leaf, leaf_descendants, false);
    defer testing.allocator.free(leaf_overrides);
    try testing.expectEqual(@as(usize, 1), leaf_overrides.len);
    try testing.expectEqual(leaf, idx.graph.symbols[leaf_overrides[0].method].parent);
    try testing.expectEqual(idx.lookup("Left")[0], idx.graph.symbols[leaf_overrides[0].base_method].parent);

    var output_bytes: std.ArrayList(u8) = .empty;
    defer output_bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &output_bytes);
    defer output.deinit();
    try testing.expect(try run(&output.writer, &idx, "Leaf", .{ .format = .json, .hierarchy_overrides = true }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"base_method\"") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"counts\"") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"truncated\":false") != null);
}

test "hierarchy JSON shares one result limit across sections" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bounded.py", .data =
        \\class Base:
        \\    def run(self): pass
        \\class Child(Base):
        \\    def run(self): pass
        \\class Other(Base): pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &bytes);
    defer output.deinit();
    try testing.expect(try run(&output.writer, &idx, "Base", .{ .format = .json, .hierarchy_overrides = true, .limit = 1 }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    const object = parsed.value.array.items[0].object;
    try testing.expectEqual(@as(usize, 1), object.get("subtypes").?.array.items.len);
    try testing.expectEqual(@as(usize, 0), object.get("overrides").?.array.items.len);
    try testing.expectEqual(@as(i64, 2), object.get("counts").?.object.get("subtypes").?.integer);
    try testing.expectEqual(@as(i64, 1), object.get("counts").?.object.get("overrides").?.integer);
    try testing.expect(object.get("truncated").?.bool);
}

test "hierarchy keeps qualified unresolved bases distinct" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "qualified.py", .data = "class Child(a.Base, b.Base): pass\n" });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    const child = idx.lookup("Child")[0];
    const order = try graph.mro(&idx, child);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(SymbolId, &.{child}, order);
    try testing.expectEqual(@as(usize, 2), graph.edges.len);
    try testing.expectEqualStrings("a.Base", graph.edges[0].name);
    try testing.expectEqualStrings("b.Base", graph.edges[1].name);
}

test "hierarchy reports MROs with unresolved ancestor bases as incomplete" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "incomplete.py", .data =
        \\class Known(Missing): pass
        \\class Child(Known): pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    const order = try graph.mro(&idx, idx.lookup("Child")[0]);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 2), order.len);
    try testing.expect(!mroComplete(&graph, order));

    var json_bytes: std.ArrayList(u8) = .empty;
    defer json_bytes.deinit(testing.allocator);
    var json: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &json_bytes);
    defer json.deinit();
    try testing.expect(try run(&json.writer, &idx, "Child", .{ .format = .json }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json.written(), .{});
    defer parsed.deinit();
    try testing.expect(!parsed.value.array.items[0].object.get("mro_complete").?.bool);

    var text_bytes: std.ArrayList(u8) = .empty;
    defer text_bytes.deinit(testing.allocator);
    var text: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &text_bytes);
    defer text.deinit();
    try testing.expect(try run(&text.writer, &idx, "Child", .{}));
    try testing.expect(std.mem.indexOf(u8, text.written(), "MRO (incomplete):") != null);
}

test "C++ and C# name-only override matches are inexact and strict excludes them" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "types.cpp", .data =
        \\class NativeBase { public: virtual void Run() {} };
        \\class NativeChild : public NativeBase { public: void Run(int value) {} };
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "Types.cs", .data =
        \\class ManagedBase { public void Run() {} }
        \\class ManagedChild : ManagedBase { public void Run(int value) {} }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    inline for (.{ "NativeChild", "ManagedChild" }) |name| {
        const child = idx.lookup(name)[0];
        const descendants = try graph.descendants(&idx, child);
        defer testing.allocator.free(descendants);
        const loose = try collectOverrides(&graph, &idx, child, descendants, false);
        defer testing.allocator.free(loose);
        try testing.expectEqual(@as(usize, 1), loose.len);
        try testing.expect(!loose[0].exact);
        const strict = try collectOverrides(&graph, &idx, child, descendants, true);
        defer testing.allocator.free(strict);
        try testing.expectEqual(@as(usize, 0), strict.len);
    }
}

test "hierarchy JSON reports inheritance cycles instead of inventing an MRO" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "cycle.py", .data =
        \\class A(B): pass
        \\class B(A): pass
    });
    var path_buf: [256]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root_path, false);
    defer idx.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &bytes);
    defer output.deinit();
    try testing.expect(try run(&output.writer, &idx, "A", .{ .format = .json }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .array);
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"mro\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "InheritanceCycle") != null);
}

test "hierarchy keeps an ambiguous external base honest" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.py", .data = "class Base: pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.py", .data = "class Base: pass\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "child.py", .data = "class Child(Base): pass\n" });
    var path_buf: [256]u8 = undefined;
    const root_path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root_path, false);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    const child = idx.lookup("Child")[0];
    try testing.expectEqual(@as(usize, 1), graph.edges.len);
    try testing.expectEqual(child, graph.edges[0].subtype);
    try testing.expectEqual(invalid, graph.edges[0].supertype);
    try testing.expect(!graph.edges[0].exact);
}

test "hierarchy resolves Rust trait impls with generic where clauses" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "traits.rs", .data =
        \\trait Service { fn run(&self); }
        \\trait Blocked {}
        \\struct Worker<T> { value: T }
        \\impl<T> Service for Worker<T> where T: Copy {
        \\    fn run(&self) {}
        \\}
        \\impl<T> !Blocked for Worker<T> {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 1), idx.lookup("Worker").len);
    try testing.expectEqual(@as(usize, 1), idx.lookup("Service").len);
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    const order = try graph.mro(&idx, idx.lookup("Worker")[0]);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 2), order.len);
    try testing.expectEqual(idx.lookup("Service")[0], order[1]);
    for (graph.edges) |edge| try testing.expect(!std.mem.eql(u8, edge.name, "Blocked"));
}

test "hierarchy resolves embedded Go interfaces" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "streams.go", .data =
        \\package streams
        \\type Reader interface { Read([]byte) error }
        \\type Closer interface { Close() error }
        \\type ReadCloser interface {
        \\    Reader
        \\    Closer
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 1), idx.lookup("ReadCloser").len);
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    const order = try graph.mro(&idx, idx.lookup("ReadCloser")[0]);
    defer testing.allocator.free(order);
    try testing.expectEqual(@as(usize, 3), order.len);
    try testing.expectEqualStrings("Reader", idx.graph.symbols[order[1]].name);
    try testing.expectEqualStrings("Closer", idx.graph.symbols[order[2]].name);
}

test "hierarchy resolves C++ and C# nominal bases" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "types.cpp", .data =
        \\class NativeBase {};
        \\class NativeChild : public NativeBase {};
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "Types.cs", .data =
        \\class ManagedBase {}
        \\class ManagedChild : ManagedBase {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    const native = try graph.mro(&idx, idx.lookup("NativeChild")[0]);
    defer testing.allocator.free(native);
    const managed = try graph.mro(&idx, idx.lookup("ManagedChild")[0]);
    defer testing.allocator.free(managed);
    try testing.expectEqual(@as(usize, 2), native.len);
    try testing.expectEqualStrings("NativeBase", idx.graph.symbols[native[1]].name);
    try testing.expectEqual(@as(usize, 2), managed.len);
    try testing.expectEqualStrings("ManagedBase", idx.graph.symbols[managed[1]].name);
}

test "hierarchy rejects an inconsistent C3 linearization" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "inconsistent.py", .data =
        \\class X: pass
        \\class Y: pass
        \\class A(X, Y): pass
        \\class B(Y, X): pass
        \\class Broken(A, B): pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 1), idx.lookup("Broken").len);
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    try testing.expectError(error.InconsistentHierarchy, graph.mro(&idx, idx.lookup("Broken")[0]));
}

test "hierarchy rejects duplicate direct bases" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "duplicate.py", .data =
        \\class Base: pass
        \\class Broken(Base, Base): pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 2), graph.edges.len);
    try testing.expectError(error.DuplicateBase, graph.mro(&idx, idx.lookup("Broken")[0]));
}
