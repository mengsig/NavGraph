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
/// Python, TypeScript and TSX are owned by tree-sitter: the grammar reads
/// constructs the scanner cannot (instance fields, interface members, declared
/// types), and `zig build bench` records the resulting accuracy floors. Every
/// other language stays on the heuristic scanner — linking a grammar makes
/// tree-sitter *available* (`--backend tree-sitter`), it does not silently
/// change what `navgraph` extracts. Promoting a language means flipping its
/// entry here and re-running the differ and the bench: no definition lost, no
/// metric below its floor.
const owner_table: [std.meta.fields(Language).len]model.Backend = blk: {
    var table: [std.meta.fields(Language).len]model.Backend = @splat(.heuristic);
    table[@intFromEnum(Language.python)] = .tree_sitter;
    table[@intFromEnum(Language.typescript)] = .tree_sitter;
    table[@intFromEnum(Language.tsx)] = .tree_sitter;
    break :blk table;
};

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

/// Whether this build links any grammar at all. Re-exported here so the CLI and
/// the capability manifest read the backend seam, not the parser internals.
pub const any_grammar = ts_backend.any_grammar;

/// Whether any language could reach the tree-sitter backend under `choice`.
/// Lets the CLI reject `--backend tree-sitter` on a grammar-less build instead
/// of silently serving heuristic results under a tree-sitter flag.
pub fn available(choice: Choice) bool {
    return choice != .tree_sitter or ts_backend.any_grammar;
}

/// Holder for the compiled grammars. Creating a `TSQuery` walks the whole
/// grammar (~14 ms), so one Registry is built per process (a CLI run) or per
/// long-lived session and reused for every file of every build it drives.
/// Compiling per file made the spike's extraction 37x slower; compiling per
/// build costs an LSP session that ~14 ms on every keystroke's re-index.
pub const Registry = struct {
    ts: ts_backend.Registry,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .ts = ts_backend.Registry.init(gpa) };
    }

    pub fn deinit(self: *Registry) void {
        self.ts.deinit();
    }
};

/// One parse context: which backend the caller asked for, plus the grammars
/// compiled for it. The two always travel together and share a lifetime — the
/// registry is owned by the process or session that built it, and borrowed by
/// every build and every single-file re-parse it drives.
pub const Parsing = struct {
    /// Backend the caller asked for (`--backend`).
    choice: Choice,
    /// Compiled grammars, owned by the process or session that built them.
    registry: *Registry,

    /// Parse `source` for `lang` with the backend `choice` selects, appending
    /// the discovered symbols to `out`.
    ///
    /// A tree-sitter parse that produces an ERROR node is discarded whole and
    /// the heuristic scanner re-parses the file, with the substitution recorded
    /// in the returned `ParseHealth`. A partially-parsed file is never presented
    /// as a complete symbol set. Real backend failures (a query that will not
    /// compile, an unsupported grammar ABI) are returned, not swallowed — they
    /// are build defects and must not degrade into quietly different output.
    pub fn parse(
        self: Parsing,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        source: []const u8,
        lang: Language,
        out: *std.ArrayList(ParsedSymbol),
    ) !model.ParseHealth {
        // Comptime guard, not just a runtime one: a `-Dtree-sitter=none` build
        // links no tree-sitter runtime at all, so this branch must not be emitted.
        if (comptime ts_backend.any_grammar) {
            if (owner(lang, self.choice) == .tree_sitter) {
                const before = out.items.len;
                switch (try ts_backend.parse(&self.registry.ts, gpa, arena, source, lang, out)) {
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

    /// Whether a cache entry parsed as `health` may answer for `lang` under this
    /// `choice`. The cache stores extracted symbols, not the backend that
    /// produced them, so without this check `--backend` decides nothing on the
    /// default (cache-on) path: whichever backend ran first wins for every later
    /// run.
    ///
    /// A file the tree-sitter backend fell back on was parsed heuristically *on
    /// purpose*, so its entry is the right answer for `.tree_sitter` and the
    /// wrong one for `.heuristic`.
    pub fn cacheEntryUsable(self: Parsing, lang: Language, health: model.ParseHealth) bool {
        return switch (owner(lang, self.choice)) {
            .tree_sitter => health.backend == .tree_sitter or health.tree_sitter_fallback,
            .heuristic => health.backend == .heuristic and !health.tree_sitter_fallback,
        };
    }
};
