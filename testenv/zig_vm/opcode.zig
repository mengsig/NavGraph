//! Bytecode definitions for the compiled execution path.
//!
//! A `Chunk` is a flat array of `Instruction`s plus a side table of constants.
//! This is exactly the data the `compiler` emits and the bytecode VM consumes.

const std = @import("std");

/// The instruction set of the bytecode VM. Backed by an explicit `u8` tag so a
/// `Chunk` could be serialized byte-for-byte.
pub const OpCode = enum(u8) {
    push_const,
    add,
    sub,
    mul,
    div,
    neg,
    halt,

    /// Number of operands this opcode pops off the operand stack.
    pub fn arity(self: OpCode) u8 {
        return switch (self) {
            .push_const, .halt => 0,
            .neg => 1,
            .add, .sub, .mul, .div => 2,
        };
    }
};

/// A compile-time constant that a `push_const` instruction can reference.
pub const Constant = union(enum) {
    int: i64,
    /// A boolean flag constant. Unused by the arithmetic path today, but part of
    /// the value model so the union has more than one active variant.
    flag: bool,

    /// Render the constant as an `i64`, coercing booleans to 0/1.
    pub fn asInt(self: Constant) i64 {
        return switch (self) {
            .int => |n| n,
            .flag => |b| if (b) 1 else 0,
        };
    }
};

/// A single decoded instruction: an opcode plus an inline operand index.
pub const Instruction = struct {
    op: OpCode,
    operand: usize = 0,
};

/// Errors raised while assembling a `Chunk`.
pub const CompileError = error{
    TooManyInstructions,
    TooManyConstants,
    EmptyProgram,
};

/// A bounded, self-contained unit of bytecode: an instruction array plus its
/// constant pool. The nested fixed arrays keep the whole thing allocation-free.
pub const Chunk = struct {
    const max_code = 256;
    const max_consts = 64;

    code: [max_code]Instruction = undefined,
    code_len: usize = 0,
    consts: [max_consts]Constant = undefined,
    consts_len: usize = 0,

    /// Append an instruction, failing if the code array is full.
    pub fn emit(self: *Chunk, ins: Instruction) CompileError!void {
        if (self.code_len >= max_code) return error.TooManyInstructions;
        self.code[self.code_len] = ins;
        self.code_len += 1;
    }

    /// Intern a constant and return its index for use as an operand.
    pub fn addConst(self: *Chunk, c: Constant) CompileError!usize {
        if (self.consts_len >= max_consts) return error.TooManyConstants;
        const idx = self.consts_len;
        self.consts[self.consts_len] = c;
        self.consts_len += 1;
        return idx;
    }

    /// Fetch the instruction at instruction-pointer `ip`.
    pub fn at(self: *const Chunk, ip: usize) Instruction {
        return self.code[ip];
    }

    /// Fetch a previously-interned constant by index.
    pub fn constAt(self: *const Chunk, idx: usize) Constant {
        return self.consts[idx];
    }
};

/// Factory: an empty chunk ready to emit into.
pub fn newChunk() Chunk {
    return Chunk{};
}

// intentionally dead (fixture): an alternate wide-operand instruction layout we
// sketched for two-address form but never ended up needing.
const WideInstruction = struct {
    op: OpCode,
    lhs: usize = 0,
    rhs: usize = 0,
};
