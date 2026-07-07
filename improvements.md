# NavGraph — findings from dogfooding

Written after auditing Phases 1–3 (type-scoped resolution, cross-language API
linking, incremental cache + JSON) by navigating the codebase **with NavGraph
itself** instead of `grep`/`read`. It records what worked, the correctness bugs
that dogfooding surfaced (and which are now fixed), and the output/UX gaps worth
addressing next — ranked by impact on an agent.

---

## What works well

- **`outline -v names` is the standout.** A whole-repo structural map in a few
  hundred dense lines; far cheaper than reading files. `outline <subdir>` and
  per-file outlines are equally good orientation tools.
- **Real edges, not text.** `calls`/`callers` resolve actual references, so
  matches inside comments/strings don't pollute results, and same-name symbols
  in different files are disambiguated (e.g. the two `build` and three `parse`
  definitions are listed separately with their files).
- **Type-scoped member resolution behaves as designed.** A member call on an
  unknown receiver (`x.family()`) is correctly left *external* rather than
  guessed — visible when auditing `chooseTarget`.
- **Cross-language API linking is genuinely novel and reliable.** A Python
  `@app.get("/users/{id}")` and a TS `fetch(\`/users/${id}\`)` link both ways
  first try; `routes` gives a clean API surface.
- **JSON mode** (`-j`) produced valid, well-formed output for every verb — good
  for tooling/MCP.
- **Cache** makes repeat calls fast (~5× on a 40k-line tree).

---

## Correctness bugs found while dogfooding — now fixed

1. **Zig `\\` multiline strings were tokenized as code.** `navgraph routes` on
   this very repo reported a phantom `GET /users/{id}` route that lives only
   inside a test fixture string. The shared lexer had no notion of Zig's
   to-end-of-line string literal, so any code-shaped text inside `\\ ...` lines
   (extremely common in Zig tests) produced phantom symbols and routes.
   → Fixed by adding `Config.line_string` (set to `\\` for Zig) and lexing such
   lines as string tokens. Regression test added.

2. **The cache was rewritten on every invocation.** Even a no-op query
   re-serialized the entire repo to `.navgraph/cache` (hundreds of KB, or many
   MB on a large repo) despite nothing changing.
   → Fixed: the write is skipped when every file was a cache hit and no file was
   added/removed (`cacheStale`).

3. **Usage errors exited 0 with no explanation.** `navgraph calls build -d abc`
   and `-d1` just dumped the full help text and returned success, so a script or
   agent couldn't tell the command had failed.
   → Fixed: parse failures now print a one-line reason to **stderr** and exit
   **2**; valid runs and explicit `help` still exit 0.

---

## Cross-repo dogfooding fixes (src-layout monorepo)

Surfaced auditing a Python+TS `src/`-layout monorepo where installed package
names (`ccso_core`) differ from on-disk directories
(`packages/ccso_core/src/ccso_core/...`). All fixed:

1. **Src-layout imports now resolve.** `imports`/`importers`/`path` used to
   report "no local imports" because `from ccso_core.classes.Ship import Ship`
   maps to the candidate `ccso_core/classes/Ship.py`, which is never an on-disk
   prefix. `index.resolveModule` now adds a Python unique-suffix fallback: when
   exactly one indexed file ends with `/<candidate>`, it binds to it (ambiguous
   suffixes stay unresolved rather than guessed).

2. **No more cross-language false edges.** `callers Ship` (a Python class) used
   to list TSX components that merely mention "Ship". `chooseTarget` now refuses
   to bind a bare reference across language families — Python `Ship` and a TSX
   `Ship` share a name, not a namespace. The only intended cross-language edge
   (client call → route) is a `route_call`, resolved separately.

3. **`unused` is no longer buried in framework entry points.** `isDeadCandidate`
   skips `__dunder__` methods, `test_*` functions, and everything in
   test/`conftest.py`/`*.spec.*` files (tests + fixtures are framework-invoked).

4. **`routes` applies the router prefix.** `admin_router = APIRouter(prefix=
   "/api/admin")` + `@admin_router.get("/users")` now reports
   `GET /api/admin/users` (via `api.matchRouterDecl`). This also fixes the
   cross-language link, since a frontend `fetch("/api/admin/users")` now matches.

5. **Truncation is visible.** When output is capped by `-l`, a
   `… (stopped at -l N; …)` line is printed for `outline`/`search`/`routes`/
   `unused`, so a truncated result is never mistaken for the whole project.

## Test-environment dogfooding round — 22 bugs found & fixed

Seven purpose-built test applications under `testenv/` (excluded from the tool's
own indexing) give **full-coverage** exercise of every language and verb: a Zig
VM, a C container lib, a C++ classes/namespaces app, a Python FastAPI backend, a
JS Express backend (CommonJS + ESM), a TS/TSX frontend, and a cross-language
Flask+TS full-stack app. Probing NavGraph against each app's known ground truth
(then adversarially verifying every candidate against source) surfaced 18
confirmed defects; fixing them exposed 3 more latent ones, and a second
adversarial verification pass over the fixed binary found 1 more. All 22 are
fixed with regression tests (43 unit tests, up from 29).

**C / C++ (the biggest coverage gap).** The C scanner recognised only
`struct/enum/union` records and free functions, so entire language features were
invisible:
- `namespace X { ... }` bodies were skipped wholesale — every class, method and
  function inside (i.e. essentially all real C++) vanished. `parseCppNamespace`
  now recurses transparently and emits the namespace as a `module`.
- `class` was never dispatched to record parsing; classes and their methods are
  now indexed (`parseCRecord` handles `class` + inheritance; `parseCppMembers`
  extracts inline **and** declared methods). Trailing qualifiers
  (`const`/`noexcept`/`override`) and constructor member-initializer lists are
  handled — the latter previously produced phantom functions (`radius_(r)` →
  `fn radius_`).
- `static` free functions (internal linkage) were hard-coded `exported = true`,
  so a genuinely-dead private helper was flagged in `unused` as "may be public
  API" (risky to remove) and reported `exported:true` in JSON. Now `exported`
  reflects the `static` qualifier.

**TypeScript type-level decls.** `interface`, `enum` and `type` aliases were in
the keyword skip-set and emitted nothing — a file of exported interfaces
outlined as empty. `parseTsContainer`/`parseTsTypeAlias` now emit them (gated to
`.ts`/`.tsx`; plain JS is unaffected).

**JS/TS module edges.** CommonJS `require('./x')` (and destructured
`const { a } = require('./x')`) never populated the import graph; both now emit
import symbols, and a `require` binding resolves member calls (`db.all()`).
`export { X } from './m'` / `export type { X } from './m'` re-exports now record
edges too, and `import type { X }` no longer mis-binds the name `type`.

**Python relative imports.** `from ..services.user_service import X` was dropped
because the module-path scanner rejected the leading dots — so `imports.zig`'s
relative-resolution logic was dead code. `parsePyImport` now captures the dotted
prefix; relative/`from .` imports resolve across a package.

**Cross-language API linking.**
- `fetch(url, { method: "POST" })` (and DELETE/PUT/…) was hard-coded to GET, so a
  client POST linked to the wrong route. `clientMethodOverride` reads the inline
  options object.
- Collection routes `@router.post("")` (empty path) were dropped by `pathOf`,
  which also made their handlers look **unused**; empty paths are now accepted
  and prefixed (`/api/users`).
- An Express inline-arrow route `router.delete("/x", (req,res)=>{})` bound a
  *phantom* handler (a later top-level function found by the forward `def`/
  `function` scan). The scan now runs only for decorator-form routes.

**Graph symmetry & precision.** `callers` counted every resolved reference but
`calls`/`neighbors`/`path` followed only `.call`/`.route_call` edges — so a macro
or const use showed up under `callers X` yet `calls Y` omitted it (a
self-contradiction). All directions now traverse every resolved edge; only
unresolved *calls* are listed as `~ ext`. Surfacing those read edges also exposed
a name-collision false edge (a local `const candidates = …` binding to a global
`fn candidates`); a bare reference that names a local variable/parameter is no
longer bound to a same-named global.

## Agent-ergonomics round — "the tool I'd want for myself"

Dogfooding NavGraph as *the agent that consumes it* (not just correctness
testing) exposed that the graph already stored the data I most wanted — it just
wasn't surfaced. Every gap below is now closed; +8 regression tests (51 total).
The through-line: **close the loop from "find a symbol" to "act on it"** — a
query should hand me an exact line range to read and the exact line where an edge
happens, not send me back to grep.

### Line ranges everywhere — ✅ built
Locations render as `path:start-end` (`src/index.zig:373-384`), computed from the
symbol's byte span (`model.Symbol.endLine`). A single-line symbol stays a bare
line. This is the highest-leverage change: I can now `Read` exactly the
definition instead of guessing an offset. JSON gains a `line_end` field.

An adversarial verification pass (4 agents refuting each feature against
ground-truth source across 7 languages) caught a real bug here: for C/C++,
`endLine` overshot the closing brace — sometimes past EOF — because it was
measured as an offset from the *name* line, but a C span can legitimately begin
earlier (a leading doc comment, or a `template <…>` / multi-line-return prefix).
Fixed two ways: `endLine` now computes the end line *absolutely* (the line of the
last real byte, prefix-independent), and the C parser no longer folds a leading
doc comment into a definition's span (so `def -v full` stops duplicating the doc
too). Re-verified: 0 findings. Regression test in `query.zig`.

### Call-site lines on every edge — ✅ built (was gap 2)
`callers`/`calls`/`neighbors`/`routes` annotate each edge with `↳:N`, the line
where the call actually happens (from `Reference.line`), rather than only the
caller's own definition line. In a callers tree N is in this row's file; in a
callees tree N is in the parent's file — i.e. always the caller side of the edge.
JSON gains a `site` field on tree nodes. Now a `callers` result is directly
jump-to-usage.

### `hot` — relevance ranking — ✅ built (new verb)
`navgraph hot [path]` ranks functions/methods by fan-in (callers) then fan-out
(callees) and lists the busiest with `←N callers →M callees`. On first contact
with an unknown repo this is the orientation view: it surfaces the load-bearing
symbols to read first and shows where a change will ripple widest. Defaults to a
short top-25 (raise `-l`); honors a path filter; has a JSON form (`fan_in`/
`fan_out`). Alias: `central`.

### `search --refs` — find-usages — ✅ built (was gap 5)
`search <pat> --refs` lists every *use site* (reference) matching the pattern —
`file:line  name (on receiver)  in <enclosing symbol>  → <target file|~ext>` —
a resolution-aware grep that name-only search couldn't do. It's structural
(no comment/string false hits) and shows what each use resolves to.

### `name@path` disambiguation — ✅ built (was gap 6)
Any name argument accepts a trailing `@<path-substring>` selector
(`build@build.zig`, `parse@parser`) that keeps only matches whose file path
contains the substring — the way to target one of several same-named symbols.
Composes with `Parent.name`.

### Attached flag values — ✅ built (was gap 3)
`-d2`, `-l50`, `-kfn`, `--depth=2`, `-Csub/dir` all parse now (value attached or
as the next token). Boolean flags reject an attached `=value`. Removes a common
silent footgun.

### `--kind` filter — ✅ built (new)
`outline`/`search` accept `-k/--kind fn,struct,…` to restrict output to given
kinds (with `function`/`func` aliases). `outline --kind fn` is the "just the
functions" view.

### Collapsed `const` initializers in `sig` view — ✅ built (was gap 4)
Const/var values now cap at 60 chars (vs 160 for signatures), so a big comptime
map collapses to its type/constructor head
(`std.StaticStringMap(void).initComptime(.{ .{".git"}, .{"node…`) instead of
dumping the literal. `outline -v full` still shows the whole definition.

---

## Still open (deliberately not built)

- **Module-qualified calls on untracked-type values** (`x.tag()` where `x`'s type
  isn't inferred) still fall through to `~ext` — a resolution-depth limit, not an
  output gap.
- **Raw-text grep** (matching strings/comments) is intentionally left to `grep`;
  `search --refs` covers the structural "where is this used" need.
