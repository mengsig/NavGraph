# navgraph: required tool for code navigation

`navgraph` (`~/.local/bin/navgraph`) is a lightweight static code-graph CLI that
returns symbols, signatures, and call/import edges rather than raw text. One call
replaces a whole grep-then-read-many-files loop, so it is far more
token-efficient. **For any indexed language below, use it before raw reads.**

**Indexed extensions:** Python (`.py .pyi`), JS (`.js .jsx .mjs .cjs`), TS
(`.ts .tsx .mts`), Zig (`.zig`), C (`.c .h`), C++ (`.cpp .hpp .cc .cxx .hh`),
C# (`.cs`), Lua (`.lua`), Go (`.go`), Rust (`.rs`), Ruby (`.rb`). Representative
files, symbols, and direct calls were confirmed in every family; this is
heuristic indexing, not compiler/type-checker acceptance. Anything else (Java,
Kotlin, Swift, Elixir, shell, config, markdown) → grep/read.

## The rule

On indexed code you may NOT `read` a whole file, `cat`, or `grep` for a symbol
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
| Who writes/reads a value | `navgraph flow <symbol>` (includes definition initializers; `--to <sink>` traces the handoff) |
| Static source-to-sink tracing | `navgraph taint <source> --to <sink>` |
| Finding duplicate names | `navgraph collisions [pattern]` (alias `duplicates`; `--members` includes members) |
| Guessing what matters | `navgraph hot [path]` |
| Scoping a branch's changes | `navgraph diff [ref]` (+ callers); add `--exact-source` for byte ranges + raw patch |
| Inspecting symbol history/provenance/churn | `navgraph history <symbol>` / `blame <symbol>` / `churn [path]` |
| Listing statically affected tests | `navgraph affected --since <ref>` |
| Set reachability | `navgraph reaches <A,B,...>` (`--from-tests` selects exercising tests) |
| Finding dead code | `navgraph unused [filter]` (`--no-public` hides API) |
| Which tests hit a symbol | `navgraph callers <name> --tests-only` |
| Static test reach / coverage | `navgraph coverage [path]` (call graph; does not run tests) |
| Visual codebase map | `navgraph graph [path] > graph.html` (offline interactive) |
| Mapping an HTTP endpoint | `navgraph routes [filter] --clients` (mounted prefixes + cross-language callers) |
| Finding dead/unserved API edges | `navgraph routes --unhit` / `routes --orphan-calls` (`--orphan`/`--orphans`) |
| Auditing a port or sibling adapters | `navgraph conforms <Protocol|*Glob|Type.method>` (aliases `impls`, `implements`) |
| Inspecting nominal inheritance/overrides | `navgraph hierarchy <Type> [--overrides]` |
| Tracing raised and caught exceptions | `navgraph raises <symbol>` / `catches <Error>` |
| Crossing Protocol/interface dispatch | add `--impls` to `calls`/`callers`/`neighbors`/`path`/`reaches`/`affected` |
| Tracing a bus/broker event | `navgraph events [filter]` (cross-language; Kafka topics recognized, common DOM listeners filtered) |
| Reading imports | `navgraph imports [filter]` / `importers <file>` |
| grep inside string literals | `navgraph strings <pattern>` |
| Reading intent/docs | `navgraph docs <name>` / `todos [path]` |
| Planning a mechanical rename | `navgraph edits <symbol>` / `rename <symbol> <new> --preview` |
| Listing indexed files | `navgraph files [filter]` (`--sort symbols`) |
| Checking snapshot trust/freshness | `navgraph status [filter]` (`-j`/`--jsonl` for structured diagnostics) |

## Combine with unix tools (pipe, don't substitute)

navgraph owns symbols/graph; unix tools only filter its output. The command must
come first (except top-level `-h`/`--help`); afterward, flags may appear before or
after positional arguments. `navgraph outline | grep -A3 Type`, `navgraph
callers foo | wc -l`, and `navgraph search foo -j | jq` are valid pipelines. Use
grep only as a locator for a non-symbol fragment, then switch to navgraph to
understand it.

## Escape hatches (the only skips allowed)

1. Unsupported language/filetype.
2. Non-symbol config content — but strings in supported source still →
   `navgraph strings`, symbol docs → `docs`, and TODO/FIXME/HACK comments → `todos`.
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
- Use `conforms Port` instead of outlining every adapter; structural matches are
  explicitly marked for review.
- `path A B` beats `calls A -d3` for "how does A reach B". Use `flow field`
  when the missing link is a write/read handoff rather than a call; definition
  initializers count as producers. Ambiguous flow selectors report the exact
  match count and the `Parent.name` / `name@path` pin syntax; JSON includes every
  candidate. Add `--to sink` for a chain.
- Use `outline src -k fn --sort span -l 10` for largest-definition audits and
  `collisions` instead of dumping names through `sort | uniq -d`. Use
  `hot --no-tests` when you want a production-only ranking.
- On a large hub use `--max-nodes N --summary` or `--budget BYTES`; bounded
  views report what was elided.
- Use `affected --since HEAD~1` rather than manually unioning `diff` with test
  callers; it lists a static impacted-test set but does not execute tests. Use
  `reaches A,B --from-tests` for named target sets. Add `diff --exact-source`
  when review also needs exact hunks and non-symbol edits.
- Before a mechanical rename, run `rename Old New --preview` (or `edits Old`).
  Apply without `--preview` only after collision/review warnings are clear.
- For pageable automation, use `--jsonl -l N` only with `outline`, `search`,
  `hot`, `todos`, `reaches`, `affected`, `edits`, or `status`; resume from the
  footer's `next` cursor with `--after v1:N`. `serve` exposes CLI queries through
  `navgraph`; call `navgraph.reload` after edits (or send `workspace/reload`).
- Trust the JSON `parent` field for "which class owns this method".
- Go: a uniquely resolved imported package call is retained by `--strict`; pin
  ambiguous methods as `Type.method` or `name@path`.

## Key flags

- `-v names|sig|doc|full` — output detail (default `sig`).
- `-d N` — traversal depth for `calls`, `callers`, `neighbors`, and `raises` (default 1).
- `-k fn,struct,…` — kinds for `outline`/`search`.
- `-p`/`--vis public|private|all` — visibility for `outline`, `search`, `def`,
  and `collisions`; shortcuts: `--public`, `--private`, `--no-private`.
- `-i`/`--impls` — add query-local Protocol/interface implementation edges to
  `calls`, `callers`, `neighbors`, `path`, `reaches`, and `affected`. Structural
  links carry `?`; combine with `-s` only when intentionally dropping them.
- `-s`/`--strict` — retain only exact static edges. It drops inferred and `?`
  edges; “exact” is NavGraph confidence, not proof of runtime dispatch.
- `-r`/`--refs` — use sites in `search`; variable/field reads in `calls` and
  `neighbors`. `-e`/`--exact` means exact *search name*, not exact graph edge.
- `--budget BYTES`, `--max-nodes N`, `--summary` — bounded output for `calls`,
  `callers`, `neighbors`, `outline`, `search`, `hot`, `reaches`, and `affected`.
- `--since REF` applies to `affected`/`churn`; `--last N` to `history`/`churn`;
  `--from-tests` to `reaches`; `--preview` to `rename`; `--exact-source` to
  `diff`; `--overrides` to `hierarchy`; `--to` to `flow`/`taint` (required by
  `taint`).
- `-t`/`--tests with|without|only` (aliases `--no-tests`, `--tests-only`) — test
  scope for `outline`, `search`, `callers`, `hot`, and `unused`; default `with`.
- `-C <path>` — directory or single-file index root. Use a separate value
  (`-C path`); command-first attached forms verified are `-d2`/`--depth=2`.
- `--sort`: `files` accepts `path|symbols`; `outline`/`search` accept
  `line|name|span|callers|callees`; `hot` accepts
  `fan_in|fan_in_exact|fan_out|fan_out_exact|span`; `churn` accepts
  `commits|lines`.
- Directional references: `-w`/`--writers`, `--readers`, and `--on-type Type`
  affect `flow` or `search --refs`; rows are `[w]`/`[r]`. Treat
  `-u`/`--unread` as incomplete; see Gotchas.
- Duplicate audit: `search PAT --duplicates`; `collisions --members` includes
  methods and fields.
- Route views: `--clients`, `--unhit`, `--orphan-calls` (aliases `--orphan`,
  `--orphans`), and `--handler <glob>`. Stacked FastAPI `APIRouter` and aliased
  `include_router` prefixes are applied before route/client matching.
- `--no-recurse` limits `outline`/`files` to direct files. On `status`, it scopes
  structured `scope` counts and diagnostics while top-level snapshot totals
  remain recursive.
- `--no-cache` bypasses cache reads and writes for that invocation; it leaves an
  existing `.navgraph/cache` untouched. `--follow-imports` changes `unused`
  only; other commands may accept it without effect.

## Output formats and limits

- `-j`/`--json` emits one valid JSON value for all index-backed one-shot CLI
  commands (every listed command except `help` and `serve`). Empty queries still
  emit valid JSON and exit 1. Unchanged test snapshots produced deterministic bytes,
  but no cross-version schema guarantee was established.
- `--jsonl` is supported only by `outline`, `search`, `hot`, `todos`, `reaches`,
  `affected`, `edits`, and `status`. Every non-empty line is JSON; the final
  `page` row carries `total`, `has_more`, and `next`. Resume with
  `--after <next>` against the same snapshot/options. A valid cursor beyond the
  end emits an empty footer and exits 1.
- `-j` and `--jsonl` are mutually exclusive; `--after` requires `--jsonl`.
  `help` ignores format flags and remains text. `serve -j` still speaks its
  JSON-RPC protocol; `serve --jsonl` is a usage error.
- `-l N` caps list results (default 300) in text/JSON and is the per-page size
  under JSONL. Truncated text listings print an ellipsis note; JSONL preserves
  the uncapped `total` in its footer. Taint JSON also caps endpoint-site arrays
  while preserving uncapped `match_count` and top-level counts. Churn JSON uses
  `{entries,count,truncated,exact}`; `count` is uncapped before `-l` within the
  selected `--last`/`--since` history window.

## Cross-package & cross-language

Edges are static and resolve within the relevant language family, using receiver,
type, package, and import context where NavGraph can establish it. Unresolved or
ambiguous calls remain external or carry `?`; `--strict` filters those rather
than making resolution more precise. `--impls` adds a separate query-local
Protocol/interface graph. `routes` and `events` are the tested cross-language
bridges: a mounted Python route linked to a TS client, and a Python emitter to a
TS handler.

## Freshness: one-shot CLI vs `serve`

- Every index-backed one-shot command builds a current snapshot; valid cache
  entries accelerate it, and edited files are reparsed automatically. `--no-cache`
  forces parsing for that process but does not rewrite the cache.
- `serve` is line-delimited JSON-RPC/MCP over stdin/stdout and fixes both root and
  an in-memory snapshot at startup. Edits can make `status -j` report
  `freshness.current:false` while ordinary queries remain on old symbols;
  query-local `--no-cache` does not refresh that snapshot.
- Refresh atomically with the `navgraph.reload` MCP tool or `workspace/reload`
  (`noCache:true` is available). Failed reloads preserve the last good snapshot.
  Per-request `-C`, `help`, and nested `serve` are rejected; choose the root when
  starting the process.

## Gotchas

- Ignore handling is a gitignore-style subset, not full Git syntax: `*`, `?`,
  `**`, directory rules, and `!` negation were confirmed; character classes such
  as `[0-9]` were not honored. Per-directory `.gitignore` and
  `.navgraphignore` apply, and `.navgraphignore` can re-include a built-in skip
  such as `!vendor/`. An explicit single-file `-C` overrides ignore rules.
- The built-in root-level skip set includes node_modules, `.git`, dist, build,
  target, vendor, venv/`.venv`, `__pycache__`, `.next`, zig-out, coverage,
  site-packages, and `.codeflow`. Names such as dist/build/target/coverage can
  still be indexed below a source directory (confirmed under `src/`).
- `*` = globs (`def 'Ba*'`, `files '*_test.py'`); anchored on the whole name;
  no `*` = substring match. `search -e` requires exact name equality but can
  still return duplicate definitions.
- Exit codes: 0 = successful result or help; 1 = empty result, blocked operation,
  or runtime/indexing failure; 2 = usage/argument error. A no-path answer is a
  valid empty result and exits 1. Parse-health warnings alone do not change the
  query's exit code.
- A missing `-C` root currently exits 1 after writing a short error to stdout and
  an internal Zig stack trace to stderr.
- Minified bundles are omitted; `status` reports them with `(minified)`, while
  `files`/`outline` simply omit them. The `status` skipped list is diagnostic,
  not a guaranteed inventory of every pruned built-in directory.
- `flow` is best-effort. Definition initializers and read-to-sink handoffs worked,
  but simple Python/TS module-variable assignments were absent from its WRITERS;
  `search --refs --writers` found them, while adding `--unread` returned no
  assignment rows in those fixtures.
- C/C++ headers are indexed, but bodyless function prototypes were not emitted
  as symbols; inline definitions were. In C#, an explicit `this.method()` linked
  within the class, while the tested bare `method()` call remained external.
- Parsing is tolerant, not syntax validation: malformed Python and a truncated
  Zig body were partially indexed without warnings. `navgraph: parse-health:`
  on stderr specifically signals tokenizer desynchronization (confirmed for an
  unterminated string); the named root-wide line range may have missing symbols.
- Inline non-Zig tests (confirmed with Rust `#[cfg(test)]`/`#[test]`) are treated
  as production: `--tests-only`/`coverage` missed them, and `affected` returned no
  test after the production target changed. Zig `test` blocks, `test_*`
  functions, and test-directory files are recognized.
- Rename applies only when all planned code sites are exact: ambiguous selectors,
  destination collisions, and heuristic review sites block writes. Recognized
  local shadows are excluded rather than blocking. Confirmed exact renames
  changed code definitions/references while leaving strings and comments untouched.
- `hierarchy` derives nominal bases from language syntax and computes a C3-style
  MRO only for uniquely resolved indexed types. Qualified, ambiguous, and external
  bases retain their source spelling and remain visible as heuristic; an unresolved
  base on any traversed ancestor makes the MRO explicitly incomplete
  (`mro_complete:false` in JSON). `--strict` hides heuristic bases and C++/C#
  name-only override candidates. Go support is embedded-interface based and Rust
  support is trait-`impl` based, not compiler type checking.
- `raises`/`catches` are token- and call-graph-based. Ruby bare `rescue` is
  `StandardError`; C# `catch ... when (...)` is conditional and therefore
  heuristic. Dynamic exception values, external built-in-base matches, reflection,
  and other language-specific control-flow details can be heuristic; Go `recover`
  and Zig `catch` are intentionally non-exact and disappear under `--strict`.
- `taint` is bounded, best-effort callable-local reachability over parameters,
  assignments, returns, arguments, and call results. It does not model
  module/global state, alias-heavy fields, sanitizers, or a full path-sensitive
  CFG. Endpoint selectors accept an optional `@path` pin; edge confidence is
  explicit and `--strict` follows exact edges only. Bounded findings are ranked by
  confidence and then path distance before `-l` truncation; reported reachability
  counts remain uncapped.
- `history`, `blame`, `diff`, and `affected` require usable Git history. An
  unborn repository gives `churn` an empty ranking instead. Patch-producing Git
  commands disable configured external diff/textconv helpers and decode Git
  C-quoted paths. History/blame use current working-tree symbol ranges; churn
  counts added plus removed/replaced hunk lines and maps them to current symbols
  heuristically after moves.
- Don't test indexing with `search X | wc -l`: an empty text query prints a
  message. Check the exit code or use `-j`/`files`.
