//! A small generic bounded stack, reused by the bytecode VM.
//!
//! `Stack(T, cap)` is a comptime-parameterized fixed-capacity stack. It is the
//! one piece of the VM that is fully generic over its element type, so it also
//! exercises `comptime T` and `anytype` in one place.

const std = @import("std");

/// Errors a bounded stack can raise.
pub const StackError = error{
    Overflow,
    Underflow,
};

/// A fixed-capacity LIFO stack generic over element type `T` and capacity `cap`.
/// Returns a fresh struct type per instantiation (classic Zig generic idiom).
pub fn Stack(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        items: [cap]T = undefined,
        len: usize = 0,

        /// Push `v`, or fail with `error.Overflow` when the stack is full.
        pub fn push(self: *Self, v: T) StackError!void {
            if (self.len >= cap) return error.Overflow;
            self.items[self.len] = v;
            self.len += 1;
        }

        /// Pop the top element, or fail with `error.Underflow` when empty.
        pub fn pop(self: *Self) StackError!T {
            if (self.len == 0) return error.Underflow;
            self.len -= 1;
            return self.items[self.len];
        }

        /// Return the top element without removing it.
        pub fn peek(self: *const Self) StackError!T {
            if (self.len == 0) return error.Underflow;
            return self.items[self.len - 1];
        }

        /// True when nothing is on the stack.
        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        /// Reset to empty without touching the backing storage.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

/// Factory: build an empty `Stack(T, cap)` value in one call.
pub fn makeStack(comptime T: type, comptime cap: usize) Stack(T, cap) {
    return Stack(T, cap){};
}

/// Sum any indexable, iterable value of integers. Generic on `anytype` on
/// purpose to give navgraph an `anytype` parameter to render.
pub fn foldSum(items: anytype) i64 {
    var total: i64 = 0;
    for (items) |it| total += @as(i64, it);
    return total;
}

// intentionally dead (fixture): a spare capacity-doubling helper nothing calls.
fn growHint(current: usize) usize {
    return if (current == 0) 8 else current * 2;
}
