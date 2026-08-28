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

// Keep the static portions of the machine contract in one place. The writer
// emits these bytes verbatim and schemaFingerprint hashes the same bytes, so a
// contract edit cannot silently retain the old schema hash.
const language_support_json =
    "{\"baseline\":\"heuristic_symbol_indexing_for_listed_languages\",\"commandOverrides\":[{\"commands\":[\"imports\",\"importers\"],\"supported\":[\"zig\",\"javascript\",\"typescript\",\"tsx\",\"python\",\"lua\",\"ruby\"],\"partial\":[{\"language\":\"rust\",\"detail\":\"local mod declarations; use paths are not resolved\"},{\"language\":\"java\",\"detail\":\"qualified and static local candidates; wildcard imports remain external\"}],\"unsupported\":[\"c\",\"cpp\",\"csharp\",\"go\"]}]}";
const output_contract_json =
    "{\"limit\":{\"scope\":\"semantic_results_for_commands_declaring_limit\",\"hard\":true},\"budget\":{\"scope\":\"serialized_stdout_for_commands_declaring_budget\",\"unit\":\"bytes\",\"minimum\":64,\"hard\":true},\"source\":{\"defaultLines\":300,\"defaultBytes\":65536,\"cursor\":\"v1:selected-line-ordinal\",\"ranges\":\"sorted_merged\"},\"ambiguity\":{\"path\":\"abstain_with_candidates\",\"agentRelations\":\"abstain_with_candidates\"},\"resolution\":{\"statuses\":[\"exact\",\"inferred\",\"heuristic\",\"ambiguous\",\"unresolved\"],\"reason\":\"per_reference_and_relation_edge\"},\"editSites\":{\"listed\":\"exact_editable_only\",\"omitted\":\"counted_as_review_sites_and_warned\"}}";
const side_effects_json =
    "{\"workspaceAccess\":{\"read_only\":\"never_modifies_project_sources\",\"metadata\":\"no_workspace_access\",\"mutating\":\"may_modify_project_sources\",\"server\":\"serve_lifecycle\"},\"cache\":{\"path\":\".navgraph/cache\",\"may_read_write\":\"may_read_or_rewrite_cache_during_one_shot_indexing\",\"none\":\"no_per_invocation_cache_io\",\"disableFlag\":\"--no-cache\"},\"server\":{\"queries\":\"no_per_request_cache_io\",\"startupAndReload\":\"may_read_or_rewrite_cache\"}}";
const argv_contract_json =
    "{\"defaultOutput\":\"first_outputModes_entry\",\"formatSpellingRule\":\"a format spelling is accepted only when its fixedValue occurs in the command outputModes\",\"multiValueRule\":\"join option atoms with valueSeparator when published\"}";
const pagination_json =
    "{\"cursor\":\"v1:ordinal\",\"next\":\"directly_runnable_query\",\"operations\":[\"map\",\"diagnostics\",\"impact.edit_sites\",\"impact.affected_tests\",\"source\"]}";

const server_transport = "stdio-json-rpc-2.0";
const capabilities_method = "navgraph/capabilities";
const capabilities_tool = "navgraph.capabilities";
const legacy_tool = "navgraph";
const legacy_access = "read_only";
const reload_method = "workspace/reload";
const reload_tool = "navgraph.reload";
const snapshot_refresh = "explicit";
const max_bytes_scope = "structuredContent";

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
        .id = "git_repository_metadata_trusted",
        .summary = "Git-backed commands use Git's repository discovery and therefore trust .git indirection, repository configuration, and inherited Git environment.",
        .mitigation = "Run Git-backed queries only in trusted worktrees and sanitize Git environment/configuration when repository metadata is untrusted.",
        .commands = &.{ "affected", "diff", "history", "blame", "churn", "serve" },
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
    var buffer: [4096]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.hash.Wyhash) = .initHasher(
        std.hash.Wyhash.init(0x4e_41_56_47_52_41_50_48),
        &buffer,
    );
    writeCanonicalContract(&hashing.writer) catch unreachable;
    hashing.writer.flush() catch unreachable;
    return hashing.hasher.final();
}

/// SemVer-compatible server version including the content-addressed source
/// identity. This is what replaces the old static `phase3` MCP version.
pub fn writeBuildVersion(w: *std.Io.Writer) !void {
    try w.print("{s}+src.{x:0>16}", .{ product_version, source_fingerprint });
}

pub fn writeBuildId(w: *std.Io.Writer) !void {
    try w.print("navgraph@{s}+src.{x:0>16}", .{ product_version, source_fingerprint });
}

/// Deterministic build-variant identity for the published inputs below. This is
/// deliberately not described as an artifact digest: linker inputs and CPU
/// feature overrides can still change executable bytes. `buildId` remains the
/// compatible source identity above.
pub fn writeBinaryId(w: *std.Io.Writer) !void {
    try w.print("navgraph@{s}+src.{x:0>16}.{s}-{s}-{s}.{s}.zig-{s}", .{
        product_version,
        source_fingerprint,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.abi),
        @tagName(builtin.mode),
        builtin.zig_version_string,
    });
    if (source_revision.len != 0) {
        try w.print(".rev-{x:0>16}", .{std.hash.Wyhash.hash(0, source_revision)});
    }
}

pub fn writeManifest(w: *std.Io.Writer) !void {
    try w.writeByte('{');
    try writeContractIdentity(w);
    try w.writeAll(",\"build\":{");
    try w.writeAll("\"product\":\"navgraph\",\"version\":");
    try string(w, product_version);
    try w.writeAll(",\"buildVersion\":");
    try quotedBuildVersion(w);
    try w.writeAll(",\"buildId\":");
    try quotedBuildId(w);
    try w.writeAll(",\"buildIdScope\":\"source\",\"sourceBuildVersion\":");
    try quotedBuildVersion(w);
    try w.writeAll(",\"sourceBuildId\":");
    try quotedBuildId(w);
    try w.writeAll(",\"binaryIdScope\":\"build_variant_not_artifact_digest:source_revision_target_triple_optimize_compiler\",\"binaryId\":");
    try quotedBinaryId(w);
    try w.writeAll(",\"revision\":");
    if (source_revision.len == 0) try w.writeAll("null") else try string(w, source_revision);
    try w.print(",\"sourceFingerprint\":\"{x:0>16}\",\"sourceFingerprintAlgorithm\":\"wyhash64(sorted src/**/*.zig paths+contents)\"", .{source_fingerprint});
    try w.writeAll(",\"compiler\":");
    try string(w, builtin.zig_version_string);
    try w.writeAll(",\"target\":{\"arch\":");
    try string(w, @tagName(builtin.cpu.arch));
    try w.writeAll(",\"os\":");
    try string(w, @tagName(builtin.os.tag));
    try w.writeAll(",\"abi\":");
    try string(w, @tagName(builtin.abi));
    try w.writeAll("},\"optimize\":");
    try string(w, @tagName(builtin.mode));
    try w.writeAll("},\"schemaHash\":");
    try w.print("\"wyhash64:{x:0>16}\"", .{schemaFingerprint()});

    try writeContractFields(w);
    try w.writeByte('}');
}

/// Exact, build-independent JSON whose bytes define `schemaHash`. Both this
/// writer and the public manifest call the same field serializer, so changing a
/// key, nesting shape, spelling, MCP name, limit, or output contract necessarily
/// changes the hash. Only concrete build identity and the hash itself are
/// excluded.
fn writeCanonicalContract(w: *std.Io.Writer) !void {
    try w.writeByte('{');
    try writeContractIdentity(w);
    try writeContractFields(w);
    try w.writeByte('}');
}

fn writeContractIdentity(w: *std.Io.Writer) !void {
    try w.writeAll("\"schema\":");
    try string(w, capability_schema);
    try w.print(",\"schemaVersion\":{},\"agentProtocolVersion\":", .{capability_schema_version});
    try string(w, agent_protocol_version);
}

fn writeContractFields(w: *std.Io.Writer) !void {
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
    try w.writeAll(",\"languageSupport\":");
    try w.writeAll(language_support_json);

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
        try w.writeAll("],\"dependencies\":[");
        for (command.dependencies, 0..) |dependency, dependency_i| {
            if (dependency_i != 0) try w.writeByte(',');
            try w.writeAll("{\"option\":");
            try string(w, registry.optionDescriptor(dependency.option).name);
            try w.writeAll(",\"requires\":{\"option\":");
            try string(w, registry.optionDescriptor(dependency.requires).name);
            if (dependency.required_value) |value| {
                try w.writeAll(",\"value\":");
                try writeFixedValue(w, value);
            }
            try w.writeAll("}}");
        }
        try w.writeAll("],\"conflicts\":[");
        for (command.conflicts, 0..) |conflict, conflict_i| {
            if (conflict_i != 0) try w.writeByte(',');
            try w.writeByte('[');
            try string(w, registry.optionDescriptor(conflict.first).name);
            try w.writeByte(',');
            try string(w, registry.optionDescriptor(conflict.second).name);
            try w.writeByte(']');
        }
        try w.writeAll("],\"access\":");
        try string(w, @tagName(command.access));
        try w.print(",\"requiresIndex\":{},\"serverAvailable\":{},\"cacheEffect\":", .{ command.requires_index, command.server_available });
        try string(w, @tagName(command.cache_effect));
        try w.writeByte('}');
    }
    try w.writeByte(']');

    try w.writeAll(",\"options\":[");
    for (&registry.option_descriptors, 0..) |option, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try string(w, option.name);
        try w.writeAll(",\"flags\":[");
        for (option.spellings, 0..) |spelling, spelling_i| {
            if (spelling_i != 0) try w.writeByte(',');
            try string(w, spelling.flag);
        }
        try w.writeAll("],\"spellings\":[");
        for (option.spellings, 0..) |spelling, spelling_i| {
            if (spelling_i != 0) try w.writeByte(',');
            try w.writeAll("{\"flag\":");
            try string(w, spelling.flag);
            try w.print(",\"takesValue\":{}", .{spelling.takes_value});
            if (spelling.fixed_value) |fixed| {
                try w.writeAll(",\"fixedValue\":");
                try writeFixedValue(w, fixed);
            }
            try w.writeByte('}');
        }
        try w.writeAll("]");
        try w.writeAll(",\"valueKind\":");
        try string(w, @tagName(option.value_kind));
        if (option.values.len != 0) {
            try w.writeAll(",\"values\":");
            try stringArray(w, option.values);
        }
        if (option.minimum) |minimum| try w.print(",\"minimum\":{}", .{minimum});
        if (option.value_separator) |separator| {
            try w.writeAll(",\"valueSeparator\":");
            try string(w, separator);
        }
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

    try w.writeAll(",\"argvContract\":");
    try w.writeAll(argv_contract_json);
    try w.writeAll(",\"outputContract\":");
    try w.writeAll(output_contract_json);
    try w.writeAll(",\"sideEffects\":");
    try w.writeAll(side_effects_json);

    try w.writeAll(",\"server\":{\"transport\":");
    try string(w, server_transport);
    try w.writeAll(",\"mcpProtocolVersion\":");
    try string(w, mcp_protocol_version);
    try w.writeAll(",\"capabilitiesMethod\":");
    try string(w, capabilities_method);
    try w.writeAll(",\"capabilitiesTool\":");
    try string(w, capabilities_tool);
    try w.writeAll(",\"queryTool\":");
    try string(w, agent_api.tool_name);
    try w.writeAll(",\"querySchema\":");
    try string(w, agent_api.query_schema);
    try w.writeAll(",\"resultSchema\":");
    try string(w, agent_api.result_schema);
    try w.print(",\"agentSchemaHash\":\"wyhash64:{x:0>16}\"", .{agent_api.inputSchemaFingerprint()});
    try w.writeAll(",\"maxBytes\":{\"scope\":");
    try string(w, max_bytes_scope);
    try w.print(",\"default\":{},\"minimum\":{},\"maximum\":{},\"hard\":true}}", .{ agent_api.default_max_bytes, agent_api.min_max_bytes, agent_api.max_max_bytes });
    try w.writeAll(",\"pagination\":");
    try w.writeAll(pagination_json);
    try w.writeAll(",\"legacyTool\":");
    try string(w, legacy_tool);
    try w.writeAll(",\"legacyAccess\":");
    try string(w, legacy_access);
    try w.writeAll(",\"reloadMethod\":");
    try string(w, reload_method);
    try w.writeAll(",\"reloadTool\":");
    try string(w, reload_tool);
    try w.writeAll(",\"snapshotRefresh\":");
    try string(w, snapshot_refresh);
    try w.writeByte('}');

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
    try w.writeAll("]}");
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

fn quotedBinaryId(w: *std.Io.Writer) !void {
    try w.writeByte('"');
    try writeBinaryId(w);
    try w.writeByte('"');
}

fn writeFixedValue(w: *std.Io.Writer, value: registry.FixedValue) !void {
    switch (value) {
        .boolean => |boolean| try w.print("{}", .{boolean}),
        .string => |string_value| try string(w, string_value),
    }
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

fn canonicalContractOwned(allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    defer allocating.deinit();
    try writeCanonicalContract(&allocating.writer);
    return allocator.dupe(u8, allocating.written());
}

fn findNamedValue(items: []const std.json.Value, name: []const u8) ?*const std.json.Value {
    for (items) |*item| {
        const candidate = item.object.get("name") orelse continue;
        if (candidate != .string) continue;
        if (std.mem.eql(u8, candidate.string, name)) return item;
    }
    return null;
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
    try std.testing.expectEqualStrings("source", build.get("buildIdScope").?.string);
    try std.testing.expectEqualStrings(build.get("buildVersion").?.string, build.get("sourceBuildVersion").?.string);
    try std.testing.expectEqualStrings(build.get("buildId").?.string, build.get("sourceBuildId").?.string);
    try std.testing.expectEqualStrings("build_variant_not_artifact_digest:source_revision_target_triple_optimize_compiler", build.get("binaryIdScope").?.string);
    try std.testing.expect(!std.mem.eql(u8, build.get("sourceBuildId").?.string, build.get("binaryId").?.string));
    try std.testing.expect(build.get("target").?.object.get("arch").?.string.len != 0);
    try std.testing.expect(build.get("optimize").?.string.len != 0);
    try std.testing.expectEqual(@as(usize, 16), build.get("sourceFingerprint").?.string.len);
    try std.testing.expectEqual(language.supported.len, root.get("languages").?.array.items.len);
    const import_support = root.get("languageSupport").?.object.get("commandOverrides").?.array.items[0].object;
    try std.testing.expectEqualStrings("imports", import_support.get("commands").?.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 4), import_support.get("unsupported").?.array.items.len);
    try std.testing.expectEqual(registry.command_descriptors.len, root.get("commands").?.array.items.len);
    try std.testing.expectEqual(registry.option_descriptors.len, root.get("options").?.array.items.len);
}

test "schema fingerprint is the exact canonical emitted contract" {
    const canonical = try canonicalContractOwned(std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, canonical, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("build") == null);
    try std.testing.expect(parsed.value.object.get("schemaHash") == null);
    try std.testing.expect(parsed.value.object.get("commands") != null);
    try std.testing.expectEqual(
        std.hash.Wyhash.hash(0x4e_41_56_47_52_41_50_48, canonical),
        schemaFingerprint(),
    );
}

test "capability manifest publishes runnable option constraints and cache truth" {
    const bytes = try manifestOwned(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const search = findNamedValue(root.get("commands").?.array.items, "search").?.object;
    const dependencies = search.get("dependencies").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), dependencies.len);
    try std.testing.expectEqualStrings("after", dependencies[0].object.get("option").?.string);
    const after_requires = dependencies[0].object.get("requires").?.object;
    try std.testing.expectEqualStrings("format", after_requires.get("option").?.string);
    try std.testing.expectEqualStrings("jsonl", after_requires.get("value").?.string);
    try std.testing.expectEqualStrings("writers", dependencies[1].object.get("option").?.string);
    try std.testing.expectEqualStrings("refs", dependencies[1].object.get("requires").?.object.get("option").?.string);
    try std.testing.expectEqual(@as(usize, 2), search.get("conflicts").?.array.items.len);
    try std.testing.expectEqualStrings("may_read_write", search.get("cacheEffect").?.string);

    const read = findNamedValue(root.get("commands").?.array.items, "read").?.object;
    try std.testing.expect(!read.get("requiresIndex").?.bool);
    try std.testing.expectEqualStrings("none", read.get("cacheEffect").?.string);
    // `read` declares `no_cache` (clients append it to every argv) while its
    // cache effect stays "none" — it never touches the cache either way.
    var read_declares_no_cache = false;
    for (read.get("options").?.array.items) |option| {
        if (std.mem.eql(u8, option.string, "no_cache")) read_declares_no_cache = true;
    }
    try std.testing.expect(read_declares_no_cache);
    const rename = findNamedValue(root.get("commands").?.array.items, "rename").?.object;
    try std.testing.expect(!rename.get("serverAvailable").?.bool);

    const format = findNamedValue(root.get("options").?.array.items, "format").?.object;
    const spellings = format.get("spellings").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), spellings.len);
    try std.testing.expect(!spellings[0].object.get("takesValue").?.bool);
    try std.testing.expectEqualStrings("json", spellings[0].object.get("fixedValue").?.string);
    try std.testing.expectEqualStrings("jsonl", spellings[2].object.get("fixedValue").?.string);

    const side_effects = root.get("sideEffects").?.object;
    try std.testing.expectEqualStrings(".navgraph/cache", side_effects.get("cache").?.object.get("path").?.string);
    try std.testing.expectEqualStrings("no_per_request_cache_io", side_effects.get("server").?.object.get("queries").?.string);
    try std.testing.expectEqualStrings("first_outputModes_entry", root.get("argvContract").?.object.get("defaultOutput").?.string);

    const kind = findNamedValue(root.get("options").?.array.items, "kind").?.object;
    try std.testing.expectEqualStrings(",", kind.get("valueSeparator").?.string);
    try std.testing.expect(kind.get("values").?.array.items.len > 10);
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "git_repository_metadata_trusted") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "per_reference_and_relation_edge") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "directly_runnable_query") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "phase3") == null);
}
