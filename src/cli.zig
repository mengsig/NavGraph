//! Command-line parsing for NavGraph. Turns argv into a `Parsed` request or a
//! usage error. Parsing is intentionally small and explicit — no framework.

const std = @import("std");
const query = @import("query.zig");
const render = @import("render.zig");
const model = @import("model.zig");
const backends = @import("backends.zig");
pub const registry = @import("command_registry.zig");

pub const Command = registry.Command;

pub const Parsed = struct {
    command: Command,
    /// Positional argument: a path (outline), a name (def/calls/callers) or a
    /// pattern (search). Empty when not provided.
    arg: []const u8 = "",
    /// Second positional (only `path <A> <B>` uses it). Empty otherwise.
    arg2: []const u8 = "",
    root: []const u8 = ".",
    /// Whether `-C`/`--root` was given. `lsp` distinguishes an explicit root
    /// (which wins) from the default (which defers to the editor's workspace).
    root_given: bool = false,
    options: query.Options = .{},
    /// Public options explicitly selected by argv. This lets descriptor-driven
    /// applicability reject historical no-op flag combinations without trying
    /// to infer intent from default-valued `query.Options` fields.
    used_options: std.EnumSet(registry.Option) = std.EnumSet(registry.Option).initEmpty(),
    /// Global-class options named on a command that does not declare them.
    /// Accepted and ignored so a client's standard flag set never turns a
    /// working call into a usage error; the CLI reports them on stderr.
    ignored_options: std.EnumSet(registry.Option) = std.EnumSet(registry.Option).initEmpty(),
    /// Use the incremental on-disk cache (`.navgraph/cache`). Disabled by
    /// `--no-cache` for a guaranteed-clean rebuild.
    use_cache: bool = true,
    /// Parser backend (`--backend`). `auto` follows the per-language table in
    /// `backends.zig`; `tree-sitter` forces a grammar wherever one is linked in.
    backend: backends.Choice = .auto,
    /// `lsp` only: where to write diagnostics (stderr when empty) and how
    /// much. stdout is the protocol channel and never carries logging.
    log_path: []const u8 = "",
    log_level: []const u8 = "error",
};

pub const ParseError = error{ Usage, UnknownFlag, MissingValue, BadValue };

/// Detail for the last `parse()` error: one preformatted line naming the
/// offending token and the expected form, so the CLI can print a precise,
/// single-line message instead of a generic reason plus the full help text
/// (a ~75-line dump per typo an agent pays for in tokens). Threadlocal so
/// parallel tests never race; read right after a failed parse.
threadlocal var diag_buf: [192]u8 = undefined;
threadlocal var diag_msg: []const u8 = "";

pub fn diag() []const u8 {
    return diag_msg;
}

/// Record a diagnostic and return the error (single-expression error paths).
fn fail(err: ParseError, comptime fmt: []const u8, args: anytype) ParseError {
    diag_msg = std.fmt.bufPrint(&diag_buf, fmt, args) catch fmt;
    return err;
}

const usage_text =
    \\NavGraph — a code-graph navigator for agents.
    \\
    \\USAGE: navgraph <command> [arg] [flags]
    \\
    \\COMMANDS:
    \\  outline [path]     Outline symbols in a file/dir (default: whole project)
    \\  def <name>         Show a definition (supports Parent.name, name@path)
    \\  docs <name>        Show indexed docstrings/leading documentation
    \\  calls <name>       Symbols that <name> calls/uses (callees), as a tree
    \\  callers <name>     Symbols that call/use <name> (callers), as a tree
    \\  search <pattern>   Find symbols by name (or use sites with --refs;
    \\                     Recv.field / .field pins instance-attribute reads)
    \\  routes [filter]    HTTP routes; mounted FastAPI prefixes are applied before
    \\                     cross-language client calls are linked
    \\  conforms <selector> Audit protocol implementations or sibling signature
    \\                     divergence (aliases: impls, implements)
    \\  hierarchy <Type>   Nominal supertypes/MRO and transitive subtypes; --overrides maps methods
    \\  raises <symbol>    Direct/transitive exceptions and their nearest handler or unhandled gap
    \\  catches <Error>    Matching handlers plus handled/unhandled raise sites
    \\  events [filter]    Link bus/broker handlers to emitters; filters common DOM listeners
    \\  neighbors <name>   Callees and callers of <name> in one view
    \\  unused [filter]    Unreferenced definitions (fns/methods & types) nothing calls
    \\                     or uses — i.e. removal candidates, NOT broken code. Default
    \\                     lists the truly unused (no caller in app OR test code);
    \\                     --no-tests also lists code used only by tests (annotated);
    \\                     --tests-only lists unused test helpers; --no-public drops
    \\                     exported symbols (may be public API)
    \\  imports [filter]   Modules each file imports (local dependency edges)
    \\  importers <file>   Files that import <file>
    \\  path <A> <B>       Shortest call path from <A> to <B>
    \\  flow <symbol>      Initializers/writers and readers; warns on ambiguity; --to traces a sink
    \\  taint <source>     Security source-to-sink reachability (requires --to <sink>)
    \\  reaches <A,B,...>  Transitive reachable set; --from-tests selects exercising tests
    \\  affected [ref]     Tests affected since a git ref (or use --since; default HEAD)
    \\  collisions [pat]   Group duplicate definition names (alias: duplicates)
    \\  diff [ref]         Symbols changed since <ref> (default HEAD) + their callers
    \\  history <symbol>   Symbol-level git history/signature patches (default: last 10)
    \\  blame <symbol>     Per-line author/commit provenance for a symbol
    \\  churn [path]       Rank symbols by historical commits or added/removed lines
    \\  hot [path]         Rank functions by fan-in/out; hints --no-tests when tests dominate
    \\  files [filter]     List every indexed file + its symbol count (index coverage);
    \\                     add --sort symbols to rank biggest-first
    \\  status [filter]    Index/cache snapshot, freshness, skipped paths, and diagnostics
    \\  read <file[:A-B]>  Bounded raw source page; batch ranges: file:A-B,C-D;
    \\                     continue truncated pages with --after v1:N
    \\  strings <pattern>  Search inside string literals (URLs, log/error text, regexes)
    \\  todos [path]       TODO/FIXME/HACK markers from real comments only
    \\  edits <symbol>     Exact definition/reference sites for a safe rename
    \\  rename <sym> <new> Apply a collision-checked rename; --preview emits its patch
    \\  coverage [path]    % of fn/method reachable from a test (call-graph, no instrumentation)
    \\  graph [path]       Interactive HTML visualization of the code graph
    \\                     (redirect stdout to a .html file; -j emits the raw JSON model)
    \\  capabilities       Machine-readable protocol, build, language, command,
    \\                     option, output, safety, and trust metadata (alias: version)
    \\  serve             Long-lived JSON-RPC/MCP server over stdin/stdout
    \\  lsp                Resident editor server (LSP over stdio): keeps the graph
    \\                     in memory and answers blast/search/call queries in
    \\                     milliseconds. See docs/lsp.md
    \\  help [command]     Full catalogue or concise help for one command
    \\
    \\FLAGS (command-scoped; run `navgraph help <command>` for the exact set):
    \\  -v, --verbosity <names|sig|doc|full>   Detail level (default: sig)
    \\  -d, --depth <N>                        Graph depth for calls/callers/raises (default: 1)
    \\  -C, --root <path>                      Index root: a directory, or a single
    \\                                         file to scope to it (default: .)
    \\  -l, --limit <N>                        Max results (default: 300)
    \\  --budget <bytes> / --max-nodes <N>     Hard stdout-byte / graph-node bounds
    \\  --since <ref> / --from-tests           Affected/churn history and reaches selectors
    \\  --last <N>                             history/churn commit bound (default: 10)
    \\  --preview                              rename: emit patch without writing files
    \\  --exact-source                         diff: include source ranges and raw git patch
    \\  -k, --kind <k1,k2>                     Restrict outline/search to kinds (fn,struct,…)
    \\  -p, --vis <public|private|all>          Visibility for outline/search/def (default: all)
    \\  --public, --private, --no-private       Visibility shortcuts
    \\  --sort <key>                         files: path|symbols; outline/search:
    \\                                         line|name|span|callers|callees; hot:
    \\                                         fan_in|fan_in_exact|fan_out|fan_out_exact|span;
    \\                                         churn: commits|lines
    \\  -w, --writers / --readers             flow/search --refs: access direction
    \\  -u, --unread                          Keep written-but-never-read data
    \\  --on-type <Type>                      Type-scope member flow/reference hits
    \\  --to <sink>                           flow/taint: trace to a consumer or security sink
    \\  --duplicates                         search: group duplicate definitions
    \\  --members                            collisions: include class members
    \\  -r, --refs                             search: match use sites; calls/neighbors: include var/const/field reads
    \\  -e, --exact                            search: name must equal the pattern
    \\                                         (finds `Order` without every `createOrder`)
    \\  --no-recurse                           outline/files/status: only files directly in the
    \\                                         given dir, not its subtrees
    \\  -t, --tests <with|without|only>        Unified test-scope for outline/search/
    \\                                         callers/hot/unused: with (default) |
    \\                                         without | only. A test is a Zig `test`
    \\                                         block, a test_* fn, or a test-dir file.
    \\  --no-tests, --tests-only               Shortcuts for --tests without / --tests only.
    \\  -s, --strict                           Follow only exact edges; drops inferred,
    \\                                         heuristic `?`, and structural impl edges
    \\  -i, --impls                            calls/callers/neighbors/path: cross
    \\                                         protocol/interface implementation edges
    \\  --overrides                            hierarchy: include per-method override map
    \\  --clients                              routes: show resolved client call sites
    \\  --unhit                                routes: show routes with no client calls
    \\  --orphan-calls, --orphan, --orphans    routes: show calls matching no route
    \\  --handler <name>                       routes: select by handler (glob accepted)
    \\  -j, --json                             Emit JSON (stable, for tooling/MCP)
    \\  --jsonl [--after v1:N]                 Stream stable, cursor-pageable JSON rows;
    \\                                         read accepts --after in text or JSON
    \\  --no-cache                             Ignore the .navgraph/cache and rebuild
    \\  --backend <auto|heuristic|tree-sitter> Symbol-extraction backend (default auto)
    \\  --no-public                            unused: drop exported symbols (possible public API)
    \\  --follow-imports                       unused: disambiguate same-name symbols by
    \\                                         import reachability (finds unused code masked
    \\                                         by a used same-name twin; needs import resolution)
    \\  --log <file>                           lsp: write diagnostics to <file> (default: stderr)
    \\  --log-level <error|info|debug>         lsp: diagnostic verbosity (default: error)
    \\
    \\  Locations are `path:line-endLine`; call trees annotate each edge with its
    \\  call-site line as `↳:N`, `⇒impl` marks a protocol implementation edge,
    \\  and a trailing `?` marks a heuristic edge — verify those or use `-s` to
    \\  drop them. A `navgraph: parse-health:` stderr warning means tokenizer
    \\  desynchronization may have hidden symbols in the reported line range.
    \\  Flag values may be attached (`-d2`, `--depth=2`). Use `--` before a
    \\  positional value beginning with `-` (for example `strings -- --no-tests`).
    \\
    \\  PATTERNS: a name/filter containing `*` is a glob (`def Ba*`, `search *_handler`,
    \\  `callers Matcher.is*`). Globs anchor on the whole name; without `*`, names
    \\  substring-match and defs match exactly. Path filters glob gitignore-style:
    \\  `files *_test.py` (basename, any depth), `outline src/**/*.ts` (full path).
    \\
    \\  IGNORES: `.gitignore` is respected everywhere; a `.navgraphignore` (same
    \\  syntax, per-directory) adds navgraph-only rules, and its `!dir/` re-includes
    \\  a directory the built-in skip set (node_modules, vendor, venv, …) prunes.
    \\
    \\EXAMPLES:
    \\  navgraph outline src/parser.zig --kind fn
    \\  navgraph def parseZigScope -v full
    \\  navgraph calls build@build.zig -d 2
    \\  navgraph callers collectRefs
    \\  navgraph search resolve --refs
    \\  navgraph neighbors resolveOne
    \\  navgraph unused                            # truly-unused code (removal candidates)
    \\  navgraph unused --tests-only --no-public   # unused private test helpers
    \\  navgraph callers parse --tests-only        # which tests exercise parse
    \\  navgraph outline src --no-tests            # production structure only
    \\  navgraph coverage src                      # test reach per file
    \\  navgraph graph src --no-tests > graph.html # visualize the production graph
    \\  navgraph callers Store.get --impls      # cross port dispatch to implementations
    \\  navgraph conforms Store                 # audit impl signatures/asyncness
    \\  navgraph outline src --public           # hide non-public symbols
    \\  navgraph routes /v1/orders --clients    # resolved cross-language clients
    \\  navgraph routes --unhit                 # endpoints with no resolved client
    \\  navgraph routes --orphan-calls          # calls with no serving route
    \\  navgraph path parse emit
    \\  navgraph affected --since HEAD~1       # run only impacted tests
    \\  navgraph reaches parse,emit             # set reachability
    \\  navgraph calls build -d3 --max-nodes 40 --summary
    \\  navgraph rename Store.get fetch --preview
    \\  navgraph todos src
    \\  navgraph search parse --jsonl --limit 50
    \\  navgraph lsp -C .                       # editor server (Neovim, VS Code)
    \\
;

pub fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(usage_text);
}

/// Concise command help generated from the same registry that validates argv
/// and publishes capabilities. Agents can recover from a scoped flag error
/// without paying for (or guessing from) the full command catalogue.
pub fn usageCommand(w: *std.Io.Writer, name: []const u8) !bool {
    const command = registry.parseCommand(name) orelse return false;
    const desc = registry.descriptor(command);
    try w.print("NavGraph command: {s}\n\nUSAGE: navgraph {s}", .{ desc.name, desc.name });
    for (desc.arguments) |argument| {
        if (argument.required) {
            try w.print(" <{s}>", .{argument.name});
        } else {
            try w.print(" [{s}]", .{argument.name});
        }
    }
    if (desc.options.len != 0) try w.writeAll(" [options]");
    try w.writeByte('\n');

    if (desc.aliases.len != 0) {
        try w.writeAll("ALIASES: ");
        for (desc.aliases, 0..) |alias, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(alias);
        }
        try w.writeByte('\n');
    }
    try w.print("ACCESS: {s}\nOUTPUT: ", .{@tagName(desc.access)});
    for (desc.outputs, 0..) |output, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeAll(@tagName(output));
    }
    try w.writeByte('\n');

    if (desc.arguments.len != 0) {
        try w.writeAll("ARGUMENTS:\n");
        for (desc.arguments) |argument| {
            try w.print("  {s}  {s}; {s}\n", .{
                argument.name,
                @tagName(argument.kind),
                if (argument.required) "required" else "optional",
            });
        }
    }
    if (desc.options.len != 0) {
        try w.writeAll("OPTIONS:\n");
        for (desc.options) |option| {
            const option_desc = registry.optionDescriptor(option);
            try w.writeAll("  ");
            if (option == .format) {
                try w.writeAll("-j, --json");
                if (registry.supportsOutput(desc.command, .jsonl)) try w.writeAll(" | --jsonl");
                if (desc.outputs.len == 1 and desc.outputs[0] == .json) {
                    try w.writeAll("  (JSON is always emitted)\n");
                } else if (registry.supportsOutput(desc.command, .html)) {
                    try w.writeAll("  (html is the default)\n");
                } else {
                    try w.writeAll("  (text is the default)\n");
                }
                continue;
            }
            if (option == .tests) {
                try w.writeAll("-t, --tests <with|without|only>; --no-tests; --tests-only\n");
                continue;
            }
            if (option == .visibility) {
                try w.writeAll("-p, --vis <all|public|private>; --public; --private; --no-private\n");
                continue;
            }
            for (option_desc.spellings, 0..) |spelling, i| {
                if (i != 0) try w.writeAll(", ");
                try w.writeAll(spelling.flag);
            }
            const values = commandOptionValues(desc, option);
            if (option_desc.value_kind != .boolean) {
                try w.writeAll(" <");
                if (values.len != 0) {
                    for (values, 0..) |value, i| {
                        if (i != 0) try w.writeByte('|');
                        try w.writeAll(value);
                    }
                } else {
                    try w.writeAll(switch (option_desc.value_kind) {
                        .integer => "N",
                        .cursor => "v1:N",
                        .string => "value",
                        .enumeration => "value",
                        .boolean => unreachable,
                    });
                }
                try w.writeByte('>');
            }
            if (option_desc.minimum) |minimum| try w.print("  (min {d})", .{minimum});
            if (option_desc.value_separator) |separator| try w.print("  (repeat with '{s}')", .{separator});
            try w.writeByte('\n');
        }
    }
    try w.writeAll("\nMachine contract: navgraph capabilities\n");
    return true;
}

fn commandOptionValues(desc: *const registry.CommandDescriptor, option: registry.Option) []const []const u8 {
    for (desc.option_value_overrides) |override| {
        if (override.option == option) return override.values;
    }
    return registry.optionDescriptor(option).values;
}

/// A short human explanation for a parse failure, shown before the usage text.
pub fn reason(err: ParseError) []const u8 {
    return switch (err) {
        error.Usage => "expected a command and (for most commands) an argument",
        error.UnknownFlag => "unknown flag",
        error.MissingValue => "a flag is missing its value (e.g. `-d 2`, `-d2`, or `--depth=2`)",
        error.BadValue => "invalid flag value (expected a number or a known keyword)",
    };
}

/// Parse argv (excluding the program name at index 0).
pub fn parse(args: []const [:0]const u8) ParseError!Parsed {
    diag_msg = "";
    if (args.len == 0) return error.Usage;
    const command = registry.parseCommand(args[0]) orelse {
        if (args[0].len != 0 and args[0][0] == '-') {
            return fail(error.Usage, "flags go after the command: navgraph <command> [arg] [flags]", .{});
        }
        return fail(error.Usage, "unknown command '{s}' — run `navgraph help` for the list", .{args[0]});
    };
    if (command == .help) return parseHelp(args);

    const command_descriptor = registry.descriptor(command);
    var result = Parsed{ .command = command };
    var i: usize = 1;
    var positional_only = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!positional_only and std.mem.eql(u8, a, "--")) {
            positional_only = true;
        } else if (!positional_only and a.len != 0 and a[0] == '-') {
            i = try parseFlag(args, i, &result);
        } else if (result.arg.len == 0 and command_descriptor.arguments.len >= 1) {
            result.arg = a;
        } else if (result.arg2.len == 0 and command_descriptor.arguments.len >= 2) {
            result.arg2 = a;
        } else {
            return fail(error.Usage, "unexpected extra argument '{s}'", .{a});
        }
    }
    // `navgraph search --help` — the help flag overrides the command wholesale.
    if (result.command == .help) return .{ .command = .help, .arg = registry.descriptor(command).name };
    if (!hasRequiredArgs(command, result)) {
        if (command == .path) return fail(error.Usage, "path needs two symbol names: navgraph path <A> <B>", .{});
        if (command == .rename) return fail(error.Usage, "rename needs a selector and new name: navgraph rename <symbol> <new-name> [--preview]", .{});
        return fail(error.Usage, "{s} needs an argument: navgraph {s} <arg> [flags]", .{ @tagName(command), @tagName(command) });
    }
    try validateCommandOptions(&result);
    return result;
}

/// `help [command] [flags]`. Global-class flags are accepted and ignored here
/// like on every other command, so a client's standard argv keeps working; a
/// command-specific flag is still a usage error.
fn parseHelp(args: []const [:0]const u8) ParseError!Parsed {
    var out = Parsed{ .command = .help };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len != 0 and a[0] == '-') {
            i = try parseFlag(args, i, &out);
            // `-h`/`--help` on `help` is still just `help`.
            out.command = .help;
            continue;
        }
        if (out.arg.len != 0) return fail(error.Usage, "help accepts at most one command name", .{});
        const target = registry.parseCommand(a) orelse
            return fail(error.Usage, "unknown command '{s}' — run `navgraph help` for the list", .{a});
        out.arg = registry.descriptor(target).name;
    }
    try validateCommandOptions(&out);
    return out;
}

/// Kept as a narrow local wrapper for parser tests and callers that audit the
/// CLI module; spelling truth lives in `command_registry.zig`.
fn parseCommand(s: []const u8) ?Command {
    return registry.parseCommand(s);
}

/// Whether `command` has the positional arguments it requires. `outline`,
/// `routes`, `events`, `unused` and `imports` accept an optional filter; `path`
/// needs two.
fn hasRequiredArgs(command: Command, p: Parsed) bool {
    const arguments = registry.descriptor(command).arguments;
    if (arguments.len >= 1 and arguments[0].required and p.arg.len == 0) return false;
    if (arguments.len >= 2 and arguments[1].required and p.arg2.len == 0) return false;
    return true;
}

/// Parse a flag at index `i`, returning the index of the last token consumed.
/// Value-taking flags accept the value attached (`-d2`, `--depth=2`) or as the
/// next token (`-d 2`). Boolean flags reject an attached value.
fn parseFlag(args: []const [:0]const u8, i: usize, out: *Parsed) ParseError!usize {
    const raw = args[i];
    const f = splitFlag(raw);

    if (eqAny(f.name, &.{ "-v", "--verbosity" })) {
        out.used_options.insert(.verbosity);
        const val = try f.value(args, i, f.name);
        out.options.verbosity = render.Verbosity.parse(val) orelse
            return fail(error.BadValue, "invalid value '{s}' for -v/--verbosity (expected names|sig|doc|full)", .{val});
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-d", "--depth" })) {
        out.used_options.insert(.depth);
        out.options.depth = try parseUint(try f.value(args, i, f.name), "-d/--depth");
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-l", "--limit" })) {
        out.used_options.insert(.limit);
        out.options.limit_set = true;
        out.options.limit = try parseUint(try f.value(args, i, f.name), "-l/--limit");
        if (out.options.limit == 0)
            return fail(error.BadValue, "-l/--limit must be at least 1", .{});
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "--budget", "--max-nodes" })) {
        out.used_options.insert(if (std.mem.eql(u8, f.name, "--budget")) .budget else .max_nodes);
        const value = try parseUint(try f.value(args, i, f.name), f.name);
        if (std.mem.eql(u8, f.name, "--budget") and value < 64)
            return fail(error.BadValue, "--budget must be at least 64 bytes (enough for valid truncation metadata)", .{});
        if (std.mem.eql(u8, f.name, "--max-nodes") and value == 0)
            return fail(error.BadValue, "--max-nodes must be at least 1", .{});
        if (std.mem.eql(u8, f.name, "--budget")) out.options.budget = value else out.options.max_nodes = value;
        return f.next(i);
    }
    if (std.mem.eql(u8, f.name, "--after")) {
        out.used_options.insert(.after);
        out.options.after = try parseCursor(try f.value(args, i, f.name));
        out.options.after_set = true;
        return f.next(i);
    }
    if (std.mem.eql(u8, f.name, "--since")) {
        out.used_options.insert(.since);
        out.options.since = try f.value(args, i, f.name);
        return f.next(i);
    }
    if (std.mem.eql(u8, f.name, "--last")) {
        out.used_options.insert(.last);
        out.options.history_last = try parseUint(try f.value(args, i, f.name), "--last");
        if (out.options.history_last == 0) return fail(error.BadValue, "--last must be at least 1", .{});
        out.options.history_last_set = true;
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-C", "--root" })) {
        out.used_options.insert(.root);
        out.root = try f.value(args, i, f.name);
        out.root_given = true;
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-k", "--kind" })) {
        out.used_options.insert(.kind);
        const val = try f.value(args, i, f.name);
        var it = std.mem.tokenizeScalar(u8, val, ',');
        while (it.next()) |raw_kind| {
            const t = std.mem.trim(u8, raw_kind, " ");
            if (!model.SymbolKind.validName(t))
                return fail(error.BadValue, "unknown kind '{s}' for -k (run `navgraph help outline` for the published values)", .{t});
        }
        out.options.kinds = val;
        return f.next(i);
    }
    if (eqAny(f.name, &.{"--sort"})) {
        out.used_options.insert(.sort);
        const val = try f.value(args, i, f.name);
        if (out.command == .files) {
            out.options.file_sort = query.FileSort.parse(val) orelse
                return fail(error.BadValue, "invalid files --sort '{s}' (expected path|symbols)", .{val});
        } else if (out.command == .churn) {
            out.options.churn_sort = query.ChurnSort.parse(val) orelse
                return fail(error.BadValue, "invalid churn --sort '{s}' (expected commits|lines)", .{val});
        } else {
            out.options.sort = query.SortKey.parse(val) orelse
                return fail(error.BadValue, "invalid ranking --sort '{s}'", .{val});
        }
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "--on-type", "--to" })) {
        out.used_options.insert(if (std.mem.eql(u8, f.name, "--on-type")) .on_type else .to);
        const val = try f.value(args, i, f.name);
        if (std.mem.eql(u8, f.name, "--on-type")) out.options.on_type = val else out.options.flow_to = val;
        return f.next(i);
    }
    if (eqAny(f.name, &.{"--log"})) {
        out.used_options.insert(.log);
        out.log_path = try f.value(args, i, f.name);
        return f.next(i);
    }
    if (eqAny(f.name, &.{"--log-level"})) {
        out.used_options.insert(.log_level);
        out.log_level = try f.value(args, i, f.name);
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-t", "--tests" })) {
        out.used_options.insert(.tests);
        const val = try f.value(args, i, f.name);
        out.options.tests = query.TestScope.parse(val) orelse
            return fail(error.BadValue, "invalid value '{s}' for -t/--tests (expected with|without|only)", .{val});
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-p", "--vis" })) {
        out.used_options.insert(.visibility);
        const val = try f.value(args, i, f.name);
        out.options.visibility = query.Vis.parse(val) orelse
            return fail(error.BadValue, "invalid value '{s}' for -p/--vis (expected public|private|all)", .{val});
        return f.next(i);
    }
    if (std.mem.eql(u8, f.name, "--handler")) {
        out.used_options.insert(.handler);
        out.options.routes_handler = try f.value(args, i, f.name);
        return f.next(i);
    }
    // Boolean flags: an attached `=value` is a usage error.
    if (f.inline_val != null)
        return fail(error.BadValue, "flag {s} takes no value", .{f.name});
    if (eqAny(f.name, &.{"--no-tests"})) {
        out.used_options.insert(.tests);
        out.options.tests = .without;
        return i;
    }
    if (eqAny(f.name, &.{"--tests-only"})) {
        out.used_options.insert(.tests);
        out.options.tests = .only;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--summary")) {
        out.used_options.insert(.summary);
        out.options.summary = true;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--from-tests")) {
        out.used_options.insert(.from_tests);
        out.options.from_tests = true;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--preview")) {
        out.used_options.insert(.preview);
        out.options.preview = true;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--exact-source")) {
        out.used_options.insert(.exact_source);
        out.options.exact_source = true;
        return i;
    }
    if (eqAny(f.name, &.{ "-i", "--impls" })) {
        out.used_options.insert(.impls);
        out.options.impls = true;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--overrides")) {
        out.used_options.insert(.overrides);
        out.options.hierarchy_overrides = true;
        return i;
    }
    if (eqAny(f.name, &.{ "--public", "--no-private" })) {
        out.used_options.insert(.visibility);
        out.options.visibility = .public;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--private")) {
        out.used_options.insert(.visibility);
        out.options.visibility = .private;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--clients")) {
        out.used_options.insert(.clients);
        out.options.routes_clients = true;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--unhit")) {
        out.used_options.insert(.unhit);
        out.options.routes_unhit = true;
        return i;
    }
    if (eqAny(f.name, &.{ "--orphan-calls", "--orphan", "--orphans" })) {
        out.used_options.insert(.orphan_calls);
        out.options.routes_orphan_calls = true;
        return i;
    }
    if (eqAny(f.name, &.{ "-w", "--writers" })) {
        out.used_options.insert(.writers);
        out.options.writers = true;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--readers")) {
        out.used_options.insert(.readers);
        out.options.readers = true;
        return i;
    }
    if (eqAny(f.name, &.{ "-u", "--unread" })) {
        out.used_options.insert(.unread);
        out.options.unread = true;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--duplicates")) {
        out.used_options.insert(.duplicates);
        out.options.duplicates = true;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--members")) {
        out.used_options.insert(.members);
        out.options.collision_members = true;
        return i;
    }
    if (eqAny(f.name, &.{ "-s", "--strict" })) {
        out.used_options.insert(.strict);
        out.options.strict = true;
        return i;
    }
    if (eqAny(f.name, &.{ "-j", "--json" })) {
        out.used_options.insert(.format);
        if (out.options.format == .jsonl) return fail(error.Usage, "--json and --jsonl are mutually exclusive", .{});
        out.options.format = .json;
        return i;
    }
    if (std.mem.eql(u8, f.name, "--jsonl")) {
        out.used_options.insert(.format);
        if (out.options.format == .json) return fail(error.Usage, "--json and --jsonl are mutually exclusive", .{});
        out.options.format = .jsonl;
        return i;
    }
    if (eqAny(f.name, &.{ "-r", "--refs" })) {
        out.used_options.insert(.refs);
        out.options.refs = true;
        return i;
    }
    if (eqAny(f.name, &.{ "-e", "--exact" })) {
        out.used_options.insert(.exact);
        out.options.exact = true;
        return i;
    }
    if (eqAny(f.name, &.{"--no-recurse"})) {
        out.used_options.insert(.no_recurse);
        out.options.no_recurse = true;
        return i;
    }
    if (eqAny(f.name, &.{"--no-cache"})) {
        out.used_options.insert(.no_cache);
        out.use_cache = false;
        return i;
    }
    if (eqAny(f.name, &.{"--backend"})) {
        out.used_options.insert(.backend);
        const v = try f.value(args, i, "--backend");
        out.backend = backends.Choice.fromName(v) orelse
            return fail(error.BadValue, "--backend expects auto, heuristic or tree-sitter (got '{s}')", .{v});
        if (!backends.available(out.backend))
            return fail(error.BadValue, "--backend tree-sitter: this build links no grammars (build with -Dtree-sitter=all)", .{});
        return f.next(i);
    }
    if (eqAny(f.name, &.{"--no-public"})) {
        out.used_options.insert(.no_public);
        out.options.unused_skip_exported = true;
        return i;
    }
    if (eqAny(f.name, &.{"--follow-imports"})) {
        out.used_options.insert(.follow_imports);
        out.options.unused_follow_imports = true;
        return i;
    }
    // `navgraph <cmd> --help` — everyone types it eventually; make it work.
    if (eqAny(f.name, &.{ "-h", "--help" })) {
        out.command = .help;
        return i;
    }
    return fail(error.UnknownFlag, "unknown flag '{s}' — run `navgraph help` for the list", .{raw});
}

/// A flag token split into its name and an optional attached value. Handles both
/// `--long=value` and short `-dVALUE` (name is the first two chars, `-d`).
const SplitFlag = struct {
    name: []const u8,
    inline_val: ?[]const u8,

    /// The flag's value: the attached one if present, else the next token.
    fn value(self: SplitFlag, args: []const [:0]const u8, i: usize, flag: []const u8) ParseError![]const u8 {
        if (self.inline_val) |v| {
            if (v.len == 0) return fail(error.MissingValue, "flag {s} is missing its value", .{flag});
            return v;
        }
        if (i + 1 >= args.len) return fail(error.MissingValue, "flag {s} is missing its value", .{flag});
        return args[i + 1];
    }

    /// Index of the last consumed token: `i` when the value was attached, else
    /// `i + 1` (the separate value token).
    fn next(self: SplitFlag, i: usize) usize {
        return if (self.inline_val != null) i else i + 1;
    }
};

fn splitFlag(raw: []const u8) SplitFlag {
    if (std.mem.startsWith(u8, raw, "--")) {
        if (std.mem.indexOfScalar(u8, raw, '=')) |eq| {
            return .{ .name = raw[0..eq], .inline_val = raw[eq + 1 ..] };
        }
        return .{ .name = raw, .inline_val = null };
    }
    // Short flag with an attached value: `-d2`, `-lC` etc. (name = first 2 chars).
    if (raw.len > 2 and raw[0] == '-') {
        return .{ .name = raw[0..2], .inline_val = raw[2..] };
    }
    return .{ .name = raw, .inline_val = null };
}

fn validateCommandOptions(parsed: *Parsed) ParseError!void {
    const opts = parsed.options;
    inline for (std.meta.fields(registry.Option)) |field| {
        const option = @field(registry.Option, field.name);
        if (parsed.used_options.contains(option) and !registry.hasOption(parsed.command, option)) {
            if (!registry.isGlobalClassOption(option))
                return fail(error.Usage, "option '{s}' does not apply to {s}", .{ registry.optionDescriptor(option).name, @tagName(parsed.command) });
            parsed.ignored_options.insert(option);
        }
    }
    for (registry.descriptor(parsed.command).required_options) |option| {
        if (!parsed.used_options.contains(option)) {
            return fail(error.Usage, "{s} requires option '{s}'", .{ @tagName(parsed.command), registry.optionDescriptor(option).name });
        }
    }
    for (registry.descriptor(parsed.command).dependencies) |dependency| {
        if (!parsed.used_options.contains(dependency.option)) continue;
        const trigger = registry.optionDescriptor(dependency.option).name;
        const required = registry.optionDescriptor(dependency.requires).name;
        if (!parsed.used_options.contains(dependency.requires)) {
            return fail(error.Usage, "option '{s}' requires option '{s}'", .{ trigger, required });
        }
        if (dependency.required_value) |expected| {
            if (!optionMatchesValue(parsed.*, dependency.requires, expected)) {
                return fail(error.Usage, "option '{s}' requires option '{s}' to have the advertised value", .{ trigger, required });
            }
        }
    }
    for (registry.descriptor(parsed.command).conflicts) |conflict| {
        if (parsed.used_options.contains(conflict.first) and parsed.used_options.contains(conflict.second)) {
            return fail(error.Usage, "options '{s}' and '{s}' are mutually exclusive", .{
                registry.optionDescriptor(conflict.first).name,
                registry.optionDescriptor(conflict.second).name,
            });
        }
    }
    if (opts.impls and parsed.command != .calls and parsed.command != .callers and
        parsed.command != .neighbors and parsed.command != .path and parsed.command != .reaches and parsed.command != .affected)
    {
        return fail(error.Usage, "-i/--impls applies only to calls, callers, neighbors, path, reaches, and affected", .{});
    }
    if (opts.hierarchy_overrides and parsed.command != .hierarchy)
        return fail(error.Usage, "--overrides applies only to hierarchy", .{});
    const route_flags = opts.routes_clients or opts.routes_unhit or opts.routes_orphan_calls or opts.routes_handler.len != 0;
    if (route_flags and parsed.command != .routes)
        return fail(error.Usage, "route view flags apply only to the routes command", .{});
    if (opts.routes_orphan_calls and (opts.routes_clients or opts.routes_unhit or opts.routes_handler.len != 0))
        return fail(error.Usage, "--orphan-calls cannot be combined with --clients, --unhit, or --handler", .{});
    const vis_set = opts.visibility != .all;
    if (vis_set and parsed.command != .outline and parsed.command != .search and parsed.command != .def and parsed.command != .collisions)
        return fail(error.Usage, "visibility flags apply only to outline, search, def, and collisions", .{});
    if (opts.writers and opts.readers)
        return fail(error.Usage, "--writers and --readers are mutually exclusive", .{});
    const flow_filter = opts.writers or opts.readers or opts.unread or opts.on_type.len != 0;
    if (flow_filter and parsed.command != .flow and !(parsed.command == .search and opts.refs))
        return fail(error.Usage, "flow filters apply only to flow or search --refs", .{});
    if (opts.flow_to.len != 0 and parsed.command != .flow and parsed.command != .taint)
        return fail(error.Usage, "--to applies only to flow and taint", .{});
    if (opts.from_tests and parsed.command != .reaches)
        return fail(error.Usage, "--from-tests applies only to reaches", .{});
    if (opts.since.len != 0 and parsed.command != .affected and parsed.command != .churn)
        return fail(error.Usage, "--since applies only to affected and churn", .{});
    if (opts.history_last_set and parsed.command != .history and parsed.command != .churn)
        return fail(error.Usage, "--last applies only to history and churn", .{});
    if (opts.preview and parsed.command != .rename)
        return fail(error.Usage, "--preview applies only to rename", .{});
    if (opts.exact_source and parsed.command != .diff)
        return fail(error.Usage, "--exact-source applies only to diff", .{});
    const compact = opts.max_nodes != 0 or opts.summary;
    const compact_command = parsed.command == .calls or parsed.command == .callers or parsed.command == .neighbors or parsed.command == .read or
        parsed.command == .outline or parsed.command == .search or parsed.command == .hot or
        parsed.command == .reaches or parsed.command == .affected;
    if (compact and !compact_command)
        return fail(error.Usage, "--max-nodes/--summary require a traversal or ranked listing", .{});
    // Applicability is lenient for global-class flags, but a command that cannot
    // emit a format at all must still refuse it — that is an output-mode error.
    if (opts.format == .json and !registry.supportsOutput(parsed.command, .json))
        return fail(error.Usage, "--json is not an output mode for {s}", .{@tagName(parsed.command)});
    if (opts.format == .jsonl and !registry.supportsOutput(parsed.command, .jsonl))
        return fail(error.Usage, "--jsonl is supported by outline, search, hot, todos, reaches, affected, edits, and status", .{});
    if (opts.after_set and opts.format != .jsonl and parsed.command != .read)
        return fail(error.Usage, "--after requires --jsonl (except for read pages)", .{});
    if (opts.duplicates and (parsed.command != .search or opts.refs))
        return fail(error.Usage, "--duplicates applies only to definition search", .{});
    if (opts.collision_members and parsed.command != .collisions)
        return fail(error.Usage, "--members applies only to collisions", .{});
    if (opts.sort != .default) {
        if (parsed.command != .outline and parsed.command != .search and parsed.command != .hot)
            return fail(error.Usage, "ranking --sort applies only to outline, search, and hot", .{});
        if (parsed.command == .hot and (opts.sort == .line or opts.sort == .name or opts.sort == .callers or opts.sort == .callees))
            return fail(error.BadValue, "hot --sort expects fan_in|fan_in_exact|fan_out|fan_out_exact|span", .{});
        if (parsed.command != .hot and (opts.sort == .fan_in or opts.sort == .fan_in_exact or opts.sort == .fan_out or opts.sort == .fan_out_exact))
            return fail(error.BadValue, "outline/search --sort expects line|name|span|callers|callees", .{});
    }
}

fn optionMatchesValue(parsed: Parsed, option: registry.Option, expected: registry.FixedValue) bool {
    return switch (expected) {
        .boolean => |value| switch (option) {
            .refs => parsed.options.refs == value,
            else => false,
        },
        .string => |value| switch (option) {
            .format => std.mem.eql(u8, @tagName(parsed.options.format), value),
            else => false,
        },
    };
}

fn parseCursor(s: []const u8) ParseError!u32 {
    if (!std.mem.startsWith(u8, s, "v1:"))
        return fail(error.BadValue, "invalid cursor '{s}' (expected v1:<ordinal>)", .{s});
    return parseUint(s[3..], "--after");
}

fn parseUint(s: []const u8, flag: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch
        fail(error.BadValue, "invalid value '{s}' for {s} (expected a non-negative integer)", .{ s, flag });
}

fn eqAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

test "parse basic commands and flags" {
    const p1 = try parse(&.{ "def", "foo", "-v", "full" });
    try std.testing.expectEqual(Command.def, p1.command);
    try std.testing.expectEqualStrings("foo", p1.arg);
    try std.testing.expectEqual(render.Verbosity.full, p1.options.verbosity);

    const p2 = try parse(&.{ "calls", "bar", "-d", "3", "-C", "sub" });
    try std.testing.expectEqual(@as(u32, 3), p2.options.depth);
    try std.testing.expectEqualStrings("sub", p2.root);

    const p3 = try parse(&.{"outline"});
    try std.testing.expectEqual(Command.outline, p3.command);
    try std.testing.expectEqualStrings("", p3.arg);

    try std.testing.expectError(error.Usage, parse(&.{"def"}));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "def", "x", "--nope" }));
}

test "--help anywhere resolves to the help command" {
    const search_help = try parse(&.{ "search", "--help" });
    try std.testing.expectEqual(Command.help, search_help.command);
    try std.testing.expectEqualStrings("search", search_help.arg);
    const def_help = try parse(&.{ "def", "x", "-h" });
    try std.testing.expectEqual(Command.help, def_help.command);
    try std.testing.expectEqualStrings("def", def_help.arg);
}

test "capabilities is a no-positional metadata command with version aliases" {
    const direct = try parse(&.{ "capabilities", "-j" });
    try std.testing.expectEqual(Command.capabilities, direct.command);
    try std.testing.expectEqual(query.OutputFormat.json, direct.options.format);
    try std.testing.expect(!registry.descriptor(direct.command).requires_index);
    try std.testing.expectEqual(Command.capabilities, (try parse(&.{"version"})).command);
    try std.testing.expectEqual(Command.capabilities, (try parse(&.{"--version"})).command);
    try std.testing.expectError(error.Usage, parse(&.{ "capabilities", "unexpected" }));
    // `--no-cache` is global-class: accepted and reported, never a usage error.
    const ignored = try parse(&.{ "capabilities", "--no-cache" });
    try std.testing.expect(ignored.ignored_options.contains(.no_cache));
    try std.testing.expectError(error.Usage, parse(&.{ "capabilities", "--jsonl" }));
}

test "descriptor applicability rejects a command-specific flag on the wrong command" {
    // Command-specific flags stay hard usage errors: they can only be a mistake.
    try std.testing.expectError(error.Usage, parse(&.{ "def", "x", "--no-recurse" }));
    try std.testing.expectError(error.Usage, parse(&.{ "outline", "--preview" }));
    try std.testing.expectEqual(@as(u32, 10), (try parse(&.{ "read", "x.zig", "--limit", "10" })).options.limit);
    // An explicit `-l 300` is a real cap, not the "unset" default (F8).
    const explicit = try parse(&.{ "imports", "-l", "300" });
    try std.testing.expect(explicit.options.limit_set);
    try std.testing.expectEqual(@as(u32, 300), query.listCap(explicit.options).?);
    const implicit = try parse(&.{"imports"});
    try std.testing.expect(!implicit.options.limit_set);
    try std.testing.expect(query.listCap(implicit.options) == null);
    try std.testing.expectEqual(query.hot_default, query.hotLimit(implicit.options));
    try std.testing.expectEqual(@as(u32, 300), query.hotLimit(explicit.options));
    // A format the command cannot emit is still refused (output mode, not
    // applicability), even though `-j` is global-class.
    try std.testing.expectError(error.Usage, parse(&.{ "serve", "--json" }));
    try std.testing.expect((try parse(&.{ "outline", "src", "--no-recurse" })).options.no_recurse);
    try std.testing.expect((try parse(&.{ "rename", "Old", "New", "--preview" })).options.preview);
}

test "a global-class flag a command does not use is accepted, ignored, and reported" {
    // Regression: eight previously working invocations began exiting 2, which
    // broke every client that appends a standard flag set to one argv template.
    const cases = [_][]const [:0]const u8{
        &.{ "read", "src/model.zig", "--no-cache" },
        &.{ "neighbors", "readLines", "-d", "2" },
        &.{ "imports", "-l", "500" },
        &.{ "importers", "model.zig", "-l", "5" },
        &.{ "graph", "-j", "-l", "500" },
    };
    for (cases) |argv| _ = try parse(argv); // declared now: accepted outright

    // Not applicable, but never fatal: accepted, ignored, and named for stderr.
    const def_limit = try parse(&.{ "def", "Symbol", "-l", "5" });
    try std.testing.expect(def_limit.ignored_options.contains(.limit));
    const def_depth = try parse(&.{ "def", "Symbol", "-d", "2" });
    try std.testing.expect(def_depth.ignored_options.contains(.depth));
    const docs_limit = try parse(&.{ "docs", "Symbol", "-l", "5" });
    try std.testing.expect(docs_limit.ignored_options.contains(.limit));
}

test "descriptor dependencies and conflicts are enforced by the parser" {
    try std.testing.expectError(error.Usage, parse(&.{ "search", "needle", "--writers" }));
    try std.testing.expect(std.mem.indexOf(u8, diag(), "requires option 'refs'") != null);
    try std.testing.expect((try parse(&.{ "search", "needle", "--refs", "--writers" })).options.writers);
    try std.testing.expectError(error.Usage, parse(&.{ "search", "needle", "--after", "v1:1" }));
    try std.testing.expectError(error.Usage, parse(&.{ "search", "needle", "--json", "--after", "v1:1" }));
    try std.testing.expect((try parse(&.{ "search", "needle", "--jsonl", "--after", "v1:1" })).options.after_set);
    try std.testing.expectError(error.Usage, parse(&.{ "search", "needle", "--refs", "--duplicates" }));
    try std.testing.expectError(error.Usage, parse(&.{ "routes", "--orphan-calls", "--clients" }));
    try std.testing.expectError(error.Usage, parse(&.{ "flow", "node", "--writers", "--readers" }));
}

test "fixed visibility spellings realize their advertised values" {
    try std.testing.expectEqual(query.Vis.public, (try parse(&.{ "outline", "--public" })).options.visibility);
    try std.testing.expectEqual(query.Vis.public, (try parse(&.{ "outline", "--no-private" })).options.visibility);
    try std.testing.expectEqual(query.Vis.private, (try parse(&.{ "outline", "--private" })).options.visibility);
}

test "help lists every canonical command from the registry" {
    for (&registry.command_descriptors) |command| {
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "  {s}", .{command.name});
        try std.testing.expect(std.mem.indexOf(u8, usage_text, needle) != null);
    }
}

test "parse diagnostics: named flag, bad kind, zero limit, flag-before-command" {
    // Unknown kind is rejected at parse time (was: silently zero results).
    try std.testing.expectError(error.BadValue, parse(&.{ "outline", "-k", "xyz123" }));
    try std.testing.expect(std.mem.indexOf(u8, diag(), "xyz123") != null);
    // `-l 0` is rejected (was: silently behaved like -l 1).
    try std.testing.expectError(error.BadValue, parse(&.{ "outline", "-l", "0" }));
    try std.testing.expect(std.mem.indexOf(u8, diag(), "at least 1") != null);
    // A flag before the command gets the move-it hint.
    try std.testing.expectError(error.Usage, parse(&.{ "-j", "def", "x" }));
    try std.testing.expect(std.mem.indexOf(u8, diag(), "after the command") != null);
    // Bad value names the flag and the expected keywords.
    try std.testing.expectError(error.BadValue, parse(&.{ "def", "x", "-v", "bogus" }));
    try std.testing.expect(std.mem.indexOf(u8, diag(), "--verbosity") != null);
    // A successful parse clears the diagnostic.
    _ = try parse(&.{ "def", "x" });
    try std.testing.expectEqualStrings("", diag());
}

test "attached flag values: -d2, --depth=2, -l50" {
    const a = try parse(&.{ "calls", "x", "-d2" });
    try std.testing.expectEqual(@as(u32, 2), a.options.depth);

    const b = try parse(&.{ "calls", "x", "--depth=3" });
    try std.testing.expectEqual(@as(u32, 3), b.options.depth);

    const c = try parse(&.{ "outline", "-l50", "-vnames" });
    try std.testing.expectEqual(@as(u32, 50), c.options.limit);
    try std.testing.expectEqual(render.Verbosity.names, c.options.verbosity);

    // `-C` still works both attached and separate.
    const d = try parse(&.{ "outline", "-Csub/dir" });
    try std.testing.expectEqualStrings("sub/dir", d.root);

    // A boolean flag rejects an attached value.
    try std.testing.expectError(error.BadValue, parse(&.{ "outline", "--json=1" }));
    // An attached-but-empty value is a missing value.
    try std.testing.expectError(error.MissingValue, parse(&.{ "calls", "x", "--depth=" }));
}

test "unused flags: --no-public and the unified --tests scope (no --no-test)" {
    const a = try parse(&.{ "unused", "--no-public" });
    try std.testing.expect(a.options.unused_skip_exported);
    try std.testing.expectEqual(query.TestScope.with, a.options.tests); // default

    const b = try parse(&.{ "unused", "src", "--no-tests", "--no-public" });
    try std.testing.expect(b.options.unused_skip_exported);
    try std.testing.expectEqual(query.TestScope.without, b.options.tests);
    try std.testing.expectEqualStrings("src", b.arg);

    try std.testing.expectEqual(query.TestScope.only, (try parse(&.{ "unused", "--tests-only" })).options.tests);

    // --no-public rejects an attached value; the retired --no-test is now unknown.
    try std.testing.expectError(error.BadValue, parse(&.{ "unused", "--no-public=1" }));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "unused", "--no-test" }));

    const c = try parse(&.{ "unused", "--follow-imports" });
    try std.testing.expect(c.options.unused_follow_imports);
}

test "new flags: --refs, --kind" {
    const a = try parse(&.{ "search", "foo", "--refs" });
    try std.testing.expect(a.options.refs);

    const b = try parse(&.{ "search", "foo", "-r" });
    try std.testing.expect(b.options.refs);

    const c = try parse(&.{ "outline", "--kind", "fn,struct" });
    try std.testing.expectEqualStrings("fn,struct", c.options.kinds);

    const d = try parse(&.{ "outline", "-kfn" });
    try std.testing.expectEqualStrings("fn", d.options.kinds);
}

test "events and diff commands parse with optional args and aliases" {
    const a = try parse(&.{"events"});
    try std.testing.expectEqual(Command.events, a.command);

    const b = try parse(&.{ "dispatch", "start" });
    try std.testing.expectEqual(Command.events, b.command);
    try std.testing.expectEqualStrings("start", b.arg);

    const c = try parse(&.{"diff"});
    try std.testing.expectEqual(Command.diff, c.command);
    try std.testing.expectEqualStrings("", c.arg);

    const d = try parse(&.{ "changed", "HEAD~3" });
    try std.testing.expectEqual(Command.diff, d.command);
    try std.testing.expectEqualStrings("HEAD~3", d.arg);
}

test "files --sort accepts path/symbols and rejects garbage" {
    const a = try parse(&.{ "files", "--sort", "symbols" });
    try std.testing.expectEqual(query.FileSort.symbols, a.options.file_sort);

    const b = try parse(&.{ "files", "--sort=path" });
    try std.testing.expectEqual(query.FileSort.path, b.options.file_sort);

    try std.testing.expectError(error.BadValue, parse(&.{ "files", "--sort", "nope" }));
}

// ---------------------------------------------------------------------------
// Appended hardening tests for src/cli.zig
// ---------------------------------------------------------------------------

test "parseCommand: every primary command name maps correctly" {
    try std.testing.expectEqual(Command.outline, parseCommand("outline").?);
    try std.testing.expectEqual(Command.def, parseCommand("def").?);
    try std.testing.expectEqual(Command.docs, parseCommand("docs").?);
    try std.testing.expectEqual(Command.calls, parseCommand("calls").?);
    try std.testing.expectEqual(Command.callers, parseCommand("callers").?);
    try std.testing.expectEqual(Command.search, parseCommand("search").?);
    try std.testing.expectEqual(Command.routes, parseCommand("routes").?);
    try std.testing.expectEqual(Command.conforms, parseCommand("conforms").?);
    try std.testing.expectEqual(Command.hierarchy, parseCommand("hierarchy").?);
    try std.testing.expectEqual(Command.raises, parseCommand("raises").?);
    try std.testing.expectEqual(Command.catches, parseCommand("catches").?);
    try std.testing.expectEqual(Command.events, parseCommand("events").?);
    try std.testing.expectEqual(Command.neighbors, parseCommand("neighbors").?);
    try std.testing.expectEqual(Command.unused, parseCommand("unused").?);
    try std.testing.expectEqual(Command.imports, parseCommand("imports").?);
    try std.testing.expectEqual(Command.importers, parseCommand("importers").?);
    try std.testing.expectEqual(Command.path, parseCommand("path").?);
    try std.testing.expectEqual(Command.flow, parseCommand("flow").?);
    try std.testing.expectEqual(Command.taint, parseCommand("taint").?);
    try std.testing.expectEqual(Command.reaches, parseCommand("reaches").?);
    try std.testing.expectEqual(Command.affected, parseCommand("affected").?);
    try std.testing.expectEqual(Command.collisions, parseCommand("collisions").?);
    try std.testing.expectEqual(Command.diff, parseCommand("diff").?);
    try std.testing.expectEqual(Command.history, parseCommand("history").?);
    try std.testing.expectEqual(Command.blame, parseCommand("blame").?);
    try std.testing.expectEqual(Command.churn, parseCommand("churn").?);
    try std.testing.expectEqual(Command.hot, parseCommand("hot").?);
    try std.testing.expectEqual(Command.files, parseCommand("files").?);
    try std.testing.expectEqual(Command.status, parseCommand("status").?);
    try std.testing.expectEqual(Command.read, parseCommand("read").?);
    try std.testing.expectEqual(Command.strings, parseCommand("strings").?);
    try std.testing.expectEqual(Command.todos, parseCommand("todos").?);
    try std.testing.expectEqual(Command.edits, parseCommand("edits").?);
    try std.testing.expectEqual(Command.rename, parseCommand("rename").?);
    try std.testing.expectEqual(Command.coverage, parseCommand("coverage").?);
    try std.testing.expectEqual(Command.graph, parseCommand("graph").?);
    try std.testing.expectEqual(Command.serve, parseCommand("serve").?);
    try std.testing.expectEqual(Command.help, parseCommand("help").?);
    try std.testing.expectEqual(Command.capabilities, parseCommand("capabilities").?);
}

test "parseCommand: every alias maps to its command" {
    try std.testing.expectEqual(Command.outline, parseCommand("o").?);
    try std.testing.expectEqual(Command.def, parseCommand("show").?);
    try std.testing.expectEqual(Command.docs, parseCommand("doc").?);
    try std.testing.expectEqual(Command.calls, parseCommand("callees").?);
    try std.testing.expectEqual(Command.callers, parseCommand("uses").?);
    try std.testing.expectEqual(Command.search, parseCommand("grep").?);
    try std.testing.expectEqual(Command.routes, parseCommand("api").?);
    try std.testing.expectEqual(Command.conforms, parseCommand("impls").?);
    try std.testing.expectEqual(Command.conforms, parseCommand("implements").?);
    try std.testing.expectEqual(Command.hierarchy, parseCommand("hier").?);
    try std.testing.expectEqual(Command.raises, parseCommand("throws").?);
    try std.testing.expectEqual(Command.catches, parseCommand("handles").?);
    try std.testing.expectEqual(Command.events, parseCommand("dispatch").?);
    try std.testing.expectEqual(Command.events, parseCommand("bus").?);
    try std.testing.expectEqual(Command.neighbors, parseCommand("near").?);
    try std.testing.expectEqual(Command.unused, parseCommand("dead").?);
    try std.testing.expectEqual(Command.flow, parseCommand("dataflow").?);
    try std.testing.expectEqual(Command.taint, parseCommand("security").?);
    try std.testing.expectEqual(Command.reaches, parseCommand("reachable").?);
    try std.testing.expectEqual(Command.affected, parseCommand("impact").?);
    try std.testing.expectEqual(Command.collisions, parseCommand("duplicates").?);
    try std.testing.expectEqual(Command.diff, parseCommand("changed").?);
    try std.testing.expectEqual(Command.history, parseCommand("hist").?);
    try std.testing.expectEqual(Command.hot, parseCommand("central").?);
    try std.testing.expectEqual(Command.files, parseCommand("manifest").?);
    try std.testing.expectEqual(Command.status, parseCommand("snapshot").?);
    try std.testing.expectEqual(Command.read, parseCommand("cat").?);
    try std.testing.expectEqual(Command.strings, parseCommand("str").?);
    try std.testing.expectEqual(Command.strings, parseCommand("literals").?);
    try std.testing.expectEqual(Command.todos, parseCommand("todo").?);
    try std.testing.expectEqual(Command.edits, parseCommand("edit-sites").?);
    try std.testing.expectEqual(Command.serve, parseCommand("mcp").?);
    try std.testing.expectEqual(Command.graph, parseCommand("viz").?);
    try std.testing.expectEqual(Command.graph, parseCommand("visualize").?);
    try std.testing.expectEqual(Command.coverage, parseCommand("cov").?);
    // help aliases
    try std.testing.expectEqual(Command.help, parseCommand("--help").?);
    try std.testing.expectEqual(Command.help, parseCommand("-h").?);
    // capabilities doubles as the version verb
    try std.testing.expectEqual(Command.capabilities, parseCommand("version").?);
    try std.testing.expectEqual(Command.capabilities, parseCommand("--version").?);
}

test "phase 1 commands and scoped flags parse" {
    const testing = std.testing;
    try testing.expectEqual(Command.conforms, (try parse(&.{ "conforms", "Port" })).command);
    try testing.expectEqual(Command.conforms, (try parse(&.{ "implements", "Port" })).command);

    const calls = try parse(&.{ "calls", "Port.run", "--impls" });
    try testing.expect(calls.options.impls);
    const outline_cmd = try parse(&.{ "outline", "src", "-ppublic" });
    try testing.expectEqual(query.Vis.public, outline_cmd.options.visibility);
    const routes_cmd = try parse(&.{ "routes", "--clients", "--handler", "place_*" });
    try testing.expect(routes_cmd.options.routes_clients);
    try testing.expectEqualStrings("place_*", routes_cmd.options.routes_handler);
    try testing.expect((try parse(&.{ "routes", "--orphan" })).options.routes_orphan_calls);
    try testing.expect((try parse(&.{ "routes", "--orphans" })).options.routes_orphan_calls);

    try testing.expectError(error.Usage, parse(&.{ "search", "x", "--impls" }));
    try testing.expectError(error.Usage, parse(&.{ "calls", "x", "--clients" }));
    try testing.expectError(error.Usage, parse(&.{ "routes", "--orphan-calls", "--unhit" }));
}

test "phase 2 commands, ranking, and flow flags parse" {
    const flow_cmd = try parse(&.{ "flow", "Record.value", "--writers", "--on-type", "Record", "--to", "sink" });
    try std.testing.expectEqual(Command.flow, flow_cmd.command);
    try std.testing.expect(flow_cmd.options.writers);
    try std.testing.expectEqualStrings("Record", flow_cmd.options.on_type);
    try std.testing.expectEqualStrings("sink", flow_cmd.options.flow_to);

    const ranked = try parse(&.{ "outline", "src", "--sort", "span" });
    try std.testing.expectEqual(query.SortKey.span, ranked.options.sort);
    const duplicates = try parse(&.{ "search", "Graph", "--duplicates" });
    try std.testing.expect(duplicates.options.duplicates);
    const groups = try parse(&.{ "collisions", "Graph", "--members" });
    try std.testing.expectEqual(Command.collisions, groups.command);
    try std.testing.expect(groups.options.collision_members);
    try std.testing.expectError(error.Usage, parse(&.{ "flow", "x", "--writers", "--readers" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "hot", "--sort", "callers" }));
}

test "phase 3 workflows, compaction, rename, and JSONL flags parse" {
    const affected_cmd = try parse(&.{ "affected", "--since", "HEAD~1", "--max-nodes", "20", "--summary" });
    try std.testing.expectEqual(Command.affected, affected_cmd.command);
    try std.testing.expectEqualStrings("HEAD~1", affected_cmd.options.since);
    try std.testing.expectEqual(@as(u32, 20), affected_cmd.options.max_nodes);
    try std.testing.expect(affected_cmd.options.summary);

    const reaches_cmd = try parse(&.{ "reaches", "parse,emit", "--from-tests", "--budget=4096" });
    try std.testing.expect(reaches_cmd.options.from_tests);
    try std.testing.expectEqual(@as(u32, 4096), reaches_cmd.options.budget);
    try std.testing.expectError(error.BadValue, parse(&.{ "calls", "parse", "--budget", "63" }));
    const rename_cmd = try parse(&.{ "rename", "Store.get", "fetch", "--preview" });
    try std.testing.expectEqualStrings("fetch", rename_cmd.arg2);
    try std.testing.expect(rename_cmd.options.preview);
    const stream = try parse(&.{ "search", "parse", "--jsonl", "--after", "v1:25" });
    try std.testing.expectEqual(query.OutputFormat.jsonl, stream.options.format);
    try std.testing.expectEqual(@as(u32, 25), stream.options.after);
    try std.testing.expect(stream.options.after_set);
    const first_page = try parse(&.{ "search", "parse", "--jsonl", "--after", "v1:0" });
    try std.testing.expectEqual(@as(u32, 0), first_page.options.after);
    try std.testing.expect(first_page.options.after_set);

    try std.testing.expectError(error.Usage, parse(&.{ "search", "x", "--since", "HEAD" }));
    try std.testing.expectError(error.Usage, parse(&.{ "search", "x", "--after", "v1:0" }));
    try std.testing.expectError(error.Usage, parse(&.{ "def", "x", "--jsonl" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "search", "x", "--jsonl", "--after", "25" }));
}

test "phase 4 depth and history commands parse with scoped options" {
    const hierarchy_request = try parse(&.{ "hierarchy", "Leaf", "--overrides", "-j" });
    try std.testing.expect(hierarchy_request.options.hierarchy_overrides);
    try std.testing.expectEqual(query.OutputFormat.json, hierarchy_request.options.format);

    const raises_request = try parse(&.{ "raises", "submit", "-d3", "--strict" });
    try std.testing.expectEqual(@as(u32, 3), raises_request.options.depth);
    try std.testing.expect(raises_request.options.strict);
    try std.testing.expectEqual(Command.catches, (try parse(&.{ "handles", "OrderError" })).command);

    const taint_request = try parse(&.{ "security", "request.json", "--to", "subprocess.run", "--strict" });
    try std.testing.expectEqualStrings("subprocess.run", taint_request.options.flow_to);
    try std.testing.expect(taint_request.options.strict);
    try std.testing.expectError(error.Usage, parse(&.{ "taint", "request.json" }));

    const history_request = try parse(&.{ "hist", "submit", "--last", "7" });
    try std.testing.expectEqual(@as(u32, 7), history_request.options.history_last);
    const churn_request = try parse(&.{ "churn", "src", "--since", "HEAD~5", "--sort", "lines" });
    try std.testing.expectEqualStrings("HEAD~5", churn_request.options.since);
    try std.testing.expectEqual(query.ChurnSort.lines, churn_request.options.churn_sort);
    try std.testing.expectError(error.Usage, parse(&.{ "blame", "submit", "--last", "2" }));
    try std.testing.expectError(error.Usage, parse(&.{ "raises", "submit", "--overrides" }));
}

test "parseCommand: unknown and empty return null" {
    try std.testing.expect(parseCommand("frobnicate") == null);
    try std.testing.expect(parseCommand("") == null);
    try std.testing.expect(parseCommand("Outline") == null); // case-sensitive
    try std.testing.expect(parseCommand("defx") == null);
}

test "parse: unknown command is a usage error" {
    try std.testing.expectError(error.Usage, parse(&.{"frobnicate"}));
    try std.testing.expectError(error.Usage, parse(&.{ "nope", "arg" }));
    // An unknown leading-dash token is treated as a command lookup, not a flag.
    try std.testing.expectError(error.Usage, parse(&.{"--bogus"}));
}

test "parse: empty argv is a usage error" {
    try std.testing.expectError(error.Usage, parse(&.{}));
}

test "parse: aliases resolve through parse to the same command" {
    try std.testing.expectEqual(Command.outline, (try parse(&.{"o"})).command);
    try std.testing.expectEqual(Command.callers, (try parse(&.{ "uses", "x" })).command);
    try std.testing.expectEqual(Command.search, (try parse(&.{ "grep", "x" })).command);
    try std.testing.expectEqual(Command.routes, (try parse(&.{"api"})).command);
    try std.testing.expectEqual(Command.hot, (try parse(&.{"central"})).command);
    try std.testing.expectEqual(Command.files, (try parse(&.{"manifest"})).command);
    try std.testing.expectEqual(Command.read, (try parse(&.{ "cat", "f.zig" })).command);
    try std.testing.expectEqual(Command.strings, (try parse(&.{ "literals", "pat" })).command);
}

test "help accepts a global-class flag and ignores it, like every other command" {
    // Regression (F9): `help` short-circuited before flag parsing, so
    // `navgraph help -l 5` exited 2 and contradicted the README's promise that
    // the global-class flags are accepted on every command.
    const bare = try parse(&.{ "help", "-l", "5" });
    try std.testing.expectEqual(Command.help, bare.command);
    try std.testing.expectEqualStrings("", bare.arg);
    try std.testing.expect(bare.ignored_options.contains(.limit));

    const scoped = try parse(&.{ "help", "outline", "-l", "5" });
    try std.testing.expectEqualStrings("outline", scoped.arg);
    try std.testing.expect(scoped.ignored_options.contains(.limit));

    // Command-specific flags and an unemittable format stay usage errors.
    try std.testing.expectError(error.Usage, parse(&.{ "help", "--preview" }));
    try std.testing.expectError(error.Usage, parse(&.{ "help", "-j" }));
}

test "parse: help accepts one canonical command or alias" {
    const a = try parse(&.{"help"});
    try std.testing.expectEqual(Command.help, a.command);

    const b = try parse(&.{ "help", "cat" });
    try std.testing.expectEqual(Command.help, b.command);
    try std.testing.expectEqualStrings("read", b.arg);
    try std.testing.expectError(error.Usage, parse(&.{ "help", "garbage" }));
    try std.testing.expectError(error.Usage, parse(&.{ "help", "read", "extra" }));

    const c = try parse(&.{"--help"});
    try std.testing.expectEqual(Command.help, c.command);

    const d = try parse(&.{"-h"});
    try std.testing.expectEqual(Command.help, d.command);
}

test "usageCommand renders concise registry-derived argument and option help" {
    const testing = std.testing;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try testing.expect(try usageCommand(&aw.writer, "read"));
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "USAGE: navgraph read <source> [options]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-l, --limit <N>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--after <v1:N>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "COMMANDS:") == null);

    const capabilities_start = aw.written().len;
    try testing.expect(try usageCommand(&aw.writer, "capabilities"));
    const capabilities_help = aw.written()[capabilities_start..];
    try testing.expect(std.mem.indexOf(u8, capabilities_help, "OUTPUT: json") != null);
    try testing.expect(std.mem.indexOf(u8, capabilities_help, "-j, --json  (JSON is always emitted)") != null);
    try testing.expect(std.mem.indexOf(u8, capabilities_help, "--jsonl") == null);
    try testing.expect(std.mem.indexOf(u8, capabilities_help, "text is the default") == null);
}

test "parse: default option values on a bare command" {
    const p = try parse(&.{"outline"});
    try std.testing.expectEqual(render.Verbosity.sig, p.options.verbosity);
    try std.testing.expectEqual(@as(u32, 1), p.options.depth);
    try std.testing.expectEqual(query.default_limit, p.options.limit);
    try std.testing.expect(!p.options.strict);
    try std.testing.expectEqual(query.OutputFormat.text, p.options.format);
    try std.testing.expect(!p.options.refs);
    try std.testing.expectEqualStrings("", p.options.kinds);
    try std.testing.expect(!p.options.unused_skip_exported);
    try std.testing.expectEqual(query.TestScope.with, p.options.tests);
    try std.testing.expect(!p.options.unused_follow_imports);
    try std.testing.expectEqual(query.FileSort.path, p.options.file_sort);
    try std.testing.expect(p.use_cache);
    try std.testing.expectEqualStrings(".", p.root);
    try std.testing.expectEqualStrings("", p.arg);
    try std.testing.expectEqualStrings("", p.arg2);
}

test "hasRequiredArgs: optional-arg commands accept no positional" {
    const empty = Parsed{ .command = .outline };
    try std.testing.expect(hasRequiredArgs(.outline, empty));
    try std.testing.expect(hasRequiredArgs(.routes, empty));
    try std.testing.expect(hasRequiredArgs(.events, empty));
    try std.testing.expect(hasRequiredArgs(.unused, empty));
    try std.testing.expect(hasRequiredArgs(.imports, empty));
    try std.testing.expect(hasRequiredArgs(.hot, empty));
    try std.testing.expect(hasRequiredArgs(.files, empty));
    try std.testing.expect(hasRequiredArgs(.status, empty));
    try std.testing.expect(hasRequiredArgs(.diff, empty));
    try std.testing.expect(hasRequiredArgs(.churn, empty));
}

test "hasRequiredArgs: single-arg commands require a positional" {
    const empty = Parsed{ .command = .def };
    const withArg = Parsed{ .command = .def, .arg = "foo" };
    try std.testing.expect(!hasRequiredArgs(.def, empty));
    try std.testing.expect(hasRequiredArgs(.def, withArg));
    try std.testing.expect(!hasRequiredArgs(.calls, empty));
    try std.testing.expect(!hasRequiredArgs(.callers, empty));
    try std.testing.expect(!hasRequiredArgs(.search, empty));
    try std.testing.expect(!hasRequiredArgs(.neighbors, empty));
    try std.testing.expect(!hasRequiredArgs(.importers, empty));
    try std.testing.expect(!hasRequiredArgs(.read, empty));
    try std.testing.expect(!hasRequiredArgs(.strings, empty));
    try std.testing.expect(!hasRequiredArgs(.hierarchy, empty));
    try std.testing.expect(!hasRequiredArgs(.raises, empty));
    try std.testing.expect(!hasRequiredArgs(.catches, empty));
    try std.testing.expect(!hasRequiredArgs(.taint, empty));
    try std.testing.expect(!hasRequiredArgs(.history, empty));
    try std.testing.expect(!hasRequiredArgs(.blame, empty));
}

test "hasRequiredArgs: path needs exactly two positionals" {
    try std.testing.expect(!hasRequiredArgs(.path, .{ .command = .path }));
    try std.testing.expect(!hasRequiredArgs(.path, .{ .command = .path, .arg = "A" }));
    try std.testing.expect(!hasRequiredArgs(.path, .{ .command = .path, .arg2 = "B" }));
    try std.testing.expect(hasRequiredArgs(.path, .{ .command = .path, .arg = "A", .arg2 = "B" }));
}

test "parse: optional-arg commands succeed with no positional" {
    try std.testing.expectEqual(Command.routes, (try parse(&.{"routes"})).command);
    try std.testing.expectEqual(Command.events, (try parse(&.{"events"})).command);
    try std.testing.expectEqual(Command.unused, (try parse(&.{"unused"})).command);
    try std.testing.expectEqual(Command.imports, (try parse(&.{"imports"})).command);
    try std.testing.expectEqual(Command.hot, (try parse(&.{"hot"})).command);
    try std.testing.expectEqual(Command.files, (try parse(&.{"files"})).command);
    try std.testing.expectEqual(Command.status, (try parse(&.{"status"})).command);
    try std.testing.expectEqual(Command.diff, (try parse(&.{"diff"})).command);
    try std.testing.expectEqual(Command.churn, (try parse(&.{"churn"})).command);
    // ...and with an optional filter/positional.
    try std.testing.expectEqualStrings("src", (try parse(&.{ "outline", "src" })).arg);
    try std.testing.expectEqualStrings("HEAD~2", (try parse(&.{ "diff", "HEAD~2" })).arg);
}

test "parse: single-arg commands require their positional" {
    try std.testing.expectError(error.Usage, parse(&.{"def"}));
    try std.testing.expectError(error.Usage, parse(&.{"calls"}));
    try std.testing.expectError(error.Usage, parse(&.{"callers"}));
    try std.testing.expectError(error.Usage, parse(&.{"search"}));
    try std.testing.expectError(error.Usage, parse(&.{"neighbors"}));
    try std.testing.expectError(error.Usage, parse(&.{"importers"}));
    try std.testing.expectError(error.Usage, parse(&.{"read"}));
    try std.testing.expectError(error.Usage, parse(&.{"strings"}));
    try std.testing.expectError(error.Usage, parse(&.{"hierarchy"}));
    try std.testing.expectError(error.Usage, parse(&.{"raises"}));
    try std.testing.expectError(error.Usage, parse(&.{"catches"}));
    try std.testing.expectError(error.Usage, parse(&.{"taint"}));
    try std.testing.expectError(error.Usage, parse(&.{"history"}));
    try std.testing.expectError(error.Usage, parse(&.{"blame"}));
    // Provided: fine.
    try std.testing.expectEqualStrings("f.zig", (try parse(&.{ "importers", "f.zig" })).arg);
    try std.testing.expectEqualStrings("x.zig:1-2", (try parse(&.{ "read", "x.zig:1-2" })).arg);
}

test "parse: path with two positionals; too few or too many is usage error" {
    const p = try parse(&.{ "path", "A", "B" });
    try std.testing.expectEqual(Command.path, p.command);
    try std.testing.expectEqualStrings("A", p.arg);
    try std.testing.expectEqualStrings("B", p.arg2);

    try std.testing.expectError(error.Usage, parse(&.{"path"}));
    try std.testing.expectError(error.Usage, parse(&.{ "path", "A" }));
    // Third positional overflows.
    try std.testing.expectError(error.Usage, parse(&.{ "path", "A", "B", "C" }));
}

test "parse: extra positional on a single-arg command is a usage error" {
    try std.testing.expectError(error.Usage, parse(&.{ "def", "a", "b" }));
    // A second positional is only accepted by `path`.
    try std.testing.expectError(error.Usage, parse(&.{ "outline", "a", "b" }));
}

test "parse: flags may appear before and after the positional" {
    const a = try parse(&.{ "calls", "-d2", "target", "-s" });
    try std.testing.expectEqualStrings("target", a.arg);
    try std.testing.expectEqual(@as(u32, 2), a.options.depth);
    try std.testing.expect(a.options.strict);

    const b = try parse(&.{ "outline", "-l50", "src", "--json" });
    try std.testing.expectEqualStrings("src", b.arg);
    try std.testing.expectEqual(@as(u32, 50), b.options.limit);
    try std.testing.expectEqual(query.OutputFormat.json, b.options.format);
}

test "verbosity flag: every keyword and alias, separated and attached" {
    try std.testing.expectEqual(render.Verbosity.names, (try parse(&.{ "def", "x", "-v", "names" })).options.verbosity);
    try std.testing.expectEqual(render.Verbosity.sig, (try parse(&.{ "def", "x", "-v", "sig" })).options.verbosity);
    try std.testing.expectEqual(render.Verbosity.doc, (try parse(&.{ "def", "x", "-v", "doc" })).options.verbosity);
    try std.testing.expectEqual(render.Verbosity.full, (try parse(&.{ "def", "x", "-v", "full" })).options.verbosity);
    // aliases
    try std.testing.expectEqual(render.Verbosity.names, (try parse(&.{ "def", "x", "--verbosity", "name" })).options.verbosity);
    try std.testing.expectEqual(render.Verbosity.sig, (try parse(&.{ "def", "x", "-v", "signature" })).options.verbosity);
    try std.testing.expectEqual(render.Verbosity.doc, (try parse(&.{ "def", "x", "-v", "docs" })).options.verbosity);
    try std.testing.expectEqual(render.Verbosity.full, (try parse(&.{ "def", "x", "-v", "body" })).options.verbosity);
    // attached forms
    try std.testing.expectEqual(render.Verbosity.full, (try parse(&.{ "def", "x", "-vfull" })).options.verbosity);
    try std.testing.expectEqual(render.Verbosity.doc, (try parse(&.{ "def", "x", "--verbosity=doc" })).options.verbosity);
}

test "verbosity flag: garbage value is a BadValue error" {
    try std.testing.expectError(error.BadValue, parse(&.{ "def", "x", "-v", "nope" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "def", "x", "--verbosity=zzz" }));
}

test "depth/limit/root/kind flags: separated and attached forms" {
    // depth
    try std.testing.expectEqual(@as(u32, 4), (try parse(&.{ "calls", "x", "-d", "4" })).options.depth);
    try std.testing.expectEqual(@as(u32, 4), (try parse(&.{ "calls", "x", "-d4" })).options.depth);
    try std.testing.expectEqual(@as(u32, 4), (try parse(&.{ "calls", "x", "--depth", "4" })).options.depth);
    try std.testing.expectEqual(@as(u32, 4), (try parse(&.{ "calls", "x", "--depth=4" })).options.depth);
    // limit
    try std.testing.expectEqual(@as(u32, 7), (try parse(&.{ "outline", "-l", "7" })).options.limit);
    try std.testing.expectEqual(@as(u32, 7), (try parse(&.{ "outline", "-l7" })).options.limit);
    try std.testing.expectEqual(@as(u32, 7), (try parse(&.{ "outline", "--limit=7" })).options.limit);
    // root
    try std.testing.expectEqualStrings("sub", (try parse(&.{ "outline", "-C", "sub" })).root);
    try std.testing.expectEqualStrings("sub", (try parse(&.{ "outline", "-Csub" })).root);
    try std.testing.expectEqualStrings("sub", (try parse(&.{ "outline", "--root=sub" })).root);
    // kind
    try std.testing.expectEqualStrings("fn,struct", (try parse(&.{ "outline", "-k", "fn,struct" })).options.kinds);
    try std.testing.expectEqualStrings("fn", (try parse(&.{ "outline", "-kfn" })).options.kinds);
    try std.testing.expectEqualStrings("method", (try parse(&.{ "outline", "--kind=method" })).options.kinds);
}

test "value-taking flags without a value are MissingValue errors" {
    try std.testing.expectError(error.MissingValue, parse(&.{ "calls", "x", "-d" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "outline", "-l" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "outline", "-C" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "outline", "-k" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "def", "x", "-v" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "files", "--sort" }));
    // Attached-but-empty value is also MissingValue.
    try std.testing.expectError(error.MissingValue, parse(&.{ "calls", "x", "--depth=" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "outline", "--kind=" }));
}

test "depth/limit reject non-numeric and overflowing values (BadValue)" {
    try std.testing.expectError(error.BadValue, parse(&.{ "calls", "x", "-d", "abc" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "calls", "x", "-dxx" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "outline", "-l", "-5" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "calls", "x", "--depth=99999999999" }));
}

test "sort flag: keywords and aliases, plus BadValue" {
    try std.testing.expectEqual(query.FileSort.path, (try parse(&.{ "files", "--sort", "path" })).options.file_sort);
    try std.testing.expectEqual(query.FileSort.path, (try parse(&.{ "files", "--sort", "name" })).options.file_sort);
    try std.testing.expectEqual(query.FileSort.symbols, (try parse(&.{ "files", "--sort=symbols" })).options.file_sort);
    try std.testing.expectEqual(query.FileSort.symbols, (try parse(&.{ "files", "--sort=size" })).options.file_sort);
    try std.testing.expectError(error.BadValue, parse(&.{ "files", "--sort", "zzz" }));
}

test "boolean flags set their fields (short and long)" {
    try std.testing.expect((try parse(&.{ "calls", "x", "-s" })).options.strict);
    try std.testing.expect((try parse(&.{ "calls", "x", "--strict" })).options.strict);
    try std.testing.expectEqual(query.OutputFormat.json, (try parse(&.{ "outline", "-j" })).options.format);
    try std.testing.expectEqual(query.OutputFormat.json, (try parse(&.{ "outline", "--json" })).options.format);
    try std.testing.expect((try parse(&.{ "search", "x", "-r" })).options.refs);
    try std.testing.expect((try parse(&.{ "search", "x", "--refs" })).options.refs);
    try std.testing.expect(!(try parse(&.{ "outline", "--no-cache" })).use_cache);
    try std.testing.expectEqual(query.TestScope.without, (try parse(&.{ "unused", "--no-tests" })).options.tests);
    try std.testing.expect((try parse(&.{ "unused", "--no-public" })).options.unused_skip_exported);
    try std.testing.expect((try parse(&.{ "unused", "--follow-imports" })).options.unused_follow_imports);
}

test "boolean flags reject an attached value (BadValue)" {
    try std.testing.expectError(error.BadValue, parse(&.{ "calls", "x", "--strict=1" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "calls", "x", "-s1" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "outline", "--json=1" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "outline", "-j1" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "search", "x", "--refs=yes" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "search", "x", "-r1" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "outline", "--no-cache=0" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "unused", "--no-tests=1" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "unused", "--no-public=1" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "unused", "--follow-imports=1" }));
}

test "unknown flag: bare form is UnknownFlag, attached-value form is BadValue" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "def", "x", "--nope" }));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "def", "x", "-z" }));
    // An unknown flag carrying an attached value trips the boolean-attach guard
    // before the unknown-flag fallthrough, so it surfaces as BadValue.
    try std.testing.expectError(error.BadValue, parse(&.{ "def", "x", "--nope=1" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "def", "x", "-z9" }));
}

test "reason: each ParseError maps to its explanation" {
    try std.testing.expect(std.mem.indexOf(u8, reason(error.Usage), "expected a command") != null);
    try std.testing.expectEqualStrings("unknown flag", reason(error.UnknownFlag));
    try std.testing.expect(std.mem.indexOf(u8, reason(error.MissingValue), "missing its value") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason(error.BadValue), "invalid flag value") != null);
}

test "usage: writes the full help banner" {
    const testing = std.testing;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try usage(&aw.writer);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "NavGraph") != null);
    try testing.expect(std.mem.indexOf(u8, out, "USAGE:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "COMMANDS:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "FLAGS (command-scoped") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--no-cache") != null);
}

test "usage documents every command and phase flags (drift guard)" {
    const testing = std.testing;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &buf);
    defer aw.deinit();
    try usage(&aw.writer);
    const out = aw.written();
    // Every Command's canonical name must appear in the help, so a new verb can't
    // ship undocumented.
    inline for (@typeInfo(Command).@"enum".fields) |f| {
        try testing.expect(std.mem.indexOf(u8, out, f.name) != null);
    }
    // Unified test-scope and Phase 1/2/3 flags are documented.
    for ([_][]const u8{
        "--tests",      "--no-tests",  "--tests-only",   "--no-public",
        "--impls",      "--vis",       "--public",       "--private",
        "--clients",    "--unhit",     "--orphan-calls", "--orphans",
        "--handler",    "--writers",   "--readers",      "--unread",
        "--on-type",    "--to",        "--duplicates",   "--members",
        "--budget",     "--max-nodes", "--summary",      "--since",
        "--from-tests", "--preview",   "--jsonl",        "--after",
        "--overrides",  "--last",      "parse-health",
        "⇒impl",
    }) |flag| {
        try testing.expect(std.mem.indexOf(u8, out, flag) != null);
    }
}

test "splitFlag: long flag with and without an attached value" {
    const a = splitFlag("--depth=2");
    try std.testing.expectEqualStrings("--depth", a.name);
    try std.testing.expectEqualStrings("2", a.inline_val.?);

    const b = splitFlag("--strict");
    try std.testing.expectEqualStrings("--strict", b.name);
    try std.testing.expect(b.inline_val == null);

    // Only the first `=` splits; the rest is part of the value.
    const c = splitFlag("--kind=fn=struct");
    try std.testing.expectEqualStrings("--kind", c.name);
    try std.testing.expectEqualStrings("fn=struct", c.inline_val.?);

    // `--sort=` yields an empty (non-null) value → value() reports MissingValue.
    const d = splitFlag("--sort=");
    try std.testing.expectEqualStrings("--sort", d.name);
    try std.testing.expectEqualStrings("", d.inline_val.?);
}

test "splitFlag: short flag with and without an attached value" {
    const a = splitFlag("-d2");
    try std.testing.expectEqualStrings("-d", a.name);
    try std.testing.expectEqualStrings("2", a.inline_val.?);

    // A bare 2-char short flag has no attached value.
    const b = splitFlag("-d");
    try std.testing.expectEqualStrings("-d", b.name);
    try std.testing.expect(b.inline_val == null);

    // The name is always the first two chars for a long-ish short token.
    const c = splitFlag("-Csub/dir");
    try std.testing.expectEqualStrings("-C", c.name);
    try std.testing.expectEqualStrings("sub/dir", c.inline_val.?);

    // A lone dash is neither long nor an attach; passes through untouched.
    const d = splitFlag("-");
    try std.testing.expectEqualStrings("-", d.name);
    try std.testing.expect(d.inline_val == null);
}

test "SplitFlag.value: attached value wins and value() ignores args" {
    const args = [_][:0]const u8{ "--depth", "IGNORED" };
    const sf = SplitFlag{ .name = "--depth", .inline_val = "9" };
    try std.testing.expectEqualStrings("9", try sf.value(&args, 0, sf.name));
    try std.testing.expectEqual(@as(usize, 0), sf.next(0));
}

test "SplitFlag.value: separate value reads the next token" {
    const args = [_][:0]const u8{ "-d", "5" };
    const sf = SplitFlag{ .name = "-d", .inline_val = null };
    try std.testing.expectEqualStrings("5", try sf.value(&args, 0, sf.name));
    try std.testing.expectEqual(@as(usize, 1), sf.next(0));
}

test "SplitFlag.value: empty attached value is MissingValue" {
    const args = [_][:0]const u8{"--sort"};
    const sf = SplitFlag{ .name = "--sort", .inline_val = "" };
    try std.testing.expectError(error.MissingValue, sf.value(&args, 0, sf.name));
}

test "SplitFlag.value: no next token is MissingValue" {
    const args = [_][:0]const u8{"-d"};
    const sf = SplitFlag{ .name = "-d", .inline_val = null };
    try std.testing.expectError(error.MissingValue, sf.value(&args, 0, sf.name));
}

test "parseUint: valid decimals including bounds" {
    try std.testing.expectEqual(@as(u32, 0), try parseUint("0", "-l/--limit"));
    try std.testing.expectEqual(@as(u32, 42), try parseUint("42", "-l/--limit"));
    try std.testing.expectEqual(@as(u32, 7), try parseUint("007", "-l/--limit")); // leading zeros ok
    try std.testing.expectEqual(@as(u32, 4294967295), try parseUint("4294967295", "-l/--limit")); // u32 max
}

test "parseUint: overflow, non-digit, empty and negative are BadValue" {
    try std.testing.expectError(error.BadValue, parseUint("4294967296", "-l/--limit")); // u32 max + 1
    try std.testing.expectError(error.BadValue, parseUint("99999999999", "-l/--limit"));
    try std.testing.expectError(error.BadValue, parseUint("abc", "-l/--limit"));
    try std.testing.expectError(error.BadValue, parseUint("12x", "-l/--limit"));
    try std.testing.expectError(error.BadValue, parseUint("", "-l/--limit"));
    try std.testing.expectError(error.BadValue, parseUint("-1", "-l/--limit"));
    try std.testing.expectError(error.BadValue, parseUint("0x10", "-l/--limit")); // base 10 only
    try std.testing.expectError(error.BadValue, parseUint(" 5", "-l/--limit")); // no whitespace
}

test "eqAny: membership, misses and empty option set" {
    try std.testing.expect(eqAny("-d", &.{ "-d", "--depth" }));
    try std.testing.expect(eqAny("--depth", &.{ "-d", "--depth" }));
    try std.testing.expect(!eqAny("-x", &.{ "-d", "--depth" }));
    try std.testing.expect(!eqAny("-d", &.{})); // empty set never matches
    try std.testing.expect(eqAny("--sort", &.{"--sort"}));
    try std.testing.expect(!eqAny("--Sort", &.{"--sort"})); // case-sensitive
}

test "parse: multiple mixed flags accumulate onto one Parsed" {
    const p = try parse(&.{ "search", "resolve", "--refs", "-l", "10", "-C", "src", "-kfn", "-s", "--json" });
    try std.testing.expectEqual(Command.search, p.command);
    try std.testing.expectEqualStrings("resolve", p.arg);
    try std.testing.expect(p.options.refs);
    try std.testing.expectEqual(@as(u32, 10), p.options.limit);
    try std.testing.expectEqualStrings("src", p.root);
    try std.testing.expectEqualStrings("fn", p.options.kinds);
    try std.testing.expect(p.options.strict);
    try std.testing.expectEqual(query.OutputFormat.json, p.options.format);
}

test "double dash terminates options for flag-looking positional literals" {
    const literal = try parse(&.{ "strings", "--", "--no-tests" });
    try std.testing.expectEqual(Command.strings, literal.command);
    try std.testing.expectEqualStrings("--no-tests", literal.arg);

    const search = try parse(&.{ "search", "--", "-needle" });
    try std.testing.expectEqualStrings("-needle", search.arg);

    const source = try parse(&.{ "read", "--", "-generated.py:1-2" });
    try std.testing.expectEqualStrings("-generated.py:1-2", source.arg);

    try std.testing.expectError(error.Usage, parse(&.{ "strings", "--" }));
    try std.testing.expectError(error.Usage, parse(&.{ "strings", "value", "--", "extra" }));
}

test "read accepts line budget and cursor page options in text and json" {
    const json_page = try parse(&.{ "read", "m.py", "-l2", "--budget", "1000", "--after=v1:2", "-j" });
    try std.testing.expectEqual(Command.read, json_page.command);
    try std.testing.expectEqual(@as(u32, 2), json_page.options.limit);
    try std.testing.expectEqual(@as(u32, 1000), json_page.options.budget);
    try std.testing.expectEqual(@as(u32, 2), json_page.options.after);
    try std.testing.expect(json_page.options.after_set);
    try std.testing.expectEqual(query.OutputFormat.json, json_page.options.format);

    const text_page = try parse(&.{ "read", "m.py", "--after", "v1:4" });
    try std.testing.expectEqual(@as(u32, 4), text_page.options.after);
    try std.testing.expectEqual(query.OutputFormat.text, text_page.options.format);

    try std.testing.expectError(error.Usage, parse(&.{ "read", "m.py", "--max-nodes", "2" }));
    try std.testing.expectError(error.Usage, parse(&.{ "def", "name", "--after", "v1:2" }));
}

test "coverage command and unified --tests scope selector" {
    const t = std.testing;
    try t.expectEqual(Command.coverage, (try parse(&.{"coverage"})).command);
    try t.expectEqual(Command.coverage, (try parse(&.{"cov"})).command);
    // value form (next token, short alias, attached)
    try t.expectEqual(query.TestScope.only, (try parse(&.{ "callers", "foo", "--tests", "only" })).options.tests);
    try t.expectEqual(query.TestScope.without, (try parse(&.{ "outline", "-t", "without" })).options.tests);
    try t.expectEqual(query.TestScope.with, (try parse(&.{ "outline", "--tests=with" })).options.tests);
    // boolean aliases
    try t.expectEqual(query.TestScope.without, (try parse(&.{ "outline", "--no-tests" })).options.tests);
    try t.expectEqual(query.TestScope.only, (try parse(&.{ "callers", "foo", "--tests-only" })).options.tests);
    // default is `with`
    try t.expectEqual(query.TestScope.with, (try parse(&.{"outline"})).options.tests);
    try t.expectError(error.BadValue, parse(&.{ "outline", "--tests", "nope" }));
}

test "status and exact-source options are scoped and structured-output aware" {
    const status_request = try parse(&.{ "status", "src", "--jsonl", "-l2" });
    try std.testing.expectEqual(Command.status, status_request.command);
    try std.testing.expectEqualStrings("src", status_request.arg);
    try std.testing.expectEqual(query.OutputFormat.jsonl, status_request.options.format);

    const diff_request = try parse(&.{ "diff", "HEAD~1", "--exact-source", "--budget", "1000", "-j" });
    try std.testing.expect(diff_request.options.exact_source);
    try std.testing.expectEqual(@as(u32, 1000), diff_request.options.budget);
    try std.testing.expectEqual(query.OutputFormat.json, diff_request.options.format);
    try std.testing.expectError(error.Usage, parse(&.{ "search", "x", "--exact-source" }));
}
