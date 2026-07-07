//! Command-line parsing for NavGraph. Turns argv into a `Parsed` request or a
//! usage error. Parsing is intentionally small and explicit — no framework.

const std = @import("std");
const query = @import("query.zig");
const render = @import("render.zig");

pub const Command = enum {
    outline, def, calls, callers, search, routes,
    neighbors, unused, imports, importers, path, hot, help,
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
    \\  search <pattern>   Find symbols by name (or use sites with --refs)
    \\  routes [filter]    List HTTP routes and the client calls that hit them
    \\  neighbors <name>   Callees and callers of <name> in one view
    \\  unused [filter]    Functions/methods with no callers (possible dead code)
    \\  imports [filter]   Modules each file imports (local dependency edges)
    \\  importers <file>   Files that import <file>
    \\  path <A> <B>       Shortest call path from <A> to <B>
    \\  hot [path]         Rank functions by fan-in/out — the load-bearing symbols
    \\  help               Show this help
    \\
    \\FLAGS:
    \\  -v, --verbosity <names|sig|doc|full>   Detail level (default: sig)
    \\  -d, --depth <N>                        Graph depth for calls/callers (default: 1)
    \\  -C, --root <path>                      Project root to index (default: .)
    \\  -l, --limit <N>                        Max results (default: 300)
    \\  -k, --kind <k1,k2>                     Restrict outline/search to kinds (fn,struct,…)
    \\  -r, --refs                             search: match use sites, not just names
    \\  -s, --strict                           Follow only high-confidence edges
    \\  -j, --json                             Emit JSON (stable, for tooling/MCP)
    \\  --no-cache                             Ignore the .navgraph/cache and rebuild
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
        .{ "neighbors", Command.neighbors }, .{ "near", Command.neighbors },
        .{ "unused", Command.unused },   .{ "dead", Command.unused },
        .{ "imports", Command.imports }, .{ "importers", Command.importers },
        .{ "path", Command.path },
        .{ "hot", Command.hot },         .{ "central", Command.hot },

        .{ "help", Command.help },       .{ "--help", Command.help },
        .{ "-h", Command.help },
    };
    inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
    return null;
}

/// Whether `command` has the positional arguments it requires. `outline`,
/// `routes`, `unused` and `imports` accept an optional filter; `path` needs two.
fn hasRequiredArgs(command: Command, p: Parsed) bool {
    return switch (command) {
        .outline, .routes, .unused, .imports, .hot => true,
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
    // Boolean flags: an attached `=value` is a usage error.
    if (f.inline_val != null) return error.BadValue;
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
