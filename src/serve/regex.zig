//! A small backtracking regular-expression engine for `navgraph/grep`.
//!
//! Deliberately minimal — the grep contract needs POSIX-ish patterns over single
//! lines, not a general regex library, and pulling in a dependency for it is not
//! worth the cost. Supported: literals, `.`, character classes (`[a-z]`,
//! `[^...]`, class escapes), groups with alternation, the quantifiers `* + ?`
//! and `{n}` / `{n,}` / `{n,m}` (greedy and lazy), and the `^` / `$` anchors.
//! Not supported: backreferences, lookaround, captures (groups only group).
//!
//! Backtracking is bounded by `step_budget`: a pathological pattern reports
//! `error.TooComplex` instead of hanging, and the caller turns that into a
//! JSON-RPC error rather than silently returning no matches.

const std = @import("std");

pub const CompileError = error{
    UnbalancedParen,
    UnbalancedBracket,
    TrailingBackslash,
    NothingToRepeat,
    BadRepeatCount,
    OutOfMemory,
};

pub const MatchError = error{TooComplex};

/// Steps (one per node visit) before a match is abandoned as pathological.
pub const step_budget: u32 = 200_000;

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
    /// Alternation: each branch is a node sequence. A plain group is one branch.
    group: []const []const Node,
    repeat: Repeat,
};

const Repeat = struct {
    node: *const Node,
    min: u32,
    max: u32,
    greedy: bool,
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    root: []const Node,
    case_sensitive: bool,

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    /// The first match in `input`, or null. `error.TooComplex` when the pattern
    /// exhausts the backtracking budget.
    pub fn find(self: *const Regex, input: []const u8) MatchError!?Match {
        var start: usize = 0;
        while (start <= input.len) : (start += 1) {
            var st = State{
                .input = input,
                .case_sensitive = self.case_sensitive,
                .steps = 0,
            };
            const frame = Frame{ .nodes = self.root, .i = 0, .next = null };
            if (run(&st, &frame, start)) |end| return Match{ .start = start, .end = end };
            if (st.steps >= step_budget) return error.TooComplex;
        }
        return null;
    }
};

pub const Match = struct { start: usize, end: usize };

/// Compile `pattern`. Caller owns the returned `Regex`.
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, case_sensitive: bool) CompileError!Regex {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p = Parser{ .arena = arena.allocator(), .src = pattern, .pos = 0 };
    const root = try p.parseAlternation();
    if (p.pos != pattern.len) return error.UnbalancedParen; // a stray ')'
    return .{ .arena = arena, .root = root, .case_sensitive = case_sensitive };
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    /// `alt := seq ('|' seq)*` — always returns a single-node sequence holding a
    /// `group`, so the caller can treat any subexpression uniformly.
    fn parseAlternation(self: *Parser) CompileError![]const Node {
        var branches: std.ArrayList([]const Node) = .empty;
        defer branches.deinit(self.arena);
        try branches.append(self.arena, try self.parseSequence());
        while (self.pos < self.src.len and self.src[self.pos] == '|') {
            self.pos += 1;
            try branches.append(self.arena, try self.parseSequence());
        }
        if (branches.items.len == 1) return branches.items[0];
        const owned = try self.arena.dupe([]const Node, branches.items);
        const one = try self.arena.alloc(Node, 1);
        one[0] = .{ .group = owned };
        return one;
    }

    fn parseSequence(self: *Parser) CompileError![]const Node {
        var out: std.ArrayList(Node) = .empty;
        defer out.deinit(self.arena);
        while (self.pos < self.src.len and self.src[self.pos] != '|' and self.src[self.pos] != ')') {
            const atom = try self.parseAtom();
            try out.append(self.arena, try self.parseQuantifier(atom));
        }
        return self.arena.dupe(Node, out.items);
    }

    fn parseAtom(self: *Parser) CompileError!Node {
        const c = self.src[self.pos];
        switch (c) {
            '(' => {
                self.pos += 1;
                const inner = try self.parseAlternation();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.UnbalancedParen;
                self.pos += 1;
                const branches = try self.arena.alloc([]const Node, 1);
                branches[0] = inner;
                return .{ .group = branches };
            },
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

    fn parseQuantifier(self: *Parser, atom: Node) CompileError!Node {
        if (self.pos >= self.src.len) return atom;
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
                    error.BadRepeatCount => return atom,
                    else => return err,
                };
                min = parsed[0];
                max = parsed[1];
            },
            else => return atom,
        }
        if (isAnchor(atom)) return error.NothingToRepeat;
        var greedy = true;
        if (self.pos < self.src.len and self.src[self.pos] == '?') {
            greedy = false;
            self.pos += 1;
        }
        const boxed = try self.arena.create(Node);
        boxed.* = atom;
        return .{ .repeat = .{ .node = boxed, .min = min, .max = max, .greedy = greedy } };
    }

    /// `{n}` / `{n,}` / `{n,m}`. Leaves `pos` untouched when it is not a bound.
    fn parseBounds(self: *Parser) CompileError![2]u32 {
        const save = self.pos;
        errdefer self.pos = save;
        self.pos += 1; // '{'
        const close = std.mem.indexOfScalarPos(u8, self.src, self.pos, '}') orelse return error.BadRepeatCount;
        const body = self.src[self.pos..close];
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
        self.pos = close + 1;
        return .{ min, max };
    }
};

fn isAnchor(n: Node) bool {
    return n == .start_anchor or n == .end_anchor;
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

const State = struct {
    input: []const u8,
    case_sensitive: bool,
    steps: u32,
};

/// The continuation stack: what remains to match after the current node.
/// `repeat` frames re-enter a quantified subexpression; `entry` is the position
/// the last iteration started at, which stops a zero-width body looping forever.
const Frame = struct {
    nodes: []const Node,
    i: usize,
    next: ?*const Frame,
    repeat: ?Repeat = null,
    done: u32 = 0,
    entry: usize = 0,
};

fn run(st: *State, frame: ?*const Frame, pos: usize) ?usize {
    st.steps += 1;
    if (st.steps >= step_budget) return null;
    const f = frame orelse return pos;
    if (f.repeat) |r| return runRepeat(st, f, r, pos);
    if (f.i == f.nodes.len) return run(st, f.next, pos);

    const rest = Frame{ .nodes = f.nodes, .i = f.i + 1, .next = f.next };
    switch (f.nodes[f.i]) {
        .literal => |c| {
            if (pos < st.input.len and byteEql(st, st.input[pos], c)) return run(st, &rest, pos + 1);
            return null;
        },
        .any => {
            if (pos < st.input.len and st.input[pos] != '\n') return run(st, &rest, pos + 1);
            return null;
        },
        .class => |cls| {
            if (pos < st.input.len and classMatch(st, cls, st.input[pos])) return run(st, &rest, pos + 1);
            return null;
        },
        .start_anchor => return if (pos == 0) run(st, &rest, pos) else null,
        .end_anchor => return if (pos == st.input.len) run(st, &rest, pos) else null,
        .group => |branches| {
            for (branches) |b| {
                const inner = Frame{ .nodes = b, .i = 0, .next = &rest };
                if (run(st, &inner, pos)) |end| return end;
                if (st.steps >= step_budget) return null;
            }
            return null;
        },
        .repeat => |r| {
            const loop = Frame{ .nodes = &.{}, .i = 0, .next = &rest, .repeat = r, .done = 0, .entry = pos };
            return runRepeat(st, &loop, r, pos);
        },
    }
}

fn runRepeat(st: *State, f: *const Frame, r: Repeat, pos: usize) ?usize {
    // A zero-width iteration cannot make progress; stop expanding.
    const stalled = f.done != 0 and pos == f.entry;
    const may_iterate = f.done < r.max and !stalled;
    const may_exit = f.done >= r.min;

    if (may_iterate and r.greedy) {
        if (iterate(st, f, r, pos)) |end| return end;
        if (st.steps >= step_budget) return null;
    }
    if (may_exit) {
        if (run(st, f.next, pos)) |end| return end;
        if (st.steps >= step_budget) return null;
    }
    if (may_iterate and !r.greedy) return iterate(st, f, r, pos);
    return null;
}

/// Match the quantified node once more, continuing back into the same loop.
fn iterate(st: *State, f: *const Frame, r: Repeat, pos: usize) ?usize {
    const again = Frame{
        .nodes = &.{},
        .i = 0,
        .next = f.next,
        .repeat = r,
        .done = f.done + 1,
        .entry = pos,
    };
    const body: [1]Node = .{r.node.*};
    const once = Frame{ .nodes = &body, .i = 0, .next = &again };
    return run(st, &once, pos);
}

fn byteEql(st: *const State, a: u8, b: u8) bool {
    if (st.case_sensitive) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn classMatch(st: *const State, cls: Class, c: u8) bool {
    var hit = cls.has(c);
    if (!hit and !st.case_sensitive) {
        hit = cls.has(std.ascii.toLower(c)) or cls.has(std.ascii.toUpper(c));
    }
    return hit != cls.negate;
}

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
