//! A minimal stack machine that evaluates tokenized RPN arithmetic.
//!
//! `Vm` owns a fixed operand stack; `push`/`pop`/`run`/`apply` form its call
//! graph. `eval` is the one-shot convenience entry point.

const std = @import("std");
const lexer = @import("lexer.zig");

/// A value living on the VM operand stack.
pub const Value = union(enum) {
    int: i64,
    err: void,
};

/// A stack-based virtual machine over a byte-slice program.
pub const Vm = struct {
    stack: [64]Value = undefined,
    sp: usize = 0,
    src: []const u8,

    /// Per-run bookkeeping counters, kept beside the machine that owns them.
    pub const Stats = struct {
        ops: u32 = 0,

        /// Record that one more operation has executed.
        pub fn bump(self: *Stats) void {
            self.ops += 1;
        }
    };

    /// Push a value onto the operand stack.
    pub fn push(self: *Vm, v: Value) void {
        self.stack[self.sp] = v;
        self.sp += 1;
    }

    /// Pop the top value off the operand stack.
    pub fn pop(self: *Vm) Value {
        self.sp -= 1;
        return self.stack[self.sp];
    }

    /// Run the program to completion and return the final stack value.
    pub fn run(self: *Vm) Value {
        var stats = Stats{};
        var buf: [128]lexer.Token = undefined;
        const n = lexer.tokenize(self.src, &buf);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const t = buf[i];
            if (t.kind == .number) {
                self.push(.{ .int = t.value });
            } else if (t.kind != .eof) {
                self.apply(t.kind);
                stats.bump();
            }
        }
        return self.pop();
    }

    fn apply(self: *Vm, kind: lexer.TokenKind) void {
        const b = self.pop();
        const a = self.pop();
        self.push(combine(a, b, kind));
    }
};

fn combine(a: Value, b: Value, kind: lexer.TokenKind) Value {
    return switch (kind) {
        .plus => .{ .int = a.int + b.int },
        .minus => .{ .int = a.int - b.int },
        .star => .{ .int = a.int * b.int },
        else => .{ .int = 0 },
    };
}

/// Construct a VM bound to `src`, with an empty stack.
pub fn init(src: []const u8) Vm {
    return Vm{ .src = src, .sp = 0 };
}

/// Evaluate an RPN expression end to end and return its result.
pub fn eval(src: []const u8) Value {
    var v = Vm.init(src);
    return v.run();
}
