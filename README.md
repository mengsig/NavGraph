# NavGraph

**Steroids for a coding agent's understanding of a repository.**

<p align="center">
  <img src="assets/navgraph-graph.gif" alt="NavGraph rendering its own source as an interactive, dependency-layered graph — callers on top, callees below, click any symbol to trace its callers and callees" width="840">
</p>
<p align="center">
  <sub><b><code>navgraph graph src &gt; graph.html</code></b> — the whole codebase as one interactive, dependency-layered page (callers → callees, top-down). Click a symbol to trace it. <a href="#visualize-the-graph">Details ↓</a></sub>
</p>

NavGraph builds a dependency graph of your codebase — definitions, calls,
references, imports — and exposes it through a fast CLI that emits
*hyper-compressed*, token-frugal views. It is designed so an agent can navigate
and understand a repo almost entirely through NavGraph instead of `grep` + `read`.

Ask precise questions ("what does `foo()` call, 2 levels deep?", "which classes
implement this port?", "which clients hit this route?", "outline this file at
signature detail") and get exactly the information needed — nothing more.

- **Language-agnostic core.** Ships with Zig, C/C++, C#, Python, JavaScript,
  TypeScript, TSX, Lua, Go, Rust and Ruby.
- **Depth control.** Walk the call graph outward (callees) or inward (callers)
  to a bounded depth.
- **Verbosity levels.** `names` → `sig` → `doc` → `full`, so you spend tokens
  only where you need detail.
- **Ports and adapters.** Follow Protocol/interface dispatch to nominal and
  structural implementations, or audit sibling signature divergence in one query.
- **Cross-language APIs.** Link HTTP routes to client calls, including mounted
  FastAPI router prefixes, and expose unhit routes and orphan calls.
- **Trust signals.** Type-scoped member resolution avoids global same-name guesses;
  tokenizer desynchronization produces a parse-health warning instead of silently
  presenting a partial index as complete.
- **Fast.** A ~550-file project indexes and answers a query in ~0.2s. No daemon,
  no external dependencies, single static binary.

## Build & install

Requires Zig `0.16.0`.

```sh
zig build -Doptimize=ReleaseFast          # -> zig-out/bin/navgraph
zig build -Doptimize=ReleaseFast --prefix ~/.local   # installs to ~/.local/bin/navgraph
```

Run the tests:

```sh
zig build test --summary all
```

Estimate test coverage — the fraction of `fn`/`method` symbols reachable in the
call graph from a test (kcov cannot read Zig 0.16's DWARF5, so there is no
line-coverage tool for this codebase; this is a dependency-free substitute):

```sh
navgraph coverage src            # per-file % + overall, computed natively
navgraph coverage src -j         # same, as JSON
```

## Visualize the graph

Turn the whole graph into a **standalone, offline HTML page** — the animation at
the top is NavGraph rendering *its own* source. It's a **layered dependency view**
(callers on top, callees below, edges flowing downward), with a force-directed
mode one click away. Zoom, pan, search, and **click any symbol to trace its
callers/callees**; nodes are sized by fan-in and colored by file. No server, no
CDN, no dependencies — the data *and* the renderer are inlined into one
self-contained file you can open (or email) anywhere.

```sh
navgraph graph src --no-tests > graph.html   # then open graph.html in a browser
navgraph graph                                # whole repo (tests hidden in the initial view)
navgraph graph -C src/lexer.zig > lexer.html  # scope to a single file
navgraph graph -j > graph.json                # raw {nodes, edges} model for other tools
```

> Tip: GitHub won't run the page's JavaScript inline, so a repo shows a
> screenshot/GIF like the one above — but the file itself is fully interactive the
> moment you open it locally.

## Usage

```
navgraph <command> [arg] [flags]
```

| Command            | Purpose                                                        |
|--------------------|---------------------------------------------------------------|
| `outline [path]`   | Outline symbols in a file/dir (default: the whole project).   |
| `def <name>`       | Show a definition. Supports `Parent.name` to disambiguate.    |
| `calls <name>`     | Tree of what `<name>` calls/uses (callees).                   |
| `callers <name>`   | Tree of who calls/uses `<name>` (callers).                    |
| `search <pattern>` | Symbols whose name contains `<pattern>` (`--refs` for use sites; `Recv.field`/`.field` pins attribute reads). |
| `routes [filter]`  | HTTP routes and cross-language client calls. Views: `--clients`, `--unhit`, `--orphan-calls`, `--handler <glob>`. Mounted FastAPI router prefixes are applied automatically. |
| `conforms <selector>` | Audit Protocol/interface implementations or compare sibling classes/methods for missing, signature, and async divergence. Aliases: `impls`, `implements`. |
| `events [filter]`  | Link message-bus handlers (`register`/`on`) to emitters (`send`/`emit`) by shared string key. |
| `neighbors <name>` | Callees and callers of `<name>` in one view.                  |
| `unused [filter]`  | Unreferenced definitions (fns/methods & types) — removal candidates nothing calls or uses (**not** "broken" code). Default: truly unused (no caller in app or test code). `--no-tests` also lists code used only by tests (annotated); `--tests-only` lists unused test helpers; `--no-public` drops exported (maybe public API); `--follow-imports` disambiguates same-name symbols across packages by import reachability. |
| `imports [filter]` | Modules each file imports (local dependency edges).           |
| `importers <file>` | Files that import `<file>`.                                    |
| `path <A> <B>`     | Shortest call path from `<A>` to `<B>`.                        |
| `diff [ref]`       | Symbols changed since `<ref>` (default `HEAD`) plus their callers — the blast radius of a change. |
| `hot [path]`       | Rank functions by fan-in/out (`←N callers →M callees`) — the load-bearing symbols. |
| `files [filter]`   | Indexed files + symbol counts; `--sort symbols` ranks biggest-first. |
| `read <file[:A-B]>`| Print raw source lines (numbered); batch ranges: `file:A-B,C-D`. |
| `strings <pattern>`| Search inside string literals (URLs, log/error text, regexes). |
| `coverage [path]`  | Per-file % of `fn`/`method` symbols reachable in the call graph from a test — a dependency-free, language-agnostic substitute for line coverage. |
| `graph [path]`     | **Interactive HTML** of the code graph (nodes = symbols, sized by fan-in, colored by file; edges = calls/type uses). Redirect stdout to a `.html` file and open it; `-j` emits the raw `{nodes, edges}` JSON. Respects `--tests`. |
| `help`             | Show help.                                                    |

**Flags**

| Flag                          | Meaning                                    |
|-------------------------------|--------------------------------------------|
| `-v, --verbosity <level>`     | `names` \| `sig` \| `doc` \| `full` (default `sig`). |
| `-d, --depth <N>`             | Graph depth for `calls`/`callers` (default `1`). |
| `-C, --root <path>`           | Index root: a directory, or a single file to scope to it (default `.`). |
| `-l, --limit <N>`             | Max results (default `300`).               |
| `-k, --kind <k1,k2>`          | Restrict `outline`/`search` to kinds (`fn`, `struct`, …). |
| `-p, --vis <scope>`            | Visibility for `outline`/`search`/`def`: `public`, `private`, or `all` (default). Shortcuts: `--public`, `--private`, `--no-private`. |
| `-t, --tests <with\|without\|only>` | Unified test-scope for `outline`/`search`/`callers`/`hot`/`unused`: include tests (default), exclude (`--no-tests`), or only tests (`--tests-only`). A *test* is a Zig `test` block, a `test_*` function, or a file under a test dir. |
| `-r, --refs`                  | `search`: match use sites; `calls`/`neighbors`: include var/const/field reads. |
| `-e, --exact`                 | `search`: name must equal the pattern (no substring hits). |
| `--no-recurse`                | `outline`/`files`: only files directly in the given dir, not subtrees. |
| `-s, --strict`                | Follow only high-confidence edges (drop heuristic `?` edges, including structural implementation edges). |
| `-i, --impls`                 | On `calls`/`callers`/`neighbors`/`path`, cross Protocol/interface ↔ implementation edges (`⇒impl`). |
| `--clients`                   | `routes`: show resolved client call sites, tagged by source language. |
| `--unhit`                     | `routes`: show only routes with no resolved client calls. |
| `--orphan-calls`              | `routes`: show client calls that match no indexed route. |
| `--handler <glob>`            | `routes`: select routes by handler name. |
| `-j, --json`                  | Emit JSON (stable, for tooling/MCP).       |
| `--sort <path\|symbols>`      | `files`: order by path (default) or symbol count. |
| `--no-cache`                  | Ignore the `.navgraph/cache` and rebuild.  |
| `--no-public`                 | `unused`: drop exported symbols (possible public API). |
| `--follow-imports`            | `unused`: disambiguate same-name symbols by import reachability. |

**Patterns.** A name or filter containing `*` is a glob: `def 'Ba*'` lists
`Bays` and `Bananas`, `search '*_handler'` anchors on the whole name,
`callers 'Matcher.is*'` walks every matching member. Path filters glob
gitignore-style — `files '*_test.py'` matches basenames at any depth,
`outline 'src/**/*.ts'` the full path. Without a `*`, names substring-match
(and `def` matches exactly), as before.

**Ignores.** `.gitignore` is respected everywhere. A `.navgraphignore`
(same syntax, per-directory) adds navgraph-only rules — scratch dirs, vendored
code, fixtures — without touching git; a negated rule (`!vendor/`) re-includes
a directory the built-in skip set would prune. Minified/bundled artifacts
(`*.min.*`, one-enormous-line files) are skipped automatically and named in
the skipped-note.

**Exit codes.** `0` = found results, `1` = the query ran but found nothing
(grep convention), `2` = usage error. Piping into `head` exits quietly (141).
A not-found suggests near-miss names (`did you mean: …`); an ambiguous name
prints how many definitions matched and the `Parent.name` / `name@path` pin
syntax.

## Examples

Outline a file at signature detail:

```
$ navgraph outline src/parser.zig
# src/parser.zig (zig)
  fn parse ( gpa: std.mem.Allocator, ... ) !void  L69
  fn collectRefs (ctx: *Ctx, lo: u32, hi: u32, ...) ![]Reference  L172
  struct Ctx  L37
    method Ctx.isPunct (self: *const Ctx, i: u32, c: u8) bool  L53
  ...
```

Follow the call graph two levels deep (callees). Resolved edges recurse;
unresolved/external calls are summarised on a `~ ext:` line:

```
$ navgraph calls collectRefs -d 2
fn collectRefs (...) ![]Reference  src/parser.zig:172
  method Token.text (...) []const u8  src/lexer.zig:30
    ~ ext: assert
  fn recordRef (...) !void  src/parser.zig:193
    ~ ext: get, put, @intCast, append
  ~ ext: assert, StringHashMap, init, ArrayList, has, eql, dupe
```

Who calls a symbol:

```
$ navgraph callers emit
fn emit (ctx: *Ctx, sym: ParsedSymbol) !u32  src/parser.zig:216
  fn parseZigFn (...) !u32  src/parser.zig:291
  fn parseZigConst (...) !u32  src/parser.zig:333
  ...
```

Who implements a port, and which dispatch sites reach it:

```
$ navgraph callers Store.get --impls
method Store.get (...)  src/ports.py:8
  method MemoryStore.get (...)  src/memory.py:12  ⇒impl ?
```

Structural implementation edges are heuristic (`?`); explicit nominal
inheritance can be exact. `--strict` keeps only exact edges. The derived
implementation graph is query-local, so it does not inflate `hot`, `unused`, or
coverage.

Audit a Protocol or compare sibling classes selected by a glob:

```
navgraph conforms Store
navgraph conforms '*Runner' -j
```

`conforms` reports `OK`, `MISSING`, `SIG-DIFF`, and `ASYNC-DIFF`. A Protocol
selector compares its methods with discovered implementations; a selector that
matches multiple ordinary classes or methods produces a sibling divergence
matrix.

Inspect HTTP client coverage after mounted router prefixes are applied:

```
navgraph routes /v1/orders --clients
navgraph routes --unhit
navgraph routes --orphan-calls
navgraph routes --handler 'place_*'
```

Visibility can be filtered without post-processing:

```
navgraph outline src --public
navgraph search '*_handler' --vis private
```

Show a full definition:

```
$ navgraph def bracketMatches -v full
fn bracketMatches  src/parser.zig:128
fn bracketMatches(open: u8, cl: u8) bool {
    return (open == '(' and cl == ')') or
        (open == '{' and cl == '}') or
        (open == '[' and cl == ']');
}
```

Cross-file resolution works out of the box; HTTP routes and events can also
bridge language families:

```
$ navgraph calls Server.start -C ./backend -d 2
method Server.start (self):  app/server.py:15
  fn load_config (path):  app/server.py:3
    fn parse (text):  app/server.py:8
    ~ ext: open, read
```

## How it works

1. **Walk** the project tree, skipping vendored/build dirs (`node_modules`,
   `.git`, `zig-out`, `__pycache__`, `dist`, `site-packages`, …) and any file or
   directory matched by a `.gitignore` (per-directory files, negation, and
   `*`/`**` globs). A **`.navgraphignore`** (same syntax, per-directory) adds
   navgraph-only rules on top — and a negated `!vendor/` rule there re-includes
   a directory the built-in skip set would prune.
2. **Tokenize** each file with a shared, language-configured lexer that
   correctly skips strings, comments, JavaScript regex literals, and JSX closing
   tags. If an unterminated string still consumes the rest of a file, NavGraph
   prints a `parse-health` warning with the affected line range.
3. **Extract** definitions and their in-body references with per-language
   heuristic scanners (no per-language grammar required).
4. **Resolve** references to definitions by name, with exact receiver-aware
   handling for `self`/`this`, typed receivers, and imported modules. Member calls
   are scoped to the enclosing or inferred receiver type; unknown receiver types
   remain external or heuristic rather than being attached to an unrelated
   same-named class. Build a reverse (callers) index.
5. **Render** query results in a dense, indentation-based format tuned for low
   token cost.

Everything for one run lives in a single arena that is freed on exit.

## Limitations & roadmap

- Resolution is **heuristic**, not compiler-grade. It is type-scoped (a member
  call binds only to a member of the receiver's inferred type — `self`/`this`,
  typed params, local `Foo{…}`/`Foo.init()` bindings) and import-aware, but a
  call on an untracked receiver falls back to a name match, marked heuristic
  (`?`); `--strict` drops those. Treat the graph as high-recall guidance.
- Repeat runs are fast via an on-disk cache under `.navgraph/cache` (path +
  mtime + ctime + size keyed); `--no-cache` forces a clean rebuild.
- **Cross-language linking** covers HTTP routes (`navgraph routes`, e.g. a TS
  `fetch('/v1/route')` paired with a mounted Python/FastAPI handler) and
  message-bus events (`navgraph events`). Literal FastAPI `include_router`
  prefixes are resolved across imported modules before clients are linked;
  dynamic prefixes and ambiguous mounts are left unresolved rather than guessed.
  GraphQL / DB-model / protobuf schemas, and non-Zig
  *inline* tests (e.g. Rust `#[cfg(test)]`), are not yet handled.

See `ROADMAP.md` for planned work and `new-features.md` for the current backlog.

## Library use

The engine is exposed as a Zig module (`src/root.zig`) — `language`, `lexer`,
`model`, `parser`, `index`, `query`, `render`, `api`, `impls`, and related query
output modules — so it can be embedded directly.
