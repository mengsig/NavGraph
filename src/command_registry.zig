//! Canonical metadata for NavGraph's CLI surface.
//!
//! The parser, capability manifest, and MCP identity all consume this table.
//! Dispatch remains explicit in `main.zig`: centralizing names, aliases, argument
//! shapes, option applicability, output modes, and access classification here is
//! deliberately a smaller and safer first step than rewriting every handler.

const std = @import("std");

pub const Command = enum {
    outline,
    def,
    docs,
    calls,
    callers,
    search,
    routes,
    events,
    conforms,
    hierarchy,
    raises,
    catches,
    neighbors,
    unused,
    imports,
    importers,
    path,
    flow,
    taint,
    reaches,
    affected,
    hot,
    diff,
    history,
    blame,
    churn,
    collisions,
    files,
    status,
    read,
    strings,
    todos,
    edits,
    rename,
    coverage,
    graph,
    capabilities,
    serve,
    help,
};

pub const Access = enum { read_only, mutating, metadata, server };
pub const OutputMode = enum { text, json, jsonl, html, json_rpc };
pub const ArgumentKind = enum { path_filter, symbol, pattern, filter, git_ref, source_range, new_name, command_name };

pub const Argument = struct {
    name: []const u8,
    kind: ArgumentKind,
    required: bool,
};

/// Stable machine names for flags. These are intentionally not the fields of
/// `query.Options`: aliases and fixed-value shortcuts (`--public`, `--jsonl`)
/// belong to the public CLI contract, while `after_set` and similar fields are
/// parser implementation details.
pub const Option = enum {
    root,
    no_cache,
    verbosity,
    depth,
    limit,
    budget,
    max_nodes,
    summary,
    strict,
    format,
    after,
    refs,
    kind,
    sort,
    tests,
    exact,
    no_recurse,
    visibility,
    writers,
    readers,
    unread,
    on_type,
    to,
    duplicates,
    members,
    impls,
    overrides,
    from_tests,
    since,
    last,
    preview,
    exact_source,
    clients,
    unhit,
    orphan_calls,
    handler,
    no_public,
    follow_imports,
};

pub const ValueKind = enum { boolean, string, integer, enumeration, cursor };

pub const OptionDescriptor = struct {
    option: Option,
    name: []const u8,
    flags: []const []const u8,
    value_kind: ValueKind,
    values: []const []const u8 = &.{},
    minimum: ?u32 = null,
};

pub const option_descriptors = [_]OptionDescriptor{
    .{ .option = .root, .name = "root", .flags = &.{ "-C", "--root" }, .value_kind = .string },
    .{ .option = .no_cache, .name = "no_cache", .flags = &.{"--no-cache"}, .value_kind = .boolean },
    .{ .option = .verbosity, .name = "verbosity", .flags = &.{ "-v", "--verbosity" }, .value_kind = .enumeration, .values = &.{ "names", "sig", "doc", "full" } },
    .{ .option = .depth, .name = "depth", .flags = &.{ "-d", "--depth" }, .value_kind = .integer, .minimum = 0 },
    .{ .option = .limit, .name = "limit", .flags = &.{ "-l", "--limit" }, .value_kind = .integer, .minimum = 1 },
    .{ .option = .budget, .name = "budget", .flags = &.{"--budget"}, .value_kind = .integer, .minimum = 64 },
    .{ .option = .max_nodes, .name = "max_nodes", .flags = &.{"--max-nodes"}, .value_kind = .integer, .minimum = 1 },
    .{ .option = .summary, .name = "summary", .flags = &.{"--summary"}, .value_kind = .boolean },
    .{ .option = .strict, .name = "strict", .flags = &.{ "-s", "--strict" }, .value_kind = .boolean },
    .{ .option = .format, .name = "format", .flags = &.{ "-j", "--json", "--jsonl" }, .value_kind = .enumeration, .values = &.{ "text", "json", "jsonl" } },
    .{ .option = .after, .name = "after", .flags = &.{"--after"}, .value_kind = .cursor },
    .{ .option = .refs, .name = "refs", .flags = &.{ "-r", "--refs" }, .value_kind = .boolean },
    .{ .option = .kind, .name = "kind", .flags = &.{ "-k", "--kind" }, .value_kind = .string },
    .{ .option = .sort, .name = "sort", .flags = &.{"--sort"}, .value_kind = .enumeration, .values = &.{ "path", "symbols", "line", "name", "span", "callers", "callees", "fan_in", "fan_in_exact", "fan_out", "fan_out_exact", "commits", "lines" } },
    .{ .option = .tests, .name = "tests", .flags = &.{ "-t", "--tests", "--no-tests", "--tests-only" }, .value_kind = .enumeration, .values = &.{ "with", "without", "only" } },
    .{ .option = .exact, .name = "exact", .flags = &.{ "-e", "--exact" }, .value_kind = .boolean },
    .{ .option = .no_recurse, .name = "no_recurse", .flags = &.{"--no-recurse"}, .value_kind = .boolean },
    .{ .option = .visibility, .name = "visibility", .flags = &.{ "-p", "--vis", "--public", "--private", "--no-private" }, .value_kind = .enumeration, .values = &.{ "all", "public", "private" } },
    .{ .option = .writers, .name = "writers", .flags = &.{ "-w", "--writers" }, .value_kind = .boolean },
    .{ .option = .readers, .name = "readers", .flags = &.{"--readers"}, .value_kind = .boolean },
    .{ .option = .unread, .name = "unread", .flags = &.{ "-u", "--unread" }, .value_kind = .boolean },
    .{ .option = .on_type, .name = "on_type", .flags = &.{"--on-type"}, .value_kind = .string },
    .{ .option = .to, .name = "to", .flags = &.{"--to"}, .value_kind = .string },
    .{ .option = .duplicates, .name = "duplicates", .flags = &.{"--duplicates"}, .value_kind = .boolean },
    .{ .option = .members, .name = "members", .flags = &.{"--members"}, .value_kind = .boolean },
    .{ .option = .impls, .name = "impls", .flags = &.{ "-i", "--impls" }, .value_kind = .boolean },
    .{ .option = .overrides, .name = "overrides", .flags = &.{"--overrides"}, .value_kind = .boolean },
    .{ .option = .from_tests, .name = "from_tests", .flags = &.{"--from-tests"}, .value_kind = .boolean },
    .{ .option = .since, .name = "since", .flags = &.{"--since"}, .value_kind = .string },
    .{ .option = .last, .name = "last", .flags = &.{"--last"}, .value_kind = .integer, .minimum = 1 },
    .{ .option = .preview, .name = "preview", .flags = &.{"--preview"}, .value_kind = .boolean },
    .{ .option = .exact_source, .name = "exact_source", .flags = &.{"--exact-source"}, .value_kind = .boolean },
    .{ .option = .clients, .name = "clients", .flags = &.{"--clients"}, .value_kind = .boolean },
    .{ .option = .unhit, .name = "unhit", .flags = &.{"--unhit"}, .value_kind = .boolean },
    .{ .option = .orphan_calls, .name = "orphan_calls", .flags = &.{ "--orphan-calls", "--orphan", "--orphans" }, .value_kind = .boolean },
    .{ .option = .handler, .name = "handler", .flags = &.{"--handler"}, .value_kind = .string },
    .{ .option = .no_public, .name = "no_public", .flags = &.{"--no-public"}, .value_kind = .boolean },
    .{ .option = .follow_imports, .name = "follow_imports", .flags = &.{"--follow-imports"}, .value_kind = .boolean },
};

pub const CommandDescriptor = struct {
    command: Command,
    name: []const u8,
    aliases: []const []const u8 = &.{},
    arguments: []const Argument = &.{},
    options: []const Option = &.{},
    required_options: []const Option = &.{},
    option_value_overrides: []const OptionValueOverride = &.{},
    outputs: []const OutputMode,
    access: Access,
    requires_index: bool,
    server_available: bool = true,
};

pub const OptionValueOverride = struct {
    option: Option,
    values: []const []const u8,
};

const no_args = [_]Argument{};
const help_args = [_]Argument{.{ .name = "command", .kind = .command_name, .required = false }};
const optional_path = [_]Argument{.{ .name = "path", .kind = .path_filter, .required = false }};
const optional_filter = [_]Argument{.{ .name = "filter", .kind = .filter, .required = false }};
const optional_ref = [_]Argument{.{ .name = "ref", .kind = .git_ref, .required = false }};
const symbol_arg = [_]Argument{.{ .name = "symbol", .kind = .symbol, .required = true }};
const pattern_arg = [_]Argument{.{ .name = "pattern", .kind = .pattern, .required = true }};
const file_arg = [_]Argument{.{ .name = "file", .kind = .path_filter, .required = true }};
const source_arg = [_]Argument{.{ .name = "source", .kind = .source_range, .required = true }};
const path_args = [_]Argument{
    .{ .name = "from", .kind = .symbol, .required = true },
    .{ .name = "to", .kind = .symbol, .required = true },
};
const rename_args = [_]Argument{
    .{ .name = "symbol", .kind = .symbol, .required = true },
    .{ .name = "new_name", .kind = .new_name, .required = true },
};

const text_json = [_]OutputMode{ .text, .json };
const text_json_jsonl = [_]OutputMode{ .text, .json, .jsonl };
const json_only = [_]OutputMode{.json};
const html_json = [_]OutputMode{ .html, .json };
const text_only = [_]OutputMode{.text};
const rpc_only = [_]OutputMode{.json_rpc};
const outline_sort_values = [_]OptionValueOverride{.{ .option = .sort, .values = &.{ "line", "name", "span", "callers", "callees" } }};
const files_sort_values = [_]OptionValueOverride{.{ .option = .sort, .values = &.{ "path", "symbols" } }};
const hot_sort_values = [_]OptionValueOverride{.{ .option = .sort, .values = &.{ "fan_in", "fan_in_exact", "fan_out", "fan_out_exact", "span" } }};
const churn_sort_values = [_]OptionValueOverride{.{ .option = .sort, .values = &.{ "commits", "lines" } }};

/// Every command appears exactly once. Option lists describe documented,
/// semantically effective applicability rather than every no-op combination the
/// historical parser happened to accept.
pub const command_descriptors = [_]CommandDescriptor{
    .{ .command = .outline, .name = "outline", .aliases = &.{"o"}, .arguments = &optional_path, .options = &.{ .root, .no_cache, .verbosity, .limit, .budget, .max_nodes, .summary, .format, .after, .kind, .sort, .tests, .no_recurse, .visibility }, .option_value_overrides = &outline_sort_values, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .def, .name = "def", .aliases = &.{"show"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .format, .visibility }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .docs, .name = "docs", .aliases = &.{"doc"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .calls, .name = "calls", .aliases = &.{"callees"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .depth, .limit, .budget, .max_nodes, .summary, .strict, .format, .refs, .impls }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .callers, .name = "callers", .aliases = &.{"uses"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .depth, .limit, .budget, .max_nodes, .summary, .strict, .format, .refs, .tests, .impls }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .search, .name = "search", .aliases = &.{"grep"}, .arguments = &pattern_arg, .options = &.{ .root, .no_cache, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .after, .refs, .kind, .sort, .tests, .exact, .visibility, .writers, .readers, .unread, .on_type, .duplicates }, .option_value_overrides = &outline_sort_values, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .routes, .name = "routes", .aliases = &.{"api"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .verbosity, .limit, .format, .clients, .unhit, .orphan_calls, .handler }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .events, .name = "events", .aliases = &.{ "dispatch", "bus" }, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .conforms, .name = "conforms", .aliases = &.{ "impls", "implements" }, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .limit, .strict, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .hierarchy, .name = "hierarchy", .aliases = &.{"hier"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .limit, .strict, .format, .overrides }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .raises, .name = "raises", .aliases = &.{"throws"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .depth, .limit, .strict, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .catches, .name = "catches", .aliases = &.{"handles"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .limit, .strict, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .neighbors, .name = "neighbors", .aliases = &.{"near"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .refs, .impls }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .unused, .name = "unused", .aliases = &.{"dead"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .verbosity, .limit, .format, .tests, .no_public, .follow_imports }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .imports, .name = "imports", .arguments = &optional_filter, .options = &.{ .root, .no_cache, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .importers, .name = "importers", .arguments = &file_arg, .options = &.{ .root, .no_cache, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .path, .name = "path", .arguments = &path_args, .options = &.{ .root, .no_cache, .verbosity, .strict, .format, .impls }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .flow, .name = "flow", .aliases = &.{"dataflow"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .limit, .strict, .format, .writers, .readers, .unread, .on_type, .to }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .taint, .name = "taint", .aliases = &.{"security"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .limit, .strict, .format, .to }, .required_options = &.{.to}, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .reaches, .name = "reaches", .aliases = &.{"reachable"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .after, .tests, .impls, .from_tests }, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .affected, .name = "affected", .aliases = &.{"impact"}, .arguments = &optional_ref, .options = &.{ .root, .no_cache, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .after, .impls, .since }, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .hot, .name = "hot", .aliases = &.{"central"}, .arguments = &optional_path, .options = &.{ .root, .no_cache, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .after, .sort, .tests }, .option_value_overrides = &hot_sort_values, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .diff, .name = "diff", .aliases = &.{"changed"}, .arguments = &optional_ref, .options = &.{ .root, .no_cache, .verbosity, .limit, .budget, .format, .exact_source }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .history, .name = "history", .aliases = &.{"hist"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .limit, .format, .last }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .blame, .name = "blame", .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .verbosity, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .churn, .name = "churn", .arguments = &optional_path, .options = &.{ .root, .no_cache, .verbosity, .limit, .format, .sort, .since, .last }, .option_value_overrides = &churn_sort_values, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .collisions, .name = "collisions", .aliases = &.{"duplicates"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .verbosity, .limit, .format, .kind, .tests, .visibility, .members }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .files, .name = "files", .aliases = &.{"manifest"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .limit, .format, .sort, .no_recurse }, .option_value_overrides = &files_sort_values, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .status, .name = "status", .aliases = &.{"snapshot"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .limit, .format, .after, .no_recurse }, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .read, .name = "read", .aliases = &.{"cat"}, .arguments = &source_arg, .options = &.{ .root, .no_cache, .limit, .budget, .format, .after }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .strings, .name = "strings", .aliases = &.{ "str", "literals" }, .arguments = &pattern_arg, .options = &.{ .root, .no_cache, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .todos, .name = "todos", .aliases = &.{"todo"}, .arguments = &optional_path, .options = &.{ .root, .no_cache, .limit, .format, .after }, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .edits, .name = "edits", .aliases = &.{"edit-sites"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .limit, .format, .after }, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .rename, .name = "rename", .arguments = &rename_args, .options = &.{ .root, .no_cache, .format, .preview }, .outputs = &text_json, .access = .mutating, .requires_index = true },
    .{ .command = .coverage, .name = "coverage", .aliases = &.{"cov"}, .arguments = &optional_path, .options = &.{ .root, .no_cache, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .graph, .name = "graph", .aliases = &.{ "viz", "visualize", "html" }, .arguments = &optional_path, .options = &.{ .root, .no_cache, .format, .tests }, .outputs = &html_json, .access = .read_only, .requires_index = true },
    .{ .command = .capabilities, .name = "capabilities", .aliases = &.{ "version", "--version" }, .arguments = &no_args, .options = &.{.format}, .outputs = &json_only, .access = .metadata, .requires_index = false },
    .{ .command = .serve, .name = "serve", .aliases = &.{"mcp"}, .arguments = &no_args, .options = &.{ .root, .no_cache }, .outputs = &rpc_only, .access = .server, .requires_index = true, .server_available = false },
    .{ .command = .help, .name = "help", .aliases = &.{ "--help", "-h" }, .arguments = &help_args, .outputs = &text_only, .access = .metadata, .requires_index = false, .server_available = false },
};

pub fn parseCommand(name: []const u8) ?Command {
    for (&command_descriptors) |desc| {
        if (std.mem.eql(u8, name, desc.name)) return desc.command;
        for (desc.aliases) |alias| if (std.mem.eql(u8, name, alias)) return desc.command;
    }
    return null;
}

pub fn descriptor(command: Command) *const CommandDescriptor {
    return &command_descriptors[@intFromEnum(command)];
}

pub fn optionDescriptor(option: Option) *const OptionDescriptor {
    return &option_descriptors[@intFromEnum(option)];
}

pub fn parseOptionFlag(flag: []const u8) ?Option {
    for (&option_descriptors) |desc| {
        for (desc.flags) |spelling| if (std.mem.eql(u8, flag, spelling)) return desc.option;
    }
    return null;
}

pub fn hasOption(command: Command, option: Option) bool {
    for (descriptor(command).options) |candidate| if (candidate == option) return true;
    return false;
}

pub fn supportsOutput(command: Command, output: OutputMode) bool {
    for (descriptor(command).outputs) |candidate| if (candidate == output) return true;
    return false;
}

test "registry covers enum order exactly and every public spelling is unique" {
    try std.testing.expectEqual(std.meta.fields(Command).len, command_descriptors.len);
    var spellings: std.StringHashMapUnmanaged(void) = .empty;
    defer spellings.deinit(std.testing.allocator);
    for (&command_descriptors, 0..) |desc, ordinal| {
        try std.testing.expectEqual(@as(usize, @intFromEnum(desc.command)), ordinal);
        try std.testing.expectEqualStrings(@tagName(desc.command), desc.name);
        try std.testing.expect((try spellings.fetchPut(std.testing.allocator, desc.name, {})) == null);
        try std.testing.expectEqual(desc.command, parseCommand(desc.name).?);
        for (desc.aliases) |alias| {
            try std.testing.expect(alias.len > 0);
            try std.testing.expect((try spellings.fetchPut(std.testing.allocator, alias, {})) == null);
            try std.testing.expectEqual(desc.command, parseCommand(alias).?);
        }
    }
}

test "option registry covers enum order exactly and command references are valid" {
    try std.testing.expectEqual(std.meta.fields(Option).len, option_descriptors.len);
    var flags: std.StringHashMapUnmanaged(void) = .empty;
    defer flags.deinit(std.testing.allocator);
    for (&option_descriptors, 0..) |desc, ordinal| {
        try std.testing.expectEqual(@as(usize, @intFromEnum(desc.option)), ordinal);
        try std.testing.expectEqualStrings(@tagName(desc.option), desc.name);
        try std.testing.expect(desc.flags.len > 0);
        for (desc.flags) |flag| {
            try std.testing.expect((try flags.fetchPut(std.testing.allocator, flag, {})) == null);
            try std.testing.expectEqual(desc.option, parseOptionFlag(flag).?);
        }
        var applies_to: usize = 0;
        for (&command_descriptors) |command| {
            if (hasOption(command.command, desc.option)) applies_to += 1;
        }
        try std.testing.expect(applies_to > 0);
    }
    for (&command_descriptors) |command| {
        var seen = std.EnumSet(Option).initEmpty();
        for (command.options) |option| {
            try std.testing.expect(!seen.contains(option));
            seen.insert(option);
            _ = optionDescriptor(option);
        }
        for (command.required_options) |option| try std.testing.expect(hasOption(command.command, option));
        for (command.option_value_overrides) |override| {
            try std.testing.expect(hasOption(command.command, override.option));
            try std.testing.expect(override.values.len > 0);
        }
    }
}
