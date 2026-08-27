//! Derived protocol/interface implementation relationships.
//!
//! These edges are intentionally separate from the indexed call graph: callers,
//! hotness, coverage and unused-code analysis must not count inferred structural
//! conformance unless a query explicitly asks for implementation traversal.

const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");

const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

pub const Relation = struct {
    port: SymbolId,
    implementation: SymbolId,
    exact: bool,
};

pub const Edge = struct {
    port_method: SymbolId,
    implementation_method: SymbolId,
    exact: bool,
};

pub const Graph = struct {
    gpa: std.mem.Allocator,
    relations: []Relation,
    edges: []Edge,

    pub fn deinit(self: *Graph) void {
        self.gpa.free(self.relations);
        self.gpa.free(self.edges);
        self.* = undefined;
    }

    pub fn relation(self: *const Graph, port: SymbolId, implementation: SymbolId) ?Relation {
        for (self.relations) |rel| {
            if (rel.port == port and rel.implementation == implementation) return rel;
        }
        return null;
    }
};

pub fn build(gpa: std.mem.Allocator, idx: *const Index) !Graph {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(SymbolId));
    var relations: std.ArrayList(Relation) = .empty;
    defer relations.deinit(gpa);
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);

    for (idx.graph.symbols) |port| {
        if (!isPort(idx, port)) continue;
        for (idx.graph.symbols) |candidate| {
            if (!isContainer(candidate) or candidate.id == port.id) continue;
            if (idx.graph.files[candidate.file].language.family() != idx.graph.files[port.file].language.family()) continue;
            const nominal = namesBase(idx, candidate, port.name);
            if (!nominal and !coversMethods(idx, port.id, candidate.id)) continue;
            const exact = nominal and uniqueContainerName(idx, port.name);
            try relations.append(gpa, .{ .port = port.id, .implementation = candidate.id, .exact = exact });
            try appendSharedEdges(gpa, idx, &edges, port.id, candidate.id, exact);
        }
    }
    return .{
        .gpa = gpa,
        .relations = try relations.toOwnedSlice(gpa),
        .edges = try edges.toOwnedSlice(gpa),
    };
}

pub fn isContainer(sym: model.Symbol) bool {
    return switch (sym.kind) {
        // `enum` is a first-class, trait-implementing / method-bearing type in
        // Rust (and carries methods in Zig/C#), so it participates in the
        // hierarchy / conformance / implementation graphs like other containers.
        .class, .@"struct", .interface, .@"enum" => true,
        else => false,
    };
}

pub fn isPort(idx: *const Index, sym: model.Symbol) bool {
    if (!isContainer(sym)) return false;
    if (sym.kind == .interface) return true;
    const source = idx.graph.files[sym.file].text;
    const sig = sym.signature(source);
    if (containsIdentifier(sig, "Protocol") or containsIdentifier(sig, "ABC")) return true;

    var method_count: usize = 0;
    var stub_count: usize = 0;
    for (idx.graph.symbols) |child| {
        if (child.parent != sym.id or child.kind != .method) continue;
        method_count += 1;
        if (child.modifiers.abstract or isStubMethod(idx, child)) stub_count += 1;
    }
    return method_count > 0 and stub_count == method_count;
}

pub fn methodOf(idx: *const Index, parent: SymbolId, name: []const u8) ?SymbolId {
    std.debug.assert(parent < idx.graph.symbols.len);
    std.debug.assert(name.len > 0);
    if (directMethodOf(idx, parent, name)) |direct| return direct;

    // A nominal implementation inherits concrete default methods from its
    // protocol. Surface that effective method instead of reporting a false
    // MISSING cell for Rust `impl Trait for Type` (and keep structural matches,
    // which have no nominal metadata, unchanged). Ambiguous defaults abstain.
    var inherited: ?SymbolId = null;
    for (idx.graph.symbols) |impl_method| {
        if (impl_method.parent != parent or impl_method.impl_protocol.len == 0) continue;
        for (idx.lookup(impl_method.impl_protocol)) |port_id| {
            if (!isPort(idx, idx.graph.symbols[port_id])) continue;
            for (idx.lookup(name)) |method_id| {
                const default = idx.graph.symbols[method_id];
                if (default.parent != port_id or default.kind != .method or isStubMethod(idx, default)) continue;
                if (inherited != null and inherited.? != method_id) return null;
                inherited = method_id;
            }
        }
    }
    return inherited;
}

/// A method physically declared under `parent`, excluding inherited protocol
/// defaults. Structural conformance uses this cheaper/stricter lookup so a
/// missing member does not trigger a whole-graph nominal scan for every class.
fn directMethodOf(idx: *const Index, parent: SymbolId, name: []const u8) ?SymbolId {
    for (idx.lookup(name)) |id| {
        const sym = idx.graph.symbols[id];
        if (sym.parent == parent and sym.kind == .method) return id;
    }
    return null;
}

pub fn methodCount(idx: *const Index, parent: SymbolId) usize {
    std.debug.assert(parent < idx.graph.symbols.len);
    var count: usize = 0;
    for (idx.graph.symbols) |sym| {
        if (sym.parent == parent and sym.kind == .method) count += 1;
    }
    return count;
}

fn coversMethods(idx: *const Index, port: SymbolId, candidate: SymbolId) bool {
    var required: usize = 0;
    for (idx.graph.symbols) |method| {
        if (method.parent != port or method.kind != .method) continue;
        required += 1;
        if (directMethodOf(idx, candidate, method.name) == null) return false;
    }
    return required > 0;
}

fn appendSharedEdges(
    gpa: std.mem.Allocator,
    idx: *const Index,
    edges: *std.ArrayList(Edge),
    port: SymbolId,
    implementation: SymbolId,
    exact: bool,
) !void {
    std.debug.assert(port != implementation);
    std.debug.assert(isContainer(idx.graph.symbols[port]) and isContainer(idx.graph.symbols[implementation]));
    for (idx.graph.symbols) |method| {
        if (method.parent != port or method.kind != .method) continue;
        const target = methodOf(idx, implementation, method.name) orelse continue;
        if (target == method.id) continue; // inherited protocol default, not an override edge
        try edges.append(gpa, .{ .port_method = method.id, .implementation_method = target, .exact = exact });
    }
}

fn namesBase(idx: *const Index, candidate: model.Symbol, port_name: []const u8) bool {
    // Rust declares nominal conformance out of line (`impl Trait for Type`), so
    // the implemented type's own signature cannot name the trait. The parser
    // retains that declaration on each attached impl method; one is sufficient
    // to prove the candidate names this port.
    for (idx.graph.symbols) |method| {
        if (method.parent != candidate.id or method.kind != .method) continue;
        if (std.mem.eql(u8, method.impl_protocol, port_name)) return true;
    }
    const sig = candidate.signature(idx.graph.files[candidate.file].text);
    const own = std.mem.indexOf(u8, sig, candidate.name) orelse return false;
    return containsIdentifier(sig[own + candidate.name.len ..], port_name);
}

fn uniqueContainerName(idx: *const Index, name: []const u8) bool {
    var count: usize = 0;
    for (idx.lookup(name)) |id| {
        if (!isContainer(idx.graph.symbols[id])) continue;
        count += 1;
        if (count > 1) return false;
    }
    return count == 1;
}

fn containsIdentifier(text: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, name)) |at| {
        const before_ok = at == 0 or !isIdentByte(text[at - 1]);
        const end = at + name.len;
        const after_ok = end == text.len or !isIdentByte(text[end]);
        if (before_ok and after_ok) return true;
        start = at + 1;
    }
    return false;
}

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isStubMethod(idx: *const Index, sym: model.Symbol) bool {
    const source = idx.graph.files[sym.file].text;
    if (sym.sig_end >= sym.span_end) return true;
    var body = std.mem.trim(u8, source[sym.sig_end..sym.span_end], " \t\r\n:{};");
    if (std.mem.eql(u8, body, "pass") or std.mem.eql(u8, body, "...")) return true;
    if (std.mem.startsWith(u8, body, "raise NotImplementedError")) return true;
    // Declaration-only interface methods often end in punctuation after the
    // parser's signature boundary.
    body = std.mem.trim(u8, body, " \t\r\n;");
    return body.len == 0;
}

test "build discovers structural and nominal protocol implementations" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ports.py", .data =
        \\from typing import Protocol
        \\class Store(Protocol):
        \\    def get(self, key: str) -> str: ...
        \\    def put(self, key: str, value: str) -> None: ...
        \\class MemoryStore:
        \\    def get(self, key: str) -> str: return key
        \\    def put(self, key: str, value: str) -> None: pass
        \\class Partial(Store):
        \\    def get(self, key: str) -> str: return key
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();

    const port = idx.lookup("Store")[0];
    const memory = idx.lookup("MemoryStore")[0];
    const partial = idx.lookup("Partial")[0];
    try testing.expect(graph.relation(port, memory) != null);
    try testing.expect(!graph.relation(port, memory).?.exact);
    try testing.expect(graph.relation(port, partial) != null);
    try testing.expect(graph.relation(port, partial).?.exact);
    try testing.expectEqual(@as(usize, 3), graph.edges.len);
}

test "checked-in Rust cross-file impl is an exact nominal conformance" {
    const testing = std.testing;
    var idx = try index_mod.build(testing.allocator, testing.io, "testenv/rust_cli", false, .auto);
    defer idx.deinit();
    var graph = try build(testing.allocator, &idx);
    defer graph.deinit();

    const port = idx.lookup("Evaluate")[0];
    const implementation = idx.lookup("Expr")[0];
    const relation = graph.relation(port, implementation).?;
    try testing.expect(relation.exact);
    try testing.expectEqual(idx.graph.symbols[implementation].id, implementation);
    try testing.expect(methodOf(&idx, implementation, "evaluate") != null);
    const inherited_default = methodOf(&idx, implementation, "evaluate_number").?;
    try testing.expectEqual(port, idx.graph.symbols[inherited_default].parent);
}
