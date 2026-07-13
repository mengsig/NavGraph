//! Generated black-box checks for the machine-readable CLI contract.
//!
//! This executable knows no NavGraph parser internals. It asks the built binary
//! for its capability manifest, synthesizes argv from that JSON, and verifies
//! the parser agrees about positional arity, flag arity, dependencies, and
//! conflicts. Keeping this separate from white-box registry tests catches drift
//! between published descriptors and the actual executable.

const std = @import("std");

const ContractError = error{ContractMismatch};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const process_args = try init.minimal.args.toSlice(allocator);
    if (process_args.len != 3) {
        std.debug.print("usage: manifest-contract <navgraph-bin> <repo-root>\n", .{});
        return ContractError.ContractMismatch;
    }
    const bin = process_args[1];
    const repo = process_args[2];

    const manifest_result = try run(allocator, io, &.{ bin, "capabilities" });
    try requireExit(manifest_result, 0, "capabilities manifest");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_result.stdout, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return mismatch("capabilities root is not an object", .{});
    const root = parsed.value.object;
    const commands = root.get("commands") orelse return mismatch("manifest has no commands", .{});
    const options = root.get("options") orelse return mismatch("manifest has no options", .{});
    if (commands != .array or options != .array) return mismatch("commands/options are not arrays", .{});

    try checkRequiredArguments(allocator, io, bin, commands.array.items);
    try checkRequiredOptions(allocator, io, bin, commands.array.items);
    try checkSpellingArity(allocator, io, bin, commands.array.items, options.array.items);
    try checkDependencies(allocator, io, bin, repo, commands.array.items, options.array.items);
    try checkConflicts(allocator, io, bin, commands.array.items, options.array.items);
    try checkServerAvailability(allocator, io, bin, repo, commands.array.items, options.array.items);

    std.debug.print("manifest-contract: generated argv checks passed\n", .{});
}

fn checkRequiredArguments(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    commands: []const std.json.Value,
) !void {
    for (commands) |*command| {
        const command_obj = try object(command.*, "command");
        const arguments = try arrayField(command_obj, "arguments");
        var required_count: usize = 0;
        for (arguments) |argument| {
            const argument_obj = try object(argument, "argument");
            if (try boolField(argument_obj, "required")) required_count += 1;
        }
        if (required_count == 0) continue;

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(allocator, bin);
        try argv.append(allocator, try stringField(command_obj, "name"));
        var emitted: usize = 0;
        for (arguments) |argument| {
            const argument_obj = try object(argument, "argument");
            if (!try boolField(argument_obj, "required")) continue;
            emitted += 1;
            if (emitted == required_count) break;
            try argv.append(allocator, argumentSample(try stringField(argument_obj, "kind")));
        }
        const result = try run(allocator, io, argv.items);
        try requireUsage(result, "manifest required positional argument");
    }
}

fn checkRequiredOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    commands: []const std.json.Value,
) !void {
    for (commands) |*command| {
        const command_obj = try object(command.*, "command");
        const required = try arrayField(command_obj, "requiredOptions");
        if (required.len == 0) continue;
        const argv = try baseArgv(allocator, bin, command_obj);
        const result = try run(allocator, io, argv.items);
        try requireUsageContaining(result, "requires option", "manifest required option");
    }
}

fn checkSpellingArity(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    commands: []const std.json.Value,
    options: []const std.json.Value,
) !void {
    for (options) |*option| {
        const option_obj = try object(option.*, "option");
        const applies_to = try arrayField(option_obj, "appliesTo");
        if (applies_to.len == 0) return mismatch("option has no applicable command", .{});
        const first_command_name = try valueString(applies_to[0], "appliesTo entry");
        const first_command = findNamed(commands, first_command_name) orelse
            return mismatch("option references missing command '{s}'", .{first_command_name});
        const first_command_obj = try object(first_command.*, "command");

        for (try arrayField(option_obj, "spellings")) |spelling| {
            const spelling_obj = try object(spelling, "spelling");
            const flag = try stringField(spelling_obj, "flag");
            const takes_value = try boolField(spelling_obj, "takesValue");
            var arity_argv = try baseArgv(allocator, bin, first_command_obj);
            if (takes_value) {
                if (spelling_obj.get("fixedValue") != null)
                    return mismatch("value-taking spelling '{s}' also has fixedValue", .{flag});
                try arity_argv.append(allocator, flag);
                const result = try run(allocator, io, arity_argv.items);
                try requireUsageContaining(result, "missing", "value-taking spelling without value");
            } else {
                if (spelling_obj.get("fixedValue") == null)
                    return mismatch("fixed spelling '{s}' has no fixedValue", .{flag});
                try arity_argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}=unexpected", .{flag}));
                const result = try run(allocator, io, arity_argv.items);
                try requireUsage(result, "fixed spelling with attached value");
            }

            // Prove every advertised alias is actually recognized on every
            // advertised command. A known sentinel flag follows the valid
            // spelling: the parser must advance through the advertised flag
            // and report the sentinel, not stop on an unknown/bad alias.
            for (applies_to) |applies_value| {
                const command_name = try valueString(applies_value, "appliesTo entry");
                const command = findNamed(commands, command_name) orelse
                    return mismatch("option references missing command '{s}'", .{command_name});
                const command_obj = try object(command.*, "command");
                var recognized_argv = try baseArgv(allocator, bin, command_obj);
                try appendSpelling(allocator, &recognized_argv, option_obj, spelling_obj, command_obj);
                if (spellingAllowed(command_obj, option_obj, spelling_obj)) {
                    try recognized_argv.append(allocator, "--manifest-contract-stop");
                    const recognized = try run(allocator, io, recognized_argv.items);
                    try requireUsageContaining(recognized, "--manifest-contract-stop", "advertised spelling recognition");
                } else {
                    const rejected = try run(allocator, io, recognized_argv.items);
                    try requireUsage(rejected, "command-inapplicable fixed spelling");
                }
            }
        }
    }
}

fn appendSpelling(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    option: std.json.ObjectMap,
    spelling: std.json.ObjectMap,
    command: std.json.ObjectMap,
) !void {
    try argv.append(allocator, try stringField(spelling, "flag"));
    if (try boolField(spelling, "takesValue")) {
        try argv.append(allocator, try optionSampleForCommand(allocator, option, command));
    }
}

fn spellingAllowed(command: std.json.ObjectMap, option: std.json.ObjectMap, spelling: std.json.ObjectMap) bool {
    const option_name = stringField(option, "name") catch return false;
    if (!std.mem.eql(u8, option_name, "format")) return true;
    const fixed = spelling.get("fixedValue") orelse return true;
    if (fixed != .string) return false;
    const outputs = arrayField(command, "outputModes") catch return false;
    return hasString(outputs, fixed.string);
}

fn checkDependencies(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    repo: []const u8,
    commands: []const std.json.Value,
    options: []const std.json.Value,
) !void {
    const clean_root = try std.fs.path.join(allocator, &.{ repo, "testenv", "rust_cli" });
    for (commands) |*command| {
        const command_obj = try object(command.*, "command");
        for (try arrayField(command_obj, "dependencies")) |dependency| {
            const dependency_obj = try object(dependency, "dependency");
            const trigger_name = try stringField(dependency_obj, "option");
            const requires_obj = try object(dependency_obj.get("requires") orelse
                return mismatch("dependency has no requires object", .{}), "requires");
            const required_name = try stringField(requires_obj, "option");
            const trigger = findNamed(options, trigger_name) orelse
                return mismatch("dependency trigger '{s}' is missing", .{trigger_name});
            const required = findNamed(options, required_name) orelse
                return mismatch("dependency requirement '{s}' is missing", .{required_name});

            var missing_argv = try baseArgv(allocator, bin, command_obj);
            try appendOption(allocator, &missing_argv, try object(trigger.*, "trigger option"), null);
            const missing = try run(allocator, io, missing_argv.items);
            try requireUsageContaining(missing, "requires option", "declared dependency omitted");

            // The fully synthesized dependency must pass argv validation. Exit
            // 0 and semantic no-result exit 1 are both valid; exit 2 is usage.
            var complete_argv = try baseArgv(allocator, bin, command_obj);
            try appendOption(allocator, &complete_argv, try object(trigger.*, "trigger option"), null);
            try appendOption(allocator, &complete_argv, try object(required.*, "required option"), requires_obj.get("value"));
            if (hasString(try arrayField(command_obj, "options"), "root")) {
                try complete_argv.append(allocator, "-C");
                try complete_argv.append(allocator, clean_root);
            }
            if (hasString(try arrayField(command_obj, "options"), "no_cache")) {
                try complete_argv.append(allocator, "--no-cache");
            }
            const complete = try run(allocator, io, complete_argv.items);
            if (exitCode(complete.term) == 2) {
                return mismatch("manifest dependency did not synthesize valid argv; stderr: {s}", .{complete.stderr});
            }
        }
    }
}

fn checkConflicts(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    commands: []const std.json.Value,
    options: []const std.json.Value,
) !void {
    for (commands) |*command| {
        const command_obj = try object(command.*, "command");
        for (try arrayField(command_obj, "conflicts")) |conflict| {
            if (conflict != .array or conflict.array.items.len != 2)
                return mismatch("conflict is not a two-option pair", .{});
            const first_name = try valueString(conflict.array.items[0], "conflict option");
            const second_name = try valueString(conflict.array.items[1], "conflict option");
            const first = findNamed(options, first_name) orelse
                return mismatch("conflict option '{s}' is missing", .{first_name});
            const second = findNamed(options, second_name) orelse
                return mismatch("conflict option '{s}' is missing", .{second_name});
            var argv = try baseArgv(allocator, bin, command_obj);
            try appendOption(allocator, &argv, try object(first.*, "conflict option"), null);
            try appendOption(allocator, &argv, try object(second.*, "conflict option"), null);
            // A conflicting option may itself have a prerequisite (for
            // example search writers/readers both require refs). Satisfy those
            // first so the executable reaches the advertised conflict.
            for (try arrayField(command_obj, "dependencies")) |dependency| {
                const dependency_obj = try object(dependency, "dependency");
                const trigger_name = try stringField(dependency_obj, "option");
                if (!std.mem.eql(u8, trigger_name, first_name) and !std.mem.eql(u8, trigger_name, second_name)) continue;
                const requires_obj = try object(dependency_obj.get("requires") orelse
                    return mismatch("dependency has no requires object", .{}), "requires");
                const required_name = try stringField(requires_obj, "option");
                const required = findNamed(options, required_name) orelse
                    return mismatch("dependency requirement '{s}' is missing", .{required_name});
                try appendOption(allocator, &argv, try object(required.*, "required option"), requires_obj.get("value"));
            }
            const result = try run(allocator, io, argv.items);
            try requireUsageContaining(result, "mutually exclusive", "declared conflict");
        }
    }
}

fn checkServerAvailability(
    allocator: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    repo: []const u8,
    commands: []const std.json.Value,
    options: []const std.json.Value,
) !void {
    var requests: std.ArrayList(u8) = .empty;
    var allocating: std.Io.Writer.Allocating = .fromArrayList(allocator, &requests);
    defer allocating.deinit();
    const writer = &allocating.writer;

    for (commands) |*command| {
        const command_obj = try object(command.*, "command");
        const command_name = try stringField(command_obj, "name");
        var command_argv = try baseArgv(allocator, "", command_obj);
        // baseArgv's first item is the executable; MCP argv starts at command.
        _ = command_argv.orderedRemove(0);
        for (try arrayField(command_obj, "requiredOptions")) |required_value| {
            const required_name = try valueString(required_value, "required option");
            const required = findNamed(options, required_name) orelse
                return mismatch("required option '{s}' is missing", .{required_name});
            try appendOption(allocator, &command_argv, try object(required.*, "required option"), null);
        }
        if (hasString(try arrayField(command_obj, "options"), "limit")) {
            try command_argv.append(allocator, "-l");
            try command_argv.append(allocator, "1");
        }

        try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeJsonString(writer, command_name);
        try writer.writeAll(",\"method\":\"tools/call\",\"params\":{\"name\":\"navgraph\",\"arguments\":{\"args\":[");
        for (command_argv.items, 0..) |arg, index| {
            if (index != 0) try writer.writeByte(',');
            try writeJsonString(writer, arg);
        }
        try writer.writeAll("]}}}\n");
    }
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":\"shutdown\",\"method\":\"shutdown\"}\n");

    const server_root = try std.fs.path.join(allocator, &.{ repo, "testenv", "rust_cli" });
    const result = try run(allocator, io, &.{
        "sh",
        "-c",
        "printf '%s' \"$1\" | \"$2\" serve -C \"$3\" --no-cache",
        "manifest-contract",
        allocating.written(),
        bin,
        server_root,
    });
    try requireExit(result, 0, "generated server availability session");

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    for (commands) |*command| {
        const line = lines.next() orelse return mismatch("server omitted a command response", .{});
        const command_obj = try object(command.*, "command");
        const command_name = try stringField(command_obj, "name");
        var response = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch
            return mismatch("server response for '{s}' is not JSON: {s}", .{ command_name, line });
        defer response.deinit();
        const response_obj = try object(response.value, "server response");
        const response_id = response_obj.get("id") orelse return mismatch("server response has no id", .{});
        if (!std.mem.eql(u8, try valueString(response_id, "response id"), command_name))
            return mismatch("server response order/id drifted for '{s}'", .{command_name});
        const rejected = response_obj.get("error") != null;
        const advertised = try boolField(command_obj, "serverAvailable");
        if (advertised == rejected)
            return mismatch("serverAvailable={any} disagrees with raw MCP gate for '{s}': {s}", .{ advertised, command_name, line });
    }
}

fn baseArgv(allocator: std.mem.Allocator, bin: []const u8, command: std.json.ObjectMap) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, bin);
    try argv.append(allocator, try stringField(command, "name"));
    for (try arrayField(command, "arguments")) |argument| {
        const argument_obj = try object(argument, "argument");
        if (try boolField(argument_obj, "required")) {
            try argv.append(allocator, argumentSample(try stringField(argument_obj, "kind")));
        }
    }
    return argv;
}

fn appendOption(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    option: std.json.ObjectMap,
    required_value: ?std.json.Value,
) !void {
    const spellings = try arrayField(option, "spellings");
    if (spellings.len == 0) return mismatch("option has no spellings", .{});

    var chosen: ?std.json.ObjectMap = null;
    if (required_value) |wanted| {
        for (spellings) |spelling| {
            const spelling_obj = try object(spelling, "spelling");
            const fixed = spelling_obj.get("fixedValue") orelse continue;
            if (jsonScalarEqual(fixed, wanted)) {
                chosen = spelling_obj;
                break;
            }
        }
    }
    if (chosen == null) chosen = try object(spellings[0], "spelling");
    const spelling = chosen.?;
    try argv.append(allocator, try stringField(spelling, "flag"));
    if (try boolField(spelling, "takesValue")) {
        try argv.append(allocator, if (required_value) |value|
            try valueString(value, "required option value")
        else
            try optionSample(allocator, option));
    } else if (required_value) |wanted| {
        const fixed = spelling.get("fixedValue") orelse
            return mismatch("required fixed spelling has no fixedValue", .{});
        if (!jsonScalarEqual(fixed, wanted))
            return mismatch("no spelling realizes required dependency value", .{});
    }
}

fn argumentSample(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "source_range")) return "missing-contract-source.zig";
    if (std.mem.eql(u8, kind, "new_name")) return "NavGraphContractNewName";
    if (std.mem.eql(u8, kind, "command_name")) return "outline";
    if (std.mem.eql(u8, kind, "file")) return "missing-contract-source.zig";
    return "NavGraphContractMissing";
}

fn optionSample(allocator: std.mem.Allocator, option: std.json.ObjectMap) ![]const u8 {
    const kind = try stringField(option, "valueKind");
    if (std.mem.eql(u8, kind, "integer")) {
        if (option.get("minimum")) |minimum| {
            if (minimum != .integer) return mismatch("integer option minimum is not an integer", .{});
            return std.fmt.allocPrint(allocator, "{d}", .{minimum.integer});
        }
        return "1";
    }
    if (std.mem.eql(u8, kind, "cursor")) return "v1:1";
    if (std.mem.eql(u8, kind, "enumeration")) {
        const values = try arrayField(option, "values");
        if (values.len == 0) return mismatch("enumeration option has no values", .{});
        return valueString(values[0], "enumeration value");
    }
    return "NavGraphContractValue";
}

fn optionSampleForCommand(
    allocator: std.mem.Allocator,
    option: std.json.ObjectMap,
    command: std.json.ObjectMap,
) ![]const u8 {
    const overrides_value = command.get("optionValueOverrides") orelse
        return mismatch("command has no optionValueOverrides", .{});
    if (overrides_value != .object) return mismatch("optionValueOverrides is not an object", .{});
    const option_name = try stringField(option, "name");
    if (overrides_value.object.get(option_name)) |values_value| {
        if (values_value != .array or values_value.array.items.len == 0)
            return mismatch("command option override is not a non-empty array", .{});
        return valueString(values_value.array.items[0], "command option override");
    }
    return optionSample(allocator, option);
}

fn findNamed(items: []const std.json.Value, name: []const u8) ?*const std.json.Value {
    for (items) |*item| {
        if (item.* != .object) continue;
        const candidate = item.object.get("name") orelse continue;
        if (candidate != .string) continue;
        if (std.mem.eql(u8, candidate.string, name)) return item;
    }
    return null;
}

fn hasString(items: []const std.json.Value, expected: []const u8) bool {
    for (items) |*item| {
        if (item.* == .string and std.mem.eql(u8, item.string, expected)) return true;
    }
    return false;
}

fn object(value: std.json.Value, context: []const u8) !std.json.ObjectMap {
    if (value != .object) return mismatch("{s} is not an object", .{context});
    return value.object;
}

fn arrayField(obj: std.json.ObjectMap, name: []const u8) ![]const std.json.Value {
    const value = obj.get(name) orelse return mismatch("object has no '{s}'", .{name});
    if (value != .array) return mismatch("'{s}' is not an array", .{name});
    return value.array.items;
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = obj.get(name) orelse return mismatch("object has no '{s}'", .{name});
    return valueString(value, name);
}

fn valueString(value: std.json.Value, context: []const u8) ![]const u8 {
    if (value != .string) return mismatch("{s} is not a string", .{context});
    return value.string;
}

fn jsonScalarEqual(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .string => |value| std.mem.eql(u8, value, right.string),
        .bool => |value| value == right.bool,
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .null => true,
        else => false,
    };
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn boolField(obj: std.json.ObjectMap, name: []const u8) !bool {
    const value = obj.get(name) orelse return mismatch("object has no '{s}'", .{name});
    if (value != .bool) return mismatch("'{s}' is not boolean", .{name});
    return value.bool;
}

fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
}

fn requireUsage(result: std.process.RunResult, context: []const u8) !void {
    if (exitCode(result.term) != 2)
        return mismatch("{s}: expected usage exit 2, got {any}; stdout={s}; stderr={s}", .{ context, result.term, result.stdout, result.stderr });
}

fn requireUsageContaining(result: std.process.RunResult, needle: []const u8, context: []const u8) !void {
    try requireUsage(result, context);
    if (std.mem.indexOf(u8, result.stderr, needle) == null)
        return mismatch("{s}: stderr does not contain '{s}': {s}", .{ context, needle, result.stderr });
}

fn requireExit(result: std.process.RunResult, expected: u8, context: []const u8) !void {
    if (exitCode(result.term) != expected)
        return mismatch("{s}: expected exit {d}, got {any}; stderr={s}", .{ context, expected, result.term, result.stderr });
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

fn mismatch(comptime format: []const u8, args: anytype) ContractError {
    std.debug.print("manifest-contract: " ++ format ++ "\n", args);
    return ContractError.ContractMismatch;
}
