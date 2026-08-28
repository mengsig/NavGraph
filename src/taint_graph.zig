const std = @import("std");
const lexer = @import("lexer.zig");
const language = @import("language.zig");
const model = @import("model.zig");
const index_mod = @import("index.zig");

const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;
const Token = lexer.Token;

pub const Confidence = enum(u8) {
    exact,
    inferred,
    heuristic,

    pub fn tag(self: Confidence) []const u8 {
        return @tagName(self);
    }
};

pub const NodeKind = enum {
    source,
    sink,
    variable,
    parameter,
    return_value,
};

pub const Node = struct {
    kind: NodeKind,
    owner: SymbolId,
    name: []const u8,
    line: u32,
    offset: u32,
    param_index: u16 = 0,
};

pub const EdgeKind = enum {
    source_value,
    assignment,
    argument,
    return_value,
    call_result,
    sink_argument,
};

pub const Edge = struct {
    from: u32,
    to: u32,
    kind: EdgeKind,
    file: model.FileId,
    line: u32,
    confidence: Confidence,
};

pub const Selector = struct {
    raw: []const u8,
    name: []const u8,
    path: []const u8,

    pub fn parse(raw: []const u8) ?Selector {
        if (raw.len == 0) return null;
        var body = raw;
        var path: []const u8 = "";
        if (std.mem.lastIndexOfScalar(u8, body, '@')) |at| {
            path = body[at + 1 ..];
            body = body[0..at];
            if (path.len == 0) return null;
        }
        if (!validSelectorName(body)) return null;
        return .{ .raw = raw, .name = body, .path = path };
    }

    pub fn fileMatches(self: Selector, path: []const u8) bool {
        std.debug.assert(self.name.len > 0);
        std.debug.assert(path.len > 0);
        return self.path.len == 0 or std.mem.indexOf(u8, path, self.path) != null;
    }
};

pub const Graph = struct {
    gpa: std.mem.Allocator,
    nodes: []Node,
    edges: []Edge,

    pub fn deinit(self: *Graph) void {
        std.debug.assert(self.nodes.len <= std.math.maxInt(u32));
        std.debug.assert(self.edges.len <= std.math.maxInt(u32));
        self.gpa.free(self.nodes);
        self.gpa.free(self.edges);
        self.* = undefined;
    }

    pub fn sourceCount(self: Graph) usize {
        var count: usize = 0;
        for (self.nodes) |node| if (node.kind == .source) {
            count += 1;
        };
        return count;
    }

    pub fn sinkCount(self: Graph) usize {
        var count: usize = 0;
        for (self.nodes) |node| if (node.kind == .sink) {
            count += 1;
        };
        return count;
    }
};

const CallableRange = struct { start: u32, end: u32 };

const CallableIndex = struct {
    ids: []SymbolId,
    ranges: []CallableRange,
};

const Builder = struct {
    gpa: std.mem.Allocator,
    idx: *const Index,
    source: Selector,
    sink: Selector,
    param_starts: []u32,
    param_counts: []u32,
    return_nodes: []u32,
    span_lines: []u32,
    callable_ids: []SymbolId,
    callable_ranges: []CallableRange,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,

    fn init(gpa: std.mem.Allocator, idx: *const Index, source: Selector, sink: Selector) !Builder {
        std.debug.assert(source.name.len > 0);
        std.debug.assert(sink.name.len > 0);
        const starts = try gpa.alloc(u32, idx.graph.symbols.len);
        errdefer gpa.free(starts);
        const counts = try gpa.alloc(u32, idx.graph.symbols.len);
        errdefer gpa.free(counts);
        const returns = try gpa.alloc(u32, idx.graph.symbols.len);
        errdefer gpa.free(returns);
        const span_lines = try gpa.alloc(u32, idx.graph.symbols.len);
        errdefer gpa.free(span_lines);
        const callable_index = try buildCallableIndex(gpa, idx);
        errdefer gpa.free(callable_index.ids);
        errdefer gpa.free(callable_index.ranges);
        @memset(starts, 0);
        @memset(counts, 0);
        @memset(returns, invalid);
        fillSpanLines(idx, span_lines);
        return .{
            .gpa = gpa,
            .idx = idx,
            .source = source,
            .sink = sink,
            .param_starts = starts,
            .param_counts = counts,
            .return_nodes = returns,
            .span_lines = span_lines,
            .callable_ids = callable_index.ids,
            .callable_ranges = callable_index.ranges,
        };
    }

    fn deinit(self: *Builder) void {
        std.debug.assert(self.nodes.items.len <= std.math.maxInt(u32));
        std.debug.assert(self.edges.items.len <= std.math.maxInt(u32));
        self.gpa.free(self.param_starts);
        self.gpa.free(self.param_counts);
        self.gpa.free(self.return_nodes);
        self.gpa.free(self.span_lines);
        self.gpa.free(self.callable_ids);
        self.gpa.free(self.callable_ranges);
        self.nodes.deinit(self.gpa);
        self.edges.deinit(self.gpa);
    }
};

pub fn build(gpa: std.mem.Allocator, idx: *const Index, source: Selector, sink: Selector) !Graph {
    std.debug.assert(source.name.len > 0);
    std.debug.assert(sink.name.len > 0);
    var b = try Builder.init(gpa, idx, source, sink);
    defer b.deinit();
    for (idx.graph.symbols) |sym| {
        if (!isCallable(sym.kind)) continue;
        b.return_nodes[sym.id] = try appendNode(&b, .return_value, sym.id, "return", sym.line, sym.sig_end, 0);
        b.param_starts[sym.id] = @intCast(b.nodes.items.len);
        try appendParameterNodes(&b, sym);
    }
    for (idx.graph.symbols) |sym| {
        if (isCallable(sym.kind)) try scanOwner(&b, sym);
    }
    const nodes = try b.nodes.toOwnedSlice(gpa);
    errdefer gpa.free(nodes);
    const edges = try b.edges.toOwnedSlice(gpa);
    return .{
        .gpa = gpa,
        .nodes = nodes,
        .edges = edges,
    };
}

fn appendParameterNodes(b: *Builder, sym: model.Symbol) !void {
    std.debug.assert(isCallable(sym.kind));
    std.debug.assert(sym.file < b.idx.graph.files.len);
    const source = b.idx.graph.files[sym.file].text;
    const sig = source[sym.span_start..sym.sig_end];
    if (sig.len == 0) return;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(b.gpa);
    try lexer.tokenize(b.gpa, sig, language.configFor(b.idx.graph.files[sym.file].language), &toks);
    const lang = b.idx.graph.files[sym.file].language;
    var open = findPunct(toks.items, sig, 0, '(') orelse return;
    if (lang == .go and sym.kind == .method) {
        const receiver_close = matchingClose(toks.items, sig, open, '(', ')') orelse return;
        open = findPunct(toks.items, sig, receiver_close + 1, '(') orelse return;
    }
    const close = matchingClose(toks.items, sig, open, '(', ')') orelse return;
    var segment = open + 1;
    var depth: i32 = 0;
    var in_default = false;
    for (toks.items[open + 1 .. close], open + 1..) |tok, i| {
        if (depth == 0 and punctEq(tok, sig, '=')) in_default = true;
        depth += parameterBracketDelta(tok, sig, lang, !in_default);
        if (depth == 0 and punctEq(tok, sig, ',')) {
            try appendParameter(b, sym, toks.items, sig, segment, i);
            segment = i + 1;
            in_default = false;
        }
    }
    try appendParameter(b, sym, toks.items, sig, segment, close);
}

fn appendParameter(b: *Builder, sym: model.Symbol, toks: []const Token, src: []const u8, lo: usize, hi: usize) !void {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    const lang = b.idx.graph.files[sym.file].language;
    const name_i = parameterToken(toks, src, lo, hi, lang) orelse return;
    const name = toks[name_i].text(src);
    const offset = sym.span_start + toks[name_i].start;
    const line = tokenLine(b, sym, toks[name_i]);
    std.debug.assert(b.param_counts[sym.id] <= std.math.maxInt(u16));
    const index: u16 = @intCast(b.param_counts[sym.id]);
    _ = try appendNode(b, .parameter, sym.id, name, line, offset, index);
    b.param_counts[sym.id] += 1;
}

fn parameterToken(toks: []const Token, src: []const u8, lo: usize, hi: usize, lang: language.Language) ?usize {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var first: ?usize = null;
    var last: ?usize = null;
    var has_colon = false;
    for (toks[lo..hi], lo..) |tok, i| {
        if (punctEq(tok, src, '=')) break;
        if (punctEq(tok, src, ':')) has_colon = true;
        if (tok.kind != .identifier or parameterKeyword(tok.text(src))) continue;
        if (first == null) first = i;
        last = i;
    }
    const name_first = has_colon or lang == .go or lang == .zig or lang.family() == .python or lang.family() == .js or lang.family() == .rust;
    return if (name_first) first else last;
}

fn scanOwner(b: *Builder, sym: model.Symbol) !void {
    std.debug.assert(isCallable(sym.kind));
    std.debug.assert(sym.span_start <= sym.sig_end and sym.sig_end <= sym.span_end);
    const body = sym.body(b.idx.graph.files[sym.file].text);
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(b.gpa);
    try lexer.tokenize(b.gpa, body, language.configFor(b.idx.graph.files[sym.file].language), &toks);
    const body_from = sym.sig_end - sym.span_start;
    try scanAssignments(b, sym, toks.items, body, body_from);
    try scanCalls(b, sym, toks.items, body, body_from);
    try scanReturns(b, sym, toks.items, body, body_from);
}

fn scanAssignments(b: *Builder, sym: model.Symbol, toks: []const Token, src: []const u8, body_from: u32) !void {
    std.debug.assert(sym.span_start <= sym.sig_end);
    std.debug.assert(body_from <= src.len);
    for (toks, 0..) |tok, i| {
        if (tok.start < body_from or !assignmentEq(toks, src, i)) continue;
        const lhs_i = lhsIdentifier(toks, src, i) orelse continue;
        const abs = sym.span_start + toks[lhs_i].start;
        if (!belongsToOwner(b, sym, abs)) continue;
        const end = expressionEnd(toks, src, i + 1);
        const name = toks[lhs_i].text(src);
        const line = tokenLine(b, sym, toks[lhs_i]);
        const lhs = try appendVariableDefinition(b, sym.id, name, line, abs);
        if (compoundAssignment(toks, src, i)) try appendPreviousValue(b, sym, name, abs, line, lhs);
        try appendDependencies(b, sym, toks, src, i + 1, end, lhs, .assignment, .exact);
        try appendCallResults(b, sym, toks, src, i + 1, end, lhs, .exact);
    }
}

fn scanReturns(b: *Builder, sym: model.Symbol, toks: []const Token, src: []const u8, body_from: u32) !void {
    std.debug.assert(sym.id < b.idx.graph.symbols.len);
    std.debug.assert(body_from <= src.len);
    const return_node = returnNode(b, sym.id) orelse unreachable;
    for (toks, 0..) |tok, i| {
        if (tok.start < body_from or !tokenEq(tok, src, "return")) continue;
        const abs = sym.span_start + tok.start;
        if (!belongsToOwner(b, sym, abs)) continue;
        const end = expressionEnd(toks, src, i + 1);
        if (i + 1 >= toks.len or (toks[i + 1].line > tok.line and !punctEq(toks[i + 1], src, '('))) continue;
        try appendDependencies(b, sym, toks, src, i + 1, end, return_node, .return_value, .exact);
        try appendCallResults(b, sym, toks, src, i + 1, end, return_node, .exact);
    }
}

fn scanCalls(b: *Builder, sym: model.Symbol, toks: []const Token, src: []const u8, body_from: u32) !void {
    std.debug.assert(sym.id < b.idx.graph.symbols.len);
    std.debug.assert(body_from <= src.len);
    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        if (toks[i].start < body_from or toks[i].kind != .identifier) continue;
        const call = callAt(toks, src, i) orelse continue;
        const abs = sym.span_start + toks[call.name_i].start;
        if (!belongsToOwner(b, sym, abs)) continue;
        const sink_end = selectorEndAt(b.sink, toks, src, i);
        if (sink_end != null and sink_end.? == call.name_i and b.sink.fileMatches(b.idx.graph.files[sym.file].path)) {
            const sink_offset = sym.span_start + toks[call.name_i].start;
            const sink_node = try nodeFor(b, .sink, sym.id, b.sink.name, tokenLine(b, sym, toks[call.name_i]), sink_offset, 0);
            try appendArgumentsToNode(b, sym, toks, src, call.open, call.close, sink_node, .sink_argument);
        }
        if (resolvedCall(b.idx, sym, toks, src, call.name_i)) |target| {
            const confidence: Confidence = if (callReferenceExact(b.idx, sym, toks, src, call.name_i)) .exact else .heuristic;
            try appendArgumentsToParams(b, sym, target, toks, src, call.open, call.close, confidence);
        }
        i = call.name_i;
    }
}

const Call = struct { name_i: usize, open: usize, close: usize };

fn callAt(toks: []const Token, src: []const u8, start: usize) ?Call {
    std.debug.assert(start < toks.len);
    std.debug.assert(toks[start].kind == .identifier);
    var name_i = start;
    var cursor = start + 1;
    while (cursor < toks.len) {
        cursor = skipCallGeneric(toks, src, cursor) orelse return null;
        if (cursor + 1 < toks.len and punctEq(toks[cursor], src, '.') and toks[cursor + 1].kind == .identifier) {
            name_i = cursor + 1;
            cursor += 2;
            continue;
        }
        if (cursor + 2 < toks.len and punctEq(toks[cursor], src, ':') and punctEq(toks[cursor + 1], src, ':') and toks[cursor + 2].kind == .identifier) {
            name_i = cursor + 2;
            cursor += 3;
            continue;
        }
        break;
    }
    cursor = skipCallGeneric(toks, src, cursor) orelse return null;
    if (cursor >= toks.len or !punctEq(toks[cursor], src, '(')) return null;
    const close = matchingClose(toks, src, cursor, '(', ')') orelse return null;
    return .{ .name_i = name_i, .open = cursor, .close = close };
}

fn skipCallGeneric(toks: []const Token, src: []const u8, from: usize) ?usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(src.len == 0 or toks.len > 0);
    var open = from;
    if (open + 2 < toks.len and punctEq(toks[open], src, ':') and punctEq(toks[open + 1], src, ':') and punctEq(toks[open + 2], src, '<')) open += 2;
    if (open >= toks.len or !punctEq(toks[open], src, '<')) return from;
    const close = matchingClose(toks, src, open, '<', '>') orelse return null;
    return close + 1;
}

fn appendArgumentsToNode(b: *Builder, sym: model.Symbol, toks: []const Token, src: []const u8, open: usize, close: usize, target: u32, kind: EdgeKind) !void {
    std.debug.assert(open < close);
    std.debug.assert(close < toks.len);
    var start = open + 1;
    var depth: i32 = 0;
    for (toks[open + 1 .. close], open + 1..) |tok, i| {
        depth += bracketDelta(tok, src);
        if (depth == 0 and punctEq(tok, src, ',')) {
            const value_start = argumentValueStart(toks, src, start, i);
            try appendDependencies(b, sym, toks, src, value_start, i, target, kind, .exact);
            try appendCallResults(b, sym, toks, src, value_start, i, target, .exact);
            start = i + 1;
        }
    }
    const value_start = argumentValueStart(toks, src, start, close);
    try appendDependencies(b, sym, toks, src, value_start, close, target, kind, .exact);
    try appendCallResults(b, sym, toks, src, value_start, close, target, .exact);
}

fn appendArgumentsToParams(b: *Builder, caller: model.Symbol, callee: SymbolId, toks: []const Token, src: []const u8, open: usize, close: usize, confidence: Confidence) !void {
    std.debug.assert(callee < b.idx.graph.symbols.len);
    std.debug.assert(open < close);
    var arg_index: u16 = 0;
    var start = open + 1;
    var depth: i32 = 0;
    for (toks[open + 1 .. close], open + 1..) |tok, i| {
        depth += bracketDelta(tok, src);
        if (depth == 0 and punctEq(tok, src, ',')) {
            try appendArgumentToParam(b, caller, callee, arg_index, toks, src, start, i, confidence);
            arg_index +|= 1;
            start = i + 1;
        }
    }
    try appendArgumentToParam(b, caller, callee, arg_index, toks, src, start, close, confidence);
}

fn appendArgumentToParam(b: *Builder, caller: model.Symbol, callee: SymbolId, arg_index: u16, toks: []const Token, src: []const u8, lo: usize, hi: usize, confidence: Confidence) !void {
    std.debug.assert(lo <= hi);
    std.debug.assert(callee < b.idx.graph.symbols.len);
    const offset: u16 = if (hasReceiverParam(b, callee)) 1 else 0;
    if (lo >= hi) return;
    const value_lo = argumentValueStart(toks, src, lo, hi);
    if (value_lo >= hi) return;
    const param = if (argumentLabel(toks, src, lo, hi)) |label|
        findParamNodeByName(b, callee, label)
    else
        findParamNode(b, callee, arg_index +| offset);
    const target = param orelse return;
    try appendDependencies(b, caller, toks, src, value_lo, hi, target, .argument, confidence);
    try appendCallResults(b, caller, toks, src, value_lo, hi, target, confidence);
}

fn appendDependencies(b: *Builder, sym: model.Symbol, toks: []const Token, src: []const u8, lo: usize, hi: usize, target: u32, kind: EdgeKind, direct_confidence: Confidence) !void {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var i = lo;
    while (i < hi) : (i += 1) {
        const tok = toks[i];
        if (tok.kind != .identifier) continue;
        const abs = sym.span_start + tok.start;
        if (!belongsToOwner(b, sym, abs)) continue;
        const nested = insideNestedCall(toks, src, lo, i, hi);
        if (!nested and selectorMatchesAt(b.source, toks, src, i) and b.source.fileMatches(b.idx.graph.files[sym.file].path)) {
            const line = tokenLine(b, sym, tok);
            const source_node = try nodeFor(b, .source, sym.id, b.source.name, line, abs, 0);
            try appendEdge(b, source_node, target, kindForSource(kind), sym.file, line, direct_confidence);
            continue;
        }
        if (nested or valueKeyword(tok.text(src)) or memberToken(toks, src, i, lo, hi)) continue;
        const line = tokenLine(b, sym, tok);
        const value = try valueNodeForUse(b, sym, tok.text(src), line, abs, target);
        const confidence = worstConfidence(.inferred, direct_confidence);
        try appendEdge(b, value, target, kind, sym.file, line, confidence);
    }
}

fn appendCallResults(b: *Builder, sym: model.Symbol, toks: []const Token, src: []const u8, lo: usize, hi: usize, target: u32, context_confidence: Confidence) !void {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    var i = lo;
    while (i < hi) : (i += 1) {
        if (toks[i].kind != .identifier) continue;
        const call = callAt(toks, src, i) orelse continue;
        if (call.close > hi) continue;
        const callee = resolvedCall(b.idx, sym, toks, src, call.name_i) orelse continue;
        const return_node = returnNode(b, callee) orelse continue;
        const call_confidence: Confidence = if (callReferenceExact(b.idx, sym, toks, src, call.name_i)) .exact else .heuristic;
        const confidence = worstConfidence(context_confidence, call_confidence);
        const line = tokenLine(b, sym, toks[call.name_i]);
        try appendEdge(b, return_node, target, .call_result, sym.file, line, confidence);
        i = call.close;
    }
}

fn callReference(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, name_i: usize) ?model.Reference {
    std.debug.assert(name_i < toks.len);
    std.debug.assert(sym.id < idx.graph.symbols.len);
    const abs = sym.span_start + toks[name_i].start;
    for (sym.refs) |ref| {
        if ((ref.kind != .call and ref.kind != .read) or ref.target == invalid or !std.mem.eql(u8, ref.name, toks[name_i].text(src))) continue;
        if (ref.offsets.len == 0 and ref.line == absoluteLine(idx.graph.files[sym.file].text, abs)) return ref;
        if (std.mem.indexOfScalar(u32, ref.offsets, abs) != null) return ref;
    }
    return null;
}

fn callReferenceExact(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, name_i: usize) bool {
    return if (callReference(idx, sym, toks, src, name_i)) |ref| ref.exact else false;
}

fn resolvedCall(idx: *const Index, sym: model.Symbol, toks: []const Token, src: []const u8, name_i: usize) ?SymbolId {
    const ref = callReference(idx, sym, toks, src, name_i) orelse return null;
    std.debug.assert(ref.target != invalid);
    if (ref.target >= idx.graph.symbols.len or !isCallable(idx.graph.symbols[ref.target].kind)) return null;
    return ref.target;
}

fn appendNode(b: *Builder, kind: NodeKind, owner: SymbolId, name: []const u8, line: u32, offset: u32, param_index: u16) !u32 {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(name.len > 0);
    const id: u32 = @intCast(b.nodes.items.len);
    try b.nodes.append(b.gpa, .{ .kind = kind, .owner = owner, .name = name, .line = line, .offset = offset, .param_index = param_index });
    return id;
}

fn nodeFor(b: *Builder, kind: NodeKind, owner: SymbolId, name: []const u8, line: u32, offset: u32, param_index: u16) !u32 {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(name.len > 0);
    if (findNode(b, kind, owner, name, param_index, offset)) |id| return id;
    return appendNode(b, kind, owner, name, line, offset, param_index);
}

fn valueNodeForUse(b: *Builder, sym: model.Symbol, name: []const u8, line: u32, offset: u32, target: u32) !u32 {
    std.debug.assert(sym.id < b.idx.graph.symbols.len);
    std.debug.assert(name.len > 0);
    if (latestVariableBefore(b, sym.id, name, offset, target)) |id| return id;
    if (findParamNodeByName(b, sym.id, name)) |id| return id;
    return nodeFor(b, .variable, sym.id, name, line, offset, 0);
}

fn latestVariableBefore(b: *const Builder, owner: SymbolId, name: []const u8, offset: u32, target: u32) ?u32 {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(target < b.nodes.items.len);
    var i = b.nodes.items.len;
    while (i > 0) {
        i -= 1;
        const node = b.nodes.items[i];
        if (i == target or node.kind != .variable or node.owner != owner or !std.mem.eql(u8, node.name, name)) continue;
        if (node.offset <= offset and node.offset <= b.nodes.items[target].offset) return @intCast(i);
    }
    return null;
}

fn appendPreviousValue(b: *Builder, sym: model.Symbol, name: []const u8, offset: u32, line: u32, target: u32) !void {
    std.debug.assert(sym.id < b.idx.graph.symbols.len);
    std.debug.assert(target < b.nodes.items.len);
    const previous = latestVariableBefore(b, sym.id, name, offset, target) orelse
        findParamNodeByName(b, sym.id, name) orelse return;
    try appendEdge(b, previous, target, .assignment, sym.file, line, .inferred);
}

fn appendVariableDefinition(b: *Builder, owner: SymbolId, name: []const u8, line: u32, offset: u32) !u32 {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(name.len > 0);
    if (findNode(b, .variable, owner, name, 0, offset)) |id| {
        if (b.nodes.items[id].offset == offset) return id;
    }
    return appendNode(b, .variable, owner, name, line, offset, 0);
}

fn findNode(b: *const Builder, kind: NodeKind, owner: SymbolId, name: []const u8, param_index: u16, offset: u32) ?u32 {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(name.len > 0);
    if (kind == .parameter) return findParamNode(b, owner, param_index);
    var i = b.nodes.items.len;
    while (i > 0) {
        i -= 1;
        const node = b.nodes.items[i];
        if (node.kind != kind or node.owner != owner or !std.mem.eql(u8, node.name, name)) continue;
        if ((kind == .source or kind == .sink or kind == .variable) and node.offset != offset) continue;
        return @intCast(i);
    }
    return null;
}

fn returnNode(b: *const Builder, owner: SymbolId) ?u32 {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(b.return_nodes.len == b.idx.graph.symbols.len);
    const id = b.return_nodes[owner];
    return if (id == invalid) null else id;
}

fn findParamNode(b: *const Builder, owner: SymbolId, index: u16) ?u32 {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(b.param_starts.len == b.param_counts.len);
    if (index >= b.param_counts[owner]) return null;
    const id = b.param_starts[owner] + index;
    std.debug.assert(id < b.nodes.items.len and b.nodes.items[id].kind == .parameter);
    return id;
}

fn findParamNodeByName(b: *const Builder, owner: SymbolId, name: []const u8) ?u32 {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(name.len > 0);
    const start = b.param_starts[owner];
    const end = start + b.param_counts[owner];
    for (b.nodes.items[start..end], start..) |node, i| {
        if (std.mem.eql(u8, node.name, name)) return @intCast(i);
    }
    return null;
}

fn hasReceiverParam(b: *const Builder, owner: SymbolId) bool {
    std.debug.assert(owner < b.idx.graph.symbols.len);
    std.debug.assert(isCallable(b.idx.graph.symbols[owner].kind));
    if (b.idx.graph.symbols[owner].kind != .method) return false;
    const first = findParamNode(b, owner, 0) orelse return false;
    const name = b.nodes.items[first].name;
    return std.mem.eql(u8, name, "self") or std.mem.eql(u8, name, "this") or std.mem.eql(u8, name, "cls");
}

fn appendEdge(b: *Builder, from: u32, to: u32, kind: EdgeKind, file: model.FileId, line: u32, confidence: Confidence) !void {
    std.debug.assert(from < b.nodes.items.len and to < b.nodes.items.len);
    std.debug.assert(file < b.idx.graph.files.len);
    if (from == to) return;
    try b.edges.append(b.gpa, .{ .from = from, .to = to, .kind = kind, .file = file, .line = line, .confidence = confidence });
}

fn confidenceRank(confidence: Confidence) u2 {
    return switch (confidence) {
        .exact => 0,
        .inferred => 1,
        .heuristic => 2,
    };
}

fn worstConfidence(a: Confidence, b: Confidence) Confidence {
    return if (confidenceRank(a) >= confidenceRank(b)) a else b;
}

fn selectorMatchesAt(selector: Selector, toks: []const Token, src: []const u8, start: usize) bool {
    return selectorEndAt(selector, toks, src, start) != null;
}

fn selectorEndAt(selector: Selector, toks: []const Token, src: []const u8, start: usize) ?usize {
    std.debug.assert(selector.name.len > 0);
    std.debug.assert(start < toks.len);
    var name_pos: usize = 0;
    var token_pos = start;
    while (name_pos < selector.name.len) {
        const delimiter = nextSelectorDelimiter(selector.name, name_pos);
        const part_end = if (delimiter) |item| item.at else selector.name.len;
        const part = selector.name[name_pos..part_end];
        if (part.len == 0 or token_pos >= toks.len or toks[token_pos].kind != .identifier or !segmentMatch(part, toks[token_pos].text(src))) return null;
        if (delimiter == null) return token_pos;
        token_pos = consumeSourceDelimiter(toks, src, token_pos + 1, delimiter.?.len) orelse return null;
        name_pos = part_end + delimiter.?.len;
    }
    return null;
}

const SelectorDelimiter = struct { at: usize, len: usize };

fn validSelectorName(name: []const u8) bool {
    if (name.len == 0) return false;
    var start: usize = 0;
    while (start < name.len) {
        const delimiter = nextSelectorDelimiter(name, start);
        const end = if (delimiter) |item| item.at else name.len;
        const part = name[start..end];
        if (!validSelectorPart(part)) return false;
        if (delimiter == null) return true;
        start = end + delimiter.?.len;
    }
    return false;
}

fn validSelectorPart(part: []const u8) bool {
    if (std.mem.eql(u8, part, "*")) return true;
    if (part.len == 0 or !selectorIdentStart(part[0])) return false;
    for (part[1..]) |c| if (!selectorIdentContinue(c)) return false;
    return true;
}

fn selectorIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

fn selectorIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

fn nextSelectorDelimiter(name: []const u8, from: usize) ?SelectorDelimiter {
    std.debug.assert(from <= name.len);
    std.debug.assert(name.len > 0);
    var i = from;
    while (i < name.len) : (i += 1) {
        if (name[i] == '.') return .{ .at = i, .len = 1 };
        if (name[i] == ':' and i + 1 < name.len and name[i + 1] == ':') return .{ .at = i, .len = 2 };
    }
    return null;
}

fn consumeSourceDelimiter(toks: []const Token, src: []const u8, from: usize, len: usize) ?usize {
    std.debug.assert(len == 1 or len == 2);
    std.debug.assert(from <= toks.len);
    if (from >= toks.len) return null;
    if (len == 1) return if (punctEq(toks[from], src, '.')) from + 1 else null;
    if (from + 1 >= toks.len or !punctEq(toks[from], src, ':') or !punctEq(toks[from + 1], src, ':')) return null;
    return from + 2;
}

fn segmentMatch(pattern: []const u8, text: []const u8) bool {
    std.debug.assert(pattern.len > 0);
    std.debug.assert(text.len > 0);
    if (std.mem.eql(u8, pattern, "*")) return true;
    return std.mem.eql(u8, pattern, text);
}

fn belongsToOwner(b: *const Builder, owner: model.Symbol, offset: u32) bool {
    std.debug.assert(owner.file < b.idx.graph.files.len);
    std.debug.assert(offset <= b.idx.graph.files[owner.file].text.len);
    const range = b.callable_ranges[owner.file];
    var lo: usize = range.start;
    var hi: usize = range.end;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const sym = b.idx.graph.symbols[b.callable_ids[mid]];
        if (sym.span_start <= offset) lo = mid + 1 else hi = mid;
    }
    var cursor = lo;
    while (cursor > range.start) {
        cursor -= 1;
        const sym = b.idx.graph.symbols[b.callable_ids[cursor]];
        if (offset >= sym.span_end) continue;
        return sym.id == owner.id;
    }
    return false;
}

fn buildCallableIndex(gpa: std.mem.Allocator, idx: *const Index) !CallableIndex {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var count: usize = 0;
    for (idx.graph.symbols) |sym| count += @intFromBool(isCallable(sym.kind));
    const ids = try gpa.alloc(SymbolId, count);
    errdefer gpa.free(ids);
    const ranges = try gpa.alloc(CallableRange, idx.graph.files.len);
    errdefer gpa.free(ranges);
    var cursor: usize = 0;
    for (idx.graph.files) |file| {
        const start = cursor;
        for (idx.graph.symbols[file.sym_start..file.sym_end]) |sym| {
            if (!isCallable(sym.kind)) continue;
            ids[cursor] = sym.id;
            cursor += 1;
        }
        std.mem.sort(SymbolId, ids[start..cursor], idx, callableLessThan);
        ranges[file.id] = .{ .start = @intCast(start), .end = @intCast(cursor) };
    }
    std.debug.assert(cursor == count);
    return .{ .ids = ids, .ranges = ranges };
}

fn callableLessThan(idx: *const Index, a: SymbolId, b: SymbolId) bool {
    std.debug.assert(a < idx.graph.symbols.len);
    std.debug.assert(b < idx.graph.symbols.len);
    const lhs = idx.graph.symbols[a];
    const rhs = idx.graph.symbols[b];
    if (lhs.span_start != rhs.span_start) return lhs.span_start < rhs.span_start;
    if (lhs.span_end != rhs.span_end) return lhs.span_end > rhs.span_end;
    return a < b;
}

fn argumentLabel(toks: []const Token, src: []const u8, lo: usize, hi: usize) ?[]const u8 {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    if (lo + 1 >= hi or toks[lo].kind != .identifier) return null;
    if (!punctEq(toks[lo + 1], src, '=') and !punctEq(toks[lo + 1], src, ':')) return null;
    return toks[lo].text(src);
}

fn argumentValueStart(toks: []const Token, src: []const u8, lo: usize, hi: usize) usize {
    std.debug.assert(lo <= hi);
    std.debug.assert(hi <= toks.len);
    if (lo + 1 < hi and toks[lo].kind == .identifier and (punctEq(toks[lo + 1], src, '=') or punctEq(toks[lo + 1], src, ':'))) return lo + 2;
    return lo;
}

fn insideNestedCall(toks: []const Token, src: []const u8, lo: usize, at: usize, hi: usize) bool {
    std.debug.assert(lo <= at);
    std.debug.assert(at < hi);
    std.debug.assert(hi <= toks.len);
    var i = lo;
    while (i < at) : (i += 1) {
        if (toks[i].kind != .identifier) continue;
        const call = callAt(toks, src, i) orelse continue;
        if (call.open < at and at < call.close and call.close <= hi) return true;
        i = call.name_i;
    }
    return false;
}

fn memberToken(toks: []const Token, src: []const u8, i: usize, lo: usize, hi: usize) bool {
    std.debug.assert(lo <= i and i < hi);
    std.debug.assert(hi <= toks.len);
    if (i > lo and (punctEq(toks[i - 1], src, '.') or punctEq(toks[i - 1], src, ':'))) return true;
    return i + 1 < hi and (punctEq(toks[i + 1], src, '.') or punctEq(toks[i + 1], src, ':'));
}

fn expressionEnd(toks: []const Token, src: []const u8, from: usize) usize {
    std.debug.assert(from <= toks.len);
    std.debug.assert(src.len <= std.math.maxInt(u32));
    if (from >= toks.len) return from;
    const line = toks[from].line;
    var depth: i32 = 0;
    var i = from;
    while (i < toks.len) : (i += 1) {
        if (depth == 0 and (punctEq(toks[i], src, ';') or (toks[i].line > line and lineStart(toks, i)))) return i;
        depth += bracketDelta(toks[i], src);
    }
    return toks.len;
}

fn lhsIdentifier(toks: []const Token, src: []const u8, eq: usize) ?usize {
    std.debug.assert(eq < toks.len);
    std.debug.assert(eq > 0);
    var start = eq;
    while (start > 0 and toks[start - 1].line == toks[eq].line) start -= 1;
    var colon: ?usize = null;
    for (toks[start..eq], start..) |tok, i| {
        if (punctEq(tok, src, ':')) colon = i;
    }
    const hi = colon orelse eq;
    var result: ?usize = null;
    for (toks[start..hi], start..) |tok, i| {
        if (tok.kind == .identifier) result = i;
    }
    return result;
}

fn assignmentEq(toks: []const Token, src: []const u8, i: usize) bool {
    if (i == 0 or i + 1 >= toks.len or !punctEq(toks[i], src, '=')) return false;
    if (punctEq(toks[i + 1], src, '>')) return false;
    if (punctEq(toks[i - 1], src, '=') or punctEq(toks[i + 1], src, '=') or punctEq(toks[i - 1], src, '!')) return false;
    if (punctEq(toks[i - 1], src, '<') or punctEq(toks[i - 1], src, '>')) {
        if (i < 2 or !std.mem.eql(u8, toks[i - 2].text(src), toks[i - 1].text(src))) return false;
    }
    if (insideDelimitedContext(toks, src, i)) return false;
    return true;
}

fn compoundAssignment(toks: []const Token, src: []const u8, eq: usize) bool {
    std.debug.assert(eq > 0 and eq < toks.len);
    std.debug.assert(punctEq(toks[eq], src, '='));
    const previous = toks[eq - 1];
    if (previous.kind != .punct or previous.end != previous.start + 1) return false;
    return switch (src[previous.start]) {
        '+', '-', '*', '/', '%', '&', '|', '^', '?' => true,
        '<', '>' => eq >= 2 and std.mem.eql(u8, toks[eq - 2].text(src), previous.text(src)),
        else => false,
    };
}

fn insideDelimitedContext(toks: []const Token, src: []const u8, at: usize) bool {
    std.debug.assert(at < toks.len);
    std.debug.assert(at > 0);
    var depth: i32 = 0;
    for (toks[0..at]) |tok| depth += assignmentContextDelta(tok, src);
    return depth > 0;
}

fn assignmentContextDelta(tok: Token, src: []const u8) i32 {
    if (tok.kind != .punct or tok.end != tok.start + 1) return 0;
    return switch (src[tok.start]) {
        '(', '[' => 1,
        ')', ']' => -1,
        else => 0,
    };
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

fn bracketDelta(tok: Token, src: []const u8) i32 {
    if (tok.kind != .punct or tok.end != tok.start + 1) return 0;
    return switch (src[tok.start]) {
        '(', '[', '{' => 1,
        ')', ']', '}' => -1,
        else => 0,
    };
}

fn parameterBracketDelta(tok: Token, src: []const u8, lang: language.Language, allow_angle: bool) i32 {
    if (tok.kind != .punct or tok.end != tok.start + 1) return 0;
    if (allow_angle and languageUsesAngleGenerics(lang)) {
        if (src[tok.start] == '<') return 1;
        if (src[tok.start] == '>') return -1;
    }
    return bracketDelta(tok, src);
}

fn languageUsesAngleGenerics(lang: language.Language) bool {
    return switch (lang) {
        .cpp, .csharp, .javascript, .typescript, .tsx, .rust => true,
        else => false,
    };
}

fn fillSpanLines(idx: *const Index, lines: []u32) void {
    std.debug.assert(lines.len == idx.graph.symbols.len);
    std.debug.assert(idx.graph.files.len > 0 or lines.len == 0);
    for (idx.graph.files) |file| {
        var cursor: u32 = 0;
        var line: u32 = 1;
        var id = file.sym_start;
        while (id < file.sym_end) : (id += 1) {
            const target = idx.graph.symbols[id].span_start;
            if (target < cursor) {
                lines[id] = absoluteLine(file.text, target);
                continue;
            }
            for (file.text[cursor..target]) |c| if (c == '\n') {
                line += 1;
            };
            lines[id] = line;
            cursor = target;
        }
    }
}

fn tokenLine(b: *const Builder, sym: model.Symbol, tok: Token) u32 {
    std.debug.assert(sym.id < b.span_lines.len);
    std.debug.assert(tok.line > 0);
    return b.span_lines[sym.id] +| tok.line - 1;
}

fn absoluteLine(source: []const u8, offset: u32) u32 {
    std.debug.assert(offset <= source.len);
    std.debug.assert(source.len <= std.math.maxInt(u32));
    var line: u32 = 1;
    for (source[0..offset]) |c| if (c == '\n') {
        line += 1;
    };
    return line;
}

fn lineStart(toks: []const Token, i: usize) bool {
    return i == 0 or toks[i - 1].line != toks[i].line;
}

fn tokenEq(tok: Token, src: []const u8, text: []const u8) bool {
    return tok.kind == .identifier and std.mem.eql(u8, tok.text(src), text);
}

fn punctEq(tok: Token, src: []const u8, c: u8) bool {
    return tok.kind == .punct and tok.end == tok.start + 1 and src[tok.start] == c;
}

fn kindForSource(kind: EdgeKind) EdgeKind {
    return if (kind == .sink_argument) .sink_argument else .source_value;
}

fn parameterKeyword(name: []const u8) bool {
    inline for (.{ "fn", "def", "function", "async", "const", "var", "let", "mut", "pub", "static", "int", "str", "string", "bool", "void" }) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

fn valueKeyword(name: []const u8) bool {
    inline for (.{ "return", "if", "else", "for", "while", "new", "await", "async", "const", "var", "let", "true", "false", "null", "None", "self", "this" }) |word| {
        if (std.mem.eql(u8, name, word)) return true;
    }
    return false;
}

fn isCallable(kind: model.SymbolKind) bool {
    return switch (kind) {
        .function, .method, .test_case, .macro => true,
        else => false,
    };
}

test "taint graph does not bypass a constant-returning wrapper" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\def clean(value):
        \\    return "fixed"
        \\def run(request):
        \\    subprocess.run(clean(request.json))
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx, Selector.parse("request.json").?, Selector.parse("subprocess.run").?);
    defer graph.deinit();
    for (graph.edges) |edge| {
        try testing.expect(!(graph.nodes[edge.from].kind == .source and graph.nodes[edge.to].kind == .sink));
    }
}

test "taint graph propagates a call result into a sink" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\def get(request):
        \\    return request.json
        \\def run(request):
        \\    subprocess.run(get(request))
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx, Selector.parse("request.json").?, Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var return_to_sink = false;
    for (graph.edges) |edge| {
        if (graph.nodes[edge.from].kind == .return_value and graph.nodes[edge.to].kind == .sink) return_to_sink = true;
    }
    try testing.expect(return_to_sink);
}

test "taint graph ignores later writes when reading an earlier binding" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\def run(request):
        \\    subprocess.run(command)
        \\    command = request.json
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx, Selector.parse("request.json").?, Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var assigned: ?u32 = null;
    var consumed: ?u32 = null;
    for (graph.edges) |edge| {
        if (graph.nodes[edge.from].kind == .source) assigned = edge.to;
        if (graph.nodes[edge.to].kind == .sink) consumed = edge.from;
    }
    try testing.expect(assigned != null and consumed != null);
    try testing.expect(assigned.? != consumed.?);
}

test "taint selector preserves namespace separators and rejects invalid forms" {
    const testing = std.testing;
    try testing.expectEqualStrings("std::system", Selector.parse("std::system").?.name);
    try testing.expectEqualStrings("src/app.rs", Selector.parse("std::system@src/app.rs").?.path);
    try testing.expect(Selector.parse("request.json@") == null);
    try testing.expect(Selector.parse("request..json") == null);
    try testing.expect(Selector.parse("std:system") == null);
    try testing.expect(Selector.parse("read:request.json#0") == null);
    try testing.expect(Selector.parse("sub*process.run") == null);
    try testing.expect(Selector.parse("sink()") == null);
    try testing.expect(Selector.parse("items[0]") == null);
}

test "taint call parser accepts namespace and generic syntax" {
    const testing = std.testing;
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(testing.allocator);
    const rust = "std::process::Command::<String>::new::<String>(value)";
    try lexer.tokenize(testing.allocator, rust, language.configFor(.rust), &toks);
    const rust_call = callAt(toks.items, rust, 0).?;
    try testing.expectEqualStrings("new", toks.items[rust_call.name_i].text(rust));
    try testing.expect(punctEq(toks.items[rust_call.open], rust, '('));

    toks.clearRetainingCapacity();
    const cpp = "dangerous<std::string>(value)";
    try lexer.tokenize(testing.allocator, cpp, language.configFor(.cpp), &toks);
    const cpp_call = callAt(toks.items, cpp, 0).?;
    try testing.expectEqualStrings("dangerous", toks.items[cpp_call.name_i].text(cpp));
    try testing.expect(punctEq(toks.items[cpp_call.close], cpp, ')'));
}

test "taint graph handles route pseudo-symbol ordering" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "routes.py", .data =
        \\@app.get("/run")
        \\def run(request):
        \\    subprocess.run(request.json)
        \\def later():
        \\    pass
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx, Selector.parse("request.json").?, Selector.parse("subprocess.run").?);
    defer graph.deinit();
    const run_id = idx.lookup("run")[0];
    try testing.expectEqual(@as(usize, 1), graph.sourceCount());
    try testing.expectEqual(@as(usize, 1), graph.sinkCount());
    for (graph.nodes) |node| {
        if (node.kind == .source or node.kind == .sink) try testing.expectEqual(run_id, node.owner);
    }
}

test "taint graph keeps assignments inside brace-language bodies" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.ts", .data =
        \\function run(request) {
        \\  const command = request.json;
        \\  subprocess.run(command);
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx, Selector.parse("request.json").?, Selector.parse("subprocess.run").?);
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 1), graph.sourceCount());
    try testing.expectEqual(@as(usize, 1), graph.sinkCount());
    var variable_to_sink = false;
    for (graph.edges) |edge| {
        if (graph.nodes[edge.from].kind == .variable and graph.nodes[edge.to].kind == .sink) variable_to_sink = true;
    }
    try testing.expect(variable_to_sink);
}

test "taint graph links a direct source through a local assignment to a sink" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\def run(request):
        \\    command = request.json["command"]
        \\    subprocess.run(command)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx, Selector.parse("request.json").?, Selector.parse("subprocess.run").?);
    defer graph.deinit();
    try testing.expectEqual(@as(usize, 1), graph.sourceCount());
    try testing.expectEqual(@as(usize, 1), graph.sinkCount());
    var source_to_var = false;
    var var_to_sink = false;
    for (graph.edges) |edge| {
        if (graph.nodes[edge.from].kind == .source and graph.nodes[edge.to].kind == .variable) source_to_var = true;
        if (graph.nodes[edge.from].kind == .variable and graph.nodes[edge.to].kind == .sink) var_to_sink = true;
    }
    try testing.expect(source_to_var);
    try testing.expect(var_to_sink);
}

test "taint graph maps a caller argument to a callee parameter" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\def execute(command):
        \\    subprocess.run(command)
        \\def route(request):
        \\    execute(request.json)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx, Selector.parse("request.json").?, Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var source_to_param = false;
    for (graph.edges) |edge| {
        if (graph.nodes[edge.from].kind == .source and graph.nodes[edge.to].kind == .parameter) source_to_param = true;
    }
    try testing.expect(source_to_param);
}

test "taint graph downgrades nested call results in heuristic receiver calls" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.ts", .data =
        \\class Service {
        \\  consume(value) { subprocess.run(value); }
        \\}
        \\function produce(request) { return request.json; }
        \\function route(request, svc) { svc.consume(produce(request)); }
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx, Selector.parse("request.json").?, Selector.parse("subprocess.run").?);
    defer graph.deinit();
    const produce = idx.lookup("produce")[0];
    const consume = idx.lookup("consume")[0];
    var nested_edge: ?Edge = null;
    for (graph.edges) |edge| {
        const from = graph.nodes[edge.from];
        const to = graph.nodes[edge.to];
        if (from.kind == .return_value and from.owner == produce and to.kind == .parameter and to.owner == consume) nested_edge = edge;
    }
    try testing.expect(nested_edge != null);
    try testing.expectEqual(Confidence.heuristic, nested_edge.?.confidence);
}
