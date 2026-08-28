//! Ranked symbol search, reference search, and overlay-aware grep.
//!
//! Ranking is the contract's: exact > prefix > word-boundary > subsequence,
//! ties broken by fan-in and then by the shorter file path. Matching is a fuzzy
//! subsequence over the symbol's `qualified` name, so `Idx.lkp` finds
//! `Index.lookup`.

const std = @import("std");
const model = @import("../model.zig");
const index_mod = @import("../index.zig");
const query = @import("../query.zig");
const regex = @import("regex.zig");

const SymbolId = model.SymbolId;
const Index = index_mod.Index;

/// Longest query we score. Beyond this a "fuzzy" search is really a paste.
pub const max_query_len: usize = 128;

/// A scored match: the rank and where in the haystack each query character
/// landed (the contract's `matches`).
pub const Score = struct {
    value: i32,
    count: u8,
    positions: [max_query_len]u32,

    pub fn slice(self: *const Score) []const u32 {
        return self.positions[0..self.count];
    }
};

/// Score `needle` against `haystack`, or null when it is not even a
/// subsequence. An empty needle matches everything at rank 0.
///
/// The tiers are the contract's, decided by direct string tests rather than by
/// the fuzzy match, so a prefix always outranks a word-boundary hit and both
/// outrank a mere subsequence.
pub fn score(haystack: []const u8, needle: []const u8) ?Score {
    if (needle.len == 0) return .{ .value = 0, .count = 0, .positions = undefined };
    if (needle.len > max_query_len) return null;

    if (std.ascii.eqlIgnoreCase(haystack, needle)) return run(0, needle.len, 4000);
    if (haystack.len > needle.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle)) {
        return run(0, needle.len, 3000);
    }
    if (indexOfIgnoreCase(haystack, needle)) |at| {
        const base: i32 = if (isBoundary(haystack, @intCast(at))) 2000 else 1500;
        return run(at, needle.len, base - positionPenalty(at));
    }
    return subsequence(haystack, needle);
}

/// A contiguous match of `len` characters starting at `at`.
fn run(at: usize, len: usize, rank: i32) Score {
    var s = Score{ .value = rank, .count = @intCast(len), .positions = undefined };
    for (0..len) |i| s.positions[i] = @intCast(at + i);
    return s;
}

/// Later matches rank below earlier ones within a tier, but never enough to
/// drop below the tier beneath.
fn positionPenalty(at: usize) i32 {
    return @intCast(@min(at, 50));
}

fn subsequence(haystack: []const u8, needle: []const u8) ?Score {
    var s = Score{ .value = 0, .count = 0, .positions = undefined };
    var h: usize = 0;
    for (needle) |c| {
        while (h < haystack.len and !eqFold(haystack[h], c)) h += 1;
        if (h == haystack.len) return null;
        s.positions[s.count] = @intCast(h);
        s.count += 1;
        h += 1;
    }
    tighten(&s, haystack, needle);

    var boundary_hits: i32 = 0;
    var adjacent: i32 = 0;
    for (s.slice(), 0..) |p, i| {
        if (isBoundary(haystack, p)) boundary_hits += 1;
        if (i != 0 and p == s.positions[i - 1] + 1) adjacent += 1;
    }
    s.value = 1000 + boundary_hits * 20 + adjacent * 10 - positionPenalty(s.positions[0]);
    return s;
}

/// Slide each matched position as far right as it can go without passing the
/// next one. Greedy matching alone binds `rO` to `re`solve`One`'s first `o`;
/// tightening moves it onto the capital `O`, so the boundary bonus is earned.
fn tighten(s: *Score, haystack: []const u8, needle: []const u8) void {
    if (s.count == 0) return;
    var i: usize = s.count;
    var limit: usize = haystack.len;
    while (i > 0) {
        i -= 1;
        const lowest = s.positions[i];
        var j = limit;
        while (j > lowest) {
            j -= 1;
            if (eqFold(haystack[j], needle[i])) {
                s.positions[i] = @intCast(j);
                break;
            }
        }
        limit = s.positions[i];
    }
}

/// Whether index `i` starts a word: the string start, after a separator, or a
/// lower→upper transition (camelCase).
fn isBoundary(haystack: []const u8, i: u32) bool {
    if (i == 0) return true;
    const prev = haystack[i - 1];
    if (prev == '.' or prev == '_' or prev == '-' or prev == '/' or prev == ':') return true;
    return std.ascii.isLower(prev) and std.ascii.isUpper(haystack[i]);
}

fn eqFold(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// `Parent.name` for a symbol, written into `buf`. Falls back to the bare name
/// when the qualified form does not fit.
pub fn qualifiedInto(idx: *const Index, sym: model.Symbol, buf: []u8) []const u8 {
    if (sym.parent == model.invalid_symbol) return sym.name;
    const parent = idx.graph.symbols[sym.parent].name;
    if (parent.len + 1 + sym.name.len > buf.len) return sym.name;
    @memcpy(buf[0..parent.len], parent);
    buf[parent.len] = '.';
    @memcpy(buf[parent.len + 1 ..][0..sym.name.len], sym.name);
    return buf[0 .. parent.len + 1 + sym.name.len];
}

// ---------------------------------------------------------------------------
// Symbol search
// ---------------------------------------------------------------------------

pub const Hit = struct {
    id: SymbolId,
    score: i32,
    count: u8,
    positions: [max_query_len]u32,
    /// Use sites, for a `refs` search. Empty for a definition search.
    lines: []const u32 = &.{},

    pub fn matches(self: *const Hit) []const u32 {
        return self.positions[0..self.count];
    }
};

pub const Filter = struct {
    kinds: []const u8 = "",
    tests: query.TestScope = .with,
};

/// Rank every definition whose qualified name fuzzy-matches `needle`. Returns
/// the total number of matches; `out` holds them sorted best-first (all of them
/// — the caller applies its own limit after seeing `total`).
pub fn searchSymbols(
    gpa: std.mem.Allocator,
    idx: *const Index,
    needle: []const u8,
    filter: Filter,
    out: *std.ArrayList(Hit),
) !void {
    var buf: [512]u8 = undefined;
    for (idx.graph.symbols) |sym| {
        if (sym.kind == .import) continue;
        if (!query.kindAllowed(sym.kind, filter.kinds)) continue;
        if (!inScope(filter.tests, query.isTestSymbol(idx, sym))) continue;
        const qualified = qualifiedInto(idx, sym, &buf);
        const s = score(qualified, needle) orelse continue;
        try out.append(gpa, .{ .id = sym.id, .score = s.value, .count = s.count, .positions = s.positions });
    }
    sortHits(idx, out.items);
}

/// Rank every *use site* matching `pattern`, grouped by the referencing
/// definition. `pattern` follows the CLI's `search --refs` grammar, so
/// `Recv.field` and `.field` pin instance-attribute reads.
pub fn searchRefs(
    gpa: std.mem.Allocator,
    idx: *const Index,
    pattern: []const u8,
    filter: Filter,
    out: *std.ArrayList(Hit),
) !void {
    const pat = query.RefPattern.parse(pattern);
    var lines: std.ArrayList(u32) = .empty;
    defer lines.deinit(gpa);
    for (idx.graph.symbols) |sym| {
        if (!query.kindAllowed(sym.kind, filter.kinds)) continue;
        if (!inScope(filter.tests, query.isTestSymbol(idx, sym))) continue;
        lines.clearRetainingCapacity();
        var best: ?Score = null;
        for (sym.refs) |ref| {
            if (!pat.matches(ref)) continue;
            const s = score(ref.name, pat.name) orelse continue;
            if (best == null or s.value > best.?.value) best = s;
            if (ref.lines.len > 1) {
                try lines.appendSlice(gpa, ref.lines);
            } else {
                try lines.append(gpa, ref.line);
            }
        }
        const s = best orelse continue;
        std.mem.sort(u32, lines.items, {}, std.sort.asc(u32));
        try out.append(gpa, .{
            .id = sym.id,
            .score = s.value,
            .count = s.count,
            .positions = s.positions,
            .lines = try gpa.dupe(u32, lines.items),
        });
    }
    sortHits(idx, out.items);
}

fn inScope(scope: query.TestScope, is_test: bool) bool {
    return switch (scope) {
        .with => true,
        .without => !is_test,
        .only => is_test,
    };
}

fn sortHits(idx: *const Index, hits: []Hit) void {
    std.mem.sort(Hit, hits, idx, hitLessThan);
}

/// Best first: score, then fan-in, then the shorter file path, then the id so
/// the order is total (a client paging through results sees a stable list).
fn hitLessThan(idx: *const Index, a: Hit, b: Hit) bool {
    if (a.score != b.score) return a.score > b.score;
    const ca = idx.callersOf(a.id).len;
    const cb = idx.callersOf(b.id).len;
    if (ca != cb) return ca > cb;
    const pa = idx.graph.files[idx.graph.symbols[a.id].file].path;
    const pb = idx.graph.files[idx.graph.symbols[b.id].file].path;
    if (pa.len != pb.len) return pa.len < pb.len;
    return a.id < b.id;
}

// ---------------------------------------------------------------------------
// Glob include filters
// ---------------------------------------------------------------------------

/// Match `path` against a glob. `*` stays within a path segment, `**` crosses
/// separators, `?` is one character. A pattern with no `/` is matched against
/// the basename, so `*.zig` means "any .zig file".
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    const subject = if (std.mem.indexOfScalar(u8, pattern, '/') == null)
        std.fs.path.basename(path)
    else
        path;
    return globHere(pattern, subject);
}

fn globHere(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    switch (pat[0]) {
        '*' => {
            if (pat.len > 1 and pat[1] == '*') {
                const rest = if (pat.len > 2 and pat[2] == '/') pat[3..] else pat[2..];
                // `**` may consume any number of characters, separators included.
                var i: usize = 0;
                while (true) : (i += 1) {
                    if (globHere(rest, s[i..])) return true;
                    if (i == s.len) return false;
                }
            }
            var i: usize = 0;
            while (true) : (i += 1) {
                if (globHere(pat[1..], s[i..])) return true;
                if (i == s.len or s[i] == '/') return false;
            }
        },
        '?' => return s.len != 0 and s[0] != '/' and globHere(pat[1..], s[1..]),
        else => return s.len != 0 and s[0] == pat[0] and globHere(pat[1..], s[1..]),
    }
}

/// Whether `path` passes an `include` list. An empty list includes everything.
pub fn included(globs: []const []const u8, path: []const u8) bool {
    if (globs.len == 0) return true;
    for (globs) |g| if (globMatch(g, path)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Grep
// ---------------------------------------------------------------------------

/// A compiled grep pattern: a literal or a regular expression.
pub const Pattern = union(enum) {
    literal: struct { text: []const u8, case_sensitive: bool },
    regex: regex.Regex,

    pub fn deinit(self: *Pattern) void {
        switch (self.*) {
            .regex => |*re| re.deinit(),
            .literal => {},
        }
    }

    /// Byte range of the first match in `line`, or null.
    pub fn find(self: *const Pattern, line: []const u8) regex.MatchError!?regex.Match {
        switch (self.*) {
            .literal => |lit| {
                const at = if (lit.case_sensitive)
                    std.mem.indexOf(u8, line, lit.text)
                else
                    indexOfIgnoreCase(line, lit.text);
                const start = at orelse return null;
                return .{ .start = start, .end = start + lit.text.len };
            },
            .regex => |*re| return re.find(line),
        }
    }
};

pub fn compilePattern(
    gpa: std.mem.Allocator,
    pattern: []const u8,
    use_regex: bool,
    case_sensitive: bool,
) regex.CompileError!Pattern {
    if (!use_regex) return .{ .literal = .{ .text = pattern, .case_sensitive = case_sensitive } };
    return .{ .regex = try regex.compile(gpa, pattern, case_sensitive) };
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scoreOf(haystack: []const u8, needle: []const u8) ?i32 {
    const s = score(haystack, needle) orelse return null;
    return s.value;
}

test "score orders exact above prefix above boundary above substring" {
    const exact = scoreOf("run", "run").?;
    const prefix = scoreOf("runner", "run").?;
    const boundary = scoreOf("Task.run", "run").?;
    const substring = scoreOf("prerun", "run").?;
    const loose = scoreOf("rearrange_unit", "run").?;
    try testing.expect(exact > prefix);
    try testing.expect(prefix > boundary);
    try testing.expect(boundary > substring);
    try testing.expect(substring > loose);
}

test "score rejects a needle that is not a subsequence" {
    try testing.expect(score("resolveOne", "xyz") == null);
    try testing.expect(score("abc", "abcd") == null);
    try testing.expect(score("", "a") == null);
    try testing.expect(score("anything", "").?.value == 0);
}

test "score records the matched positions and tightens onto camel humps" {
    const s = score("resolveOne", "rO").?;
    try testing.expectEqualSlices(u32, &.{ 0, 7 }, s.slice());
    const q = score("Index.lookup", "Idxlkp").?;
    try testing.expectEqual(@as(u8, 6), q.count);
    // Every position lands on the right character.
    const hay = "Index.lookup";
    for (q.slice(), "Idxlkp") |p, c| try testing.expect(eqFold(hay[p], c));
}

test "score is case-insensitive" {
    try testing.expect(score("ResolveOne", "resolveone") != null);
    try testing.expectEqual(scoreOf("run", "RUN").?, @as(i32, 4000));
}

test "globMatch handles basenames, segments and **" {
    try testing.expect(globMatch("*.zig", "src/deep/a.zig"));
    try testing.expect(!globMatch("*.zig", "src/a.md"));
    try testing.expect(globMatch("src/*.zig", "src/a.zig"));
    try testing.expect(!globMatch("src/*.zig", "src/deep/a.zig"));
    try testing.expect(globMatch("src/**/*.zig", "src/deep/a.zig"));
    try testing.expect(globMatch("src/**", "src/deep/a.zig"));
    try testing.expect(globMatch("src/?.zig", "src/a.zig"));
    try testing.expect(!globMatch("src/?.zig", "src/ab.zig"));
}

test "included is permissive with no globs and any-of otherwise" {
    try testing.expect(included(&.{}, "anything"));
    try testing.expect(included(&.{ "*.md", "*.zig" }, "src/a.zig"));
    try testing.expect(!included(&.{"*.md"}, "src/a.zig"));
}

test "literal patterns honor case sensitivity" {
    var sensitive = try compilePattern(testing.allocator, "Run", true == false, true);
    defer sensitive.deinit();
    try testing.expect((try sensitive.find("please run")) == null);
    try testing.expectEqual(@as(usize, 7), (try sensitive.find("please Run")).?.start);

    var insensitive = try compilePattern(testing.allocator, "Run", false, false);
    defer insensitive.deinit();
    try testing.expectEqual(@as(usize, 7), (try insensitive.find("please run")).?.start);
}

test "regex patterns compile and match through the same interface" {
    var p = try compilePattern(testing.allocator, "fn\\s+\\w+", true, true);
    defer p.deinit();
    const m = (try p.find("pub fn resolveOne(")).?;
    try testing.expectEqual(@as(usize, 4), m.start);
    try testing.expectEqual(@as(usize, 17), m.end);
}
