# Using NavGraph (agent guide)

NavGraph is a code-graph navigator. It parses the repo into a symbol graph and
prints dense, low-token, **directly actionable** views. Prefer it over
`grep`/`read` for locating code, understanding structure and relationships, and
**fetching the exact source you're about to change** — often you can go straight
from NavGraph to `Edit`/`Write` without a separate `Read`.

Binary: `navgraph`. Runs from a repo root (or point it with `-C <root>`). It
**recursively indexes the whole tree** under the root, skipping `.git`,
`node_modules`, `zig-out`, `__pycache__`, `dist`, `build`, `vendor`, etc.
Languages: Zig, C/C++, Python, JavaScript, TypeScript, TSX.

## Edit without reading first

This is the intended loop. `def <name> -v full` prints the **byte-exact source**
of a definition (a verbatim slice of the file), so you can construct an `Edit`
directly from its output — no `Read` step.

- **Change a function/method/class:**
  `navgraph def <name> -v full` → copy the exact snippet you want to change into
  `Edit`'s `old_string` → write `new_string`. The body is verbatim, so the match
  is reliable. (Ignore the one-line `kind name  path:line` header and any
  trailing blank line — your `old_string` is a snippet from inside the body.)

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
top-level statements, config, comments, a specific arbitrary line), fall back to
`Read`/`grep` — see **Blind spots** below.

## Reading locations

Every symbol prints as `path:start-end` (1-based, inclusive) — e.g.
`app/routes/users.py:18-21`. In call trees each edge also shows the **call-site
line** as `↳:N` (the line where the call happens, in the *caller*), and a
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

When a `calls`/`callers` tree contains any `?` edges it ends with a one-line
footer telling you how many and reminding you to re-run with `-s` to drop them —
so you never have to eyeball a large tree to decide whether it's fully trusted.

Two views are built to be trustworthy at repo scale:

- **`hot`** ranks by *confident* (exact) fan-in, so a symbol whose callers are
  only name-match guesses can't float to the top. A count with a heuristic
  share prints it as `←42 callers (30 ?)`; `-s` reports exact-only and hides
  symbols whose connectivity is entirely heuristic. Don't read a bare `?`-share
  count as ground truth.
- **`unused`** reports a callable only when its name appears **nowhere else** in
  the repo — decided by a repo-wide identifier-token count (comments and strings
  excluded), not by the resolved call graph. So a use inside a template literal,
  JSX, a Zig `test {}` block, module scope, or a body NavGraph parses only
  partially still keeps a symbol off the list. It's high-precision (what it lists
  is very likely dead) and won't flag live code, at the cost of recall (a dead
  name colliding with a live one elsewhere is skipped). Decorated definitions,
  dunder/`constructor` methods, and test files are treated as invoked. Note:
  framework entry points reached only by reflection (alembic `upgrade`/
  `downgrade`, ASGI middleware `dispatch`) can still appear — they are, strictly,
  never called by name.

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
| Find **use sites** of a name (structural grep)      | `navgraph search <fragment> --refs` |
| The HTTP API surface + who calls each endpoint      | `navgraph routes [filter]` |
| Possible dead code (functions with no callers)      | `navgraph unused [filter]` |
| What a file imports / who imports a file            | `navgraph imports [filter]` · `navgraph importers <file>` |
| Shortest call path from A to B                      | `navgraph path <A> <B>` |

## Flags

Flags come **after** the command (`navgraph outline src -v full`, not
`navgraph -v full outline`). Values may be attached (`-d2`, `--depth=2`).

- `-v names|sig|doc|full` — detail (default `sig`). `full` = **verbatim source**;
  `doc` = leading doc comment.
- `-d N` — call-graph depth for `calls`/`callers` (default `1`).
- `-k, --kind k1,k2` — restrict `outline`/`search` to kinds (`fn`, `method`,
  `class`, `struct`, `route`, …).
- `-r, --refs` — `search` matches **use sites**, not just definition names.
- `-C <path>` — repo root to index (default `.`). Point it at the real project
  root so it doesn't walk unrelated trees.
- `-l N` — cap results (default `300`). Output tells you when it truncated.
- `-s, --strict` — `calls`/`callers` follow only high-confidence edges (no `?`).
- `-j, --json` — stable JSON (for tooling/MCP). Edges carry `site` (call-site
  line), `line`/`line_end`, and `"exact":false` on heuristic edges.
- `--no-cache` — ignore `.navgraph/cache` and rebuild. Use this if you ever
  suspect a stale answer.

## Disambiguating names

- `Parent.name` — a method by its class (`UserService.create`, `Ctx.isPunct`).
- `name@path` — a same-named symbol by file (`run@other.zig`, `build@build.zig`).
  Bare `name` returns all matches.

## Cross-language API links

NavGraph links HTTP **route definitions** (FastAPI/Flask `@app.get`, Express
`app.get(...)`, `APIRouter(prefix=…)` mounts included) to **client calls**
(`fetch`, `axios`, `requests`) by method + path. So a frontend
`fetch("/users/1")` shows up as a call into `GET /users/{id}` and on to its
handler:

```
navgraph routes                 # every endpoint + handler + the clients that hit it
navgraph calls loadUser -d 3    # frontend fetch → route → backend handler
navgraph callers get_user       # who (any language) hits this endpoint
```

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

- **Non-symbol text:** string literals, config, comments, TODOs, log messages.
- **Module top-level statements:** references made outside any function body
  (e.g. a TS `const client = new ApiClient()` at module scope) are not attributed
  to a caller, so `callers`/`search --refs` can miss them.
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
