//! Executes a compiled `Chunk` on a generic operand stack.
//!
//! Where `vm.zig` walks tokens directly, `BytecodeVm` runs pre-compiled
//! bytecode: it consumes an `opcode.Chunk`, uses the generic `stack.Stack`
//! container for operands, and leans on `compiler` for the source-to-chunk hop.

const std = @import("std");
const opcode = @import("opcode.zig");
const stack = @import("stack.zig");
const compiler = @import("compiler.zig");

const Chunk = opcode.Chunk;
const OpCode = opcode.OpCode;

/// Errors the bytecode interpreter can raise at run time.
pub const RuntimeError = error{
    StackUnderflow,
    StackOverflow,
    DivideByZero,
    BadOpcode,
};

/// A concrete `i64` operand stack sized for the interpreter. This is the one
/// concrete instantiation of the generic `Stack`.
const OperandStack = stack.Stack(i64, 64);

/// A register-free bytecode interpreter over an `opcode.Chunk`.
pub const BytecodeVm = struct {
    /// Instruction-level counters gathered while a chunk runs. Nested beside the
    /// interpreter that owns them, like `Vm.Stats` in vm.zig.
    pub const Metrics = struct {
        steps: u32 = 0,
        max_depth: usize = 0,

        /// Fold in one executed instruction and the current stack depth.
        pub fn record(self: *Metrics, depth: usize) void {
            self.steps += 1;
            if (depth > self.max_depth) self.max_depth = depth;
        }
    };

    chunk: Chunk,
    ip: usize = 0,
    operands: OperandStack = .{},
    metrics: Metrics = .{},

    /// Run the loaded chunk to `halt` and return the top-of-stack result.
    pub fn run(self: *BytecodeVm) RuntimeError!i64 {
        while (self.ip < self.chunk.code_len) {
            const ins = self.chunk.at(self.ip);
            self.ip += 1;
            self.metrics.record(self.operands.len);
            switch (ins.op) {
                .push_const => try self.pushConst(ins.operand),
                .add, .sub, .mul, .div => try self.binary(ins.op),
                .neg => try self.negate(),
                .halt => break,
            }
        }
        return self.operands.peek() catch error.StackUnderflow;
    }

    fn pushConst(self: *BytecodeVm, idx: usize) RuntimeError!void {
        const c = self.chunk.constAt(idx);
        self.operands.push(c.asInt()) catch return error.StackOverflow;
    }

    fn binary(self: *BytecodeVm, op: OpCode) RuntimeError!void {
        const b = self.operands.pop() catch return error.StackUnderflow;
        const a = self.operands.pop() catch return error.StackUnderflow;
        const r = switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => if (b == 0) return error.DivideByZero else @divTrunc(a, b),
            else => return error.BadOpcode,
        };
        self.operands.push(r) catch return error.StackOverflow;
    }

    fn negate(self: *BytecodeVm) RuntimeError!void {
        const a = self.operands.pop() catch return error.StackUnderflow;
        self.operands.push(-a) catch return error.StackOverflow;
    }
};

/// Factory: build a `BytecodeVm` around an already-compiled chunk.
pub fn init(chunk: Chunk) BytecodeVm {
    return BytecodeVm{ .chunk = chunk };
}

/// Compile `src` and run it through the bytecode VM in one shot.
///
/// The return type threads both the compiler's `CompileError` and the
/// interpreter's `RuntimeError` into a single merged error union.
pub fn evalBytecode(src: []const u8) (opcode.CompileError || RuntimeError)!i64 {
    const chunk = try compiler.compile(src);
    var machine = init(chunk);
    return machine.run();
}
