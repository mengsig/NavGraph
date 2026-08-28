//! Compressed, token-frugal rendering of symbols to an `Io.Writer`.
//!
//! The output is designed to be read by an agent: dense, one line per symbol at
//! low verbosity, with signatures collapsed to a single line and locations as
//! `path:line`. Higher verbosity adds docs, then full source.

const std = @import("std");
const model = @import("model.zig");
const index_mod = @import("index.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const Symbol = model.Symbol;

pub const Verbosity = enum {
    /// kind + name only.
    names,
    /// kind + collapsed signature (default).
    sig,
    /// signature + first doc line.
    doc,
    /// full source of the definition.
    full,

    pub fn parse(s: []const u8) ?Verbosity {
        const map = .{
            .{ "names", Verbosity.names }, .{ "name", Verbosity.names },
            .{ "sig", Verbosity.sig },     .{ "signature", Verbosity.sig },
            .{ "doc", Verbosity.doc },     .{ "docs", Verbosity.doc },
            .{ "full", Verbosity.full },   .{ "body", Verbosity.full },
        };
        inline for (map) |e| if (std.mem.eql(u8, s, e[0])) return e[1];
        return null;
    }
};

const max_sig_len: usize = 160;
/// Cap for const/var initializer values in `sig` view — short enough that a big
/// comptime literal collapses to its type/constructor head instead of dumping.
const max_value_len: usize = 60;

/// Render one symbol as an indented line (or block, for `.full`).
pub fn symbol(
    w: *Writer,
    idx: *const Index,
    sym: Symbol,
    v: Verbosity,
    indent: usize,
    show_path: bool,
) !void {
    return symbolSite(w, idx, sym, v, indent, show_path, 0, 1, &.{}, true);
}

/// Like `symbol`, but annotates the line with the call-site `site` (the source
/// line of the graph edge connecting this node to its parent in a call tree).
/// `site == 0` means no edge (a root, or a plain listing) and renders like
/// `symbol`. The annotation is `↳:N` — N lives in the file of whichever endpoint
/// is the *caller* (this row in a callers tree; the parent row in a callees tree).
pub fn symbolSite(
    w: *Writer,
    idx: *const Index,
    sym: Symbol,
    v: Verbosity,
    indent: usize,
    show_path: bool,
    site: u32,
    /// Number of call sites this edge represents; `↳:N ×C` is shown when C > 1 so
    /// a caller that invokes the target repeatedly isn't undercounted as one.
    sites: u32,
    /// The distinct call-site lines of this edge, when it spans more than one
    /// line (empty = single site → fall back to `site`). Rendered as
    /// `↳:l1,l2,l3` so every call site is visible, not just the first.
    lines: []const u32,
    /// False marks a heuristic (name-match) edge to this node, rendered with a
    /// trailing `?`; true (the default for roots and exact edges) renders plain.
    exact: bool,
) !void {
    try writeIndent(w, indent);
    try writeKind(w, sym);
    try writeQualifiedName(w, idx, sym);

    const source = idx.graph.files[sym.file].text;
    switch (v) {
        .names => {},
        .sig, .doc => try writeSigSuffix(w, idx, sym, source),
        .full => {},
    }
    try writeLocation(w, idx, sym, source, show_path);
    if (site != 0) {
        if (lines.len > 1) {
            try writeSiteLines(w, lines);
            // Show the total count only when it exceeds the distinct lines shown
            // (same-line repeats): the line list already conveys the rest.
            if (sites > lines.len) try w.print(" ×{d}", .{sites});
        } else {
            try w.print("  ↳:{d}", .{site});
            if (sites > 1) try w.print(" ×{d}", .{sites});
        }
        if (!exact) try w.writeAll(" ?");
    }
    try w.writeByte('\n');

    if (v == .doc) try writeDocLine(w, sym, indent);
    if (v == .full) try writeFullBody(w, sym, source, indent);
}

/// Render a multi-site edge's call-site lines as `  ↳:l1,l2,l3`, capping the
/// list so a heavily-repeated call doesn't flood the row; the remainder is
/// summarized as `,+N`.
fn writeSiteLines(w: *Writer, lines: []const u32) !void {
    const cap = 6;
    const shown = @min(lines.len, cap);
    try w.writeAll("  ↳:");
    for (lines[0..shown], 0..) |ln, k| {
        if (k != 0) try w.writeByte(',');
        try w.print("{d}", .{ln});
    }
    if (lines.len > shown) try w.print(",+{d}", .{lines.len - shown});
}

fn writeIndent(w: *Writer, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) try w.writeAll("  ");
}

/// Write the leading `[modifiers ]<tag> ` field for a symbol. Modifiers surface
/// accessor/dispatch/async-ness (`async fn run`, `static get x`, `classmethod
/// method of`) so an agent isn't misled into reading a getter as a plain method
/// — the false-bug-report a trial hit on `_field`. Accessors replace the tag
/// with `get`/`set`; other modifiers prefix it. `kind` is untouched, so `-k`
/// filtering and the JSON `kind` stay stable.
fn writeKind(w: *Writer, sym: Symbol) !void {
    const m = sym.modifiers;
    if (m.is_static) try w.writeAll("static ");
    if (m.classmethod) try w.writeAll("classmethod ");
    if (m.abstract) try w.writeAll("abstract ");
    if (m.is_async) try w.writeAll("async ");
    if (m.getter) {
        try w.writeAll("get");
    } else if (m.setter) {
        try w.writeAll("set");
    } else {
        try w.writeAll(sym.kind.tag());
    }
    try w.writeByte(' ');
}

fn writeQualifiedName(w: *Writer, idx: *const Index, sym: Symbol) !void {
    if (sym.parent != model.invalid_symbol) {
        const parent = idx.graph.symbols[sym.parent];
        try w.writeAll(parent.name);
        try w.writeByte('.');
    }
    try w.writeAll(sym.name);
}

/// Append the collapsed signature after the name, minus the redundant name/kind.
fn writeSigSuffix(w: *Writer, idx: *const Index, sym: Symbol, source: []const u8) !void {
    const is_value = switch (sym.kind) {
        .function, .method => false,
        // Containers show their inheritance clause (`class Group(Command)`,
        // `class Foo extends Bar`, `struct X : Y`) — the one hierarchy fact an
        // "explain these classes" task otherwise needs a read per class for.
        .class, .@"struct", .interface => return writeBaseClause(w, sym, source),
        .@"enum", .import, .macro, .module, .test_case => return,
        else => true,
    };
    const suffix = if (is_value)
        valueSlice(sym.signature(source), sym.name)
    else
        paramSlice(sym.signature(source));
    if (suffix.len == 0) return;
    try w.writeByte(' ');
    // A const/var initializer (comptime map, keyword set, big array) is noise
    // when you only want the shape, so values get a much shorter cap than a
    // function signature — enough to show the type/constructor head, not the
    // whole literal. `outline -v full` still shows the complete definition.
    const cap: usize = if (is_value) max_value_len else max_sig_len;
    try writeCollapsed(w, suffix, cap);
    // Java declares the return type before the method name. Keeping only the
    // parameter suffix silently erased it from the compact view — exactly the
    // view an agent uses to compare APIs without opening every definition.
    if (!is_value and idx.graph.files[sym.file].language == .java) {
        const return_type = javaReturnType(sym.signature(source), sym.name);
        if (return_type.len != 0) {
            try w.writeAll(" -> ");
            try writeCollapsed(w, return_type, max_sig_len);
        }
    }
}

/// Print a container's inheritance clause: the signature text after the name,
/// minus declaration punctuation (`{`, `:` line-end) and bodyless noise. Yields
/// `(Command)` for Python, `extends Bar implements Baz` for JS/TS, `: IBar`
/// for C++/C#, `< Base` for Ruby — and nothing for a bare `struct {`.
fn writeBaseClause(w: *Writer, sym: Symbol, source: []const u8) !void {
    const sig = sym.signature(source);
    const n = std.mem.indexOf(u8, sig, sym.name) orelse return;
    var rest = sig[n + sym.name.len ..];
    // Generic params belong to the name, not the base clause: `class Foo<T> …`.
    if (rest.len != 0 and (rest[0] == '<' or rest[0] == '[')) {
        const closer: u8 = if (rest[0] == '<') '>' else ']';
        if (std.mem.indexOfScalar(u8, rest, closer)) |c| rest = rest[c + 1 ..];
    }
    rest = std.mem.trim(u8, rest, " \t\r\n");
    while (rest.len != 0 and (rest[rest.len - 1] == '{' or rest[rest.len - 1] == ':')) {
        rest = std.mem.trimEnd(u8, rest[0 .. rest.len - 1], " \t\r\n");
    }
    // Nothing left, or only the declaration keyword (`= struct`, `interface`):
    // no base clause to show.
    inline for (.{ "", "=", "= struct", "= enum", "= union", "= opaque", "struct", "interface", "class", "object" }) |noise| {
        if (std.mem.eql(u8, rest, noise)) return;
    }
    try w.writeByte(' ');
    try writeCollapsed(w, rest, 80);
}

/// The parameter/return portion of a function signature (from the first `(`).
fn paramSlice(sig: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, sig, '(')) |p| return sig[p..];
    return "";
}

/// Extract Java's leading return type from a method declaration. Constructors
/// naturally return empty because stripping their modifiers leaves no text
/// before the declaration name. Generic method parameters are declaration
/// metadata rather than part of the return type and are skipped as a balanced
/// `<...>` prefix.
fn javaReturnType(sig: []const u8, name: []const u8) []const u8 {
    var search_from: usize = 0;
    var name_at: ?usize = null;
    while (std.mem.indexOfPos(u8, sig, search_from, name)) |at| {
        const after = std.mem.trimStart(u8, sig[at + name.len ..], " \t\r\n");
        if (after.len != 0 and after[0] == '(') name_at = at;
        search_from = at + name.len;
    }
    var prefix = std.mem.trim(u8, sig[0 .. name_at orelse return ""], " \t\r\n");

    // Declaration annotations may be included in a symbol's source span. Drop
    // complete leading annotation lines; type-use annotations after modifiers
    // remain visible as part of the return type.
    while (prefix.len != 0 and prefix[0] == '@') {
        const newline = std.mem.indexOfScalar(u8, prefix, '\n') orelse break;
        prefix = std.mem.trimStart(u8, prefix[newline + 1 ..], " \t\r\n");
    }

    const modifiers = [_][]const u8{
        "public",       "protected", "private",  "static",  "final",     "abstract",
        "synchronized", "native",    "strictfp", "default", "transient",
    };
    while (prefix.len != 0) {
        const word_end = std.mem.indexOfAny(u8, prefix, " \t\r\n") orelse prefix.len;
        const word = prefix[0..word_end];
        var is_modifier = false;
        for (modifiers) |modifier| {
            if (std.mem.eql(u8, word, modifier)) {
                is_modifier = true;
                break;
            }
        }
        if (!is_modifier) break;
        prefix = std.mem.trimStart(u8, prefix[word_end..], " \t\r\n");
    }

    if (prefix.len != 0 and prefix[0] == '<') {
        var depth: usize = 0;
        for (prefix, 0..) |c, i| {
            if (c == '<') depth += 1;
            if (c == '>') {
                depth -= 1;
                if (depth == 0) {
                    prefix = std.mem.trimStart(u8, prefix[i + 1 ..], " \t\r\n");
                    break;
                }
            }
        }
    }
    return prefix;
}

/// For a const/var/type, the value/type portion after the name.
fn valueSlice(sig: []const u8, name: []const u8) []const u8 {
    const n = std.mem.indexOf(u8, sig, name) orelse return "";
    var rest = std.mem.trim(u8, sig[n + name.len ..], " \t\r\n:=;");
    if (rest.len != 0 and rest[rest.len - 1] == ';') rest = rest[0 .. rest.len - 1];
    return rest;
}

fn writeLocation(w: *Writer, idx: *const Index, sym: Symbol, source: []const u8, show_path: bool) !void {
    try w.writeAll("  ");
    if (show_path) {
        try w.writeAll(idx.graph.files[sym.file].path);
        try w.writeByte(':');
    } else {
        try w.writeByte('L');
    }
    // A line range (`start-end`) lets a reader open exactly the definition; a
    // single-line symbol stays a bare line number.
    const end = sym.endLine(source);
    try w.print("{d}", .{sym.line});
    if (end > sym.line) try w.print("-{d}", .{end});
}

/// Collapse runs of whitespace to single spaces, capping length with an ellipsis.
/// The (1-based) `line_no`-th line of `text`, or "" when out of range. Linear
/// scan — callers print at most a few hundred rows per query.
pub fn sourceLine(text: []const u8, line_no: u32) []const u8 {
    if (line_no == 0) return "";
    var rest = text;
    var n: u32 = 1;
    while (n < line_no) : (n += 1) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return "";
        rest = rest[nl + 1 ..];
    }
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return std.mem.trim(u8, rest[0..end], " \t\r");
}

pub fn writeCollapsed(w: *Writer, text: []const u8, cap: usize) !void {
    var written: usize = 0;
    var prev_space = false;
    for (text) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n';
        if (is_space) {
            if (prev_space or written == 0) continue;
            prev_space = true;
            continue;
        }
        if (prev_space) {
            try w.writeByte(' ');
            written += 1;
            prev_space = false;
        }
        if (written >= cap) {
            try w.writeAll("…");
            return;
        }
        try w.writeByte(c);
        written += 1;
    }
}

fn writeDocLine(w: *Writer, sym: Symbol, indent: usize) !void {
    const stripped = stripDoc(sym.doc);
    const line = firstLine(stripped);
    if (line.len == 0) return;
    try writeIndent(w, indent + 1);
    try w.writeAll("» ");
    try writeCollapsed(w, line, 200);
    try w.writeByte('\n');
}

fn writeFullBody(w: *Writer, sym: Symbol, source: []const u8, indent: usize) !void {
    _ = indent;
    // Include any leading `@decorator` / attribute lines so `-v full` is a
    // complete, paste-ready Edit target — a Python `@property`/FastAPI handler
    // carries its decorators, a TS `@Component` its annotation. The parser
    // deliberately excludes these from the span (to keep `line`/`endLine` on the
    // definition itself), so widen the printed slice here.
    const start = decoratorStart(source, sym.span_start);
    try w.writeAll(source[start..sym.span_end]);
    try w.writeByte('\n');
}

/// Walk upward from `span_start` over a contiguous run of decorator/attribute
/// lines (a line whose first non-blank byte is `@`), returning the offset where
/// the definition-with-decorators begins. A blank or non-decorator line stops
/// the run.
fn decoratorStart(source: []const u8, span_start: u32) u32 {
    var start = span_start;
    while (start > 0 and source[start - 1] != '\n') start -= 1; // start of span's own line
    while (start > 0) {
        const prev_nl = start - 1; // the '\n' terminating the previous line
        var ls = prev_nl;
        while (ls > 0 and source[ls - 1] != '\n') ls -= 1; // start of previous line
        var i = ls;
        while (i < prev_nl and (source[i] == ' ' or source[i] == '\t')) i += 1;
        if (i < prev_nl and source[i] == '@') start = ls else break;
    }
    return start;
}

/// Strip leading comment/docstring markers from a raw doc slice.
pub fn stripDoc(doc: []const u8) []const u8 {
    var s = std.mem.trim(u8, doc, " \t\r\n");
    if (std.mem.startsWith(u8, s, "\"\"\"")) s = std.mem.trim(u8, s, "\"");
    if (std.mem.startsWith(u8, s, "'''")) s = std.mem.trim(u8, s, "'");
    if (std.mem.startsWith(u8, s, "/**")) s = std.mem.trim(u8, s[3..], " \t\r\n*/");
    return s;
}

fn firstLine(s: []const u8) []const u8 {
    var line = s;
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| line = s[0..nl];
    // Drop a leading `///`, `//`, `#`, `*` marker.
    line = std.mem.trimStart(u8, line, "/#* \t");
    return std.mem.trim(u8, line, " \t\r");
}

// ---------------------------------------------------------------------------
// Appended tests for render.zig
// ---------------------------------------------------------------------------

/// A minimal stub Symbol carrying only the fields a given render helper reads
/// (kind + modifiers for `writeKind`, parent/name for `writeQualifiedName`).
fn stubSym(kind: model.SymbolKind, mods: model.Mods) Symbol {
    return .{
        .id = 0,
        .file = 0,
        .name = "x",
        .kind = kind,
        .line = 1,
        .span_start = 0,
        .span_end = 0,
        .sig_end = 0,
        .doc = "",
        .parent = model.invalid_symbol,
        .exported = false,
        .modifiers = mods,
        .refs = @constCast(&[_]model.Reference{}),
    };
}

fn renderKindStr(sym: Symbol) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeKind(&aw.writer, sym);
    return try aw.toOwnedSlice();
}

fn renderCollapsedStr(text: []const u8, cap: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeCollapsed(&aw.writer, text, cap);
    return try aw.toOwnedSlice();
}

fn renderSiteLinesStr(lines: []const u32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSiteLines(&aw.writer, lines);
    return try aw.toOwnedSlice();
}

fn renderIndentStr(indent: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeIndent(&aw.writer, indent);
    return try aw.toOwnedSlice();
}

/// Render a looked-up symbol via the public `symbol` entry point.
fn renderByName(idx: *const Index, name: []const u8, v: Verbosity, show_path: bool) ![]u8 {
    const id = idx.lookup(name)[0];
    const sym = idx.graph.symbols[id];
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try symbol(&aw.writer, idx, sym, v, 0, show_path);
    return try aw.toOwnedSlice();
}

// --- Verbosity.parse ------------------------------------------------------

test "Verbosity.parse accepts every alias and rejects the unknown" {
    const t = std.testing;
    try t.expectEqual(Verbosity.names, Verbosity.parse("names").?);
    try t.expectEqual(Verbosity.names, Verbosity.parse("name").?);
    try t.expectEqual(Verbosity.sig, Verbosity.parse("sig").?);
    try t.expectEqual(Verbosity.sig, Verbosity.parse("signature").?);
    try t.expectEqual(Verbosity.doc, Verbosity.parse("doc").?);
    try t.expectEqual(Verbosity.doc, Verbosity.parse("docs").?);
    try t.expectEqual(Verbosity.full, Verbosity.parse("full").?);
    try t.expectEqual(Verbosity.full, Verbosity.parse("body").?);
    // Unknown / empty / case-sensitive-miss all return null.
    try t.expect(Verbosity.parse("nope") == null);
    try t.expect(Verbosity.parse("") == null);
    try t.expect(Verbosity.parse("Names") == null);
    try t.expect(Verbosity.parse("sig ") == null);
}

// --- writeKind: every SymbolKind tag --------------------------------------

test "writeKind emits the canonical tag for every SymbolKind" {
    const t = std.testing;
    // writeKind writes only the `<tag> ` field (the name is written separately).
    const cases = .{
        .{ model.SymbolKind.function, "fn " },
        .{ model.SymbolKind.method, "method " },
        .{ model.SymbolKind.class, "class " },
        .{ model.SymbolKind.@"struct", "struct " },
        .{ model.SymbolKind.@"enum", "enum " },
        .{ model.SymbolKind.interface, "iface " },
        .{ model.SymbolKind.type, "type " },
        .{ model.SymbolKind.variable, "var " },
        .{ model.SymbolKind.constant, "const " },
        .{ model.SymbolKind.field, "field " },
        .{ model.SymbolKind.macro, "macro " },
        .{ model.SymbolKind.module, "mod " },
        .{ model.SymbolKind.import, "import " },
        .{ model.SymbolKind.route, "route " },
        .{ model.SymbolKind.unknown, "sym " },
    };
    inline for (cases) |c| {
        const s = try renderKindStr(stubSym(c[0], .{}));
        defer t.allocator.free(s);
        try t.expectEqualStrings(c[1], s);
    }
}

test "writeKind prefixes dispatch/async modifiers before the tag" {
    const t = std.testing;
    {
        const s = try renderKindStr(stubSym(.function, .{ .is_async = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("async fn ", s);
    }
    {
        const s = try renderKindStr(stubSym(.method, .{ .is_static = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("static method ", s);
    }
    {
        const s = try renderKindStr(stubSym(.method, .{ .classmethod = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("classmethod method ", s);
    }
    {
        const s = try renderKindStr(stubSym(.method, .{ .abstract = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("abstract method ", s);
    }
    {
        // Modifier ordering: static, classmethod, abstract, async all stack.
        const s = try renderKindStr(stubSym(.method, .{ .is_static = true, .is_async = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("static async method ", s);
    }
}

test "writeKind replaces the tag with get/set for accessors" {
    const t = std.testing;
    {
        const s = try renderKindStr(stubSym(.method, .{ .getter = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("get ", s);
    }
    {
        const s = try renderKindStr(stubSym(.method, .{ .setter = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("set ", s);
    }
    {
        // getter wins over setter (getter branch checked first) and combines
        // with a leading dispatch modifier.
        const s = try renderKindStr(stubSym(.method, .{ .is_static = true, .getter = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("static get ", s);
    }
    {
        const s = try renderKindStr(stubSym(.method, .{ .is_async = true, .setter = true }));
        defer t.allocator.free(s);
        try t.expectEqualStrings("async set ", s);
    }
}

// --- writeCollapsed -------------------------------------------------------

test "writeCollapsed squashes whitespace and trims the ends" {
    const t = std.testing;
    {
        const s = try renderCollapsedStr("  a   b\t\tc\n\nd  ", 100);
        defer t.allocator.free(s);
        try t.expectEqualStrings("a b c d", s);
    }
    {
        // No internal whitespace, nothing to trim.
        const s = try renderCollapsedStr("hello", 100);
        defer t.allocator.free(s);
        try t.expectEqualStrings("hello", s);
    }
    {
        // All whitespace collapses to nothing.
        const s = try renderCollapsedStr("   \t\n  ", 100);
        defer t.allocator.free(s);
        try t.expectEqualStrings("", s);
    }
    {
        // Empty input.
        const s = try renderCollapsedStr("", 100);
        defer t.allocator.free(s);
        try t.expectEqualStrings("", s);
    }
}

test "writeCollapsed appends the ellipsis exactly when the cap is exceeded" {
    const t = std.testing;
    {
        // Length equal to cap: no ellipsis.
        const s = try renderCollapsedStr("abcde", 5);
        defer t.allocator.free(s);
        try t.expectEqualStrings("abcde", s);
    }
    {
        // Length exceeds cap by one: first over-cap char becomes the ellipsis.
        const s = try renderCollapsedStr("abcdef", 5);
        defer t.allocator.free(s);
        try t.expectEqualStrings("abcde\u{2026}", s);
    }
    {
        // cap 0: any real content collapses to just the ellipsis.
        const s = try renderCollapsedStr("abc", 0);
        defer t.allocator.free(s);
        try t.expectEqualStrings("\u{2026}", s);
    }
    {
        // cap 0 with only whitespace: nothing written (never reaches a char).
        const s = try renderCollapsedStr("   ", 0);
        defer t.allocator.free(s);
        try t.expectEqualStrings("", s);
    }
    {
        // The collapsed space is emitted before the cap check, so the third
        // gap ("a b ") is written and the over-cap `c` becomes the ellipsis.
        const s = try renderCollapsedStr("a   b   c", 3);
        defer t.allocator.free(s);
        try t.expectEqualStrings("a b \u{2026}", s);
    }
}

// --- paramSlice / valueSlice ---------------------------------------------

test "paramSlice returns from the first paren, else empty" {
    const t = std.testing;
    try t.expectEqualStrings("(x: i32) void", paramSlice("fn f(x: i32) void"));
    try t.expectEqualStrings("()", paramSlice("()"));
    try t.expectEqualStrings("", paramSlice("no parens here"));
    try t.expectEqualStrings("", paramSlice(""));
    // Only the first paren matters.
    try t.expectEqualStrings("(a)(b)", paramSlice("g(a)(b)"));
}

test "javaReturnType preserves declared and generic return types but not constructors" {
    const t = std.testing;
    try t.expectEqualStrings("String", javaReturnType("public static String format(int cents)", "format"));
    try t.expectEqualStrings(
        "Map<String, T>",
        javaReturnType("protected final <T extends Number> Map<String, T> collect(T item)", "collect"),
    );
    try t.expectEqualStrings("void", javaReturnType("synchronized void flush()", "flush"));
    try t.expectEqualStrings("", javaReturnType("private Money(int cents)", "Money"));
    try t.expectEqualStrings("String", javaReturnType("@Override\npublic String label()", "label"));
    try t.expectEqualStrings("", javaReturnType("public String label()", "missing"));
}

test "valueSlice extracts the value after the name, trimming separators" {
    const t = std.testing;
    try t.expectEqualStrings("5", valueSlice("const X = 5;", "X"));
    try t.expectEqualStrings("5", valueSlice("const X = 5", "X"));
    try t.expectEqualStrings("u32", valueSlice("MyType: u32", "MyType"));
    // A leading `:`/`=`/whitespace run is stripped from the front.
    try t.expectEqualStrings("u32 = 10", valueSlice("pub const LIMIT: u32 = 10;", "LIMIT"));
    // Name not present -> empty.
    try t.expectEqualStrings("", valueSlice("const X = 5;", "Z"));
    // Nothing after the name -> empty.
    try t.expectEqualStrings("", valueSlice("something X", "X"));
}

// --- stripDoc / firstLine -------------------------------------------------

test "stripDoc removes triple-quote and block-comment markers" {
    const t = std.testing;
    try t.expectEqualStrings("doc", stripDoc("\"\"\"doc\"\"\""));
    try t.expectEqualStrings("doc", stripDoc("'''doc'''"));
    try t.expectEqualStrings("doc", stripDoc("/** doc */"));
    // Plain text and surrounding whitespace.
    try t.expectEqualStrings("hello world", stripDoc("   hello world   "));
    // Leading whitespace trimmed before marker detection.
    try t.expectEqualStrings("doc", stripDoc("  \"\"\"doc\"\"\"  "));
}

test "firstLine takes the first line and drops its comment marker" {
    const t = std.testing;
    try t.expectEqualStrings("hello", firstLine("/// hello\nworld"));
    try t.expectEqualStrings("comment", firstLine("# comment"));
    try t.expectEqualStrings("bullet", firstLine("* bullet"));
    try t.expectEqualStrings("plain", firstLine("plain"));
    // Trailing CR is trimmed.
    try t.expectEqualStrings("crlf", firstLine("// crlf\r\nnext"));
    // Empty -> empty.
    try t.expectEqualStrings("", firstLine(""));
}

// --- decoratorStart -------------------------------------------------------

test "decoratorStart widens over a contiguous decorator run and stops at blanks" {
    const t = std.testing;
    {
        // No decorator: first line of file -> offset 0 (start of def's own line).
        const src = "def f():\n    pass\n";
        const at: u32 = @intCast(std.mem.indexOf(u8, src, "def").?);
        try t.expectEqual(@as(u32, 0), decoratorStart(src, at));
    }
    {
        // Single decorator directly above -> include it (offset of '@').
        const src = "@dec\ndef f():\n    pass\n";
        const at: u32 = @intCast(std.mem.indexOf(u8, src, "def").?);
        const start = decoratorStart(src, at);
        try t.expectEqual(@as(u32, 0), start);
        try t.expect(src[start] == '@');
    }
    {
        // Two stacked decorators -> both included.
        const src = "@a\n@b\ndef f():\n    pass\n";
        const at: u32 = @intCast(std.mem.indexOf(u8, src, "def").?);
        const start = decoratorStart(src, at);
        try t.expectEqual(@as(u32, 0), start);
        try t.expect(std.mem.startsWith(u8, src[start..], "@a\n@b\ndef"));
    }
    {
        // A blank line between decorator and def stops the run.
        const src = "@a\n\ndef f():\n    pass\n";
        const at: u32 = @intCast(std.mem.indexOf(u8, src, "def").?);
        const start = decoratorStart(src, at);
        // Should land at the start of the `def` line, not include `@a`.
        try t.expect(std.mem.startsWith(u8, src[start..], "def f()"));
    }
    {
        // A non-decorator preceding line stops the run.
        const src = "x = 1\ndef f():\n    pass\n";
        const at: u32 = @intCast(std.mem.indexOf(u8, src, "def").?);
        const start = decoratorStart(src, at);
        try t.expect(std.mem.startsWith(u8, src[start..], "def f()"));
    }
}

// --- writeIndent / writeSiteLines ----------------------------------------

test "writeIndent emits two spaces per level" {
    const t = std.testing;
    {
        const s = try renderIndentStr(0);
        defer t.allocator.free(s);
        try t.expectEqualStrings("", s);
    }
    {
        const s = try renderIndentStr(3);
        defer t.allocator.free(s);
        try t.expectEqualStrings("      ", s);
    }
}

test "writeSiteLines lists distinct call-site lines and caps the run" {
    const t = std.testing;
    {
        const s = try renderSiteLinesStr(&.{ 3, 7 });
        defer t.allocator.free(s);
        try t.expectEqualStrings("  \u{21B3}:3,7", s);
    }
    {
        // Exactly the cap (6) -> full list, no remainder.
        const s = try renderSiteLinesStr(&.{ 1, 2, 3, 4, 5, 6 });
        defer t.allocator.free(s);
        try t.expectEqualStrings("  \u{21B3}:1,2,3,4,5,6", s);
    }
    {
        // Over the cap -> first 6 then `,+N`.
        const s = try renderSiteLinesStr(&.{ 1, 2, 3, 4, 5, 6, 7, 8 });
        defer t.allocator.free(s);
        try t.expectEqualStrings("  \u{21B3}:1,2,3,4,5,6,+2", s);
    }
}

// --- Integration: symbol rendering at each verbosity ----------------------

test "symbol renders name/sig/doc/full for a documented function" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "add.zig", .data =
        \\/// Adds two numbers together.
        \\pub fn add(a: i32, b: i32) i32 {
        \\    return a + b;
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    { // names: kind + name + location, no signature.
        const s = try renderByName(&idx, "add", .names, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.startsWith(u8, s, "fn add  L"));
        try testing.expect(std.mem.indexOf(u8, s, "i32") == null);
        try testing.expect(std.mem.indexOf(u8, s, "\u{00BB}") == null); // no doc line
    }
    { // sig: collapsed signature appears.
        const s = try renderByName(&idx, "add", .sig, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "fn add (a: i32, b: i32) i32") != null);
        try testing.expect(std.mem.indexOf(u8, s, "\u{00BB}") == null);
    }
    { // doc: signature plus the first doc line, indented under it.
        const s = try renderByName(&idx, "add", .doc, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "fn add (a: i32, b: i32) i32") != null);
        try testing.expect(std.mem.indexOf(u8, s, "\u{00BB} Adds two numbers together.") != null);
    }
    { // full: location line then the full source body (no signature suffix).
        const s = try renderByName(&idx, "add", .full, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "pub fn add(a: i32, b: i32) i32 {") != null);
        try testing.expect(std.mem.indexOf(u8, s, "return a + b;") != null);
    }
}

test "doc verbosity emits no doc line when the symbol is undocumented" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "nd.zig", .data =
        \\pub fn bare() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const s = try renderByName(&idx, "bare", .doc, false);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "fn bare") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\u{00BB}") == null);
}

// --- Integration: writeLocation (bare/range, path on/off) -----------------

test "writeLocation is a bare line for single-line and a range for multi-line" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "loc.zig", .data =
        \\pub fn one() void {}
        \\pub fn many(a: i32) i32 {
        \\    return a;
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    { // single-line -> bare `L1`, no range.
        const s = try renderByName(&idx, "one", .names, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "  L1\n") != null);
        try testing.expect(std.mem.indexOf(u8, s, "-") == null);
    }
    { // multi-line (lines 2..4) -> range `L2-4`.
        const s = try renderByName(&idx, "many", .names, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "  L2-4\n") != null);
    }
    { // show_path on -> `path:line` instead of `L`.
        const s = try renderByName(&idx, "one", .names, true);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "loc.zig:1") != null);
        try testing.expect(std.mem.indexOf(u8, s, "  L1") == null);
    }
    { // show_path on with a range.
        const s = try renderByName(&idx, "many", .names, true);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "loc.zig:2-4") != null);
    }
}

// --- Integration: writeSigSuffix (params vs value vs container) -----------

test "writeSigSuffix shows params for functions and values for consts, nothing for containers" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "sig.zig", .data =
        \\pub const LIMIT: u32 = 10;
        \\pub const Store = struct {
        \\    n: u32,
        \\};
        \\pub fn run(x: u32) u32 {
        \\    return x;
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    { // function -> parameter/return slice.
        const s = try renderByName(&idx, "run", .sig, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "fn run (x: u32) u32") != null);
    }
    { // constant -> value slice after the name.
        const s = try renderByName(&idx, "LIMIT", .sig, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "const LIMIT u32 = 10") != null);
    }
    { // container (struct) -> no signature suffix, just kind+name+location.
        const s = try renderByName(&idx, "Store", .sig, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.startsWith(u8, s, "struct Store  L"));
        // The `struct {` body head must not leak into the sig line.
        const nl = std.mem.indexOfScalar(u8, s, '\n').?;
        try testing.expect(std.mem.indexOf(u8, s[0..nl], "{") == null);
    }
}

test "writeSigSuffix renders Java's leading method return type" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Money.java", .data =
        \\public final class Money {
        \\    public Money(int cents) {}
        \\    public static String format(int cents) { return ""; }
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const method = try renderByName(&idx, "format", .sig, false);
    defer testing.allocator.free(method);
    try testing.expect(std.mem.indexOf(u8, method, "Money.format (int cents) -> String") != null);

    const constructor = try renderByName(&idx, "Money", .sig, false);
    defer testing.allocator.free(constructor);
    try testing.expect(std.mem.indexOf(u8, constructor, "->") == null);
}

test "writeSigSuffix caps a long const value with an ellipsis" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // A value string well over max_value_len (60) non-space chars.
    try tmp.dir.writeFile(io, .{ .sub_path = "big.zig", .data =
        \\pub const MSG = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const s = try renderByName(&idx, "MSG", .sig, false);
    defer testing.allocator.free(s);
    // Truncated with the ellipsis; the tail of the literal is dropped.
    try testing.expect(std.mem.indexOf(u8, s, "\u{2026}") != null);
    try testing.expect(std.mem.indexOf(u8, s, "aaaaaaaaaa") != null);
}

// --- Integration: writeQualifiedName (Parent.child) -----------------------

test "writeQualifiedName prefixes the enclosing parent for a method" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "q.zig", .data =
        \\pub const Store = struct {
        \\    pub fn load(self: Store) void {
        \\        _ = self;
        \\    }
        \\};
        \\pub fn free_fn() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    { // method carries `Store.load`.
        const s = try renderByName(&idx, "load", .names, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "Store.load") != null);
    }
    { // top-level function has no parent prefix.
        const s = try renderByName(&idx, "free_fn", .names, false);
        defer testing.allocator.free(s);
        try testing.expect(std.mem.indexOf(u8, s, "fn free_fn ") != null);
        try testing.expect(std.mem.indexOf(u8, s, ".free_fn") == null);
    }
}

// --- Integration: writeFullBody includes decorators -----------------------

test "writeFullBody widens the slice to include leading decorators" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "d.py", .data =
        \\class C:
        \\    @property
        \\    def value(self):
        \\        return self._x
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const s = try renderByName(&idx, "value", .full, false);
    defer testing.allocator.free(s);
    // The decorator that the parser excludes from the span is restored in `-v full`.
    try testing.expect(std.mem.indexOf(u8, s, "@property") != null);
    try testing.expect(std.mem.indexOf(u8, s, "def value(self):") != null);
    try testing.expect(std.mem.indexOf(u8, s, "return self._x") != null);
}

// --- Integration: symbolSite edge annotations -----------------------------

test "symbolSite annotates a single call-site edge with counts and heuristic marks" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "e.zig", .data =
        \\pub fn target() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const sym = idx.graph.symbols[idx.lookup("target")[0]];

    { // site != 0, sites == 1 -> plain `↳:N`.
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try symbolSite(&aw.writer, &idx, sym, .names, 0, false, 7, 1, &.{}, true);
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "\u{21B3}:7") != null);
        try testing.expect(std.mem.indexOf(u8, out, "\u{00D7}") == null); // no ×
        try testing.expect(std.mem.indexOf(u8, out, " ?") == null);
    }
    { // sites > 1 -> `↳:N ×C`.
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try symbolSite(&aw.writer, &idx, sym, .names, 0, false, 7, 3, &.{}, true);
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "\u{21B3}:7 \u{00D7}3") != null);
    }
    { // exact == false -> trailing ` ?`.
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try symbolSite(&aw.writer, &idx, sym, .names, 0, false, 7, 1, &.{}, false);
        const out = aw.written();
        try testing.expect(std.mem.endsWith(u8, out, " ?\n"));
    }
    { // site == 0 -> no annotation at all (root / plain listing).
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try symbolSite(&aw.writer, &idx, sym, .names, 0, false, 0, 1, &.{}, true);
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "\u{21B3}") == null);
    }
}

test "symbolSite lists multiple call-site lines and adds a count only past them" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ml.zig", .data =
        \\pub fn target() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const sym = idx.graph.symbols[idx.lookup("target")[0]];

    { // Multiple distinct lines, sites == lines.len -> list, no trailing count.
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try symbolSite(&aw.writer, &idx, sym, .names, 0, false, 10, 2, &.{ 10, 20 }, true);
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "\u{21B3}:10,20") != null);
        try testing.expect(std.mem.indexOf(u8, out, "\u{00D7}") == null);
    }
    { // sites exceed the distinct lines shown (same-line repeats) -> `×C`.
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try symbolSite(&aw.writer, &idx, sym, .names, 0, false, 10, 5, &.{ 10, 20 }, true);
        const out = aw.written();
        try testing.expect(std.mem.indexOf(u8, out, "\u{21B3}:10,20 \u{00D7}5") != null);
    }
}

test "symbol delegates to symbolSite with no edge annotation" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.zig", .data =
        \\pub fn foo(x: i32) i32 {
        \\    return x;
        \\}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const sym = idx.graph.symbols[idx.lookup("foo")[0]];
    var a: std.Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    try symbol(&a.writer, &idx, sym, .sig, 0, false);
    const via_symbol = a.written();

    var b: std.Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try symbolSite(&b.writer, &idx, sym, .sig, 0, false, 0, 1, &.{}, true);
    const via_site = b.written();

    try testing.expectEqualStrings(via_symbol, via_site);
    try testing.expect(std.mem.indexOf(u8, via_symbol, "\u{21B3}") == null);
}

test "symbol honors indent depth for the leading field" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "i.zig", .data =
        \\pub fn foo() void {}
    });
    var path_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var idx = try index_mod.build(testing.allocator, io, root, false, .auto);
    defer idx.deinit();

    const sym = idx.graph.symbols[idx.lookup("foo")[0]];
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try symbol(&aw.writer, &idx, sym, .names, 2, false);
    const out = aw.written();
    // Two levels of indent (four spaces) then the kind field.
    try testing.expect(std.mem.startsWith(u8, out, "    fn foo"));
}

test "sourceLine returns the trimmed 1-based line, and empty out of range" {
    const src = "first\n  second line  \nthird";
    try std.testing.expectEqualStrings("first", sourceLine(src, 1));
    try std.testing.expectEqualStrings("second line", sourceLine(src, 2));
    try std.testing.expectEqualStrings("third", sourceLine(src, 3));
    try std.testing.expectEqualStrings("", sourceLine(src, 4));
    try std.testing.expectEqualStrings("", sourceLine(src, 0));
}
