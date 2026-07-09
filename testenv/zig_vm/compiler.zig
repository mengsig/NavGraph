//! Translates a source string into a `Chunk` of bytecode.
//!
//! The compiler reuses the existing `lexer` for tokenization and emits into an
//! `opcode.Chunk`, bridging the text front-end and the bytecode back-end. This
//! is the module that ties `lexer` and `opcode` together with an `@import` each.

const std = @import("std");
const lexer = @import("lexer.zig");
const opcode = @import("opcode.zig");

const Chunk = opcode.Chunk;
const Instruction = opcode.Instruction;
const CompileError = opcode.CompileError;

/// Compile an RPN source string into a ready-to-run `Chunk`.
///
/// Returns `error.EmptyProgram` when the input holds no real tokens, or one of
/// the `Chunk` capacity errors if the program is too large.
pub fn compile(src: []const u8) CompileError!Chunk {
    var chunk = opcode.newChunk();
    var buf: [128]lexer.Token = undefined;
    const n = lexer.tokenize(src, &buf);

    var emitted: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = buf[i];
        switch (t.kind) {
            .number => {
                const idx = try chunk.addConst(.{ .int = t.value });
                try chunk.emit(.{ .op = .push_const, .operand = idx });
                emitted += 1;
            },
            .eof => {},
            else => {
                try chunk.emit(.{ .op = opForToken(t.kind) });
                emitted += 1;
            },
        }
    }
    if (emitted == 0) return error.EmptyProgram;
    try chunk.emit(.{ .op = .halt });
    return chunk;
}

/// Map a lexer token kind to its arithmetic opcode.
fn opForToken(kind: lexer.TokenKind) opcode.OpCode {
    return switch (kind) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        else => .halt,
    };
}

// intentionally dead (fixture): a constant-folding peephole pass we sketched but
// never wired into `compile`.
fn foldConstants(chunk: *Chunk) void {
    _ = chunk;
}
