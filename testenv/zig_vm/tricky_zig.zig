//! Constructs that break heuristic parsers, collected in one file so the
//! accuracy benchmark has a per-language "hard cases" corpus beside the
//! ordinary VM sources. Nothing in the VM calls it: `tests/golden/zig.json`
//! records exactly which definitions and edges a correct indexer must find here.

const std = @import("std");
const lx = @import("lexer.zig");
const opcode_mod = @import("opcode.zig");

/// Re-export under a new name: `Token` here IS `lexer.Token`.
pub const Token = lx.Token;
/// Second-hop alias of an imported type.
pub const Op = opcode_mod.OpCode;

/// A file-level constant whose name a local below deliberately shadows.
pub const budget: usize = 16;

/// Outer container holding a nested container, which holds a nested enum.
pub const Registry = struct {
    /// Nested type: `Registry.Entry`.
    pub const Entry = struct {
        name: []const u8,
        weight: u32 = 0,

        /// Three levels deep, and an enum carrying a method.
        pub const Tag = enum {
            cold,
            warm,

            pub fn hotter(self: Tag) bool {
                return self == .warm;
            }
        };

        /// Inner method calling the nested enum's method.
        pub fn isHot(self: Entry, tag: Tag) bool {
            return tag.hotter() and self.weight > 0;
        }
    };

    entries: [8]Entry = undefined,
    len: usize = 0,

    /// Namespaced constructor: no `self`, so it is Zig's static method.
    pub fn empty() Registry {
        return Registry{};
    }

    /// Getter/setter pair over the length field.
    pub fn count(self: *const Registry) usize {
        return self.len;
    }

    pub fn setCount(self: *Registry, n: usize) void {
        self.len = n;
    }

    /// Signature spanning three lines with a trailing comma.
    pub fn push(
        self: *Registry,
        entry: Entry,
    ) bool {
        if (self.len >= self.entries.len) return false;
        self.entries[self.len] = entry;
        self.len += 1;
        return true;
    }

    /// Method call on a typed parameter, reached through a field chain.
    pub fn promote(self: *Registry, tag: Entry.Tag) usize {
        var hot: usize = 0;
        for (self.entries[0..self.len]) |e| {
            if (e.isHot(tag)) hot += 1;
        }
        return hot;
    }
};

/// Comptime generic type constructor: a fresh struct type per (T, cap).
pub fn Ring(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        buf: [cap]T = undefined,
        head: usize = 0,

        pub fn put(self: *Self, v: T) void {
            self.buf[self.head % cap] = v;
            self.head += 1;
        }

        pub fn depth(self: *const Self) usize {
            return @min(self.head, cap);
        }
    };
}

/// The single concrete instantiation, so the generic has a real use site.
const TokenRing = Ring(Token, 4);

/// A vtable interface: Zig's stand-in for a trait/protocol.
pub const Sink = struct {
    ptr: *anyopaque,
    writeFn: *const fn (*anyopaque, i64) void,

    /// Dispatch through the function-pointer field.
    pub fn write(self: Sink, v: i64) void {
        self.writeFn(self.ptr, v);
    }
};

/// One implementation behind `Sink`.
pub const CountingSink = struct {
    seen: u32 = 0,

    fn writeImpl(ctx: *anyopaque, v: i64) void {
        const self: *CountingSink = @ptrCast(@alignCast(ctx));
        _ = v;
        self.seen += 1;
    }

    /// Build the interface value pointing back at this implementation.
    pub fn sink(self: *CountingSink) Sink {
        return .{ .ptr = self, .writeFn = writeImpl };
    }
};

fn doubleValue(v: i64) i64 {
    return v * 2;
}

/// A function bound to a constant — Zig's closure-in-a-variable shape.
const doubler: *const fn (i64) i64 = doubleValue;

/// Reaches `doubleValue` only through the constant binding.
pub fn applyDoubler(v: i64) i64 {
    return doubler(v);
}

/// Zig forbids shadowing a declaration, so the near-miss is a *field* named
/// like the file-level `budget` constant: `Quota.budget` and `budget` are two
/// different things spelled the same.
pub const Quota = struct {
    budget: usize = 4,

    pub fn scale(self: Quota, n: usize) usize {
        return n * self.budget;
    }
};

pub fn shadowBudget(n: usize) usize {
    const q = Quota{};
    return q.scale(n);
}

/// Third `init` in this tree (vm.zig and bytecode_vm.zig have the others), so a
/// name-only resolver has to choose by file.
pub fn init() Registry {
    return Registry.empty();
}

/// Comptime parameter driving a switch, plus a call into the imported enum.
pub fn describe(comptime kind: lx.TokenKind) []const u8 {
    return switch (kind) {
        .number => "num",
        .plus, .minus, .star, .slash => kind.name(),
        .eof => "end",
    };
}

/// Multi-value return destructured at the call site.
pub fn split() struct { usize, usize } {
    return .{ 1, 2 };
}

pub fn useSplit() usize {
    const lo, const hi = split();
    return lo + hi;
}

/// Code-shaped text inside a multiline string: data, never symbols.
const banner =
    \\pub fn phantomFromString() void {}
    \\const PhantomStruct = struct { x: i32 };
    \\@app.get("/phantom-zig")
;

// pub fn phantomFromComment() void {}

/// One root that exercises the import, the generic instantiation, the vtable
/// interface, the function constant and the shadowed global together.
pub fn run(src: []const u8) i64 {
    var buf: [16]Token = undefined;
    const n = lx.tokenize(src, &buf);

    var ring = TokenRing{};
    var i: usize = 0;
    while (i < n) : (i += 1) ring.put(buf[i]);

    var counter = CountingSink{};
    const s = counter.sink();
    s.write(@intCast(ring.depth()));

    var reg = init();
    _ = reg.push(.{ .name = banner, .weight = 1 });
    reg.setCount(reg.count());
    const hot = reg.promote(.warm);

    return applyDoubler(@intCast(hot + shadowBudget(budget)));
}
