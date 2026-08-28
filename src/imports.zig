//! Pure module-path resolution: given the importing file's path, the raw module
//! string, and the language, produce the candidate repo-relative file paths an
//! import could refer to. `index.zig` matches these against the set of indexed
//! files to bind an import to a `FileId`.
//!
//! Kept dependency-free and allocation-explicit (an arena is passed in) so the
//! candidate generation can be unit-tested without building a whole index.

const std = @import("std");
const language = @import("language.zig");

const Language = language.Language;

/// JS/TS resolution extensions, in priority order.
const js_exts = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" };

/// Classification produced before the index tries candidate paths against the
/// files in the workspace. Keeping `external` and `outside_root` distinct is
/// important: neither is a local edge, but the latter proves that a relative
/// import deliberately crossed the configured workspace boundary.
pub const CandidateStatus = enum { local, external, outside_root };

pub const CandidateResolution = union(CandidateStatus) {
    local: []const []const u8,
    external,
    outside_root,

    /// Compatibility view for callers that only need possible local paths.
    /// New graph-building code should retain the tagged result instead.
    pub fn paths(self: CandidateResolution) []const []const u8 {
        return switch (self) {
            .local => |items| items,
            .external, .outside_root => &.{},
        };
    }
};

/// Classify `module` and, for a potentially local import, return repo-relative
/// candidate paths in priority order. Every candidate is arena-owned.
pub fn resolveCandidates(
    arena: std.mem.Allocator,
    importer_path: []const u8,
    module: []const u8,
    lang: Language,
) !CandidateResolution {
    std.debug.assert(importer_path.len > 0);
    if (module.len == 0) return .external;
    return switch (lang.family()) {
        .zig => try zigCandidates(arena, importer_path, module),
        .js => try jsCandidates(arena, importer_path, module),
        .python => try pyCandidates(arena, importer_path, module),
        .lua => try luaCandidates(arena, importer_path, module),
        .rust => try rustCandidates(arena, importer_path, module),
        .ruby => try rubyCandidates(arena, importer_path, module),
        .java => try javaCandidates(arena, module),
        else => .external,
    };
}

/// Repo-relative candidate paths `module` may resolve to. Empty for external
/// and outside-root imports. Prefer `resolveCandidates` when the distinction is
/// useful to diagnostics or trust reporting.
pub fn candidates(
    arena: std.mem.Allocator,
    importer_path: []const u8,
    module: []const u8,
    lang: Language,
) ![]const []const u8 {
    return (try resolveCandidates(arena, importer_path, module, lang)).paths();
}

/// Rust `mod name;` resolves to a sibling `name.rs` or a subdir `name/mod.rs`.
/// A `use` path is intra-crate (`crate::a::b`) and unresolvable to a file
/// without the crate root, so `::`-bearing modules yield no candidates.
fn rustCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) !CandidateResolution {
    if (std.mem.indexOf(u8, module, "::") != null) return .external;
    const dir = dirOf(importer);
    const stem = switch (try joinNormalize(arena, dir, module)) {
        .inside_root => |path| path,
        .outside_root => return .outside_root,
    };
    if (stem.len == 0) return .external;
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, try concat(arena, stem, ".rs"));
    try list.append(arena, try concat(arena, stem, "/mod.rs"));
    return .{ .local = try list.toOwnedSlice(arena) };
}

/// Ruby `require_relative "lib/user"` resolves from the importer's directory;
/// a plain `require "user"` may be a gem, but we also offer a repo-relative
/// `user.rb` in case it names a local file. Non-existent candidates are simply
/// never matched by the index.
fn rubyCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) !CandidateResolution {
    var list: std.ArrayList([]const u8) = .empty;
    const rel = switch (try joinNormalize(arena, dirOf(importer), module)) {
        .inside_root => |path| path,
        .outside_root => return .outside_root,
    };
    if (rel.len != 0) try list.append(arena, try concat(arena, rel, ".rb"));
    // A path beginning with `.` is explicitly relative. Trying it again from
    // the workspace root can both change its meaning and hide an escape.
    if (!std.mem.startsWith(u8, module, ".")) {
        const root = switch (try joinNormalize(arena, "", module)) {
            .inside_root => |path| path,
            .outside_root => return .outside_root,
        };
        if (root.len != 0 and !std.mem.eql(u8, root, rel)) try list.append(arena, try concat(arena, root, ".rb"));
    }
    const paths = try list.toOwnedSlice(arena);
    return if (paths.len == 0) .external else .{ .local = paths };
}

/// Lua `require "a.b.c"` maps the dotted module to `a/b/c.lua` or the package
/// form `a/b/c/init.lua`. Candidates are emitted both repo-root-relative (LÖVE,
/// plain Lua) and under a `lua/` prefix (the Neovim runtimepath convention,
/// where `require("advantage.util")` resolves to `lua/advantage/util.lua`). A
/// leading `.` (relative require) resolves from the importer's directory.
fn luaCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) !CandidateResolution {
    const slash_relative = startsWithRelativeSegment(module);
    const dots = if (slash_relative) 0 else leadingDots(module);
    const base_dir = if (slash_relative or dots > 0) dirOf(importer) else "";
    const rel_path = if (slash_relative)
        module
    else blk: {
        const slashed = try dotsToSlashes(arena, module[dots..]);
        break :blk if (dots > 0) try prependUp(arena, dots - 1, slashed) else slashed;
    };
    const stem = switch (try joinNormalize(arena, base_dir, rel_path)) {
        .inside_root => |path| path,
        .outside_root => return .outside_root,
    };
    if (stem.len == 0) return .external;
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, try concat(arena, stem, ".lua"));
    try list.append(arena, try concat(arena, stem, "/init.lua"));
    if (!slash_relative and dots == 0) { // Neovim `lua/`-rooted modules
        const nvim = switch (try joinNormalize(arena, "lua", stem)) {
            .inside_root => |path| path,
            .outside_root => return .outside_root,
        };
        try list.append(arena, try concat(arena, nvim, ".lua"));
        try list.append(arena, try concat(arena, nvim, "/init.lua"));
    }
    return .{ .local = try list.toOwnedSlice(arena) };
}

/// Java `import com.foo.Bar;` maps the fully-qualified name to `com/foo/Bar.java`
/// under the repo root and the common Maven/Gradle source roots. `import static
/// a.b.C.m;` names a member, so a variant dropping the trailing segment is also
/// offered. Wildcard imports (`com.foo.*`) name a package, not a single file.
fn javaCandidates(arena: std.mem.Allocator, module: []const u8) !CandidateResolution {
    if (std.mem.indexOfScalar(u8, module, '*') != null) return .external;
    // Java imports are qualified identifiers, never filesystem paths. Classify
    // a path-shaped traversal explicitly before dotsToSlashes could erase it.
    if (std.mem.indexOfAny(u8, module, "/\\") != null) {
        return switch (try joinNormalize(arena, "", module)) {
            .inside_root => .external,
            .outside_root => .outside_root,
        };
    }
    if (std.mem.startsWith(u8, module, ".") or
        std.mem.endsWith(u8, module, ".") or
        std.mem.indexOf(u8, module, "..") != null) return .external;
    const slashed = try dotsToSlashes(arena, module);
    if (slashed.len == 0) return .external;
    const roots = [_][]const u8{ "", "src/main/java", "src/test/java", "src" };
    var list: std.ArrayList([]const u8) = .empty;
    for (roots) |root| {
        const stem = switch (try joinNormalize(arena, root, slashed)) {
            .inside_root => |path| path,
            .outside_root => return .outside_root,
        };
        if (stem.len != 0) try list.append(arena, try concat(arena, stem, ".java"));
    }
    // Static-member import: also try dropping the trailing `.member` segment.
    if (std.mem.lastIndexOfScalar(u8, slashed, '/')) |cut| {
        const outer = slashed[0..cut];
        for (roots) |root| {
            const stem = switch (try joinNormalize(arena, root, outer)) {
                .inside_root => |path| path,
                .outside_root => return .outside_root,
            };
            if (stem.len != 0) try list.append(arena, try concat(arena, stem, ".java"));
        }
    }
    return .{ .local = try list.toOwnedSlice(arena) };
}

fn zigCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) !CandidateResolution {
    // `@import("std")` and other package roots have no local file.
    if (!std.mem.endsWith(u8, module, ".zig")) return .external;
    const joined = switch (try joinNormalize(arena, dirOf(importer), module)) {
        .inside_root => |path| path,
        .outside_root => return .outside_root,
    };
    return .{ .local = try dupeOne(arena, joined) };
}

fn jsCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) !CandidateResolution {
    // Only relative imports refer to local files; bare specifiers are packages.
    if (!std.mem.startsWith(u8, module, ".")) return .external;
    const base = switch (try joinNormalize(arena, dirOf(importer), module)) {
        .inside_root => |path| path,
        .outside_root => return .outside_root,
    };
    var list: std.ArrayList([]const u8) = .empty;
    if (hasKnownExt(base)) {
        try list.append(arena, base); // already `./foo.ts`
        return .{ .local = try list.toOwnedSlice(arena) };
    }
    for (js_exts) |ext| try list.append(arena, try concat(arena, base, ext));
    for (js_exts) |ext| try list.append(arena, try concat(arena, base, try concat(arena, "/index", ext)));
    return .{ .local = try list.toOwnedSlice(arena) };
}

fn pyCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) !CandidateResolution {
    // Leading dots => relative import: N dots means go up (N-1) package levels
    // from the importer's directory. No leading dot => absolute from the root.
    // Python syntax cannot contain filesystem separators. Check path-shaped
    // malformed input before dotsToSlashes could erase its `..` traversal.
    if (std.mem.indexOfAny(u8, module, "/\\") != null) {
        return switch (try joinNormalize(arena, dirOf(importer), module)) {
            .inside_root => .external,
            .outside_root => .outside_root,
        };
    }
    const dots = leadingDots(module);
    const slashed = try dotsToSlashes(arena, module[dots..]);
    const rel_path = if (dots > 0) try prependUp(arena, dots - 1, slashed) else slashed;
    const base_dir = if (dots > 0) dirOf(importer) else "";
    const stem = switch (try joinNormalize(arena, base_dir, rel_path)) {
        .inside_root => |path| path,
        .outside_root => return .outside_root,
    };
    var list: std.ArrayList([]const u8) = .empty;
    if (stem.len != 0) {
        try list.append(arena, try concat(arena, stem, ".py"));
        try list.append(arena, try concat(arena, stem, "/__init__.py"));
    }
    const paths = try list.toOwnedSlice(arena);
    return if (paths.len == 0) .external else .{ .local = paths };
}

/// Prefix `path` with `levels` `../` segments (for Python relative imports).
fn prependUp(arena: std.mem.Allocator, levels: usize, path: []const u8) ![]const u8 {
    if (levels == 0) return path;
    var out: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    while (k < levels) : (k += 1) try out.appendSlice(arena, "../");
    try out.appendSlice(arena, path);
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

/// Parent directory of `path` (no trailing slash); "" when path has no slash.
pub fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

pub const NormalizedPathStatus = enum { inside_root, outside_root };
pub const NormalizedPath = union(NormalizedPathStatus) {
    inside_root: []const u8,
    outside_root,
};

/// Join `base` and `rel` and resolve `.`/`..` segments into a clean, forward-
/// slash repo-relative path. Traversal above the configured root is retained as
/// `outside_root`; it is never silently normalized back into a local path.
pub fn joinNormalize(arena: std.mem.Allocator, base: []const u8, rel: []const u8) !NormalizedPath {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(arena);
    if (!try pushSegments(arena, &segs, base)) return .outside_root;
    if (!try pushSegments(arena, &segs, rel)) return .outside_root;

    var out: std.ArrayList(u8) = .empty;
    for (segs.items, 0..) |seg, k| {
        if (k != 0) try out.append(arena, '/');
        try out.appendSlice(arena, seg);
    }
    return .{ .inside_root = try out.toOwnedSlice(arena) };
}

/// Append normalized path segments. `false` means the part was absolute or a
/// `..` attempted to pop past the repo-relative root.
fn pushSegments(arena: std.mem.Allocator, segs: *std.ArrayList([]const u8), part: []const u8) !bool {
    if (isAbsolutePath(part)) return false;
    var it = std.mem.tokenizeAny(u8, part, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len == 0) return false;
            _ = segs.pop();
            continue;
        }
        try segs.append(arena, seg);
    }
    return true;
}

fn startsWithRelativeSegment(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "./") or
        std.mem.startsWith(u8, path, "../") or
        std.mem.startsWith(u8, path, ".\\") or
        std.mem.startsWith(u8, path, "..\\");
}

fn isAbsolutePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn dotsToSlashes(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    for (out) |*c| if (c.* == '.') {
        c.* = '/';
    };
    return out;
}

/// Count leading dots. A module that *starts* with a dot is a relative import
/// (`.mod`, `..pkg.x`); `os.path` starts with a letter, so this returns 0.
fn leadingDots(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] == '.') n += 1;
    return n;
}

fn hasKnownExt(path: []const u8) bool {
    for (js_exts) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}

fn concat(arena: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ a, b });
}

fn dupeOne(arena: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    const one = try arena.alloc([]const u8, 1);
    one[0] = s;
    return one;
}

test "rust mod resolves to sibling file or subdir mod.rs; use is unresolved" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const c = try candidates(arena, "src/main.rs", "parser", .rust);
    try std.testing.expectEqualStrings("src/parser.rs", c[0]);
    try std.testing.expectEqualStrings("src/parser/mod.rs", c[1]);
    // A `use crate::a::b` path is intra-crate; no file candidates.
    try std.testing.expectEqual(@as(usize, 0), (try candidates(arena, "src/main.rs", "crate::a::b", .rust)).len);
}

test "ruby require_relative resolves to a sibling .rb file" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const c = try candidates(arena, "app/main.rb", "lib/user", .ruby);
    try std.testing.expectEqualStrings("app/lib/user.rb", c[0]);
    try std.testing.expectEqualStrings("lib/user.rb", c[1]);
}

test "zig imports resolve relative to importer dir" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const c = try candidates(arena, "src/index.zig", "parser.zig", .zig);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqualStrings("src/parser.zig", c[0]);

    const up = try candidates(arena, "src/sub/x.zig", "../root.zig", .zig);
    try std.testing.expectEqualStrings("src/root.zig", up[0]);

    // Package roots (no `.zig`) are external.
    try std.testing.expectEqual(@as(usize, 0), (try candidates(arena, "a.zig", "std", .zig)).len);
}

test "js imports try extensions and index files" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const c = try candidates(arena, "src/app.ts", "./api", .typescript);
    try std.testing.expect(c.len >= 2);
    try std.testing.expectEqualStrings("src/api.ts", c[0]);
    // bare package specifier → external
    try std.testing.expectEqual(@as(usize, 0), (try candidates(arena, "src/app.ts", "react", .typescript)).len);
    // explicit extension is kept as-is
    const ex = try candidates(arena, "src/app.ts", "./api.js", .typescript);
    try std.testing.expectEqualStrings("src/api.js", ex[0]);
}

test "python dotted and relative imports map to files" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const c = try candidates(arena, "app/main.py", "pkg.mod", .python);
    try std.testing.expectEqualStrings("pkg/mod.py", c[0]);
    try std.testing.expectEqualStrings("pkg/mod/__init__.py", c[1]);

    const rel = try candidates(arena, "app/main.py", "..lib.util", .python);
    try std.testing.expectEqualStrings("lib/util.py", rel[0]);
}

test "lua require maps dotted modules to file and package init paths" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const c = try candidates(arena, "src/main.lua", "lib.util", .lua);
    try std.testing.expectEqualStrings("lib/util.lua", c[0]);
    try std.testing.expectEqualStrings("lib/util/init.lua", c[1]);
    // Neovim `lua/`-rooted convention: require("advantage.util") → lua/advantage/util.lua
    try std.testing.expectEqualStrings("lua/lib/util.lua", c[2]);
    try std.testing.expectEqualStrings("lua/lib/util/init.lua", c[3]);
}

// ===========================================================================
// Appended tests — imports.zig candidate generation & path helpers.
// ===========================================================================

const t_testing = std.testing;

fn newArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t_testing.allocator);
}

fn expectCandidateStatus(expected: CandidateStatus, actual: CandidateResolution) !void {
    try t_testing.expectEqual(expected, std.meta.activeTag(actual));
}

fn expectInsidePath(expected: []const u8, actual: NormalizedPath) !void {
    switch (actual) {
        .inside_root => |path| try t_testing.expectEqualStrings(expected, path),
        .outside_root => return error.TestUnexpectedResult,
    }
}

// --------------------------------------------------------------------------
// candidates(): top-level dispatch & guards
// --------------------------------------------------------------------------

test "candidates: empty module string yields no candidates for every language" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const langs = [_]Language{ .zig, .javascript, .typescript, .tsx, .python, .lua, .rust, .ruby };
    for (langs) |lang| {
        const c = try candidates(arena, "src/whatever.ext", "", lang);
        try t_testing.expectEqual(@as(usize, 0), c.len);
    }
}

test "candidates: java maps a fully-qualified import to source-root paths" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/main/java/com/foo/App.java", "com.foo.Bar", .java);
    try t_testing.expect(c.len >= 2);
    try t_testing.expectEqualStrings("com/foo/Bar.java", c[0]);
    try t_testing.expectEqualStrings("src/main/java/com/foo/Bar.java", c[1]);
}

test "candidates: java wildcard import names a package, not a file" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/main/java/com/foo/App.java", "com.foo.*", .java);
    try t_testing.expectEqual(@as(usize, 0), c.len);
}

test "candidates: unsupported families (c, cpp, csharp, go, unknown) return empty" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const langs = [_]Language{ .c, .cpp, .csharp, .go, .unknown };
    for (langs) |lang| {
        const c = try candidates(arena, "src/main.c", "helper", lang);
        try t_testing.expectEqual(@as(usize, 0), c.len);
    }
}

test "resolveCandidates: known external imports retain an explicit external outcome" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();

    try expectCandidateStatus(.external, try resolveCandidates(arena, "src/main.zig", "std", .zig));
    try expectCandidateStatus(.external, try resolveCandidates(arena, "src/main.ts", "react", .typescript));
    try expectCandidateStatus(.external, try resolveCandidates(arena, "src/main.rs", "crate::api", .rust));
    try expectCandidateStatus(.external, try resolveCandidates(arena, "src/main.go", "example.com/api", .go));
}

test "resolveCandidates: traversal outside workspace stays outside_root across import families" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const Case = struct { importer: []const u8, module: []const u8, lang: Language };
    const cases = [_]Case{
        .{ .importer = "src/main.zig", .module = "../../outside.zig", .lang = .zig },
        .{ .importer = "src/main.ts", .module = "../../outside", .lang = .typescript },
        .{ .importer = "src/pkg/main.py", .module = "....outside", .lang = .python },
        .{ .importer = "src/main.lua", .module = "../../outside", .lang = .lua },
        .{ .importer = "src/main.rs", .module = "../../outside", .lang = .rust },
        .{ .importer = "src/main.rb", .module = "../../outside", .lang = .ruby },
        .{ .importer = "src/App.java", .module = "../../outside", .lang = .java },
    };
    for (cases) |case| {
        const resolution = try resolveCandidates(arena, case.importer, case.module, case.lang);
        try expectCandidateStatus(.outside_root, resolution);
        try t_testing.expectEqual(@as(usize, 0), resolution.paths().len);
    }
}

test "resolveCandidates: multiple parent segments that stop at root remain local" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();

    const js = try candidates(arena, "a/b/main.ts", "../../root", .typescript);
    try t_testing.expectEqualStrings("root.ts", js[0]);
    const lua = try candidates(arena, "a/b/main.lua", "../../root", .lua);
    try t_testing.expectEqualStrings("root.lua", lua[0]);
    const rust = try candidates(arena, "a/b/main.rs", "../../root", .rust);
    try t_testing.expectEqualStrings("root.rs", rust[0]);
    const ruby = try candidates(arena, "a/b/main.rb", "../../root", .ruby);
    try t_testing.expectEqualStrings("root.rb", ruby[0]);
}

test "candidates: all three js-family languages route to jsCandidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const langs = [_]Language{ .javascript, .typescript, .tsx };
    for (langs) |lang| {
        const c = try candidates(arena, "src/app.ts", "./api", lang);
        try t_testing.expectEqual(@as(usize, 12), c.len);
        try t_testing.expectEqualStrings("src/api.ts", c[0]);
    }
}

// --------------------------------------------------------------------------
// zigCandidates
// --------------------------------------------------------------------------

test "zig: importer with no directory yields a root-relative candidate" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "a.zig", "b.zig", .zig);
    try t_testing.expectEqual(@as(usize, 1), c.len);
    try t_testing.expectEqualStrings("b.zig", c[0]);
}

test "zig: nested importer resolves module relative to importer dir" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/a/b/x.zig", "y.zig", .zig);
    try t_testing.expectEqualStrings("src/a/b/y.zig", c[0]);
}

test "zig: multiple .. segments normalize upward" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/a/b/x.zig", "../../top.zig", .zig);
    try t_testing.expectEqual(@as(usize, 1), c.len);
    try t_testing.expectEqualStrings("src/top.zig", c[0]);
}

test "zig: .. that escapes above root is outside_root, never root-local" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const resolution = try resolveCandidates(arena, "a.zig", "../b.zig", .zig);
    try expectCandidateStatus(.outside_root, resolution);
    try t_testing.expectEqual(@as(usize, 0), resolution.paths().len);
}

test "zig: modules not ending in .zig are external (empty)" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try t_testing.expectEqual(@as(usize, 0), (try candidates(arena, "a.zig", "std", .zig)).len);
    try t_testing.expectEqual(@as(usize, 0), (try candidates(arena, "a.zig", "builtin", .zig)).len);
    // A module whose name merely contains but does not end with .zig is still external.
    try t_testing.expectEqual(@as(usize, 0), (try candidates(arena, "a.zig", "foo.ziglet", .zig)).len);
}

// --------------------------------------------------------------------------
// jsCandidates
// --------------------------------------------------------------------------

test "js: extensionless relative import produces 12 ordered candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/app.ts", "./api", .typescript);
    try t_testing.expectEqual(@as(usize, 12), c.len);
    try t_testing.expectEqualStrings("src/api.ts", c[0]);
    try t_testing.expectEqualStrings("src/api.tsx", c[1]);
    try t_testing.expectEqualStrings("src/api.js", c[2]);
    try t_testing.expectEqualStrings("src/api.jsx", c[3]);
    try t_testing.expectEqualStrings("src/api.mjs", c[4]);
    try t_testing.expectEqualStrings("src/api.cjs", c[5]);
    try t_testing.expectEqualStrings("src/api/index.ts", c[6]);
    try t_testing.expectEqualStrings("src/api/index.tsx", c[7]);
    try t_testing.expectEqualStrings("src/api/index.js", c[8]);
    try t_testing.expectEqualStrings("src/api/index.jsx", c[9]);
    try t_testing.expectEqualStrings("src/api/index.mjs", c[10]);
    try t_testing.expectEqualStrings("src/api/index.cjs", c[11]);
}

test "js: bare specifiers are external packages" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try t_testing.expectEqual(@as(usize, 0), (try candidates(arena, "src/app.ts", "react", .typescript)).len);
    try t_testing.expectEqual(@as(usize, 0), (try candidates(arena, "src/app.ts", "@scope/pkg", .typescript)).len);
}

test "js: explicit known extension is kept verbatim (single candidate)" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    for ([_][]const u8{ "./api.ts", "./api.tsx", "./api.js", "./api.jsx", "./api.mjs", "./api.cjs" }) |mod| {
        const c = try candidates(arena, "src/app.ts", mod, .javascript);
        try t_testing.expectEqual(@as(usize, 1), c.len);
        // strips the leading ./ via normalization
        try t_testing.expect(std.mem.startsWith(u8, c[0], "src/api."));
    }
}

test "js: parent-relative import normalizes upward" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/ui/app.ts", "../api", .typescript);
    try t_testing.expectEqualStrings("src/api.ts", c[0]);
    try t_testing.expectEqualStrings("src/api/index.cjs", c[11]);
}

test "js: unknown extension is treated as extensionless stem" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    // `.json` is not a known JS resolution ext, so it is treated as a stem.
    const c = try candidates(arena, "src/app.ts", "./data.json", .typescript);
    try t_testing.expectEqual(@as(usize, 12), c.len);
    try t_testing.expectEqualStrings("src/data.json.ts", c[0]);
}

// --------------------------------------------------------------------------
// pyCandidates
// --------------------------------------------------------------------------

test "py: absolute dotted import maps to module and package init" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "app/main.py", "pkg.sub.mod", .python);
    try t_testing.expectEqual(@as(usize, 2), c.len);
    try t_testing.expectEqualStrings("pkg/sub/mod.py", c[0]);
    try t_testing.expectEqualStrings("pkg/sub/mod/__init__.py", c[1]);
}

test "py: single-dot relative import resolves from importer dir" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "app/pkg/main.py", ".sibling", .python);
    try t_testing.expectEqual(@as(usize, 2), c.len);
    try t_testing.expectEqualStrings("app/pkg/sibling.py", c[0]);
    try t_testing.expectEqualStrings("app/pkg/sibling/__init__.py", c[1]);
}

test "py: two-dot relative import climbs one package level" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "app/pkg/main.py", "..lib.util", .python);
    try t_testing.expectEqualStrings("app/lib/util.py", c[0]);
    try t_testing.expectEqualStrings("app/lib/util/__init__.py", c[1]);
}

test "py: three-dot relative import climbs two package levels" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "a/b/c/main.py", "...x", .python);
    // dots=3 => prependUp(2, "x") => ../../x relative to a/b/c => a/x
    try t_testing.expectEqualStrings("a/x.py", c[0]);
    try t_testing.expectEqualStrings("a/x/__init__.py", c[1]);
}

test "py: bare `.` relative from a root-level importer yields no candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    // importer has no directory and module is just a dot => empty stem => no candidates.
    const c = try candidates(arena, "main.py", ".", .python);
    try t_testing.expectEqual(@as(usize, 0), c.len);
}

// --------------------------------------------------------------------------
// luaCandidates
// --------------------------------------------------------------------------

test "lua: non-relative dotted require emits root and nvim lua/ candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/main.lua", "a.b.c", .lua);
    try t_testing.expectEqual(@as(usize, 4), c.len);
    try t_testing.expectEqualStrings("a/b/c.lua", c[0]);
    try t_testing.expectEqualStrings("a/b/c/init.lua", c[1]);
    try t_testing.expectEqualStrings("lua/a/b/c.lua", c[2]);
    try t_testing.expectEqualStrings("lua/a/b/c/init.lua", c[3]);
}

test "lua: relative require resolves from importer dir with only 2 candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/plugin/main.lua", ".util", .lua);
    try t_testing.expectEqual(@as(usize, 2), c.len);
    try t_testing.expectEqualStrings("src/plugin/util.lua", c[0]);
    try t_testing.expectEqualStrings("src/plugin/util/init.lua", c[1]);
}

test "lua: single-segment module still emits nvim lua/ variants" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "init.lua", "mymod", .lua);
    try t_testing.expectEqual(@as(usize, 4), c.len);
    try t_testing.expectEqualStrings("mymod.lua", c[0]);
    try t_testing.expectEqualStrings("mymod/init.lua", c[1]);
    try t_testing.expectEqualStrings("lua/mymod.lua", c[2]);
    try t_testing.expectEqualStrings("lua/mymod/init.lua", c[3]);
}

test "lua: bare `.` relative from a root importer yields no candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "main.lua", ".", .lua);
    try t_testing.expectEqual(@as(usize, 0), c.len);
}

// --------------------------------------------------------------------------
// rustCandidates
// --------------------------------------------------------------------------

test "rust: mod name resolves to sibling and subdir mod.rs" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "src/lib.rs", "parser", .rust);
    try t_testing.expectEqual(@as(usize, 2), c.len);
    try t_testing.expectEqualStrings("src/parser.rs", c[0]);
    try t_testing.expectEqualStrings("src/parser/mod.rs", c[1]);
}

test "rust: importer with no directory yields root-relative candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "main.rs", "foo", .rust);
    try t_testing.expectEqualStrings("foo.rs", c[0]);
    try t_testing.expectEqualStrings("foo/mod.rs", c[1]);
}

test "rust: paths containing :: are intra-crate and unresolvable" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try t_testing.expectEqual(@as(usize, 0), (try candidates(arena, "src/main.rs", "crate::a::b", .rust)).len);
    try t_testing.expectEqual(@as(usize, 0), (try candidates(arena, "src/main.rs", "super::x", .rust)).len);
}

test "rust: `.` module against a root importer yields empty stem => no candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "main.rs", ".", .rust);
    try t_testing.expectEqual(@as(usize, 0), c.len);
}

// --------------------------------------------------------------------------
// rubyCandidates
// --------------------------------------------------------------------------

test "ruby: relative require emits both importer-relative and root candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "app/main.rb", "lib/user", .ruby);
    try t_testing.expectEqual(@as(usize, 2), c.len);
    try t_testing.expectEqualStrings("app/lib/user.rb", c[0]);
    try t_testing.expectEqualStrings("lib/user.rb", c[1]);
}

test "ruby: when importer has no dir, rel and root coincide -> single candidate" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "main.rb", "user", .ruby);
    // rel == root == "user", so the duplicate root candidate is suppressed.
    try t_testing.expectEqual(@as(usize, 1), c.len);
    try t_testing.expectEqualStrings("user.rb", c[0]);
}

test "ruby: `.` module against a root importer yields no candidates" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "main.rb", ".", .ruby);
    try t_testing.expectEqual(@as(usize, 0), c.len);
}

test "ruby: `.` module against a nested importer yields only the rel candidate" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    // dirOf = "app"; rel = joinNormalize("app",".") = "app"; root = joinNormalize("",".") = "" (skipped).
    const c = try candidates(arena, "app/main.rb", ".", .ruby);
    try t_testing.expectEqual(@as(usize, 1), c.len);
    try t_testing.expectEqualStrings("app.rb", c[0]);
}

// --------------------------------------------------------------------------
// dirOf
// --------------------------------------------------------------------------

test "dirOf: returns parent dir or empty when no slash" {
    try t_testing.expectEqualStrings("src", dirOf("src/main.rs"));
    try t_testing.expectEqualStrings("a/b", dirOf("a/b/c.py"));
    try t_testing.expectEqualStrings("", dirOf("main.rs"));
    try t_testing.expectEqualStrings("", dirOf(""));
    // trailing slash: parent is everything before the final slash
    try t_testing.expectEqualStrings("src", dirOf("src/"));
    try t_testing.expectEqualStrings("/abs", dirOf("/abs/path.zig"));
}

// --------------------------------------------------------------------------
// joinNormalize
// --------------------------------------------------------------------------

test "joinNormalize: basic join, dot and dotdot resolution" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try expectInsidePath("a/b/c", try joinNormalize(arena, "a/b", "c"));
    try expectInsidePath("a/c", try joinNormalize(arena, "a/b", "../c"));
    try expectInsidePath("c", try joinNormalize(arena, "a/b", "../../c"));
    // interior "." segments are stripped
    try expectInsidePath("a/b/c", try joinNormalize(arena, "a", "./b/./c"));
}

test "joinNormalize: escaping above root and absolute paths stay outside_root" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try t_testing.expectEqual(NormalizedPathStatus.outside_root, std.meta.activeTag(try joinNormalize(arena, "", "../x")));
    try t_testing.expectEqual(NormalizedPathStatus.outside_root, std.meta.activeTag(try joinNormalize(arena, "a", "../../../x")));
    try t_testing.expectEqual(NormalizedPathStatus.outside_root, std.meta.activeTag(try joinNormalize(arena, "", "/x")));
    try t_testing.expectEqual(NormalizedPathStatus.outside_root, std.meta.activeTag(try joinNormalize(arena, "", "C:\\x")));
    // Reaching the root exactly is valid and produces the empty repo-relative path.
    try expectInsidePath("", try joinNormalize(arena, "a/b", "../.."));
}

test "joinNormalize: empty inputs and redundant slashes" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try expectInsidePath("", try joinNormalize(arena, "", ""));
    try expectInsidePath("a/b", try joinNormalize(arena, "a//b", ""));
    try expectInsidePath("a/b", try joinNormalize(arena, "a\\b", ""));
}

// --------------------------------------------------------------------------
// pushSegments (private, exercised directly)
// --------------------------------------------------------------------------

test "pushSegments: appends, skips . and empty, pops on .." {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(arena);
    try t_testing.expect(try pushSegments(arena, &segs, "a/./b//c"));
    try t_testing.expectEqual(@as(usize, 3), segs.items.len);
    try t_testing.expect(try pushSegments(arena, &segs, "../d"));
    try t_testing.expectEqual(@as(usize, 3), segs.items.len);
    try t_testing.expectEqualStrings("a", segs.items[0]);
    try t_testing.expectEqualStrings("b", segs.items[1]);
    try t_testing.expectEqualStrings("d", segs.items[2]);
    // Popping past empty is an explicit outside-root result.
    try t_testing.expect(!try pushSegments(arena, &segs, "../../../../../z"));
}

// --------------------------------------------------------------------------
// dotsToSlashes
// --------------------------------------------------------------------------

test "dotsToSlashes: replaces every dot with a slash" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try t_testing.expectEqualStrings("a/b/c", try dotsToSlashes(arena, "a.b.c"));
    try t_testing.expectEqualStrings("abc", try dotsToSlashes(arena, "abc"));
    try t_testing.expectEqualStrings("", try dotsToSlashes(arena, ""));
    // consecutive dots become consecutive slashes
    try t_testing.expectEqualStrings("a//b", try dotsToSlashes(arena, "a..b"));
}

// --------------------------------------------------------------------------
// leadingDots
// --------------------------------------------------------------------------

test "leadingDots: counts only leading dots" {
    try t_testing.expectEqual(@as(usize, 0), leadingDots("mod"));
    try t_testing.expectEqual(@as(usize, 0), leadingDots("os.path"));
    try t_testing.expectEqual(@as(usize, 1), leadingDots(".mod"));
    try t_testing.expectEqual(@as(usize, 2), leadingDots("..pkg.x"));
    try t_testing.expectEqual(@as(usize, 3), leadingDots("..."));
    try t_testing.expectEqual(@as(usize, 0), leadingDots(""));
}

// --------------------------------------------------------------------------
// hasKnownExt
// --------------------------------------------------------------------------

test "hasKnownExt: true only for the JS resolution extensions" {
    try t_testing.expect(hasKnownExt("a.ts"));
    try t_testing.expect(hasKnownExt("a.tsx"));
    try t_testing.expect(hasKnownExt("a.js"));
    try t_testing.expect(hasKnownExt("a.jsx"));
    try t_testing.expect(hasKnownExt("a.mjs"));
    try t_testing.expect(hasKnownExt("a.cjs"));
    try t_testing.expect(!hasKnownExt("a.py"));
    try t_testing.expect(!hasKnownExt("a.json"));
    try t_testing.expect(!hasKnownExt("noext"));
    try t_testing.expect(!hasKnownExt(""));
}

// --------------------------------------------------------------------------
// concat
// --------------------------------------------------------------------------

test "concat: concatenates two slices" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try t_testing.expectEqualStrings("ab", try concat(arena, "a", "b"));
    try t_testing.expectEqualStrings("foo.rs", try concat(arena, "foo", ".rs"));
    try t_testing.expectEqualStrings("x", try concat(arena, "x", ""));
    try t_testing.expectEqualStrings("y", try concat(arena, "", "y"));
}

// --------------------------------------------------------------------------
// prependUp
// --------------------------------------------------------------------------

test "prependUp: prefixes the requested number of ../ segments" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    // zero levels returns the path unchanged
    try t_testing.expectEqualStrings("lib/util", try prependUp(arena, 0, "lib/util"));
    try t_testing.expectEqualStrings("../lib/util", try prependUp(arena, 1, "lib/util"));
    try t_testing.expectEqualStrings("../../x", try prependUp(arena, 2, "x"));
    try t_testing.expectEqualStrings("../../../", try prependUp(arena, 3, ""));
}

// --------------------------------------------------------------------------
// dupeOne
// --------------------------------------------------------------------------

test "dupeOne: wraps a single slice into a one-element list" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const d = try dupeOne(arena, "only.zig");
    try t_testing.expectEqual(@as(usize, 1), d.len);
    try t_testing.expectEqualStrings("only.zig", d[0]);
}
