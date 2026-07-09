# NavGraph

**Steroids for a coding agent's understanding of a repository.**

NavGraph builds a dependency graph of your codebase — definitions, calls,
references, imports — and exposes it through a fast CLI that emits
*hyper-compressed*, token-frugal views. It is designed so an agent can navigate
and understand a repo almost entirely through NavGraph instead of `grep` + `read`.

Ask precise questions ("what does `foo()` call, 2 levels deep?", "who calls
`bar`?", "outline this file at signature detail") and get exactly the
information needed — nothing more.

- **Language-agnostic core.** Ships with Zig, C/C++, C#, Python, JavaScript,
  TypeScript, TSX, Lua, Go, Rust and Ruby.
- **Depth control.** Walk the call graph outward (callees) or inward (callers)
  to a bounded depth.
- **Verbosity levels.** `names` → `sig` → `doc` → `full`, so you spend tokens
  only where you need detail.
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
| `events [filter]`  | Link message-bus handlers (`register`/`on`) to emitters (`send`/`emit`) by shared string key. |
| `diff [ref]`       | Symbols changed since `<ref>` (default `HEAD`) plus their callers — the blast radius of a change. |
| `files [filter]`   | Indexed files + symbol counts; `--sort symbols` ranks biggest-first. |
| `unused [filter]`  | Unreferenced definitions (fns/methods & types) — removal candidates nothing calls or uses (**not** "broken" code). Default: truly unused (no caller in app or test code). `--no-tests` also lists code used only by tests (annotated); `--tests-only` lists unused test helpers; `--no-public` drops exported (maybe public API); `--follow-imports` disambiguates same-name symbols across packages by import reachability. |
| `coverage [path]`  | Per-file % of `fn`/`method` symbols reachable in the call graph from a test — a dependency-free, language-agnostic substitute for line coverage. |
| `help`             | Show help.                                                    |

**Flags**

| Flag                          | Meaning                                    |
|-------------------------------|--------------------------------------------|
| `-v, --verbosity <level>`     | `names` \| `sig` \| `doc` \| `full` (default `sig`). |
| `-d, --depth <N>`             | Graph depth for `calls`/`callers` (default `1`). |
| `-C, --root <path>`           | Index root: a directory, or a single file to scope to it (default `.`). |
| `-l, --limit <N>`             | Max results (default `300`).               |
| `-t, --tests <with\|without\|only>` | Unified test-scope for `outline`/`search`/`callers`/`hot`/`unused`: include tests (default), exclude (`--no-tests`), or only tests (`--tests-only`). A *test* is a Zig `test` block, a `test_*` function, or a file under a test dir. |

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

Cross-file and cross-language resolution works out of the box (name-based):

```
$ navgraph calls Server.start -C ./backend -d 2
method Server.start (self):  app/server.py:15
  fn load_config (path):  app/server.py:3
    fn parse (text):  app/server.py:8
    ~ ext: open, read
```

## How it works

1. **Walk** the project tree, skipping vendored/build dirs (`node_modules`,
   `.git`, `zig-out`, `__pycache__`, `dist`, …) and any file or directory
   matched by a `.gitignore` (per-directory files, negation, and `*`/`**` globs).
2. **Tokenize** each file with a shared, language-configured lexer that
   correctly skips strings/comments.
3. **Extract** definitions and their in-body references with per-language
   heuristic scanners (no per-language grammar required).
4. **Resolve** references to definitions by name, preferring same-file, then
   same-language-family, then callable targets, and build a reverse (callers)
   index.
5. **Render** query results in a dense, indentation-based format tuned for low
   token cost.

Everything for one run lives in a single arena that is freed on exit.

## Limitations & roadmap

- Resolution is **name-based**: a method call on a standard-library object can
  resolve to a same-named project symbol. Ambiguity is possible; treat the
  graph as high-recall guidance, not a compiler-grade index.
- No persistent cache yet — each invocation re-indexes. This is sub-second for
  typical repos; a mtime-keyed cache is a planned enhancement.
- **Cross-language API linking** (e.g. a TS `fetch('/route')` linked to a Python
  route handler) is on the roadmap and not yet implemented.

## Library use

The engine is exposed as a Zig module (`src/root.zig`) — `language`, `lexer`,
`model`, `parser`, `index`, `query`, `render` — so it can be embedded directly.
