//! Language detection and per-language lexical configuration.
//!
//! NavGraph is deliberately built on a shared, configurable lexer rather than a
//! full parser per language. Each `Language` supplies just enough lexical rules
//! (comment markers, string delimiters, doc-comment style) for the tokenizer and
//! the heuristic symbol extractor to do their job across many languages.

const std = @import("std");

pub const Language = enum {
    zig,
    c,
    cpp,
    csharp,
    python,
    javascript,
    typescript,
    tsx,
    lua,
    go,
    rust,
    ruby,
    java,
    unknown,

    /// Human-readable short tag used in compressed output.
    pub fn tag(self: Language) []const u8 {
        return switch (self) {
            .zig => "zig",
            .c => "c",
            .cpp => "cpp",
            .csharp => "cs",
            .python => "py",
            .javascript => "js",
            .typescript => "ts",
            .tsx => "tsx",
            .lua => "lua",
            .go => "go",
            .rust => "rs",
            .ruby => "rb",
            .java => "java",
            .unknown => "?",
        };
    }

    /// True when the indexer actually resolves this language's import bindings.
    /// Only then is a non-`resolved_local` outcome *evidence* that a name is
    /// external; elsewhere it just means the import form was never parsed.
    /// Mirrors the manifest split in `capabilities.zig`: Rust `use` and Java
    /// wildcards are declared partial, C/C++/C#/Go unsupported.
    pub fn resolvesImportBindings(self: Language) bool {
        return switch (self) {
            .zig, .python, .javascript, .typescript, .tsx, .lua, .ruby => true,
            .c, .cpp, .csharp, .go, .rust, .java, .unknown => false,
        };
    }

    /// True where `T(...)` legitimately invokes the type itself — a Python/Ruby
    /// class call, a C++/Java/C#/Rust constructor, a JS factory. Elsewhere a
    /// *call* bound to a type is always a mis-binding. Go is excluded even
    /// though it spells conversion as a call: `goPackageTarget` records
    /// `models.WidgetID(n)` as a `.type_use`, so nothing is lost and a Go local
    /// shadowing a package can no longer produce an exact call to a type.
    pub fn callMayTargetType(self: Language) bool {
        return switch (self) {
            .python, .ruby, .javascript, .typescript, .tsx, .cpp, .csharp, .java, .rust => true,
            .zig, .c, .go, .lua, .unknown => false,
        };
    }

    /// Whether `name` is a builtin/standard-library container or scalar type in
    /// this language. A member call through a receiver of such a type
    /// (`items.add`, `entries.len`, `items_.size`) belongs to that library, so
    /// the resolver must abstain instead of matching a same-named project
    /// method. Deliberately a small, curated list of the types projects
    /// actually declare fields and locals with — a name absent from it just
    /// keeps today's heuristic behaviour.
    pub fn isBuiltinContainer(self: Language, name: []const u8) bool {
        const table: []const []const u8 = switch (self.family()) {
            .c => &.{
                "vector",   "map",    "unordered_map", "set",    "unordered_set",
                "string",   "array",  "list",          "deque",  "pair",
                "optional", "queue",  "stack",         "span",   "string_view",
                "shared_ptr", "unique_ptr", "weak_ptr", "ostream",  "istream", "ostringstream",
                "size_t",   "int",    "char",          "double", "float",
                "bool",     "FILE",
            },
            .java => &.{
                "List",       "ArrayList", "LinkedList", "Map",      "HashMap",
                "TreeMap",    "Set",       "HashSet",    "TreeSet",  "Collection",
                "Iterator",   "Stream",    "Optional",   "String",   "StringBuilder",
                "Integer",    "Long",      "Double",     "Boolean",  "Object",
                "Arrays",     "Objects",   "Collections",
            },
            .csharp => &.{
                "List",        "Dictionary", "IEnumerable", "IList",    "IDictionary",
                "ICollection", "HashSet",    "Queue",       "Stack",    "Array",
                "String",      "StringBuilder", "Task",     "Nullable", "Tuple",
            },
            .rust => &.{
                "Vec",    "VecDeque", "HashMap", "HashSet", "BTreeMap",
                "BTreeSet", "String", "Option",  "Result",  "Iterator",
                "str",    "Box",      "Rc",      "Arc",     "RefCell",
                "Cell",   "Cow",      "Mutex",   "RwLock",
            },
            .python => &.{
                "dict",  "list",  "set",   "tuple", "str",
                "int",   "float", "bytes", "bool",  "frozenset",
                "deque", "defaultdict", "Counter", "OrderedDict", "Path",
            },
            .js => &.{
                "Array", "Map",     "Set",    "WeakMap", "WeakSet",
                "Object", "String", "Number", "Promise", "Date",
                "RegExp", "JSON",   "Error",
            },
            .zig => &.{
                "ArrayList", "ArrayListUnmanaged", "HashMap", "AutoHashMap",
                "StringHashMap", "ArrayHashMap", "StringArrayHashMap",
                "Allocator", "Writer", "Reader",
            },
            .go, .lua, .ruby, .other => &.{},
        };
        for (table) |t| if (std.mem.eql(u8, t, name)) return true;
        return false;
    }

    /// Whether `name` is a smart pointer whose members are reached through the
    /// type it wraps. A call on a value declared `Box<Expr>` dispatches to
    /// `Expr`'s method, so a *receiver* of this type must not abstain the way an
    /// opaque container does — but `Box::new` is still the wrapper's own. C++
    /// `unique_ptr`/`shared_ptr`/`weak_ptr` dispatch through their pointee the
    /// same way; both stay in `isBuiltinContainer` too, so the wrapper's own
    /// members (`reset`, `get`, `lock`, ...) still never bind to a same-named
    /// project method unless a project method of that exact name exists.
    pub fn derefsToInner(self: Language, name: []const u8) bool {
        const table: []const []const u8 = switch (self.family()) {
            .rust => &.{ "Box", "Rc", "Arc", "RefCell", "Cell", "Cow", "Mutex", "RwLock" },
            .c => &.{ "unique_ptr", "shared_ptr", "weak_ptr" },
            else => return false,
        };
        for (table) |t| if (std.mem.eql(u8, t, name)) return true;
        return false;
    }

    /// Whether a declaration writes the type before the name (`Product p`)
    /// rather than after it (`p: Product`). C, C++, Java and C# do; the
    /// annotation languages and the `:=`/`let` forms do not.
    pub fn declaresTypeBeforeName(self: Language) bool {
        return switch (self) {
            .c, .cpp, .java, .csharp => true,
            .zig, .python, .javascript, .typescript, .tsx, .lua, .go, .rust, .ruby, .unknown => false,
        };
    }

    /// Family groups languages that resolve references against each other.
    pub fn family(self: Language) Family {
        return switch (self) {
            .zig => .zig,
            .c, .cpp => .c,
            .csharp => .csharp,
            .python => .python,
            .javascript, .typescript, .tsx => .js,
            .lua => .lua,
            .go => .go,
            .rust => .rust,
            .ruby => .ruby,
            .java => .java,
            .unknown => .other,
        };
    }
};

pub const Family = enum { zig, c, csharp, python, js, lua, go, rust, ruby, java, other };

/// Canonical public language inventory. Detection and the capability manifest
/// consume the same table so adding a parser family cannot silently leave agent
/// clients advertising an older set.
pub const Descriptor = struct {
    language: Language,
    name: []const u8,
    extensions: []const []const u8,
};

pub const supported = [_]Descriptor{
    .{ .language = .zig, .name = "zig", .extensions = &.{".zig"} },
    .{ .language = .c, .name = "c", .extensions = &.{ ".c", ".h" } },
    .{ .language = .cpp, .name = "cpp", .extensions = &.{ ".cc", ".cpp", ".cxx", ".hpp", ".hh" } },
    .{ .language = .csharp, .name = "csharp", .extensions = &.{".cs"} },
    .{ .language = .python, .name = "python", .extensions = &.{ ".py", ".pyi" } },
    .{ .language = .javascript, .name = "javascript", .extensions = &.{ ".js", ".mjs", ".cjs", ".jsx" } },
    .{ .language = .typescript, .name = "typescript", .extensions = &.{ ".ts", ".mts" } },
    .{ .language = .tsx, .name = "tsx", .extensions = &.{".tsx"} },
    .{ .language = .lua, .name = "lua", .extensions = &.{".lua"} },
    .{ .language = .go, .name = "go", .extensions = &.{".go"} },
    .{ .language = .rust, .name = "rust", .extensions = &.{".rs"} },
    .{ .language = .ruby, .name = "ruby", .extensions = &.{".rb"} },
    .{ .language = .java, .name = "java", .extensions = &.{".java"} },
};

/// Doc-comment extraction style differs enough between languages to name it.
pub const DocStyle = enum {
    /// Zig: lines starting with `///` (and `//!`) immediately above a decl.
    zig_slashes,
    /// C/JS/TS: `/** ... */` block or `//`-run immediately above a decl.
    block_star,
    /// Python: `"""..."""` string as the first statement of the body.
    py_string,
    none,
};

pub const Config = struct {
    language: Language,
    /// Single-line comment prefix, e.g. "//" or "#". Empty means none.
    line_comment: []const u8,
    /// Block comment open/close, e.g. "/*" / "*/". Empty means none.
    block_open: []const u8,
    block_close: []const u8,
    /// Characters that open/close a string literal (matched pairwise).
    string_delims: []const u8,
    /// Whether backtick template strings are supported (js/ts).
    template_strings: bool,
    /// Marker that begins a to-end-of-line string literal (Zig's `\\`). Empty
    /// means none. Prevents string contents being tokenized as code.
    line_string: []const u8 = "",
    doc_style: DocStyle,
    /// True for indentation-scoped languages (python) vs brace-scoped.
    brace_scoped: bool,
};

pub fn configFor(language: Language) Config {
    return switch (language) {
        .zig => .{
            .language = .zig,
            .line_comment = "//",
            .block_open = "",
            .block_close = "",
            .string_delims = "\"'",
            .template_strings = false,
            .line_string = "\\\\",
            .doc_style = .zig_slashes,
            .brace_scoped = true,
        },
        .c, .cpp, .csharp, .java => .{
            .language = language,
            .line_comment = "//",
            .block_open = "/*",
            .block_close = "*/",
            .string_delims = "\"'",
            .template_strings = false,
            .doc_style = .block_star,
            .brace_scoped = true,
        },
        .python => .{
            .language = .python,
            .line_comment = "#",
            .block_open = "",
            .block_close = "",
            .string_delims = "\"'",
            .template_strings = false,
            .doc_style = .py_string,
            .brace_scoped = false,
        },
        .javascript, .typescript, .tsx => .{
            .language = language,
            .line_comment = "//",
            .block_open = "/*",
            .block_close = "*/",
            .string_delims = "\"'",
            .template_strings = true,
            .doc_style = .block_star,
            .brace_scoped = true,
        },
        .lua => .{
            .language = .lua,
            .line_comment = "--",
            .block_open = "--[[",
            .block_close = "]]",
            .string_delims = "\"'",
            .template_strings = false,
            .doc_style = .none,
            .brace_scoped = false,
        },
        .go => .{
            .language = .go,
            .line_comment = "//",
            .block_open = "/*",
            .block_close = "*/",
            .string_delims = "\"'",
            // Backtick raw strings.
            .template_strings = true,
            .doc_style = .block_star,
            .brace_scoped = true,
        },
        .rust => .{
            .language = .rust,
            .line_comment = "//",
            .block_open = "/*",
            .block_close = "*/",
            // `'` is included for char literals; the lexer's Rust guard keeps a
            // lifetime (`&'a T`) from opening one and swallowing code.
            .string_delims = "\"'",
            .template_strings = false,
            .doc_style = .block_star,
            .brace_scoped = true,
        },
        .ruby => .{
            .language = .ruby,
            .line_comment = "#",
            .block_open = "",
            .block_close = "",
            .string_delims = "\"'",
            .template_strings = false,
            .doc_style = .block_star,
            .brace_scoped = false,
        },
        .unknown => .{
            .language = .unknown,
            .line_comment = "",
            .block_open = "",
            .block_close = "",
            .string_delims = "",
            .template_strings = false,
            .doc_style = .none,
            .brace_scoped = true,
        },
    };
}

/// Detect language from a file path's extension. Returns `.unknown` when the
/// extension is not recognised so callers can skip non-source files.
pub fn detect(path: []const u8) Language {
    const ext = extension(path);
    inline for (supported) |descriptor| {
        inline for (descriptor.extensions) |candidate| {
            if (std.mem.eql(u8, ext, candidate)) return descriptor.language;
        }
    }
    return .unknown;
}

/// Returns the extension including the dot (lowercased view not needed since we
/// compare against lowercase literals; paths are expected lowercase-ext).
fn extension(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    // Guard against dotfiles like ".gitignore" where the dot is the basename start.
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    if (dot <= slash + 1 and slash != 0) return "";
    if (dot == 0) return "";
    return path[dot..];
}

test "detect language from extension" {
    try std.testing.expectEqual(Language.zig, detect("src/main.zig"));
    try std.testing.expectEqual(Language.python, detect("app/server.py"));
    try std.testing.expectEqual(Language.tsx, detect("web/App.tsx"));
    try std.testing.expectEqual(Language.csharp, detect("Shop/Order.cs"));
    try std.testing.expectEqual(Language.lua, detect("config/init.lua"));
    try std.testing.expectEqual(Language.go, detect("cmd/server/main.go"));
    try std.testing.expectEqual(Language.rust, detect("src/lib.rs"));
    try std.testing.expectEqual(Language.ruby, detect("app/models/user.rb"));
    try std.testing.expectEqual(Language.java, detect("src/main/java/com/foo/Bar.java"));
    try std.testing.expectEqual(Language.unknown, detect("README.md"));
    try std.testing.expectEqual(Language.unknown, detect(".gitignore"));
}

test "supported language descriptors cover every indexed enum exactly once" {
    try std.testing.expectEqual(std.meta.fields(Language).len - 1, supported.len);
    var seen = std.EnumSet(Language).initEmpty();
    for (supported) |descriptor| {
        try std.testing.expect(descriptor.language != .unknown);
        try std.testing.expectEqualStrings(@tagName(descriptor.language), descriptor.name);
        try std.testing.expect(!seen.contains(descriptor.language));
        seen.insert(descriptor.language);
        try std.testing.expect(descriptor.extensions.len > 0);
        for (descriptor.extensions) |ext| {
            try std.testing.expect(ext.len > 1 and ext[0] == '.');
            var path_buf: [32]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "fixture{s}", .{ext});
            try std.testing.expectEqual(descriptor.language, detect(path));
        }
    }
}

// ---------------------------------------------------------------------------
// Appended hardening tests for language.zig
// ---------------------------------------------------------------------------

// ---- detect(): every supported extension ----------------------------------

test "detect: C and header extensions map to c" {
    try std.testing.expectEqual(Language.c, detect("src/foo.c"));
    try std.testing.expectEqual(Language.c, detect("include/foo.h"));
    try std.testing.expectEqual(Language.c, detect("a/b/c/deep.h"));
}

test "detect: C++ source and header extensions map to cpp" {
    try std.testing.expectEqual(Language.cpp, detect("a.cc"));
    try std.testing.expectEqual(Language.cpp, detect("a.cpp"));
    try std.testing.expectEqual(Language.cpp, detect("a.cxx"));
    try std.testing.expectEqual(Language.cpp, detect("a.hpp"));
    try std.testing.expectEqual(Language.cpp, detect("a.hh"));
}

test "detect: csharp extension" {
    try std.testing.expectEqual(Language.csharp, detect("Shop/Order.cs"));
}

test "detect: python extensions" {
    try std.testing.expectEqual(Language.python, detect("app/server.py"));
    try std.testing.expectEqual(Language.python, detect("stubs/typing.pyi"));
}

test "detect: javascript extensions" {
    try std.testing.expectEqual(Language.javascript, detect("web/app.js"));
    try std.testing.expectEqual(Language.javascript, detect("web/app.mjs"));
    try std.testing.expectEqual(Language.javascript, detect("web/app.cjs"));
    try std.testing.expectEqual(Language.javascript, detect("web/App.jsx"));
}

test "detect: typescript extensions excluding tsx" {
    try std.testing.expectEqual(Language.typescript, detect("web/app.ts"));
    try std.testing.expectEqual(Language.typescript, detect("web/app.mts"));
}

test "detect: tsx is its own language distinct from typescript" {
    try std.testing.expectEqual(Language.tsx, detect("web/App.tsx"));
    // .tsx must NOT collapse into .typescript.
    try std.testing.expect(detect("web/App.tsx") != Language.typescript);
}

test "detect: remaining single-extension languages" {
    try std.testing.expectEqual(Language.zig, detect("src/main.zig"));
    try std.testing.expectEqual(Language.lua, detect("config/init.lua"));
    try std.testing.expectEqual(Language.go, detect("cmd/server/main.go"));
    try std.testing.expectEqual(Language.rust, detect("src/lib.rs"));
    try std.testing.expectEqual(Language.ruby, detect("app/models/user.rb"));
}

test "detect: unrecognised extensions return unknown" {
    try std.testing.expectEqual(Language.unknown, detect("README.md"));
    try std.testing.expectEqual(Language.unknown, detect("data.json"));
    try std.testing.expectEqual(Language.unknown, detect("notes.txt"));
    try std.testing.expectEqual(Language.unknown, detect("style.css"));
    try std.testing.expectEqual(Language.unknown, detect("Makefile"));
    try std.testing.expectEqual(Language.unknown, detect(""));
}

test "detect: no-extension paths return unknown" {
    try std.testing.expectEqual(Language.unknown, detect("bin/tool"));
    try std.testing.expectEqual(Language.unknown, detect("LICENSE"));
}

test "detect: dotfiles are not treated as source" {
    try std.testing.expectEqual(Language.unknown, detect(".gitignore"));
    try std.testing.expectEqual(Language.unknown, detect("proj/.gitignore"));
    try std.testing.expectEqual(Language.unknown, detect("proj/.env"));
}

test "detect: extension matching is case-sensitive" {
    // Comment on extension() says paths are expected lowercase-ext; verify
    // uppercase variants do NOT resolve.
    try std.testing.expectEqual(Language.unknown, detect("SRC/MAIN.ZIG"));
    try std.testing.expectEqual(Language.unknown, detect("App.TS"));
    try std.testing.expectEqual(Language.unknown, detect("Order.CS"));
}

test "detect: dots in directory names do not confuse extension" {
    // Directory has a dot but the file itself has an extension.
    try std.testing.expectEqual(Language.python, detect("my.pkg/server.py"));
    try std.testing.expectEqual(Language.zig, detect("v1.2/build.zig"));
    // Directory has a dot but the file has NO extension.
    try std.testing.expectEqual(Language.unknown, detect("my.dir/README"));
    try std.testing.expectEqual(Language.unknown, detect("a.b.c/main"));
}

test "detect: leading-slash absolute paths still resolve" {
    try std.testing.expectEqual(Language.zig, detect("/home/u/main.zig"));
    try std.testing.expectEqual(Language.go, detect("/main.go"));
}

// ---- extension(): private helper edge cases -------------------------------

test "extension: basic extraction includes the dot" {
    try std.testing.expectEqualStrings(".zig", extension("main.zig"));
    try std.testing.expectEqualStrings(".py", extension("a/b/c.py"));
}

test "extension: no dot yields empty" {
    try std.testing.expectEqualStrings("", extension("Makefile"));
    try std.testing.expectEqualStrings("", extension("bin/tool"));
    try std.testing.expectEqualStrings("", extension(""));
}

test "extension: trailing dot yields a bare dot" {
    // lastIndexOf finds the trailing dot; nothing follows it.
    try std.testing.expectEqualStrings(".", extension("archive."));
    try std.testing.expectEqualStrings(".", extension("dir/archive."));
}

test "extension: leading-dot basename (dotfile) yields empty" {
    try std.testing.expectEqualStrings("", extension(".gitignore"));
    try std.testing.expectEqualStrings("", extension("path/to/.hidden"));
}

test "extension: multiple dots keeps only the last segment" {
    try std.testing.expectEqualStrings(".ts", extension("a.b.c.ts"));
    try std.testing.expectEqualStrings(".local", extension("config.env.local"));
}

test "extension: dot in directory with dotless file yields empty" {
    try std.testing.expectEqualStrings("", extension("a.b/c"));
    try std.testing.expectEqualStrings("", extension("x.y.z/main"));
}

test "extension: dot immediately after slash yields empty" {
    // "a/.b" -> dot right after the slash means the file is a dotfile.
    try std.testing.expectEqualStrings("", extension("a/.b"));
    try std.testing.expectEqualStrings("", extension("src/.env"));
}

// ---- configFor(): invariants across all languages -------------------------

test "configFor: config.language round-trips for every language" {
    inline for (std.meta.fields(Language)) |f| {
        const lang = @field(Language, f.name);
        try std.testing.expectEqual(lang, configFor(lang).language);
    }
}

test "configFor: line_string is populated only for zig" {
    inline for (std.meta.fields(Language)) |f| {
        const lang = @field(Language, f.name);
        const cfg = configFor(lang);
        if (lang == .zig) {
            try std.testing.expectEqualStrings("\\\\", cfg.line_string);
            try std.testing.expectEqual(@as(usize, 2), cfg.line_string.len);
        } else {
            try std.testing.expectEqual(@as(usize, 0), cfg.line_string.len);
        }
    }
}

test "configFor: brace_scoped is false only for python, lua, ruby" {
    inline for (std.meta.fields(Language)) |f| {
        const lang = @field(Language, f.name);
        const cfg = configFor(lang);
        const expected_indent = (lang == .python or lang == .lua or lang == .ruby);
        try std.testing.expectEqual(!expected_indent, cfg.brace_scoped);
    }
}

test "configFor: template_strings true only for js, ts, tsx, and go" {
    inline for (std.meta.fields(Language)) |f| {
        const lang = @field(Language, f.name);
        const cfg = configFor(lang);
        const expect_tmpl = switch (lang) {
            .javascript, .typescript, .tsx, .go => true,
            else => false,
        };
        try std.testing.expectEqual(expect_tmpl, cfg.template_strings);
    }
}

test "configFor: string_delims empty only for unknown" {
    inline for (std.meta.fields(Language)) |f| {
        const lang = @field(Language, f.name);
        const cfg = configFor(lang);
        if (lang == .unknown) {
            try std.testing.expectEqual(@as(usize, 0), cfg.string_delims.len);
        } else {
            try std.testing.expectEqualStrings("\"'", cfg.string_delims);
        }
    }
}

test "configFor: zig specifics" {
    const cfg = configFor(.zig);
    try std.testing.expectEqualStrings("//", cfg.line_comment);
    try std.testing.expectEqualStrings("", cfg.block_open);
    try std.testing.expectEqualStrings("", cfg.block_close);
    try std.testing.expectEqualStrings("\"'", cfg.string_delims);
    try std.testing.expectEqual(false, cfg.template_strings);
    try std.testing.expectEqual(DocStyle.zig_slashes, cfg.doc_style);
    try std.testing.expectEqual(true, cfg.brace_scoped);
}

test "configFor: c, cpp, csharp share block-comment config but keep language tag" {
    const langs = [_]Language{ .c, .cpp, .csharp };
    for (langs) |lang| {
        const cfg = configFor(lang);
        try std.testing.expectEqual(lang, cfg.language);
        try std.testing.expectEqualStrings("//", cfg.line_comment);
        try std.testing.expectEqualStrings("/*", cfg.block_open);
        try std.testing.expectEqualStrings("*/", cfg.block_close);
        try std.testing.expectEqual(DocStyle.block_star, cfg.doc_style);
        try std.testing.expectEqual(true, cfg.brace_scoped);
        try std.testing.expectEqual(false, cfg.template_strings);
        try std.testing.expectEqual(@as(usize, 0), cfg.line_string.len);
    }
}

test "configFor: python specifics" {
    const cfg = configFor(.python);
    try std.testing.expectEqualStrings("#", cfg.line_comment);
    try std.testing.expectEqualStrings("", cfg.block_open);
    try std.testing.expectEqualStrings("", cfg.block_close);
    try std.testing.expectEqual(DocStyle.py_string, cfg.doc_style);
    try std.testing.expectEqual(false, cfg.brace_scoped);
    try std.testing.expectEqual(false, cfg.template_strings);
}

test "configFor: js, ts, tsx enable template strings with block-star docs" {
    const langs = [_]Language{ .javascript, .typescript, .tsx };
    for (langs) |lang| {
        const cfg = configFor(lang);
        try std.testing.expectEqual(lang, cfg.language);
        try std.testing.expectEqualStrings("//", cfg.line_comment);
        try std.testing.expectEqualStrings("/*", cfg.block_open);
        try std.testing.expectEqualStrings("*/", cfg.block_close);
        try std.testing.expectEqual(true, cfg.template_strings);
        try std.testing.expectEqual(DocStyle.block_star, cfg.doc_style);
        try std.testing.expectEqual(true, cfg.brace_scoped);
    }
}

test "configFor: lua specifics with long-bracket block comments" {
    const cfg = configFor(.lua);
    try std.testing.expectEqualStrings("--", cfg.line_comment);
    try std.testing.expectEqualStrings("--[[", cfg.block_open);
    try std.testing.expectEqualStrings("]]", cfg.block_close);
    try std.testing.expectEqual(DocStyle.none, cfg.doc_style);
    try std.testing.expectEqual(false, cfg.brace_scoped);
    try std.testing.expectEqual(false, cfg.template_strings);
}

test "configFor: go enables backtick raw strings" {
    const cfg = configFor(.go);
    try std.testing.expectEqualStrings("//", cfg.line_comment);
    try std.testing.expectEqualStrings("/*", cfg.block_open);
    try std.testing.expectEqualStrings("*/", cfg.block_close);
    try std.testing.expectEqual(true, cfg.template_strings);
    try std.testing.expectEqual(DocStyle.block_star, cfg.doc_style);
    try std.testing.expectEqual(true, cfg.brace_scoped);
}

test "configFor: rust specifics" {
    const cfg = configFor(.rust);
    try std.testing.expectEqualStrings("//", cfg.line_comment);
    try std.testing.expectEqualStrings("/*", cfg.block_open);
    try std.testing.expectEqualStrings("*/", cfg.block_close);
    try std.testing.expectEqualStrings("\"'", cfg.string_delims);
    try std.testing.expectEqual(false, cfg.template_strings);
    try std.testing.expectEqual(DocStyle.block_star, cfg.doc_style);
    try std.testing.expectEqual(true, cfg.brace_scoped);
}

test "configFor: ruby specifics" {
    const cfg = configFor(.ruby);
    try std.testing.expectEqualStrings("#", cfg.line_comment);
    try std.testing.expectEqualStrings("", cfg.block_open);
    try std.testing.expectEqualStrings("", cfg.block_close);
    try std.testing.expectEqual(DocStyle.block_star, cfg.doc_style);
    try std.testing.expectEqual(false, cfg.brace_scoped);
    try std.testing.expectEqual(false, cfg.template_strings);
}

test "configFor: java specifics" {
    const cfg = configFor(.java);
    try std.testing.expectEqual(Language.java, cfg.language);
    try std.testing.expectEqualStrings("//", cfg.line_comment);
    try std.testing.expectEqualStrings("/*", cfg.block_open);
    try std.testing.expectEqualStrings("*/", cfg.block_close);
    try std.testing.expectEqualStrings("\"'", cfg.string_delims);
    try std.testing.expectEqual(false, cfg.template_strings);
    try std.testing.expectEqual(DocStyle.block_star, cfg.doc_style);
    try std.testing.expectEqual(true, cfg.brace_scoped);
}

test "configFor: unknown is fully inert" {
    const cfg = configFor(.unknown);
    try std.testing.expectEqualStrings("", cfg.line_comment);
    try std.testing.expectEqualStrings("", cfg.block_open);
    try std.testing.expectEqualStrings("", cfg.block_close);
    try std.testing.expectEqualStrings("", cfg.string_delims);
    try std.testing.expectEqual(false, cfg.template_strings);
    try std.testing.expectEqual(@as(usize, 0), cfg.line_string.len);
    try std.testing.expectEqual(DocStyle.none, cfg.doc_style);
    // brace_scoped defaults to true for the inert config.
    try std.testing.expectEqual(true, cfg.brace_scoped);
}

// ---- Language.tag() -------------------------------------------------------

test "tag: every language yields its documented short tag" {
    try std.testing.expectEqualStrings("zig", Language.zig.tag());
    try std.testing.expectEqualStrings("c", Language.c.tag());
    try std.testing.expectEqualStrings("cpp", Language.cpp.tag());
    try std.testing.expectEqualStrings("cs", Language.csharp.tag());
    try std.testing.expectEqualStrings("py", Language.python.tag());
    try std.testing.expectEqualStrings("js", Language.javascript.tag());
    try std.testing.expectEqualStrings("ts", Language.typescript.tag());
    try std.testing.expectEqualStrings("tsx", Language.tsx.tag());
    try std.testing.expectEqualStrings("lua", Language.lua.tag());
    try std.testing.expectEqualStrings("go", Language.go.tag());
    try std.testing.expectEqualStrings("rs", Language.rust.tag());
    try std.testing.expectEqualStrings("rb", Language.ruby.tag());
    try std.testing.expectEqualStrings("java", Language.java.tag());
    try std.testing.expectEqualStrings("?", Language.unknown.tag());
}

test "tag: every language returns a non-empty tag" {
    inline for (std.meta.fields(Language)) |f| {
        const lang = @field(Language, f.name);
        try std.testing.expect(lang.tag().len > 0);
    }
}

// ---- Language.family() ----------------------------------------------------

test "family: each language maps to its resolution family" {
    try std.testing.expectEqual(Family.zig, Language.zig.family());
    try std.testing.expectEqual(Family.c, Language.c.family());
    try std.testing.expectEqual(Family.c, Language.cpp.family());
    try std.testing.expectEqual(Family.csharp, Language.csharp.family());
    try std.testing.expectEqual(Family.python, Language.python.family());
    try std.testing.expectEqual(Family.js, Language.javascript.family());
    try std.testing.expectEqual(Family.js, Language.typescript.family());
    try std.testing.expectEqual(Family.js, Language.tsx.family());
    try std.testing.expectEqual(Family.lua, Language.lua.family());
    try std.testing.expectEqual(Family.go, Language.go.family());
    try std.testing.expectEqual(Family.rust, Language.rust.family());
    try std.testing.expectEqual(Family.ruby, Language.ruby.family());
    try std.testing.expectEqual(Family.java, Language.java.family());
    try std.testing.expectEqual(Family.other, Language.unknown.family());
}

test "family: c and cpp share the c family; js dialects share the js family" {
    try std.testing.expectEqual(Language.c.family(), Language.cpp.family());
    try std.testing.expectEqual(Language.javascript.family(), Language.typescript.family());
    try std.testing.expectEqual(Language.typescript.family(), Language.tsx.family());
    // Distinct families do not collide.
    try std.testing.expect(Language.zig.family() != Language.go.family());
    try std.testing.expect(Language.python.family() != Language.ruby.family());
}

// ---- detect() + configFor() composition -----------------------------------

test "detect then configFor: a .zig path is the only line_string path" {
    const cfg = configFor(detect("build.zig"));
    try std.testing.expectEqual(Language.zig, cfg.language);
    try std.testing.expect(cfg.line_string.len > 0);
}

test "detect then configFor: an unknown path yields the inert config" {
    const cfg = configFor(detect("README.md"));
    try std.testing.expectEqual(Language.unknown, cfg.language);
    try std.testing.expectEqual(DocStyle.none, cfg.doc_style);
    try std.testing.expectEqual(@as(usize, 0), cfg.string_delims.len);
}
