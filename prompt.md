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
| Who writes/reads a value | `navgraph flow <symbol>` (`--to <sink>` traces the handoff) |
| Finding duplicate names | `navgraph collisions [pattern]` (`--members` includes members) |
| Guessing what matters | `navgraph hot [path]` |
| Scoping a branch's changes | `navgraph diff [ref]` (default HEAD, + callers) |
| Finding dead code | `navgraph unused [filter]` (`--no-public` hides API) |
| Which tests hit a symbol | `navgraph callers <name> --tests-only` |
| Test reach / coverage | `navgraph coverage [path]` |
| Visual codebase map | `navgraph graph [path] > graph.html` (offline interactive) |
| Mapping an HTTP endpoint | `navgraph routes [filter] --clients` (mounted prefixes + cross-language callers) |
| Finding dead/unserved API edges | `navgraph routes --unhit` / `routes --orphan-calls` |
| Auditing a port or sibling adapters | `navgraph conforms <Protocol|*Glob|Type.method>` |
| Crossing Protocol/interface dispatch | add `--impls` to `calls`/`callers`/`neighbors`/`path` |
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
- On a hub function use `-s` early; heuristic `?` edges are noise. For a
  Protocol/interface boundary, first use `--impls`; combine it with `-s` only
  when you intentionally want nominal/exact implementations and can drop
  structural matches.
- Use `conforms Port` instead of outlining every adapter and diffing signatures;
  use a class/method glob for a sibling divergence matrix.
- `path A B` beats `calls A -d3` for "how does A reach B". Use `flow field`
  when the missing link is a write/read handoff rather than a call; add
  `--to sink` for the producer-to-consumer chain.
- Use `outline src -k fn --sort span -l 10` for largest-definition audits and
  `collisions` instead of dumping names through `sort | uniq -d`.
- Trust the JSON `parent` field for "which class owns this method".
- Go: package-qualified calls resolve exactly; pin methods as `Type.method`; a
  shared name prints an N-definitions banner — pin it.

## Key flags

- `-v names|sig|doc|full` — detail (default sig).
- `-d N` — graph depth for calls/callers/neighbors (default 1).
- `-k fn,struct,…` — restrict outline/search kinds.
- `-p`/`--vis public|private|all` — visibility for outline/search/def; shortcuts
  `--public`, `--private`, `--no-private`.
- `-i`/`--impls` — cross Protocol/interface ↔ implementation edges in
  calls/callers/neighbors/path; structural links are heuristic and `-s` drops them.
- `-s`/`--strict` — only high-confidence edges (a trailing `?` = heuristic).
- `-l N`/`--limit` (default 300); `-r`/`--refs` — include use sites/reads.
- `-t`/`--tests <with|without|only>` (aliases `--no-tests`, `--tests-only`) —
  test scope for outline/search/callers/hot/unused; default `with`.
- `-C <path>` — index root (subtree or a single file).
- `-j`/`--json` — stable JSON. `files --sort path|symbols`; `outline`/`search`
  accept `line|name|span|callers|callees`; `hot` accepts
  `fan_in|fan_in_exact|fan_out|fan_out_exact|span`.
- Directional references: `-w`/`--writers`, `--readers`, `-u`/`--unread`, and
  `--on-type Type` apply to `flow` or `search --refs`; rows are tagged `[w]`/`[r]`.
- Duplicate audit: `search PAT --duplicates`; `collisions --members` includes
  methods and fields.
- Route views: `--clients`, `--unhit`, `--orphan-calls`, and
  `--handler <glob>`. Literal imported FastAPI `include_router` prefixes are
  applied automatically before route/client matching.
- `--no-cache` — rebuild (`.navgraph/cache`); run after updating navgraph or big
  refactors. `--follow-imports` (unused) — disambiguate same-name symbols.

## Cross-package & cross-language

Edges resolve within the relevant language family, with receiver/type and import
context used where NavGraph can establish it; unresolved or ambiguous cases stay
external or are marked heuristic rather than being globally guessed. `--impls`
adds a separate, query-local Protocol/interface dispatch graph. `routes` (HTTP)
and `events` (bus/WS) bridge across languages, pairing e.g. a mounted Python
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
- Go interface dispatch and other Protocol/interface dispatch is not included by
  default; add `--impls`. Structural matches carry `?`, may over-match generic
  single-method ports, and are removed by `--strict`.
- A `navgraph: parse-health:` stderr warning means an unterminated string caused
  tokenizer desynchronization; symbols in the named line range may be missing.
- `path A B` "no call path" is a real answer, not a failure.
- Don't gauge "is X indexed?" with `search X | wc -l` — the not-found message is
  one line too; read the actual output.
- Inline non-Zig tests (e.g. Rust `#[cfg(test)] mod tests`) aren't detected as
  tests — treated as production, so `--tests-only`/`coverage` miss them.
