# navgraph: required tool for code navigation

`navgraph` (`~/.local/bin/navgraph`) is a code-graph CLI that returns *semantic
structure* — symbols, signatures, call/import graph — not raw text. One call
replaces a whole grep-then-read-many-files loop, so it is far more
token-efficient. **For any file in a supported language, using it is mandatory.**

**Supported:** Python (`.py .pyi`), JS (`.js .jsx .mjs .cjs`), TS (`.ts .tsx
.mts`), Zig (`.zig`), C (`.c .h`), C++ (`.cpp .hpp .cc .cxx .hh`), C# (`.cs`),
Lua (`.lua`), Go (`.go`), Rust (`.rs`), Ruby (`.rb`). Anything else (Java,
Kotlin, Swift, Elixir, shell, config, markdown) → grep/read.

## The rule

On supported code you may NOT `read` a whole file, `cat`, or `grep` for a symbol
as your way of understanding it. Reach for navgraph first. Only after it points
you at specific lines may you `read` those exact lines.

| Instead of… | Use |
| --- | --- |
| Reading a file for its structure | `navgraph outline <path>` (`-k class/struct` for containers) |
| Reading a function body | `navgraph def <name>` (`-v full` for source) |
| Grabbing scattered ranges | `navgraph read file:A-B,C-D` |
| grep for a definition | `navgraph def <name>` / `search <name>` |
| grep -r for who uses a symbol | `navgraph callers <name>` (or `search <name> --refs`) |
| Tracing what a function does | `navgraph calls <name>` (`-d2` deeper) |
| A function + its callers | `navgraph neighbors <name>` |
| How A reaches B | `navgraph path <A> <B>` |
| Guessing what matters | `navgraph hot [path]` |
| Scoping a branch's changes | `navgraph diff [ref]` (default HEAD, + callers) |
| Finding dead code | `navgraph unused [filter]` (`--no-public` hides API) |
| Which tests hit a symbol | `navgraph callers <name> --tests-only` |
| Test reach / coverage | `navgraph coverage [path]` |
| Visual codebase map | `navgraph graph [path] > graph.html` (offline interactive) |
| Mapping an HTTP endpoint | `navgraph routes [filter]` (cross-language) |
| Tracing a bus/WS event | `navgraph events [filter]` (cross-language) |
| Reading imports | `navgraph imports [filter]` / `importers <file>` |
| grep inside string literals | `navgraph strings <pattern>` |
| Listing indexed files | `navgraph files [filter]` (`--sort symbols`) |

## Combine with unix tools (pipe, don't substitute)

navgraph owns symbols/graph; unix tools only filter its output. Flags go *after*
the command+arg. `navgraph outline | grep -A3 Type`, `callers foo | wc -l`, `-j`
→ pipe to `jq`. Use grep only as a *locator* for a string fragment, then switch
to navgraph to understand it.

## Escape hatches (the only skips allowed)

1. Unsupported language/filetype.
2. Non-symbol content (comments, config, docs) — but strings in supported source
   still → `navgraph strings`.
3. You're editing and need the exact surrounding lines navgraph already located.
4. navgraph genuinely can't answer (ran the right command, got nothing useful,
   e.g. a dynamic/reflected call) — say so.

"Faster to just read it" is not a hatch. If you skip navgraph, name the hatch.

## Efficiency tips

- `outline` already gives file:line — don't `def X` just to locate X.
- Start container questions with `outline <file> -k class` — the inheritance
  clause is on the container line.
- On a hub function use `-s` early; heuristic `?` edges are noise.
- `path A B` beats `calls A -d3` for "how does A reach B".
- Trust the JSON `parent` field for "which class owns this method".
- Go: package-qualified calls resolve exactly; pin methods as `Type.method`; a
  shared name prints an N-definitions banner — pin it.

## Key flags

- `-v names|sig|doc|full` — detail (default sig).
- `-d N` — graph depth for calls/callers/neighbors (default 1).
- `-k fn,struct,…` — restrict outline/search kinds.
- `-s`/`--strict` — only high-confidence edges (a trailing `?` = heuristic).
- `-l N`/`--limit` (default 300); `-r`/`--refs` — include use sites/reads.
- `-t`/`--tests <with|without|only>` (aliases `--no-tests`, `--tests-only`) —
  test scope for outline/search/callers/hot/unused; default `with`.
- `-C <path>` — index root (subtree or a single file).
- `-j`/`--json` — stable JSON. `--sort path|symbols` (files).
- `--no-cache` — rebuild (`.navgraph/cache`); run after updating navgraph or big
  refactors. `--follow-imports` (unused) — disambiguate same-name symbols.

## Cross-package & cross-language

Edges resolve across monorepo packages (import-resolved, not name-matched), so
`unused`/`callers`/`path` are trustworthy across `apps/*`+`packages/*`. `routes`
(HTTP) and `events` (bus/WS) bridge across languages, pairing e.g. a Python
handler with the TS call that hits it.

## Gotchas

- Respects `.gitignore` + a fixed skip set (node_modules, .git, dist, build,
  target, vendor, .venv, __pycache__, .next, zig-out, coverage, site-packages).
  `.navgraphignore` adds navgraph-only ignores; `!vendor/` re-includes.
- `*` = globs (`def 'Ba*'`, `files '*_test.py'`); anchored on the whole name;
  no `*` = substring match; quote them. `search -e` demands exact name equality.
- Exit codes: 0 found, 1 ran-but-empty, 2 usage error.
- Misses print `did you mean:` / ambiguous prints `pin with Parent.name`.
- Minified/bundled files are skipped and named in a note.
- `outline`/`files` take `--no-recurse` (this dir only).
- Go interface dispatch isn't guessed — stays external; `unused` annotates
  possible-dispatch names, verify before deleting.
- `path A B` "no call path" is a real answer, not a failure.
- Don't gauge "is X indexed?" with `search X | wc -l` — the not-found message is
  one line too; read the actual output.
- Inline non-Zig tests (e.g. Rust `#[cfg(test)] mod tests`) aren't detected as
  tests — treated as production, so `--tests-only`/`coverage` miss them.
