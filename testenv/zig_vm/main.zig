//! Command-line entry point for the toy RPN stack-VM calculator.

const std = @import("std");
const vm = @import("vm.zig");
const lexer = @import("lexer.zig");
const bytecode_vm = @import("bytecode_vm.zig");
const stack = @import("stack.zig");

/// A short usage banner. The example lines deliberately contain code-shaped
/// text so we can confirm that text inside a multiline string is never parsed
/// as real code (no `ghost` symbol, no `/phantom` route should appear).
const usage =
    \\usage: calc "<rpn expression>"
    \\example handler:
    \\    pub fn ghost() void {}
    \\    @app.get("/phantom")
;

pub fn main() void {
    const program = "3 4 + 2 *";
    std.debug.print("{s}\n", .{usage});

    // Tokenize once up front for a quick diagnostic count (bare local call
    // that resolves to lexer.tokenize).
    var tokens: [64]lexer.Token = undefined;
    const count = tokenize(program, &tokens);
    std.debug.print("tokens: {d}\n", .{count});

    // Construct a machine explicitly via the module-qualified factory...
    _ = vm.init(program);

    // ...then evaluate through the module-qualified high-level helper.
    const result = vm.eval(program);
    printValue(result);

    // Now run the *same* program through the compiled bytecode back-end, which
    // reaches lexer.tokenize by way of compiler.compile.
    const compiled = bytecode_vm.evalBytecode(program) catch {
        std.debug.print("bytecode error\n", .{});
        return;
    };
    std.debug.print("bytecode = {d}\n", .{compiled});

    // A tiny diagnostic that also exercises the generic anytype fold.
    const digits = [_]i64{ 3, 4, 2 };
    std.debug.print("operand sum = {d}\n", .{stack.foldSum(&digits)});
}

/// Print a computed VM value to stderr.
fn printValue(v: vm.Value) void {
    switch (v) {
        .int => |n| std.debug.print("= {d}\n", .{n}),
        .err => std.debug.print("= <err>\n", .{}),
    }
}
