//! A small backtracking regular-expression engine for `navgraph/grep`.
//!
//! Deliberately minimal — the grep contract needs POSIX-ish patterns over single
//! lines, not a general regex library, and pulling in a dependency for it is not
//! worth the cost. Supported: literals, `.`, character classes (`[a-z]`,
//! `[^...]`, class escapes), groups with alternation, the quantifiers `* + ?`
//! and `{n}` / `{n,}` / `{n,m}` (greedy and lazy), and the `^` / `$` anchors.
//! Not supported: backreferences, lookaround, captures (groups only group).
//!
//! Patterns come from the network, so both halves are bounded and neither
//! recurses — a pattern or an input can make the engine give up, never crash:
//!
//! - The parser walks an explicit stack. A pattern longer than
//!   `max_pattern_bytes` or nested deeper than `max_nesting` is rejected at
//!   compile time (`-32602`).
//! - The matcher walks an explicit backtrack stack, bounded by `budgetFor`
//!   steps, `max_backtrack` live alternatives and `max_conts` continuation
//!   frames — all fixed scratch sized once per compiled pattern. Exceeding any
//!   of them is `error.TooComplex` (`-32002`).
//!
//! Recursion in the matcher was the bug this shape exists to prevent: one frame
//! per matched byte overflowed the stack on an ordinary pattern (`a+b`) over an
//! ordinary long line, which any minified file in a workspace provides.

const std = @import("std");

pub const CompileError = error{
    UnbalancedParen,
    UnbalancedBracket,
    TrailingBackslash,
    NothingToRepeat,
    BadRepeatCount,
    NestingTooDeep,
    PatternTooLong,
    OutOfMemory,
};

pub const MatchError = error{TooComplex};

/// Longest pattern accepted. Past this a "pattern" is a paste.
pub const max_pattern_bytes: usize = 4096;

/// Deepest `(` nesting accepted. The parser is iterative, so this is a contract
/// limit, not a stack limit: it keeps a compiled pattern small enough that the
/// match-time bounds below mean something.
pub const max_nesting: usize = 64;

/// Node visits allowed for one compiled pattern: a fixed base, plus an
/// allowance per byte searched that each `find` adds as it goes.
///
/// Pooled across calls rather than granted per call, because grep runs a
/// pattern once per line: a per-call budget bounds each line but leaves the
/// request itself unbounded, which is the denial of service half of the same
/// defect. Scaling with the bytes actually searched keeps an honest whole-tree
/// grep well inside it.
pub const step_budget_base: u32 = 200_000;
pub const step_budget_per_byte: u32 = 32;

/// Live backtrack alternatives, and live continuation frames, allowed during one
/// match attempt. Both are fixed scratch owned by the compiled `Regex`, so the
/// matcher never allocates and its peak memory does not depend on the input.
pub const max_backtrack: usize = 16_384;
pub const max_conts: usize = 16_384;

const Class = struct {
    negate: bool,
    bits: [32]u8,

    fn set(self: *Class, c: u8) void {
        self.bits[c >> 3] |= @as(u8, 1) << @intCast(c & 7);
    }

    fn has(self: Class, c: u8) bool {
        return (self.bits[c >> 3] >> @intCast(c & 7)) & 1 == 1;
    }
};

const Node = union(enum) {
    literal: u8,
    any,
    class: Class,
    start_anchor,
    end_anchor,
    /// Alternation: one node sequence per branch. A group that does not
    /// alternate is spliced into its parent sequence instead.
    alt: []const []const Node,
    repeat: Repeat,
};

const Repeat = struct {
    /// The quantified subexpression.
    body: []const Node,
    min: u32,
    max: u32,
    greedy: bool,
    /// The body is one node consuming exactly one byte, so the iteration counts
    /// that can match form a contiguous range. Lets the matcher hold the whole
    /// range as one backtrack alternative instead of one per iteration — the
    /// difference between `.*foo` working on a minified line and giving up.
    simple: bool,
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    root: []const Node,
    case_sensitive: bool,
    /// Matcher scratch, sized once at compile time. `find` takes a const
    /// pointer and never allocates; these bound what one match can use.
    conts: []Cont,
    stack: []Thread,
    /// Steps left, as a one-element slice so `find` can spend from it through a
    /// const pointer. A compiled pattern lives for one request, so this is the
    /// request's whole allowance.
    budget: []u32,

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    /// The first match in `input`, or null. `error.TooComplex` when the pattern
    /// exhausts the step budget or the matcher's scratch.
    pub fn find(self: *const Regex, input: []const u8) MatchError!?Match {
        // Positions are u32; a line this long is not a line.
        if (input.len >= std.math.maxInt(u32)) return error.TooComplex;
        const left = &self.budget[0];
        left.* = left.* +| (step_budget_per_byte *| @as(u32, @intCast(input.len)));
        var m = Matcher{
            .input = input,
            .case_sensitive = self.case_sensitive,
            .conts = self.conts,
            .stack = self.stack,
            .left = left,
        };
        var start: u32 = 0;
        while (start <= input.len) : (start += 1) {
            if (try m.runFrom(self.root, start)) |end| return Match{ .start = start, .end = end };
        }
        return null;
    }
};

pub const Match = struct { start: usize, end: usize };

/// Compile `pattern`. Caller owns the returned `Regex`.
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, case_sensitive: bool) CompileError!Regex {
    if (pattern.len > max_pattern_bytes) return error.PatternTooLong;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var p = Parser{ .arena = alloc, .src = pattern, .pos = 0 };
    const root = try p.parse();
    const conts = try alloc.alloc(Cont, max_conts);
    const stack = try alloc.alloc(Thread, max_backtrack);
    const budget = try alloc.alloc(u32, 1);
    budget[0] = step_budget_base;
    return .{
        .arena = arena,
        .root = root,
        .case_sensitive = case_sensitive,
        .conts = conts,
        .stack = stack,
        .budget = budget,
    };
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// An explicit stack of open subexpressions, one frame per unclosed `(`.
/// Recursive descent here was unbounded: the pattern is client-supplied, and a
/// few thousand `(` overflowed the stack before any syntax check ran.
const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    /// One open alternation: the branches closed so far and the sequence being
    /// built. Both live in the compile arena.
    const Frame = struct {
        branches: std.ArrayList([]const Node) = .empty,
        seq: std.ArrayList(Node) = .empty,
    };

    fn parse(self: *Parser) CompileError![]const Node {
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(self.arena);
        try frames.append(self.arena, .{});

        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '(' => {
                    // `frames.items.len - 1` is the current nesting depth.
                    if (frames.items.len > max_nesting) return error.NestingTooDeep;
                    self.pos += 1;
                    try frames.append(self.arena, .{});
                },
                '|' => {
                    self.pos += 1;
                    const top = &frames.items[frames.items.len - 1];
                    try top.branches.append(self.arena, try self.arena.dupe(Node, top.seq.items));
                    top.seq.clearRetainingCapacity();
                },
                ')' => {
                    if (frames.items.len == 1) return error.UnbalancedParen; // a stray ')'
                    self.pos += 1;
                    var inner = frames.pop().?;
                    const body = try self.close(&inner);
                    try self.emit(&frames.items[frames.items.len - 1], body, true);
                },
                else => {
                    const atom = try self.parseAtom();
                    const body = try self.arena.alloc(Node, 1);
                    body[0] = atom;
                    try self.emit(&frames.items[frames.items.len - 1], body, false);
                },
            }
        }
        if (frames.items.len != 1) return error.UnbalancedParen;
        return self.close(&frames.items[0]);
    }

    /// Close an alternation: its single branch as a plain sequence, or one
    /// `alt` node holding every branch.
    fn close(self: *Parser, f: *Frame) CompileError![]const Node {
        if (f.branches.items.len == 0) return self.arena.dupe(Node, f.seq.items);
        try f.branches.append(self.arena, try self.arena.dupe(Node, f.seq.items));
        const owned = try self.arena.dupe([]const Node, f.branches.items);
        const one = try self.arena.alloc(Node, 1);
        one[0] = .{ .alt = owned };
        return one;
    }

    /// Add `body` to the sequence being built, wrapped in a repeat when a
    /// quantifier follows it. Unquantified, a parenthesised subexpression is
    /// spliced in flat — a group that does not alternate only groups.
    fn emit(self: *Parser, top: *Frame, body: []const Node, grouped: bool) CompileError!void {
        if (try self.parseQuantifier(body, grouped)) |rep| {
            try top.seq.append(self.arena, rep);
            return;
        }
        try top.seq.appendSlice(self.arena, body);
    }

    fn parseAtom(self: *Parser) CompileError!Node {
        const c = self.src[self.pos];
        switch (c) {
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return .any;
            },
            '^' => {
                self.pos += 1;
                return .start_anchor;
            },
            '$' => {
                self.pos += 1;
                return .end_anchor;
            },
            '*', '+', '?' => return error.NothingToRepeat,
            '\\' => {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.TrailingBackslash;
                const esc = self.src[self.pos];
                self.pos += 1;
                if (classEscape(esc)) |cls| return .{ .class = cls };
                return .{ .literal = literalEscape(esc) };
            },
            else => {
                self.pos += 1;
                return .{ .literal = c };
            },
        }
    }

    fn parseClass(self: *Parser) CompileError!Node {
        self.pos += 1; // '['
        var cls = Class{ .negate = false, .bits = @splat(0) };
        if (self.pos < self.src.len and self.src[self.pos] == '^') {
            cls.negate = true;
            self.pos += 1;
        }
        // A ']' as the first member is a literal, per POSIX.
        var first = true;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ']' and !first) {
                self.pos += 1;
                return .{ .class = cls };
            }
            first = false;
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.TrailingBackslash;
                const esc = self.src[self.pos];
                self.pos += 1;
                if (classEscape(esc)) |sub| {
                    for (0..256) |b| {
                        const byte: u8 = @intCast(b);
                        if (sub.has(byte) != sub.negate) cls.set(byte);
                    }
                } else cls.set(literalEscape(esc));
                continue;
            }
            self.pos += 1;
            // A range `a-z`, unless the '-' is last (then it is a literal).
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '-' and self.src[self.pos + 1] != ']') {
                const hi = self.src[self.pos + 1];
                self.pos += 2;
                var b: u16 = c;
                while (b <= hi) : (b += 1) cls.set(@intCast(b));
                continue;
            }
            cls.set(c);
        }
        return error.UnbalancedBracket;
    }

    /// The quantifier applied to `body`, or null when none follows.
    fn parseQuantifier(self: *Parser, body: []const Node, grouped: bool) CompileError!?Node {
        if (self.pos >= self.src.len) return null;
        var min: u32 = 0;
        var max: u32 = std.math.maxInt(u32);
        switch (self.src[self.pos]) {
            '*' => self.pos += 1,
            '+' => {
                min = 1;
                self.pos += 1;
            },
            '?' => {
                max = 1;
                self.pos += 1;
            },
            '{' => {
                const parsed = self.parseBounds() catch |err| switch (err) {
                    // A '{' that is not a valid bound is an ordinary literal.
                    error.BadRepeatCount => return null,
                    else => return err,
                };
                min = parsed[0];
                max = parsed[1];
            },
            else => return null,
        }
        if (!grouped and isAnchor(body[0])) return error.NothingToRepeat;
        var greedy = true;
        if (self.pos < self.src.len and self.src[self.pos] == '?') {
            greedy = false;
            self.pos += 1;
        }
        return .{ .repeat = .{
            .body = body,
            .min = min,
            .max = max,
            .greedy = greedy,
            .simple = isSimple(body),
        } };
    }

    /// `{n}` / `{n,}` / `{n,m}`. Leaves `pos` untouched when it is not a bound.
    fn parseBounds(self: *Parser) CompileError![2]u32 {
        const save = self.pos;
        errdefer self.pos = save;
        self.pos += 1; // '{'
        const close_at = std.mem.indexOfScalarPos(u8, self.src, self.pos, '}') orelse return error.BadRepeatCount;
        const body = self.src[self.pos..close_at];
        if (body.len == 0) return error.BadRepeatCount;
        const comma = std.mem.indexOfScalar(u8, body, ',');
        const lo_txt = if (comma) |i| body[0..i] else body;
        const min = std.fmt.parseInt(u32, lo_txt, 10) catch return error.BadRepeatCount;
        var max = min;
        if (comma) |i| {
            const hi_txt = body[i + 1 ..];
            max = if (hi_txt.len == 0)
                std.math.maxInt(u32)
            else
                std.fmt.parseInt(u32, hi_txt, 10) catch return error.BadRepeatCount;
        }
        if (max < min) return error.BadRepeatCount;
        self.pos = close_at + 1;
        return .{ min, max };
    }
};

fn isAnchor(n: Node) bool {
    return n == .start_anchor or n == .end_anchor;
}

/// Whether a repeat body consumes exactly one input byte per iteration.
fn isSimple(body: []const Node) bool {
    if (body.len != 1) return false;
    return switch (body[0]) {
        .literal, .any, .class => true,
        else => false,
    };
}

fn literalEscape(c: u8) u8 {
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        else => c,
    };
}

/// The class an escape denotes (`\d`, `\w`, `\s` and their negations), or null
/// when the escape is a plain literal.
fn classEscape(c: u8) ?Class {
    var cls = Class{ .negate = false, .bits = @splat(0) };
    switch (std.ascii.toLower(c)) {
        'd' => for ('0'..'9' + 1) |b| cls.set(@intCast(b)),
        'w' => {
            for ('0'..'9' + 1) |b| cls.set(@intCast(b));
            for ('a'..'z' + 1) |b| cls.set(@intCast(b));
            for ('A'..'Z' + 1) |b| cls.set(@intCast(b));
            cls.set('_');
        },
        's' => for ([_]u8{ ' ', '\t', '\n', '\r', 11, 12 }) |b| cls.set(b),
        else => return null,
    }
    cls.negate = std.ascii.isUpper(c);
    return cls;
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

/// Where a repeat stands: which one, how many iterations are done, and where
/// the current one began — a zero-width iteration must not loop forever.
const Iter = struct { rep: *const Repeat, done: u32, entry: u32 };

/// What still has to match. The matcher holds one of these as its cursor and
/// materializes copies into `Matcher.conts` only when one has to be pointed at.
pub const Cont = union(enum) {
    /// The whole pattern matched.
    accept,
    /// Match `nodes[i..]`; on running out, re-enter `iter` when set, else
    /// continue with `next`. `iter` is what fuses a repeat's body and its loop
    /// state into one frame, so iterating allocates nothing.
    seq: struct { nodes: []const Node, i: u32, iter: ?Iter, next: *const Cont },
    /// At a repeat's decision point: iterate once more, or leave it.
    loop: struct { iter: Iter, next: *const Cont },
    /// Iteration counts of a simple repeat still to try, walked from `count`
    /// toward `limit`, each ending at `base + count`. Only ever a backtrack
    /// alternative: it stands in for one stack entry per iteration.
    span: struct { base: u32, count: u32, limit: u32, next: *const Cont },
};

/// One suspended alternative.
pub const Thread = struct { cont: Cont, pos: u32 };

/// An iterative backtracking matcher. Every alternative lives on `stack`, so
/// the machine stack depth is constant whatever the pattern or the input.
const Matcher = struct {
    input: []const u8,
    case_sensitive: bool,
    conts: []Cont,
    stack: []Thread,
    n_conts: usize = 0,
    n_stack: usize = 0,
    /// Node visits still allowed. Shared with the compiled pattern, so the bound
    /// covers the whole request and not just one attempt or one line.
    left: *u32,

    /// Match `root` anchored at `start`, or null when it cannot.
    fn runFrom(m: *Matcher, root: []const Node, start: u32) MatchError!?u32 {
        m.n_conts = 0;
        m.n_stack = 0;
        const accept = try m.hold(.accept);
        var cur: Cont = .{ .seq = .{ .nodes = root, .i = 0, .iter = null, .next = accept } };
        var pos: u32 = start;

        while (true) {
            if (m.left.* == 0) return error.TooComplex;
            m.left.* -= 1;

            const advanced = switch (cur) {
                .accept => return pos,
                .seq => |s| try m.stepSeq(s, &cur, &pos),
                .loop => |l| try m.stepLoop(l, &cur, &pos),
                .span => |s| try m.stepSpan(s, &cur, &pos),
            };
            if (advanced) continue;
            if (m.n_stack == 0) return null;
            m.n_stack -= 1;
            cur = m.stack[m.n_stack].cont;
            pos = m.stack[m.n_stack].pos;
        }
    }

    /// Copy `c` into the continuation scratch so it can be pointed at.
    fn hold(m: *Matcher, c: Cont) MatchError!*const Cont {
        if (m.n_conts == m.conts.len) return error.TooComplex;
        m.conts[m.n_conts] = c;
        m.n_conts += 1;
        return &m.conts[m.n_conts - 1];
    }

    fn push(m: *Matcher, c: Cont, pos: u32) MatchError!void {
        if (m.n_stack == m.stack.len) return error.TooComplex;
        m.stack[m.n_stack] = .{ .cont = c, .pos = pos };
        m.n_stack += 1;
    }

    /// Advance past one node. False means this path is dead and the caller
    /// must backtrack.
    fn stepSeq(m: *Matcher, s: @FieldType(Cont, "seq"), cur: *Cont, pos: *u32) MatchError!bool {
        if (s.i == s.nodes.len) {
            cur.* = if (s.iter) |it| .{ .loop = .{ .iter = it, .next = s.next } } else s.next.*;
            return true;
        }
        const rest = Cont{ .seq = .{ .nodes = s.nodes, .i = s.i + 1, .iter = s.iter, .next = s.next } };
        switch (s.nodes[s.i]) {
            .literal => |c| {
                if (pos.* >= m.input.len or !m.eql(m.input[pos.*], c)) return false;
                pos.* += 1;
                cur.* = rest;
            },
            .any => {
                if (pos.* >= m.input.len or m.input[pos.*] == '\n') return false;
                pos.* += 1;
                cur.* = rest;
            },
            .class => |*cls| {
                if (pos.* >= m.input.len or !m.inClass(cls, m.input[pos.*])) return false;
                pos.* += 1;
                cur.* = rest;
            },
            .start_anchor => {
                if (pos.* != 0) return false;
                cur.* = rest;
            },
            .end_anchor => {
                if (pos.* != m.input.len) return false;
                cur.* = rest;
            },
            .alt => |branches| {
                const link = try m.hold(rest);
                var j = branches.len;
                while (j > 1) {
                    j -= 1;
                    try m.push(.{ .seq = .{ .nodes = branches[j], .i = 0, .iter = null, .next = link } }, pos.*);
                }
                cur.* = .{ .seq = .{ .nodes = branches[0], .i = 0, .iter = null, .next = link } };
            },
            .repeat => |*r| {
                const link = try m.hold(rest);
                cur.* = .{ .loop = .{ .iter = .{ .rep = r, .done = 0, .entry = pos.* }, .next = link } };
            },
        }
        return true;
    }

    fn stepLoop(m: *Matcher, l: @FieldType(Cont, "loop"), cur: *Cont, pos: *u32) MatchError!bool {
        const r = l.iter.rep;
        if (r.simple and l.iter.done == 0) return m.stepSimple(r, l.next, cur, pos);

        // A zero-width iteration cannot make progress; stop expanding.
        const stalled = l.iter.done != 0 and pos.* == l.iter.entry;
        const may_iterate = l.iter.done < r.max and !stalled;
        const may_exit = l.iter.done >= r.min;
        if (!may_iterate and !may_exit) return false;

        const again = Cont{ .seq = .{
            .nodes = r.body,
            .i = 0,
            .iter = .{ .rep = r, .done = l.iter.done + 1, .entry = pos.* },
            .next = l.next,
        } };
        if (!may_exit) {
            cur.* = again;
        } else if (!may_iterate) {
            cur.* = l.next.*;
        } else if (r.greedy) {
            try m.push(l.next.*, pos.*);
            cur.* = again;
        } else {
            try m.push(again, pos.*);
            cur.* = l.next.*;
        }
        return true;
    }

    /// A repeat whose body eats exactly one byte: run it as far as it goes, then
    /// keep the remaining iteration counts as a single `span` alternative.
    fn stepSimple(m: *Matcher, r: *const Repeat, next: *const Cont, cur: *Cont, pos: *u32) MatchError!bool {
        const base = pos.*;
        var k: u32 = 0;
        while (k < r.max and @as(usize, base) + k < m.input.len and
            m.matchesOne(&r.body[0], m.input[@as(usize, base) + k])) : (k += 1)
        {}
        if (k < r.min) return false;
        const count: u32 = if (r.greedy) k else r.min;
        const limit: u32 = if (r.greedy) r.min else k;
        if (count != limit) {
            const nxt = if (r.greedy) count - 1 else count + 1;
            try m.push(.{ .span = .{ .base = base, .count = nxt, .limit = limit, .next = next } }, base);
        }
        pos.* = base + count;
        cur.* = next.*;
        return true;
    }

    fn stepSpan(m: *Matcher, s: @FieldType(Cont, "span"), cur: *Cont, pos: *u32) MatchError!bool {
        if (s.count != s.limit) {
            const nxt = if (s.limit > s.count) s.count + 1 else s.count - 1;
            try m.push(.{ .span = .{ .base = s.base, .count = nxt, .limit = s.limit, .next = s.next } }, s.base);
        }
        pos.* = s.base + s.count;
        cur.* = s.next.*;
        return true;
    }

    fn matchesOne(m: *const Matcher, n: *const Node, c: u8) bool {
        return switch (n.*) {
            .literal => |lit| m.eql(c, lit),
            .any => c != '\n',
            .class => |*cls| m.inClass(cls, c),
            // `Repeat.simple` admits only the three above.
            else => unreachable,
        };
    }

    fn eql(m: *const Matcher, a: u8, b: u8) bool {
        if (m.case_sensitive) return a == b;
        return std.ascii.toLower(a) == std.ascii.toLower(b);
    }

    fn inClass(m: *const Matcher, cls: *const Class, c: u8) bool {
        var hit = cls.has(c);
        if (!hit and !m.case_sensitive) {
            hit = cls.has(std.ascii.toLower(c)) or cls.has(std.ascii.toUpper(c));
        }
        return hit != cls.negate;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFind(pattern: []const u8, input: []const u8, start: usize, end: usize) !void {
    var re = try compile(testing.allocator, pattern, true);
    defer re.deinit();
    const m = (try re.find(input)) orelse return error.NoMatch;
    try testing.expectEqual(start, m.start);
    try testing.expectEqual(end, m.end);
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    var re = try compile(testing.allocator, pattern, true);
    defer re.deinit();
    try testing.expect((try re.find(input)) == null);
}

test "literals and dot" {
    try expectFind("abc", "xxabcyy", 2, 5);
    try expectFind("a.c", "zzaXc", 2, 5);
    try expectNoMatch("a.c", "a\nc");
    try expectNoMatch("abc", "abd");
}

test "anchors pin the match to the ends of the input" {
    try expectFind("^abc", "abcdef", 0, 3);
    try expectNoMatch("^abc", "xabcdef");
    try expectFind("def$", "abcdef", 3, 6);
    try expectNoMatch("def$", "abcdefg");
    try expectFind("^$", "", 0, 0);
}

test "character classes, ranges and negation" {
    try expectFind("[abc]+", "xxbcayy", 2, 5);
    try expectFind("[a-f0-9]+", "zz1a9fzz", 2, 6);
    try expectFind("[^0-9]+", "12abc34", 2, 5);
    try expectFind("[]]", "x]y", 1, 2);
    try expectFind("[a-]", "x-y", 1, 2);
    try expectNoMatch("[a-c]", "d");
}

test "class escapes inside and outside brackets" {
    try expectFind("\\d+", "ab123cd", 2, 5);
    try expectFind("\\w+", "  foo_1 ", 2, 7);
    try expectFind("\\s+", "ab  cd", 2, 4);
    try expectFind("[\\d_]+", "ab1_2cd", 2, 5);
    try expectFind("\\D+", "12ab34", 2, 4);
}

test "greedy and lazy quantifiers" {
    try expectFind("a*", "aaab", 0, 3);
    try expectFind("a+b", "caaab", 1, 5);
    try expectFind("ab?c", "ac", 0, 2);
    try expectFind("<.*>", "<a><b>", 0, 6);
    try expectFind("<.*?>", "<a><b>", 0, 3);
    try expectFind("a??b", "ab", 0, 2);
}

test "bounded repetition" {
    try expectFind("a{3}", "aaaaa", 0, 3);
    try expectFind("a{2,}", "xaaa", 1, 4);
    try expectFind("a{2,3}b", "aaaab", 1, 5);
    try expectNoMatch("a{4}", "aaa");
    // A '{' that is not a valid bound is a literal.
    try expectFind("a{x", "za{x", 1, 4);
}

test "groups and alternation" {
    try expectFind("(foo|bar)baz", "xxbarbaz", 2, 8);
    try expectFind("(ab)+", "xababy", 1, 5);
    try expectFind("^(a|b)*c", "ababc", 0, 5);
    try expectNoMatch("(foo|bar)baz", "quxbaz");
}

test "escaped metacharacters are literals" {
    try expectFind("a\\.c", "xa.c", 1, 4);
    try expectNoMatch("a\\.c", "abc");
    try expectFind("\\(x\\)", "f(x)", 1, 4);
    try expectFind("a\\tb", "a\tb", 0, 3);
}

test "case-insensitive matching folds literals and classes" {
    var re = try compile(testing.allocator, "Foo[a-z]+", false);
    defer re.deinit();
    const m = (try re.find("xxFOOBAR11")).?;
    try testing.expectEqual(@as(usize, 2), m.start);
    try testing.expectEqual(@as(usize, 8), m.end);
}

test "a zero-width repeat body terminates instead of looping" {
    try expectFind("(a*)*b", "aaab", 0, 4);
    try expectFind("(|a)*b", "b", 0, 1);
}

test "compile rejects malformed patterns" {
    try testing.expectError(error.UnbalancedParen, compile(testing.allocator, "(ab", true));
    try testing.expectError(error.UnbalancedParen, compile(testing.allocator, "ab)", true));
    try testing.expectError(error.UnbalancedBracket, compile(testing.allocator, "[abc", true));
    try testing.expectError(error.TrailingBackslash, compile(testing.allocator, "ab\\", true));
    try testing.expectError(error.NothingToRepeat, compile(testing.allocator, "*abc", true));
    try testing.expectError(error.NothingToRepeat, compile(testing.allocator, "^*", true));
}

test "a pathological pattern reports TooComplex instead of hanging" {
    var re = try compile(testing.allocator, "(a+)+$", true);
    defer re.deinit();
    try testing.expectError(error.TooComplex, re.find("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab"));
}

// --- bounds -----------------------------------------------------------------

test "a deeply nested pattern is rejected, not crashed into" {
    const gpa = testing.allocator;
    // The reviewer's repro: 20k nested groups used to overflow the parser's
    // stack before any syntax check ran.
    const nested = try gpa.alloc(u8, 20_000 * 2 + 1);
    defer gpa.free(nested);
    @memset(nested[0..20_000], '(');
    nested[20_000] = 'a';
    @memset(nested[20_001..], ')');
    try testing.expectError(error.PatternTooLong, compile(gpa, nested, true));

    // Unbalanced, and short enough to reach the parser.
    const opens = try gpa.alloc(u8, 4000);
    defer gpa.free(opens);
    @memset(opens, '(');
    try testing.expectError(error.NestingTooDeep, compile(gpa, opens, true));
}

test "nesting is accepted up to the cap and refused past it" {
    const gpa = testing.allocator;
    var buf: [4 * max_nesting + 8]u8 = undefined;

    const ok = try nest(&buf, max_nesting);
    var re = try compile(gpa, ok, true);
    defer re.deinit();
    const m = (try re.find("xay")).?;
    try testing.expectEqual(@as(usize, 1), m.start);
    try testing.expectEqual(@as(usize, 2), m.end);

    const too_deep = try nest(&buf, max_nesting + 1);
    try testing.expectError(error.NestingTooDeep, compile(gpa, too_deep, true));
}

/// `(((…a…)))` with `depth` levels of parentheses.
fn nest(buf: []u8, depth: usize) ![]const u8 {
    const len = depth * 2 + 1;
    if (len > buf.len) return error.NoSpaceLeft;
    @memset(buf[0..depth], '(');
    buf[depth] = 'a';
    @memset(buf[depth + 1 .. len], ')');
    return buf[0..len];
}

/// A line long enough that a per-byte recursion would overflow the stack.
fn longLine(gpa: std.mem.Allocator, fill: u8, marker: ?struct { at: usize, text: []const u8 }) ![]u8 {
    const line = try gpa.alloc(u8, 300_000);
    @memset(line, fill);
    if (marker) |mk| @memcpy(line[mk.at..][0..mk.text.len], mk.text);
    return line;
}

test "an ordinary pattern on a very long line is bounded, not fatal" {
    const gpa = testing.allocator;
    const line = try longLine(gpa, 'a', null);
    defer gpa.free(line);

    // `a+b` over 300k 'a' — the reviewer's repro. One frame per matched byte
    // used to be a SIGSEGV; the answer now is a bounded refusal.
    var re = try compile(gpa, "a+b", true);
    defer re.deinit();
    try testing.expectError(error.TooComplex, re.find(line));
}

test "a greedy quantifier still scans a very long line" {
    const gpa = testing.allocator;
    const line = try longLine(gpa, 'a', .{ .at = 200_000, .text = "marker" });
    defer gpa.free(line);

    // The whole point of the simple-repeat span: `.*` over a minified line must
    // not cost one backtrack entry per byte.
    var re = try compile(gpa, ".*marker", true);
    defer re.deinit();
    const m = (try re.find(line)).?;
    try testing.expectEqual(@as(usize, 0), m.start);
    try testing.expectEqual(@as(usize, 200_006), m.end);

    var cls = try compile(gpa, "[a-z]+marker", true);
    defer cls.deinit();
    try testing.expectEqual(@as(usize, 200_006), (try cls.find(line)).?.end);
}

test "scanning a long line for something absent is not pathological" {
    const gpa = testing.allocator;
    const line = try longLine(gpa, 'a', null);
    defer gpa.free(line);

    var re = try compile(gpa, "zzz", true);
    defer re.deinit();
    try testing.expect((try re.find(line)) == null);

    var anchored = try compile(gpa, "^b+$", true);
    defer anchored.deinit();
    try testing.expect((try anchored.find(line)) == null);
}

test "a pattern longer than the cap is refused" {
    const gpa = testing.allocator;
    const long = try gpa.alloc(u8, max_pattern_bytes + 1);
    defer gpa.free(long);
    @memset(long, 'a');
    try testing.expectError(error.PatternTooLong, compile(gpa, long, true));

    long[max_pattern_bytes] = 0;
    var re = try compile(gpa, long[0..max_pattern_bytes], true);
    re.deinit();
}

// --- equivalence against a naive reference matcher --------------------------
//
// The reference is the shape this engine replaced: plainly recursive, with no
// budget, no scratch and no simple-repeat shortcut. It is the oracle for the
// rewrite, and is only ever run on inputs small enough for that to be safe.

const ref_step_cap: u32 = 2_000_000;

const RefState = struct { input: []const u8, case_sensitive: bool, steps: u32 = 0 };

const RefFrame = struct {
    nodes: []const Node,
    i: usize,
    next: ?*const RefFrame,
    iter: ?RefIter = null,
};

const RefIter = struct { rep: *const Repeat, done: u32, entry: usize };

fn refRun(st: *RefState, frame: ?*const RefFrame, pos: usize) ?usize {
    st.steps += 1;
    if (st.steps >= ref_step_cap) return null;
    const f = frame orelse return pos;
    if (f.i == f.nodes.len) {
        if (f.iter) |it| return refLoop(st, it, f.next, pos);
        return refRun(st, f.next, pos);
    }
    const rest = RefFrame{ .nodes = f.nodes, .i = f.i + 1, .next = f.next, .iter = f.iter };
    switch (f.nodes[f.i]) {
        .literal => |c| {
            if (pos < st.input.len and refEql(st, st.input[pos], c)) return refRun(st, &rest, pos + 1);
            return null;
        },
        .any => {
            if (pos < st.input.len and st.input[pos] != '\n') return refRun(st, &rest, pos + 1);
            return null;
        },
        .class => |*cls| {
            if (pos < st.input.len and refInClass(st, cls, st.input[pos])) return refRun(st, &rest, pos + 1);
            return null;
        },
        .start_anchor => return if (pos == 0) refRun(st, &rest, pos) else null,
        .end_anchor => return if (pos == st.input.len) refRun(st, &rest, pos) else null,
        .alt => |branches| {
            for (branches) |b| {
                const inner = RefFrame{ .nodes = b, .i = 0, .next = &rest };
                if (refRun(st, &inner, pos)) |end| return end;
                if (st.steps >= ref_step_cap) return null;
            }
            return null;
        },
        .repeat => |*r| return refLoop(st, .{ .rep = r, .done = 0, .entry = pos }, &rest, pos),
    }
}

fn refLoop(st: *RefState, it: RefIter, next: ?*const RefFrame, pos: usize) ?usize {
    st.steps += 1;
    if (st.steps >= ref_step_cap) return null;
    const r = it.rep;
    const stalled = it.done != 0 and pos == it.entry;
    const may_iterate = it.done < r.max and !stalled;
    const may_exit = it.done >= r.min;
    if (may_iterate and r.greedy) {
        if (refIterate(st, it, next, pos)) |end| return end;
        if (st.steps >= ref_step_cap) return null;
    }
    if (may_exit) {
        if (refRun(st, next, pos)) |end| return end;
        if (st.steps >= ref_step_cap) return null;
    }
    if (may_iterate and !r.greedy) return refIterate(st, it, next, pos);
    return null;
}

fn refIterate(st: *RefState, it: RefIter, next: ?*const RefFrame, pos: usize) ?usize {
    const again = RefFrame{
        .nodes = it.rep.body,
        .i = 0,
        .next = next,
        .iter = .{ .rep = it.rep, .done = it.done + 1, .entry = pos },
    };
    return refRun(st, &again, pos);
}

fn refEql(st: *const RefState, a: u8, b: u8) bool {
    if (st.case_sensitive) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn refInClass(st: *const RefState, cls: *const Class, c: u8) bool {
    var hit = cls.has(c);
    if (!hit and !st.case_sensitive) {
        hit = cls.has(std.ascii.toLower(c)) or cls.has(std.ascii.toUpper(c));
    }
    return hit != cls.negate;
}

const RefOutcome = union(enum) { exhausted, found: ?Match };

fn refFind(re: *const Regex, input: []const u8) RefOutcome {
    var start: usize = 0;
    while (start <= input.len) : (start += 1) {
        var st = RefState{ .input = input, .case_sensitive = re.case_sensitive };
        const frame = RefFrame{ .nodes = re.root, .i = 0, .next = null };
        if (refRun(&st, &frame, start)) |end| return .{ .found = Match{ .start = start, .end = end } };
        if (st.steps >= ref_step_cap) return .exhausted;
    }
    return .{ .found = null };
}

/// Random patterns over the supported syntax, built into `buf`.
const Gen = struct {
    rng: std.Random,
    buf: []u8,
    len: usize = 0,

    fn put(self: *Gen, s: []const u8) void {
        if (self.len + s.len > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn pick(self: *Gen, comptime options: []const []const u8) void {
        self.put(options[self.rng.uintLessThan(usize, options.len)]);
    }

    fn seq(self: *Gen, depth: u32) void {
        const n = self.rng.intRangeAtMost(u32, 1, 3);
        for (0..n) |_| {
            if (depth != 0 and self.rng.uintLessThan(u8, 4) == 0) {
                self.put("(");
                self.alt(depth - 1);
                self.put(")");
            } else {
                self.pick(&.{ "a", "b", "c", ".", "[ab]", "[^a]", "\\d", "\\w", "x" });
            }
            self.pick(&.{ "", "", "", "*", "+", "?", "*?", "+?", "??", "{2}", "{1,2}", "{0,2}", "{2,}" });
        }
    }

    fn alt(self: *Gen, depth: u32) void {
        self.seq(depth);
        while (self.rng.uintLessThan(u8, 3) == 0) {
            self.put("|");
            self.seq(depth);
        }
    }

    fn pattern(self: *Gen) []const u8 {
        self.len = 0;
        if (self.rng.uintLessThan(u8, 5) == 0) self.put("^");
        self.alt(2);
        if (self.rng.uintLessThan(u8, 5) == 0) self.put("$");
        return self.buf[0..self.len];
    }
};

test "the iterative matcher agrees with the naive reference on random patterns" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x6e6176677261_7068);
    const rng = prng.random();

    var pat_buf: [256]u8 = undefined;
    var in_buf: [12]u8 = undefined;
    var compared: u32 = 0;
    var skipped: u32 = 0;

    for (0..4000) |_| {
        var gen = Gen{ .rng = rng, .buf = &pat_buf };
        const pattern = gen.pattern();
        const case_sensitive = rng.boolean();

        var re = compile(gpa, pattern, case_sensitive) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // A generated pattern can still be ill-formed (`a{2,}{3}` and the
            // like); the point is the matcher, not the generator.
            else => continue,
        };
        defer re.deinit();

        const n = rng.uintLessThan(usize, in_buf.len + 1);
        for (in_buf[0..n]) |*c| c.* = "aabbcxA \n"[rng.uintLessThan(usize, 9)];
        const input = in_buf[0..n];

        const ours = re.find(input) catch |err| switch (err) {
            error.TooComplex => {
                skipped += 1;
                continue;
            },
        };
        switch (refFind(&re, input)) {
            .exhausted => skipped += 1,
            .found => |want| {
                compared += 1;
                if (want) |w| {
                    const got = ours orelse {
                        std.debug.print("pattern {s} input '{s}': no match, want {d}..{d}\n", .{ pattern, input, w.start, w.end });
                        return error.TestExpectedEqual;
                    };
                    testing.expectEqual(w, got) catch |err| {
                        std.debug.print("pattern {s} input '{s}'\n", .{ pattern, input });
                        return err;
                    };
                } else if (ours) |got| {
                    std.debug.print("pattern {s} input '{s}': matched {d}..{d}, want none\n", .{ pattern, input, got.start, got.end });
                    return error.TestExpectedEqual;
                }
            },
        }
    }
    // The comparison must actually be happening.
    try testing.expect(compared > 3000);
    try testing.expect(skipped < compared / 10);
}
