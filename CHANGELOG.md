# Changelog

All notable changes to NavGraph are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
