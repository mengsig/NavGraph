# Using NavGraph (agent guide)

NavGraph is a code-graph navigator. Prefer it over `grep`/`read` for
**understanding structure and relationships** in a codebase. It parses the repo
into a symbol graph and prints dense, low-token views.

Binary: `navgraph`. Runs from a repo root (or point it with `-C <root>`). It
**recursively indexes the whole tree** under the root, skipping `.git`,
`node_modules`, `zig-out`, `__pycache__`, `dist`, `build`, `vendor`, etc.
Languages: Zig, C/C++, Python, JavaScript, TypeScript, TSX.

## When to use which command

| You want to know…                                   | Command |
|-----------------------------------------------------|---------|
| What's in this file / dir (a structural map)        | `navgraph outline [path]` |
| Where is X defined + its signature                  | `navgraph def <name>` |
| What does X call/use (its dependencies)             | `navgraph calls <name> -d <depth>` |
| Who calls/uses X (impact of changing it)            | `navgraph callers <name> -d <depth>` |
| Find a symbol by name fragment across the repo      | `navgraph search <fragment>` |
| The HTTP API surface + who calls each endpoint       | `navgraph routes [filter]` |
| Callees **and** callers of X in one view             | `navgraph neighbors <name>` |
| Possible dead code (functions with no callers)       | `navgraph unused [filter]` |
| What a file imports / who imports a file             | `navgraph imports [filter]` · `navgraph importers <file>` |
| Shortest call path from A to B                       | `navgraph path <A> <B>` |

## Flags

- `-v names|sig|doc|full` — detail level (default `sig`). Use `full` to read a
  definition's source; `doc` to see the leading doc comment.
- `-d N` — call-graph depth for `calls`/`callers` (default `1`).
- `-C <path>` — repo root to index (default `.`). **Point this at the actual
  project root** so it doesn't walk unrelated trees.
- `-l N` — cap results (default `300`).
- `-s/--strict` — for `calls`/`callers`, follow only high-confidence edges
  (type/receiver-bound or unambiguous). Use it when you want zero false edges.
- `-j/--json` — emit JSON instead of the compact text (stable schema for
  tooling/MCP; list verbs → arrays, `calls`/`callers` → call-tree roots).
- `--no-cache` — ignore `.navgraph/cache` and rebuild from scratch.

Flags come **after** the command (e.g. `navgraph outline src -v full`, not
`navgraph -v full outline`).

## Speed

NavGraph writes an incremental cache to `.navgraph/cache` (keyed by file
mtime + size). Repeat calls only re-parse files that changed — typically several
times faster on a warm cache. The cache is safe to delete and is regenerated on
the next run; add `.navgraph/` to `.gitignore`.

## Argument meaning per command

- `outline [path]` → a **path filter** (file or subdir prefix). Whole project if omitted.
- `def/calls/callers <name>` → a **symbol name**. Disambiguate a method with
  `Parent.name` (e.g. `Server.start`, `Ctx.isPunct`).
- `search <fragment>` → **substring** matched against symbol names.

## Recommended workflow

1. `navgraph outline` (or `outline <subdir>`) to get the lay of the land.
2. `navgraph search <fragment>` to locate the symbol you care about.
3. `navgraph def <name> -v full` to read just that definition.
4. `navgraph calls <name> -d 2` to trace what it depends on;
   `navgraph callers <name>` before you change it, to see the blast radius.

## Cross-language API links

NavGraph recognizes HTTP **route definitions** (FastAPI/Flask `@app.get`,
Express `app.get(...)`) and **client calls** (`fetch`, `axios`, `requests`) and
links them by method + path. So a frontend `fetch("/users/1")` shows up as a
call into the backend route `GET /users/{id}` and on to its handler:

```
navgraph routes                 # every endpoint + its handler + the clients that hit it
navgraph calls loadUser -d 3    # frontend fetch → route → backend handler
navgraph callers get_user       # who (any language) calls this endpoint
```

## Why it beats grep/read here

- **Real edges, not text hits.** `callers`/`calls` resolve actual references —
  no matches inside comments/strings, no substring false positives
  (`emit` vs `emitZigContainer`).
- **Attribution.** Each call site is reported as its *enclosing function* with a
  signature, not a bare line number — so you know *who* calls, not just *where*.
- **Token-frugal.** `outline` is several times smaller than reading the file;
  depth/verbosity let you fetch exactly what you need.

## When to still use grep/read

- Non-symbol text: string literals, config, comments, TODOs, log messages.
- Languages NavGraph doesn't parse yet.
- Exact-line edits (use `read`/`edit` once NavGraph has located the symbol).

## Caveats

- Resolution is **type-scoped** for member calls (`recv.name()`): the receiver's
  type is inferred from `self`/`this`, typed parameters, and local
  `const/var/let` initializers. When the receiver type is unknown the edge is
  left external rather than guessed — so a stdlib `x.deinit()` no longer
  resolves to a same-named project symbol. Bare `name()` calls still use a
  heuristic global match (shown by default; hidden under `--strict`).
- **Module-qualified calls resolve** through imports: `mod.func()` binds to the
  imported file's `func` (Zig `@import`, JS/TS relative imports, Python
  `import mod`). So `callers`, `unused`, and `imports`/`importers` see across
  files. Calls on values whose type isn't tracked (e.g. an enum method
  `x.tag()`) still fall through to external, so `unused` can list a used-but-
  untracked method — exported entries are marked as possible public API.
- Callee trees follow **calls** only; `callers` includes all references
  (calls + reads), so it's the right tool for "who uses this variable/type".
