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
different bug from missing the edge.

## Baseline at this commit

Percentages; the triples are matched/produced/expected.

| language | def P | def R | defs | edge P | edge R | edges | exact agree |
|---|---|---|---|---|---|---|---|
| c | 98.68 | 65.78 | 75/76/114 | 100.00 | 56.81 | 50/50/88 | 100.00 |
| cpp | 69.40 | 56.02 | 93/134/166 | 41.66 | 18.75 | 15/36/80 | 33.33 |
| csharp | 100.00 | 71.07 | 86/86/121 | 89.47 | 51.51 | 34/38/66 | 52.94 |
| go | 100.00 | 80.00 | 80/80/100 | 81.81 | 47.36 | 27/33/57 | 70.37 |
| java | 100.00 | 76.25 | 106/106/139 | 78.94 | 61.22 | 60/76/98 | 41.66 |
| javascript | 85.05 | 77.08 | 74/87/96 | 93.87 | 75.40 | 46/49/61 | 82.60 |
| lua | 92.72 | 68.00 | 51/55/75 | 80.55 | 63.04 | 29/36/46 | 79.31 |
| python | 96.68 | 91.14 | 175/181/192 | 90.00 | 85.40 | 117/130/137 | 75.21 |
| ruby | 96.42 | 75.00 | 54/56/72 | 100.00 | 23.21 | 13/13/56 | 53.84 |
| rust | 98.64 | 85.88 | 73/74/85 | 70.58 | 45.56 | 36/51/79 | 66.66 |
| typescript | 91.78 | 56.30 | 67/73/119 | 96.15 | 45.45 | 25/26/55 | 84.00 |
| zig | 100.00 | 72.91 | 105/105/144 | 98.36 | 63.82 | 60/61/94 | 61.66 |
| **all** | **93.35** | **73.01** | 1039/1113/1423 | **85.48** | **55.83** | 512/599/917 | **69.33** |

Python is the reference implementation: it is the only language where both
recalls clear 85%. C++ is the outlier in every column. Ruby produces almost no
edges at all. The 1113 produced definitions and 599 produced edges are what an
agent sees today; the 1423 and 917 are what it should see.

## Failure classes, by what they cost

Counted across all twelve languages: 365 missing definitions, 55 phantom
definitions, 19 mis-kinded or mis-placed definitions, 405 missing edges, 87
phantom edges, 157 exactness disagreements.

**1. Container members are indexed for two languages out of twelve** - 241 of
the 365 missing definitions. `field` is a first-class kind and `navgraph def
Money.amount` works, but only Python dataclass attributes and Lua table fields
ever populate it. `Chunk.code_len`, `Widget.Name`, `Product.priceCents`,
`RequestOptions.method` and every other struct field, class field, interface
member, property and record component is absent from the graph, in ten
languages.

**2. A reference to a type is usually not an edge** - the single largest edge
class. Of 405 missing edges, 215 point at a type
(`struct`/`class`/`enum`/`iface`/`type`). `var buf: [128]lexer.Token`,
`Vec *v = malloc(...)`, `var widget models.Widget`, `class Sprite : public
Positioned` all record nothing. Zig, C, C++, Rust and Ruby produce none at all;
Go finds 2 of 15 and TypeScript 2 of 16, while Python finds 41 of 43 - so this
is per-language parser work, not a missing model.

**3. C++ out-of-line definitions lose their class** - 41 phantoms and 41 misses
in one language. `double Shape::area() const` in shapes.cpp is indexed as a
free function named `area` with no parent, so `Shape.area` is missing and `area`
is a phantom; every call to it lands on the wrong side too. The index already
has the cross-file parenting pass that Rust `impl Type` and Go `func (r Type)`
use (`Symbol.receiver`); C++ `Type::method` never fills it.

**4. Same-name symbols in another file get bound anyway** - most of the 87
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

**6. Ruby barely resolves at all** - 23.21% edge recall, the worst number in the
table. `book.available?`, `find(id)`, `Sorting.by_title`, `super.label`,
`identifier` from an included module: 43 of 56 edges are missing. The
attr_accessor-generated readers are missing as definitions too, so half the call
targets do not exist in the graph.

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
   resolution). Fixes classes 4 and 5 together: it removes most of the 87
   phantom edges and re-aims ~40 misbound ones, and it is the only wave that
   improves precision. It should also raise the confidence bit where the
   receiver's declared type is known, taking a large bite out of class 9.
   Affects go, java, csharp, rust, python, cpp, js. **Medium**, and the highest
   value in the list.
2. **Index container members in every language** (`parser.zig`, per-language
   member parsing). Class 1: 241 definitions, +17 points of overall definition
   recall on its own. The kind, the model and two working implementations
   already exist, so this is mostly per-language parsing. **Medium-large**, but
   splittable one language at a time.
3. **Record type-use edges** (`parser.zig` reference collection). Class 2: 215
   edges. The `RefKind.type_use` variant is already in the model and already
   traversed by `graph`/`calls`; the parsers simply do not emit it for a type
   named in a body. **Medium**.
4. **Parent C++ out-of-line definitions to their class** (`parser.zig` +
   `index.zig` receiver pass). Class 3: 41 phantoms and 41 misses, and it is
   what makes C++ the worst language in the table. Reuse the existing
   `Symbol.receiver` cross-file pass. **Small**, unusually high value.
5. **Ruby method resolution** (`parser.zig` ruby, `index.zig`). Classes 6 and 8:
   attr_accessor definitions, self-calls, `super`, module-mixin methods and
   `Namespace::Class.method` receivers. Ruby is 23% today; this is the whole
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
- **An edge between two overloads of one name.** `Ledger.Post(string, int)`
  calling `Ledger.Post(Entry)` has the same from and to key. The edge model has
  no overload discriminator, so overload-to-overload calls are unrepresentable
  and excluded in C#, C++ and Java.
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

`tests/golden/floors.json` records each language's five measurements as the
floor the gate enforces. They start at the baseline above, so the gate only ever
catches a regression. After a wave lands, re-record with
`zig build bench -- --update-floors` and commit the raised floors with the fix,
which is what locks the gain in. Never lower a floor to make a build pass: a
number that went down is the finding.
