# NavGraph editor protocol — v1

`navgraph lsp` runs NavGraph as a resident editor
server: the whole code graph stays in memory, an edit re-indexes in tens of
milliseconds or less, and blast-radius / search / call-graph queries answer in
single-digit milliseconds. Measured figures are in the table below.

It is a standard LSP server (a subset) **plus** custom `navgraph/*` methods.
Neovim's built-in client (`vim.lsp.start`) is the reference client.

```
navgraph lsp [-C|--root <dir>] [--log <file>] [--log-level error|info|debug]
```

- **Transport** — JSON-RPC 2.0 over stdio with LSP framing
  (`Content-Length: N\r\n\r\n<json>`). A bare `\n` after the header is accepted
  too, so hand-written scripts work.
- **stdout is the protocol channel.** Nothing else is ever written there.
  Diagnostics go to stderr, or to `--log <file>` (truncated per run).
- **`--root`** pins the index root. Without it the root is the workspace sent in
  `initialize` (`rootUri`, else the first `workspaceFolders` entry, else
  `rootPath`), falling back to the current directory.

## Positions and encodings

Positions are LSP-style: 0-based `line` and `character`. The server negotiates
`positionEncoding: "utf-8"` when the client offers it in
`general.positionEncodings`, otherwise UTF-16 with correct conversion on
non-ASCII lines (an astral code point counts as a surrogate pair; a column
landing inside a multi-byte sequence snaps to that sequence's start).

Symbol `line` / `endLine` in navgraph payloads stay **1-based**, matching the
CLI's JSON. LSP `Location` / `Range` values are **0-based**, per spec. `uri`
fields are `file://` URIs; `file` fields are root-relative paths, exactly as the
CLI prints them.

## Standard LSP

| Method | Notes |
| --- | --- |
| `initialize` | Capabilities below. |
| `initialized` (notif) | Builds the index (using `.navgraph/cache` like the CLI), reports `$/progress`, and ends with `navgraph/indexed` — or, if indexing failed, with `window/logMessage` and no index. |
| `shutdown` → `null`, `exit` | `exit` after `shutdown` exits 0, without it exits 1. stdin EOF exits 0. |
| `textDocument/didOpen` `didChange` `didSave` `didClose` | Overlay store; see below. |
| `textDocument/definition` → `Location[]` | The identifier at the position, resolved with the same rules as `calls`. |
| `textDocument/references` → `Location[]` | Every use site; the declaration is included when `context.includeDeclaration`. |
| `textDocument/hover` | Markdown: `kind name`, the fenced signature, `file:line-endLine`, `← N callers → M callees`, then the doc comment. |
| `textDocument/documentSymbol` → `DocumentSymbol[]` | Nested; `range` spans `line..endLine`, `selectionRange` covers the name. Reflects the overlay. |
| `workspace/symbol` → `SymbolInformation[]` | Ranked like `navgraph/search`; `limit` defaults to 200. The test scope is the server's `initializationOptions` one; per-request `strict`/`tests` are not read. |
| `workspace/didChangeWatchedFiles` (notif) | Re-stats the listed files and re-indexes. |
| `$/cancelRequest`, `$/setTrace` (notif) | Accepted and ignored. |

`initialize` advertises:

```jsonc
{"capabilities": {
  "positionEncoding": "utf-8",                     // or "utf-16"
  "textDocumentSync": {"openClose": true, "change": 1, "save": {"includeText": false}},
  "definitionProvider": true, "referencesProvider": true, "hoverProvider": true,
  "documentSymbolProvider": true, "workspaceSymbolProvider": true,
  "experimental": {"navgraph": {"protocolVersion": 1,
    "methods": [ /* every callable navgraph/* request */ ],
    "notifications": [ /* every navgraph/* notification the server sends */ ]}}
}, "serverInfo": {"name": "navgraph", "version": "…"}}
```

`initializationOptions` (all optional):

| Field | Default | Meaning |
| --- | --- | --- |
| `tests` | `"with"` | `with` \| `without` \| `only` — the test-code scope. |
| `strict` | `false` | Follow only high-confidence (type/self-bound) edges. |
| `debounceMs` | `120` | How long an edit waits before re-indexing. `0` and negatives mean "use the default", not "no debounce". |
| `watch` | `true` | Poll file mtimes for out-of-editor changes. |
| `watchIntervalMs` | `2000` | Poll interval. |
| `depth` | `3` | Default graph depth (max 10). |

### Overlays

An open document's text overrides the disk copy everywhere the server reads
source: indexing, `navgraph/grep`, hover, and position lookups. `didChange`
(Full sync — the last content change wins) schedules a debounced re-index of
that file; `didClose` drops the overlay and the disk copy is re-read; `didSave`
re-stats the file. Every re-index ends with `navgraph/indexed`.

An overlay for a path that does not exist on disk is indexed as a new file, and
disappears again when the buffer is closed.

## Errors

| Code | When |
| --- | --- |
| `-32700` | A frame body that is not JSON, or a frame the server could not parse. The server resyncs and keeps serving. |
| `-32600` | Not a JSON-RPC request, or a request before `initialized`. |
| `-32601` | Unknown method. |
| `-32602` | Bad params: a missing required field, an ill-typed *required* field, an unknown `direction` or `tests` scope, a grep pattern that will not compile or is too long or too deeply nested, an unindexed file. An ill-typed *optional* field (e.g. `{"strict":"yes"}`) falls back to its default instead of erroring. |
| `-32603` | Internal failure (allocation, IO). |
| `-32001` | A `Target` that resolves to nothing — `{"code": -32001, "message": "…: symbol not found"}`. An error object never carries `data`. |
| `-32002` | The request could not be completed: a grep regex that exhausts one of the bounds below, or a `navgraph/diff` / `{ref}` target whose `git diff` failed (bad ref, no git tree, git unavailable). |

A malformed *notification* gets no reply, per JSON-RPC — with one exception: a
body the server cannot parse at all has no id to identify it as a notification,
so it is answered with `-32700` and `"id": null`. Nothing a client can send
kills the server.

### Resynchronizing

A frame the server cannot parse costs exactly that frame. The reader does not
resume at the offending header line — a malformed frame's body would then be
read back as headers, and a JSON body has enough colons in it to look like
headers forever — it hunts forward for the next `Content-Length:` instead,
across as many reads as that takes. So the request behind a bad header is still
answered, and `shutdown` / `exit` always land.

One run of garbage produces one `-32700`, however many reads it spans, so a bad
client cannot turn one bad header into a storm of replies. Limits that surface
this way: a body over 32 MiB and a header block over 8 KiB are both refused
without being buffered.

## Shared result shapes

```
Symbol { id:int, name:string, qualified:string, kind:string, file:string, uri:string,
         line:int, endLine:int, sig:string, doc?:string, language:string,
         callers:int, callees:int, exported:bool, test:bool }
Node   { symbol:Symbol, exact:bool, lines:int[], children:Node[], ext:string[], recursion:bool }
Edge   { from:int, to:int, exact:bool, lines:int[] }
Target = { uri:string, position:{line,character} } | { symbol:string }
Scope  = { strict?:bool, tests?:"with"|"without"|"only" }
```

- `qualified` is `Parent.name` for a nested definition, else `name` — the form
  `{ symbol: … }` accepts back.
- `kind` and `language` use the CLI's short tags (`fn`, `method`, `struct`, …;
  `zig`, `py`, `ts`, …).
- `id` is a graph index, **stable only within one index generation.** Every
  re-index renumbers; clients refresh open views on `navgraph/indexed`.

## Custom requests

### `navgraph/status` `{}`

```
{ root, protocolVersion:1, version:string, files, symbols, edges,
  languages:{<lang>:files}, overlays:int, indexedAt:string(ISO-8601),
  lastIndexMs:int, cache:bool }
```

`cache` reports whether the on-disk parse cache served the last full walk.

### `navgraph/symbolAt` `{ uri, position }`

```
{ word:string, symbol:Symbol|null, enclosing:Symbol|null, candidates:Symbol[] }
```

`candidates` lists the same-name definitions that were **not** chosen.

Resolution order — the graph's own, not a fresh guess:

1. The cursor is on a definition's own name → that definition.
2. Otherwise the enclosing body's already-resolved reference for that name on
   that line (receiver- and import-aware, exact edges preferred).
3. Otherwise a name lookup, preferring a definition in the cursor's own file.

### `navgraph/blast`

Params: `Target | { file:string } | { ref:string }`, plus
`{ depth?:int, direction?:"callers"|"callees", limit?:int (500), offset?:int
(0) } & Scope`.

```
{ roots:Symbol[],
  nodes:[{ symbol:Symbol, depth:int, via:int[], exact:bool }],
  edges:Edge[],
  summary:{ symbols:int, total:int, files:int, tests:int, maxDepth:int,
            truncated:bool, byDepth:int[], byFile:[{file:string,count:int}] },
  next:int|null }
```

- `{ file }` unions every definition in that file. `{ ref }` is every definition
  changed since that git ref (`navgraph diff`'s rule) **plus** every definition
  in a file whose unsaved buffer differs from the copy on disk.
- Breadth-first to `depth`; each symbol appears once, at its **minimum** depth.
  The walk always covers the full depth-bounded reachable set — `nodes`/`edges`
  are the `[offset, offset+limit)` page of it, in that same stable BFS order;
  `edges` is restricted to edges whose caller/callee-walk source is on the page.
- `via` names the depth-1 neighbours the node was reached through.
- `edges` are always written caller→callee, whichever direction the walk ran.
- `byFile`/`byDepth`/`maxDepth`/`tests` describe the page in `nodes`, matching
  `symbols` (`nodes.length`) — `summary.total` is the true reachable count,
  independent of paging.
- `truncated` is set when the page doesn't reach `total`; `next` is the
  `offset` for the following page, or `null` once nothing remains.

### `navgraph/search`

Params: `{ query:string, kinds?:string[], refs?:bool, limit?:int (50) } & Scope`.

```
{ items:[{ symbol:Symbol, score:int, matches:int[], lines?:int[] }], total:int }
```

Fuzzy subsequence match on `qualified`, ranked **exact > prefix >
word-boundary > substring > subsequence**; ties break on fan-in, then the
shorter file path, then the symbol id (so paging is stable). `matches` holds the
byte offsets in `qualified` where the query characters landed. `total` counts
every match, before `limit`.

With `refs: true` the query matches **use sites** instead: an item's `symbol` is
the *referencing* definition and `lines` lists its use-site lines. The pattern
grammar is the CLI's `search --refs` one, so `Recv.field` and `.field` pin
instance-attribute reads.

### `navgraph/grep`

Params: `{ pattern:string, regex?:bool (false), caseSensitive?:bool (false),
limit?:int (200), include?:string[] }`.

```
{ items:[{ file, uri, line:int(1-based), character:int(0-based), text:string,
           enclosing:Symbol|null }], total:int, truncated:bool }
```

Runs over the in-memory, overlay-aware sources, so it sees unsaved edits.
`include` globs match the basename when the pattern has no `/`, else the
root-relative path; `*` stays within a segment, `**` crosses separators, `?` is
one character.

`regex: true` uses a small built-in engine: literals, `.`, character classes
(`[a-z]`, `[^…]`, `\d \w \s` and their negations), groups with alternation,
greedy and lazy `* + ? {n} {n,} {n,m}`, and the `^` `$` anchors. No
backreferences, no lookaround, no captures.

**Bounds.** The pattern comes off the wire, so the engine is bounded in time,
memory and stack, and neither half recurses. Worst case, per request:

| Bound | Limit | Over it |
| --- | --- | --- |
| Pattern length | 4096 bytes | `-32602` |
| Group nesting | 64 | `-32602` |
| Node visits, per grep request | 200 000 + 32 × bytes searched | `-32002` |
| Live backtrack alternatives | 16 384 | `-32002` |
| Live continuation frames | 16 384 | `-32002` |
| Matcher scratch | ≈ 2 MiB, allocated once per compiled pattern | — |
| Machine stack | constant — the parser and the matcher both walk explicit stacks | — |

The step allowance is **pooled across the whole request**, not granted per
line: grep runs the pattern once per line, so a per-line bound would leave the
request itself unbounded. It grows with the bytes actually searched, so an
honest whole-tree grep stays well inside it — seven ordinary regex greps over a
142 000-line tree answer in about a second, including the index — while a
pathological pattern gives up in tens of milliseconds. A quantifier over a
single-byte body (`.*`, `a+`, `[a-z]*`) holds its whole backtrack range as one
alternative rather than one per byte, so an ordinary scan of a minified `.js`,
`.css` or `.json` line stays linear. A pattern that is quadratic in the line
length anyway — `a+b` across 300 000 `a` — gives up with `-32002`; it never
hangs and never takes the server down.

### `navgraph/callers` / `navgraph/calls`

Params: `Target & { depth?:int (1), refs?:bool } & Scope` → `{ root:Node }`.
`{ file }` and `{ ref }` are accepted too, as for `navgraph/blast`, but a tree
has one root: only the first definition they resolve to is walked. Send a
`Target` unless you mean that.

Mirrors the CLI's `callers`/`calls -j` tree. `lines` on a child is every
call-site line of the edge to its parent; `ext` lists unresolved call targets;
`recursion` marks a node already on the path. Plain data reads (a module `var`,
`const` or field) are hidden unless `refs: true`, exactly as in the CLI.

### `navgraph/rescan` `{ full?:bool }` → the `navgraph/status` shape

Re-walks the tree, so files created or deleted outside the editor are picked up
(a git checkout, a formatter). `full: true` ignores the on-disk cache (and then
does not write one back). Open documents are re-applied afterwards, so unsaved
edits survive a rescan. The `navgraph/indexed` that follows carries the disk
delta in `changedFiles`: files created, deleted, or re-read with new content.
An open document is not listed — the index holds its buffer, which a rescan
does not touch.

### `navgraph/neighbors`

Params: `Target & Scope` → `{ items:[{ symbol:Symbol,
callees:[{symbol,exact,lines}], callers:[{symbol,exact,lines}] }] }`.

Callees and callers of one symbol, one level deep, in a single view — a
quicker "what's around this" than `blast`/`callers`/`calls`. One entry in
`items` per definition the `Target` resolves to — a name with several
definitions (overloads, same-named methods across files) gets an entry for
each, exactly as the CLI's `neighbors` does, not just the first. Unlike the
CLI, both sides go through the same `Scope` (`strict`/`tests`) every other
navgraph/* walk uses, for a consistent contract; and unlike `blast`/`callers`/
`calls`, plain data-read callees are always included (there is no `refs`
param here, matching the CLI's `-j` output).

### `navgraph/path`

Params: `{ from:string, to:string }` →
`{ path:Symbol[], ambiguousFrom:Symbol[], ambiguousTo:Symbol[] }`.

The shortest call path from `from` to `to` (BFS over resolved call/use edges),
source-first; `path` is empty when either name is unknown or no path exists.
Names accept the same `Parent.name` / `name@path` forms as every CLI name
argument.

A path is authoritative only between unique endpoints. When a name matches
several definitions the walk is not run and its candidates come back in
`ambiguousFrom` / `ambiguousTo`, so an ambiguous question is never answered as
"no path" — re-ask with `Parent.name` or `name@path`. Both arrays are empty on
an ordinary answer.

### `navgraph/outline`

Params: `{ path?:string, kinds?:string[], limit?:int (300) } & Scope` →
`{ files:[{file,lang,symbols:Symbol[]}] }`.

Every visible top-level (and nested) definition per file, in indexing order.
`path` is a substring filter over the root-relative path; `kinds` restricts to
kind tags (`fn`, `struct`, …).

### `navgraph/hot`

Params: `{ path?:string, limit?:int (25) } & Scope` →
`{ items:[{symbol,fanIn,fanInExact,fanInTest,fanOut,fanOutExact}] }`.

Functions/methods ranked by connectivity — the load-bearing symbols. `*Exact`
counts exclude heuristic (name-collision) edges; `fanInTest` is the share of
callers living in test files. `strict` drops entries whose connectivity is
entirely heuristic. Ranking and ordering are the CLI's own, tie-break included.

### `navgraph/unused`

Params: `{ path?:string, noPublic?:bool, followImports?:bool, limit?:int (300)
} & Scope` → `{ items:[{symbol,testOnly}] }`.

Zero-caller function/method/type definitions — removal candidates, not broken
code. `tests`: `with` (default) lists code dead in the whole graph;
`without` also flags code used only by tests (`testOnly: true`); `only` lists
unused test helpers. `noPublic` drops exported symbols (possible public API).
`followImports` disambiguates same-name symbols by import reachability instead
of the safe family-wide name tally — finds dead code masked by a used
same-name twin, at the cost of depending on import resolution.

### `navgraph/diff`

Params: `{ ref?:string ("HEAD"), depth?:int (1), direction?:"callers"|
"callees" ("callers"), limit?:int (500), offset?:int (0) } & Scope` →
`{ ref:string, blast: <the navgraph/blast result> }`.

Definitions changed since `ref` **plus** every definition in a file whose
unsaved buffer differs from disk, wrapped as a `navgraph/blast` walk from those
roots — the blast radius of a pending change. Unlike `navgraph/blast`'s own
`{ ref }` target form, an empty change set is not a `-32001` error here:
"nothing changed" is a routine answer, not a failed lookup. A `ref` git
rejects, or a served root that is not a git tree, **is** an error —
`-32002` with git's own message — so a mistyped ref is never reported as a
clean tree; this also applies to `navgraph/blast`'s `{ ref }` form.

### `navgraph/routes`

Params: `{ filter?:string, limit?:int (300) }` →
`{ items:[{symbol,handler:Symbol|null,callers:Symbol[]}] }`.

Every HTTP route (`symbol.name` is `"METHOD /path"`, e.g. `"GET /api/orders"`),
its resolved handler definition, and the client call sites that hit it.
`filter` is a substring match over the route name.

### `navgraph/events`

Params: `{ filter?:string, limit?:int (50) }` →
`{ groups:[{key,sites:[{role:"handler"|"emitter", verb, file, uri, line, in?}]}] }`.


Message-bus handlers (`register`/`on`) linked to emitters (`send`/`emit`) by
their shared string key, key-sorted, paired keys first. `in` names the
enclosing definition when the site sits inside one. `limit` caps the number of
key groups returned.

### `navgraph/imports`

Params: `{ path?:string, limit?:int (300) }` →
`{ files:[{file,uri,imports:[{target,targetUri,binding}]}] }`.

The local modules each in-scope file imports (resolved edges only). `path` is
a substring filter over the importing file's path. `limit` caps the number of
files listed (each file's full import list still comes through).

### `navgraph/importers`

Params: `{ path:string }` → `{ files:[{file,uri,importers:[{file,uri}]}] }`.

Files that import the file(s) matching `path` — reverse dependencies. `path`
is required (a substring filter over the imported file's path).

### `navgraph/graph`

Params: `{ path?:string } & Scope` →
`{ path:string, nodes:int, nodesTotal:int, truncated:bool }`.

Renders the same interactive HTML visualization as `navgraph graph` and writes
it to `.navgraph/graph-<hash>.html` under the served root. `<hash>` identifies
the *view* (the path filter and test scope), so re-requesting it overwrites
that one file in place instead of leaving one page per edit behind. The write
is an atomic rename that refuses to follow a symlink planted at the path, and a
write failure is reported rather than swallowed. `path` is returned
root-relative; open it in a browser. `tests` selects whether test symbols
appear in the graph (`strict` has no effect here).

The page holds at most `nodes` of `nodesTotal` symbols — the renderer's own
node cap, which the HTML has nowhere to report. `truncated` says the view is
partial, so a client can say so rather than present a capped subgraph as the
graph.

## Notifications (server → client)

- **`navgraph/indexed`** `{ reason:"initial"|"change"|"save"|"rescan"|"watch",
  files:int, symbols:int, edges:int, ms:int, changedFiles:string[] }` — sent
  after every (re)index that produced a graph. Clients refresh open views on it.
  `changedFiles` is the dirty set for an edit and the disk delta for a rescan;
  it is empty for `"initial"`. A *failed* index sends `window/logMessage` (and
  a `$/progress` end) instead, and leaves the server without an index — every
  graph request then answers `-32600`.
- **`$/progress`** for the initial index, after a
  `window/workDoneProgress/create` request, and only when the client advertised
  `window.workDoneProgress`. The client's answer to that request is accepted
  and dropped — a response is never replied to.
- **`window/logMessage`** for diagnostics.

## Watching

With `watch: true` the server polls the mtime/size of every indexed file every
`watchIntervalMs`; a change re-indexes it and emits `navgraph/indexed` with
`reason: "watch"`. A file the editor holds open is skipped — the buffer is
authoritative while a document is open. Files *created* outside the editor are
picked up by `navgraph/rescan` or `workspace/didChangeWatchedFiles`, not by the
mtime poll (which only re-stats files it already knows). Editor notifications
remain the primary realtime path.

## Concurrency model

**There is none, by construction.** The server is single-threaded: one timed
read on stdin drives everything.

- When the read returns bytes, complete frames are extracted and dispatched one
  at a time. A request is answered before the next is read.
- When the read times out, the debounce window or the watcher interval is due,
  and the loop does that work inline. The read deadline is always the soonest of
  the two, so neither is starved by an idle client.
- Every handler that reads the graph flushes pending edits first. A request that
  arrives mid-debounce therefore sees those edits — it waits for the index
  rather than answering from a stale graph.

The index, the overlays, the reader and the writer are all owned by that one
thread. No shared mutable state, no lock, and no data race is possible.
`$/cancelRequest` is accepted and ignored because there is never a request in
flight to cancel.

This is a deliberate departure from "a watcher thread": a thread would buy
nothing here (an mtime scan of a large tree is a few milliseconds, and indexing
must serialize with queries anyway) and would cost a mutex around the graph.

### Memory ownership

The initial walk's arena owns every file's text and parse output. When a file is
re-parsed its slot takes a private arena holding the newer copy; the arena the
*live* index still points into is retired and freed only once the replacement
index is in place. So a re-index never frees memory a served response might
still reference, and steady-state memory is the initial walk plus one arena per
currently-edited file — under realistic editing. There is no leak (the Debug
build's leak-detecting allocator is silent over long runs); on **ReleaseFast**
specifically, the allocator retains rather than reuses freed per-generation
arenas, so RSS grows roughly linearly under an edit pattern dominated by
*brand-new* symbol names — about 72 kB per re-index at 600 new names per edit.
Realistic edits (existing names, growing bodies, a handful of new names) show
no measurable growth; only heavy sustained refactoring of a large file will
drift RSS above the steady-state figure below.

## Measured performance

Zig 0.16.0, `-Doptimize=ReleaseFast`, Linux x86-64. "server" is the `ms` the
server reports in `navgraph/indexed`; query figures are the best of seven round
trips over the pipe. Ranges span two independent runs — cold-cache indexing in
particular varies with page-cache warmth.

| Measurement | This repo (30 files, ~23k lines) | 59k-line tree (250 files) | 118k-line tree (500 files) |
| --- | --- | --- | --- |
| Initial index, cold cache | **36–46 ms** | 67–107 ms | 96–129 ms |
| Initial index, warm cache | **14–16 ms** | 31–36 ms | — |
| Single-file re-index (debounce excluded) | **4–10 ms** | **7–19 ms** | — |
| `navgraph/search` | **1.2–2.1 ms** | 3.2 ms | — |
| `navgraph/grep` (literal) | **1.9–3.4 ms** | 6.4–6.6 ms | — |
| `navgraph/blast` depth 3 | **0.1 ms** | 0.4–0.5 ms | — |
| `navgraph/callers` depth 2 | **≤ 0.1 ms** | 0.2 ms | — |
| Peak resident memory | 10.8 MB | 20.5 MB | **34.8–36.1 MB** |

Against the v1 targets: initial index of this repo < 1 s (36–46 ms), single-file
re-index < 100 ms on a 50k-line tree (7–19 ms), search / grep / blast(3) each
< 30 ms (≤ 6.6 ms, on the 59k-line tree), resident memory < 200 MB at 100k lines
(≈ 35 MB).

**Targeted re-resolution was measured and is not needed.** A re-index re-parses
only the changed file and re-assembles the graph from the already-parsed rest;
full reference re-resolution over a 59k-line tree costs single-digit to low-tens
of milliseconds, an order of magnitude inside the budget. Restricting resolution
to the files affected by a changed definition would add real complexity (and a
new correctness surface) to buy nothing measurable, so the simple whole-graph
re-assembly stands.

Reproduce with a client that drives the binary over a pipe: `initialize` →
`initialized`, read the `ms` from `navgraph/indexed`, then time
`didChange` → `navgraph/status` round trips and the query methods.

## Hostile input

`zig build smoke` replays a hostile session into the built binary and checks
what comes back: a 20 000-deep regex, an ordinary pattern over a 300 000
character line, and a malformed header with a body — each followed by a request
that must still be answered. It then walks stdout as an exact frame stream
(every byte inside a frame, the last ending at EOF), requires a
`navgraph/blast` result shape that only the `navgraph/*` handlers can produce,
and requires the process to exit 0. CI runs it against the ReleaseFast build.

## Limitations

- Symbol ids are per-generation (see above).
- `textDocument/definition` returns the resolved definition first, then the
  other same-name candidates, so an ambiguous name still offers every choice.
- The parse cache is not written while a document is open: the live index then
  holds unsaved text, which must never be stored in a cache keyed by disk mtime.
- No diagnostics are published — NavGraph is a navigator, not a compiler.
- `navgraph/diff` (and `navgraph/blast`'s `{ ref }` form) misses an untracked
  file: `git diff` never lists one, and an unsaved buffer whose text matches
  the new file on disk looks unchanged to the overlay half too. Matches the
  CLI's `diff`, which has the same gap. Save the file under a tracked path (or
  `git add` it) to bring it into `diff`'s view.

## 1.1

Additive to v1: `protocolVersion` stays `1`; `navgraph/status` gains
`protocolMinor: 1`. Every method below is listed in
`experimental.navgraph.methods` only once implemented — a client builds its
method list from that array, never from this document's version number alone.

`Symbol` gains `contentHash:string` — a stable hash of the definition's source
text (signature + body), whitespace-normalized so reformatting alone does not
change it. Key per-site client state (e.g. an approved-impact marker) on
`qualified@file` + `contentHash`, so it invalidates when the code actually
changes.

### Standard LSP additions

| Method | Result |
| --- | --- |
| `textDocument/prepareCallHierarchy` | `CallHierarchyItem[]` |
| `callHierarchy/incomingCalls` | `CallHierarchyIncomingCall[]` |
| `callHierarchy/outgoingCalls` | `CallHierarchyOutgoingCall[]` |
| `textDocument/prepareTypeHierarchy` | `TypeHierarchyItem[]` |
| `typeHierarchy/supertypes` / `subtypes` | `TypeHierarchyItem[]` |
| `textDocument/implementation` | `Location[]` |
| `textDocument/typeDefinition` | `Location[]` |
| `textDocument/documentHighlight` | `DocumentHighlight[]` |
| `textDocument/codeLens` | `CodeLens[]`; `codeLens/resolve` is a no-op (the lens is already fully populated) |

```
CallHierarchyItem { name, kind:int, uri, range, selectionRange,
                     data:{ id:int, qualified:string, file:string, exact?:bool } }
```

`data` is what `incomingCalls`/`outgoingCalls`/`supertypes`/`subtypes` re-resolve
from — by `qualified`+`file`, not the possibly-stale `id` (ids are only stable
within one index generation). Heuristic (non-exact) edges are still returned;
`data.exact` carries the flag on a call-hierarchy item (a type-hierarchy edge
has no separate confidence bit, so `exact` is omitted there).

```jsonc
// -> textDocument/prepareCallHierarchy {textDocument:{uri}, position}
[{"name":"mid","kind":12,"uri":"file:///…/app.zig",
  "range":{"start":{"line":7,"character":0},"end":{"line":9,"character":1}},
  "selectionRange":{"start":{"line":7,"character":3},"end":{"line":7,"character":6}},
  "data":{"id":3,"qualified":"mid","file":"app.zig"}}]

// -> callHierarchy/incomingCalls {item}
[{"from":{"name":"run", …}, "fromRanges":[{"start":{"line":4,"character":4},"end":{"line":4,"character":7}}]}]
```

`textDocument/implementation` covers both member- and type-level conformance:
implementors of an interface/trait/protocol **method**, or of a **type**
(structural port relations plus keyword-declared subtypes, so duck-typed
Python and keyword-typed Java/TS/C#/Go/Ruby both surface here).
`textDocument/typeDefinition` answers from the enclosing body's own typed
bindings (`name: TypeName` locals/params) — empty, never an error, when the
identifier under the cursor has no recorded binding.

`textDocument/documentHighlight` reports every reference site of the symbol
under the cursor **in the current document only**: the definition itself
(`kind: 1`, Text) and each use (`kind: 2` Read or `kind: 3` Write, when known).

```jsonc
// -> textDocument/codeLens {textDocument:{uri}}
[{"range":{"start":{"line":7,"character":0},"end":{"line":9,"character":1}},
  "command":{"title":"1 callers · 1 callees","command":"navgraph.blast",
             "arguments":[{"symbol":"mid@app.zig"}]}}]
```

One lens per definition with a call-graph presence; `command.arguments[0].symbol`
is a `name@file` string, the same form `Target.symbol` accepts, so a client can
wire the lens straight into a `navgraph/blast` (or `navgraph/impact`) request.

### `navgraph/impact`

Params: `({ uri?:string, range?:{start:{line,character},end:{line,character}} } |
{ ref?:string }) & { depth?:int, direction?:"callers"|"callees", limit?:int(500),
offset?:int(0) } & Scope`.

```
{ roots:Symbol[], nodes:[…], edges:Edge[], summary:{…}, next:int|null,
  hunks:[{ uri:string, range:Range, roots:Symbol[] }],
  changeId:string }
```

The blast radius of the current **working change**, grouped by changed hunk —
`navgraph/blast`'s result shape (including its `offset`/`summary.total`/`next`
paging — B1: a response with more blast radius than `limit` shows must report
the true size and a working continuation, not a `truncated:true` dead end)
plus `hunks`. Two sources:

- No `ref`: the working change is every open document whose buffer differs
  from disk (overlay vs disk); `uri` narrows to one document. A hunk is the
  common-prefix/common-suffix span between the disk copy and the buffer (the
  same trim the incremental-reparse seam computes) — multiple disjoint edits
  in one buffer collapse into the single span between the first and the last,
  same as the reparse hook's own granularity.
- `ref` given: disk vs that git ref (`navgraph diff`'s rule), one hunk per
  changed range `git diff` reports; overlays are not consulted in this mode.
- `uri` + `range` together (no `ref`): the client hands navgraph an exact hunk
  it already knows about, bypassing overlay comparison entirely — useful
  before a `didChange` for that edit has round-tripped.

An empty change (nothing open differs from disk, or an empty diff against
`ref`) is `{ roots:[], nodes:[], edges:[], summary:{ symbols:0, total:0,
files:0, tests:0, maxDepth:0, truncated:false, byDepth:[], byFile:[] },
next:null, hunks:[], changeId:"0000000000000000" }` — a routine answer, not
`-32001` (matches `navgraph/diff`'s own "nothing changed" rule). A bad `ref`
**is** an error (`-32002`, git's own message), same as `navgraph/diff`.

`changeId` is a hash of the hunk set's shape (each hunk's file + line range,
in file order) — stable for "this is still the same working change", distinct
for a new one. It is deliberately not a deep content hash: per-symbol staleness
is `contentHash`'s job, not this one's.

### `navgraph/tests`

Params: `Target & { limit?:int(200) } & Scope` (`Scope` is accepted for the
contract's `Target & Scope` shape; `tests`/`strict` have no effect here — the
walk already answers "which tests", and always follows the same exact
call/route_call edges `navgraph coverage` does).

```
{ symbol:Symbol, tests:[{ symbol:Symbol, depth:int, via:int[] }],
  summary:{ count:int, maxDepth:int, truncated:bool } }
```

`query.coverage`'s forward walk from every test, inverted and rooted at one
target: every test symbol from which `target` is reachable through an exact
call/route_call edge (`target` never lists itself). `via` names the depth-1
neighbour each test was reached through, same convention as `navgraph/blast`.
An unresolved `Target` is `-32001`.

### `navgraph/types`

Params: `Target & { limit?:int(200) } & Scope`.

```
{ symbol:Symbol, supertypes:Symbol[], subtypes:Symbol[], implementors:Symbol[],
  users:[{ symbol:Symbol, kind:"extends"|"implements"|"param"|"local" }],
  truncated:bool }
```

"Who uses type T": `supertypes`/`subtypes` are one hop of the same base table
`typeHierarchy` walks; `implementors` is the same type-level table
`textDocument/implementation` uses. `users` unifies the subtype (`extends`) and
implementor (`implements`) edges with typed param/local bindings whose
declared type names this symbol (`param` when the binding is one of the
owner's own parameters, else `local`) — a best-effort, name-based match (the
same one `navgraph flow --on-type` already uses), so a shadowed same-named
type in another scope can produce a false match. `field`/`return`/
`annotation`/`generic` uses are not yet extracted by any language backend, so
they are simply absent from `users` — never an error, per the contract's
best-effort clause for languages/kinds not yet modeled.

### `navgraph/context`

Params: `Target & { budget?:int(2000, tokens), offset?:int(0) }`.

```
{ symbol:Symbol, definition:{ text:string, range:Range }, signature:string,
  doc?:string, callers:Symbol[], callees:Symbol[], types:Symbol[],
  tests:Symbol[], callersTotal:int, next:int|null, truncated:bool,
  tokensEstimate:int }
```

Everything an editing agent typically needs about one symbol, in a single
call. `types` is `navgraph/types`'s best-effort scan applied to this one
symbol: a container's declared supertypes, or a function/method's own typed
binding types. `tests` is `navgraph/tests`'s reachability list for this
symbol. `tokensEstimate` is the real serialized byte count of everything below
(the whole response, not just signatures) divided by ~4 — good enough to
shrink monotonically, not an exact tokenizer count.

Trimmed to `budget` (B2: this is an enforced bound, not a suggestion), **in
order**: the body (`definition.text` falls back to the bare `signature`),
then `tests`, then `types`, then `callees`. `callers` is never dropped as a
whole section, but — unlike the others — it is count-capped to whatever
budget remains once every other section has settled: production code before
any test block, then an exact call edge over a heuristic one, then proximity
to the target (same file, then same directory), with a floor of one shown
whenever the symbol has any caller at all, so an extreme budget still answers
"who calls this" rather than going empty. `callersTotal` is the true caller
count regardless of the *cap* — it is `0` when `include` excludes `callers`
outright, same as the section itself. `offset` pages through that priority
order and `next` is the offset for the following page, or `null` once
nothing remains (B1). `truncated` is set when a section `include` asked for
was actually dropped by the ladder, or `callers` is capped/paged past what
this response shows — never merely because `include` never asked for a
section. An unresolved `Target` is `-32001`.

### `navgraph/where`

Params: `{ uri:string, line:int (1-based) }`.

```
{ enclosing:Symbol|null, breadcrumbs:Symbol[], file:string }
```

The symbol enclosing `line` — built for stack traces and diff hunks, which are
1-based, unlike an LSP `position.line`. `enclosing` is `null` (never an error)
for a line with no enclosing definition (file scope, a blank line, or a file
outside the index). `breadcrumbs` is the enclosing chain outermost → innermost
(`[Class, method]` for a line inside `Class.method`), empty when `enclosing` is
null.

### `navgraph/symbolAt` gains `range` and `breadcrumbs`

```
{ word, symbol, enclosing, candidates,
  range: Range|null, breadcrumbs: Symbol[] }
```

`range` is the identifier's own LSP range (`null` off any identifier, matching
`word`/`symbol`/`candidates`' existing empty-answer convention).
`breadcrumbs` is the enclosing chain outermost → innermost, rooted at
`enclosing` — for winbar-style breadcrumbs. `navgraph/where` reuses the exact
same chain walk.

### `navgraph/search` gains `recent`

Params add `recent?:string[]` — client-supplied qualified names (an editor's
own recently-visited-symbols list). A hit whose `qualified` is in `recent`
ranks above every other tier, before score; ties among `recent` hits still
break on score, fan-in, path length, then id, same as always.

### `navgraph/status` gains `protocolMinor` and `backend`

```
{ …, protocolMinor:1,
  backend:{ default:"auto", languages:{ <lang>:"heuristic"|"tree-sitter" } } }
```

`backend.languages` reports, per language actually present in the index,
which parse backend served it. This repo ships only the heuristic
lexer/parser (`src/parser.zig`), so every language reports `"heuristic"` —
`backend` exists so a client can tell backends apart once a tree-sitter
backend (`feat/x/tree-sitter-backend`) lands, without a protocol version bump.

### `limit` / `truncated` everywhere

Every `navgraph/*` list method now accepts `limit` and reports `truncated`:
`navgraph/outline`, `navgraph/hot`, `navgraph/unused`, `navgraph/routes`,
`navgraph/events` and `navgraph/imports` gained `truncated` in 1.1
(`navgraph/blast`, `navgraph/search`, `navgraph/grep`, `navgraph/importers`,
`navgraph/tests` and `navgraph/types` already reported it).

`navgraph/blast`, `navgraph/diff`, `navgraph/impact` and `navgraph/context`
additionally gain a working continuation past `truncated:true` (B1: a
truncated response with no route to the rest, and no way to size what's
missing, is a contract violation — the independent evaluation's finding #4,
also flagged for the 1.0 `map`/`source`/`read` helpers' own `next`).
`offset` pages a stable priority order (BFS order for the blast-radius
methods; for `context`'s `callers`, production code before any test block,
then exactness, then proximity — see `navgraph/context` below); the response's
`next` is the `offset` for the following page, or `null` once nothing
remains; `summary.total` / `callersTotal` report the true count independent
of paging.

### Incremental re-parse (server-side only — not visible on the wire)

`index.parseOne` takes a `ReparseHint{ old_tree:?*anyopaque, edits:[]TreeEdit }`
seam, shaped for a tree-sitter backend's `ts_tree_edit`. This repo's heuristic
lexer/parser ignores the hint and always cold-parses; the seam exists so
`feat/x/tree-sitter-backend` (PR #9, not merged here) can satisfy it without
touching `index`/`session`/LSP code again. `session.reparse` computes `edits`
itself via `index.computeEdit` (a common-prefix/common-suffix diff of the
previous parsed text against the new one) on every reparse, regardless of
backend — LSP Full sync (this server's only mode) never sends a delta, so this
is where one gets reconstructed. `navgraph/impact`'s overlay-hunk detection
(above) reuses this same function.

Measured: no regression in single-file re-index with the seam threaded through
(noise-dominated, ~16–48 ms either way on this repo's own largest files —
whole-graph re-resolution, not parsing, is the actual cost driver; see
"Measured performance" above).

### Known limitations (1.1)

- `navgraph/types`'s `users` and `navgraph/context`'s `types` match typed
  bindings by **type name**, not by resolved id — the same limitation
  `navgraph flow --on-type` already has. A same-named type in an unrelated
  scope can produce a false match.
- `navgraph/impact`'s overlay-hunk detection collapses every disjoint edit in
  one buffer into a single span (the reparse seam's own granularity) — two
  edits far apart in one file report as one hunk covering the whole span
  between them, not two.
- `limit:0`/`budget:0` on any method is not honored as "no cap" — it is
  silently reinterpreted as "use the default" (500/200/2000/…), matching the
  1.0 helper's existing behavior. An explicit `0` and an absent `limit` are
  indistinguishable on the wire; send a real cap instead of `0`. The CLI's own
  `-l/--limit` diverges from this on purpose: `--limit 0` is a usage error
  (`-l/--limit must be at least 1`), not a silent default, on every CLI
  command that takes it — including `hunks`/`context`'s mirrored flags.
- `navgraph/types.supertypes` and `typeHierarchy/supertypes` drop a base the
  resolver could not place in the index (an external/ambiguous base) rather
  than reporting it — the CLI's `navgraph hierarchy` shows it as `~ external/
  ambiguous base: Name ?`, but the LSP surface currently cannot distinguish
  "no supertype" from "supertype outside the index".

### CLI and MCP mirrors

`navgraph/impact`, `navgraph/context` and `navgraph/where` are also available
outside the LSP: `navgraph hunks`/`context`/`where` on the command line, and
`navgraph.hunks`/`navgraph.context`/`navgraph.where` as tools on `navgraph
serve`/`mcp`'s MCP surface (alongside `navgraph.query`). All three share their
implementation with the LSP server verbatim (`src/lsp/mirrors.zig` calls
`queries.writeImpact`/`writeContext`/`writeWhere` directly) — the query logic
lives in exactly one place; only how a caller reaches it differs.

- `navgraph hunks [ref] [--depth N] [--direction callers|callees] [--limit N]
  [--offset N] [-j]` — the working change's hunks, blast radius and roots
  (`navgraph/impact`'s wire shape exactly, `roots`/`nodes`/`edges`/`summary`/
  `next`/`hunks`/`changeId` included, `summary.total` and `next` among them —
  B1/m6: these flags were previously unreachable from the CLI/MCP mirrors, the
  mechanism that made a `limit`-truncated `hunks` response unrecoverable on
  those two surfaces; `--limit` is the one that actually raises the 500-node
  page). Named `hunks`, not `impact`, because `navgraph impact` was already
  taken (an alias of the pre-1.1 `navgraph affected` command, an unrelated
  git-diff query). The CLI and MCP tool never have an open-document overlay,
  so — unlike the wire method, which treats an absent `ref` as "compare open
  buffers to disk" — a missing `ref` here always means "compare disk to HEAD",
  the same default `navgraph diff`/`navgraph affected` already use. Unset
  `--depth` keeps the session's configured depth, not the CLI's generic
  depth-1 default meant for `calls`/`callers`.
- `navgraph context <symbol> [--budget N] [--include a,b,…] [--offset N]
  [-j]` — `navgraph/context`'s wire shape exactly: definition, signature, doc,
  callers/callees/types/tests, trimmed to `--budget` tokens (default 2000; `0`
  is silently reinterpreted as the default, per the wire contract — never a
  usage error). `--include` is the same allow-list the wire `include` array
  validates (`callers`, `callees`, `types`, `tests`, `body`); absent means
  every section, present-but-empty means none. `--budget` here is *not* the
  CLI's shared hard-byte-output `--budget` (a different unit and a different
  default entirely) — `context` is the one command where that flag means
  tokens, matching the wire param it mirrors. `--offset` pages a budget-capped
  `callers` list (B1/B2), distinct from `--after`'s unrelated JSONL row-stream
  cursor.
- `navgraph where <file>:<line> [-j]` — the symbol enclosing a 1-based
  `file:line` and its breadcrumb chain, `navgraph/where`'s wire shape exactly.
  A file outside the index answers `{"enclosing":null,...}` (never an error,
  per the wire contract); a malformed `file:line` (no colon, a non-numeric or
  zero line) is reported as a usage message and exit 1, not a crash.

All three default to human-readable text; `-j` emits the identical JSON the
wire methods return (the same `Symbol` shape — `qualified`, `uri`,
`contentHash`, 0-based `range`s — not the CLI's own differently-shaped `-j`
output; text mode is a plain reformatting of that same JSON, computed once).

Design note: the CLI's other commands dispatch over a plain, already-loaded
`Index`; the MCP surface's `navgraph.query`/legacy `navgraph` tools dispatch
the same way over a resident one. Neither fits `queries.writeImpact`/
`writeContext`/`writeWhere`, which need a `Session` (for git/overlay access,
URI construction, and the position-encoding convention `Ctx` carries). Rather
than thread a `Session` through the CLI's `Index`-based dispatch, or grow
`agent_api`'s typed operation envelope with three more Session-shaped
operations, `src/lsp/mirrors.zig` builds a throwaway one-shot `Session` per
call — the same walk `Session.init` already does, and the same one-shot cost
model every other `navgraph` CLI invocation already pays. The MCP tools pay
that cost on every call (unlike `navgraph.query`, which reuses the server's
resident index) since `Session` always builds its own index rather than
adopting an existing one; not worth carrying two synchronized indices unless
these mirrors turn out to be called often enough for it to matter.

## Neovim

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "zig", "python", "javascript", "javascriptreact", "typescript",
              "typescriptreact", "go", "rust", "ruby", "lua", "c", "cpp", "cs" },
  callback = function(args)
    local root = vim.fs.root(args.buf, { ".git", "build.zig", "package.json", "go.mod", "Cargo.toml" })
    if not root then return end
    vim.lsp.start({
      name = "navgraph",
      cmd = { "navgraph", "lsp" },
      root_dir = root,
      init_options = { depth = 3, debounceMs = 120 },
    }, { bufnr = args.buf })
  end,
})

-- A custom method, for a blast-radius picker:
-- vim.lsp.buf_request(0, "navgraph/blast",
--   { uri = vim.uri_from_bufnr(0), position = { line = 10, character = 4 }, depth = 3 },
--   function(err, result) ... end)
```

## Implementation map

`src/lsp/` — each layer depends only on the ones below it.

| File | Responsibility |
| --- | --- |
| `loop.zig` | The stdio run loop, the read deadline, logging. |
| `handlers.zig` | The method table, `initialize` negotiation, error mapping. |
| `mirrors.zig` | One-shot CLI/MCP callers of `queries.write*` (`navgraph hunks`/`context`/`where` and their MCP tools) — no resident session. |
| `queries.zig` | Target resolution, blast, call trees, hover, document symbols, grep, and every other `navgraph/*` adapter. |
| `search.zig` | Fuzzy ranking, include globs, grep patterns. |
| `payload.zig` | The JSON shapes above — one writer each. |
| `session.zig` | The resident index: overlays, re-index, watching, ownership. |
| `overlay.zig` | The document store and `file://` URIs. |
| `position.zig` | Position ↔ byte offset, identifier extraction. |
| `rpc.zig` | Framing and JSON-RPC envelopes. |
| `regex.zig` | The bounded grep regex engine. |

Nothing here re-implements NavGraph's semantics: name resolution, edge
confidence, call-site lines, test classification and dead-read filtering all
come from `src/query.zig` and `src/index.zig`.
