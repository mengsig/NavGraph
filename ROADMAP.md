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

1a. **Import-aware module resolution.** ✅ *Done.* `.import` symbols now carry
   the module string (`import_path`) plus the binding name; `src/imports.zig`
   turns `(importer, module, language)` into candidate repo-relative paths
   (Zig `@import`, JS/TS relative + extension/`index` resolution, Python dotted
   and relative imports); `index.buildImportTable` binds each to a `FileId`
   (`Index.importsOf`). `resolveOne` then resolves `mod.func()` against the
   imported file's top-level symbols when the receiver type is unknown. This
   fixed the dominant `callers`/`calls` blind spot — module-qualified calls like
   `render.symbol(...)` now resolve. (Also fixed a `collectRefs` bug that dropped
   a qualified call sharing the enclosing function's name.)

2. **Richer edge kinds.** Capture references from signatures/returns
   (type uses beyond params), plus `extends` / `implements` / base classes.
   Enables "who subclasses / uses type `T`".

## Tier 2 — Reach & correctness

3. **Tree-sitter backend (optional).** Vendor grammars compiled via `build.zig`
   for exact parsing and more languages (Go, Rust, Java, Ruby), keeping the
   zero-dependency heuristic path as a fallback.

4. **Cross-language API linking.** ✅ *Done (HTTP).* `src/api.zig` recognizes
   route definitions (FastAPI/Flask `@app.get`, Express `app.get(...)`) and HTTP
   client calls (`fetch`, `axios`, `requests`/known clients), emits a `route`
   symbol per endpoint, and links each client call to the matching route by
   method + path pattern (`{id}`/`:id`/`<int:id>`/template/numeric segments act
   as wildcards). Surfaced via `navgraph routes` and traversable with
   `calls`/`callers` across languages. *Still open:* fetch `method:` option
   detection (POST client calls currently default to GET), DB models, GraphQL,
   protobuf/OpenAPI schemas.

## Tier 3 — Speed & integration

5. **Incremental on-disk cache.** ✅ *Done.* `src/cache.zig` persists each
   file's parsed symbols to `.navgraph/cache`, keyed by path + mtime + size.
   Unchanged files are restored from a single binary blob instead of re-lexed
   and re-parsed; only reference resolution re-runs (global ids change per
   build, so ref *targets* are never cached). Measured ~4.8× faster on a
   40k-line tree (1.26s → 0.26s). Editing one file re-parses only that file.
   `--no-cache` forces a clean rebuild. A version-tagged magic (`NGCACHE2`)
   invalidates the whole cache on any format change or corruption (safe
   rebuild, never a crash).

6. **Daemon / LSP / MCP mode.** Long-running server with `inotify` file-watching
   to keep the graph warm; agents query over a socket for near-instant
   responses. Optionally expose as an MCP server or editor LSP.
   - *Note:* the on-disk cache (5) already captures most of the per-call speed
     win without the complexity of a resident process + cross-platform watcher.

7. **`--json` output.** ✅ *Done.* `src/json_out.zig` mirrors every verb
   (`outline`/`def`/`calls`/`callers`/`search`/`routes`) behind `-j`/`--json`.
   List verbs emit a JSON array; `calls`/`callers` emit an array of call-tree
   roots (`callees`/`callers` children, `ext` for unresolved names, `recursion`
   markers). Strings are escaped; fields grow with verbosity (`sig`→`doc`→
   `body`). For stable programmatic/MCP/editor consumption.
   - *Still open:* `--jsonl` streaming variant for very large result sets.

## Tier 4 — Smarter views

8. **New query verbs.** ✅ *Done.*
   - `path <A> <B>` — shortest call path between two symbols (BFS). ✅
   - `neighbors <name>` — callees + callers in one view. ✅
   - `unused [filter]` — functions/methods *and types* nothing references
     (candidate dead code; exported symbols are marked, not hidden). ✅
   - `imports [filter]` / `importers <file>` — local module dependency graph,
     built from the resolved import table. ✅
   - `events [filter]` — string-keyed message-bus dispatch: pairs handler
     registrations (`register`/`on`) with emitters (`send`/`emit`) by key,
     the event-bus analogue of `routes`. ✅
   - `diff [ref]` — symbols touched since a git revision (default `HEAD`) plus
     their direct callers: the blast radius of a change. ✅

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

Tiers 1–4 core items are done (type-scoped + import-aware resolution, API
linking, cache + JSON, and the new query verbs). Next highest-value:
**relevance ranking** (Tier 4.9: fan-in/out counts, PageRank on the call graph
so `search`/`outline` surface important symbols first) and `changed <gitrev>`
for blast-radius review, then the robustness items (Tier 4.10).
