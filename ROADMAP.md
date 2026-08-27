# NavGraph Roadmap

Prioritized improvements to move NavGraph from a strong heuristic navigator to a
state-of-the-art code-graph engine. Tiers are ordered by impact-to-effort; do
Tier 1 first.

Baseline today: recursive whole-repo indexing with an on-disk cache; heuristic
symbol + reference extraction for Zig, C, C++, C#, Python, JS/TS/TSX, Lua, Go,
Rust, and Ruby; type-scoped + import-aware (scope-aware) reference resolution;
and a broad verb set (`outline`/`def`/`calls`/`callers`/`search`/`routes`/
`events`/`neighbors`/`unused`/`imports`/`importers`/`path`/`diff`/`hot`/`files`/
`read`/`strings`/`coverage`) with depth, verbosity, JSON, and a unified `--tests`
scope. Known gaps: bare-receiver resolution is still heuristic (marked `?`), and
type-annotation uses in signatures are not fully captured as edges.

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

3. **More languages.** ✅ *Language expansion done* — Go, Rust, Ruby, C#, and Lua
   now ship via the zero-dependency heuristic parser (alongside Zig, C/C++,
   Python, JS/TS/TSX). *Still open:* an optional tree-sitter backend for exact
   parsing / more languages (Java, Kotlin, Swift, …), keeping the heuristic path
   as the fallback.

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
   `--no-cache` forces a clean rebuild. A version-tagged magic (currently
   `NGCACHE5`) plus a content-hash of the indexer source invalidate the whole
   cache on any format/logic change or corruption (safe rebuild, never a crash).

6. **Daemon / LSP / MCP mode.** ✅ *Done.* `navgraph serve` is the MCP surface;
   `navgraph lsp` is a resident editor server over stdio: LSP framing +
   JSON-RPC 2.0, the standard subset (`definition`/`references`/`hover`/`documentSymbol`/
   `workspace/symbol`, full document sync) plus custom `navgraph/*` methods
   (`status`/`symbolAt`/`blast`/`search`/`grep`/`callers`/`calls`/`rescan` and a
   `navgraph/indexed` notification). An open buffer's unsaved text drives the
   graph; an edit re-parses only that file and re-assembles it. Watching is an
   mtime poll (portable, no `inotify`), and the whole server is single-threaded
   so the graph needs no lock. Measured on this repo (ReleaseFast): initial
   index 36–46 ms cold / 14–16 ms warm, single-file re-index 4–10 ms, search
   ~2 ms, grep ~3 ms, blast depth 3 0.1 ms; ~35 MB resident at 118k lines.
   Protocol and numbers: [`docs/lsp.md`](docs/lsp.md).
   - *Still open:* the remaining verb mirrors (`neighbors`/`path`/`outline`/
     `hot`/`unused`/`diff`/`routes`/`events`/`imports`/`importers`/`graph`) —
     one adapter function each.

7. **`--json` output.** ✅ *Done.* `src/json_out.zig` mirrors every verb
   (`outline`/`def`/`calls`/`callers`/`search`/`routes`/`events`/`neighbors`/
   `unused`/`diff`/`hot`/`coverage`/…) behind `-j`/`--json`.
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
   - `hot [path]` — rank functions by fan-in/out (`←N callers →M callees`),
     the load-bearing symbols. ✅
   - `coverage [path]` — per-file % of fn/method reachable from a test
     (call-graph, no instrumentation; text + JSON). ✅

9. **Relevance ranking.** ✅ *Partial* — fan-in/out ranking ships as the `hot`
   verb (`←N callers →M callees`). *Still open:* PageRank/centrality so `search`
   and `outline` *themselves* surface important symbols first.

10. **Test-awareness & coverage.** ✅ *Done.* Zig `test` blocks are indexed as
    first-class `test` symbols, so `callers foo --tests-only` shows the tests
    exercising `foo`; a unified `--tests <with|without|only>` selector scopes
    `outline`/`search`/`callers`/`hot`/`unused` (cross-language via a test path
    heuristic); and `coverage [path]` reports call-graph test reach. *Still open:*
    non-Zig *inline* tests (e.g. Rust `#[cfg(test)]`) are not yet detected.

11. **Robustness details.**
    - UTF-8 column handling (Python indentation currently uses byte columns;
      multibyte source could misalign scoping).
    - Snapshot / golden tests across a multi-repo corpus per language.
    - Fuzz the lexer/parser for panics on malformed input.

---

## Suggested next step

Tiers 1–4 core items are done (type-scoped + import-aware resolution, API
linking, cache + JSON, the query verbs incl. `hot`/`coverage`, and
test-awareness). Next highest-value, per the dogfooding backlog in
`new-features.md`: **import-graph resolution for C/C++/C#/Go** (§F — lights up
`imports`/`importers`/`path` for four more languages and fixes a Python
submodule-import bug), **`def -v doc` docstrings** (§H), and the remaining
per-language parser depth (§D — Zig generic containers, C# properties/fields).
Then PageRank ordering (Tier 4.9) and the robustness items (Tier 4.11).
