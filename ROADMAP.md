# NavGraph Roadmap

Prioritized improvements to move NavGraph from a strong heuristic navigator to a
state-of-the-art code-graph engine. Tiers are ordered by impact-to-effort; do
Tier 1 first.

Baseline today: recursive whole-repo indexing; heuristic symbol + reference
extraction for Zig, C/C++, Python, JS/TS/TSX; name-based reference resolution;
`outline`/`def`/`calls`/`callers`/`search` with depth + verbosity. Known gaps:
name-based resolution produces false positives (a stdlib `x.deinit()` can
resolve to a project `Index.deinit`), and type-annotation uses in signatures are
not fully captured as edges.

---

## Tier 1 — Precision (the current ceiling)

1. **Type-scoped receiver resolution.** ✅ *Done.* Member calls `recv.name()`
   resolve only to a member of `recv`'s inferred type — from `self`/`this`, typed
   parameters, and local `const/var/let` initializers (`Foo.init()`, `Foo{...}`,
   `new Foo()`). Unknown receiver types are left external instead of guessed,
   which removed the dominant false-positive class (e.g. a stdlib `x.deinit()`
   pointing at `Index.deinit`). Each edge carries an `exact` confidence flag and
   `--strict` follows only high-confidence edges.
   - *Still open:* **import-aware module resolution** — use the recorded `import`
     edges to bind a qualifier that names an imported module/file to that file's
     symbols (currently such qualifiers fall through to external).

2. **Richer edge kinds.** Capture references from signatures/returns
   (type uses beyond params), plus `extends` / `implements` / base classes.
   Enables "who subclasses / uses type `T`".

## Tier 2 — Reach & correctness

3. **Tree-sitter backend (optional).** Vendor grammars compiled via `build.zig`
   for exact parsing and more languages (Go, Rust, Java, Ruby), keeping the
   zero-dependency heuristic path as a fallback.

4. **Cross-language API linking.** Detect route definitions (FastAPI/Flask
   decorators, Express `app.get`, etc.) and client calls (`fetch('/route')`,
   axios, RPC) and link them across languages. Likewise DB models, GraphQL,
   protobuf/OpenAPI schemas.

## Tier 3 — Speed & integration

5. **Incremental on-disk cache** keyed by mtime + size (`.navgraph/cache`).
   Re-parse only changed files; turns repeated agent calls from ~200ms to ~ms.

6. **Daemon / LSP / MCP mode.** Long-running server with `inotify` file-watching
   to keep the graph warm; agents query over a socket for near-instant
   responses. Optionally expose as an MCP server or editor LSP.

7. **`--json` / `--jsonl` output** for stable programmatic consumption by agents
   and tooling.

## Tier 4 — Smarter views

8. **New query verbs:**
   - `path <A> <B>` — shortest call path between two symbols.
   - `neighbors <name>` — callers + callees in one view.
   - `unused` — dead code (symbols with no callers).
   - `imports <file>` / `importers <file>` — module dependency graph.
   - `changed <gitrev>` — symbols touched since a revision + their blast radius.

9. **Relevance ranking.** PageRank / centrality on the call graph so `search`
   and `outline` surface important symbols first; show fan-in/out counts
   (e.g. `+12 callers`).

10. **Robustness details.**
    - UTF-8 column handling (Python indentation currently uses byte columns;
      multibyte source could misalign scoping).
    - Snapshot / golden tests across a multi-repo corpus per language.
    - Fuzz the lexer/parser for panics on malformed input.

---

## Suggested next step

Tier 1 receiver-type resolution is done. Next highest-value: **import-aware
module resolution** (Tier 1.1) to recover edges through imported module
qualifiers, then the **incremental on-disk cache** (Tier 3.5) for speed on
repeated agent calls.
