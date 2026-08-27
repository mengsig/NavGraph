# Changelog

All notable changes to NavGraph are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **`navgraph lsp`** — a resident editor server: a standard LSP subset
  (`definition`, `references`, `hover`, `documentSymbol`, `workspace/symbol`,
  full document sync) plus every CLI verb exposed as a `navgraph/*` method
  (`status`, `symbolAt`, `blast`, `search`, `grep`, `callers`, `calls`,
  `rescan`, `neighbors`, `path`, `outline`, `hot`, `unused`, `diff`, `routes`,
  `events`, `imports`, `importers`, `graph`). The whole graph stays in memory;
  an edit re-indexes in single-digit milliseconds and queries answer in well
  under a millisecond. See [`docs/lsp.md`](docs/lsp.md) for the full protocol.
- `navgraph --version` / `-V` / `version`, and the version now surfaces in
  `navgraph/status` and the LSP `initialize` `serverInfo`.
- A tagged (`v*`) push now cross-compiles and publishes `ReleaseFast`
  binaries for x86_64/aarch64 Linux and macOS as GitHub release assets.

### Changed

- README: an install-from-release path (`gh release download`), and a
  pointer to [epicenter.nvim](https://github.com/mengsig/epicenter.nvim) as
  the reference Neovim client for `navgraph lsp`.
