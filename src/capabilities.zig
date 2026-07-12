//! Machine-readable identity and capability contract for NavGraph clients.
//!
//! This is intentionally independent of an indexed workspace. `navgraph
//! capabilities` must remain cheap and usable even when the current directory
//! is not a source tree, because clients use it to decide whether a binary is
//! compatible before exposing tools to a model.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const registry = @import("command_registry.zig");
const language = @import("language.zig");

pub const product_version = "0.0.0";
pub const capability_schema = "navgraph.capabilities.v1";
pub const capability_schema_version: u32 = 1;
pub const agent_protocol_version = "1.0";
pub const mcp_protocol_version = "2024-11-05";
pub const source_fingerprint: u64 = build_options.cache_key;
pub const source_revision: []const u8 = build_options.revision;

const TrustLimitation = struct {
    id: []const u8,
    summary: []const u8,
    mitigation: []const u8,
    languages: []const []const u8 = &.{},
    commands: []const []const u8 = &.{},
};

/// These are capability boundaries a client must be able to surface without
/// scraping prose. Keep them factual and testable; feature-specific bug lists
/// belong in issues rather than becoming a second roadmap here.
const trust_limitations = [_]TrustLimitation{
    .{
        .id = "heuristic_analysis",
        .summary = "Indexing and resolution are static heuristics, not compiler or type-checker acceptance.",
        .mitigation = "Use exact selectors, inspect source, and run the language's real build/test tools before changing code.",
    },
    .{
        .id = "uncertain_edges",
        .summary = "Inferred and heuristic edges can be ambiguous or unresolved.",
        .mitigation = "Use --strict for exact-only traversals and pin ambiguous symbols with Parent.name or name@path.",
        .commands = &.{ "calls", "callers", "neighbors", "path", "flow", "taint", "reaches", "affected" },
    },
    .{
        .id = "approximate_output_budget",
        .summary = "--budget estimates graph-node bytes and is not a hard serialized-output ceiling.",
        .mitigation = "Clients requiring a hard context bound must cap captured bytes and treat truncation explicitly.",
        .commands = &.{ "outline", "search", "calls", "callers", "neighbors", "hot", "reaches", "affected" },
    },
    .{
        .id = "limit_not_uniform_for_walks",
        .summary = "The current -l/--limit contract is not uniformly enforced by every graph walk.",
        .mitigation = "Also set --max-nodes and enforce a client-side byte/result ceiling.",
        .commands = &.{ "calls", "callers", "neighbors" },
    },
    .{
        .id = "source_read_not_paginated",
        .summary = "read accepts explicit ranges, but whole-file reads do not honor result or byte budgets and have no continuation cursor.",
        .mitigation = "Request bounded file:A-B ranges and enforce client-side line/byte caps.",
        .commands = &.{"read"},
    },
    .{
        .id = "java_resolution_incomplete",
        .summary = "Java indexing is supported, but some bare same-class, inherited, and static-import calls can remain unresolved.",
        .mitigation = "Treat missing Java edges as unknown and verify with exact source/build tools.",
        .languages = &.{"java"},
        .commands = &.{ "calls", "callers", "path", "flow" },
    },
    .{
        .id = "serve_snapshot_requires_reload",
        .summary = "Long-lived serve sessions keep an in-memory snapshot and do not automatically observe edits.",
        .mitigation = "Call navgraph.reload or workspace/reload after filesystem changes.",
        .commands = &.{"serve"},
    },
};

pub fn schemaFingerprint() u64 {
    var hasher = std.hash.Wyhash.init(0x4e_41_56_47_52_41_50_48);
    hashToken(&hasher, capability_schema);
    hashToken(&hasher, agent_protocol_version);
    for (&language.supported) |lang| {
        hashToken(&hasher, lang.name);
        hashToken(&hasher, @tagName(lang.language.family()));
        for (lang.extensions) |ext| hashToken(&hasher, ext);
    }
    for (&registry.command_descriptors) |command| {
        hashToken(&hasher, command.name);
        hashToken(&hasher, @tagName(command.access));
        hashToken(&hasher, if (command.requires_index) "index" else "no-index");
        hashToken(&hasher, if (command.server_available) "server" else "one-shot-only");
        for (command.aliases) |alias| hashToken(&hasher, alias);
        for (command.arguments) |argument| {
            hashToken(&hasher, argument.name);
            hashToken(&hasher, @tagName(argument.kind));
            hashToken(&hasher, if (argument.required) "required" else "optional");
        }
        for (command.options) |option| hashToken(&hasher, @tagName(option));
        for (command.required_options) |option| hashToken(&hasher, @tagName(option));
        for (command.option_value_overrides) |override| {
            hashToken(&hasher, @tagName(override.option));
            for (override.values) |value| hashToken(&hasher, value);
        }
        for (command.outputs) |output| hashToken(&hasher, @tagName(output));
    }
    for (&registry.option_descriptors) |option| {
        hashToken(&hasher, option.name);
        hashToken(&hasher, @tagName(option.value_kind));
        for (option.flags) |flag| hashToken(&hasher, flag);
        for (option.values) |value| hashToken(&hasher, value);
        if (option.minimum) |minimum| {
            var minimum_buf: [16]u8 = undefined;
            hashToken(&hasher, std.fmt.bufPrint(&minimum_buf, "{d}", .{minimum}) catch unreachable);
        }
    }
    for (&trust_limitations) |limitation| {
        hashToken(&hasher, limitation.id);
        hashToken(&hasher, limitation.summary);
        hashToken(&hasher, limitation.mitigation);
        for (limitation.languages) |lang| hashToken(&hasher, lang);
        for (limitation.commands) |command| hashToken(&hasher, command);
    }
    return hasher.final();
}

fn hashToken(hasher: *std.hash.Wyhash, token: []const u8) void {
    hasher.update(token);
    hasher.update(&.{0});
}

/// SemVer-compatible server version including the content-addressed source
/// identity. This is what replaces the old static `phase3` MCP version.
pub fn writeBuildVersion(w: *std.Io.Writer) !void {
    try w.print("{s}+src.{x:0>16}", .{ product_version, source_fingerprint });
}

pub fn writeBuildId(w: *std.Io.Writer) !void {
    try w.print("navgraph@{s}+src.{x:0>16}", .{ product_version, source_fingerprint });
}

pub fn writeManifest(w: *std.Io.Writer) !void {
    try w.writeAll("{\"schema\":");
    try string(w, capability_schema);
    try w.print(",\"schemaVersion\":{},\"agentProtocolVersion\":", .{capability_schema_version});
    try string(w, agent_protocol_version);
    try w.writeAll(",\"build\":{");
    try w.writeAll("\"product\":\"navgraph\",\"version\":");
    try string(w, product_version);
    try w.writeAll(",\"buildVersion\":");
    try quotedBuildVersion(w);
    try w.writeAll(",\"buildId\":");
    try quotedBuildId(w);
    try w.writeAll(",\"revision\":");
    if (source_revision.len == 0) try w.writeAll("null") else try string(w, source_revision);
    try w.print(",\"sourceFingerprint\":\"{x:0>16}\",\"sourceFingerprintAlgorithm\":\"wyhash64(sorted src/**/*.zig paths+contents)\"", .{source_fingerprint});
    try w.writeAll(",\"compiler\":");
    try string(w, builtin.zig_version_string);
    try w.writeAll("},\"schemaHash\":");
    try w.print("\"wyhash64:{x:0>16}\"", .{schemaFingerprint()});

    try w.writeAll(",\"languages\":[");
    for (&language.supported, 0..) |lang, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try string(w, lang.name);
        try w.writeAll(",\"family\":");
        try string(w, @tagName(lang.language.family()));
        try w.writeAll(",\"extensions\":");
        try stringArray(w, lang.extensions);
        try w.writeAll(",\"analysis\":\"heuristic\"}");
    }
    try w.writeByte(']');

    try w.writeAll(",\"commands\":[");
    for (&registry.command_descriptors, 0..) |command, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try string(w, command.name);
        try w.writeAll(",\"aliases\":");
        try stringArray(w, command.aliases);
        try w.writeAll(",\"arguments\":[");
        for (command.arguments, 0..) |argument, arg_i| {
            if (arg_i != 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try string(w, argument.name);
            try w.writeAll(",\"kind\":");
            try string(w, @tagName(argument.kind));
            try w.print(",\"required\":{}}}", .{argument.required});
        }
        try w.writeAll("],\"options\":[");
        for (command.options, 0..) |option, option_i| {
            if (option_i != 0) try w.writeByte(',');
            try string(w, registry.optionDescriptor(option).name);
        }
        try w.writeAll("],\"requiredOptions\":[");
        for (command.required_options, 0..) |option, option_i| {
            if (option_i != 0) try w.writeByte(',');
            try string(w, registry.optionDescriptor(option).name);
        }
        try w.writeAll("],\"optionValueOverrides\":{");
        for (command.option_value_overrides, 0..) |override, override_i| {
            if (override_i != 0) try w.writeByte(',');
            try string(w, registry.optionDescriptor(override.option).name);
            try w.writeByte(':');
            try stringArray(w, override.values);
        }
        try w.writeAll("},\"outputModes\":[");
        for (command.outputs, 0..) |output, output_i| {
            if (output_i != 0) try w.writeByte(',');
            try string(w, @tagName(output));
        }
        try w.writeAll("],\"access\":");
        try string(w, @tagName(command.access));
        try w.print(",\"requiresIndex\":{},\"serverAvailable\":{}}}", .{ command.requires_index, command.server_available });
    }
    try w.writeByte(']');

    try w.writeAll(",\"options\":[");
    for (&registry.option_descriptors, 0..) |option, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try string(w, option.name);
        try w.writeAll(",\"flags\":");
        try stringArray(w, option.flags);
        try w.writeAll(",\"valueKind\":");
        try string(w, @tagName(option.value_kind));
        if (option.values.len != 0) {
            try w.writeAll(",\"values\":");
            try stringArray(w, option.values);
        }
        if (option.minimum) |minimum| try w.print(",\"minimum\":{}", .{minimum});
        try w.writeAll(",\"appliesTo\":[");
        var first = true;
        for (&registry.command_descriptors) |command| {
            if (!registry.hasOption(command.command, option.option)) continue;
            if (!first) try w.writeByte(',');
            try string(w, command.name);
            first = false;
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');

    try w.writeAll(",\"server\":{\"transport\":\"stdio-json-rpc-2.0\",\"mcpProtocolVersion\":");
    try string(w, mcp_protocol_version);
    try w.writeAll(",\"capabilitiesMethod\":\"navgraph/capabilities\",\"capabilitiesTool\":\"navgraph.capabilities\",\"reloadMethod\":\"workspace/reload\",\"reloadTool\":\"navgraph.reload\",\"snapshotRefresh\":\"explicit\"}");

    try w.writeAll(",\"trust\":{\"default\":\"heuristic\",\"strictFlag\":\"--strict\",\"limitations\":[");
    for (&trust_limitations, 0..) |limitation, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try string(w, limitation.id);
        try w.writeAll(",\"summary\":");
        try string(w, limitation.summary);
        try w.writeAll(",\"mitigation\":");
        try string(w, limitation.mitigation);
        if (limitation.languages.len != 0) {
            try w.writeAll(",\"languages\":");
            try stringArray(w, limitation.languages);
        }
        if (limitation.commands.len != 0) {
            try w.writeAll(",\"commands\":");
            try stringArray(w, limitation.commands);
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}}");
}

fn quotedBuildVersion(w: *std.Io.Writer) !void {
    try w.writeByte('"');
    try writeBuildVersion(w);
    try w.writeByte('"');
}

fn quotedBuildId(w: *std.Io.Writer) !void {
    try w.writeByte('"');
    try writeBuildId(w);
    try w.writeByte('"');
}

fn string(w: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, w);
}

fn stringArray(w: *std.Io.Writer, values: []const []const u8) !void {
    try w.writeByte('[');
    for (values, 0..) |value, i| {
        if (i != 0) try w.writeByte(',');
        try string(w, value);
    }
    try w.writeByte(']');
}

fn manifestOwned(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer allocating.deinit();
    try writeManifest(&allocating.writer);
    return allocator.dupe(u8, allocating.written());
}

test "capability manifest is valid, self-identifying JSON" {
    const bytes = try manifestOwned(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const second = try manifestOwned(std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(bytes, second);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(capability_schema, root.get("schema").?.string);
    try std.testing.expectEqual(@as(i64, capability_schema_version), root.get("schemaVersion").?.integer);
    try std.testing.expect(root.get("schemaHash").?.string.len > "wyhash64:".len);
    const build = root.get("build").?.object;
    try std.testing.expectEqualStrings(product_version, build.get("version").?.string);
    try std.testing.expect(std.mem.indexOf(u8, build.get("buildId").?.string, "src.") != null);
    try std.testing.expectEqual(@as(usize, 16), build.get("sourceFingerprint").?.string.len);
    try std.testing.expectEqual(language.supported.len, root.get("languages").?.array.items.len);
    try std.testing.expectEqual(registry.command_descriptors.len, root.get("commands").?.array.items.len);
    try std.testing.expectEqual(registry.option_descriptors.len, root.get("options").?.array.items.len);
}

test "capability manifest advertises Java and exact CLI/MCP contract anchors" {
    const bytes = try manifestOwned(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"name\":\"java\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"extensions\":[\".java\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"name\":\"capabilities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"aliases\":[\"version\",\"--version\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"name\":\"rename\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"access\":\"mutating\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "navgraph/capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "phase3") == null);
}
