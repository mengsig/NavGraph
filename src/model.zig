//! Core data model for the code graph: files, symbols and references.
//!
//! All string slices point into the owning `SourceFile.text`, which is kept
//! alive for the lifetime of the `Graph`. Nothing here allocates; construction
//! and ownership live in `index.zig`.

const std = @import("std");
const language = @import("language.zig");

pub const SymbolId = u32;
pub const FileId = u32;

pub const invalid_symbol: SymbolId = std.math.maxInt(SymbolId);

pub const SymbolKind = enum {
    function,
    method,
    class,
    @"struct",
    @"enum",
    interface,
    type,
    variable,
    constant,
    field,
    macro,
    module,
    import,
    route,
    /// A router-mount directive (FastAPI `include_router(mod.router, prefix=…)`):
    /// records the URL prefix under which another module's routes are mounted, so
    /// `index` can prefix those routes cross-file. Never shown to users.
    route_mount,
    /// A test unit with its own body/call-graph: a Zig `test "…" {}` block (and,
    /// in future, other native test constructs). Kept as a first-class symbol so
    /// `callers`/`coverage` can see which tests exercise a function.
    test_case,
    unknown,

    /// Whether `t` names a known kind: a tag (`fn`, `struct`, …) or a CLI alias
    /// (`function`/`func`, `constant`, `variable`). Lets the CLI reject a typo'd
    /// `-k` filter instead of silently matching nothing.
    pub fn validName(t: []const u8) bool {
        inline for (@typeInfo(SymbolKind).@"enum".fields) |f| {
            if (std.mem.eql(u8, t, @field(SymbolKind, f.name).tag())) return true;
        }
        inline for (.{ "function", "func", "constant", "variable" }) |a| {
            if (std.mem.eql(u8, t, a)) return true;
        }
        return false;
    }

    pub fn tag(self: SymbolKind) []const u8 {
        return switch (self) {
            .function => "fn",
            .method => "method",
            .class => "class",
            .@"struct" => "struct",
            .@"enum" => "enum",
            .interface => "iface",
            .type => "type",
            .variable => "var",
            .constant => "const",
            .field => "field",
            .macro => "macro",
            .module => "mod",
            .import => "import",
            .route => "route",
            .route_mount => "mount",
            .test_case => "test",
            .unknown => "sym",
        };
    }

    /// Symbols an agent typically wants as top-level outline entries.
    pub fn isTopLevelInteresting(self: SymbolKind) bool {
        return switch (self) {
            .import, .field, .unknown, .route_mount => false,
            else => true,
        };
    }
};

pub const RefKind = enum {
    call,
    type_use,
    read,
    import,
    route_call,
};

/// Definition modifiers that refine a symbol without changing its `kind`:
/// accessor role (getter/setter), dispatch (static/classmethod), async-ness and
/// abstractness. Deliberately language-agnostic — JS/TS `get`/`set`/`static`/
/// `async`, Python `@property`/`@staticmethod`/`@classmethod`/`@abstractmethod`
/// and `async def`, C++ `static`/`virtual`. Rendered as words before the kind
/// tag (`async fn run`, `static get x`) so an agent isn't misled into reading a
/// getter as a plain method; the `kind` itself is untouched, so `-k` filtering
/// and graph semantics are unaffected. Serialized as a single byte.
pub const Mods = packed struct(u8) {
    is_static: bool = false,
    is_async: bool = false,
    getter: bool = false,
    setter: bool = false,
    classmethod: bool = false,
    abstract: bool = false,
    _pad: u2 = 0,

    /// Whether any modifier is set (nothing to render otherwise).
    pub fn any(self: Mods) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

/// A use of some name inside a symbol's body. `target` is filled during
/// resolution (`invalid_symbol` when unresolved / external).
pub const Reference = struct {
    name: []const u8,
    /// Receiver identifier for a member access `recv.name`, else "" for a bare
    /// reference. Used to type-scope resolution (kills same-name false edges).
    qualifier: []const u8 = "",
    /// First line (1-based) where this name is referenced in the body.
    line: u32,
    kind: RefKind,
    /// Number of times this name is referenced within the owning symbol's body.
    count: u32 = 1,
    /// The distinct 1-based lines this name is referenced on, in source order
    /// (`line` is the first). Populated only when there is more than one distinct
    /// line — a single-site reference leaves it empty and callers fall back to
    /// `line`. Lets `callers`/`calls` show *every* call site, not just the first,
    /// when a caller invokes the target on several lines.
    lines: []const u32 = &.{},
    target: SymbolId = invalid_symbol,
    /// True when resolution bound `target` via a known receiver type or self,
    /// rather than a heuristic global name match. `--strict` follows only these.
    exact: bool = false,
};

/// A local variable binding discovered inside a symbol body: `name` was declared
/// with (inferred) type `type_name`. Used to resolve `name.method()` receivers.
pub const Binding = struct {
    name: []const u8,
    type_name: []const u8,
};

/// A definition discovered in a source file.
pub const Symbol = struct {
    id: SymbolId,
    file: FileId,
    name: []const u8,
    kind: SymbolKind,
    /// 1-based line of the definition.
    line: u32,
    /// Byte range [span_start, span_end) of the whole definition including body.
    span_start: u32,
    span_end: u32,
    /// Byte offset where the signature/declaration ends (start of body or line end).
    sig_end: u32,
    /// Doc comment text (may be empty). Slice into source.
    doc: []const u8,
    /// Enclosing symbol (e.g. class for a method), or `invalid_symbol`.
    parent: SymbolId,
    /// True when the definition is exported/public.
    exported: bool,
    /// Accessor/dispatch/async modifiers (see `Mods`). Refines how the symbol is
    /// displayed without altering `kind`.
    modifiers: Mods = .{},
    /// Outgoing references collected from the body.
    refs: []Reference,
    /// Local variable -> type-name bindings discovered in the body.
    bindings: []const Binding = &.{},
    /// For an `import` symbol: the raw module string (`"util.zig"`, `"./api"`,
    /// `os.path`). Empty for every other kind. `name` holds the binding it is
    /// imported as, so `import_path` + `name` gives `alias -> module`.
    import_path: []const u8 = "",

    /// The single-line signature slice (declaration up to sig_end), trimmed.
    pub fn signature(self: Symbol, source: []const u8) []const u8 {
        std.debug.assert(self.span_start <= self.sig_end);
        std.debug.assert(self.sig_end <= source.len);
        const raw = source[self.span_start..self.sig_end];
        return std.mem.trim(u8, raw, " \t\r\n");
    }

    /// The full definition text (signature + body).
    pub fn body(self: Symbol, source: []const u8) []const u8 {
        std.debug.assert(self.span_start <= self.span_end);
        std.debug.assert(self.span_end <= source.len);
        return source[self.span_start..self.span_end];
    }

    /// 1-based line where the definition ends (line of the last body byte). Equal
    /// to `line` for a single-line definition. Lets a caller read exactly the
    /// symbol's source range (`file:line-endLine`) instead of guessing.
    ///
    /// Computed absolutely — the line of the definition's last real byte — rather
    /// than as an offset from `line`, because a span can legitimately begin on an
    /// earlier line than the name (a `template <…>` prefix, a multi-line return
    /// type, a leading doc comment), which would otherwise skew the result.
    pub fn endLine(self: Symbol, source: []const u8) u32 {
        std.debug.assert(self.span_end <= source.len);
        // Trim trailing newlines/CR so the end is the line of the last real byte
        // (span_end usually points just past the closing brace's newline).
        var end = self.span_end;
        while (end > self.span_start and (source[end - 1] == '\n' or source[end - 1] == '\r')) end -= 1;
        if (end == 0) return self.line;
        var nl: u32 = 0;
        var i: usize = 0;
        const last = end - 1;
        while (i < last) : (i += 1) {
            if (source[i] == '\n') nl += 1;
        }
        // Never report before the definition's own (name) line.
        return @max(nl + 1, self.line);
    }
};

pub const SourceFile = struct {
    id: FileId,
    /// Path relative to the project root.
    path: []const u8,
    language: language.Language,
    /// Owned source text (kept alive for the graph's lifetime).
    text: []const u8,
    /// Half-open range into `Graph.symbols` for this file's symbols.
    sym_start: u32,
    sym_end: u32,
};

pub const Graph = struct {
    files: []SourceFile,
    symbols: []Symbol,

    pub fn fileOf(self: *const Graph, sym: Symbol) *const SourceFile {
        std.debug.assert(sym.file < self.files.len);
        return &self.files[sym.file];
    }

    pub fn symbol(self: *const Graph, id: SymbolId) *const Symbol {
        std.debug.assert(id != invalid_symbol);
        std.debug.assert(id < self.symbols.len);
        return &self.symbols[id];
    }

    pub fn sourceOf(self: *const Graph, id: SymbolId) []const u8 {
        const sym = self.symbol(id);
        return self.files[sym.file].text;
    }
};

test "symbol signature and body slice within bounds" {
    const src = "pub fn add(a: i32) i32 {\n    return a;\n}";
    const sym = Symbol{
        .id = 0,
        .file = 0,
        .name = "add",
        .kind = .function,
        .line = 1,
        .span_start = 0,
        .span_end = @intCast(src.len),
        .sig_end = 23,
        .doc = "",
        .parent = invalid_symbol,
        .exported = true,
        .refs = &.{},
    };
    try std.testing.expectEqualStrings("pub fn add(a: i32) i32", sym.signature(src));
    try std.testing.expectEqualStrings(src, sym.body(src));
    // Body spans 3 lines (1: signature, 2: return, 3: closing brace).
    try std.testing.expectEqual(@as(u32, 3), sym.endLine(src));
}

test "endLine equals line for a single-line definition" {
    const src = "const x = 1;\n";
    const sym = Symbol{
        .id = 0, .file = 0, .name = "x", .kind = .constant, .line = 1,
        .span_start = 0, .span_end = 12, .sig_end = 12, .doc = "",
        .parent = invalid_symbol, .exported = false, .refs = &.{},
    };
    try std.testing.expectEqual(@as(u32, 1), sym.endLine(src));
}


// ---------------------------------------------------------------------------
// Appended tests for src/model.zig
// ---------------------------------------------------------------------------

/// Build a Symbol with sensible defaults; override only the fields a test cares
/// about. Keeps the many span/endLine tests readable.
fn mkSymForTest(
    name: []const u8,
    kind: SymbolKind,
    line: u32,
    span_start: u32,
    sig_end: u32,
    span_end: u32,
) Symbol {
    return Symbol{
        .id = 0,
        .file = 0,
        .name = name,
        .kind = kind,
        .line = line,
        .span_start = span_start,
        .span_end = span_end,
        .sig_end = sig_end,
        .doc = "",
        .parent = invalid_symbol,
        .exported = false,
        .refs = &.{},
    };
}

test "SymbolKind.validName accepts every tag and alias, rejects typos" {
    inline for (@typeInfo(SymbolKind).@"enum".fields) |f| {
        try std.testing.expect(SymbolKind.validName(@field(SymbolKind, f.name).tag()));
    }
    try std.testing.expect(SymbolKind.validName("function"));
    try std.testing.expect(SymbolKind.validName("func"));
    try std.testing.expect(SymbolKind.validName("variable"));
    try std.testing.expect(!SymbolKind.validName("xyz123"));
    try std.testing.expect(!SymbolKind.validName("fns"));
}

test "SymbolKind.tag returns the exact short tag for every kind" {
    try std.testing.expectEqualStrings("fn", SymbolKind.function.tag());
    try std.testing.expectEqualStrings("method", SymbolKind.method.tag());
    try std.testing.expectEqualStrings("class", SymbolKind.class.tag());
    try std.testing.expectEqualStrings("struct", SymbolKind.@"struct".tag());
    try std.testing.expectEqualStrings("enum", SymbolKind.@"enum".tag());
    try std.testing.expectEqualStrings("iface", SymbolKind.interface.tag());
    try std.testing.expectEqualStrings("type", SymbolKind.type.tag());
    try std.testing.expectEqualStrings("var", SymbolKind.variable.tag());
    try std.testing.expectEqualStrings("const", SymbolKind.constant.tag());
    try std.testing.expectEqualStrings("field", SymbolKind.field.tag());
    try std.testing.expectEqualStrings("macro", SymbolKind.macro.tag());
    try std.testing.expectEqualStrings("mod", SymbolKind.module.tag());
    try std.testing.expectEqualStrings("import", SymbolKind.import.tag());
    try std.testing.expectEqualStrings("route", SymbolKind.route.tag());
    try std.testing.expectEqualStrings("sym", SymbolKind.unknown.tag());
}

test "SymbolKind.tag is unique across every kind" {
    // Enumerate the whole enum so an added kind without a tag is caught.
    var seen: usize = 0;
    inline for (@typeInfo(SymbolKind).@"enum".fields) |f| {
        const kind = @field(SymbolKind, f.name);
        const t = kind.tag();
        try std.testing.expect(t.len > 0);
        // Every subsequent tag must differ from all earlier ones.
        inline for (@typeInfo(SymbolKind).@"enum".fields) |g| {
            const other = @field(SymbolKind, g.name);
            if (@intFromEnum(other) < @intFromEnum(kind)) {
                try std.testing.expect(!std.mem.eql(u8, t, other.tag()));
            }
        }
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 17), seen);
}

test "isTopLevelInteresting is false only for import, field and unknown" {
    // The three uninteresting kinds.
    try std.testing.expect(!SymbolKind.import.isTopLevelInteresting());
    try std.testing.expect(!SymbolKind.field.isTopLevelInteresting());
    try std.testing.expect(!SymbolKind.unknown.isTopLevelInteresting());
    try std.testing.expect(!SymbolKind.route_mount.isTopLevelInteresting());
    // Everything else is interesting.
    try std.testing.expect(SymbolKind.function.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.method.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.class.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.@"struct".isTopLevelInteresting());
    try std.testing.expect(SymbolKind.@"enum".isTopLevelInteresting());
    try std.testing.expect(SymbolKind.interface.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.type.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.variable.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.constant.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.macro.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.module.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.route.isTopLevelInteresting());
    try std.testing.expect(SymbolKind.test_case.isTopLevelInteresting());
}

test "isTopLevelInteresting count matches expectation across all kinds" {
    var interesting: usize = 0;
    var boring: usize = 0;
    inline for (@typeInfo(SymbolKind).@"enum".fields) |f| {
        if (@field(SymbolKind, f.name).isTopLevelInteresting()) {
            interesting += 1;
        } else {
            boring += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), boring);
    try std.testing.expectEqual(@as(usize, 13), interesting);
}

test "Mods.any is false for the empty modifier set" {
    const none = Mods{};
    try std.testing.expect(!none.any());
}

test "Mods.any is true when any single modifier is set" {
    try std.testing.expect((Mods{ .is_static = true }).any());
    try std.testing.expect((Mods{ .is_async = true }).any());
    try std.testing.expect((Mods{ .getter = true }).any());
    try std.testing.expect((Mods{ .setter = true }).any());
    try std.testing.expect((Mods{ .classmethod = true }).any());
    try std.testing.expect((Mods{ .abstract = true }).any());
}

test "Mods.any is true when several modifiers are set together" {
    const m = Mods{ .is_static = true, .is_async = true, .abstract = true };
    try std.testing.expect(m.any());
    // Round-trips through the single serialized byte.
    const byte: u8 = @bitCast(m);
    try std.testing.expect(byte != 0);
    const back: Mods = @bitCast(byte);
    try std.testing.expect(back.any());
    try std.testing.expect(back.is_static and back.is_async and back.abstract);
    try std.testing.expect(!back.getter and !back.setter and !back.classmethod);
}

test "signature trims surrounding whitespace and stops at sig_end" {
    const src = "   pub fn f() void {\n    return;\n}\n";
    // span_start 0, sig_end at the byte after "void" region including trailing
    // space before '{' — trimming must strip the leading/trailing whitespace.
    const sig_end: u32 = @intCast(std.mem.indexOf(u8, src, "{").?);
    const sym = mkSymForTest("f", .function, 1, 0, sig_end, @intCast(src.len));
    try std.testing.expectEqualStrings("pub fn f() void", sym.signature(src));
}

test "signature of a degenerate (empty) span is the empty string" {
    const src = "abcdef";
    // span_start == sig_end == span_end : nothing to slice.
    const sym = mkSymForTest("x", .constant, 1, 3, 3, 3);
    try std.testing.expectEqualStrings("", sym.signature(src));
    try std.testing.expectEqualStrings("", sym.body(src));
}

test "signature of a whitespace-only slice trims to empty" {
    const src = "  \t \n stuff";
    const sym = mkSymForTest("y", .variable, 1, 0, 5, 5);
    try std.testing.expectEqualStrings("", sym.signature(src));
}

test "body returns the full definition slice for a multi-line symbol" {
    const src = "pub fn add(a: i32) i32 {\n    return a;\n}\ntrailer";
    const span_end: u32 = @intCast(std.mem.indexOf(u8, src, "\ntrailer").? + 1);
    const sym = mkSymForTest("add", .function, 1, 0, 23, span_end);
    try std.testing.expectEqualStrings("pub fn add(a: i32) i32 {\n    return a;\n}\n", sym.body(src));
    // signature is a strict prefix of the body region.
    try std.testing.expectEqualStrings("pub fn add(a: i32) i32", sym.signature(src));
}

test "body of a sub-slice starting mid-source is exact" {
    const src = "xxfn g() {}yy";
    const start: u32 = 2;
    const end: u32 = @intCast(src.len - 2);
    const sym = mkSymForTest("g", .function, 1, start, end, end);
    try std.testing.expectEqualStrings("fn g() {}", sym.body(src));
}

test "endLine of a multi-line definition is the line of the last real byte" {
    const src = "fn f() {\n    a();\n    b();\n}\n";
    const sym = mkSymForTest("f", .function, 1, 0, 8, @intCast(src.len));
    // '}' sits on line 4; trailing newline must not push it to line 5.
    try std.testing.expectEqual(@as(u32, 4), sym.endLine(src));
}

test "endLine ignores a single-line span even with a trailing newline" {
    const src = "fn f() {}\n";
    const sym = mkSymForTest("f", .function, 1, 0, 9, @intCast(src.len));
    try std.testing.expectEqual(@as(u32, 1), sym.endLine(src));
}

test "endLine for a C-style leading prefix span that begins before the name line" {
    // A `template <...>` prefix makes span_start begin on line 1 while the name
    // ('makeVec') lives on line 2; endLine is computed absolutely.
    const src =
        "std::vector<int>\n" ++ // line 1 (prefix / return type)
        "makeVec() {\n" ++ // line 2 (name)
        "    return {};\n" ++ // line 3
        "}\n"; // line 4
    const sym = mkSymForTest("makeVec", .function, 2, 0, @intCast(std.mem.indexOf(u8, src, "{").? + 1), @intCast(src.len));
    try std.testing.expectEqual(@as(u32, 4), sym.endLine(src));
}

test "endLine never reports a line before the definition's own name line" {
    // Degenerate: the span's last real byte lands on line 1, but the recorded
    // name line is 3 — the @max clamp must win.
    const src = "a\nb\nc\nd\n";
    const sym = mkSymForTest("clamp", .function, 3, 0, 2, 2);
    try std.testing.expectEqual(@as(u32, 3), sym.endLine(src));
}

test "endLine returns the name line when the trimmed span collapses to zero" {
    // span is only newlines: after trimming, end == 0 -> falls back to self.line.
    const src = "\n\n\nrest";
    const sym = mkSymForTest("blank", .function, 5, 0, 3, 3);
    try std.testing.expectEqual(@as(u32, 5), sym.endLine(src));
}

test "endLine trims a run of trailing CR and LF bytes" {
    const src = "x = 1;\r\n\r\n";
    const sym = mkSymForTest("x", .constant, 1, 0, 6, @intCast(src.len));
    // Last real byte ';' is on line 1 despite the trailing CRLF run.
    try std.testing.expectEqual(@as(u32, 1), sym.endLine(src));
}

test "Graph.fileOf, symbol and sourceOf resolve via sym.file, not id" {
    var files = [_]SourceFile{
        .{ .id = 0, .path = "a.zig", .language = language.Language.zig, .text = "text-of-file-0", .sym_start = 0, .sym_end = 1 },
        .{ .id = 1, .path = "b.zig", .language = language.Language.zig, .text = "text-of-file-1", .sym_start = 1, .sym_end = 2 },
    };
    // Cross the mapping deliberately: symbol id 0 lives in file 1, id 1 in file 0.
    var symbols = [_]Symbol{
        mkSymForTest("s0", .function, 1, 0, 0, 0),
        mkSymForTest("s1", .constant, 1, 0, 0, 0),
    };
    symbols[0].id = 0;
    symbols[0].file = 1;
    symbols[1].id = 1;
    symbols[1].file = 0;

    var graph = Graph{ .files = &files, .symbols = &symbols };

    // symbol(id) indexes by id.
    try std.testing.expectEqualStrings("s0", graph.symbol(0).name);
    try std.testing.expectEqualStrings("s1", graph.symbol(1).name);

    // fileOf maps through sym.file.
    try std.testing.expectEqualStrings("b.zig", graph.fileOf(symbols[0]).path);
    try std.testing.expectEqualStrings("a.zig", graph.fileOf(symbols[1]).path);

    // sourceOf(id) returns the text of the symbol's file (id vs file crossed).
    try std.testing.expectEqualStrings("text-of-file-1", graph.sourceOf(0));
    try std.testing.expectEqualStrings("text-of-file-0", graph.sourceOf(1));
}

test "Graph.fileOf returns a pointer to the live file entry" {
    var files = [_]SourceFile{
        .{ .id = 0, .path = "only.zig", .language = language.Language.zig, .text = "src", .sym_start = 0, .sym_end = 1 },
    };
    var symbols = [_]Symbol{mkSymForTest("only", .function, 1, 0, 0, 0)};
    var graph = Graph{ .files = &files, .symbols = &symbols };
    const fp = graph.fileOf(symbols[0]);
    // Identity: same address as the underlying files array element.
    try std.testing.expectEqual(&files[0], fp);
    try std.testing.expectEqual(language.Language.zig, fp.language);
}
