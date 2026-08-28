# Changelog

All notable changes to NavGraph are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **A tree-sitter parser backend** (`-Dtree-sitter=<all|none|python,typescript,tsx>`,
  default `all`), selected per run with `--backend <auto|heuristic|tree-sitter>`.
  Python, TypeScript and TSX are now owned by it under the default `auto`;
  every other language stays on the heuristic scanner. See
  [`docs/backends.md`](docs/backends.md).
- `zig build differ` diffs both backends over the fixture trees: no definition
  or edge the scanner finds may disappear, and every newly exact edge is a
  reviewed entry with a written reason.
- `--full` for `status`: the item-level freshness/parse/resolution dump that
  used to be the only output. `--full -j`/`--full --jsonl` are a superset of
  the pre-change payload (two additive keys, `languages` and `backend`; no
  key removed, no value changed), not byte-identical to it.

### Changed

- `status`'s default output (text and `-j`/`--jsonl`) is now a bounded
  summary — project/language/backend counts, cache state, and headline
  freshness/parse/resolution counts, with no per-file or per-reference item
  arrays. Use `--full` for the previous file-level dump.

- Python and TypeScript accuracy against the golden corpora, measured by
  `zig build bench`: definition recall 91.14 → 96.87 (python) and
  58.19 → 89.34 (typescript), edge precision 93.07 → 98.40 (python), exact
  agreement 73.55 → 80.48 (python) and 84.61 → 97.14 (typescript). No metric of
  either language fell; the floors are raised to match.
- A declared type is now resolution evidence: a field of the receiver chain's
  head type, and a same-file top-level variable, type their receiver. A call on
  a builtin container (`items: dict`) abstains instead of matching a
  same-named project method.
- Enum members and a type alias's object-type members are no longer indexed as
  definitions, matching the golden corpora (interface members and class fields
  still are).

### Fixed

- TypeScript: the second and later declarators of `const a = 1, b = 2` were
  dropped by the tree-sitter backend.
- References one character long (`b()`) were skipped by the tree-sitter
  backend, on a rule the heuristic scanner no longer applies.

## [1.1.0] - 2026-08-28

### Added

- **`navgraph lsp` 1.1**: standard call/type hierarchy
  (`prepareCallHierarchy`/`incomingCalls`/`outgoingCalls`,
  `prepareTypeHierarchy`/`supertypes`/`subtypes`), `implementation`,
  `typeDefinition`, `documentHighlight`, and `codeLens`/`codeLens/resolve`.
- Custom `navgraph/impact` (the working change's blast radius, grouped by
  changed hunk), `navgraph/tests` (every test reaching a symbol — the
  `coverage` walk inverted), `navgraph/types` ("who uses type T"),
  `navgraph/context` (one symbol's callers/callees/types/tests/definition in
  a single call, trimmed to a token budget), and `navgraph/where` (the symbol
  enclosing a `file:line`).
- `navgraph/symbolAt` gains `range`/`breadcrumbs`; `navgraph/search` gains a
  `recent`-names ranking tier; `navgraph/status` gains `protocolMinor` and
  `backend`; every `Symbol` gains a stable `contentHash`. Every list method
  now reports `truncated`.
- An incremental-reparse seam (`index.ReparseHint`) for a future
  tree-sitter-backed parser, behind the heuristic backend unchanged.
- CLI and MCP mirrors of `navgraph/impact`/`context`/`where`: `navgraph
  hunks`/`context`/`where` on the command line, and `navgraph.hunks`/
  `.context`/`.where` as MCP tools on `navgraph serve`. All three share their
  implementation with the LSP server verbatim (`src/lsp/mirrors.zig`).
- See [`docs/lsp.md`](docs/lsp.md)'s "1.1" section for the full contract.

## [1.0.0] - 2026-08-28

First tagged release.

### Added

- **`navgraph lsp`** — a resident editor server: a standard LSP subset
  (`definition`, `references`, `hover`, `documentSymbol`, `workspace/symbol`,
  full document sync) plus every CLI verb exposed as a `navgraph/*` method
  (`status`, `symbolAt`, `blast`, `search`, `grep`, `callers`, `calls`,
  `rescan`, `neighbors`, `path`, `outline`, `hot`, `unused`, `diff`, `routes`,
  `events`, `imports`, `importers`, `graph`). The whole graph stays in memory;
  an edit re-indexes in tens of milliseconds or less and queries answer in
  single-digit milliseconds. See [`docs/lsp.md`](docs/lsp.md) for the protocol.
- The release version now comes from `build.zig.zon` instead of a second
  hardcoded copy, so `navgraph capabilities` (aliases `version`, `--version`),
  `navgraph/status` and the LSP `initialize` `serverInfo` cannot disagree with
  the tag the release workflow gates on.
- A tagged (`v*`) push now cross-compiles and publishes `ReleaseFast`
  binaries for x86_64/aarch64 Linux and macOS as GitHub release assets, after
  a tag-vs-version check and the full test suite both pass.
- Data-flow and reachability queries (`flow`, `taint`, `reaches`, `affected`)
  and Java language support landed on `main` (#4).

### Changed

- README: an install-from-release path (`gh release download`), and a
  pointer to [epicenter.nvim](https://github.com/mengsig/epicenter.nvim) as
  the reference Neovim client for `navgraph lsp`.

### Fixed

- `navgraph/path` reported an ambiguous endpoint as "no path"; it now returns
  the candidates so the question can be re-asked with `Parent.name`.
- `navgraph/graph` reported neither that the renderer's node cap had truncated
  the page nor that the write had failed.
- A resolver review of #4 fixed four cross-file regressions (Rust `use`
  bindings suppressing call edges, typed-receiver calls not resolving, Java
  inherited-member resolution going quadratic) and three smaller defects
  before it merged (#7).
