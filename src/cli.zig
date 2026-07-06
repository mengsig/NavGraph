//! Command-line parsing for NavGraph. Turns argv into a `Parsed` request or a
//! usage error. Parsing is intentionally small and explicit — no framework.

const std = @import("std");
const query = @import("query.zig");
const render = @import("render.zig");

pub const Command = enum { outline, def, calls, callers, search, routes, help };

pub const Parsed = struct {
    command: Command,
    /// Positional argument: a path (outline), a name (def/calls/callers) or a
    /// pattern (search). Empty when not provided.
    arg: []const u8 = "",
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
    \\  def <name>         Show a definition (supports Parent.name)
    \\  calls <name>       Symbols that <name> calls/uses (callees), as a tree
    \\  callers <name>     Symbols that call/use <name> (callers), as a tree
    \\  search <pattern>   Find symbols whose name contains <pattern>
    \\  routes [filter]    List HTTP routes and the client calls that hit them
    \\  help               Show this help
    \\
    \\FLAGS:
    \\  -v, --verbosity <names|sig|doc|full>   Detail level (default: sig)
    \\  -d, --depth <N>                        Graph depth for calls/callers (default: 1)
    \\  -C, --root <path>                      Project root to index (default: .)
    \\  -l, --limit <N>                        Max results (default: 300)
    \\  -s, --strict                           Follow only high-confidence edges
    \\  -j, --json                             Emit JSON (stable, for tooling/MCP)
    \\  --no-cache                             Ignore the .navgraph/cache and rebuild
    \\
    \\EXAMPLES:
    \\  navgraph outline src/parser.zig
    \\  navgraph def parseZigScope -v full
    \\  navgraph calls build -d 2
    \\  navgraph callers collectRefs
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
        error.MissingValue => "a flag is missing its value (use `-d 2`, not `-d2`)",
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
        } else {
            return error.Usage; // extra positional
        }
    }
    const arg_optional = command == .outline or command == .routes;
    if (!arg_optional and result.arg.len == 0) return error.Usage;
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
        .{ "help", Command.help },       .{ "--help", Command.help },
        .{ "-h", Command.help },
    };
    inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
    return null;
}

/// Parse a flag at index `i`, returning the index of the last token consumed.
fn parseFlag(args: []const [:0]const u8, i: usize, out: *Parsed) ParseError!usize {
    const flag = args[i];
    if (eqAny(flag, &.{ "-v", "--verbosity" })) {
        const val = try value(args, i);
        out.options.verbosity = render.Verbosity.parse(val) orelse return error.BadValue;
        return i + 1;
    }
    if (eqAny(flag, &.{ "-d", "--depth" })) {
        out.options.depth = try parseUint(try value(args, i));
        return i + 1;
    }
    if (eqAny(flag, &.{ "-l", "--limit" })) {
        out.options.limit = try parseUint(try value(args, i));
        return i + 1;
    }
    if (eqAny(flag, &.{ "-C", "--root" })) {
        out.root = try value(args, i);
        return i + 1;
    }
    if (eqAny(flag, &.{ "-s", "--strict" })) {
        out.options.strict = true;
        return i;
    }
    if (eqAny(flag, &.{ "-j", "--json" })) {
        out.options.format = .json;
        return i;
    }
    if (eqAny(flag, &.{"--no-cache"})) {
        out.use_cache = false;
        return i;
    }
    return error.UnknownFlag;
}

fn value(args: []const [:0]const u8, i: usize) ParseError![]const u8 {
    if (i + 1 >= args.len) return error.MissingValue;
    return args[i + 1];
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
