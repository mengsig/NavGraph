//! Command-line parsing for NavGraph. Turns argv into a `Parsed` request or a
//! usage error. Parsing is intentionally small and explicit — no framework.

const std = @import("std");
const query = @import("query.zig");
const render = @import("render.zig");

pub const Command = enum {
    outline, def, calls, callers, search, routes, events,
    neighbors, unused, imports, importers, path, hot, diff,
    files, read, strings, coverage, help,
};

pub const Parsed = struct {
    command: Command,
    /// Positional argument: a path (outline), a name (def/calls/callers) or a
    /// pattern (search). Empty when not provided.
    arg: []const u8 = "",
    /// Second positional (only `path <A> <B>` uses it). Empty otherwise.
    arg2: []const u8 = "",
    root: []const u8 = ".",
    options: query.Options = .{},
    /// Use the incremental on-disk cache (`.navgraph/cache`). Disabled by
    /// `--no-cache` for a guaranteed-clean rebuild.
    use_cache: bool = true,
};

pub const ParseError = error{ Usage, UnknownFlag, MissingValue, BadValue };

const usage_text =
    \\NavGraph — a code-graph navigator for agents.
    \\
    \\USAGE: navgraph <command> [arg] [flags]
    \\
    \\COMMANDS:
    \\  outline [path]     Outline symbols in a file/dir (default: whole project)
    \\  def <name>         Show a definition (supports Parent.name, name@path)
    \\  calls <name>       Symbols that <name> calls/uses (callees), as a tree
    \\  callers <name>     Symbols that call/use <name> (callers), as a tree
    \\  search <pattern>   Find symbols by name (or use sites with --refs;
    \\                     Recv.field / .field pins instance-attribute reads)
    \\  routes [filter]    List HTTP routes and the client calls that hit them
    \\  events [filter]    Link message-bus handlers (register/on) to emitters (send/emit)
    \\  neighbors <name>   Callees and callers of <name> in one view
    \\  unused [filter]    Dead code (fns/methods & types nothing references). Default:
    \\                     truly dead; --no-tests = dead in production (test-only-used
    \\                     shown), --tests-only = dead test code, --no-public drops
    \\                     exported (maybe public API)
    \\  imports [filter]   Modules each file imports (local dependency edges)
    \\  importers <file>   Files that import <file>
    \\  path <A> <B>       Shortest call path from <A> to <B>
    \\  diff [ref]         Symbols changed since <ref> (default HEAD) + their callers
    \\  hot [path]         Rank functions by fan-in/out — the load-bearing symbols
    \\  files [filter]     List every indexed file + its symbol count (index coverage);
    \\                     add --sort symbols to rank biggest-first
    \\  read <file[:A-B]>  Print raw source lines (numbered); batch ranges: file:A-B,C-D
    \\  strings <pattern>  Search inside string literals (URLs, log/error text, regexes)
    \\  coverage [path]    % of fn/method reachable from a test (call-graph, no instrumentation)
    \\  help               Show this help
    \\
    \\FLAGS:
    \\  -v, --verbosity <names|sig|doc|full>   Detail level (default: sig)
    \\  -d, --depth <N>                        Graph depth for calls/callers (default: 1)
    \\  -C, --root <path>                      Index root: a directory, or a single
    \\                                         file to scope to it (default: .)
    \\  -l, --limit <N>                        Max results (default: 300)
    \\  -k, --kind <k1,k2>                     Restrict outline/search to kinds (fn,struct,…)
    \\  --sort <path|symbols>                  files: order by path (default) or symbol count
    \\  -r, --refs                             search: match use sites; calls/neighbors: include var/const/field reads
    \\  -t, --tests <with|without|only>        Unified test-scope for outline/search/
    \\                                         callers/hot/unused: with (default) |
    \\                                         without | only. A test is a Zig `test`
    \\                                         block, a test_* fn, or a test-dir file.
    \\  --no-tests, --tests-only               Shortcuts for --tests without / --tests only.
    \\  -s, --strict                           Follow only high-confidence edges
    \\  -j, --json                             Emit JSON (stable, for tooling/MCP)
    \\  --no-cache                             Ignore the .navgraph/cache and rebuild
    \\  --no-public                            unused: drop exported symbols (possible public API)
    \\  --follow-imports                       unused: disambiguate same-name symbols by
    \\                                         import reachability (finds dead code masked
    \\                                         by a used twin; relies on import resolution)
    \\
    \\  Locations are `path:line-endLine`; call trees annotate each edge with its
    \\  call-site line as `↳:N`, and a trailing `?` marks a heuristic (ambiguous
    \\  name-match) edge — verify those or use `-s` to drop them. Flag values may
    \\  be attached (`-d2`, `--depth=2`).
    \\
    \\EXAMPLES:
    \\  navgraph outline src/parser.zig --kind fn
    \\  navgraph def parseZigScope -v full
    \\  navgraph calls build@build.zig -d 2
    \\  navgraph callers collectRefs
    \\  navgraph search resolve --refs
    \\  navgraph neighbors resolveOne
    \\  navgraph unused                            # truly-dead code
    \\  navgraph unused --tests-only --no-public   # dead private test helpers
    \\  navgraph callers parse --tests-only        # which tests exercise parse
    \\  navgraph outline src --no-tests            # production structure only
    \\  navgraph coverage src                      # test reach per file
    \\  navgraph path parse emit
    \\
;

pub fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(usage_text);
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
    if (args.len == 0) return error.Usage;
    const command = parseCommand(args[0]) orelse return error.Usage;
    if (command == .help) return .{ .command = .help };

    var result = Parsed{ .command = command };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len != 0 and a[0] == '-') {
            i = try parseFlag(args, i, &result);
        } else if (result.arg.len == 0) {
            result.arg = a;
        } else if (result.arg2.len == 0 and command == .path) {
            result.arg2 = a;
        } else {
            return error.Usage; // extra positional
        }
    }
    if (!hasRequiredArgs(command, result)) return error.Usage;
    return result;
}

fn parseCommand(s: []const u8) ?Command {
    const map = .{
        .{ "outline", Command.outline }, .{ "o", Command.outline },
        .{ "def", Command.def },         .{ "show", Command.def },
        .{ "calls", Command.calls },     .{ "callees", Command.calls },
        .{ "callers", Command.callers }, .{ "uses", Command.callers },
        .{ "search", Command.search },   .{ "grep", Command.search },
        .{ "routes", Command.routes },   .{ "api", Command.routes },
        .{ "events", Command.events },   .{ "dispatch", Command.events },
        .{ "bus", Command.events },
        .{ "neighbors", Command.neighbors }, .{ "near", Command.neighbors },
        .{ "unused", Command.unused },   .{ "dead", Command.unused },
        .{ "imports", Command.imports }, .{ "importers", Command.importers },
        .{ "path", Command.path },
        .{ "diff", Command.diff },       .{ "changed", Command.diff },
        .{ "hot", Command.hot },         .{ "central", Command.hot },
        .{ "files", Command.files },     .{ "manifest", Command.files },
        .{ "read", Command.read },       .{ "cat", Command.read },
        .{ "strings", Command.strings }, .{ "str", Command.strings },
        .{ "literals", Command.strings },
        .{ "coverage", Command.coverage }, .{ "cov", Command.coverage },

        .{ "help", Command.help },       .{ "--help", Command.help },
        .{ "-h", Command.help },
    };
    inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
    return null;
}

/// Whether `command` has the positional arguments it requires. `outline`,
/// `routes`, `events`, `unused` and `imports` accept an optional filter; `path`
/// needs two.
fn hasRequiredArgs(command: Command, p: Parsed) bool {
    return switch (command) {
        .outline, .routes, .events, .unused, .imports, .hot, .files, .diff, .coverage => true,
        .path => p.arg.len != 0 and p.arg2.len != 0,
        else => p.arg.len != 0,
    };
}

/// Parse a flag at index `i`, returning the index of the last token consumed.
/// Value-taking flags accept the value attached (`-d2`, `--depth=2`) or as the
/// next token (`-d 2`). Boolean flags reject an attached value.
fn parseFlag(args: []const [:0]const u8, i: usize, out: *Parsed) ParseError!usize {
    const raw = args[i];
    const f = splitFlag(raw);

    if (eqAny(f.name, &.{ "-v", "--verbosity" })) {
        const val = try f.value(args, i);
        out.options.verbosity = render.Verbosity.parse(val) orelse return error.BadValue;
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-d", "--depth" })) {
        out.options.depth = try parseUint(try f.value(args, i));
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-l", "--limit" })) {
        out.options.limit = try parseUint(try f.value(args, i));
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-C", "--root" })) {
        out.root = try f.value(args, i);
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-k", "--kind" })) {
        out.options.kinds = try f.value(args, i);
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "--sort" })) {
        out.options.file_sort = query.FileSort.parse(try f.value(args, i)) orelse return error.BadValue;
        return f.next(i);
    }
    if (eqAny(f.name, &.{ "-t", "--tests" })) {
        out.options.tests = query.TestScope.parse(try f.value(args, i)) orelse return error.BadValue;
        return f.next(i);
    }
    // Boolean flags: an attached `=value` is a usage error.
    if (f.inline_val != null) return error.BadValue;
    if (eqAny(f.name, &.{"--no-tests"})) {
        out.options.tests = .without;
        return i;
    }
    if (eqAny(f.name, &.{"--tests-only"})) {
        out.options.tests = .only;
        return i;
    }
    if (eqAny(f.name, &.{ "-s", "--strict" })) {
        out.options.strict = true;
        return i;
    }
    if (eqAny(f.name, &.{ "-j", "--json" })) {
        out.options.format = .json;
        return i;
    }
    if (eqAny(f.name, &.{ "-r", "--refs" })) {
        out.options.refs = true;
        return i;
    }
    if (eqAny(f.name, &.{"--no-cache"})) {
        out.use_cache = false;
        return i;
    }
    if (eqAny(f.name, &.{"--no-public"})) {
        out.options.unused_skip_exported = true;
        return i;
    }
    if (eqAny(f.name, &.{"--follow-imports"})) {
        out.options.unused_follow_imports = true;
        return i;
    }
    return error.UnknownFlag;
}

/// A flag token split into its name and an optional attached value. Handles both
/// `--long=value` and short `-dVALUE` (name is the first two chars, `-d`).
const SplitFlag = struct {
    name: []const u8,
    inline_val: ?[]const u8,

    /// The flag's value: the attached one if present, else the next token.
    fn value(self: SplitFlag, args: []const [:0]const u8, i: usize) ParseError![]const u8 {
        if (self.inline_val) |v| {
            if (v.len == 0) return error.MissingValue;
            return v;
        }
        if (i + 1 >= args.len) return error.MissingValue;
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

fn parseUint(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch error.BadValue;
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
    try std.testing.expectEqual(Command.calls, parseCommand("calls").?);
    try std.testing.expectEqual(Command.callers, parseCommand("callers").?);
    try std.testing.expectEqual(Command.search, parseCommand("search").?);
    try std.testing.expectEqual(Command.routes, parseCommand("routes").?);
    try std.testing.expectEqual(Command.events, parseCommand("events").?);
    try std.testing.expectEqual(Command.neighbors, parseCommand("neighbors").?);
    try std.testing.expectEqual(Command.unused, parseCommand("unused").?);
    try std.testing.expectEqual(Command.imports, parseCommand("imports").?);
    try std.testing.expectEqual(Command.importers, parseCommand("importers").?);
    try std.testing.expectEqual(Command.path, parseCommand("path").?);
    try std.testing.expectEqual(Command.diff, parseCommand("diff").?);
    try std.testing.expectEqual(Command.hot, parseCommand("hot").?);
    try std.testing.expectEqual(Command.files, parseCommand("files").?);
    try std.testing.expectEqual(Command.read, parseCommand("read").?);
    try std.testing.expectEqual(Command.strings, parseCommand("strings").?);
    try std.testing.expectEqual(Command.help, parseCommand("help").?);
}

test "parseCommand: every alias maps to its command" {
    try std.testing.expectEqual(Command.outline, parseCommand("o").?);
    try std.testing.expectEqual(Command.def, parseCommand("show").?);
    try std.testing.expectEqual(Command.calls, parseCommand("callees").?);
    try std.testing.expectEqual(Command.callers, parseCommand("uses").?);
    try std.testing.expectEqual(Command.search, parseCommand("grep").?);
    try std.testing.expectEqual(Command.routes, parseCommand("api").?);
    try std.testing.expectEqual(Command.events, parseCommand("dispatch").?);
    try std.testing.expectEqual(Command.events, parseCommand("bus").?);
    try std.testing.expectEqual(Command.neighbors, parseCommand("near").?);
    try std.testing.expectEqual(Command.unused, parseCommand("dead").?);
    try std.testing.expectEqual(Command.diff, parseCommand("changed").?);
    try std.testing.expectEqual(Command.hot, parseCommand("central").?);
    try std.testing.expectEqual(Command.files, parseCommand("manifest").?);
    try std.testing.expectEqual(Command.read, parseCommand("cat").?);
    try std.testing.expectEqual(Command.strings, parseCommand("str").?);
    try std.testing.expectEqual(Command.strings, parseCommand("literals").?);
    // help aliases
    try std.testing.expectEqual(Command.help, parseCommand("--help").?);
    try std.testing.expectEqual(Command.help, parseCommand("-h").?);
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

test "parse: help returns immediately and ignores trailing tokens" {
    const a = try parse(&.{"help"});
    try std.testing.expectEqual(Command.help, a.command);

    // Trailing junk (including an otherwise-unknown flag) is ignored for help.
    const b = try parse(&.{ "help", "garbage", "--nope", "-d", "x" });
    try std.testing.expectEqual(Command.help, b.command);
    try std.testing.expectEqualStrings("", b.arg);

    const c = try parse(&.{"--help"});
    try std.testing.expectEqual(Command.help, c.command);

    const d = try parse(&.{"-h"});
    try std.testing.expectEqual(Command.help, d.command);
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
    try std.testing.expect(hasRequiredArgs(.diff, empty));
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
    try std.testing.expectEqual(Command.diff, (try parse(&.{"diff"})).command);
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
    try testing.expect(std.mem.indexOf(u8, out, "FLAGS:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--no-cache") != null);
}

test "usage documents every command and test-scope flag (drift guard)" {
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
    // The unified test-scope flag and its aliases are documented.
    for ([_][]const u8{ "--tests", "--no-tests", "--tests-only", "--no-public" }) |flag| {
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
    try std.testing.expectEqualStrings("9", try sf.value(&args, 0));
    try std.testing.expectEqual(@as(usize, 0), sf.next(0));
}

test "SplitFlag.value: separate value reads the next token" {
    const args = [_][:0]const u8{ "-d", "5" };
    const sf = SplitFlag{ .name = "-d", .inline_val = null };
    try std.testing.expectEqualStrings("5", try sf.value(&args, 0));
    try std.testing.expectEqual(@as(usize, 1), sf.next(0));
}

test "SplitFlag.value: empty attached value is MissingValue" {
    const args = [_][:0]const u8{"--sort"};
    const sf = SplitFlag{ .name = "--sort", .inline_val = "" };
    try std.testing.expectError(error.MissingValue, sf.value(&args, 0));
}

test "SplitFlag.value: no next token is MissingValue" {
    const args = [_][:0]const u8{"-d"};
    const sf = SplitFlag{ .name = "-d", .inline_val = null };
    try std.testing.expectError(error.MissingValue, sf.value(&args, 0));
}

test "parseUint: valid decimals including bounds" {
    try std.testing.expectEqual(@as(u32, 0), try parseUint("0"));
    try std.testing.expectEqual(@as(u32, 42), try parseUint("42"));
    try std.testing.expectEqual(@as(u32, 7), try parseUint("007")); // leading zeros ok
    try std.testing.expectEqual(@as(u32, 4294967295), try parseUint("4294967295")); // u32 max
}

test "parseUint: overflow, non-digit, empty and negative are BadValue" {
    try std.testing.expectError(error.BadValue, parseUint("4294967296")); // u32 max + 1
    try std.testing.expectError(error.BadValue, parseUint("99999999999"));
    try std.testing.expectError(error.BadValue, parseUint("abc"));
    try std.testing.expectError(error.BadValue, parseUint("12x"));
    try std.testing.expectError(error.BadValue, parseUint(""));
    try std.testing.expectError(error.BadValue, parseUint("-1"));
    try std.testing.expectError(error.BadValue, parseUint("0x10")); // base 10 only
    try std.testing.expectError(error.BadValue, parseUint(" 5")); // no whitespace
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
