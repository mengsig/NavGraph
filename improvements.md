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

## Output / UX gaps to address next (ranked)

### 1. Module-qualified calls don't resolve — ✅ FIXED (Phase 4)
`callers`/`calls` used to miss every call made through an imported module
(`render.symbol`, `api.methodsMatch`, `cache.load` reported zero callers).
Import-aware resolution (`src/imports.zig` + `index.buildImportTable`) now binds
`mod.func()` to the imported file's `func` across Zig/JS/TS/Python, so these
resolve. A related `collectRefs` bug that dropped a qualified call sharing the
enclosing function's name was fixed too. *Remaining:* calls on values whose type
isn't tracked (enum methods like `x.tag()`) still fall through to external.

### 2. `callers`/`calls` don't show the call-site line — too little info
Each caller is printed at *its own definition* line (`parseZigFn … :566`), not
the line where the call actually happens. The `Reference.line` field already
holds the call-site line; it just isn't rendered. Showing `→ used at L620`
would let an agent jump straight to the usage instead of re-searching the body.

### 3. Attached flag values are rejected
`-d2` and `--depth=2` fail with "unknown flag" (now at least a clear error).
Agents frequently write these. Supporting `-d2` and `--flag=value` would remove
a common, silent-until-now footgun.

### 4. Large `const` initializers are dumped in `sig` view — too much info
`outline -v sig` prints ~160 chars of a comptime map's value
(`router_receivers`, keyword sets, etc.), which is noise when you only wanted
the shape. For container/collection constants, showing just the type
(`std.StaticStringMap(void)`) or the first entry would be cleaner. Verbosity
`names` already avoids this, but `sig` is the default.

### 5. `search` matches definition names only — occasional confusion
Searching for something that's only *used* (e.g. `fetch`) returns "no symbol
matching", which reads like the identifier is absent. A one-line hint, or an
opt-in `--refs` mode that also searches reference names, would help.

### 6. Ambiguity handling for same-named free functions
`Parent.name` disambiguates methods, but two same-named top-level functions in
different files (the two `build`s) can only both be shown. A `file:name` or
`path#name` selector would let a query target one precisely.

---

## Suggested priority

1. ~~Import-aware module resolution~~ — ✅ done (Phase 4); `callers`/`calls`/
   `unused`/`imports` are now trustworthy across files.
2. **Call-site lines in caller/callee trees** (gap 2) — small, high utility, now
   the top open item.
3. **Attached flag values** (gap 3) — small, removes a real friction point.
4. Then the output-tuning items (4–6) as polish, plus **relevance ranking**
   (fan-in/out counts) to surface important symbols first.
