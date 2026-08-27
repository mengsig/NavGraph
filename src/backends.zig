//! Which parser backend owns which language, and the single dispatch the index
//! build calls instead of reaching into a backend directly.
//!
//! `parser.zig` (the heuristic scanner) is the default everywhere and the
//! fallback for any file a grammar cannot parse cleanly. `ts_backend.zig` is a
//! second implementation of the same contract — same `ParsedSymbol` shape, so
//! `index.zig`, `query.zig`, `json_out.zig` and the CLI are unaffected by which
//! one ran.

const std = @import("std");
const language = @import("language.zig");
const model = @import("model.zig");
const parser = @import("parser.zig");
const ts_backend = @import("ts_backend.zig");

const Language = language.Language;
const ParsedSymbol = parser.ParsedSymbol;

/// Backend requested by the caller (`--backend`).
pub const Choice = enum {
    /// Use whichever backend owns the language (`owner_table`).
    auto,
    /// Always the heuristic scanner, even where a grammar is linked in.
    heuristic,
    /// Prefer tree-sitter wherever a grammar is linked in; languages without one
    /// still use the heuristic scanner.
    tree_sitter,

    /// Parse a `--backend` value; null when it names no known backend.
    pub fn fromName(name: []const u8) ?Choice {
        if (std.mem.eql(u8, name, "auto")) return .auto;
        if (std.mem.eql(u8, name, "heuristic")) return .heuristic;
        if (std.mem.eql(u8, name, "tree-sitter") or std.mem.eql(u8, name, "tree_sitter")) return .tree_sitter;
        return null;
    }

    pub fn tag(self: Choice) []const u8 {
        return switch (self) {
            .auto => "auto",
            .heuristic => "heuristic",
            .tree_sitter => "tree-sitter",
        };
    }
};

/// The backend that owns each language under `--backend auto`.
///
/// Every entry is `.heuristic` today: linking a grammar makes tree-sitter
/// *available* (`--backend tree-sitter`), it does not silently change what
/// `navgraph` extracts. Promoting a language is a one-line change here, gated on
/// the differ in this file showing no symbol loss for that language.
const owner_table: [std.meta.fields(Language).len]model.Backend = @splat(.heuristic);

fn owner(lang: Language, choice: Choice) model.Backend {
    return switch (choice) {
        .heuristic => .heuristic,
        .tree_sitter => if (ts_backend.supports(lang)) .tree_sitter else .heuristic,
        .auto => if (owner_table[@intFromEnum(lang)] == .tree_sitter and ts_backend.supports(lang))
            .tree_sitter
        else
            .heuristic,
    };
}

/// Whether any language could reach the tree-sitter backend under `choice`.
/// Lets the CLI reject `--backend tree-sitter` on a grammar-less build instead
/// of silently serving heuristic results under a tree-sitter flag.
pub fn available(choice: Choice) bool {
    return choice != .tree_sitter or ts_backend.any_grammar;
}

/// Per-build holder for the compiled grammars. Creating a `TSQuery` walks the
/// whole grammar (~14 ms), so they are built once here and reused for every
/// file — compiling per file made the spike's extraction 37x slower.
pub const Registry = struct {
    ts: ts_backend.Registry,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .ts = ts_backend.Registry.init(gpa) };
    }

    pub fn deinit(self: *Registry) void {
        self.ts.deinit();
    }
};

/// Parse `source` for `lang` with the backend `choice` selects, appending the
/// discovered symbols to `out`.
///
/// A tree-sitter parse that produces an ERROR node is discarded whole and the
/// heuristic scanner re-parses the file, with the substitution recorded in the
/// returned `ParseHealth`. A partially-parsed file is never presented as a
/// complete symbol set. Real backend failures (a query that will not compile, an
/// unsupported grammar ABI) are returned, not swallowed — they are build defects
/// and must not degrade into quietly different output.
pub fn parse(
    reg: *Registry,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: []const u8,
    lang: Language,
    choice: Choice,
    out: *std.ArrayList(ParsedSymbol),
) !model.ParseHealth {
    // Comptime guard, not just a runtime one: a `-Dtree-sitter=none` build links
    // no tree-sitter runtime at all, so this branch must not be emitted.
    if (comptime ts_backend.any_grammar) {
        if (owner(lang, choice) == .tree_sitter) {
            const before = out.items.len;
            switch (try ts_backend.parse(&reg.ts, gpa, arena, source, lang, out)) {
                .extracted => {
                    try parser.appendApiSymbols(gpa, arena, source, lang, out);
                    return .{ .backend = .tree_sitter };
                },
                .error_node => {
                    out.shrinkRetainingCapacity(before);
                    var health = try parser.parse(gpa, arena, source, lang, out);
                    health.tree_sitter_fallback = true;
                    return health;
                },
            }
        }
    }
    return parser.parse(gpa, arena, source, lang, out);
}
