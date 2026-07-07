# Global agent context

## MANDATE: `navgraph` is the required tool for code navigation

`navgraph` (`~/.local/bin/navgraph`) is a code-graph CLI that returns *semantic
structure* — symbols, signatures, and the call/import graph — instead of raw
text. One call replaces an entire grep-then-read-many-files loop, so it is
drastically more token-efficient. Using it is **not optional**.

### The rule (non-negotiable)

**If a file is in a navgraph-supported language, you MUST use navgraph to
navigate and understand it. You may NOT `read` a whole file, `cat` it, or `grep`
for a symbol as your way of understanding supported code.**

navgraph-supported languages (by extension):

- **Python** — `.py`
- **JavaScript** — `.js .jsx .mjs .cjs`
- **TypeScript** — `.ts .tsx .mts`
- **Zig** — `.zig`
- **C** — `.c .h`
- **C++** — `.cpp .hpp .cc .cxx .hh`
- **C#** — `.cs`
- **Lua** — `.lua`

For any of the above, navgraph is mandatory. For anything else (Go, Rust, Java,
Ruby, Kotlin, Swift, Elixir, shell, config, markdown, plain text), fall
back to grep/read — see "Escape hatches".

### Before you act, obey this order

For every code-understanding step on a supported file, you MUST reach for
navgraph **first**. Concretely, these are forbidden as a *first move* on
supported code, and each has a required replacement:

| ❌ Forbidden on supported code | ✅ Required instead |
| --- | --- |
| Reading a whole file to learn its structure | `navgraph outline <path>` |
| Reading a file to see one function's body | `navgraph def <name>` (`-v full` for source) |
| Reading many lines to grab a few ranges | `navgraph read file:A-B,C-D` (batched) |
| `grep` for a symbol's definition | `navgraph def <name>` / `navgraph search <name>` |
| `grep -r` to find who calls / uses a symbol | `navgraph callers <name>` (or `search <name> --refs`) |
| Reading files to trace what a function does | `navgraph calls <name>` (`-d2` deeper) |
| Reading both a function and its callers | `navgraph neighbors <name>` |
| Manually tracing how A reaches B | `navgraph path <A> <B>` |
| Guessing which code matters | `navgraph hot [path]` |
| Reviewing/scoping what a branch changed | `navgraph diff [ref]` (changed symbols since `ref`, default `HEAD`, + their callers) |
| Hunting for dead code (functions/methods **and types**) | `navgraph unused [filter]` — add `--no-public --no-test` for the actually-dead set |
| Reading routers + client to map an endpoint | `navgraph routes [filter]` (cross-language) |
| Reading handler + caller to trace a message-bus / WS event | `navgraph events [filter]` (pairs `register`/`on` handlers with `send`/`emit` emitters, cross-language) |
| Reading imports at the top of files | `navgraph imports [filter]` / `importers <file>` |
| `grep` inside string literals (URLs, logs, regexes) | `navgraph strings <pattern>` |
| Listing indexed files / gauging coverage | `navgraph files [filter]` (add `--sort symbols` to rank biggest-first) |

Only after navgraph has pointed you at specific lines may you `read` those exact
lines (or use `navgraph read file:A-B`) — never a whole supported file "to get
oriented". Getting oriented is exactly what `outline`/`hot`/`files` are for.

### Combine with unix tools (navgraph + pipes, not instead of navgraph)

navgraph owns *symbols and the graph*; unix tools only *filter and post-process
its output*. The winning pattern is `navgraph … | <tool>`, never grep/read as a
substitute for navgraph on supported code.

- **Scope to a subtree:** `navgraph search foo -C src` — flags go *after* the
  command and its argument.
- **Narrow output:** `navgraph outline | grep -A3 SomeType`
- **Count / dedupe:** `navgraph callers foo | wc -l`, `... | sort -u`
- **Script/parse:** add `-j` (stable JSON), pipe to `jq`.
- **grep as a *locator*, navgraph as the *explainer*:** if you only know a string
  fragment, `grep -rl` to find the file/identifier, then immediately switch to
  `navgraph def`/`callers`/`neighbors` to actually understand it. Do not
  grep-then-read a chain of files when `navgraph neighbors`/`path` answers it in
  one shot.

### Escape hatches (the ONLY times you may skip navgraph on code)

These are exhaustive. If none applies to a supported file, navgraph is required.

1. **Unsupported language / filetype** (Go, Rust, Java, Ruby, Kotlin, Swift,
   Elixir, shell, HTML/CSS, JSON/YAML/TOML, Markdown, plain text) — use
   grep/read.
2. **Non-symbol content** — comments, config values, docs, prose, license text,
   commit messages. (For strings *inside* supported source, still prefer
   `navgraph strings`.)
3. **You are editing** and need the precise surrounding lines navgraph already
   located — `read`/`navgraph read` those specific lines.
4. **navgraph genuinely can't answer** — you ran the right navgraph command and
   it returned nothing useful (e.g. a dynamic/reflected call it can't resolve).
   State that you fell back and why.

If you skip navgraph on a supported file, you must be able to name which hatch
applies. "It was faster to just read it" is not a valid hatch.

### Flags worth knowing

- `-v names|sig|doc|full` — detail level (default `sig`).
- `-d N` — graph depth for `calls`/`callers`/`neighbors` (default 1).
- `-k fn,struct,…` — restrict `outline`/`search` to kinds.
- `-s` / `--strict` — follow only high-confidence edges. A trailing `?` on an
  edge marks a heuristic (ambiguous name-match) — verify those or use `-s`.
- `-l N` / `--limit N` — cap results (default 300).
- `-r` / `--refs` — `search`: match use sites; `calls`/`neighbors`: include
  var/const/field reads.
- `-C <path>` — index root; scope to a subtree.
- `-j` / `--json` — stable JSON for tooling/`jq`.
- `--sort path|symbols` — `files`: order by path (default) or symbol count.
- `--no-cache` — rebuild (cache lives in `.navgraph/cache`). Run after updating
  navgraph itself, or after large refactors/deletions, so the index reflects
  current source.
- `unused` narrowing: `--no-public` drops exported symbols (possible public
  API), `--no-test` drops symbols used only by tests. Pass **both** for the
  actually-unused set; the output notes how many were hidden.

### Cross-package & cross-language resolution

navgraph resolves edges **across packages in a monorepo** (import-resolved, not
name-matched), so `unused`/`callers`/`path` are trustworthy across an
`apps/*` + `packages/*` split — a symbol defined in one package and used in
another is correctly seen as live, and `unused` won't mask a dead symbol just
because its name is reused elsewhere. `routes` (HTTP) and `events` (message
bus / WS) additionally bridge **across languages**, pairing e.g. a Python
backend handler with the TypeScript frontend call that hits it.

### Gotchas

- **navgraph respects `.gitignore`** (all commands) plus a fixed skip set
  (`node_modules .git dist build target vendor .venv __pycache__ .next zig-out coverage`).
  If something you expect is missing from results, check it isn't gitignored.
- `path A B` printing "no call path" is a real answer (A genuinely doesn't reach
  B), not a failure.
- Don't gauge "is X indexed?" with `navgraph search X | wc -l`: the not-found
  message is itself one line, so `wc -l` reads 1 whether X was found or not.
  Inspect the actual output.

