# Using NavGraph (agent guide)

NavGraph is a code-graph navigator. It parses the repo into a symbol graph and
prints dense, low-token, **directly actionable** views. Prefer it over
`grep`/`read` for locating code, understanding structure and relationships, and
**fetching the exact source you're about to change** — often you can go straight
from NavGraph to `Edit`/`Write` without a separate `Read`.

Binary: `navgraph`. Runs from a repo root (or point it with `-C <root>`). It
**recursively indexes the whole tree** under the root, skipping `.git`,
`node_modules`, `zig-out`, `__pycache__`, `dist`, `build`, `vendor`, etc. A
build-output name that sits **inside a source tree** (`frontend/src/coverage/`,
`app/build/`) is treated as real source and indexed anyway — only a top-level
`coverage/`/`build/`/`dist/` (the actual artifact) is pruned. It also **honors
`.gitignore`**: any file or directory a `.gitignore` excludes is skipped (nested
per-directory files, negation with `!`, and `*`/`?`/`**` globs are all
respected), so the index tracks what git tracks. Run `navgraph files` to see
exactly what got indexed, and if a query comes back empty check there first — an
empty result plus a `(not indexed — skipped: …)` note means the code lives in a
pruned subtree, not that it's absent.
Languages: Zig, C/C++, C#, Python, JavaScript, TypeScript, TSX.

## Edit without reading first

This is the intended loop. `def <name> -v full` prints the **byte-exact source**
of a definition (a verbatim slice of the file), so you can construct an `Edit`
directly from its output — no `Read` step.

- **Change a function/method/class:**
  `navgraph def <name> -v full` → copy the exact snippet you want to change into
  `Edit`'s `old_string` → write `new_string`. The body is verbatim, so the match
  is reliable. **Leading decorators/attributes are included** (a Python
  `@property`/FastAPI handler shows its decorators, a TS `@Component` its
  annotation), so the snippet is a complete, paste-ready target. A `const`/`var`
  bound to a multi-line array/dict/object literal shows the **whole literal**, so
  `def GP_GROUPS -v full` resolves its contents. (Ignore the one-line `kind name
  path:line` header and any trailing blank line — your `old_string` is a snippet
  from inside the body.)

- **Change how/where something is called** (edit each call site):
  `navgraph callers <name>` lists every **enclosing function** that calls it,
  each with its `path:start-end` range and the call-site line `↳:N`. For each
  one, `navgraph def <caller> -v full` gives that function's verbatim source to
  edit. Still no `Read`.

- **Add new code in the right place:**
  `navgraph outline <file>` for the file's structure + line ranges, and
  `navgraph def <neighbor> -v full` to match surrounding style/imports, then
  `Edit`/`Write`.

When you genuinely need raw text NavGraph can't attribute to a symbol (module
top-level statements, config, comments, a specific arbitrary line), use
`navgraph read <file>` — it prints numbered source lines. `read <file:A-B>`
prints one range, and `read <file:A-B,C-D>` **several disjoint ranges** in one
call (a `⋯` marks each gap). It works on **any** file, including config and
files in skipped dirs (it falls back to a disk read), so you can stay in
NavGraph instead of switching to `Read` for non-symbol text.

To find **text inside string literals** — a URL/route, a log or error message, a
regex source, a config key, a feature-flag name — use `navgraph strings
<pattern>`. It matches only inside string tokens across every language (so a hit
is never an identifier that merely shares the text), printing `path:line: <the
literal>`. This is the verb for the content the symbol graph can't index. See
**Blind spots** below.

## Reading locations

Every symbol prints as `path:start-end` (1-based, inclusive) — e.g.
`app/routes/users.py:18-21`. In call trees each edge also shows its **call-site
line(s)** as `↳:N` (the line where the call happens, in the *caller*); when a
caller invokes the target on several **distinct** lines they are all listed —
`↳:120,140,155` (capped at six, with a `,+K` overflow tail for very hot edges) —
so you can jump to every call site, not just the first. Repeated calls on a
single line add a `×C` multiplier (`↳:42 ×3`), so `callers` is function-granular
but never *under*-counts its call sites. A
trailing **`?`** marks a **heuristic edge** — one resolved by a name match
rather than a traceable receiver/type. Two things produce `?` edges: a bare name
with several same-named definitions, and a **method call on a receiver whose
type isn't known** (`svc.create_run()`, `self.x.create_run()`, `obj->run()`,
`Scope::run()`) — these are matched to a same-named method so instance/static
dispatch stays visible, but only as a guess. Treat `?` edges as "probably,
verify"; drop them entirely with `-s`. Unresolved calls are listed on a
`~ ext:` line (a call NavGraph could not bind — e.g. a builtin, an untracked
value, or `getattr`/reflection).

Three trust tiers, so you know when to double-check:
`exact` (unmarked) → trust · `?` → verify or `-s` · `~ ext:` → NavGraph can't
see it, use `grep`/`Read`.

**Modifiers.** A symbol's kind field carries accessor/dispatch/async modifiers so
you don't misread it: a getter renders as `get x` and a setter as `set x` (not a
bare `method x`), and `static`/`async`/`classmethod`/`abstract` prefix the tag
(`async fn boot`, `static get make`, `classmethod method build`). These come from
JS/TS `get`/`set`/`static`/`async`, Python `@property`/`@staticmethod`/
`@classmethod`/`@abstractmethod` and `async def`. The underlying `kind` is
unchanged, so `-k method` still matches a getter and the JSON `kind` is stable
(modifiers appear in a separate JSON `modifiers` array).

When a `calls`/`callers` tree contains any `?` edges it ends with a one-line
footer telling you how many and reminding you to re-run with `-s` to drop them —
so you never have to eyeball a large tree to decide whether it's fully trusted.

Two views are built to be trustworthy at repo scale:

- **`hot`** ranks by *confident* (exact) fan-in, so a symbol whose callers are
  only name-match guesses can't float to the top. A count with a heuristic
  share prints it as `←42 callers (30 ?)`; `-s` reports exact-only and hides
  symbols whose connectivity is entirely heuristic. Don't read a bare `?`-share
  count as ground truth.
- **`unused`** reports a callable with no **production** caller — decided by a
  repo-wide identifier-token count over non-test files (comments and strings
  excluded), not by the resolved call graph. So a use inside a template literal,
  JSX, module scope, or a partially-parsed body still keeps a symbol off the
  list; a name only in an `import`/`export`/`module.exports` list is a *mention*,
  not a use (a re-exported-but-uncalled function IS reported; an `X as Y` rename
  counts as a use of `X`). A symbol reached **only from tests** is reported and
  annotated `(only used by tests)`, the real cleanup target, separately from
  truly-unreferenced code. Test scope is recognized across languages by file
  convention (`test_*.py`, `*.test.ts`, `*_test.zig`, `*_test.cc`, …), by
  **directory** (`tests/`, `__tests__/`, `spec/`, `e2e/` — so a plainly-named
  helper under a test dir counts too), and — in Zig — by an inline `test {}`
  block in the same production file. Decorated definitions,
  dunder/`constructor` methods, and `main` are treated as invoked.
  It won't flag production-live code; the cost is recall (a dead name colliding
  with a live one is skipped). Framework entry points reached only by reflection
  (alembic `upgrade`/`downgrade`, ASGI middleware `dispatch`) can still appear —
  strictly, they are never called by name. Verify a candidate with `callers`.
  Two flags **narrow the list toward genuinely-dead code**: `--no-public` drops
  exported symbols (they may be public API you can't delete), and `--no-test`
  drops the `(only used by tests)` names (they *are* used, just by tests). Pass
  **both** to get only symbols referenced nowhere — the actually-unused set.

## Commands

| You want to know…                                   | Command |
|-----------------------------------------------------|---------|
| What's in this file / dir (structure + line ranges) | `navgraph outline [path]` |
| Where is X defined + signature                      | `navgraph def <name>` |
| The **exact source** of X (to edit it)              | `navgraph def <name> -v full` |
| What does X call/use (its dependencies)             | `navgraph calls <name> -d <depth>` |
| Who calls/uses X (blast radius before a change)     | `navgraph callers <name> -d <depth>` |
| Callees **and** callers of X in one view            | `navgraph neighbors <name>` |
| The load-bearing symbols (rank by fan-in/out)       | `navgraph hot [path]` |
| Find a symbol by name fragment                      | `navgraph search <fragment>` |
| Find **use sites** of a name (every site, structural)| `navgraph search <fragment> --refs` |
| Find text **inside string literals** (URLs, logs, regexes) | `navgraph strings <pattern>` |
| The HTTP API surface + who calls each endpoint      | `navgraph routes [filter]` |
| Possible dead code (functions with no callers)      | `navgraph unused [filter]` |
| **Actually-unused** code (no callers, not API, not test-only) | `navgraph unused --no-public --no-test` |
| What a file imports / who imports a file            | `navgraph imports [filter]` · `navgraph importers <file>` |
| Shortest call path from A to B                      | `navgraph path <A> <B>` |
| **Every indexed file + its symbol count** (coverage)| `navgraph files [filter]` |
| **Raw source lines** of any file (non-symbol text)  | `navgraph read <file[:A-B[,C-D]]>` |

## Flags

Flags come **after** the command (`navgraph outline src -v full`, not
`navgraph -v full outline`). Values may be attached (`-d2`, `--depth=2`).

- `-v names|sig|doc|full` — detail (default `sig`). `full` = **verbatim source**;
  `doc` = leading doc comment.
- `-d N` — call-graph depth for `calls`/`callers` (default `1`).
- `-k, --kind k1,k2` — restrict `outline`/`search` to kinds (`fn`, `method`,
  `class`, `struct`, `route`, …).
- `-r, --refs` — for `search`, match **use sites** (every distinct use-site
  line, not just definition names — a name used on several lines in one caller
  lists each site); for `calls`/`neighbors`, **also include data reads** (a
  `var`/`const`/`field`
  the symbol reads). By default the callee view shows only calls and type
  dependencies — a `const LIMIT` or module `var` a function merely reads is
  hidden as dependency noise. Use `--refs` when you want those data edges too.
  (This filters only the callee *view*; `callers`, `hot` and `unused` always
  count every reference, reads included.)
- `-C <path>` — repo root to index (default `.`). Point it at the real project
  root so it doesn't walk unrelated trees.
- `-l N` — cap results (default `300`). Output tells you when it truncated.
- `-s, --strict` — `calls`/`callers` follow only high-confidence edges (no `?`).
- `--no-public` — for `unused`, drop exported symbols (possible public API).
- `--no-test` — for `unused`, drop symbols used only by tests. Combine with
  `--no-public` to report only the symbols referenced nowhere.
- `-j, --json` — stable JSON (for tooling/MCP). Edges carry `site` (first
  call-site line), `sites` (count), `lines` (every distinct call-site line, when
  more than one), `line`/`line_end`, and `"exact":false` on heuristic edges.
- `--no-cache` — ignore `.navgraph/cache` and rebuild. Use this if you ever
  suspect a stale answer.

## Disambiguating names

- `Parent.name` — a method by its class (`UserService.create`, `Ctx.isPunct`).
- `name@path` — a same-named symbol by file (`run@other.zig`, `build@build.zig`).
  Bare `name` returns all matches.

## Cross-language API links

NavGraph links HTTP **route definitions** (FastAPI/Flask `@app.get`, Express
`app.get(...)`, `APIRouter(prefix=…)` mounts included) to **client calls**
(`fetch`, `axios`, `requests`) by method + path. It also follows a **generic
request wrapper**: a function whose body does `` fetch(`${BASE}${path}`) `` is
recognized, so a frontend that routes everything through `request("/users/1")`
(instead of a literal `fetch`) still links — the call to the wrapper is treated
as the client call, and a `${BASE}` URL prefix is stripped when matching. So a
frontend `fetch("/users/1")` **or** `request(`/users/${id}`)` shows up as a call
into `GET /users/{id}` and on to its handler:

```
navgraph routes                 # every endpoint + handler + the clients that hit it
navgraph calls loadUser -d 3    # frontend fetch → route → backend handler
navgraph callers get_user       # who (any language) hits this endpoint
```

**The path must be a literal** (a string or a template with `${…}`
placeholders). A call whose URL is a *variable* — `` fetch(url) `` where `url`
came from an array or was computed — does **not** link, and the endpoint shows
with zero clients even though a caller exists. When `routes` reports an endpoint
as client-less, confirm with `grep` before concluding it's unused from the
frontend: the client may just build its URL dynamically.

## Speed & freshness

NavGraph writes an incremental cache to `.navgraph/cache`, keyed per file by
(mtime, ctime, size) — only changed files are re-parsed. The cache is also
stamped with a fingerprint of the NavGraph binary itself, so **upgrading
NavGraph auto-invalidates a cache built by an older version** (no stale results
after a parser fix). The cache is safe to delete, regenerates on next run, and
should be gitignored (`.navgraph/`).

## Why it beats grep/read here

- **Real edges, not text hits.** `callers`/`calls` resolve actual references —
  nothing inside comments/strings, no substring false positives
  (`emit` vs `emitZigContainer`).
- **Attribution.** A call site is reported as its *enclosing function* with a
  signature and the exact `↳` line — you know *who* calls and *where*.
- **Actionable.** `path:start-end` + `-v full` verbatim source means you can
  edit straight from NavGraph output.
- **Token-frugal.** `outline` is several times smaller than reading the file;
  depth/verbosity/`--kind` fetch exactly what you need.

## Blind spots — when to still use grep/read

NavGraph is honest about what it can't see; reach for `grep`/`Read` for:

- **String-literal content** (URLs, log/error text, regexes) is searchable with
  `navgraph strings <pattern>`; for **comments, TODOs and config** use `navgraph
  read`/`grep`.
- **Module top-level statements:** references made outside any function body
  (e.g. a TS `const client = new ApiClient()` at module scope, or a
  `for (const url of urls) fetch(url)` loop) are not attributed to a caller, so
  `callers`/`search --refs` can miss them — `grep`/`Read` for those.
- **Barrel / re-export chains:** `export { X } from './x'` indirection is not
  followed transitively, so `importers`/edges can under-report consumers that
  import through an `index.ts` barrel.
- **Dynamic dispatch / untracked receivers:** a method *call* on an unknown
  receiver is resolved to a same-named method as a `?` guess (so it stays
  visible); but `getattr`/reflection, a callback passed as a value, or a
  computed method name still fall through to `~ ext:`. A `?` edge is a guess;
  verify it if it matters.
- **JS/TS template-literal calls:** a call inside `` `${fn()}` `` is not
  captured (the whole template is kept as one string so `fetch(`/x/${id}`)`
  still matches its route). Python f-string interpolations *are* captured. Use
  `grep` for a call that lives only inside a JS template literal.
- **C++ out-of-line member definitions:** `RetType Class::method(){…}` in a
  `.cpp` currently shows as a bare `method`, not `Class.method` (calls to it
  still resolve heuristically by name).
- Languages NavGraph doesn't parse yet.

## Recommended workflow

1. `navgraph outline` (or `outline <subdir>`) — lay of the land.
2. `navgraph search <fragment>` (add `--refs` for use sites) — locate the symbol.
3. `navgraph def <name> -v full` — get its **exact source** to edit.
4. `navgraph callers <name>` before changing it — blast radius; each caller is a
   `def … -v full` away from being editable too.
5. `navgraph calls <name> -d 2` — trace dependencies; `navgraph hot` — find the
   load-bearing symbols worth reading first.
