//! Canonical metadata for NavGraph's CLI surface.
//!
//! The parser, capability manifest, and MCP identity all consume this table.
//! Dispatch remains explicit in `main.zig`: centralizing names, aliases, argument
//! shapes, option applicability, output modes, and access classification here is
//! deliberately a smaller and safer first step than rewriting every handler.

const std = @import("std");
const backends = @import("backends.zig");

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
    lsp,
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
    backend,
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
    log,
    log_level,
};

pub const ValueKind = enum { boolean, string, integer, enumeration, cursor };

pub const FixedValue = union(enum) {
    boolean: bool,
    string: []const u8,
};

pub const FlagSpelling = struct {
    flag: []const u8,
    takes_value: bool,
    fixed_value: ?FixedValue = null,
};

fn valueFlag(flag: []const u8) FlagSpelling {
    return .{ .flag = flag, .takes_value = true };
}

fn trueFlag(flag: []const u8) FlagSpelling {
    return .{ .flag = flag, .takes_value = false, .fixed_value = .{ .boolean = true } };
}

fn fixedFlag(flag: []const u8, value: []const u8) FlagSpelling {
    return .{ .flag = flag, .takes_value = false, .fixed_value = .{ .string = value } };
}

pub const OptionDescriptor = struct {
    option: Option,
    name: []const u8,
    spellings: []const FlagSpelling,
    value_kind: ValueKind,
    values: []const []const u8 = &.{},
    value_separator: ?[]const u8 = null,
    minimum: ?u32 = null,
};

/// `--backend tree-sitter` is a hard error on a build that links no grammar, so
/// the manifest must not advertise it: the manifest IS the agent contract, and
/// an agent has no other way to discover what this binary can do.
const backend_values: []const []const u8 = if (backends.any_grammar)
    &.{ "auto", "heuristic", "tree-sitter" }
else
    &.{ "auto", "heuristic" };

pub const option_descriptors = [_]OptionDescriptor{
    .{ .option = .root, .name = "root", .spellings = &.{ valueFlag("-C"), valueFlag("--root") }, .value_kind = .string },
    .{ .option = .no_cache, .name = "no_cache", .spellings = &.{trueFlag("--no-cache")}, .value_kind = .boolean },
    .{ .option = .backend, .name = "backend", .spellings = &.{valueFlag("--backend")}, .value_kind = .enumeration, .values = backend_values },
    .{ .option = .verbosity, .name = "verbosity", .spellings = &.{ valueFlag("-v"), valueFlag("--verbosity") }, .value_kind = .enumeration, .values = &.{ "names", "sig", "doc", "full" } },
    .{ .option = .depth, .name = "depth", .spellings = &.{ valueFlag("-d"), valueFlag("--depth") }, .value_kind = .integer, .minimum = 0 },
    .{ .option = .limit, .name = "limit", .spellings = &.{ valueFlag("-l"), valueFlag("--limit") }, .value_kind = .integer, .minimum = 1 },
    .{ .option = .budget, .name = "budget", .spellings = &.{valueFlag("--budget")}, .value_kind = .integer, .minimum = 64 },
    .{ .option = .max_nodes, .name = "max_nodes", .spellings = &.{valueFlag("--max-nodes")}, .value_kind = .integer, .minimum = 1 },
    .{ .option = .summary, .name = "summary", .spellings = &.{trueFlag("--summary")}, .value_kind = .boolean },
    .{ .option = .strict, .name = "strict", .spellings = &.{ trueFlag("-s"), trueFlag("--strict") }, .value_kind = .boolean },
    .{ .option = .format, .name = "format", .spellings = &.{ fixedFlag("-j", "json"), fixedFlag("--json", "json"), fixedFlag("--jsonl", "jsonl") }, .value_kind = .enumeration, .values = &.{ "text", "json", "jsonl" } },
    .{ .option = .after, .name = "after", .spellings = &.{valueFlag("--after")}, .value_kind = .cursor },
    .{ .option = .refs, .name = "refs", .spellings = &.{ trueFlag("-r"), trueFlag("--refs") }, .value_kind = .boolean },
    .{ .option = .kind, .name = "kind", .spellings = &.{ valueFlag("-k"), valueFlag("--kind") }, .value_kind = .enumeration, .values = &.{ "fn", "function", "func", "method", "class", "struct", "enum", "iface", "interface", "type", "var", "variable", "const", "constant", "field", "macro", "mod", "module", "import", "route", "mount", "test", "sym" }, .value_separator = "," },
    .{ .option = .sort, .name = "sort", .spellings = &.{valueFlag("--sort")}, .value_kind = .enumeration, .values = &.{ "path", "symbols", "line", "name", "span", "callers", "callees", "fan_in", "fan_in_exact", "fan_out", "fan_out_exact", "commits", "lines" } },
    .{ .option = .tests, .name = "tests", .spellings = &.{ valueFlag("-t"), valueFlag("--tests"), fixedFlag("--no-tests", "without"), fixedFlag("--tests-only", "only") }, .value_kind = .enumeration, .values = &.{ "with", "without", "only" } },
    .{ .option = .exact, .name = "exact", .spellings = &.{ trueFlag("-e"), trueFlag("--exact") }, .value_kind = .boolean },
    .{ .option = .no_recurse, .name = "no_recurse", .spellings = &.{trueFlag("--no-recurse")}, .value_kind = .boolean },
    .{ .option = .visibility, .name = "visibility", .spellings = &.{ valueFlag("-p"), valueFlag("--vis"), fixedFlag("--public", "public"), fixedFlag("--private", "private"), fixedFlag("--no-private", "public") }, .value_kind = .enumeration, .values = &.{ "all", "public", "private" } },
    .{ .option = .writers, .name = "writers", .spellings = &.{ trueFlag("-w"), trueFlag("--writers") }, .value_kind = .boolean },
    .{ .option = .readers, .name = "readers", .spellings = &.{trueFlag("--readers")}, .value_kind = .boolean },
    .{ .option = .unread, .name = "unread", .spellings = &.{ trueFlag("-u"), trueFlag("--unread") }, .value_kind = .boolean },
    .{ .option = .on_type, .name = "on_type", .spellings = &.{valueFlag("--on-type")}, .value_kind = .string },
    .{ .option = .to, .name = "to", .spellings = &.{valueFlag("--to")}, .value_kind = .string },
    .{ .option = .duplicates, .name = "duplicates", .spellings = &.{trueFlag("--duplicates")}, .value_kind = .boolean },
    .{ .option = .members, .name = "members", .spellings = &.{trueFlag("--members")}, .value_kind = .boolean },
    .{ .option = .impls, .name = "impls", .spellings = &.{ trueFlag("-i"), trueFlag("--impls") }, .value_kind = .boolean },
    .{ .option = .overrides, .name = "overrides", .spellings = &.{trueFlag("--overrides")}, .value_kind = .boolean },
    .{ .option = .from_tests, .name = "from_tests", .spellings = &.{trueFlag("--from-tests")}, .value_kind = .boolean },
    .{ .option = .since, .name = "since", .spellings = &.{valueFlag("--since")}, .value_kind = .string },
    .{ .option = .last, .name = "last", .spellings = &.{valueFlag("--last")}, .value_kind = .integer, .minimum = 1 },
    .{ .option = .preview, .name = "preview", .spellings = &.{trueFlag("--preview")}, .value_kind = .boolean },
    .{ .option = .exact_source, .name = "exact_source", .spellings = &.{trueFlag("--exact-source")}, .value_kind = .boolean },
    .{ .option = .clients, .name = "clients", .spellings = &.{trueFlag("--clients")}, .value_kind = .boolean },
    .{ .option = .unhit, .name = "unhit", .spellings = &.{trueFlag("--unhit")}, .value_kind = .boolean },
    .{ .option = .orphan_calls, .name = "orphan_calls", .spellings = &.{ trueFlag("--orphan-calls"), trueFlag("--orphan"), trueFlag("--orphans") }, .value_kind = .boolean },
    .{ .option = .handler, .name = "handler", .spellings = &.{valueFlag("--handler")}, .value_kind = .string },
    .{ .option = .no_public, .name = "no_public", .spellings = &.{trueFlag("--no-public")}, .value_kind = .boolean },
    .{ .option = .follow_imports, .name = "follow_imports", .spellings = &.{trueFlag("--follow-imports")}, .value_kind = .boolean },
    .{ .option = .log, .name = "log", .spellings = &.{valueFlag("--log")}, .value_kind = .string },
    .{ .option = .log_level, .name = "log_level", .spellings = &.{valueFlag("--log-level")}, .value_kind = .enumeration, .values = &.{ "error", "info", "debug" } },
};

pub const CommandDescriptor = struct {
    command: Command,
    name: []const u8,
    /// One plain-English line for `navgraph help <command>` — no internal
    /// terms (resolver, backend tier, ...). The top-level catalogue in
    /// `usage()` is separate, hand-maintained text; this does not feed it.
    summary: []const u8,
    /// A single runnable `navgraph <command> ...` invocation shown in help.
    example: []const u8,
    aliases: []const []const u8 = &.{},
    arguments: []const Argument = &.{},
    options: []const Option = &.{},
    required_options: []const Option = &.{},
    option_value_overrides: []const OptionValueOverride = &.{},
    dependencies: []const OptionDependency = &.{},
    conflicts: []const OptionConflict = &.{},
    outputs: []const OutputMode,
    access: Access,
    requires_index: bool,
    server_available: bool = true,
    cache_effect: CacheEffect = .may_read_write,
};

pub const OptionValueOverride = struct {
    option: Option,
    values: []const []const u8,
};

pub const OptionDependency = struct {
    option: Option,
    requires: Option,
    required_value: ?FixedValue = null,
};

pub const OptionConflict = struct {
    first: Option,
    second: Option,
};

pub const CacheEffect = enum { none, may_read_write };

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
const jsonl_after_dependency = [_]OptionDependency{.{ .option = .after, .requires = .format, .required_value = .{ .string = "jsonl" } }};
const search_dependencies = [_]OptionDependency{
    .{ .option = .after, .requires = .format, .required_value = .{ .string = "jsonl" } },
    .{ .option = .writers, .requires = .refs },
    .{ .option = .readers, .requires = .refs },
    .{ .option = .unread, .requires = .refs },
    .{ .option = .on_type, .requires = .refs },
};
const search_conflicts = [_]OptionConflict{
    .{ .first = .writers, .second = .readers },
    .{ .first = .duplicates, .second = .refs },
};
const flow_conflicts = [_]OptionConflict{.{ .first = .writers, .second = .readers }};
const route_conflicts = [_]OptionConflict{
    .{ .first = .orphan_calls, .second = .clients },
    .{ .first = .orphan_calls, .second = .unhit },
    .{ .first = .orphan_calls, .second = .handler },
};

/// Every command appears exactly once. Option lists describe documented,
/// semantically effective applicability rather than every no-op combination the
/// historical parser happened to accept.
pub const command_descriptors = [_]CommandDescriptor{
    .{ .command = .outline, .name = "outline", .summary = "List the symbols defined in a file or directory.", .example = "navgraph outline src/parser.zig --kind fn", .aliases = &.{"o"}, .arguments = &optional_path, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .budget, .max_nodes, .summary, .format, .after, .kind, .sort, .tests, .no_recurse, .visibility }, .option_value_overrides = &outline_sort_values, .dependencies = &jsonl_after_dependency, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .def, .name = "def", .summary = "Show one definition's signature, docs, and location.", .example = "navgraph def parseZigScope -v full", .aliases = &.{"show"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .format, .visibility }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .docs, .name = "docs", .summary = "Show the docstring or leading comment for a definition.", .example = "navgraph docs buildOpenDir", .aliases = &.{"doc"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .calls, .name = "calls", .summary = "Show what a symbol calls, as a tree (its callees).", .example = "navgraph calls build@build.zig -d 2", .aliases = &.{"callees"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .depth, .limit, .budget, .max_nodes, .summary, .strict, .format, .refs, .impls }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .callers, .name = "callers", .summary = "Show what calls a symbol, as a tree (its callers).", .example = "navgraph callers collectRefs", .aliases = &.{"uses"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .depth, .limit, .budget, .max_nodes, .summary, .strict, .format, .refs, .tests, .impls }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .search, .name = "search", .summary = "Find symbols, or their use sites, by name.", .example = "navgraph search resolve --refs", .aliases = &.{"grep"}, .arguments = &pattern_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .after, .refs, .kind, .sort, .tests, .exact, .visibility, .writers, .readers, .unread, .on_type, .duplicates }, .option_value_overrides = &outline_sort_values, .dependencies = &search_dependencies, .conflicts = &search_conflicts, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .routes, .name = "routes", .summary = "List HTTP routes and, with --clients, who calls them.", .example = "navgraph routes /v1/orders --clients", .aliases = &.{"api"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .format, .clients, .unhit, .orphan_calls, .handler }, .conflicts = &route_conflicts, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .events, .name = "events", .summary = "Link message-bus event handlers to their emitters.", .example = "navgraph events order.created", .aliases = &.{ "dispatch", "bus" }, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .backend, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .conforms, .name = "conforms", .summary = "Check implementations against an interface, or diff sibling classes.", .example = "navgraph conforms Store", .aliases = &.{ "impls", "implements" }, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .strict, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .hierarchy, .name = "hierarchy", .summary = "Show a type's supertypes and subtypes (its inheritance tree).", .example = "navgraph hierarchy Store@src/cache.zig --overrides", .aliases = &.{"hier"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .strict, .format, .overrides }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .raises, .name = "raises", .summary = "Trace where a symbol's exceptions are caught, or go uncaught.", .example = "navgraph raises buildOpenDir -d 3", .aliases = &.{"throws"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .depth, .limit, .strict, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .catches, .name = "catches", .summary = "Show what handles a given exception type, and what does not.", .example = "navgraph catches AllocError", .aliases = &.{"handles"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .limit, .strict, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .neighbors, .name = "neighbors", .summary = "Show a symbol's callers and callees in one view.", .example = "navgraph neighbors resolveOne", .aliases = &.{"near"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .depth, .limit, .budget, .max_nodes, .summary, .strict, .format, .refs, .impls }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .unused, .name = "unused", .summary = "Find definitions nothing calls or uses (removal candidates).", .example = "navgraph unused --tests-only --no-public", .aliases = &.{"dead"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .format, .tests, .no_public, .follow_imports }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .imports, .name = "imports", .summary = "List what each file imports.", .example = "navgraph imports src/cli.zig", .arguments = &optional_filter, .options = &.{ .root, .no_cache, .backend, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .importers, .name = "importers", .summary = "List files that import a given file.", .example = "navgraph importers src/model.zig", .arguments = &file_arg, .options = &.{ .root, .no_cache, .backend, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .path, .name = "path", .summary = "Find the shortest call path between two symbols.", .example = "navgraph path parse emit", .arguments = &path_args, .options = &.{ .root, .no_cache, .backend, .verbosity, .strict, .format, .impls }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .flow, .name = "flow", .summary = "Show where a value is written and where it's read.", .example = "navgraph flow diag_msg --to diag", .aliases = &.{"dataflow"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .strict, .format, .writers, .readers, .unread, .on_type, .to }, .conflicts = &flow_conflicts, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .taint, .name = "taint", .summary = "Check whether an untrusted source can reach a sensitive sink.", .example = "navgraph taint request.json --to subprocess.run", .aliases = &.{"security"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .limit, .strict, .format, .to }, .required_options = &.{.to}, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .reaches, .name = "reaches", .summary = "Find everything reachable from one or more symbols.", .example = "navgraph reaches parse,emit", .aliases = &.{"reachable"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .after, .tests, .impls, .from_tests }, .dependencies = &jsonl_after_dependency, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .affected, .name = "affected", .summary = "List tests affected by what changed since a git ref.", .example = "navgraph affected --since HEAD~1", .aliases = &.{"impact"}, .arguments = &optional_ref, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .after, .impls, .since }, .dependencies = &jsonl_after_dependency, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .hot, .name = "hot", .summary = "Rank symbols by fan-in/fan-out (the most depended-on code).", .example = "navgraph hot src --sort fan_out_exact", .aliases = &.{"central"}, .arguments = &optional_path, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .budget, .max_nodes, .summary, .strict, .format, .after, .sort, .tests }, .option_value_overrides = &hot_sort_values, .dependencies = &jsonl_after_dependency, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .diff, .name = "diff", .summary = "List symbols changed since a git ref, and their callers.", .example = "navgraph diff HEAD~1 --exact-source", .aliases = &.{"changed"}, .arguments = &optional_ref, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .budget, .format, .exact_source }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .history, .name = "history", .summary = "Show a symbol's git history.", .example = "navgraph history buildOpenDir --last 10", .aliases = &.{"hist"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .format, .last }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .blame, .name = "blame", .summary = "Show per-line author and commit for a symbol's current code.", .example = "navgraph blame buildOpenDir", .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .churn, .name = "churn", .summary = "Rank symbols by how much their history has changed.", .example = "navgraph churn src --last 50 --sort lines", .arguments = &optional_path, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .format, .sort, .since, .last }, .option_value_overrides = &churn_sort_values, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .collisions, .name = "collisions", .summary = "Find definitions that share the same name.", .example = "navgraph collisions -k struct,fn", .aliases = &.{"duplicates"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .backend, .verbosity, .limit, .format, .kind, .tests, .visibility, .members }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .files, .name = "files", .summary = "List indexed files and their symbol counts.", .example = "navgraph files --sort symbols", .aliases = &.{"manifest"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .backend, .limit, .format, .sort, .no_recurse }, .option_value_overrides = &files_sort_values, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .status, .name = "status", .summary = "Show index freshness, cache state, and any warnings.", .example = "navgraph status", .aliases = &.{"snapshot"}, .arguments = &optional_filter, .options = &.{ .root, .no_cache, .backend, .limit, .format, .after, .no_recurse }, .dependencies = &jsonl_after_dependency, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .read, .name = "read", .summary = "Print a bounded, numbered range of source lines.", .example = "navgraph read src/parser.zig:1-40", .aliases = &.{"cat"}, .arguments = &source_arg, .options = &.{ .root, .no_cache, .limit, .budget, .format, .after }, .outputs = &text_json, .access = .read_only, .requires_index = false, .cache_effect = .none },
    .{ .command = .strings, .name = "strings", .summary = "Search inside string literals (URLs, log text, and the like).", .example = "navgraph strings TODO", .aliases = &.{ "str", "literals" }, .arguments = &pattern_arg, .options = &.{ .root, .no_cache, .backend, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .todos, .name = "todos", .summary = "List TODO/FIXME/HACK comments.", .example = "navgraph todos src", .aliases = &.{"todo"}, .arguments = &optional_path, .options = &.{ .root, .no_cache, .backend, .limit, .format, .after }, .dependencies = &jsonl_after_dependency, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .edits, .name = "edits", .summary = "List the exact source sites a rename would touch.", .example = "navgraph edits buildOpenDir", .aliases = &.{"edit-sites"}, .arguments = &symbol_arg, .options = &.{ .root, .no_cache, .backend, .limit, .format, .after }, .dependencies = &jsonl_after_dependency, .outputs = &text_json_jsonl, .access = .read_only, .requires_index = true },
    .{ .command = .rename, .name = "rename", .summary = "Rename a symbol everywhere it resolves exactly.", .example = "navgraph rename Store.get fetch --preview", .arguments = &rename_args, .options = &.{ .root, .no_cache, .backend, .format, .preview }, .outputs = &text_json, .access = .mutating, .requires_index = true, .server_available = false },
    .{ .command = .coverage, .name = "coverage", .summary = "Estimate test coverage from the call graph (no instrumentation).", .example = "navgraph coverage src", .aliases = &.{"cov"}, .arguments = &optional_path, .options = &.{ .root, .no_cache, .backend, .limit, .format }, .outputs = &text_json, .access = .read_only, .requires_index = true },
    .{ .command = .graph, .name = "graph", .summary = "Render the code graph as an interactive HTML page.", .example = "navgraph graph src --no-tests > graph.html", .aliases = &.{ "viz", "visualize", "html" }, .arguments = &optional_path, .options = &.{ .root, .no_cache, .backend, .limit, .format, .tests }, .outputs = &html_json, .access = .read_only, .requires_index = true },
    .{ .command = .capabilities, .name = "capabilities", .summary = "Print this binary's machine-readable feature manifest.", .example = "navgraph capabilities -j", .aliases = &.{ "version", "--version" }, .arguments = &no_args, .options = &.{.format}, .outputs = &json_only, .access = .metadata, .requires_index = false, .cache_effect = .none },
    .{ .command = .serve, .name = "serve", .summary = "Run a long-lived MCP/JSON-RPC server over stdio.", .example = "navgraph serve -C .", .aliases = &.{"mcp"}, .arguments = &no_args, .options = &.{ .root, .no_cache, .backend }, .outputs = &rpc_only, .access = .server, .requires_index = true, .server_available = false },
    .{ .command = .lsp, .name = "lsp", .summary = "Run a resident editor server (LSP) that stays in memory.", .example = "navgraph lsp -C .", .arguments = &no_args, .options = &.{ .root, .no_cache, .backend, .log, .log_level }, .outputs = &rpc_only, .access = .server, .requires_index = true, .server_available = false },
    .{ .command = .help, .name = "help", .summary = "Show the full command catalogue, or help for one command.", .example = "navgraph help outline", .aliases = &.{ "--help", "-h" }, .arguments = &help_args, .outputs = &text_only, .access = .metadata, .requires_index = false, .server_available = false, .cache_effect = .none },
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
        for (desc.spellings) |spelling| if (std.mem.eql(u8, flag, spelling.flag)) return desc.option;
    }
    return null;
}

/// Options a client appends to every invocation as a matter of course
/// (`-l 200 -j --no-cache`). A command that does not declare one must not turn
/// a previously working call into a usage error: it is accepted, ignored, and
/// reported on stderr. A *command-specific* flag on the wrong command stays a
/// hard error, because it can only be a mistake.
pub fn isGlobalClassOption(option: Option) bool {
    return switch (option) {
        .root, .no_cache, .verbosity, .depth, .limit, .format, .tests, .strict, .refs => true,
        else => false,
    };
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
        try std.testing.expect(desc.spellings.len > 0);
        for (desc.spellings) |spelling| {
            try std.testing.expect((try flags.fetchPut(std.testing.allocator, spelling.flag, {})) == null);
            try std.testing.expectEqual(desc.option, parseOptionFlag(spelling.flag).?);
            try std.testing.expect(spelling.takes_value == (spelling.fixed_value == null));
            if (desc.value_kind == .boolean) {
                try std.testing.expect(!spelling.takes_value);
                try std.testing.expect(spelling.fixed_value.? == .boolean and spelling.fixed_value.?.boolean);
            }
        }
        if (desc.value_separator) |separator| {
            try std.testing.expect(separator.len != 0);
            try std.testing.expect(desc.values.len != 0);
        }
        var applies_to: usize = 0;
        for (&command_descriptors) |command| {
            if (hasOption(command.command, desc.option)) applies_to += 1;
        }
        try std.testing.expect(applies_to > 0);
    }
    for (&command_descriptors) |command| {
        if (command.server_available) try std.testing.expect(command.access == .read_only or command.command == .capabilities);
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
        for (command.dependencies) |dependency| {
            try std.testing.expect(hasOption(command.command, dependency.option));
            try std.testing.expect(hasOption(command.command, dependency.requires));
            try std.testing.expect(dependency.option != dependency.requires);
            if (dependency.required_value) |value| switch (value) {
                .boolean => try std.testing.expect(optionDescriptor(dependency.requires).value_kind == .boolean),
                .string => |expected| {
                    const required = optionDescriptor(dependency.requires);
                    try std.testing.expect(required.value_kind == .enumeration or required.value_kind == .string);
                    var supported = required.values.len == 0;
                    for (required.values) |candidate| {
                        if (std.mem.eql(u8, candidate, expected)) supported = true;
                    }
                    try std.testing.expect(supported);
                },
            };
        }
        for (command.conflicts) |conflict| {
            try std.testing.expect(hasOption(command.command, conflict.first));
            try std.testing.expect(hasOption(command.command, conflict.second));
            try std.testing.expect(conflict.first != conflict.second);
        }
    }
}
