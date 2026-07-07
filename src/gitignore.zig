//! A practical `.gitignore` matcher: enough of gitignore(5) to keep NavGraph's
//! index in sync with what git tracks. Supports comments, blank lines, negation
//! (`!`), directory-only patterns (trailing `/`), anchoring (a leading or
//! middle `/`), the `*`/`?`/`**` wildcards, and per-directory `.gitignore` files
//! (deeper files override shallower ones). It does not implement `[charclass]`
//! ranges, `.git/info/exclude`, or the global excludesfile — a repo `.gitignore`
//! is the case that matters here.

const std = @import("std");

/// One compiled ignore pattern, tagged with the directory its `.gitignore` lives
/// in (`base`, relative to the index root; "" for the root file). Matching is
/// gated on `base` so a nested file's rules apply only within its subtree.
const Rule = struct {
    base: []const u8,
    /// The glob, with any leading `!`/`/` and trailing `/` already stripped.
    pattern: []const u8,
    negated: bool,
    dir_only: bool,
    /// Match `pattern` against the full base-relative path (true) or just the
    /// final path component (false). Anchored when the source line held a `/`.
    anchored: bool,
};

/// An ordered set of rules from one or more `.gitignore` files. Rules are matched
/// in insertion order and the last match wins, so callers must add ancestor files
/// before descendant ones (the tree walk does this naturally). All slices are
/// borrowed from the caller's arena; `Matcher` allocates only its rule list.
pub const Matcher = struct {
    gpa: std.mem.Allocator,
    rules: std.ArrayList(Rule),

    pub fn init(gpa: std.mem.Allocator) Matcher {
        return .{ .gpa = gpa, .rules = .empty };
    }

    pub fn deinit(self: *Matcher) void {
        self.rules.deinit(self.gpa);
    }

    /// Parse one `.gitignore`'s `contents` (borrowed, must outlive the matcher)
    /// whose file sits in directory `base` (borrowed, "" for the root).
    pub fn addFile(self: *Matcher, base: []const u8, contents: []const u8) !void {
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |raw| {
            const rule = parseLine(base, raw) orelse continue;
            try self.rules.append(self.gpa, rule);
        }
    }

    /// Whether `path` (relative to the index root, `/`-separated) is ignored.
    /// `is_dir` gates directory-only rules. Last matching rule decides.
    pub fn isIgnored(self: *const Matcher, path: []const u8, is_dir: bool) bool {
        std.debug.assert(path.len != 0);
        var ignored = false;
        for (self.rules.items) |r| {
            if (r.dir_only and !is_dir) continue;
            const rel = relativeTo(r.base, path) orelse continue;
            if (matchRule(r, rel)) ignored = !r.negated;
        }
        return ignored;
    }
};

/// Parse a single `.gitignore` line into a `Rule`, or null for a blank/comment
/// line (or one that reduces to nothing). `base` is borrowed into the rule.
fn parseLine(base: []const u8, raw: []const u8) ?Rule {
    var s = std.mem.trimEnd(u8, raw, " \t\r");
    if (s.len == 0 or s[0] == '#') return null;

    var negated = false;
    if (s[0] == '!') {
        negated = true;
        s = s[1..];
    } else if (s.len >= 2 and s[0] == '\\' and (s[1] == '#' or s[1] == '!')) {
        s = s[1..]; // escaped leading '#'/'!' is a literal
    }
    if (s.len == 0) return null;

    var dir_only = false;
    if (s[s.len - 1] == '/') {
        dir_only = true;
        s = s[0 .. s.len - 1];
    }
    if (s.len == 0) return null;

    var anchored = std.mem.indexOfScalar(u8, s, '/') != null;
    if (s[0] == '/') {
        anchored = true;
        s = s[1..];
    }
    if (s.len == 0) return null;

    return .{ .base = base, .pattern = s, .negated = negated, .dir_only = dir_only, .anchored = anchored };
}

/// `path` re-expressed relative to directory `base`, or null when `path` is not
/// under `base`. `base` "" means the root, so `path` is returned unchanged.
fn relativeTo(base: []const u8, path: []const u8) ?[]const u8 {
    if (base.len == 0) return path;
    if (path.len <= base.len) return null;
    if (!std.mem.startsWith(u8, path, base) or path[base.len] != '/') return null;
    return path[base.len + 1 ..];
}

/// Whether rule `r` matches `rel` (a base-relative path). Anchored rules match
/// the whole path; unanchored rules match only the final component, which — with
/// directory pruning upstream — reproduces git's "matches at any depth" rule.
fn matchRule(r: Rule, rel: []const u8) bool {
    if (r.anchored) return glob(r.pattern, rel);
    const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
    const base = if (slash) |i| rel[i + 1 ..] else rel;
    return glob(r.pattern, base);
}

/// Glob match with gitignore semantics: `?` and `*` match runs of non-`/`
/// characters, `**` matches across `/` (and `**/` may match zero directories).
fn glob(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;

    if (pattern[0] == '*') {
        if (pattern.len >= 2 and pattern[1] == '*') {
            const rest = pattern[2..];
            // `**/` can match zero path segments (the base directory itself).
            if (rest.len != 0 and rest[0] == '/' and glob(rest[1..], text)) return true;
            var i: usize = 0;
            while (true) : (i += 1) {
                if (glob(rest, text[i..])) return true;
                if (i >= text.len) return false;
            }
        }
        const rest = pattern[1..];
        var i: usize = 0;
        while (true) : (i += 1) {
            if (glob(rest, text[i..])) return true;
            if (i >= text.len or text[i] == '/') return false;
        }
    }

    if (pattern[0] == '?') {
        if (text.len == 0 or text[0] == '/') return false;
        return glob(pattern[1..], text[1..]);
    }

    if (text.len == 0 or pattern[0] != text[0]) return false;
    return glob(pattern[1..], text[1..]);
}

test "basename patterns match at any depth" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "*.log\nnode_modules/\n# a comment\n\nbuild\n");
    try std.testing.expect(m.isIgnored("a.log", false));
    try std.testing.expect(m.isIgnored("deep/nested/a.log", false));
    try std.testing.expect(!m.isIgnored("a.txt", false));
    try std.testing.expect(m.isIgnored("node_modules", true));
    try std.testing.expect(!m.isIgnored("node_modules", false)); // dir-only
    try std.testing.expect(m.isIgnored("build", true));
    try std.testing.expect(m.isIgnored("pkg/build", true));
}

test "anchored patterns and wildcards" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "/dist\nsrc/*.gen.zig\n**/tmp\nfoo/**/bar\n");
    try std.testing.expect(m.isIgnored("dist", true));
    try std.testing.expect(!m.isIgnored("app/dist", true)); // anchored to root
    try std.testing.expect(m.isIgnored("src/a.gen.zig", false));
    try std.testing.expect(!m.isIgnored("src/deep/a.gen.zig", false)); // * stops at /
    try std.testing.expect(m.isIgnored("a/b/tmp", true));
    try std.testing.expect(m.isIgnored("tmp", true));
    try std.testing.expect(m.isIgnored("foo/x/y/bar", false));
    try std.testing.expect(m.isIgnored("foo/bar", false)); // **/ matches zero dirs
}

test "negation re-includes and last match wins" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "*.log\n!keep.log\n");
    try std.testing.expect(m.isIgnored("a.log", false));
    try std.testing.expect(!m.isIgnored("keep.log", false));
}

test "nested gitignore scoped to its subtree, deeper wins" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "*.log\n");
    try m.addFile("sub", "!*.log\n");
    try std.testing.expect(m.isIgnored("a.log", false));
    try std.testing.expect(!m.isIgnored("sub/a.log", false)); // deeper negation wins
    try std.testing.expect(m.isIgnored("other/a.log", false)); // sub rule doesn't reach
}
