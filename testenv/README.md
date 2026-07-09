# NavGraph test environments

Small, self-contained applications used to **dogfood NavGraph** — each is a
realistic app with *known ground truth* (which symbols, edges, routes and
imports exist), so running NavGraph against it and diffing the output against
the truth surfaces real bugs. This directory is in NavGraph's `ignored_dirs`, so
it never pollutes the tool's own self-navigation; probe each app by rooting into
it: `navgraph <verb> -C testenv/<app> --no-cache`.

Together they give full-coverage exercise of **every supported language** (Zig,
C, C++, C#, Python, JavaScript, TypeScript/TSX, Lua, Go, Rust, Ruby) and every
verb. Each app was expanded/authored to exercise the full construct set of its
language; findings from dogfooding them live in `../new-features.md`.

| App           | Language(s)        | Exercises                                                                 |
|---------------|--------------------|--------------------------------------------------------------------------|
| `zig_vm`      | Zig                | `@import`, structs/enums/unions, nested types, methods, generic type-constructor fns, error sets, factories, dead code, `\\` multiline-string phantom suppression |
| `c_lib`       | C                  | headers + object/function-like `#define` macros, structs/enums/unions, typedefs, function pointers, static-helper call edges, dead statics |
| `cpp_app`     | C++                | nested `namespace`, `class` + (virtual/multiple) inheritance, inline & out-of-line methods, ctor init-lists, templates, operator overloads, `enum class`, free functions |
| `cs_app`      | C#                 | `using`, dotted + nested `namespace`, classes + inheritance, `interface` impls, generics `<T>`, properties, static members, enums, dead code |
| `py_fastapi`  | Python             | FastAPI `@router` with prefix, every HTTP verb, empty-path routes, async def, class services, dataclasses, dotted + **relative** imports, dunders, `test_`/`conftest` dead-code exclusion |
| `js_express`  | JS (CommonJS+ESM)  | Express routes (all verbs, sub-routers), `require()` + destructured require, ESM `import`/`export … from`, classes, inline-arrow vs identifier handlers, `fetch`/`axios` clients, event bus |
| `ts_frontend` | TS + TSX           | `interface`/`enum`/`type` (generics), classes, arrow components, index-file + `export … from` re-export resolution, typed-receiver member calls, `fetch({method})`, `import type` |
| `lua_game`    | Lua                | global/`local function`, `M.foo`/`function M.foo`, colon methods `Obj:update()`, table-constructor function fields, `require`, `return M` module pattern, nested tables, dead tables |
| `go_service`  | Go                 | packages, value & pointer receivers, structs (tags), interfaces, `type`/const/var blocks, single + grouped imports, exported vs unexported, net/http routes, dead code |
| `rust_cli`    | Rust               | `fn`/`struct`/`enum`, inherent & trait `impl`, `trait`, `mod`, `use`, `const`/`static`, `type` alias, `macro_rules!`, `///` docs, generics + lifetimes, dead code |
| `ruby_app`    | Ruby               | `def` + `self.` methods, `class`/`module` (mixins), nested containers, `require`/`require_relative`, attr_accessor, Sinatra-style routes, dead code |
| `fullstack`   | Python + TS        | cross-language route linking: every GET/POST/PUT/DELETE/PATCH client call linked to the matching Flask blueprint route (with `url_prefix`), plus a message-bus register/emit pair |

To re-run the full probe/verify sweep, see the workflow scripts referenced in
the project's dogfooding notes (`improvements.md`) and the feature backlog in
`../new-features.md`.
