//! `navgraph graph` — emit a self-contained, interactive HTML visualization of
//! the code graph: every callable/type is a node, every resolved call/type edge
//! is a link. The renderer (a small force-directed layout on a canvas) and the
//! graph data are inlined into a single HTML file with **no external
//! dependencies**, so the output opens offline in any browser.
//!
//! With `-j`/`--json` the same node/edge model is emitted as raw JSON instead of
//! the HTML shell, so other tools can consume the graph.

const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");
const query = @import("query.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const SymbolId = model.SymbolId;
const invalid = model.invalid_symbol;

/// The HTML/CSS/JS shell, split at a data marker so we can splice the graph
/// JSON in without a template engine. Everything is inlined — no CDN, no fetch.
const template = @embedFile("viz.html");
const marker = "/*__NAVGRAPH_DATA__*/";
const head = blk: {
    const i = std.mem.indexOf(u8, template, marker) orelse
        @compileError("src/viz.html is missing the '" ++ marker ++ "' data marker");
    break :blk template[0..i];
};
const tail = blk: {
    const i = std.mem.indexOf(u8, template, marker).?;
    break :blk template[i + marker.len ..];
};

/// A directed edge between two compact node indices.
const Edge = struct { s: u32, t: u32, exact: bool };

/// Sentinel node index meaning "this symbol is not a graph node".
const none = std.math.maxInt(u32);

/// Kinds that become nodes: callables, containers, tests and routes — the things
/// that participate in the call/type graph. Imports, fields, bare values and
/// unknowns are dropped so the view isn't drowned in isolated dots.
fn isNodeKind(kind: model.SymbolKind) bool {
    return switch (kind) {
        .function, .method, .class, .@"struct", .@"enum", .interface, .type, .macro, .route, .test_case => true,
        .variable, .constant, .field, .module, .import, .route_mount, .unknown => false,
    };
}

/// Apply the unified `--tests` scope to a symbol's test-ness (mirrors the
/// private `query.inTestScope`).
fn inScope(scope: query.TestScope, is_test: bool) bool {
    return switch (scope) {
        .with => true,
        .without => !is_test,
        .only => is_test,
    };
}

/// How much of the node set `-l` withheld. `total` counts every node the
/// filters selected, whether or not the cap let it through.
pub const Truncation = struct {
    shown: usize,
    total: usize,

    pub fn any(self: Truncation) bool {
        std.debug.assert(self.shown <= self.total);
        return self.shown < self.total;
    }
};

/// Build the node/edge model and render it as an interactive HTML page (or, with
/// `--json`, as the raw graph JSON). `path_filter` scopes to a subtree; the
/// `--tests` scope selects whether test symbols are included. Returns what `-l`
/// withheld so the caller can say so — a silently smaller graph reads as the
/// whole graph.
pub fn graph(w: *Writer, idx: *const Index, path_filter: []const u8, opts: query.Options) !Truncation {
    const gpa = idx.gpa;
    const syms = idx.graph.symbols;

    // Map each SymbolId to a compact node index (`none` if it isn't a node).
    const node_of = try gpa.alloc(u32, syms.len);
    defer gpa.free(node_of);
    @memset(node_of, none);

    // Pass 1 — select nodes (kind + path filter + test scope).
    var node_ids: std.ArrayList(SymbolId) = .empty;
    defer node_ids.deinit(gpa);
    var in_scope: usize = 0;
    for (syms) |sym| {
        if (!isNodeKind(sym.kind)) continue;
        const file = idx.graph.files[sym.file];
        if (!query.matchesFilter(file.path, path_filter)) continue;
        if (!inScope(opts.tests, query.isTestSymbol(idx, sym))) continue;
        in_scope += 1;
        // `-l` caps the node set (edges then span only surviving nodes). Only
        // when the user asked: an unset limit still renders the whole graph.
        // Keep counting past the cap so the total can be reported.
        if (query.listCap(opts)) |cap| if (node_ids.items.len >= cap) continue;
        node_of[sym.id] = @intCast(node_ids.items.len);
        try node_ids.append(gpa, sym.id);
    }

    const n = node_ids.items.len;
    const fan_in = try gpa.alloc(u32, n);
    defer gpa.free(fan_in);
    @memset(fan_in, 0);
    const fan_out = try gpa.alloc(u32, n);
    defer gpa.free(fan_out);
    @memset(fan_out, 0);

    // Pass 2 — collect edges between selected nodes (deduped, no self-loops).
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);
    var seen = std.AutoHashMap(u64, void).init(gpa);
    defer seen.deinit();
    for (node_ids.items, 0..) |sid, ni| {
        const sym = syms[sid];
        for (sym.refs) |ref| {
            if (ref.target == invalid) continue;
            switch (ref.kind) {
                .call, .type_use, .route_call => {},
                .read, .import => continue,
            }
            const tn = node_of[ref.target];
            if (tn == none or tn == ni) continue;
            const key = (@as(u64, @intCast(ni)) << 32) | tn;
            if ((try seen.getOrPut(key)).found_existing) continue;
            try edges.append(gpa, .{ .s = @intCast(ni), .t = tn, .exact = ref.exact });
            fan_in[tn] += 1;
            fan_out[ni] += 1;
        }
    }

    const truncation: Truncation = .{ .shown = n, .total = in_scope };
    if (opts.format != .json) try w.writeAll(head);
    try emitJson(w, idx, node_ids.items, edges.items, fan_in, fan_out, truncation);
    if (opts.format != .json) try w.writeAll(tail);
    return truncation;
}

/// Emit the graph model as compact JSON:
/// `{root, files[], nodes[], edges[], nodes_total, truncated}`.
/// Node fields are short keys to keep the payload small: `n`ame, `k`ind, `f`ile,
/// `l`ine, `e`xported, `t`est, fan-`in`, fan-`out`. `nodes_total`/`truncated`
/// tell a client that `-l` withheld nodes, so a capped subgraph is never read
/// as the whole graph.
fn emitJson(
    w: *Writer,
    idx: *const Index,
    node_ids: []const SymbolId,
    edges: []const Edge,
    fan_in: []const u32,
    fan_out: []const u32,
    truncation: Truncation,
) !void {
    const syms = idx.graph.symbols;

    try w.writeAll("{\"root\":");
    try jsonString(w, idx.root);

    try w.writeAll(",\"files\":[");
    for (idx.graph.files, 0..) |f, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try jsonString(w, f.path);
        try w.print(",\"lang\":\"{s}\"}}", .{f.language.tag()});
    }

    try w.writeAll("],\"nodes\":[");
    for (node_ids, 0..) |sid, ni| {
        const sym = syms[sid];
        if (ni != 0) try w.writeByte(',');
        try w.writeAll("{\"n\":");
        try jsonString(w, sym.name);
        try w.print(",\"k\":\"{s}\",\"f\":{d},\"l\":{d},\"e\":{d},\"t\":{d},\"in\":{d},\"out\":{d}}}", .{
            sym.kind.tag(),
            sym.file,
            sym.line,
            @as(u8, if (sym.exported) 1 else 0),
            @as(u8, if (query.isTestSymbol(idx, sym)) 1 else 0),
            fan_in[ni],
            fan_out[ni],
        });
    }

    try w.writeAll("],\"edges\":[");
    for (edges, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"s\":{d},\"t\":{d},\"x\":{d}}}", .{ e.s, e.t, @as(u8, if (e.exact) 1 else 0) });
    }

    try w.print("],\"nodes_total\":{d},\"truncated\":{}}}", .{ truncation.total, truncation.any() });
}

/// Write `s` as a JSON string literal. Besides the standard escapes, `<` is
/// escaped so a symbol name can never terminate the surrounding `<script>` tag.
fn jsonString(w: *Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '<' => try w.writeAll("\\u003c"),
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a non-cached index rooted at `tmp`'s scratch directory.
fn vzBuild(tmp: *std.testing.TmpDir) !Index {
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    return index_mod.build(testing.allocator, testing.io, root, false);
}

fn vzRender(idx: *Index, filter: []const u8, opts: query.Options) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    _ = try graph(&aw.writer, idx, filter, opts);
    // Return an exact-sized owned copy so the caller can free it directly (the
    // Allocating writer's buffer capacity may exceed its written length).
    return testing.allocator.dupe(u8, aw.written());
}

test "graph emits a self-contained HTML page carrying the node/edge model" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "u.zig", .data =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\pub fn run() i32 {
        \\    return add(1, 2);
        \\}
    });

    var idx = try vzBuild(&tmp);
    defer idx.deinit();

    const out = try vzRender(&idx, "", .{});
    defer testing.allocator.free(out);

    // The HTML shell and the spliced data are both present, offline (no http).
    try testing.expect(std.mem.indexOf(u8, out, "<!doctype html>") != null or
        std.mem.indexOf(u8, out, "<!DOCTYPE html>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<canvas") != null);
    try testing.expect(std.mem.indexOf(u8, out, "http://") == null);
    try testing.expect(std.mem.indexOf(u8, out, "https://") == null);
    // The two functions are nodes and the call edge is present.
    try testing.expect(std.mem.indexOf(u8, out, "\"n\":\"add\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"n\":\"run\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"edges\":[") != null);
    // No leftover splice marker.
    try testing.expect(std.mem.indexOf(u8, out, marker) == null);
}

test "graph --json emits the raw model without the HTML shell" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "u.zig", .data =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\pub fn run() i32 {
        \\    return add(1, 2);
        \\}
    });

    var idx = try vzBuild(&tmp);
    defer idx.deinit();

    const out = try vzRender(&idx, "", .{ .format = .json });
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(u8, '{'), out[0]);
    try testing.expectEqual(@as(u8, '}'), out[out.len - 1]);
    try testing.expect(std.mem.indexOf(u8, out, "<canvas") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"nodes\":[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"n\":\"add\"") != null);
    // run -> add is exactly one edge.
    try testing.expect(std.mem.indexOf(u8, out, "\"edges\":[{") != null);
}

test "graph --no-tests drops test nodes; --tests-only keeps only them" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "u.zig", .data =
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
        \\test "add works" {
        \\    _ = add(1, 2);
        \\}
    });

    var idx = try vzBuild(&tmp);
    defer idx.deinit();

    const prod = try vzRender(&idx, "", .{ .format = .json, .tests = .without });
    defer testing.allocator.free(prod);
    try testing.expect(std.mem.indexOf(u8, prod, "\"n\":\"add\"") != null);
    try testing.expect(std.mem.indexOf(u8, prod, "\"k\":\"test\"") == null);

    const only = try vzRender(&idx, "", .{ .format = .json, .tests = .only });
    defer testing.allocator.free(only);
    try testing.expect(std.mem.indexOf(u8, only, "\"n\":\"add\"") == null);
    try testing.expect(std.mem.indexOf(u8, only, "\"k\":\"test\"") != null);
}

test "graph -l caps the node set but reports the total and the truncation" {
    // Regression (F3): `-l N` silently returned a smaller subgraph with no
    // marker and no warning, so a client's standard `-l 200` read as the graph.
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "u.zig", .data =
        \\pub fn a() void {}
        \\pub fn b() void {}
        \\pub fn c() void {}
        \\pub fn d() void {}
    });

    var idx = try vzBuild(&tmp);
    defer idx.deinit();

    const full = try vzRender(&idx, "", .{ .format = .json });
    defer testing.allocator.free(full);
    try testing.expect(std.mem.indexOf(u8, full, "\"nodes_total\":4") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"truncated\":false") != null);

    const capped = try vzRender(&idx, "", .{ .format = .json, .limit = 2, .limit_set = true });
    defer testing.allocator.free(capped);
    // Two of four nodes emitted, and the payload says so.
    try testing.expect(std.mem.indexOf(u8, capped, "\"n\":\"a\"") != null);
    try testing.expect(std.mem.indexOf(u8, capped, "\"n\":\"d\"") == null);
    try testing.expect(std.mem.indexOf(u8, capped, "\"nodes_total\":4") != null);
    try testing.expect(std.mem.indexOf(u8, capped, "\"truncated\":true") != null);
}

test "graph escapes a name that could break out of the script tag" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A JS class whose name embeds a '<' — must be escaped to < in output.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.js", .data =
        \\class Box { m() { return 1; } }
    });

    var idx = try vzBuild(&tmp);
    defer idx.deinit();

    const out = try vzRender(&idx, "", .{ .format = .json });
    defer testing.allocator.free(out);
    // Sanity: a raw "</script" sequence never appears in the payload.
    try testing.expect(std.mem.indexOf(u8, out, "</script") == null);
}
