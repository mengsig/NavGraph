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
const agent_api = @import("agent_api.zig");

pub const product_version = "0.1.0";
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
        .id = "serve_snapshot_requires_reload",
        .summary = "Long-lived serve sessions keep an in-memory snapshot and do not automatically observe edits.",
        .mitigation = "Call navgraph.reload or workspace/reload after filesystem changes.",
        .commands = &.{"serve"},
    },
    .{
        .id = "route_mount_multiplicity",
        .summary = "Mounted routes currently retain one effective cross-file prefix per target file; multiple router instances or mounts of one file can be incomplete.",
        .mitigation = "Verify multi-router and multi-mount route instances in source before editing clients or handlers.",
        .languages = &.{"python"},
        .commands = &.{"routes"},
    },
};

pub fn schemaFingerprint() u64 {
    var hasher = std.hash.Wyhash.init(0x4e_41_56_47_52_41_50_48);
    hashToken(&hasher, capability_schema);
    hashToken(&hasher, agent_protocol_version);
    hashToken(&hasher, agent_api.tool_name);
    hashToken(&hasher, agent_api.query_schema);
    hashToken(&hasher, agent_api.result_schema);
    hashToken(&hasher, agent_api.input_schema_json);
    hashToken(&hasher, "structuredContent-hard-max-bytes");
    hashToken(&hasher, "serialized-stdout-hard-budget:v1");
    hashToken(&hasher, "path-ambiguity-abstain:v1");
    hashToken(&hasher, "source-selected-line-cursor:v1");
    hashToken(&hasher, "command-language-support:imports-v1");
    hashToken(&hasher, "reference-resolution-status-reason:v1");
    hashToken(&hasher, "edit-site-completeness:v1");
    hashToken(&hasher, "typed-ordinal-cursor:v1");
    hashToken(&hasher, "diagnostics-likely-local:v1");
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

    // A parser entry means NavGraph can index symbols in a language; it does
    // not imply that every higher-level relation is implemented there. Publish
    // the first command-specific matrix explicitly so clients never infer local
    // dependency support merely from the language list.
    try w.writeAll(",\"languageSupport\":{\"baseline\":\"heuristic_symbol_indexing_for_listed_languages\",\"commandOverrides\":[{\"commands\":[\"imports\",\"importers\"],\"supported\":[\"zig\",\"javascript\",\"typescript\",\"tsx\",\"python\",\"lua\",\"ruby\"],\"partial\":[{\"language\":\"rust\",\"detail\":\"local mod declarations; use paths are not resolved\"},{\"language\":\"java\",\"detail\":\"qualified and static local candidates; wildcard imports remain external\"}],\"unsupported\":[\"c\",\"cpp\",\"csharp\",\"go\"]}]}");

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

    try w.writeAll(",\"outputContract\":{\"limit\":{\"scope\":\"semantic_results_for_commands_declaring_limit\",\"hard\":true},\"budget\":{\"scope\":\"serialized_stdout_for_commands_declaring_budget\",\"unit\":\"bytes\",\"minimum\":64,\"hard\":true},\"source\":{\"defaultLines\":300,\"defaultBytes\":65536,\"cursor\":\"v1:selected-line-ordinal\",\"ranges\":\"sorted_merged\"},\"ambiguity\":{\"path\":\"abstain_with_candidates\",\"agentRelations\":\"abstain_with_candidates\"},\"resolution\":{\"statuses\":[\"exact\",\"inferred\",\"heuristic\",\"ambiguous\",\"unresolved\"],\"reason\":\"per_reference_and_relation_edge\"},\"editSites\":{\"listed\":\"exact_editable_only\",\"omitted\":\"counted_as_review_sites_and_warned\"}}");

    try w.writeAll(",\"server\":{\"transport\":\"stdio-json-rpc-2.0\",\"mcpProtocolVersion\":");
    try string(w, mcp_protocol_version);
    try w.writeAll(",\"capabilitiesMethod\":\"navgraph/capabilities\",\"capabilitiesTool\":\"navgraph.capabilities\",\"queryTool\":");
    try string(w, agent_api.tool_name);
    try w.writeAll(",\"querySchema\":");
    try string(w, agent_api.query_schema);
    try w.writeAll(",\"resultSchema\":");
    try string(w, agent_api.result_schema);
    try w.print(",\"agentSchemaHash\":\"wyhash64:{x:0>16}\"", .{agent_api.inputSchemaFingerprint()});
    try w.print(",\"maxBytes\":{{\"scope\":\"structuredContent\",\"default\":{},\"minimum\":{},\"maximum\":{},\"hard\":true}}", .{ agent_api.default_max_bytes, agent_api.min_max_bytes, agent_api.max_max_bytes });
    try w.writeAll(",\"pagination\":{\"cursor\":\"v1:ordinal\",\"next\":\"directly_runnable_query\",\"operations\":[\"map\",\"diagnostics\",\"impact.edit_sites\",\"impact.affected_tests\",\"source\"]}");
    try w.writeAll(",\"legacyTool\":\"navgraph\",\"legacyAccess\":\"read_only\",\"reloadMethod\":\"workspace/reload\",\"reloadTool\":\"navgraph.reload\",\"snapshotRefresh\":\"explicit\"}");

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
    const import_support = root.get("languageSupport").?.object.get("commandOverrides").?.array.items[0].object;
    try std.testing.expectEqualStrings("imports", import_support.get("commands").?.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 4), import_support.get("unsupported").?.array.items.len);
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"queryTool\":\"navgraph.query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"agentSchemaHash\":\"wyhash64:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"legacyAccess\":\"read_only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"scope\":\"structuredContent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "use paths are not resolved") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "route_mount_multiplicity") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "per_reference_and_relation_edge") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "directly_runnable_query") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "phase3") == null);
}
