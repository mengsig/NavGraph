# Indexing accuracy: baseline

NavGraph's goal is to be right in every supported language: every definition
found with the correct kind, line and parent; no phantom symbols; every
reference edge bound to the definition it actually names, and honestly marked
heuristic where the language cannot say. This file records where it stands, so
the next waves can be aimed at what actually costs the most.

Reproduce with `zig build bench` (under a second, no network, no cache). The
gate lives in `tests/accuracy.sh` and runs as part of `zig build test`.

## What is measured

Twelve golden corpora under `tests/golden/`, one per supported language, each
covering a whole `testenv/` fixture tree. Every entry is hand-verified;
`zig build bench -- --propose <root>` only drafts a skeleton for a human to
audit. Zig, C, C++, Python, JavaScript, TypeScript and Lua were cross-checked
against zls, clangd, pyright, typescript-language-server and
lua-language-server; C#, Go, Ruby and Java have no toolchain on this host and
were read line by line. Each golden's `notes` field states the rules it applies,
and each edge records whether it was `"lsp"`- or `"manual"`-verified.

The scored **definition** set is every named definition the model can address:
functions, methods, types, macros, constants, variables and container members.
It excludes import bindings, module/namespace/package declarations (scoping
directives, not navigation targets), enum members (values of a type), and the
derived `route`/`mount` symbols that belong to `navgraph routes`. A definition
matches only when file, qualified name, kind AND line all agree.

Kind follows what the per-language parser actually reports, not a uniform
reading of the source keyword, so the same construct can gold differently
across corpora - each is right for what that language's parser distinguishes
today:
- A class/interface method is `method` regardless of nesting depth EXCEPT a
  function nested inside another function's body (a C# local function, a
  Python closure), which is `fn` like any other free-standing callable -
  nesting is a scoping fact, not a membership one.
- A module-level binding is `const` when the parser can tell it's immutable
  (Rust's `static`, without `mut`) and `var` otherwise (Rust's `static mut`, a
  Go package-level `var`). The C# and Java parsers don't yet distinguish a
  `const`/`final` field from an ordinary one, so both gold as `field` -
  `TrickyRunner.Banner`'s `private const string` is not miscategorized, it is
  golden to a real, coarser parser behavior.
- A `delegate`/type-alias declaration is `type`.
- Constructors are `method`: the model has no separate constructor kind, so a
  language whose constructor is written like any other method (Java, C#,
  C++) golds it the same way.

The scored **edge** set is the call, type-use and function-valued references
that occur in a symbol's BODY, deduped per (from, to). A type named in a
symbol's own signature or in a field declaration is that symbol's interface, not
a dependency, and is not an edge. Reading data is not an edge; calling through a
function-valued member is. A reference to an enum member is an edge to its enum.
Both endpoints must be definitions in the same golden - the bench refuses a
golden that breaks this. An edge is `exact` when the language's own resolver
binds the site to exactly one definition, and heuristic when the binding is
genuinely ambiguous; `exact` agreement is scored separately from the edge
itself, because getting the endpoints right and the confidence wrong is a
different bug from missing the edge. `lines` is hand-verified call-site
ground truth, scored two more ways over every golden edge (matched or not - a
missed edge's whole `lines` list counts as unmatched sites, not zero):
call-site recall (`site_recall_bp`) and, within matched edges, call-site
precision (`site_precision_bp`, a produced line the golden doesn't list for
that edge). Both are floored and ratcheted the same as the other five, for
seven total. Every golden call site is checked against the produced edge's own
lines and reported as a finding when it's missing (`MISS site`).

`exact_agreement_bp` and `site_recall_bp` are both non-monotone in one
direction: each divides by a count only a MATCHED edge contributes to (matched
edges for exactness, a matched edge's own lines for site recall), so losing an
edge match can raise either one by shrinking its denominator, and
`ratioBp(0, 0)` scores a perfect 10000. A rising number on either metric is
not on its own evidence of an improvement - read it next to edge recall.

An edge is keyed `file:qualified` on each end - the same key defs are
bucketed by, since overloads legitimately share it. Most edges are
unambiguous under that key, but 51 across six languages are not: an
overload set (`Ledger.Post(string,int)` vs `Ledger.Post(Entry)`), or a field
and the accessor it generates (`Product.sku` the field vs `Product.sku()`
the method), share a `file:qualified` pair while naming different
definitions. Those edges carry an explicit `from_line` and/or `to_line`
saying which definition's own declaration line the endpoint names; the bench
refuses a golden where an endpoint's key is ambiguous and the line is
missing, so this can't rot back into a silent guess.

## Baseline at this commit

Percentages; the triples are matched/produced/expected. `site P` is call-site
precision and `site R` is call-site recall over every golden edge, matched or
not (see "What is measured") - the sixth and seventh floored metrics
alongside the other five; the sites triple is matched/produced/expected call
sites.

| language | def P | def R | defs | edge P | edge R | edges | exact agree | site P | site R | sites |
|---|---|---|---|---|---|---|---|---|---|---|
| c | 98.68 | 65.78 | 75/76/114 | 100.00 | 56.81 | 50/50/88 | 100.00 | 100.00 | 52.94 | 54/54/102 |
| cpp | 69.40 | 56.02 | 93/134/166 | 38.46 | 17.44 | 15/39/86 | 33.33 | 100.00 | 15.84 | 16/16/101 |
| csharp | 100.00 | 71.07 | 86/86/121 | 89.47 | 47.88 | 34/38/71 | 52.94 | 87.23 | 51.89 | 41/47/79 |
| go | 100.00 | 79.20 | 80/80/101 | 81.81 | 45.00 | 27/33/60 | 70.37 | 100.00 | 45.00 | 27/27/60 |
| java | 100.00 | 76.25 | 106/106/139 | 77.92 | 54.05 | 60/77/111 | 41.66 | 90.54 | 54.91 | 67/74/122 |
| javascript | 85.05 | 77.08 | 74/87/96 | 93.87 | 70.76 | 46/49/65 | 82.60 | 100.00 | 71.64 | 48/48/67 |
| lua | 90.90 | 66.66 | 50/55/75 | 80.55 | 54.71 | 29/36/53 | 79.31 | 96.96 | 55.17 | 32/33/58 |
| python | 96.68 | 91.14 | 175/181/192 | 90.00 | 84.78 | 117/130/138 | 75.21 | 100.00 | 85.10 | 120/120/141 |
| ruby | 96.42 | 67.50 | 54/56/80 | 100.00 | 20.96 | 13/13/62 | 53.84 | 100.00 | 22.22 | 14/14/63 |
| rust | 98.64 | 85.88 | 73/74/85 | 70.58 | 42.85 | 36/51/84 | 66.66 | 97.61 | 34.16 | 41/42/120 |
| typescript | 91.78 | 56.77 | 67/73/118 | 96.15 | 44.64 | 25/26/56 | 84.00 | 100.00 | 42.37 | 25/25/59 |
| zig | 100.00 | 72.91 | 105/105/144 | 98.36 | 63.82 | 60/61/94 | 61.66 | 100.00 | 50.00 | 64/64/128 |
| **all** | **93.26** | **72.53** | 1038/1113/1431 | **84.90** | **52.89** | 512/603/968 | **69.33** | **97.34** | **49.90** | 549/564/1100 |

Python is the reference implementation: it is the only language where both
recalls clear 85%. C++ is the outlier in every column. Ruby produces almost no
edges at all. The 1113 produced definitions and 603 produced edges are what an
agent sees today; the 1431 and 968 are what it should see. Site precision is
100% in nine of twelve languages, and no run ever reports a `MISS site`
finding: every matched edge's produced lines already cover its golden lines in
full, so waves 1-8 below are entirely about missing/phantom definitions and
edges, not about a matched edge's own line list being wrong. Site recall is a
different story - fix round 2's F2 redefined it over every golden edge rather
than only matched ones, so a missing edge's whole line list now counts as
unmatched sites and site recall tracks edge recall instead of reading a
misleadingly perfect 100%.

### Fix round 1: baseline moved, indexer did not

F1-F12 (`git log --oneline b69f397..4b51658`) corrected wrong or incomplete
goldens the coldstart review found - shifted lines, missing edges a corpus's
own stated rule required, a spurious definition, an unscored `lines` field
hiding six errors, and an edge key that let overloads and field/accessor pairs
match each other. None changed the indexer. The table above is the same
indexer scored against the corrected truth; every drop below is a golden
denominator growing (or an existing match exposed as wrong by a corrected
line), not a regression, and floors were lowered to match with `--lower-floors
--reason` (never edited by hand):

| language | what moved | why |
|---|---|---|
| cpp | edge P 41.66→38.46, edge R 18.75→17.64 | matched stayed 15 throughout - F12's dedupe-key change (`{from,to}` string pair → `{sym.id, ref.target}`) is entirely what moved this row, splitting `Analyzer.measure`'s edges 6→9 (produced) and `tricky_run -> Analyzer.measure` 1→3 (expected 80→85). F4 renamed one definition (`Weights::operator()`'s out-of-line name); no cpp edge names it, and F4 alone changed nothing here (re-verified by re-measuring at each intermediate commit) |
| csharp | edge R 51.51→49.27 | expected grew by three, from two fixes: +1 from F5 (`InventoryService.InventoryService -> Product`), +2 from F12 splitting the merged `TrickyRunner.Run -> Ledger.Post` [217,218,219] into three `to_line`-qualified edges |
| go | def R 80.00→79.20, edge R 47.36→45.00 | F8 added the missing `Auditor.Describer` embedded-field definition; F5 added `NewMemoryStore`'s three missing body edges |
| java | edge P 78.94→77.92, edge R 61.22→55.04 | expected grew by eleven, not nine: F5 added nine constructor-call edges the corpus's own pattern already covered at other `new X(...)` sites (98→107), and F12's key split added two more by splitting the merged `Tricky.run -> Ledger.post` [186,187,190] into three `to_line`-qualified edges (107→109); F12 alone (not F5, and not F10's line-only additions) also shifted produced 76→77, moving precision |
| javascript | edge R 75.40→73.01 | F5 added the renamed-import edge (`syncAll -> formatStatus`) and `TaggedLedger`'s `super(...)` constructor edge, both patterns already recorded elsewhere in the corpus |
| lua | def P 92.72→90.90, def R 68.00→66.66, edge R 63.04→54.71 | F3 corrected six wrong lines/parents, and one previously-coincidental def match no longer lines up with the corrected line (a real miss, not a new one); F5 added SEVEN missing edges, not six - the six the coldstart listed plus `M.run -> M.limits.clampers.hard` [186], which only became expressible after F3 renamed the definition it targets |
| python | edge R 85.40→86.02 | F6 dropped two bogus edges from a decorator's own parameter (net -1 after F12 split one merged overload edge into two) - recall rose because the denominator shrank on a corrected golden |
| ruby | def R 75.00→67.50, edge R 23.21→20.96 | F9 added the eight missing `attr_accessor` writer definitions (def denominator only, 72→80); the edge denominator grew separately, 56→62, from F5's six new heuristic edges - F9 added no edge |
| typescript | def R 56.30→56.77 (up), edge R 45.45→44.64 (down) | F11 dropped the one spurious `PostList.pending` definition, raising def R; F12's overload/field-accessor key split gave one merged edge its own separate line-disambiguated pair, growing the edge denominator by one |
| c, csharp (def), rust, zig | unchanged | no F-fix touched these goldens' scored def/edge counts |

Re-derived by re-measuring at every intermediate commit between `b69f397` and
`4b51658`, not by reading the diffs and guessing which fix caused which
delta - five of the ten rows above (cpp, csharp, java, ruby, lua) named the
wrong fix, or the right fix with the wrong count, in the version of this
table that shipped with fix round 1.

Floors were lowered for exactly the fourteen metrics that dropped above (cpp
edge P + edge R, csharp edge R, go def R + edge R, java edge P + edge R,
javascript edge R, lua def P + def R + edge R, ruby def R + edge R,
typescript edge R) - each ratcheted back down to the newly measured value with
`--lower-floors --reason "F1-F12 golden corrections added missing/corrected
definitions and edges, growing recall denominators; measured drops are
more-complete truth, not indexer regressions"`. Every other metric's floor
only rose or held (the ratchet in F1 never lets `--update-floors` erase a
raised floor), and `site_recall_bp` was recorded for the first time this
round (F10 added the metric; it defaulted to 0 in every existing
`floors.json` until now).

### Fix round 2: site recall redefined, six edge denominators grew

F1-F19 (`git log --oneline 500ae3f..967db94`) fixed every finding the
merge-gate review raised over round 1's state: inverted/missing exact flags, a
false lsp claim and a missing call site (F1); site recall redefined over
every golden edge instead of only matched ones (F2); overload self-call and
corpus-required edges recorded in cpp and elsewhere (F3, F4); a contradictory
exact flag in ruby (F7); missing javascript and python getter/setter edges
(F8, F16); `validateGolden` rejecting duplicate/unexplained repeated edge rows
(F6); loose verified provenance corrected on four resolver-produced edges
(F17); a usage/propose drift closed (F11); a new unit-tested site-scoring
machinery (F14); the `--lower-floors` gap that could hide a real regression
inside a batch of golden corrections closed (F15); site precision recorded as
a seventh floored metric, fresh with no prior floor (F13); five wrong "why
this floor dropped" rows in the Fix round 1 table above corrected (F5); and a
cluster of documentation fixes both reviews raised (F9, F10, F12, F18, F19).
None of the nineteen changed the indexer - every fix corrects a golden, the
bench's own validation, or this file's prose.

Only two kinds of measurement moved, both from denominators growing, not from
indexer behavior: `site_recall_bp` dropped in all twelve languages, because
F2 now counts a missing edge's whole `lines` list as unmatched sites instead
of scoring recall only within edges that already matched (it measures what it
was always floored to measure); and `edge_recall_bp` dropped in
cpp/csharp/java/javascript/python/rust, because F3, F4, F7, F8 and F16 added
edges each corpus's own stated rules already required, growing the expected
count out from under an unchanged matched count. Def precision/recall, edge
precision and exact agreement are unchanged in every language - this round
added no definitions and no produced-edge behavior changed.

Floors were lowered for exactly those eighteen metrics (site recall in all
twelve languages, edge recall in the six above) with `--update-floors
--lower-floors --reason "F1-F19 golden corrections and the site-recall
redefinition grew recall denominators; measured drops are more-complete
truth, not indexer regressions"`. `site_precision_bp` was recorded for the
first time this round (F13 added the metric) with a plain `--update-floors`,
not a lowering - there was no prior floor to ratchet against.

`zig build test --summary all`: 15/15 steps, 1659/1659 tests pass. `zig build
bench`: every language at or above its recorded floor.

### Wave 1: bind by receiver type, and drop unsupported name matches

The first wave that changes the indexer. It is `src/index.zig` reference
resolution plus the `src/parser.zig` binding support that resolution needs —
not symbol extraction, with two deliberate exceptions Ruby's own wave
required (`attr_*` and operator methods are definitions, not extraction work
this wave could route around).

**The base moved first.** This branch was cut before PR #4/#7 landed on
`main`, and those PRs are the resolver contract this wave builds on, so the
wave starts by merging `main`. That merge alone — no work of this wave's —
moved four languages: go edge P 81.8→87.2 and edge R 45.0→56.7, lua edge R
54.7→79.2, rust edge R 42.9→50.0, and cpp edge P 38.5→33.3 (six more
typed-receiver calls landing on a header declaration where the golden names
the out-of-line definition). Three floors went red on the merge — cpp edge
precision, lua exact agreement, rust site precision — and every one of them
is back above its floor by the end of this wave, without `--lower-floors`.
The table below is measured on the merged base, so it separates the merge
from the wave; the "Baseline at this commit" table above is the pre-merge
number and is left as it was recorded.

| language | def P | def R | defs | edge P | edge R | edges | exact agree | site P | site R | sites |
|---|---|---|---|---|---|---|---|---|---|---|
| c | 98.68 | 65.78 | 75/76/114 | 100.00 | 56.81 | 50/50/88 | 100.00 | 100.00 | 52.94 | 54/54/102 |
| cpp | 69.40 | 56.02 | 93/134/166 | 33.33 | 17.44 | 15/45/86 | 53.33 | 100.00 | 15.84 | 16/16/101 |
| csharp | 100.00 | 71.07 | 86/86/121 | 89.47 | 47.88 | 34/38/71 | 52.94 | 87.23 | 51.89 | 41/47/79 |
| go | 100.00 | 79.20 | 80/80/101 | 87.17 | 56.66 | 34/39/60 | 85.29 | 100.00 | 56.66 | 34/34/60 |
| java | 100.00 | 76.25 | 106/106/139 | 77.92 | 54.05 | 60/77/111 | 41.66 | 90.54 | 54.91 | 67/74/122 |
| javascript | 85.05 | 77.08 | 74/87/96 | 93.87 | 70.76 | 46/49/65 | 82.60 | 100.00 | 71.64 | 48/48/67 |
| lua | 90.90 | 66.66 | 50/55/75 | 82.35 | 79.24 | 42/51/53 | 66.66 | 95.91 | 81.03 | 47/49/58 |
| python | 96.68 | 91.14 | 175/181/192 | 90.00 | 84.78 | 117/130/138 | 75.21 | 100.00 | 85.10 | 120/120/141 |
| ruby | 96.42 | 67.50 | 54/56/80 | 100.00 | 20.96 | 13/13/62 | 53.84 | 100.00 | 22.22 | 14/14/63 |
| rust | 98.64 | 85.88 | 73/74/85 | 72.41 | 50.00 | 42/58/84 | 71.42 | 94.00 | 39.16 | 47/50/120 |
| typescript | 91.78 | 56.77 | 67/73/118 | 96.15 | 44.64 | 25/26/56 | 84.00 | 100.00 | 42.37 | 25/25/59 |
| zig | 100.00 | 72.91 | 105/105/144 | 98.36 | 63.82 | 60/61/94 | 61.66 | 100.00 | 50.00 | 64/64/128 |
| **all** | **93.26** | **72.54** | 1038/1113/1431 | **84.46** | **55.58** | 538/637/968 | **70.45** | **96.97** | **52.45** | 577/595/1100 |

After the wave:

| language | def P | def R | defs | edge P | edge R | edges | exact agree | site P | site R | sites |
|---|---|---|---|---|---|---|---|---|---|---|
| c | 98.68 | 65.78 | 75/76/114 | 100.00 | 56.81 | 50/50/88 | 100.00 | 100.00 | 52.94 | 54/54/102 |
| cpp | 69.40 | 56.02 | 93/134/166 | 39.02 | 18.60 | 16/41/86 | 68.75 | 100.00 | 16.83 | 17/17/101 |
| csharp | 100.00 | 71.07 | 86/86/121 | 94.59 | 49.29 | 35/37/71 | 82.85 | 87.50 | 53.16 | 42/48/79 |
| go | 100.00 | 79.20 | 80/80/101 | 89.74 | 58.33 | 35/39/60 | 85.71 | 100.00 | 58.33 | 35/35/60 |
| java | 100.00 | 76.25 | 106/106/139 | 97.05 | 59.45 | 66/68/111 | 87.87 | 93.58 | 59.83 | 73/78/122 |
| javascript | 85.05 | 77.08 | 74/87/96 | 95.91 | 72.30 | 47/49/65 | 82.97 | 100.00 | 73.13 | 49/49/67 |
| lua | 90.90 | 66.66 | 50/55/75 | 84.90 | 84.90 | 45/53/53 | 93.33 | 100.00 | 86.20 | 50/50/58 |
| python | 96.68 | 91.14 | 175/181/192 | 90.76 | 85.50 | 118/130/138 | 75.42 | 100.00 | 85.81 | 121/121/141 |
| ruby | 97.36 | 92.50 | 74/76/80 | 100.00 | 70.96 | 44/44/62 | 81.81 | 100.00 | 71.42 | 45/45/63 |
| rust | 98.64 | 85.88 | 73/74/85 | 84.31 | 51.19 | 43/51/84 | 83.72 | 97.95 | 40.00 | 48/49/120 |
| typescript | 91.78 | 56.77 | 67/73/118 | 100.00 | 46.42 | 26/26/56 | 84.61 | 100.00 | 44.06 | 26/26/59 |
| zig | 100.00 | 72.91 | 105/105/144 | 100.00 | 64.89 | 61/61/94 | 67.21 | 100.00 | 50.78 | 65/65/128 |
| **all** | **93.38** | **73.93** | 1058/1133/1431 | **90.29** | **60.54** | 586/649/968 | **82.42** | **98.12** | **56.82** | 625/637/1100 |

No measurement dropped in any language. Overall edge precision rose 84.46 →
90.29, edge recall 55.58 → 60.54, exact agreement 70.45 → 82.42, site
precision 96.97 → 98.12, site recall 52.45 → 56.82. Zig and TypeScript now
produce no phantom edge at all; Ruby still produces none while nearly
quadrupling what it finds.

**What each change bought.** Ordered by what moved:

| change | languages | measured |
|---|---|---|
| Class/struct bodies record their field types, and Java/C# parameters bind `name -> Type` instead of binding the type as the name (they were using the annotation-language `name: Type` splitter). The C declarator also counts generic depth itself, since `<` is not in the bracket table, so `Repository<Product> products` used to parse as nothing | java, csharp, cpp | java edge P 77.9→97.1, edge R 54.1→59.5, exact 41.7→87.9; csharp edge P 89.5→94.6, exact 52.9→82.9; cpp exact 53.3→66.7 |
| A bare qualifier naming a field of the enclosing type resolves through that field's declared type (`products.add(...)`), and a receiver whose declared type is a standard-library container abstains instead of matching a same-named project method | java, csharp, rust, cpp | folded into the row above; rust edge P 72.4→75.0 |
| Lua `local x = Account.new(…)` declares a typed local (it was not a declaration at all), Zig container bodies record field types, and a qualifier naming a same-file top-level symbol that declares the member is exact evidence even when that symbol is a plain table | lua, zig, rust | lua exact 66.7→93.2, edge R 79.2→83.0, site P 95.9→100.0; rust exact 71.4→78.6; zig exact 61.7→66.7 |
| Ruby: `attr_*` readers/writers and operator methods are definitions; a method call needs no parentheses and Ruby has no public fields, so `book.to_row` is a call; `available?` keeps its sigil at the call site; implicit self, `include`/`extend` mixins, a superclass and `super` all resolve through a generalized `type_bases` (which for a module carries the classes that mix it in); `Klass.new` reaches `initialize` | ruby | def R 67.5→92.5, edge R 21.0→71.0, exact 53.8→81.8, site R 22.2→71.4, edge and site precision held at 100.0 |
| A call through a constant that holds nothing but a named function reaches that function | all | zig/typescript edge P → 100.0, javascript 93.9→95.9, go 87.2→89.7, python 90.0→90.8, lua 83.0→84.9, rust +1 edge |
| A member reached through an expression we cannot name is no longer recorded as a *bare* reference and handed to the global name match; a qualifier naming a standard-library type abstains; `Weights w({1.0})` types its local | cpp, rust | cpp edge P 36.6→39.0, rust site P 94.1→98.0 and edge P 78.2→84.3 |
| One-letter names are references (the collector dropped every identifier shorter than two bytes, so `pub fn a() void { b(); }` produced no callee in any language) | all | no corpus defines a one-letter symbol, so nothing moved; covered by a new index test |

**NavGraph's own `src/` as a second corpus.** Paired whole-project edge dumps
across the wave: 5621 → 5624 edges over an unchanged 2666 definitions. Four
edges lost, each justified — three were replaced by the correct target
(`outlineFile -> SymbolKind.tag` became `Language.tag`, `pathJson ->
SymbolKind.tag` became `Confidence.tag`, `RefPattern.matches ->
RefPattern.partMatches` became `exactOrGlob`, the alias it holds) and the
fourth, `serve -> gitdiff.flush`, was a phantom: `out` is a `*std.Io.Writer`,
so `out.flush()` is the standard library's. Seven edges gained, all through a
now-typed receiver.

**Floors** were re-recorded once at the end of the wave with a plain
`--update-floors`; every metric that moved rose, and nothing was lowered
(`--lower-floors` was not used and is not needed — the three floors the base
merge put underwater were recovered by the wave's own fixes, not by lowering
them).

**What this wave did not fix.** The acceptance targets it misses, and why:

- **cpp edge precision is 39.0%, not ≥90%.** 25 of its 41 produced edges are
  phantoms, and essentially all of them are failure class 3: an out-of-line
  `double Shape::area() const` is indexed as a free `area` with no parent, so
  the edge's `from` or `to` names a definition the golden does not have. That
  is wave 4's change, not this one's. The two phantoms this wave could reach —
  `items_.size()` on a `std::vector` field, and a CRTP call through
  `static_cast<Derived*>(this)` — are gone.
- **Overall edge precision is 90.3%, not ≥95%,** and exact agreement 82.4%,
  not ≥85%. cpp alone accounts for 25 of the 63 remaining phantom edges.
- **Ruby edge recall is 71.0%, not ≥80%.** What is left needs machinery
  outside this wave: string interpolation (`"#{prefix}-#{id}"` is one string
  token, so two golden edges are invisible), operator *call sites* (`ledger +
  tagged`, `merged[0]` — wave 8 owns those, and this wave records only the
  definitions), and type-use edges to a class nested in a module (wave 3).
- Zig's remaining exactness gap is type aliases: `operands: OperandStack` where
  `const OperandStack = Stack(i64)` needs the alias followed to `Stack`, which
  needs a return/alias type the model does not record.

## Failure classes, by what they cost

Counted across all twelve languages at the pre-wave-1 baseline: 374 missing
definitions, 56 phantom definitions, 19 mis-kinded or mis-placed definitions,
456 missing edges, 91 phantom edges, 157 exactness disagreements. (Fix round 1
grew the missing/phantom counts by correcting goldens that were previously too
small or mismatched, and fix round 2's F3/F4/F7/F8/F16 grew the missing-edge
count further the same way - see "Fix round 1" and "Fix round 2" above; neither
touched exactness.)

After wave 1 the same census reads: 354 missing definitions, 56 phantom
definitions, 19 mis-kinded, 382 missing edges, 63 phantom edges, 103 exactness
disagreements. Classes 4, 5, 6 and 9 are the ones it moved; the counts below
describe the baseline, and each class says where it now stands.

**1. Container members are indexed for two languages out of twelve** - 242 of
the 374 missing definitions. `field` is a first-class kind and `navgraph def
Money.amount` works, but only Python dataclass attributes and Lua table fields
ever populate it. `Chunk.code_len`, `Widget.Name`, `Product.priceCents`,
`RequestOptions.method` and every other struct field, class field, interface
member, property and record component is absent from the graph, in ten
languages.

**2. A reference to a type is usually not an edge** - the single largest edge
class. Of 456 missing edges, 226 point at a type
(`struct`/`class`/`enum`/`iface`/`type`). `var buf: [128]lexer.Token`,
`Vec *v = malloc(...)`, `var widget models.Widget`, `class Sprite : public
Positioned` all record nothing. Zig, C, C++, Rust and Ruby produce none at all;
Go finds 2 of 18 and TypeScript 2 of 16, while Python finds 41 of 43 - so this
is per-language parser work, not a missing model.

**3. C++ out-of-line definitions lose their class** - 41 phantoms and 41 misses
in one language. `double Shape::area() const` in shapes.cpp is indexed as a
free function named `area` with no parent, so `Shape.area` is missing and `area`
is a phantom; every call to it lands on the wrong side too. The index already
has the cross-file parenting pass that Rust `impl Type` and Go `func (r Type)`
use (`Symbol.receiver`); C++ `Type::method` never fills it.

**4. Same-name symbols in another file get bound anyway** - most of the 91
phantom edges. `_ITEMS.get(...)` in Python resolves to `OrderService.get`;
`self.entries.len()` in Rust resolves to `tricky_rust::Ledger::len`;
`items.add(...)` in Java resolves to `Repository.add`; `store.get(key)` on a
`Map` resolves to `Repository.get`; `items_.size()` in C++ resolves to
`Weights::size` in a different header. A name match with no receiver evidence is
being emitted as a resolved edge rather than dropped.

**5. Dispatch picks the wrong end of the interface/impl pair** - Go, Java, C#,
Rust. `widget.Validate()` on a concrete `models.Widget` binds to
`Validator.Validate`; `product.label()` on a declared `Product` binds to
`PerishableProduct.label`; `pricing.priceFor(...)` on a `PricingStrategy`
interface binds to `StandardPricing.priceFor`; `expr.evaluate()` on an `Expr`
binds to the trait method. The rule is one line: bind to the receiver's DECLARED
type, and to the interface only when that is what is declared.

**6. Ruby barely resolves at all** - 20.96% edge recall, the worst number in the
table. `book.available?`, `find(id)`, `Sorting.by_title`, `super.label`,
`identifier` from an included module: 49 of 62 edges are missing. The
attr_accessor-generated readers are missing as definitions too (F9 added the
writer half to the golden; the indexer produces neither), so a third of the
call targets do not exist in the graph.

**7. Function-valued references are not edges** - callbacks and method values.
`vec_apply(v, times_two)`, `.init = node_init`, `it.next = vec_iter_next`,
`mux.HandleFunc("GET /widgets", a.ListWidgets)`, `bus.on('item.created',
onItemCreated)`, `items.map(formatItem)` all record nothing, so the handler
looks dead and the wiring is invisible.

**8. Nested and generated definitions** - a nested function is indexed but
unparented (`to_summary`, `wrapper`, `paginate`, `keep`, `decorate` are phantoms
under a bare name and misses under their real one). Definitions produced by a
macro or a declarative helper are absent: C's `TRICKY_DEFINE_SCALER`, Rust's
`define_scaler!`, Ruby's `attr_accessor`.

**9. Confidence is systematically low** - 157 exactness disagreements, worst in
Java (41.66%), C# (52.94), Ruby (53.84), Zig (61.66). A typed receiver whose
type is written two lines up is marked heuristic, so `--strict` drops edges a
compiler would call certain.

**10. Text and declaration syntax read as code** - the phantom tail. Ruby's
`<<~TEXT` heredoc body is parsed as Ruby, inventing `phantom_from_string` and
`PhantomClass`. A C function-like macro's body yields a definition named after
its parameter (`name`). `enum class ShapeKind` is indexed as a definition NAMED
`class`. `static mut EVAL_COUNT` in Rust is indexed as `mut`. A C++ destructor
`~Node()` is indexed under the constructor's name. Lua's `function love.load()`
drops the table it is attached to, and a function two tables deep
(`Vec.dir.opposite`) is attributed one level up. JS/TS never distinguish `const`
from `var`.

## Proposed fix waves, in order

Ordered by measured impact per unit of work. Sizes are estimates for the change
plus its tests.

1. ~~**Bind by receiver type, and drop unsupported name matches**~~ **LANDED**
   (`index.zig` resolution plus the parser binding support it needs) - see
   "Wave 1" above for the measured result. It took classes 4, 5 and 9 down
   (91 phantom edges to 63, 157 exactness disagreements to 103) and carried
   class 6 (Ruby) with it. What it left behind in cpp is class 3, which is
   wave 4's.
2. **Index container members in every language** (`parser.zig`, per-language
   member parsing). Class 1: 242 definitions, +17 points of overall definition
   recall on its own. The kind, the model and two working implementations
   already exist, so this is mostly per-language parsing. **Medium-large**, but
   splittable one language at a time.
3. **Record type-use edges** (`parser.zig` reference collection). Class 2: 226
   edges. The `RefKind.type_use` variant is already in the model and already
   traversed by `graph`/`calls`; the parsers simply do not emit it for a type
   named in a body. **Medium**.
4. **Parent C++ out-of-line definitions to their class** (`parser.zig` +
   `index.zig` receiver pass). Class 3: 41 phantoms and 41 misses, and it is
   what makes C++ the worst language in the table. Reuse the existing
   `Symbol.receiver` cross-file pass. **Small**, unusually high value.
5. ~~**Ruby method resolution**~~ **LANDED with wave 1** (`parser.zig` ruby,
   `index.zig`): attr_accessor and operator definitions, implicit self,
   `super`, module mixins and `Namespace::Class.method` receivers took Ruby
   from 21% to 71% edge recall at 100% precision. What is left needs string
   interpolation, operator call sites (wave 8) and nested-class type uses
   (wave 3).
6. **Treat a function named as a value as a reference** (`parser.zig`
   reference collection). Class 7. Wave 1 landed half of it: a call *through* a
   function-valued constant now reaches the function it holds, in every
   language. What remains is a function passed as an argument or stored in a
   struct field (`vec_apply(v, times_two)`, `.init = node_init`). **Small**.
7. **Parent nested functions; index macro-generated definitions**
   (`parser.zig`). Class 8's remainder: 6 phantom/6 missing pairs in Python and
   JS from parenting alone, plus the C/Rust/Ruby generated definitions.
   **Small** for parenting, **medium** for expansion (which needs a bounded
   macro-body scan).
8. **Declaration-syntax fixes** (`parser.zig`). Class 10, one small independent
   change each: heredoc bodies (`<<~`/`<<-`) as text, `enum class NAME`,
   `static mut NAME`, `~Dtor`, C macro bodies, `function tbl.name()` in Lua,
   nested Lua table depth, `const` vs `var` in JS/TS, and operator-syntax call
   sites (C++, Python, Lua don't emit them; C#, Ruby, Rust do - see "no
   defensible golden answer" below). Each is a handful of lines with an
   obvious test. **Small**, and they are the cheapest precision wins.

Waves 1-4 alone move the two numbers that matter most: they close roughly half
of the missing definitions and half of the missing edges, and they are the only
ones that touch precision.

## Constructs with no defensible golden answer

Recorded rather than guessed at, because a benchmark that invents an answer
measures the invention:

- **A computed method name.** JavaScript's `*[Symbol.iterator]()` and a TS index
  signature `[key: string]: unknown` have no name a dot-separated qualified name
  can spell. Both are absent from the golden, so neither counts for or against.
- **A name that only exists after interpolation.** Ruby's
  `define_method("scale_by_#{name}")` inside a loop. A static tool cannot know
  the names; a golden that demanded them would demand the impossible. By
  contrast, C's `TRICKY_DEFINE_SCALER(tricky_double, 2)` and Rust's
  `define_scaler!(scale_by_two, 2.0)` name their functions literally at the use
  site, so those ARE golden.
- **A CRTP call with no instantiation to resolve it.** `Counter::bump`'s
  `static_cast<Derived*>(this)->step()` needs a concrete `Derived` to bind,
  which no resolver has without instantiating the template, so it is left out
  entirely. This is NOT the same question as which of a method's declaration
  (header) and out-of-line definition (.cpp) a call names - that one IS
  answerable, and `to_line` records the answer (the definition) everywhere it
  comes up: `Vec2.magnitude` [52], `Describe.text` [73], `Describe` [101].
- **An edge between two overloads of one name** (`Ledger.Post(string, int)`
  calling `Ledger.Post(Entry)`) is now representable - `from_line`/`to_line`
  disambiguate each end independently - and not itself a construct with no
  answer; it is simply not yet recorded in any golden, since no corpus
  exercises it through a call the reviewed indexer output actually produces.
- **Which function a function-pointer member reaches.** `ops->step(n, by)` in C
  binds to the member `TrickyOps.step`; picking `node_step` out of it needs
  whole-program analysis of every assignment. The golden records the member and
  stops.
- **A reference with no named owner.** An Express route handler registered as an
  inline arrow at module scope, and a Sinatra `get "/books" do ... end` block,
  contain real calls but sit inside no named definition. The golden has no
  `from` to write, so those references are excluded (references inside an
  anonymous callback that IS inside a named function belong to that function).
- **An anonymous union's members.** C's `union { long as_long; void *as_ptr; }
  payload;` reaches its members through `payload`, but the union type has no
  name, so `TrickyNode.payload.as_long` would make a field the parent of a
  field. Excluded.
- **A tuple struct's positional field.** Rust's `Cents(pub i64)` field is `.0`.
  Excluded for the same reason.
- **Enum members and error-set members.** Excluded in every language: they are
  values of a type, no language's parser here indexes them, and there is no
  evidence in the model that they are meant to be. A reference to one is scored
  as an edge to the enum instead, which is the answer a reader wants anyway.
- **Namespace and package membership.** `geo::scene::Sprite::move` is golden as
  `Sprite.move`, and namespace/package declarations are not scored definitions.
  NavGraph never parents a symbol under a namespace, in any language; that is
  consistent behavior, so the benchmark treats it as the model's shape rather
  than as a bug. If the operator wants namespace-qualified names, it is one
  deliberate change to the goldens and to `index.zig`, not a bug fix.

Not on this list, because it has a defensible answer that just isn't applied
everywhere yet: **operator-syntax call sites** (`a + b`, `weights[0]`,
`ledger + blank`) ARE a dependency on the operator method, the same as any
other call, and three corpora record them (C# `Slip.operator+`, Ruby
`Ledger.+`/`Ledger.[]`, Rust `Cents.add`) while three don't (C++, Python,
Lua). Each corpus is internally consistent, so nothing mis-scores today, but a
wave that starts emitting operator-call edges is correct in the first three
languages and generates phantoms in the other three. Tracked for wave 8
(declaration-syntax fixes) alongside the other per-corpus inconsistencies
that wave exists to close.

## Keeping the numbers honest

`tests/golden/floors.json` records each language's seven measurements - the
five headline metrics plus `site_recall_bp` and `site_precision_bp` - as the
floors the gate enforces. They start at the baseline above, so the gate only
ever catches a regression. After a wave lands, re-record with
`zig build bench -- --update-floors` and commit the raised floors with the fix,
which is what locks the gain in. Never lower a floor to make a build pass: a
number that went down is the finding - unless the golden it is measured
against changed underneath it (a correction, not a regression), in which case
`--update-floors --lower-floors --reason "<why>"` accepts the drop
deliberately and prints the reason alongside every metric it moved - `floors.json`
itself has no room for prose, so the reason is not persisted there; put it in
the commit message and this file's fix-round table, the way every prior round
has, so a later reader can tell a golden correction from an indexer regression
at a glance. `--lower-floors` accepts every drop in the run, not a chosen
subset, so a real regression riding along with a batch of golden corrections
has no distinguishing mark beyond that printed line - read it before
committing.
