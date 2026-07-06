# NavGraph test environments

Small, self-contained applications used to **dogfood NavGraph** — each is a
realistic app with *known ground truth* (which symbols, edges, routes and
imports exist), so running NavGraph against it and diffing the output against
the truth surfaces real bugs. This directory is in NavGraph's `ignored_dirs`, so
it never pollutes the tool's own self-navigation; probe each app by rooting into
it: `navgraph <verb> -C testenv/<app> --no-cache`.

Together they give full-coverage exercise of every language and verb.

| App           | Language(s)        | Exercises                                                                 |
|---------------|--------------------|--------------------------------------------------------------------------|
| `zig_vm`      | Zig                | `@import`, structs/enums/unions, nested types, methods, factories, dead code, `\\` multiline-string phantom suppression |
| `c_lib`       | C                  | headers + `#define` macros, structs, static-helper call edges, dead statics |
| `cpp_app`     | C++                | `namespace`, `class` + inheritance, inline & out-of-line methods, ctor init-lists, templates, free functions |
| `py_fastapi`  | Python             | FastAPI `@router` with prefix, empty-path routes, dotted + **relative** imports, dunders, `test_`/`conftest` dead-code exclusion |
| `js_express`  | JS (CommonJS+ESM)  | Express routes, `require()` imports, ESM `import`, inline-arrow vs identifier handlers, `fetch`/`axios` clients |
| `ts_frontend` | TS + TSX           | `interface`/`enum`/`type`, classes, arrow components, index-file + `export … from` re-export resolution, typed-receiver member calls, `fetch({method})` |
| `fullstack`   | Python + TS        | cross-language route linking: every GET/POST/PUT/DELETE client call linked to the matching Flask blueprint route (with `url_prefix`) |

To re-run the full probe/verify sweep, see the workflow scripts referenced in
the project's dogfooding notes (`improvements.md`).
