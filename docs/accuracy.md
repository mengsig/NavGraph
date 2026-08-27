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
ground truth, scored as call-site recall within matched edges: a sixth
floored metric (`site_recall_bp`, ratcheted the same as the other five)
alongside them, and every call site it names must appear among the produced
edge's own lines or it is reported as a finding (`MISS site`).

An edge is keyed `file:qualified` on each end - the same key defs are
bucketed by, since overloads legitimately share it. Most edges are
unambiguous under that key, but 34 across five languages are not: an
overload set (`Ledger.Post(string,int)` vs `Ledger.Post(Entry)`), or a field
and the accessor it generates (`Product.sku` the field vs `Product.sku()`
the method), share a `file:qualified` pair while naming different
definitions. Those edges carry an explicit `from_line` and/or `to_line`
saying which definition's own declaration line the endpoint names; the bench
refuses a golden where an endpoint's key is ambiguous and the line is
missing, so this can't rot back into a silent guess.

## Baseline at this commit

Percentages; the triples are matched/produced/expected. `site R` is call-site
recall within matched edges (see "What is measured"), floored as a sixth
metric alongside the other five; its pair is matched/expected call sites.

| language | def P | def R | defs | edge P | edge R | edges | exact agree | site R | sites |
|---|---|---|---|---|---|---|---|---|---|
| c | 98.68 | 65.78 | 75/76/114 | 100.00 | 56.81 | 50/50/88 | 100.00 | 100.00 | 54/54 |
| cpp | 69.40 | 56.02 | 93/134/166 | 38.46 | 17.64 | 15/39/85 | 33.33 | 100.00 | 16/16 |
| csharp | 100.00 | 71.07 | 86/86/121 | 89.47 | 49.27 | 34/38/69 | 52.94 | 100.00 | 41/41 |
| go | 100.00 | 79.20 | 80/80/101 | 81.81 | 45.00 | 27/33/60 | 70.37 | 100.00 | 27/27 |
| java | 100.00 | 76.25 | 106/106/139 | 77.92 | 55.04 | 60/77/109 | 41.66 | 100.00 | 67/67 |
| javascript | 85.05 | 77.08 | 74/87/96 | 93.87 | 73.01 | 46/49/63 | 82.60 | 100.00 | 48/48 |
| lua | 90.90 | 66.66 | 50/55/75 | 80.55 | 54.71 | 29/36/53 | 79.31 | 100.00 | 32/32 |
| python | 96.68 | 91.14 | 175/181/192 | 90.00 | 86.02 | 117/130/136 | 75.21 | 100.00 | 120/120 |
| ruby | 96.42 | 67.50 | 54/56/80 | 100.00 | 20.96 | 13/13/62 | 53.84 | 100.00 | 14/14 |
| rust | 98.64 | 85.88 | 73/74/85 | 70.58 | 45.56 | 36/51/79 | 66.66 | 100.00 | 41/41 |
| typescript | 91.78 | 56.77 | 67/73/118 | 96.15 | 44.64 | 25/26/56 | 84.00 | 100.00 | 25/25 |
| zig | 100.00 | 72.91 | 105/105/144 | 98.36 | 63.82 | 60/61/94 | 61.66 | 100.00 | 64/64 |
| **all** | **93.26** | **72.53** | 1038/1113/1431 | **84.90** | **53.66** | 512/603/954 | **69.33** | **100.00** | 549/549 |

Python is the reference implementation: it is the only language where both
recalls clear 85%. C++ is the outlier in every column. Ruby produces almost no
edges at all. The 1113 produced definitions and 603 produced edges are what an
agent sees today; the 1431 and 954 are what it should see. Call-site recall is
100% everywhere: every matched edge's produced lines already cover its golden
lines, so waves 1-8 below are entirely about missing/phantom
definitions and edges, not about a matched edge's own line list.

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
| cpp | edge P 41.66→38.46, edge R 18.75→17.64 | F4 gave `Weights::operator()`'s out-of-line definition its real name, adding edges the golden was missing while it was misnamed |
| csharp | edge R 51.51→49.27 | F5 added the `InventoryService.InventoryService -> Product` generic-arg edge, matching the sibling `List<T>` sites already recorded |
| go | def R 80.00→79.20, edge R 47.36→45.00 | F8 added the missing `Auditor.Describer` embedded-field definition; F5 added `NewMemoryStore`'s three missing body edges |
| java | edge P 78.94→77.92, edge R 61.22→55.04 | F5 added nine constructor-call edges the corpus's own pattern already covered at other `new X(...)` sites; F10's two added call-site lines and F12's key split shifted the produced count by one |
| javascript | edge R 75.40→73.01 | F5 added the renamed-import edge (`syncAll -> formatStatus`) and `TaggedLedger`'s `super(...)` constructor edge, both patterns already recorded elsewhere in the corpus |
| lua | def P 92.72→90.90, def R 68.00→66.66, edge R 63.04→54.71 | F3 corrected six wrong lines/parents, and one previously-coincidental def match no longer lines up with the corrected line (a real miss, not a new one); F5 added six missing edges the corpus's own "is the call site covered" rule required |
| python | edge R 85.40→86.02 | F6 dropped two bogus edges from a decorator's own parameter (net -1 after F12 split one merged overload edge into two) - recall rose because the denominator shrank on a corrected golden |
| ruby | def R 75.00→67.50, edge R 23.21→20.96 | F9 added the eight missing `attr_accessor` writer definitions the corpus's own notes require, growing both denominators |
| typescript | def R 56.30→56.77 (up), edge R 45.45→44.64 (down) | F11 dropped the one spurious `PostList.pending` definition, raising def R; F12's overload/field-accessor key split gave one merged edge its own separate line-disambiguated pair, growing the edge denominator by one |
| c, csharp (def), rust, zig | unchanged | no F-fix touched these goldens' scored def/edge counts |

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

## Failure classes, by what they cost

Counted across all twelve languages: 374 missing definitions, 56 phantom
definitions, 19 mis-kinded or mis-placed definitions, 442 missing edges, 91
phantom edges, 157 exactness disagreements. (Fix round 1 grew the missing/
phantom counts by correcting goldens that were previously too small or
mismatched - see "Fix round 1" above; it did not touch exactness.)

**1. Container members are indexed for two languages out of twelve** - 242 of
the 374 missing definitions. `field` is a first-class kind and `navgraph def
Money.amount` works, but only Python dataclass attributes and Lua table fields
ever populate it. `Chunk.code_len`, `Widget.Name`, `Product.priceCents`,
`RequestOptions.method` and every other struct field, class field, interface
member, property and record component is absent from the graph, in ten
languages.

**2. A reference to a type is usually not an edge** - the single largest edge
class. Of 442 missing edges, 221 point at a type
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

1. **Bind by receiver type, and drop unsupported name matches** (`index.zig`
   resolution). Fixes classes 4 and 5 together: it removes most of the 91
   phantom edges and re-aims ~40 misbound ones, and it is the only wave that
   improves precision. It should also raise the confidence bit where the
   receiver's declared type is known, taking a large bite out of class 9.
   Affects go, java, csharp, rust, python, cpp, js. **Medium**, and the highest
   value in the list.
2. **Index container members in every language** (`parser.zig`, per-language
   member parsing). Class 1: 242 definitions, +17 points of overall definition
   recall on its own. The kind, the model and two working implementations
   already exist, so this is mostly per-language parsing. **Medium-large**, but
   splittable one language at a time.
3. **Record type-use edges** (`parser.zig` reference collection). Class 2: 221
   edges. The `RefKind.type_use` variant is already in the model and already
   traversed by `graph`/`calls`; the parsers simply do not emit it for a type
   named in a body. **Medium**.
4. **Parent C++ out-of-line definitions to their class** (`parser.zig` +
   `index.zig` receiver pass). Class 3: 41 phantoms and 41 misses, and it is
   what makes C++ the worst language in the table. Reuse the existing
   `Symbol.receiver` cross-file pass. **Small**, unusually high value.
5. **Ruby method resolution** (`parser.zig` ruby, `index.zig`). Classes 6 and 8:
   attr_accessor definitions, self-calls, `super`, module-mixin methods and
   `Namespace::Class.method` receivers. Ruby is 21% today; this is the whole
   gap. **Medium**.
6. **Treat a function named as a value as a reference** (`parser.zig`
   reference collection). Class 7. Small, uniform, and it makes callback-driven
   code stop looking dead. **Small**.
7. **Parent nested functions; index macro-generated definitions**
   (`parser.zig`). Class 8's remainder: 6 phantom/6 missing pairs in Python and
   JS from parenting alone, plus the C/Rust/Ruby generated definitions.
   **Small** for parenting, **medium** for expansion (which needs a bounded
   macro-body scan).
8. **Declaration-syntax fixes** (`parser.zig`). Class 10, one small independent
   change each: heredoc bodies (`<<~`/`<<-`) as text, `enum class NAME`,
   `static mut NAME`, `~Dtor`, C macro bodies, `function tbl.name()` in Lua,
   nested Lua table depth, `const` vs `var` in JS/TS. Each is a handful of lines
   with an obvious test. **Small**, and they are the cheapest precision wins.

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
- **Which of a method's two sites a call names.** In C++, a method has a
  declaration in the header and a definition in the .cpp. Both are definitions;
  an edge has to pick one, and there is no principled choice, so
  `Counter::bump`'s CRTP call `static_cast<Derived*>(this)->step()` is left out
  entirely (no resolver binds it without instantiation either).
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

## Keeping the numbers honest

`tests/golden/floors.json` records each language's six measurements - the five
headline metrics plus `site_recall_bp` - as the floors the gate enforces. They
start at the baseline above, so the gate only ever catches a regression. After a wave lands, re-record with
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
