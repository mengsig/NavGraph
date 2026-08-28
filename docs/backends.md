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

`serve` accepts it too, and the session reuses the choice across reloads.

The on-disk cache is keyed on the backend that produced each entry, so
`--backend` decides the same thing warm as it does with `--no-cache`. A cached
entry answers only when the backend owning that file under the current
`--backend` produced it; a file the grammar could not parse cleanly was
heuristic-parsed *on purpose*, so its entry answers for `tree-sitter` and not
for `heuristic`. Switching backends therefore costs one full re-parse and
rewrites the cache (measured below).

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

The substitution is also reported: `navgraph: parse-health: <file>: the grammar
could not parse this file cleanly — indexed with the heuristic scanner instead`.
A user who asked for `--backend tree-sitter` can tell which files did not get
it. A query cursor that exceeds its match limit takes the same whole-file exit —
a dropped match would present a silently short symbol set as a complete one.

### Build identity

`capabilities -j` publishes the linked grammars (`build.grammars`), and the
`--backend` enum omits `tree-sitter` on a build that links none — the manifest
is the agent contract, so it must not advertise a value the binary refuses. The
grammar selection is folded into the source fingerprint, so `-Dtree-sitter=none`
and `-Dtree-sitter=all` have distinct `buildId`s and cannot share a cache.

### Visibility and ownership

The two backends agree on what is public API, which the differ asserts symbol
for symbol. Python uses the leading-underscore rule; TypeScript uses the
`export` keyword, and an `export` does not reach through a class, interface,
enum, type-alias or object-literal body — `export class C { m() {} }` exports
`C`, not `C.m`, and `export const h = { save() {} }` exports `h`, not
`h.save`. The rule is one token per node shape (`isMemberList` in
`ts_backend.zig`); every member-list shape stops the walk the same way.

A member named twice is one symbol: a field declared and then assigned on
`this`/`self`, or an overload signature standing next to its implementation. A
`get`/`set` pair is two real members and stays two. A container declared inside
a function belongs to that function; a nested helper function stays parentless
and keeps resolving by its bare name. An object literal's methods are parented
to the binding that owns the literal (`h.save` above), the same rule.

### Reference chain heads

`model.Reference.receiver_root` records the identifier heading a receiver chain
(`o.store.Get()` -> `o`), which is how the resolver tells a field access from a
bare module qualifier. The tree-sitter backend derives it from the tree rather
than from a capture — a capture would need one pattern per chain depth — and
the differ asserts it matches the heuristic scanner's in both directions, so a
chain head either backend invents where the other emits none is caught too.

Owner attribution (which callable a reference site belongs to) is linear in
nesting depth, not in the file's definition count: `defs` is sorted
outer-before-inner and spans nest, so one binary search plus a walk up the
enclosing chain finds the innermost callable. The per-site linear scan this
replaced made a single large module quadratic — 12 000 definitions in one file
cost 1.141 s, against 0.268 s now.

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
   promoted) — a 10-13x cold-parse regression is accepted for python (measured
   below); re-measure before promoting a language with different grammar cost.
3. The differ's `exported`, `receiver_root` and attribution-cost assertions,
   which are what make "the resolver behaves the same" more than a claim.

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
  machine (or vendor it into CI's cache action, see `.github/workflows/ci.yml`).

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
`strip`. Index time is best-of-3 wall-clock via `outline -C <target> -j -l 1`
(`--no-cache` for cold, a warm-cache run afterward for warm); peak RSS is
`ru_maxrss` from `wait4` on the exact child process. Two targets: **repo** =
this worktree (`src/` + `testenv/` + everything else, mostly `.zig` with a
`.py`/`.ts` fixture mix), and **synth100k** = a synthetic 1,780-file /
99,680-line all-Python tree of 6 documented classes per module, each with a
constructor assigning two `self` fields and a method calling a module-level
helper.

| `-Dtree-sitter` | binary (raw) | binary (stripped) |
| --- | --- | --- |
| `none` | 14.13 MB | 2.73 MB |
| `python` | 15.35 MB | 3.42 MB (+0.69 MB) |
| `all` | 18.20 MB | 6.26 MB (+2.84 MB over `python` for typescript+tsx) |

| cfg | backend | target | cold | cold peak RSS | warm | warm peak RSS |
| --- | --- | --- | --- | --- | --- | --- |
| `none` | heuristic | repo | 0.145s | 15.4 MB | 0.052s | 20.7 MB |
| `none` | heuristic | synth100k | 0.113s | 31.3 MB | 0.074s | 34.1 MB |
| `python` | heuristic | repo | 0.137s | 15.6 MB | 0.053s | 22.8 MB |
| `python` | heuristic | synth100k | 0.121s | 28.3 MB | 0.077s | 32.8 MB |
| `python` | tree-sitter | repo | 0.146s | 15.8 MB | 0.043s | 22.8 MB |
| `python` | tree-sitter | synth100k | 1.229s | 42.0 MB | 0.103s | 50.6 MB |
| `all` | heuristic | repo | 0.138s | 15.3 MB | 0.053s | 23.3 MB |
| `all` | heuristic | synth100k | 0.117s | 28.8 MB | 0.086s | 34.9 MB |
| `all` | tree-sitter | repo | 0.138s | 15.3 MB | 0.060s | 23.0 MB |
| `all` | tree-sitter | synth100k | 1.566s | 42.7 MB | 0.106s | 51.6 MB |

Switching backends over an existing cache (`-Dtree-sitter=all`, synth100k):

| run | time |
| --- | --- |
| cold heuristic, writes the cache | 0.133s |
| warm heuristic, same backend | 0.060s |
| first tree-sitter run over that cache | 1.538s |
| warm tree-sitter, same backend | 0.108s |
| first heuristic run again | 0.130s |

Takeaways:

- A warm run is only warm within one backend. The cache records which backend
  produced each entry, so switching re-parses the tree and rewrites it — the
  price of `--backend` meaning the same thing warm as cold. Repeat runs on one
  backend cost 0.06-0.11s either way.
- The cold-parse cost is real and concentrated in tree-sitter: on the synthetic
  100k-line all-Python tree, tree-sitter cold is 10-13x the heuristic's cold
  time (1.229-1.566s vs 0.117-0.121s), consistent with the migration plan's
  accepted "7x slower cold parse" — same order of magnitude, and warm-cache is
  what repeat runs pay. On the repo target (mostly `.zig`, which has no grammar
  and stays on the heuristic scanner either way) the two backends are
  indistinguishable, as expected.
- Each linked grammar has a fixed binary-size cost independent of whether any
  file in a given run actually uses it: `python` alone costs 0.69 MB stripped,
  `typescript`+`tsx` together cost another 2.84 MB.

The corpus is regenerated per measurement run rather than checked in; the
table here is the record.

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
