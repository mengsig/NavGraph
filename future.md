# Future work

## Agent-trial hardening rounds (2026-07-09/10, 10 Sonnet trials + A/B vs grep)

Three rounds of agent trials (own src, testenv/fullstack, Caddy ~100k-line Go,
pallets/click, CLI stress audit, and a navgraph-vs-grep A/B on identical
questions) drove: `.navgraphignore` + `!` re-include over the built-in skip set
(issue #2), `*` glob patterns for names/paths (issue #3), the JSON test-scope
bug fix, exit codes (0/1/2 + quiet SIGPIPE), one-line named-flag errors,
did-you-mean suggestions, multi-match banners, minified-file quarantine,
`testdata/` as test scope, scope-aware `hot` ranking, the >4-candidate
heuristic-dispatch cap, Go package-qualified resolution (`caddy.Load`) via
`package X` module symbols, Go receiver→type parenting (`Metrics.Provision`
pins), inheritance clauses in outlines, JSON `parent`, kwarg/loop-var binding
capture (killed false cross-file arrows), `unused` dispatch/protocol/
external-base/route-call annotations, `--no-recurse`, `search -e`, and use-site
source lines in `search --refs`.

**Parked from these trials** (value clear, needs design):
- **`fields <Type>` / shape-usage** — which properties of a type are actually
  dereferenced downstream (the "what breaks if I rename this JSON key" query).
  Attribute-read refs (`.field` pins) already hold most of the data.
- **Stub/no-op body detection** for `events`/`routes` pairings (an empty
  `emit() {}` transport looked wired when it wasn't).
- **`--tests-only` noise**: test-helper classes defined and used inside a
  single test function still read as unused test helpers.
- **Go admin-mux route registration** (`caddyconfig/load.go` style) isn't
  recognized by `routes` (only decorator/`app.get`-style and HTTP clients).

**Correction (2026-08-28).** The claim below that index work is below the noise
floor held only at the scale it was measured at. Java inherited-member lookup
scanned the whole symbol table per unresolved reference, recursed 16 deep, so
index build went quadratic in project size: 4,192 files cost 4,428 ms warm
against a 120 ms baseline. It is now a supertype map precomputed once per build
(179 ms on the same corpus), with a bounded regression test in `src/index.zig`
(`Java inherited-member resolution stays linear in symbol count`). Whole-project
link passes are the thing to watch; per-file parse cost still is not.

Ideas parked for when they're justified by evidence. Ordered by value-for-effort.
Context: profiling (2026-07-07) shows NavGraph's index work on a 550-file tree is
below the process-startup noise floor (~15 ms). The parser is a fast single-pass
heuristic scan (no AST), so re-parsing is nearly free and the existing per-file
parse cache barely pays off — on tiny repos it is net-negative (blob
deserialization costs more than re-parsing). **The bottleneck is not parse
compute.** Optimize accordingly.

## 1. Cache the fully-linked graph, not just parses

Today `.navgraph/cache` stores per-file *parsed symbols*; the global link pass
(name index, import resolution, reference→target resolution, route matching,
caller inversion) is rebuilt from scratch on every invocation. A no-edit repeat
query — the common agent pattern (many queries, no edits between them) — could
skip linking entirely by restoring the whole resolved `Index`.

Keep it all-or-nothing, not dependency-tracked: if the file set + every file's
(mtime, ctime, size) are unchanged, restore the linked graph verbatim; if
*anything* changed, re-link everything. Re-link is cheap, so the coarse policy
is fine. This is the ~20-line version of "incremental" and captures most of the
realistic win without a dependency graph. Requires serializing resolved edges
(ref targets / global symbol ids), which are currently deliberately not cached —
so gate it behind a whole-graph fingerprint (file-set hash) and fall back to the
current parse-cache path on any mismatch.

## 2. Daemon mode (`navgraph serve`)

Attacks the *actual* dominant cost: process startup (~15 ms), which no amount of
caching touches. A long-lived process holds the graph in memory, watches the
tree (inotify/FSEvents), and answers queries over a socket/stdio. Amortizes
startup + walk + parse + link across every query in a session. This is the
highest-leverage speed change if latency ever matters, and it composes with (1)
(the in-memory graph is exactly the linked graph (1) would persist).

## Repo-scale accuracy pass (2026-07-07, driven by head-to-head trials)

Fixes landed after the trials showed navgraph losing repo-wide accuracy tasks to
grep. All language-general unless noted; full suite + all 7 testenv repos green,
cold==warm held.

- **Bare identifiers no longer bind to class members** (`index.zig chooseTarget`).
  A bare local `name` used to mis-resolve to a class field/property `Ctx.name`
  and inflate its fan-in (same-file collisions even bound as *exact*). Bare refs
  now resolve to top-level defs only.
- **Instance/static dispatch is resolved heuristically** (`index.zig
  resolveQualified`). A method *call* on a receiver whose type isn't inferable
  (`svc.m()`, `self.x.m()`, C++ `obj->m()`, `Scope::m()`) binds to a same-named
  method as a `?` edge, so `callers`/`unused`/`path` see it. `memberQualifier`
  now recognizes `->` and `::` so C/C++ dispatch is covered too.
- **`hot` is honest** (`query.zig`). Ranks by exact fan-in; prints the heuristic
  share as `(N ?)`; `-s` reports exact-only and hides all-heuristic symbols.
- **`unused` is high-precision, on a token count not the call graph**
  (`query.zig buildReferencedNames`). "Used anywhere" is decided by re-lexing
  every file and counting identifier tokens (ignoring comments/strings), so a use
  in a template literal, JSX, a Zig `test {}` block, module scope, or a partially
  parsed body all count. Also excludes decorated defs, `constructor`, and dunders
  (framework-invoked). This replaced the body-scoped ref set, which produced
  large false-positive lists on real TS/Python repos (a live symbol used only in
  a `test`/JSX/template site looked dead). Follow-up idea: suppress reflection-
  only entry points (alembic `upgrade`/`downgrade`, ASGI `dispatch`).
- **JSX prose apostrophes no longer swallow the file** (`lexer.zig`). In JS/TS a
  `'`/`"` glued to the end of a word (`you'll`, `don't` in JSX text) was opening
  a string that ran to the next quote — hiding every symbol and call after it.
  Now a quote right after an identifier char is treated as text (JS has no
  `b'…'`/`r'…'` prefixes, so this is safe). This was the dominant cause of TSX
  `unused`/`callers` false results on real component files.
- **C/C++ digit separators no longer swallow the file** (`lexer.zig`). `1'000`
  (or `0xFF'FF`) opened a char literal that ran to EOF, erasing every symbol in
  the file. A `'` immediately after a *number token* is now a separator; char
  prefixes `L'a'`/`u'x'` (previous token is an identifier) are untouched.
- **Dispatch is complete across the member operators of every language.**
  `memberQualifier` now recognizes `.` (all), JS/TS `?.` and `!.`
  (optional-chaining / non-null), and C/C++ `->` and `::`. Verified: an untyped-
  receiver method call resolves (as a `?` edge) in Zig, C, C++, Python, JS and
  TS. The apostrophe/digit-separator guards are the only language-specific lexer
  rules; f-string splitting is Python-only and template scanning JS-only because
  those are the only languages with the respective construct.
- **Expression-body arrows are functions** (`parser.zig`). `const C = () =>
  (<JSX>{call()})` now collects its calls instead of being an opaque variable —
  the main TS/TSX component gap.
- **Python f-string interpolations tokenize as code** (`lexer.zig`). Calls in
  `f"{fn(x)}"` are edges now. JS/TS template literals are deliberately left
  whole (see blind spots) to keep `fetch(`/x/${id}`)` route matching.

## Repo-scale accuracy pass, round 3 (2026-07-07, third trial batch)

- **`unused` surfaces test-only dead code** (`query.zig`, `RefSets`). "Used" is
  now decided over *non-test* files; a symbol reached only from tests is reported
  and annotated `(only used by tests)` (JSON `"test_only":true`) — the "no
  application caller" cleanup target a trial's grep agent won on (e.g.
  `select_planet_assured_imaging_window`, `fetch_tle_by_norad_id`). The prior
  behavior (any test reference = used) hid them. Production use still excludes.
- **Skipped directories are named on empty results** (`index.zig`,
  `query.zig skippedNote`). A pruned source dir (e.g. `testenv/`, `vendor/`) is
  recorded and, when a query returns empty, printed as `(not indexed — skipped:
  testenv/; index one with -C <dir>)` so "skipped" isn't misread as "absent" —
  the silent-failure footgun a trial hit (burned ~8 calls). Standard build/VCS/
  cache dirs are filtered out of the note to keep it high-signal.

## Repo-scale accuracy pass, round 4 (2026-07-07, fourth trial batch)

Two precision gaps a head-to-head trial (navgraph's own `src/`, and tactica)
surfaced where grep beat navgraph. Full suite + all 7 testenv repos green,
cold==warm held, no `unused` false positives (every newly-surfaced symbol
hand-verified test-only).

- **Zig inline `test {}` blocks now count as test scope** (`query.zig tallyUses`,
  `buildReferencedNames`). Python/JS keep tests in separate files (caught by
  `isTestPath`), but Zig keeps them inline, so a helper called only from a
  `test {}` block *in a production `.zig` file* was tallied as a production use
  and hidden from `unused`. `tallyUses` now tracks brace depth for Zig files and
  routes identifiers inside a `test {}` block to the test bucket, so such a helper
  is reported and annotated `(only used by tests)`. This closed the trial's §D
  loss (`firstClientCall`, `bindingType`, and ~12 other genuine test-only helpers
  in navgraph's own tree were being under-reported). `zigTestBlockStart` detects
  `test {`, `test "name" {`, and `test decltest.Foo {`. This blind spot was
  Zig-specific; the other languages already separate tests by path.
- **`callers`/`calls` list every distinct call-site line** (`model.zig`
  `Reference.lines`, `parser.zig recordRef`, `render.zig`, `query.zig
  callSiteLines`, `cache.zig`, `json_out.zig`). `recordRef` merges repeat
  references keeping only the first line + a `count`, so a caller that hit the
  target on four different lines rendered as `↳:237 ×4` — pointing at one line
  and hiding the other three (the precision a trial's grep agent won on). Each
  reference now carries the distinct lines it spans (`Reference.lines`, populated
  only when >1, so single-site refs stay allocation-free); the edge renders
  `↳:237,240,244,250` (capped at six with a `,+K` tail) and same-line repeats
  still add `×C`. JSON edges gain a `lines` array. `skipSymbol` (the cache blob
  boundary walker) was updated in lockstep with the new serialized field; the
  binary-fingerprint cache key auto-invalidates any older cache.

## Repo-scale usability pass, round 5 (2026-07-07, "AETHER" trial)

A full-repo trial (3D satellite viz: FastAPI backend + Three.js frontend) where
an agent navigated *only* through NavGraph. It audited ~90% of the repo with no
`Read`, but hit two blockers and several noise issues. All fixed; full suite +
all 7 testenv repos green, cold==warm held.

- **A source dir named `coverage` is no longer silently eaten** (`index.zig`
  `enterDir`, `soft_ignore`/`source_roots`/`underSourceRoot`). `coverage` (and
  `build`/`dist`/`target`) are build-output conventions in the ignore list, but
  they're also real source/domain dir names — the trial's `frontend/src/coverage/`
  (satellite-coverage math, the repo's highest-risk module) was pruned, so
  `search CoverageSystem` said "no symbol", `outline` never listed it, and
  `imports main` dropped its import edge — all *silently*. Now a `soft_ignore`
  name nested under a source tree (`src`/`lib`/`app`/`source`/`packages`/`pkg`)
  is indexed; only a top-level `coverage/`/`build/`/`dist/` (the actual artifact)
  is pruned. Cache-compatible (build-time, focus-independent).
- **`navgraph files` — index coverage manifest** (`query.zig listFiles`,
  `json_out.zig`). Lists every indexed file + its symbol count, so an agent can
  see what NavGraph actually parsed and catch "this file is missing / has 0
  symbols" instead of trusting a bare "not found". The diagnostic that would have
  instantly explained the `coverage/` blind spot.
- **`navgraph read <file[:A-B]>` — raw line-range reader** (`query.zig readLines`,
  `printNumbered`, `parseLineRange`). Prints numbered source lines, optionally a
  range — the escape hatch for text NavGraph doesn't model as a symbol
  (module-scope statements, config, comments, an arbitrary line). Sources bytes
  from the in-memory index when the file is indexed, else reads from disk relative
  to root, so **config and files under ignored dirs are reachable too**. Closes
  the biggest "still need Read" gap (`read` alias `cat`).
- **`outline` truncation is per-file, not tail-drop** (`query.zig outline`,
  `visibleSymbolCount`). Hitting `-l` used to `break`, dropping the header of
  every later file — so whole files vanished and an agent could conclude a file
  didn't exist (the trial lost `tle_fetcher.py`/`build_snapshot.py` this way).
  Now every matching file always prints its header; a file past the symbol budget
  shows `… N symbols here (raise -l to list)` instead of disappearing.
- **`calls`/`neighbors` hide data reads by default** (`query.zig isDataReadEdge`,
  `walkCallees`/`renderCallees`, `json_out.zig`). The callee view followed every
  resolved edge, so a `var camera`/`const EARTH_UNIT` a function merely *reads*
  showed under "↓ calls" as if invoked — noise for blast-radius reading. Now a
  bare `.read` of a `var`/`const`/`field` is hidden by default; `--refs` opts them
  back in. Reading a *function* (a callback by name) still shows — it's a real
  dependency. The graph is unchanged: `callers`/`hot`/`unused` still count every
  reference. (`--refs` now does double duty: search use-sites, and calls data
  edges.)
- **Route-linking oversell corrected in `prompt.md`.** The guide now states
  plainly that only a *literal* URL (string or `${…}` template) links; a
  `fetch(url)` whose URL is a variable/array element does not, so a client-less
  endpoint in `routes` should be `grep`-confirmed before it's called unused.

Still open from this trial (parked): **import edges to unindexed targets** —
`imports`/`importers` drop an edge whose target file isn't indexed, instead of
showing `→ path (not indexed)`; surfacing them would keep broken/ignored imports
visible. Lower priority now that the `coverage/` case (the concrete trigger) is
indexed.

## Repo-scale usability pass, round 6 (2026-07-07, "AETHER" round 2 + go-global)

Second AETHER trial (Python/JS). The explicit brief was two-part: make the
round-4/5 fixes **global across every supported language**, and land the new
feedback the same way. Audit found most prior fixes were already language-general
(call-site lines, coverage-nesting, `files`/`read`/outline-truncation, and
callables-only — `isDataReadEdge` keys on kind, not language); the one real gap
was test-scope. Full suite (87 tests) + all 7 testenv repos green (cold==warm).

- **Kind fidelity: accessor/dispatch/async modifiers** (`model.zig Mods`,
  `parser.zig`, `render.zig`, `cache.zig`, `json_out.zig`). A getter rendered as
  a bare `method _field` read as a bug in the trial. Symbols now carry a
  `Mods` byte (getter/setter/static/async/classmethod/abstract): a getter shows
  `get x`, a setter `set x`, and `static`/`async`/`classmethod`/`abstract`
  prefix the tag (`async fn boot`, `async method ApiClient.getUser`). Sourced
  from JS/TS `get`/`set`/`static`/`async` (methods, functions, arrows) and Python
  `@property`/`@staticmethod`/`@classmethod`/`@abstractmethod`/`@x.setter` +
  `async def`. `kind` is untouched (so `-k` and JSON `kind` stay stable; JSON
  gets a separate `modifiers` array). C++ `static`/`virtual` left for later.

- **`navgraph strings <pattern>` — search inside string literals** (`query.zig
  strings`, `json_out.zig`, `cli.zig`). The escape hatch the symbol graph can't
  index: URL/route literals, log/error messages, regex sources, config keys. Re-
  lexes each file and matches only `.string` tokens (so a hit is never an
  identifier that shares the text — stricter than grep), across every language.
  The named blocker "no `?`-free way to find literal/string content."

- **`search --refs` lists every distinct use-site line** (`query.zig searchRefs`,
  `json_out.zig`). A name used on several lines within one caller was deduped
  into a single ref and printed once (`ref.line`); it now expands `ref.lines`, so
  each site is a row. Fixes "found only one of its reads."

- **`def -v full` includes leading decorators/attributes** (`render.zig
  decoratorStart`). The printed slice widens upward over a contiguous run of
  `@`-lines, so a Python `@property`/FastAPI handler or a TS `@Component` is a
  complete, paste-ready Edit target.

- **Python multi-line data literals resolve** (`parser.zig tryPyAssign`). A
  module/class `NAME = [ … ]`/`{ … }`/`( … )` spanning lines now spans the whole
  literal, so `def GP_GROUPS -v full` shows its contents (value resolution) while
  `sig` stays the first line.

- **Batched `read`** (`query.zig readLines`/`printNumbered`). `read file:A-B,C-D`
  pulls several disjoint ranges in one call, `⋯` marking each gap — "symbol + its
  N neighbours" / "definition + its use" without N invocations.

- **Test scope goes global** (`query.zig isTestPath`). Was basename-only; now
  recognizes test **directories** (`tests/`, `test/`, `__tests__/`, `__mocks__/`,
  `spec/`, `e2e/`) and stem suffixes (`_test`/`_spec`/`.test`/`.spec`, any code
  ext). This is what stops a plainly-named helper under `tests/` reading as
  production and under-reporting the dead code only its siblings use — the
  language-general version of the round-4 Zig `test {}` fix.

Still parked (documented in **Known blind spots** below, unchanged by this
round): first-class data-flow (`reads`/`writes`) and full property-read recall,
module-scope reference attribution, and non-literal (variable/loop) route URLs —
each needs a synthetic module-owner or value tracking that risks regressions.

## Cross-language linking through a request wrapper (2026-07-07, DONE)

Fixed the trial T3/T8 blind spot: a frontend that funnels every call through a
generic `request(path)`/`requestVoid(path)` helper (with template-literal URLs)
produced **zero** client edges. Now (`api.zig`, `parser.zig detectWrappers`):
- A function whose body issues a fully-dynamic `` fetch(`${BASE}${path}`) `` is
  detected as a request wrapper (`isDynamicFetch` → enclosing symbol name).
- A call to a wrapper (`request("/x", { method })`) is matched as a client call,
  path + method extracted from the args (`matchWrapperCall`).
- `pathOf` skips a leading `${BASE}` interpolation, so a direct
  `` fetch(`${BASE}/logs/bundle`) `` resolves to `/logs/bundle`, and a fully
  dynamic `${BASE}${path}` resolves to nothing (the wrapper signal).

Verified on tactica: routes-with-a-frontend-caller went 0 → 48 of 127; template
GET paths link (`getJob` → `GET /planning/jobs/{job_id}`). Backend router-prefix
and the frontend's BASE-relative paths already align (navgraph doesn't apply the
`app.include_router(prefix="/api/v1")` mount, and the frontend's BASE adds it),
so no prefix reconciliation was needed.

Still open here: **cross-file wrappers** (wrapper defined in `http.ts`, used in
`client.ts`) — detection is per-file, so only same-module wrappers link (the
common case). A global wrapper-name pass in `index.zig` would extend it.

## Repo-scale accuracy pass, round 2 (2026-07-07, second trial batch)

- **`unused` no longer hides re-exported dead code** (`query.zig tallyUses`). The
  occurrence counter skipped nothing, so a name mentioned only in `module.exports
  = {…}`, `export {…}`, or `from x import …` counted as a "use" and hid a dead
  function (repro: `js_express` `count`; `callers count` was empty but `unused`
  omitted it — the two verbs disagreed). Import/export declaration *lists* are now
  skipped, EXCEPT an `X as Y` rename counts as a use of `X` (it's live via the
  alias — repro: `removeRequests as apiRemoveRequests`). A function reached only
  from tests still counts as used (it's exercised).
- **`callers` reports call-site multiplicity** (`render.zig`, `query.zig
  callSiteCount`). An edge a caller invokes N times renders `↳:line ×N` instead
  of collapsing to one — so "how many call sites" sums correctly (a trial counted
  7 when the truth was 11 because 4 calls in one function collapsed). JSON edges
  gain a `"sites"` field.

## Known blind spots (verified 2026-07-07, across all 7 testenv repos)

Documented so a trial result of "navgraph missed X" is attributable to a known
limitation, not mistaken for a regression. Smoke-tested C, C++, Python, JS, TS,
Zig, fullstack: outline/calls/callers/unused/routes all run without crashes and
cold==warm.

- **Module-scope references are not captured.** Refs are collected only from
  within a symbol body (function/method). A top-level `const client = new
  ApiClient()` (TS) or module-level use is owned by no callable, so
  `search X --refs` and `callers X` miss it. Repro: `ts_frontend`, `callers
  ApiClient` returns empty although `useUser.ts` instantiates it at module scope.
  Fix idea: attribute module-scope refs to a synthetic file-level owner so
  "find usages" and importers see them.

- **Barrel / re-export chains are not followed transitively.** `export { X }
  from './client'` in an `index.ts` barrel resolves the *barrel's* import edge
  but does not collapse `consumer → barrel → source`. Repro: `ts_frontend`,
  `importers src/api/client.ts` lists only `src/api/index.ts`, not the
  `useUser.ts` that imports through the barrel. Affects JS/TS most (barrels are
  idiomatic). Fix idea: resolve `export … from` re-exports so a name imported
  from a barrel binds to its original definition.

- **C++ out-of-line member definitions lose their class qualifier.** In a `.cpp`,
  `RetType Class::method() { … }` is emitted as a bare `fn method`, not
  `Class.method`, so it can collide by name with other members. Repro:
  `cpp_app/shapes.cpp` shows `fn area`, `fn name` (really `Shape::area`,
  `Circle::area`). Calls to it now resolve heuristically by name (dispatch fix),
  but the *definition* is still unqualified. Fix idea: parse the `Class::` prefix
  on C++ definitions and attach the member to its class.

- **C++ raw string literals `R"delim(…)delim"` are not recognized.** The lexer
  treats the interior `"` as ordinary string delimiters, so a raw string with an
  *odd* number of embedded `"` can open a literal that runs to the next quote
  (an even count self-balances, as most do). Fix idea: recognize the `R"` prefix
  (incl. `LR"`, `u8R"`, …), capture the `(`-delimited tag, and scan to
  `)tag"`. Lower priority than the digit-separator/apostrophe swallows (which any
  file with `1'000` or JSX prose triggered).

- **JS/TS template-literal interpolations are not tokenized as code.** A call
  inside `` `${formatItem(x)}` `` is invisible, because the whole template is
  kept as a single string token so `fetch(`/users/${id}`)` still matches its
  route (verified: `fullstack` links `axios.get(`/api/orders/${id}`)` to
  `/api/orders/<int:id>`). Python f-strings *are* tokenized (they aren't used as
  route URLs in the testenv, so there's nothing to protect). Fix idea: emit
  template pieces as tokens AND teach `api.zig` to reconstruct the URL (with
  `${…}` → wildcard) across the pieces, then wire up `${…}` like Python `{…}`.

## 3. Dependency-tracked incremental linking (salsa-grade)

The full incremental-compilation approach: maintain and persist a reverse-
dependency graph so that when file A changes, only the edges that actually
depend on A's symbols are invalidated and recomputed. This is what rust-analyzer
(salsa) and Zig's incremental backend do — thousands of lines, significant
tuning.

**Defer until profiling demands it.** Only worth it at ~100× current scale
(million-symbol monorepos) AND in a persistent per-keystroke process (i.e. only
after (2) exists). For a short-lived per-query CLI, startup dominates any linking
savings, so this optimizes something that isn't on the critical path.
