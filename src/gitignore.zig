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

    /// Whether the last rule matching `path` is a negation (`!pattern`) — an
    /// explicit re-include. Used to let a `.navgraphignore` `!name` override
    /// the built-in directory skip set (e.g. force-index `vendor/`).
    pub fn isReincluded(self: *const Matcher, path: []const u8, is_dir: bool) bool {
        std.debug.assert(path.len != 0);
        var reincluded = false;
        for (self.rules.items) |r| {
            if (r.dir_only and !is_dir) continue;
            const rel = relativeTo(r.base, path) orelse continue;
            if (matchRule(r, rel)) reincluded = r.negated;
        }
        return reincluded;
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
/// Pub: `query.zig` reuses it for glob patterns in symbol/path arguments.
pub fn glob(pattern: []const u8, text: []const u8) bool {
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

// ---------------------------------------------------------------------------
// Appended tests: parseLine, relativeTo, matchRule, glob, and Matcher.isIgnored
// ---------------------------------------------------------------------------

test "parseLine: plain name is unanchored basename rule" {
    const r = parseLine("", "foo").?;
    try std.testing.expectEqualStrings("", r.base);
    try std.testing.expectEqualStrings("foo", r.pattern);
    try std.testing.expect(!r.negated);
    try std.testing.expect(!r.dir_only);
    try std.testing.expect(!r.anchored);
}

test "parseLine: negation strips bang and sets negated" {
    const r = parseLine("", "!foo.log").?;
    try std.testing.expectEqualStrings("foo.log", r.pattern);
    try std.testing.expect(r.negated);
    try std.testing.expect(!r.dir_only);
    try std.testing.expect(!r.anchored);
}

test "parseLine: directory-only strips trailing slash" {
    const r = parseLine("", "build/").?;
    try std.testing.expectEqualStrings("build", r.pattern);
    try std.testing.expect(r.dir_only);
    try std.testing.expect(!r.anchored); // no interior slash left after stripping
    try std.testing.expect(!r.negated);
}

test "parseLine: leading slash anchors and is stripped" {
    const r = parseLine("", "/dist").?;
    try std.testing.expectEqualStrings("dist", r.pattern);
    try std.testing.expect(r.anchored);
    try std.testing.expect(!r.dir_only);
}

test "parseLine: interior slash anchors without stripping" {
    const r = parseLine("", "src/gen.zig").?;
    try std.testing.expectEqualStrings("src/gen.zig", r.pattern);
    try std.testing.expect(r.anchored);
    try std.testing.expect(!r.dir_only);
}

test "parseLine: comment and blank lines return null" {
    try std.testing.expect(parseLine("", "# a comment") == null);
    try std.testing.expect(parseLine("", "#") == null);
    try std.testing.expect(parseLine("", "") == null);
    try std.testing.expect(parseLine("", "   ") == null); // all-whitespace trims to empty
    try std.testing.expect(parseLine("", "\t\t") == null);
}

test "parseLine: trailing spaces and tabs are trimmed" {
    const r = parseLine("", "foo   ").?;
    try std.testing.expectEqualStrings("foo", r.pattern);
    const r2 = parseLine("", "bar\t \t").?;
    try std.testing.expectEqualStrings("bar", r2.pattern);
}

test "parseLine: trailing carriage return (CRLF) is trimmed" {
    const r = parseLine("", "foo\r").?;
    try std.testing.expectEqualStrings("foo", r.pattern);
    // The '/' must be recognised as dir-only even with a trailing CR.
    const r2 = parseLine("", "build/\r").?;
    try std.testing.expectEqualStrings("build", r2.pattern);
    try std.testing.expect(r2.dir_only);
}

test "parseLine: escaped hash/bang become literal patterns, not comment/negation" {
    const r = parseLine("", "\\#file").?;
    try std.testing.expectEqualStrings("#file", r.pattern);
    try std.testing.expect(!r.negated);
    const r2 = parseLine("", "\\!file").?;
    try std.testing.expectEqualStrings("!file", r2.pattern);
    try std.testing.expect(!r2.negated);
}

test "parseLine: lone bang and lone slash reduce to null" {
    try std.testing.expect(parseLine("", "!") == null);
    try std.testing.expect(parseLine("", "/") == null);
    try std.testing.expect(parseLine("", "!/") == null);
}

test "parseLine: negated directory-only keeps both flags" {
    const r = parseLine("", "!logs/").?;
    try std.testing.expectEqualStrings("logs", r.pattern);
    try std.testing.expect(r.negated);
    try std.testing.expect(r.dir_only);
}

test "parseLine: base is stored on the rule" {
    const r = parseLine("sub/dir", "foo").?;
    try std.testing.expectEqualStrings("sub/dir", r.base);
}

test "relativeTo: empty base returns the path unchanged" {
    const rel = relativeTo("", "a/b/c").?;
    try std.testing.expectEqualStrings("a/b/c", rel);
}

test "relativeTo: strips the base prefix and separating slash" {
    const rel = relativeTo("sub", "sub/a.log").?;
    try std.testing.expectEqualStrings("a.log", rel);
    const rel2 = relativeTo("a/b", "a/b/c/d").?;
    try std.testing.expectEqualStrings("c/d", rel2);
}

test "relativeTo: path outside base returns null" {
    try std.testing.expect(relativeTo("sub", "other/a.log") == null);
}

test "relativeTo: path equal to base returns null" {
    try std.testing.expect(relativeTo("sub", "sub") == null);
}

test "relativeTo: prefix not on a slash boundary returns null" {
    // "subdir" starts with "sub" but the next char is not '/'.
    try std.testing.expect(relativeTo("sub", "subdir/a") == null);
}

test "matchRule: anchored rule matches against the whole relative path" {
    const r: Rule = .{ .base = "", .pattern = "a/b", .negated = false, .dir_only = false, .anchored = true };
    try std.testing.expect(matchRule(r, "a/b"));
    try std.testing.expect(!matchRule(r, "x/a/b")); // anchored: no leading segment
    const r2: Rule = .{ .base = "", .pattern = "dist", .negated = false, .dir_only = false, .anchored = true };
    try std.testing.expect(matchRule(r2, "dist"));
    try std.testing.expect(!matchRule(r2, "app/dist"));
}

test "matchRule: unanchored rule matches only the final component" {
    const r: Rule = .{ .base = "", .pattern = "foo", .negated = false, .dir_only = false, .anchored = false };
    try std.testing.expect(matchRule(r, "foo"));
    try std.testing.expect(matchRule(r, "a/b/foo")); // basename match at any depth
    try std.testing.expect(!matchRule(r, "foo/bar")); // basename is "bar", not "foo"
}

test "glob: literal exact match and mismatches" {
    try std.testing.expect(glob("foo", "foo"));
    try std.testing.expect(!glob("foo", "bar"));
    try std.testing.expect(!glob("foo", "fo")); // pattern longer than text
    try std.testing.expect(!glob("foo", "food")); // text longer than pattern
}

test "glob: question mark matches exactly one non-slash char" {
    try std.testing.expect(glob("f?o", "foo"));
    try std.testing.expect(glob("?", "a"));
    try std.testing.expect(!glob("f?o", "fo")); // nothing for '?' to consume
    try std.testing.expect(!glob("f?o", "f/o")); // '?' does not match '/'
    try std.testing.expect(!glob("?", "")); // empty text
}

test "glob: single star does not cross slash and can match empty" {
    try std.testing.expect(glob("*.log", "a.log"));
    try std.testing.expect(glob("*.log", ".log")); // '*' matches zero chars
    try std.testing.expect(glob("a*", "a")); // trailing '*' matches empty
    try std.testing.expect(!glob("*.log", "a/b.log")); // '*' stops at '/'
    try std.testing.expect(!glob("*.log", "a.txt"));
}

test "glob: double star crosses slashes and matches zero directories" {
    try std.testing.expect(glob("**/tmp", "a/b/tmp"));
    try std.testing.expect(glob("**/tmp", "a/tmp"));
    try std.testing.expect(glob("**/tmp", "tmp")); // '**/' matches zero dirs
    try std.testing.expect(!glob("**/tmp", "a/nope"));
    try std.testing.expect(glob("foo/**/bar", "foo/x/y/bar"));
    try std.testing.expect(glob("foo/**/bar", "foo/bar")); // zero dirs between
}

test "glob: bracket char classes are treated literally (unsupported)" {
    // The implementation documents that [charclass] ranges are not supported;
    // brackets match as ordinary literal characters.
    try std.testing.expect(glob("[abc].txt", "[abc].txt"));
    try std.testing.expect(!glob("[abc].txt", "a.txt"));
    try std.testing.expect(glob("[a-z]", "[a-z]"));
    try std.testing.expect(!glob("[a-z]", "m"));
}

test "glob: empty pattern only matches empty text" {
    try std.testing.expect(glob("", ""));
    try std.testing.expect(!glob("", "x"));
}

test "isIgnored: an empty matcher ignores nothing" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(!m.isIgnored("anything", false));
    try std.testing.expect(!m.isIgnored("some/dir", true));
}

test "isIgnored: last matching rule wins across negation ordering" {
    // Negation first, then a broader re-ignore: the later rule decides.
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "!*.log\n*.log\n");
    try std.testing.expect(m.isIgnored("a.log", false)); // *.log wins (last)

    // Broad ignore first, then a targeted negation.
    var m2 = Matcher.init(std.testing.allocator);
    defer m2.deinit();
    try m2.addFile("", "*.log\n!keep.log\n");
    try std.testing.expect(!m2.isIgnored("keep.log", false));
    try std.testing.expect(m2.isIgnored("other.log", false));
}

test "isIgnored: CRLF line endings are handled" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "*.log\r\nbuild/\r\n");
    try std.testing.expect(m.isIgnored("a.log", false));
    try std.testing.expect(m.isIgnored("build", true));
    try std.testing.expect(!m.isIgnored("build", false)); // dir-only survives CRLF
}

test "isIgnored: escaped hash matches a literal file, plain hash is a comment" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "\\#note\n");
    try std.testing.expect(m.isIgnored("#note", false));

    var m2 = Matcher.init(std.testing.allocator);
    defer m2.deinit();
    try m2.addFile("", "#note\n"); // comment: produces no rule
    try std.testing.expect(!m2.isIgnored("#note", false));
}

test "isIgnored: directory-only negation re-includes a directory" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "*/\n!keep/\n");
    try std.testing.expect(m.isIgnored("foo", true)); // any dir ignored
    try std.testing.expect(!m.isIgnored("keep", true)); // keep/ re-included
    try std.testing.expect(!m.isIgnored("foo", false)); // dir-only: files untouched
}

test "isIgnored: bracket pattern is matched literally, not as a class" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "[abc].txt\n");
    try std.testing.expect(m.isIgnored("[abc].txt", false));
    try std.testing.expect(!m.isIgnored("a.txt", false));
    try std.testing.expect(!m.isIgnored("b.txt", false));
}

test "isReincluded: negated rule re-includes, plain or absent rule does not" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "junk/\n!node_modules/\n");
    // `!node_modules/` → explicit re-include (overrides a built-in skip).
    try std.testing.expect(m.isReincluded("node_modules", true));
    // Plain ignore rule and unmatched paths are not re-includes.
    try std.testing.expect(!m.isReincluded("junk", true));
    try std.testing.expect(!m.isReincluded("src", true));
    // A later plain rule wins over an earlier negation.
    try m.addFile("", "node_modules/\n");
    try std.testing.expect(!m.isReincluded("node_modules", true));
}

test "isIgnored: anchored root rule does not match nested dirs" {
    var m = Matcher.init(std.testing.allocator);
    defer m.deinit();
    try m.addFile("", "/dist\n");
    try std.testing.expect(m.isIgnored("dist", true));
    try std.testing.expect(!m.isIgnored("app/dist", true));
}
