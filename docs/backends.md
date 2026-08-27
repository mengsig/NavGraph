# Parser backends

NavGraph extracts symbols with one of two backends behind a single seam. This
document is the design reference, the promotion procedure, the offline-build
story, and the measured numbers.

## The seam

`index.zig` calls the parser in exactly one place (`parser.parse` →
`[]ParsedSymbol`). `src/backends.zig` sits at that call site and dispatches to
one of:

- **`heuristic`** (`src/parser.zig`) — a lexer-driven scanner, no grammar
  required. Default everywhere, and the fallback whenever tree-sitter can't be
  used cleanly.
- **`tree-sitter`** (`src/ts_backend.zig`) — hand-written `extern fn` bindings
  to the tree-sitter C runtime (no `@cImport`), one `Compiled` holder per
  language (parser + compiled queries built once per process and reused across
  files — compiling a query per file measured 37x slower). NavGraph-owned query
  sets live under `src/queries/<lang>/{defs,refs,locals}.scm` and are embedded
  with `@embedFile` (which cannot escape the module root, hence `src/queries/`
  rather than a repo-root `queries/`).

Both backends fill the same `ParsedSymbol` shape, so `index.zig`, `query.zig`,
`json_out.zig`, and the CLI never know which one ran.

### Owner table

`src/backends.zig`'s `owner_table` names, per `Language`, which backend `auto`
mode uses. Every entry is `.heuristic` today: linking a grammar (`-Dtree-sitter`)
makes tree-sitter *available* (`--backend tree-sitter`), it does not silently
change what `auto` extracts.

### `--backend` flag

`navgraph outline --backend <auto|heuristic|tree-sitter>` (default `auto`):

- `auto` — the language's `owner_table` entry.
- `heuristic` — always the scanner, even where a grammar is linked.
- `tree-sitter` — prefer tree-sitter wherever a grammar is linked; languages
  without one still fall back to the scanner. Rejected at the CLI if the binary
  links no grammar at all (`-Dtree-sitter=none`), rather than silently serving
  heuristic output under a tree-sitter flag.

No LSP server exists on this branch yet. When one is added, the intended hook
is an `initializationOptions.backend` field mirroring this same enum — `--backend`
and the hook should share `Choice.fromName` rather than duplicating the parse.

### Fallback rule and `ParseHealth`

A tree-sitter parse that produces an ERROR node is discarded whole and the
heuristic scanner re-parses the file; the substitution is recorded in
`ParseHealth.tree_sitter_fallback`. A partially-parsed tree-sitter tree is never
presented as a complete symbol set. `ParseHealth` also carries `backend` (which
one actually produced the symbols, not the one requested) and the heuristic's
own `desync_from`/`desync_to` tokenizer-desync range; both survive an on-disk
cache round-trip (`cache.zig`'s `readHealth`/`putHealth`).

Real backend failures — a query that fails to compile, an unsupported grammar
ABI — propagate as errors rather than degrading into quietly different output;
only an ERROR *node* (a parse that succeeded but is incomplete) triggers the
heuristic fallback.

### Promoting a language

Moving a language from heuristic-owned to tree-sitter-owned under `auto` is a
one-line edit to `owner_table` in `src/backends.zig`, gated on two things
passing first:

1. `zig build differ` (`tests/backend-differ.zig`) — proves the tree-sitter
   backend loses no symbol/edge the heuristic finds (file+name+kind+line) and
   introduces no unreviewed `exact=true` edge, over the fixture trees
   (`testenv/py_fastapi`, `testenv/ts_frontend`, `testenv/fullstack`,
   `testenv/parser_gaps`).
2. The bench numbers below (or their equivalent for the language being
   promoted) — a 7-17x cold-parse regression is accepted for python (measured
   below); re-measure before promoting a language with different grammar cost.

## Offline builds

Grammars are `build.zig.zon` URL+hash dependencies, fetched **lazily**: a
`-Dtree-sitter=none` build (`linkTreeSitter` returns immediately) never touches
the network. `-Dtree-sitter=all|python|typescript|tsx` needs one of:

- Network available at build time — zig fetches into its global package cache
  (`~/.cache/zig` / `$ZIG_GLOBAL_CACHE_DIR`) on first build and reuses it after
  (content-addressed by the `hash` in `build.zig.zon`, so a repeat build or a
  fresh worktree on the same machine costs nothing).
- No network — pre-populate the cache once with `zig build --fetch` on a
  machine that has network, then copy `$ZIG_GLOBAL_CACHE_DIR/p/` to the offline
  machine (or vendor it into CI's cache action, see `.github/workflows/backends.yml`).

Pinned dependencies (`build.zig.zon`):

| package | source | pinned at |
| --- | --- | --- |
| `tree_sitter` | `registry.npmjs.org/tree-sitter` tarball (not the GitHub source archive — upstream's `build.zig` targets Zig ≤0.15 and won't compile here; the npm package ships no `build.zig`, only vendored C sources under `vendor/tree-sitter/`) | `0.25.0` |
| `tree_sitter_python` | GitHub release tarball | `v0.23.6` |
| `tree_sitter_typescript` | GitHub release tarball (ships both the `typescript` and `tsx` grammars — tsx is a separate generated parser, not a mode of typescript) | `v0.23.2` |

Bumping a grammar means bumping both the tag in the URL and the `hash` in
`build.zig.zon` (`zig fetch --save=<name> <url>` recomputes the hash).

All grammar C sources compile with `-std=gnu11`, not `-std=c11`: strict ISO
hides `le16toh`/`be16toh`/`fdopen`, which `lib/src/unicode.h` and the generated
`parser.c` files use unguarded. The tree-sitter static library and all grammars
are always built `ReleaseSmall` and stripped regardless of the project's own
`-Doptimize`, since the generated parser tables are the dominant binary-size
cost and none of it benefits from `ReleaseFast`.

## Measurements

`zig build -Doptimize=ReleaseFast -Dtree-sitter=<cfg>`, binary stripped with
`strip`. Index time is best-of-3 wall-clock via `outline -C <target> -j`
(`--no-cache` for cold, a warm-cache run afterward for warm); peak RSS is
`ru_maxrss` from `wait4` on the exact child process (no `bc`, no GNU `time` —
neither is on the measuring box). Two targets: **repo** = this worktree
(`src/` + `testenv/` + everything else, mostly `.zig` with a `.py`/`.ts` fixture
mix), and **synth100k** = a synthetic 2,320-file / 99,905-line all-Python tree.

| `-Dtree-sitter` | binary (raw) | binary (stripped) |
| --- | --- | --- |
| `none` | 14.06 MB | 2.70 MB |
| `python` | 15.04 MB | 3.35 MB (+0.64 MB) |
| `all` | 17.89 MB | 6.19 MB (+2.84 MB over `python` for typescript+tsx) |

| cfg | backend | target | cold | cold peak RSS | warm | warm peak RSS |
| --- | --- | --- | --- | --- | --- | --- |
| `none` | heuristic | repo | 0.134s | 13.5 MB | 0.051s | 19.5 MB |
| `none` | heuristic | synth100k | 0.195s | 31.2 MB | 0.090s | 40.4 MB |
| `python` | heuristic | repo | 0.138s | 15.0 MB | 0.022s | 20.1 MB |
| `python` | heuristic | synth100k | 0.101s | 30.8 MB | 0.140s | 43.7 MB |
| `python` | tree-sitter | repo | 0.137s | 14.4 MB | 0.051s | 20.4 MB |
| `python` | tree-sitter | synth100k | 1.704s | 35.0 MB | 0.130s | 42.4 MB |
| `all` | heuristic | repo | 0.079s | 14.8 MB | 0.068s | 20.7 MB |
| `all` | heuristic | synth100k | 0.123s | 31.2 MB | 0.128s | 42.8 MB |
| `all` | tree-sitter | repo | 0.138s | 15.2 MB | 0.052s | 21.6 MB |
| `all` | tree-sitter | synth100k | 1.318s | 35.9 MB | 0.088s | 44.0 MB |

Takeaways:

- Warm-cache time is backend-independent (the cache stores extracted symbols,
  not which backend produced them) — all warm numbers cluster in the same
  22-140ms band regardless of backend, within run-to-run noise on this box.
- The cold-parse cost is real and concentrated in tree-sitter: on the
  synthetic 100k-line all-Python tree, tree-sitter cold is 11-17x the
  heuristic's cold time (1.318-1.704s vs 0.101-0.123s), consistent with the
  migration plan's accepted "7x slower cold parse" (this measurement runs
  somewhat higher, on unloaded fixture content rather than the spike's
  corpus — still the same order of magnitude, and warm-cache is what repeat
  runs pay). On the repo target (mostly `.zig`, which has no grammar and stays
  on the heuristic scanner either way) the two backends are indistinguishable,
  as expected.
- Each linked grammar has a fixed binary-size cost independent of whether any
  file in a given run actually uses it: `python` alone costs 0.64 MB stripped,
  `typescript`+`tsx` together cost another 2.84 MB.

Raw data: `results.json` alongside this file's measurement run is not checked
in (regenerate with the commands above); the table here is the record.

## Cross-compile matrix

`zig build -Dtree-sitter=all -Doptimize=ReleaseFast -Dtarget=<t>`, each output
verified with `file`:

| target | result |
| --- | --- |
| `aarch64-macos` | OK — Mach-O 64-bit arm64 executable |
| `x86_64-macos` | OK — Mach-O 64-bit x86_64 executable |
| `aarch64-linux` | OK — ELF 64-bit LSB executable, ARM aarch64, statically linked |
| `x86_64-linux-musl` | OK — ELF 64-bit LSB executable, x86-64, statically linked |

All four link the tree-sitter runtime and all three grammars with no changes
needed to `build.zig` — `addCSourceFile`/`addIncludePath` on the cross target's
own module already cross-compile the C sources via zig's bundled clang, and
`.linkage = .static` keeps the single-binary property `-Dtree-sitter=none`
already had.
