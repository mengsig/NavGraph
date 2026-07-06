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
    unknown,

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
            .unknown => "sym",
        };
    }

    /// Symbols an agent typically wants as top-level outline entries.
    pub fn isTopLevelInteresting(self: SymbolKind) bool {
        return switch (self) {
            .import, .field, .unknown => false,
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

/// A use of some name inside a symbol's body. `target` is filled during
/// resolution (`invalid_symbol` when unresolved / external).
pub const Reference = struct {
    name: []const u8,
    /// First line (1-based) where this name is referenced in the body.
    line: u32,
    kind: RefKind,
    /// Number of times this name is referenced within the owning symbol's body.
    count: u32 = 1,
    target: SymbolId = invalid_symbol,
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
    /// Outgoing references collected from the body.
    refs: []Reference,

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
}
