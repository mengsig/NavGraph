# NavGraph — new feature ideas (from dogfooding while writing tests)

Ideas surfaced by *using* NavGraph to navigate its own source and to build/verify
an expanded `testenv/` fixture corpus spanning all 11 supported languages. The
guiding question throughout: **"what would I want NavGraph to be able to do right
here?"**

Scope: ideas **not already covered** by `ROADMAP.md` (tree-sitter backend,
generic "richer edge kinds", daemon/LSP/MCP, `--jsonl`, PageRank ranking, UTF-8
columns, fuzzing) or already shipped in `improvements.md`. Where a theme touches
a ROADMAP item, the *specific, reproducible* finding below is still new and
actionable.

Legend: **[bug]** wrong output · **[gap]** a construct/verb it should handle but
doesn't · **[nice]** an ergonomic win for the consuming agent.

Evidence: every item was observed either by running the current `navgraph`
against a fixture under `testenv/` (67 findings — 14 bugs, 33 gaps, 20
nice-to-haves; full list in the appendix) or by asserting on the in-memory graph
while writing the Zig unit tests (11 more — see §K). 78 findings total; the
sections below curate them by theme.

---

## A. Test-awareness — the biggest missing capability

Measuring this very task's coverage hit a wall that turned into the single
highest-value idea here.

### A1. Index `test` blocks as first-class symbols  **[✅ shipped]**
*Shipped:* Zig `test "…" {}` blocks are now `.test_case` symbols with body
edges, so `callers foo` shows the tests that exercise `foo`.
`navgraph outline src/gitdiff.zig` lists the functions but **none of the `test`
blocks**, though the file has several. Zig `test "name" { ... }` are executable
units with a call graph, but NavGraph drops them. Consequences I hit directly:
- A function exercised **only** by a test has no non-test caller, so `callers`
  shows nothing and `unused` would flag it as dead — a false positive that
  punishes well-tested private helpers.
- No way to ask "what does this test touch?" or "which tests exercise `foo`?" —
  exactly what you want when a test fails.

Proposal: parse `test` blocks as a `test` symbol-kind (name = the test string),
record their edges like any function, and let `callers foo` show `test "…"`
entries. Generalizes to Rust `#[test]`, Python `def test_*`, JS `it()/test()`.

### A2. A `coverage` / `reached-by-test` verb  **[✅ shipped]**
*Shipped:* `navgraph coverage [path]` reports the per-file and overall fraction
of `fn`/`method` reachable from a test (text + JSON) — replacing the throwaway
external script. Once tests are symbols (A1), NavGraph answers "which functions
are reachable from a test?" natively. This was needed
because there is **no working line-coverage tool for this codebase**: kcov 43
cannot parse Zig 0.16's DWARF5 line programs (even a trivial `zig test` binary
reports 0 lines) and Zig has no built-in coverage. A static call-graph
reachability metric is a genuinely useful substitute NavGraph is uniquely placed
to provide: `navgraph coverage [path]` → per-file % of fn/method reachable from a
test + the unreached list. Conservative vs. line coverage, zero instrumentation,
works on every language NavGraph parses.

### A3. `unused --no-test` from real edges, not filename heuristics  **[nice]**
Because tests aren't in the graph (A1), `--no-test` narrowing keys off
path/name patterns (`test_*`, `conftest.py`, `*.spec.*`). With real test-edge
data it could mean "used only from `test` blocks" precisely.

---

## B. Graph-level queries I wanted and couldn't get

### B1. A whole-graph edge dump (`navgraph graph --json`)  **[nice]**
To compute test reachability I had to shell out to `navgraph calls <sym>` once
per seed symbol and stitch trees together — there is no way to get **all edges at
once**. A single `graph -j` emitting `{nodes, edges:[{from,to,kind,site}]}` would
let a tool build the graph in one call and makes NavGraph a drop-in data source
for external analysis (coverage, cycles, dominators, visualization).

### B2. Set-reachability (`navgraph reaches <A,B,C> --from-tests`)  **[nice]**
`path A B` is single-pair; `calls`/`callers` are single-root. There's no
"reachable set from a *set* of roots" — what coverage, multi-symbol blast radius,
and "what can this entry point touch?" all need. `diff` already computes this
internally for changed symbols; exposing the general op would generalize it.

---

## C. Scope-blind reference resolution — recurring false edges (highest-impact bug class)  **[✅ shipped: graph edges]**

*Shipped:* JS/TS object-literal keys and untyped params/locals no longer create
false call/read edges — `callers`/`calls`/`hot`/`path` are clean. (The `unused`
token-tally's scope-blindness is tracked with §E.)

Name-based reference matching still leaks across scopes, producing **both false
callers and hidden dead code**. ROADMAP Tier 1 fixed type-scoped *member* calls,
but *bareword* references remain scope-blind. Seen in 3 languages independently:

- **[bug] Object-literal property keys count as calls.** (JS `js_express`, TS
  `ts_frontend`.) `res.json({ count: store.size() })` makes `count:` resolve to a
  top-level `count()`; `return { ok: false }` makes `ok:` a call to `ok<T>()`.
  `callers count`/`callers ok` list bogus callers, and the dead `count()` is kept
  out of `unused`.
- **[bug] Function parameters shadow globals but still bind.** (JS.) A parameter
  named `count` in `formatStatus(count)` is counted as a call to global `count()`.
- **[bug] Same-name symbols in other files collide.** (Python `py_fastapi`.) Two
  `get_item` (route handler vs `db.get_item`); an unresolved `db.get_item(...)`
  name-matches the wrong one, polluting `neighbors`/`callers`.

Fix direction: an object-literal-key context check and local-binding/param
shadowing check in reference resolution (the local-variable case already exists
per `improvements.md`; extend it to object keys and params). This single class
would improve `callers`, `calls`, `hot`, and `unused` precision at once.

---

## D. Missing or mislabeled symbol kinds (per-language parser depth)  **[✅ partly shipped]**

*Shipped:* Go package-level `const`/`var` (single and grouped `const ( … )`,
skipping multi-line initializers so call args don't become phantom symbols) are
now indexed — though a multi-name `var x, y int` still records only the first
name; C# **expression-bodied methods** (`M() => expr;`) are now indexed
with their body references (previously their `=>` body matched neither a `{`
body nor a `;` declaration, so they vanished). *Still open below:* C# properties/
fields/generic-methods, the Zig generic-container idiom, the C++ items, and
union labeling.

Whole categories of real symbols are invisible or wrong. Each makes `outline`,
`def`, `search`, and `unused` incomplete for that language.

**C# (weakest support overall — 8 findings):**
- **[gap]** Properties (auto `{get;set;}`, get-only, expression-bodied, static)
  are unindexed — `def PriceDollars` → "no definition".
- **[gap]** Fields (incl. `public static int NextOrderId`) unindexed.
- **[gap]** Generic methods `Foo<T>(...)` dropped even when block-bodied (side
  effect: their class is falsely reported fully dead by `unused`).
- **[gap]** Expression-bodied methods `IsEmpty() => …;` dropped.

**C++ (`cpp_app`):**
- **[bug]** `enum class ShapeKind` indexed with **no name** — `def ShapeKind`
  fails though `search --refs` finds 5 uses.
- **[bug]** Out-of-line member defs (`Shape::area` in `.cpp`) not attributed to
  their class — rendered as bare `fn area`, so `def Shape.area` reaches only the
  header declaration, never the body.
- **[gap]** Operator overloads completely unindexed (and drop the *following*
  member too — a parser desync).
- **[nice]** Destructors render identically to constructors.

**C (`c_lib`):** **[bug]** `union` labeled/reported as `struct`; **[gap]**
function-pointer typedefs unindexed.

**Zig (`zig_vm`):** **[bug]** methods of a struct returned by a generic
type-constructor (`fn Stack(comptime T) type { return struct { … } }`) are not
indexed, so `operands.push()` mis-resolves to an unrelated `Vm.push`; **[gap]**
`union(enum)` rendered as `struct`; **[nice]** enum backing integer type dropped.

**Go (`go_service`):** **[bug]** package-level `const`/`var` (grouped and single)
unindexed — `search StatusActive`/`ErrNotFound` find nothing.

**Rust (`rust_cli`):** **[bug]** `impl<'a> Lexer<'a>` (lifetime/generic-param
impl) orphans all its methods to top level — they don't nest under `Lexer` and
`def Lexer` shows zero methods. **Root cause identified:** `rustImplTypeName` in
`src/parser.zig` takes the last identifier before `{`, which for
`impl<'a> Lexer<'a>` is inside the generics, not the type. High-value, localized
fix.

**Ruby (`ruby_app`):** **[bug]** predicate/bang names lose their trailing `?`/`!`
— `def available?` stored as `available`, so `def 'available?'` fails; **[nice]**
`attr_accessor` accessors not surfaced.

**Lua (`lua_game`):** **[gap]** `field`-kind symbols omitted from `outline` (but
counted by `files` and found by `search`) — the two views disagree; **[gap]**
nested-table function fields flattened to the outermost table.

---

## E. `unused` precision — dead **types** and access modifiers  **[✅ partly shipped]**

*Shipped:* (1) C# access modifiers — an explicit `private`/`protected`/`internal`
member is `exported=false`, so `unused --no-public` no longer over-hides a
genuinely-private dead helper. (2) A dead **decorated class** (`@dataclass`) is
now reported — `precededByDecorator` only excludes decorated *functions/methods*
(framework hooks), not classes. (3) A JS/TS object-literal key no longer counts
as a "use" in the dead-code tally, so it can't mask a dead function.

*Still open:*
- **Ruby visibility** (statement-form `private`/`protected` toggling subsequent
  defs) is not yet modeled — more involved than C#'s per-member modifiers.
- **Dead types via the name-tally**: a self-referential type (its name appears
  in its own fields) still reads as "used"; Lua tables are `.variable`-kind (not
  a reportable dead kind); a C function-pointer `typedef` isn't indexed at all
  (see §D). A genuinely-dead, non-self-referential type *is* reported.
- **Param-shadow in the tally**: a bare parameter used in its own body still
  counts toward a same-named global's usage (the *graph* is correct after §C, but
  the `unused` token-tally needs scope-aware tallying to match).
- **[bug] Dead code in a nested namespace is missed** when a sibling is used —
  `geo::detail::deadScale` (C++) is dead but absent from `unused`.

---

## F. Import graph is empty for several languages  **[gap]**

`imports`/`importers` resolve nothing for **C/C++ `#include`**, **C# `using`**,
and **Go module-path imports** — the local dependency graph is blank there, and
cross-file edges fall back to heuristic name-matching. Plus one **[bug]**:
Python `from package import submodule` resolves to the package `__init__.py`
instead of `submodule.py`, so `importers app/db.py` misses its three real
importers and downstream `db.*` calls mis-resolve (feeds the name-collision bug
in §C).

---

## G. `routes` / `events` breadth  **[gap]**

- No **Go net/http** support (no server routes, no client linking).
- No **Ruby Sinatra** classic routes (`get "/x" do … end`).
- **Express** routes recognized only when the router var is literally
  `router`/`app` (sub-routers mounted under other names are invisible), and
  `.head()`/`.options()` verbs are not recognized.
- A **frontend-only** app with explicit client `fetch` sites surfaces nothing in
  `routes` — there's no "unmatched client calls" view.
- **[nice]** `events` shows the handler *registration call site* but not the
  bound handler *function symbol*, so you can't jump to the handler body.

---

## H. `def -v doc` rarely surfaces docs  **[gap/bug]**

- **[gap]** Python **docstrings** are never surfaced by `def -v doc` (only
  leading `#`/`//` line comments are). Same for C block-comment docs.
- **[bug]** TS **multi-line JSDoc** (`/** \n * … \n */`) is dropped — only
  single-line `/** … */` renders. It's a comment-*style* limitation, not a
  symbol-kind one (`def Store -v doc` with a one-line block works; the multi-line
  sibling doesn't).

---

## I. `outline` rendering fidelity  **[nice]**

- Dotted namespaces collapse to the last segment (`Inventory.Models` → `Models`),
  and nested block namespaces flatten to siblings.
- Generic parameter clauses dropped from names/signatures (`Repository<T>` →
  `Repository`; Rust `fn f<T>` shows no `<T>`).
- Multi-line return-type signatures truncated at the first newline (TS, C).
- Rust `static mut` rendered as `const mut` (invalid-looking Rust).
- `search <Type> --refs` misses type-usage positions (params/returns/annotations)
  — it finds call/value uses but not "used as a type here". (Zig, C.)

---

## J. Smaller ergonomics  **[nice]**

- `callers` lists the same caller once per call site instead of de-duplicating
  (Rust) — noisy when a function is called several times from one place.
- Import-resolved member-call edges have inconsistent `exact`/`?` confidence
  depending on how the target was defined (Lua).
- A pure **type annotation** is sometimes counted as a call edge (Zig) — inflates
  `calls`.

---

## K. Engine bugs found while writing the Zig unit tests  **[✅ several shipped]**

Writing white-box tests against the parser/index surfaced defects that
black-box fixture dogfooding didn't. Each was observed by asserting on the
in-memory graph (`idx.graph.symbols[...].refs`, `callersOf`, `findSym`).

- **[✅ shipped] Single-line Go `import "fmt"` bound the wrong name.**
  `emitGoImport` treated the preceding `import` keyword as an alias, binding the
  import as `"import"`; it now skips the keyword and binds `fmt`.
- **[✅ shipped] Rust `impl<'a> Type<'a>` orphaned its methods.**
  `rustImplTypeName` grabbed the last identifier before `{` (a lifetime); it now
  skips the impl's generic clause and each type's own args, nesting methods under
  the real type.
- **[✅ shipped] `-C <file>` (a single file path)** now scopes the index to that
  file instead of erroring with `NotDir`.
- **[✅ shipped] Zig `test` blocks omitted from `outline`** — fixed in §A1.
- **[gap] `import type X from '...'` binds the literal name `type`.** The `type`
  keyword is only skipped before `{`/`*`, so a default type-only import emits an
  import symbol literally named `type`.
- **[gap] Lua colon-method calls drop the receiver.** `memberQualifier` handles
  `.`/`->`/`::`/`?.`/`!.` but not Lua's `self:helper()`, so the `self` receiver
  is lost and the call can't be type-scoped (unlike `self.helper()`).
- **[gap, deliberate?] Direct self-recursion produces no call edge.** For
  `fn rec() void { rec(); }`, `rec` has zero refs — a *bare* self-reference is
  suppressed by design (recursion noise) and the resolver also skips self-binding.
  Surfacing it (with a recursion marker) would let `calls`/`callers`/`hot` reflect
  recursive functions, but it's a design change, not an obvious bug — left as-is.
- **[nice] Single-character reference names are dropped.** `collectRefs` skips
  identifiers with `name.len < 2`, so a `p->x()` call/field (1-char name, valid
  in C/Go) is never recorded as an edge.
- **[nice] `outline` doesn't surface symbol visibility** (`pub` vs private) as a
  field, though the parser tracks `exported` — a cheap addition for triage.
- **[nice] A per-parameter `///` doc comment is folded into the signature**, and
  an anonymous-struct return type is truncated (dropping the function's end line).

---

## Appendix — all 67 findings (auto-generated)

| # | app | sev | verb | finding |
|---|-----|-----|------|---------|
| 1 | c_lib | bug | `outline / def` | C union is labeled and reported as a struct |
| 2 | cs_app | bug | `calls / callers / hot ` | Unqualified same-class method calls resolve as external (~ ext) instead of internal edges |
| 3 | go_service | bug | `outline / search` | Go package-level const/var declarations are not indexed |
| 4 | js_express | bug | `unused / callers / cal` | Bareword name-matching ignores scope: object-literal keys and function parameters counted as calls, hiding dead code |
| 5 | py_fastapi | bug | `imports / importers` | `from package import submodule` resolves to the package __init__.py, not the submodule file |
| 6 | py_fastapi | bug | `callers / neighbors` | Name-collision + unresolved module-qualified call produces wrong caller/callee edges |
| 7 | ruby_app | bug | `def` | Predicate/bang method names lose their trailing ? (and would lose !) |
| 8 | rust_cli | bug | `outline` | impl<'a> Type<'a> (lifetime-parameterized impl) orphans all its methods |
| 9 | cpp_app | bug | `outline/def/search` | enum class name is dropped entirely; the enum is not navigable |
| 10 | cpp_app | bug | `outline/def/callers/un` | Out-of-line member definitions (Type::method in .cpp) are not attributed to their class |
| 11 | cpp_app | bug | `unused/calls` | `unused` misses dead code in a nested namespace when a sibling symbol is used |
| 12 | ts_frontend | bug | `def -v doc` | def -v doc drops multi-line JSDoc block comments |
| 13 | ts_frontend | bug | `callers` | Object-literal property keys mis-resolved as references to same-named functions |
| 14 | zig_vm | bug | `outline/calls/def/unus` | Methods on a struct returned by a generic type-constructor fn are not indexed, causing mis-resolved call edges |
| 15 | c_lib | gap | `def / search / outline` | Function-pointer typedefs are not indexed at all |
| 16 | c_lib | gap | `unused` | unused does not report dead types, only dead functions |
| 17 | c_lib | gap | `imports / importers` | imports/importers ignore C #include directives |
| 18 | c_lib | gap | `def -v doc` | def -v doc surfaces no doc text for C comments |
| 19 | cs_app | gap | `outline / def / search` | C# properties (all forms) are not indexed as symbols |
| 20 | cs_app | gap | `outline / def` | C# fields are not indexed |
| 21 | cs_app | gap | `outline / def / unused` | Generic methods (Foo<T>(...)) are not indexed even when block-bodied |
| 22 | cs_app | gap | `outline / def` | Expression-bodied methods (=> expr) are not indexed |
| 23 | cs_app | gap | `imports / importers` | `using` directives yield no import edges for C# |
| 24 | cs_app | gap | `unused --no-public` | C# access modifiers ignored: `unused --no-public` hides genuinely-private dead code |
| 25 | go_service | gap | `imports / importers` | imports/importers do not resolve Go local (module-path) package imports |
| 26 | go_service | gap | `routes` | routes verb has no Go net/http support (no server routes, no client linking) |
| 27 | go_service | gap | `callers / neighbors / ` | Handler method-values passed as arguments are not captured as caller/reference edges |
| 28 | js_express | gap | `routes / outline` | Express routes only recognized when router variable is named `router`/`app`; sub-router endpoints invisible |
| 29 | js_express | gap | `routes / outline` | HTTP verbs .head() and .options() not recognized as routes |
| 30 | js_express | gap | `unused` | `unused` under-reports dead class methods masked by a same-named method on another class |
| 31 | lua_game | gap | `outline` | outline omits field-kind symbols, undercounting vs `files` |
| 32 | lua_game | gap | `unused` | `unused` misses dead Lua tables (the idiomatic type/class/config) |
| 33 | lua_game | gap | `outline` | nested-table function fields are flattened to the outermost table, losing the intermediate segment |
| 34 | py_fastapi | gap | `def -v doc` | `def -v doc` never surfaces docstrings for any symbol type |
| 35 | py_fastapi | gap | `callers / path --stric` | Method calls through a module-level service singleton / dependency instance are only heuristic |
| 36 | py_fastapi | gap | `callers / search --ref` | Decorator application is not tracked as a reference/edge |
| 37 | ruby_app | gap | `routes` | Sinatra classic routes are not detected at all |
| 38 | ruby_app | gap | `calls` | Receiver-less and local-variable method calls produce no call edges |
| 39 | ruby_app | gap | `unused` | Ruby private/protected visibility is not modeled, so --no-public over-hides real dead code |
| 40 | rust_cli | gap | `path` | Trait-method call resolves to the bodyless trait declaration, not the impl, breaking path/calls traversal |
| 41 | rust_cli | gap | `files` | On-PATH navgraph binary is stale and indexes zero Rust/Go/Ruby files |
| 42 | cpp_app | gap | `imports/importers` | C++ local #include dependency edges are not resolved (import graph empty) |
| 43 | cpp_app | gap | `outline/search/def` | Operator overloads are completely unindexed and drop the following class member |
| 44 | fullstack (Python Flask + TypeScript orders/customers/inventory app) | gap | `unused` | unused does not report dead Python classes/dataclasses (only functions + TS interfaces) |
| 45 | fullstack (Python Flask + TypeScript orders/customers/inventory app) | gap | `def` | def -v doc ignores Python docstrings (only surfaces leading # / // line comments) |
| 46 | ts_frontend | gap | `calls / callers / path` | Member/method calls resolved by name only, ignoring the statically-known receiver type |
| 47 | zig_vm | gap | `outline/def` | union(enum) / union types are rendered as `struct` |
| 48 | c_lib | nice-to-have | `search --refs` | search <Type> --refs misses parameter/return type positions |
| 49 | cs_app | nice-to-have | `outline` | Dotted namespaces collapse to last segment; generic <T> dropped from type names |
| 50 | go_service | nice-to-have | `calls / callers` | Cross-package Go edges are heuristic-only because imports are unresolved |
| 51 | js_express | nice-to-have | `outline` | `export ... from` re-exports do not appear as symbols in outline |
| 52 | js_express | nice-to-have | `imports` | Duplicate import edge when the same module is both imported and re-exported |
| 53 | lua_game | nice-to-have | `def` | Lua `function Recv.name()` / `function Recv:name()` defs render as a bare unqualified name |
| 54 | lua_game | nice-to-have | `calls` | import-resolved member calls have inconsistent confidence based on how the target was defined |
| 55 | ruby_app | nice-to-have | `def` | Superclass and included mixins are not shown in outline/def nor counted as refs |
| 56 | ruby_app | nice-to-have | `outline` | attr_accessor-generated accessors are not surfaced as symbols |
| 57 | rust_cli | nice-to-have | `calls` | Chained method call receiver not inferred: `Parser::new(tokens).parse()` leaves .parse() unresolved |
| 58 | rust_cli | nice-to-have | `callers` | callers lists the same caller twice for multiple call sites instead of de-duplicating |
| 59 | rust_cli | nice-to-have | `outline` | Generic parameter clause dropped from displayed signatures |
| 60 | rust_cli | nice-to-have | `outline` | static mut rendered as `const mut`, producing invalid-looking Rust |
| 61 | cpp_app | nice-to-have | `outline` | Destructors are rendered identically to constructors |
| 62 | fullstack (Python Flask + TypeScript orders/customers/inventory app) | nice-to-have | `outline` | Multi-line TS return-type signatures are truncated at the first newline |
| 63 | fullstack (Python Flask + TypeScript orders/customers/inventory app) | nice-to-have | `events` | events shows the handler registration call site but not the bound handler function symbol |
| 64 | ts_frontend | nice-to-have | `routes` | routes surfaces nothing for a frontend-only app despite explicit client call sites |
| 65 | zig_vm | nice-to-have | `search --refs` | search <Type> --refs misses type-usage sites and substring-matches instead |
| 66 | zig_vm | nice-to-have | `calls` | A pure type annotation is counted as a call edge |
| 67 | zig_vm | nice-to-have | `outline/def` | Enum backing integer type is dropped |
