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

/// Repo-relative candidate paths `module` (imported from `importer_path`) may
/// resolve to, most-specific first. Empty when the import is external (a bare
/// package name with no local file). Every element is arena-owned.
pub fn candidates(
    arena: std.mem.Allocator,
    importer_path: []const u8,
    module: []const u8,
    lang: Language,
) ![]const []const u8 {
    std.debug.assert(importer_path.len > 0);
    if (module.len == 0) return &.{};
    return switch (lang.family()) {
        .zig => try zigCandidates(arena, importer_path, module),
        .js => try jsCandidates(arena, importer_path, module),
        .python => try pyCandidates(arena, importer_path, module),
        .lua => try luaCandidates(arena, importer_path, module),
        .rust => try rustCandidates(arena, importer_path, module),
        .ruby => try rubyCandidates(arena, importer_path, module),
        else => &.{},
    };
}

/// Rust `mod name;` resolves to a sibling `name.rs` or a subdir `name/mod.rs`.
/// A `use` path is intra-crate (`crate::a::b`) and unresolvable to a file
/// without the crate root, so `::`-bearing modules yield no candidates.
fn rustCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) ![]const []const u8 {
    if (std.mem.indexOf(u8, module, "::") != null) return &.{};
    const dir = dirOf(importer);
    const stem = try joinNormalize(arena, dir, module);
    if (stem.len == 0) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, try concat(arena, stem, ".rs"));
    try list.append(arena, try concat(arena, stem, "/mod.rs"));
    return list.toOwnedSlice(arena);
}

/// Ruby `require_relative "lib/user"` resolves from the importer's directory;
/// a plain `require "user"` may be a gem, but we also offer a repo-relative
/// `user.rb` in case it names a local file. Non-existent candidates are simply
/// never matched by the index.
fn rubyCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const rel = try joinNormalize(arena, dirOf(importer), module);
    if (rel.len != 0) try list.append(arena, try concat(arena, rel, ".rb"));
    const root = try joinNormalize(arena, "", module);
    if (root.len != 0 and !std.mem.eql(u8, root, rel)) try list.append(arena, try concat(arena, root, ".rb"));
    return list.toOwnedSlice(arena);
}

/// Lua `require "a.b.c"` maps the dotted module to `a/b/c.lua` or the package
/// form `a/b/c/init.lua`. Candidates are emitted both repo-root-relative (LÖVE,
/// plain Lua) and under a `lua/` prefix (the Neovim runtimepath convention,
/// where `require("advantage.util")` resolves to `lua/advantage/util.lua`). A
/// leading `.` (relative require) resolves from the importer's directory.
fn luaCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) ![]const []const u8 {
    const dots = leadingDots(module);
    const base_dir = if (dots > 0) dirOf(importer) else "";
    const slashed = try dotsToSlashes(arena, module[dots..]);
    const stem = try joinNormalize(arena, base_dir, slashed);
    if (stem.len == 0) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, try concat(arena, stem, ".lua"));
    try list.append(arena, try concat(arena, stem, "/init.lua"));
    if (dots == 0) { // Neovim `lua/`-rooted modules
        const nvim = try joinNormalize(arena, "lua", stem);
        try list.append(arena, try concat(arena, nvim, ".lua"));
        try list.append(arena, try concat(arena, nvim, "/init.lua"));
    }
    return list.toOwnedSlice(arena);
}

fn zigCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) ![]const []const u8 {
    // `@import("std")` and other package roots have no local file.
    if (!std.mem.endsWith(u8, module, ".zig")) return &.{};
    const joined = try joinNormalize(arena, dirOf(importer), module);
    return dupeOne(arena, joined);
}

fn jsCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) ![]const []const u8 {
    // Only relative imports refer to local files; bare specifiers are packages.
    if (!std.mem.startsWith(u8, module, ".")) return &.{};
    const base = try joinNormalize(arena, dirOf(importer), module);
    var list: std.ArrayList([]const u8) = .empty;
    if (hasKnownExt(base)) {
        try list.append(arena, base); // already `./foo.ts`
        return list.toOwnedSlice(arena);
    }
    for (js_exts) |ext| try list.append(arena, try concat(arena, base, ext));
    for (js_exts) |ext| try list.append(arena, try concat(arena, base, try concat(arena, "/index", ext)));
    return list.toOwnedSlice(arena);
}

fn pyCandidates(arena: std.mem.Allocator, importer: []const u8, module: []const u8) ![]const []const u8 {
    // Leading dots => relative import: N dots means go up (N-1) package levels
    // from the importer's directory. No leading dot => absolute from the root.
    const dots = leadingDots(module);
    const slashed = try dotsToSlashes(arena, module[dots..]);
    const rel_path = if (dots > 0) try prependUp(arena, dots - 1, slashed) else slashed;
    const base_dir = if (dots > 0) dirOf(importer) else "";
    const stem = try joinNormalize(arena, base_dir, rel_path);
    var list: std.ArrayList([]const u8) = .empty;
    if (stem.len != 0) {
        try list.append(arena, try concat(arena, stem, ".py"));
        try list.append(arena, try concat(arena, stem, "/__init__.py"));
    }
    return list.toOwnedSlice(arena);
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

/// Join `base` and `rel` and resolve `.`/`..` segments into a clean, forward-
/// slash repo-relative path. A `..` that escapes above the root is dropped.
pub fn joinNormalize(arena: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(arena);
    try pushSegments(arena, &segs, base);
    try pushSegments(arena, &segs, rel);

    var out: std.ArrayList(u8) = .empty;
    for (segs.items, 0..) |seg, k| {
        if (k != 0) try out.append(arena, '/');
        try out.appendSlice(arena, seg);
    }
    return out.toOwnedSlice(arena);
}

fn pushSegments(arena: std.mem.Allocator, segs: *std.ArrayList([]const u8), part: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, part, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len != 0) _ = segs.pop();
            continue;
        }
        try segs.append(arena, seg);
    }
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

test "zig: .. that escapes above root is dropped" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    const c = try candidates(arena, "a.zig", "../b.zig", .zig);
    try t_testing.expectEqual(@as(usize, 1), c.len);
    try t_testing.expectEqualStrings("b.zig", c[0]);
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
    try t_testing.expectEqualStrings("a/b/c", try joinNormalize(arena, "a/b", "c"));
    try t_testing.expectEqualStrings("a/c", try joinNormalize(arena, "a/b", "../c"));
    try t_testing.expectEqualStrings("c", try joinNormalize(arena, "a/b", "../../c"));
    // interior "." segments are stripped
    try t_testing.expectEqualStrings("a/b/c", try joinNormalize(arena, "a", "./b/./c"));
}

test "joinNormalize: escaping above the root drops the extra .. segments" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try t_testing.expectEqualStrings("x", try joinNormalize(arena, "", "../x"));
    try t_testing.expectEqualStrings("x", try joinNormalize(arena, "a", "../../../x"));
    try t_testing.expectEqualStrings("", try joinNormalize(arena, "a/b", "../.."));
}

test "joinNormalize: empty inputs and redundant slashes" {
    var a = newArena();
    defer a.deinit();
    const arena = a.allocator();
    try t_testing.expectEqualStrings("", try joinNormalize(arena, "", ""));
    // consecutive/leading slashes tokenize away (leading slash dropped)
    try t_testing.expectEqualStrings("a/b", try joinNormalize(arena, "a//b", ""));
    try t_testing.expectEqualStrings("a/b", try joinNormalize(arena, "/a/b", ""));
    try t_testing.expectEqualStrings("a/b", try joinNormalize(arena, "", "/a/b"));
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
    try pushSegments(arena, &segs, "a/./b//c");
    try t_testing.expectEqual(@as(usize, 3), segs.items.len);
    try pushSegments(arena, &segs, "../d");
    try t_testing.expectEqual(@as(usize, 3), segs.items.len);
    try t_testing.expectEqualStrings("a", segs.items[0]);
    try t_testing.expectEqualStrings("b", segs.items[1]);
    try t_testing.expectEqualStrings("d", segs.items[2]);
    // popping past empty is a no-op
    try pushSegments(arena, &segs, "../../../../../z");
    try t_testing.expectEqual(@as(usize, 1), segs.items.len);
    try t_testing.expectEqualStrings("z", segs.items[0]);
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
