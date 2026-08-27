const std = @import("std");
const index_mod = @import("index.zig");
const query = @import("query.zig");
const json_out = @import("json_out.zig");
const graph_mod = @import("taint_graph.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const invalid_node = std.math.maxInt(u32);
const invalid_state = std.math.maxInt(usize);
const confidence_count = 3;

const Candidate = struct {
    sink: u32,
    state: usize,
    confidence: graph_mod.Confidence,
    distance: u32,
};

const Search = struct {
    gpa: std.mem.Allocator,
    prev_state: []usize,
    prev_edge: []u32,
    distance: []u32,

    fn init(gpa: std.mem.Allocator, node_count: usize) !Search {
        std.debug.assert(node_count <= std.math.maxInt(u32));
        std.debug.assert(confidence_count == @typeInfo(graph_mod.Confidence).@"enum".fields.len);
        if (node_count > std.math.maxInt(usize) / confidence_count or
            node_count > std.math.maxInt(u32) / confidence_count) return error.GraphTooLarge;
        const state_count = node_count * confidence_count;
        const prev_state = try gpa.alloc(usize, state_count);
        errdefer gpa.free(prev_state);
        const prev_edge = try gpa.alloc(u32, state_count);
        errdefer gpa.free(prev_edge);
        const distance = try gpa.alloc(u32, state_count);
        @memset(prev_state, invalid_state);
        @memset(prev_edge, invalid_node);
        @memset(distance, invalid_node);
        return .{ .gpa = gpa, .prev_state = prev_state, .prev_edge = prev_edge, .distance = distance };
    }

    fn deinit(self: *Search) void {
        std.debug.assert(self.prev_state.len == self.prev_edge.len);
        std.debug.assert(self.prev_state.len == self.distance.len);
        self.gpa.free(self.prev_state);
        self.gpa.free(self.prev_edge);
        self.gpa.free(self.distance);
        self.* = undefined;
    }
};

pub const Path = struct {
    nodes: []u32,
    edges: []u32,
    confidence: graph_mod.Confidence,
};

pub const Trace = struct {
    gpa: std.mem.Allocator,
    paths: []Path,
    reachable_sinks: u32,

    pub fn deinit(self: *Trace) void {
        std.debug.assert(self.paths.len <= self.reachable_sinks);
        std.debug.assert(self.reachable_sinks <= std.math.maxInt(u32));
        for (self.paths) |path| {
            self.gpa.free(path.nodes);
            self.gpa.free(path.edges);
        }
        self.gpa.free(self.paths);
        self.* = undefined;
    }
};

const Adjacency = struct {
    gpa: std.mem.Allocator,
    starts: []u32,
    edge_ids: []u32,

    fn init(gpa: std.mem.Allocator, graph: graph_mod.Graph) !Adjacency {
        std.debug.assert(graph.nodes.len <= std.math.maxInt(u32));
        std.debug.assert(graph.edges.len <= std.math.maxInt(u32));
        const starts = try gpa.alloc(u32, graph.nodes.len + 1);
        errdefer gpa.free(starts);
        @memset(starts, 0);
        for (graph.edges) |edge| {
            std.debug.assert(edge.from < graph.nodes.len and edge.to < graph.nodes.len);
            starts[edge.from + 1] += 1;
        }
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const edge_ids = try gpa.alloc(u32, graph.edges.len);
        errdefer gpa.free(edge_ids);
        const cursors = try gpa.dupe(u32, starts[0..graph.nodes.len]);
        defer gpa.free(cursors);
        for (graph.edges, 0..) |edge, edge_id| {
            edge_ids[cursors[edge.from]] = @intCast(edge_id);
            cursors[edge.from] += 1;
        }
        return .{ .gpa = gpa, .starts = starts, .edge_ids = edge_ids };
    }

    fn deinit(self: *Adjacency) void {
        std.debug.assert(self.starts.len > 0);
        std.debug.assert(self.edge_ids.len <= std.math.maxInt(u32));
        self.gpa.free(self.starts);
        self.gpa.free(self.edge_ids);
        self.* = undefined;
    }
};

pub fn run(w: *Writer, idx: *const Index, source_raw: []const u8, opts: query.Options) !bool {
    std.debug.assert(source_raw.len > 0);
    std.debug.assert(opts.flow_to.len > 0);
    const source = graph_mod.Selector.parse(source_raw) orelse return invalidSelector(w, "source", source_raw, opts);
    const sink = graph_mod.Selector.parse(opts.flow_to) orelse return invalidSelector(w, "sink", opts.flow_to, opts);
    var graph = try graph_mod.build(idx.gpa, idx, source, sink);
    defer graph.deinit();
    var trace = try traceGraph(idx.gpa, graph, opts.strict, opts.limit);
    defer trace.deinit();
    if (opts.format == .json) return renderJson(w, idx, graph, source, sink, trace, opts);
    return renderText(w, idx, graph, source, sink, trace, opts);
}

pub fn traceGraph(gpa: std.mem.Allocator, graph: graph_mod.Graph, strict: bool, limit: u32) !Trace {
    std.debug.assert(limit > 0);
    std.debug.assert(graph.nodes.len <= std.math.maxInt(u32));
    std.debug.assert(graph.edges.len <= std.math.maxInt(u32));
    var search = try Search.init(gpa, graph.nodes.len);
    defer search.deinit();
    var adjacency = try Adjacency.init(gpa, graph);
    defer adjacency.deinit();
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(gpa);
    try initializeSources(gpa, graph, &search, &queue);
    try walkGraph(graph, adjacency, strict, &search, &queue);
    const candidates = try collectCandidates(gpa, graph, search);
    defer gpa.free(candidates);
    std.mem.sort(Candidate, candidates, {}, candidateLessThan);
    var paths: std.ArrayList(Path) = .empty;
    errdefer {
        freePaths(gpa, paths.items);
        paths.deinit(gpa);
    }
    for (candidates[0..@min(candidates.len, limit)]) |candidate| {
        const path = try reconstruct(gpa, graph, search, candidate.state);
        paths.append(gpa, path) catch |err| {
            gpa.free(path.nodes);
            gpa.free(path.edges);
            return err;
        };
    }
    return .{ .gpa = gpa, .paths = try paths.toOwnedSlice(gpa), .reachable_sinks = @intCast(candidates.len) };
}

fn initializeSources(gpa: std.mem.Allocator, graph: graph_mod.Graph, search: *Search, queue: *std.ArrayList(usize)) !void {
    std.debug.assert(search.prev_state.len == graph.nodes.len * confidence_count);
    std.debug.assert(queue.items.len == 0);
    for (graph.nodes, 0..) |node, i| {
        if (node.kind != .source) continue;
        const state = stateId(@intCast(i), .exact);
        search.prev_state[state] = state;
        search.distance[state] = 0;
        try queue.append(gpa, state);
    }
}

fn walkGraph(graph: graph_mod.Graph, adjacency: Adjacency, strict: bool, search: *Search, queue: *std.ArrayList(usize)) !void {
    std.debug.assert(search.prev_state.len == graph.nodes.len * confidence_count);
    std.debug.assert(adjacency.starts.len == graph.nodes.len + 1);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const current_state = queue.items[head];
        const current_node = stateNode(current_state);
        for (adjacency.edge_ids[adjacency.starts[current_node]..adjacency.starts[current_node + 1]]) |edge_id| {
            const edge = graph.edges[edge_id];
            if (strict and edge.confidence != .exact) continue;
            const next_confidence = worstConfidence(stateConfidence(current_state), edge.confidence);
            const next_state = stateId(edge.to, next_confidence);
            const next_distance = search.distance[current_state] +| 1;
            const shorter = next_distance < search.distance[next_state];
            const stable_tie = next_distance == search.distance[next_state] and
                (edge_id < search.prev_edge[next_state] or
                    (edge_id == search.prev_edge[next_state] and current_state < search.prev_state[next_state]));
            if (!shorter and !stable_tie) continue;
            search.distance[next_state] = next_distance;
            search.prev_state[next_state] = current_state;
            search.prev_edge[next_state] = edge_id;
            try queue.append(search.gpa, next_state);
        }
    }
}

fn collectCandidates(gpa: std.mem.Allocator, graph: graph_mod.Graph, search: Search) ![]Candidate {
    std.debug.assert(search.prev_state.len == graph.nodes.len * confidence_count);
    std.debug.assert(graph.nodes.len <= std.math.maxInt(u32));
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(gpa);
    for (graph.nodes, 0..) |node, i| {
        if (node.kind != .sink) continue;
        for ([_]graph_mod.Confidence{ .exact, .inferred, .heuristic }) |confidence| {
            const state = stateId(@intCast(i), confidence);
            if (search.prev_state[state] == invalid_state) continue;
            try candidates.append(gpa, .{ .sink = @intCast(i), .state = state, .confidence = confidence, .distance = search.distance[state] });
            break;
        }
    }
    return candidates.toOwnedSlice(gpa);
}

fn candidateLessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    std.debug.assert(lhs.distance != invalid_node);
    std.debug.assert(rhs.distance != invalid_node);
    if (lhs.confidence != rhs.confidence) return @intFromEnum(lhs.confidence) < @intFromEnum(rhs.confidence);
    if (lhs.distance != rhs.distance) return lhs.distance < rhs.distance;
    return lhs.sink < rhs.sink;
}

fn reconstruct(gpa: std.mem.Allocator, graph: graph_mod.Graph, search: Search, sink_state: usize) !Path {
    std.debug.assert(sink_state < search.prev_state.len);
    std.debug.assert(search.prev_state[sink_state] != invalid_state);
    var reverse_nodes: std.ArrayList(u32) = .empty;
    defer reverse_nodes.deinit(gpa);
    var reverse_edges: std.ArrayList(u32) = .empty;
    defer reverse_edges.deinit(gpa);
    var current_state = sink_state;
    try reverse_nodes.append(gpa, stateNode(current_state));
    while (search.prev_state[current_state] != current_state) {
        const edge_id = search.prev_edge[current_state];
        std.debug.assert(edge_id < graph.edges.len);
        const edge = graph.edges[edge_id];
        current_state = search.prev_state[current_state];
        std.debug.assert(stateNode(current_state) == edge.from);
        try reverse_edges.append(gpa, edge_id);
        try reverse_nodes.append(gpa, edge.from);
    }
    std.debug.assert(graph.nodes[stateNode(current_state)].kind == .source);
    std.mem.reverse(u32, reverse_nodes.items);
    std.mem.reverse(u32, reverse_edges.items);
    const nodes = try reverse_nodes.toOwnedSlice(gpa);
    errdefer gpa.free(nodes);
    const edges = try reverse_edges.toOwnedSlice(gpa);
    return .{ .nodes = nodes, .edges = edges, .confidence = stateConfidence(sink_state) };
}

fn stateId(node: u32, confidence: graph_mod.Confidence) usize {
    std.debug.assert(@intFromEnum(confidence) < confidence_count);
    std.debug.assert(node < std.math.maxInt(u32));
    return @as(usize, node) * confidence_count + @intFromEnum(confidence);
}

fn stateNode(state: usize) u32 {
    std.debug.assert(state != invalid_state);
    std.debug.assert(state / confidence_count <= std.math.maxInt(u32));
    return @intCast(state / confidence_count);
}

fn stateConfidence(state: usize) graph_mod.Confidence {
    std.debug.assert(state != invalid_state);
    std.debug.assert(state % confidence_count < confidence_count);
    return @enumFromInt(state % confidence_count);
}

fn renderText(w: *Writer, idx: *const Index, graph: graph_mod.Graph, source: graph_mod.Selector, sink: graph_mod.Selector, trace: Trace, opts: query.Options) !bool {
    std.debug.assert(source.name.len > 0 and sink.name.len > 0);
    std.debug.assert(opts.limit > 0);
    try w.print("taint {s} → {s}\n", .{ source.raw, sink.raw });
    try w.print("sources: {d}  sinks: {d}  reachable: {d}\n", .{ graph.sourceCount(), graph.sinkCount(), trace.reachable_sinks });
    if (trace.paths.len == 0) {
        try w.writeAll("(no source-to-sink path");
        if (opts.strict) try w.writeAll(" using exact edges");
        try w.writeAll(")\n");
        return false;
    }
    for (trace.paths, 0..) |path, i| {
        if (i != 0) try w.writeByte('\n');
        try pathText(w, idx, graph, path);
    }
    if (trace.reachable_sinks > trace.paths.len) try w.print("… ({d} more findings; raise -l to see them)\n", .{trace.reachable_sinks - trace.paths.len});
    return true;
}

fn pathText(w: *Writer, idx: *const Index, graph: graph_mod.Graph, path: Path) !void {
    std.debug.assert(path.nodes.len == path.edges.len + 1);
    std.debug.assert(path.nodes.len >= 2);
    const first = graph.nodes[path.nodes[0]];
    try nodeText(w, idx, first, "source");
    for (path.edges, 0..) |edge_id, i| {
        const edge = graph.edges[edge_id];
        const node = graph.nodes[path.nodes[i + 1]];
        try w.print("  → {s} [{s}] ", .{ @tagName(edge.kind), edge.confidence.tag() });
        try nodeText(w, idx, node, @tagName(node.kind));
    }
    try w.print("  confidence: {s}\n", .{path.confidence.tag()});
}

fn nodeText(w: *Writer, idx: *const Index, node: graph_mod.Node, label: []const u8) !void {
    std.debug.assert(node.owner < idx.graph.symbols.len);
    std.debug.assert(label.len > 0);
    const owner = idx.graph.symbols[node.owner];
    try w.print("{s} {s}  {s}:{d} in {s}\n", .{ label, node.name, idx.graph.files[owner.file].path, node.line, owner.name });
}

fn renderJson(w: *Writer, idx: *const Index, graph: graph_mod.Graph, source: graph_mod.Selector, sink: graph_mod.Selector, trace: Trace, opts: query.Options) !bool {
    std.debug.assert(opts.format == .json);
    std.debug.assert(opts.limit > 0);
    try w.writeAll("{\"schema\":\"navgraph.taint.v1\",\"strict\":");
    try w.print("{},\"source\":", .{opts.strict});
    try endpointJson(w, idx, graph, source, .source, opts.limit);
    try w.writeAll(",\"sink\":");
    try endpointJson(w, idx, graph, sink, .sink, opts.limit);
    try w.writeAll(",\"findings\":[");
    for (trace.paths, 0..) |path, i| {
        if (i != 0) try w.writeByte(',');
        try pathJson(w, idx, graph, path);
    }
    const endpoint_truncated = graph.sourceCount() > opts.limit or graph.sinkCount() > opts.limit;
    try w.print("],\"counts\":{{\"source_sites\":{d},\"sink_sites\":{d},\"findings\":{d}}},\"analysis_complete\":{},\"truncated\":{}}}\n", .{
        graph.sourceCount(),   graph.sinkCount(),                                             trace.reachable_sinks,
        analysisComplete(idx), endpoint_truncated or trace.reachable_sinks > trace.paths.len,
    });
    return trace.paths.len != 0;
}

fn endpointJson(w: *Writer, idx: *const Index, graph: graph_mod.Graph, selector: graph_mod.Selector, kind: graph_mod.NodeKind, limit: u32) !void {
    std.debug.assert(kind == .source or kind == .sink);
    std.debug.assert(selector.name.len > 0);
    std.debug.assert(limit > 0);
    var count: usize = 0;
    for (graph.nodes) |node| if (node.kind == kind) {
        count += 1;
    };
    try w.writeAll("{\"selector\":");
    try json_out.writeString(w, selector.raw);
    try w.print(",\"match_count\":{d},\"sites\":[", .{count});
    var emitted: u32 = 0;
    for (graph.nodes) |node| {
        if (node.kind != kind or emitted >= limit) continue;
        if (emitted != 0) try w.writeByte(',');
        try nodeJson(w, idx, node);
        emitted += 1;
    }
    try w.print("],\"truncated\":{}}}", .{count > limit});
}

fn pathJson(w: *Writer, idx: *const Index, graph: graph_mod.Graph, path: Path) !void {
    std.debug.assert(path.nodes.len == path.edges.len + 1);
    std.debug.assert(path.nodes.len >= 2);
    try w.writeAll("{\"status\":\"reachable\",\"confidence\":");
    try json_out.writeString(w, path.confidence.tag());
    try w.writeAll(",\"exact\":");
    try w.print("{},\"source_site\":", .{path.confidence == .exact});
    try nodeJson(w, idx, graph.nodes[path.nodes[0]]);
    try w.writeAll(",\"sink_site\":");
    try nodeJson(w, idx, graph.nodes[path.nodes[path.nodes.len - 1]]);
    try w.writeAll(",\"path\":[");
    for (path.edges, 0..) |edge_id, i| {
        if (i != 0) try w.writeByte(',');
        try edgeJson(w, idx, graph, graph.edges[edge_id]);
    }
    try w.writeAll("]}");
}

fn edgeJson(w: *Writer, idx: *const Index, graph: graph_mod.Graph, edge: graph_mod.Edge) !void {
    std.debug.assert(edge.from < graph.nodes.len and edge.to < graph.nodes.len);
    std.debug.assert(edge.file < idx.graph.files.len and edge.line > 0);
    try w.writeAll("{\"kind\":");
    try json_out.writeString(w, @tagName(edge.kind));
    try w.writeAll(",\"from\":");
    try nodeJson(w, idx, graph.nodes[edge.from]);
    try w.writeAll(",\"to\":");
    try nodeJson(w, idx, graph.nodes[edge.to]);
    try w.writeAll(",\"file\":");
    try json_out.writeString(w, idx.graph.files[edge.file].path);
    try w.print(",\"line\":{d},\"confidence\":", .{edge.line});
    try json_out.writeString(w, edge.confidence.tag());
    try w.print(",\"exact\":{}}}", .{edge.confidence == .exact});
}

fn nodeJson(w: *Writer, idx: *const Index, node: graph_mod.Node) !void {
    std.debug.assert(node.owner < idx.graph.symbols.len);
    std.debug.assert(node.name.len > 0);
    const owner = idx.graph.symbols[node.owner];
    try w.writeAll("{\"kind\":");
    try json_out.writeString(w, @tagName(node.kind));
    try w.writeAll(",\"name\":");
    try json_out.writeString(w, node.name);
    try w.writeAll(",\"file\":");
    try json_out.writeString(w, idx.graph.files[owner.file].path);
    try w.print(",\"line\":{d},\"owner\":", .{node.line});
    try json_out.writeString(w, owner.name);
    try w.writeByte('}');
}

fn invalidSelector(w: *Writer, endpoint: []const u8, selector: []const u8, opts: query.Options) !bool {
    std.debug.assert(std.mem.eql(u8, endpoint, "source") or std.mem.eql(u8, endpoint, "sink"));
    std.debug.assert(selector.len > 0);
    if (opts.format == .json) {
        try w.writeAll("{\"schema\":\"navgraph.taint.v1\",\"error\":{\"code\":\"invalid_selector\",\"endpoint\":");
        try json_out.writeString(w, endpoint);
        try w.writeAll(",\"selector\":");
        try json_out.writeString(w, selector);
        try w.writeAll("},\"analysis_complete\":false}\n");
    } else {
        try w.print("(invalid taint {s} selector '{s}')\n", .{ endpoint, selector });
    }
    return false;
}

fn analysisComplete(idx: *const Index) bool {
    std.debug.assert(idx.graph.files.len > 0 or idx.graph.symbols.len == 0);
    std.debug.assert(idx.graph.symbols.len <= std.math.maxInt(u32));
    for (idx.graph.files) |file| if (!file.parse_health.reliable()) return false;
    return true;
}

fn worstConfidence(a: graph_mod.Confidence, b: graph_mod.Confidence) graph_mod.Confidence {
    return @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b)));
}

fn freePaths(gpa: std.mem.Allocator, paths: []Path) void {
    std.debug.assert(paths.len <= std.math.maxInt(u32));
    std.debug.assert(@intFromPtr(gpa.ptr) != 0);
    for (paths) |path| {
        gpa.free(path.nodes);
        gpa.free(path.edges);
    }
}

test "taint trace ranks confidence before distance and truncation" {
    const testing = std.testing;
    const nodes = [_]graph_mod.Node{
        .{ .kind = .source, .owner = 1, .name = "source", .line = 1, .offset = 0 },
        .{ .kind = .variable, .owner = 1, .name = "a", .line = 2, .offset = 1 },
        .{ .kind = .variable, .owner = 1, .name = "b", .line = 3, .offset = 2 },
        .{ .kind = .sink, .owner = 1, .name = "exact_sink", .line = 4, .offset = 3 },
        .{ .kind = .sink, .owner = 1, .name = "heuristic_sink", .line = 5, .offset = 4 },
    };
    const edges = [_]graph_mod.Edge{
        .{ .from = 0, .to = 1, .kind = .assignment, .file = 0, .line = 2, .confidence = .exact },
        .{ .from = 1, .to = 2, .kind = .assignment, .file = 0, .line = 3, .confidence = .exact },
        .{ .from = 2, .to = 3, .kind = .sink_argument, .file = 0, .line = 4, .confidence = .exact },
        .{ .from = 0, .to = 4, .kind = .sink_argument, .file = 0, .line = 5, .confidence = .heuristic },
    };
    const graph = graph_mod.Graph{ .gpa = testing.allocator, .nodes = @constCast(&nodes), .edges = @constCast(&edges) };
    var trace = try traceGraph(testing.allocator, graph, false, 1);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 2), trace.reachable_sinks);
    try testing.expectEqual(@as(usize, 1), trace.paths.len);
    try testing.expectEqual(graph_mod.Confidence.exact, trace.paths[0].confidence);
    try testing.expectEqual(@as(u32, 3), trace.paths[0].nodes[trace.paths[0].nodes.len - 1]);
}

test "taint trace retains confidence states until the sink" {
    const testing = std.testing;
    const nodes = [_]graph_mod.Node{
        .{ .kind = .source, .owner = 1, .name = "source", .line = 1, .offset = 0 },
        .{ .kind = .variable, .owner = 1, .name = "short", .line = 2, .offset = 1 },
        .{ .kind = .variable, .owner = 1, .name = "long_a", .line = 3, .offset = 2 },
        .{ .kind = .variable, .owner = 1, .name = "long_b", .line = 4, .offset = 3 },
        .{ .kind = .variable, .owner = 1, .name = "join", .line = 5, .offset = 4 },
        .{ .kind = .sink, .owner = 1, .name = "sink", .line = 6, .offset = 5 },
    };
    const edges = [_]graph_mod.Edge{
        .{ .from = 0, .to = 1, .kind = .assignment, .file = 0, .line = 2, .confidence = .inferred },
        .{ .from = 1, .to = 4, .kind = .assignment, .file = 0, .line = 5, .confidence = .exact },
        .{ .from = 0, .to = 2, .kind = .assignment, .file = 0, .line = 3, .confidence = .exact },
        .{ .from = 2, .to = 3, .kind = .assignment, .file = 0, .line = 4, .confidence = .exact },
        .{ .from = 3, .to = 4, .kind = .assignment, .file = 0, .line = 5, .confidence = .exact },
        .{ .from = 4, .to = 5, .kind = .sink_argument, .file = 0, .line = 6, .confidence = .heuristic },
    };
    const graph = graph_mod.Graph{ .gpa = testing.allocator, .nodes = @constCast(&nodes), .edges = @constCast(&edges) };
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(usize, 1), trace.paths.len);
    try testing.expectEqual(graph_mod.Confidence.heuristic, trace.paths[0].confidence);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5 }, trace.paths[0].nodes);
}

test "taint trace prefers an equally short exact path" {
    const testing = std.testing;
    var nodes = [_]graph_mod.Node{
        .{ .kind = .source, .owner = 0, .name = "source", .line = 1, .offset = 0 },
        .{ .kind = .variable, .owner = 0, .name = "heuristic", .line = 2, .offset = 1 },
        .{ .kind = .variable, .owner = 0, .name = "exact", .line = 3, .offset = 2 },
        .{ .kind = .sink, .owner = 0, .name = "sink", .line = 4, .offset = 3 },
    };
    var edges = [_]graph_mod.Edge{
        .{ .from = 0, .to = 1, .kind = .assignment, .file = 0, .line = 2, .confidence = .heuristic },
        .{ .from = 1, .to = 3, .kind = .sink_argument, .file = 0, .line = 4, .confidence = .exact },
        .{ .from = 0, .to = 2, .kind = .assignment, .file = 0, .line = 3, .confidence = .exact },
        .{ .from = 2, .to = 3, .kind = .sink_argument, .file = 0, .line = 4, .confidence = .exact },
    };
    const graph = graph_mod.Graph{ .gpa = testing.allocator, .nodes = &nodes, .edges = &edges };
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 1), trace.reachable_sinks);
    try testing.expectEqual(graph_mod.Confidence.exact, trace.paths[0].confidence);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3 }, trace.paths[0].nodes);
}

test "taint trace reaches an inferred local-variable sink and strict excludes it" {
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
    var graph = try graph_mod.build(testing.allocator, &idx, graph_mod.Selector.parse("request.json").?, graph_mod.Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 1), trace.reachable_sinks);
    try testing.expectEqual(graph_mod.Confidence.inferred, trace.paths[0].confidence);
    var strict = try traceGraph(testing.allocator, graph, true, 10);
    defer strict.deinit();
    try testing.expectEqual(@as(u32, 0), strict.reachable_sinks);
}

test "taint trace keeps a direct source-to-sink argument exact" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\def run(request):
        \\    subprocess.run(request.json)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try graph_mod.build(testing.allocator, &idx, graph_mod.Selector.parse("request.json").?, graph_mod.Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var trace = try traceGraph(testing.allocator, graph, true, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 1), trace.reachable_sinks);
    try testing.expectEqual(graph_mod.Confidence.exact, trace.paths[0].confidence);

    var output_bytes: std.ArrayList(u8) = .empty;
    defer output_bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &output_bytes);
    defer output.deinit();
    try testing.expect(try run(&output.writer, &idx, "request.json", .{ .flow_to = "subprocess.run", .format = .json }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"status\":\"reachable\"") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"file\":\"app.py\"") != null);

    var invalid_bytes: std.ArrayList(u8) = .empty;
    defer invalid_bytes.deinit(testing.allocator);
    var invalid_output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &invalid_bytes);
    defer invalid_output.deinit();
    try testing.expect(!try run(&invalid_output.writer, &idx, "request.json@", .{ .flow_to = "subprocess.run", .format = .json }));
    var invalid_json = try std.json.parseFromSlice(std.json.Value, testing.allocator, invalid_output.written(), .{});
    defer invalid_json.deinit();
    try testing.expect(std.mem.indexOf(u8, invalid_output.written(), "invalid_selector") != null);
}

test "taint does not flow a future parameter reassignment backward" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "future.py", .data =
        \\def run(request, command):
        \\    subprocess.run(command)
        \\    command = request.json
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try graph_mod.build(testing.allocator, &idx, graph_mod.Selector.parse("request.json").?, graph_mod.Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(usize, 1), graph.sourceCount());
    try testing.expectEqual(@as(usize, 1), graph.sinkCount());
    try testing.expectEqual(@as(u32, 0), trace.reachable_sinks);
}

test "taint crosses files through named multiline calls" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers.py", .data =
        \\def passthrough(value):
        \\    return value
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.py", .data =
        \\from helpers import passthrough
        \\def run(request):
        \\    command = passthrough(
        \\        value=request.json,
        \\    )
        \\    subprocess.run(
        \\        command,
        \\    )
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try graph_mod.build(testing.allocator, &idx, graph_mod.Selector.parse("request.json").?, graph_mod.Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 1), trace.reachable_sinks);
    try testing.expect(trace.paths[0].nodes.len >= 5);
    try testing.expectEqual(graph_mod.Confidence.inferred, trace.paths[0].confidence);
}

test "taint JSON preserves uncapped finding counts" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "many.py", .data =
        \\def run(request):
        \\    subprocess.run(request.json)
        \\    subprocess.run(request.json)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    var output: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &bytes);
    defer output.deinit();
    try testing.expect(try run(&output.writer, &idx, "request.json", .{ .flow_to = "subprocess.run", .format = .json, .limit = 1 }));
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, output.written(), .{});
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"findings\":2") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "\"truncated\":true") != null);
}

test "taint preserves the prior value through compound assignment" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "compound.py", .data =
        \\def run(request, suffix):
        \\    command = request.json
        \\    command += suffix
        \\    subprocess.run(command)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try graph_mod.build(testing.allocator, &idx, graph_mod.Selector.parse("request.json").?, graph_mod.Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 1), trace.reachable_sinks);
    try testing.expectEqual(graph_mod.Confidence.inferred, trace.paths[0].confidence);
}

test "taint follows a generic call result into a sink" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "generic.ts", .data =
        \\function passthrough<T>(value: T): T { return value; }
        \\function run(request) {
        \\  subprocess.run(passthrough<string>(request.json));
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try graph_mod.build(testing.allocator, &idx, graph_mod.Selector.parse("request.json").?, graph_mod.Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 1), trace.reachable_sinks);
    try testing.expect(trace.paths[0].nodes.len >= 4);
}

test "taint follows a generic receiver call into a sink" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "receiver.ts", .data =
        \\class Consumer {
        \\  consume<T>(value: T) { subprocess.run(value); }
        \\}
        \\function run(request, svc: Consumer) {
        \\  svc.consume<string>(request.json);
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try graph_mod.build(testing.allocator, &idx, graph_mod.Selector.parse("request.json").?, graph_mod.Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 1), trace.reachable_sinks);
    try testing.expect(trace.paths[0].nodes.len >= 3);
}

test "taint maps parameters after comparison defaults" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "defaults.py", .data =
        \\def consume(first = 1 < 2, command = None):
        \\    subprocess.run(command)
        \\def run(request):
        \\    consume(command=request.json)
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();
    var graph = try graph_mod.build(testing.allocator, &idx, graph_mod.Selector.parse("request.json").?, graph_mod.Selector.parse("subprocess.run").?);
    defer graph.deinit();
    var trace = try traceGraph(testing.allocator, graph, false, 10);
    defer trace.deinit();
    try testing.expectEqual(@as(u32, 1), trace.reachable_sinks);
    try testing.expectEqual(@as(usize, 1), graph.sinkCount());
}
