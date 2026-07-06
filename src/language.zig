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
    python,
    javascript,
    typescript,
    tsx,
    unknown,

    /// Human-readable short tag used in compressed output.
    pub fn tag(self: Language) []const u8 {
        return switch (self) {
            .zig => "zig",
            .c => "c",
            .cpp => "cpp",
            .python => "py",
            .javascript => "js",
            .typescript => "ts",
            .tsx => "tsx",
            .unknown => "?",
        };
    }

    /// Family groups languages that resolve references against each other.
    pub fn family(self: Language) Family {
        return switch (self) {
            .zig => .zig,
            .c, .cpp => .c,
            .python => .python,
            .javascript, .typescript, .tsx => .js,
            .unknown => .other,
        };
    }
};

pub const Family = enum { zig, c, python, js, other };

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
        .c, .cpp => .{
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
    const map = .{
        .{ ".zig", Language.zig },
        .{ ".c", Language.c },
        .{ ".h", Language.c },
        .{ ".cc", Language.cpp },
        .{ ".cpp", Language.cpp },
        .{ ".cxx", Language.cpp },
        .{ ".hpp", Language.cpp },
        .{ ".hh", Language.cpp },
        .{ ".py", Language.python },
        .{ ".pyi", Language.python },
        .{ ".js", Language.javascript },
        .{ ".mjs", Language.javascript },
        .{ ".cjs", Language.javascript },
        .{ ".jsx", Language.javascript },
        .{ ".ts", Language.typescript },
        .{ ".mts", Language.typescript },
        .{ ".tsx", Language.tsx },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
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
    try std.testing.expectEqual(Language.unknown, detect("README.md"));
    try std.testing.expectEqual(Language.unknown, detect(".gitignore"));
}
