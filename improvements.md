# NavGraph — findings from dogfooding

Written after auditing Phases 1–3 (type-scoped resolution, cross-language API
linking, incremental cache + JSON) by navigating the codebase **with NavGraph
itself** instead of `grep`/`read`. It records what worked, the correctness bugs
that dogfooding surfaced (and which are now fixed), and the output/UX gaps worth
addressing next — ranked by impact on an agent.

---

## What works well

- **`outline -v names` is the standout.** A whole-repo structural map in a few
  hundred dense lines; far cheaper than reading files. `outline <subdir>` and
  per-file outlines are equally good orientation tools.
- **Real edges, not text.** `calls`/`callers` resolve actual references, so
  matches inside comments/strings don't pollute results, and same-name symbols
  in different files are disambiguated (e.g. the two `build` and three `parse`
  definitions are listed separately with their files).
- **Type-scoped member resolution behaves as designed.** A member call on an
  unknown receiver (`x.family()`) is correctly left *external* rather than
  guessed — visible when auditing `chooseTarget`.
- **Cross-language API linking is genuinely novel and reliable.** A Python
  `@app.get("/users/{id}")` and a TS `fetch(\`/users/${id}\`)` link both ways
  first try; `routes` gives a clean API surface.
- **JSON mode** (`-j`) produced valid, well-formed output for every verb — good
  for tooling/MCP.
- **Cache** makes repeat calls fast (~5× on a 40k-line tree).

---

## Correctness bugs found while dogfooding — now fixed

1. **Zig `\\` multiline strings were tokenized as code.** `navgraph routes` on
   this very repo reported a phantom `GET /users/{id}` route that lives only
   inside a test fixture string. The shared lexer had no notion of Zig's
   to-end-of-line string literal, so any code-shaped text inside `\\ ...` lines
   (extremely common in Zig tests) produced phantom symbols and routes.
   → Fixed by adding `Config.line_string` (set to `\\` for Zig) and lexing such
   lines as string tokens. Regression test added.

2. **The cache was rewritten on every invocation.** Even a no-op query
   re-serialized the entire repo to `.navgraph/cache` (hundreds of KB, or many
   MB on a large repo) despite nothing changing.
   → Fixed: the write is skipped when every file was a cache hit and no file was
   added/removed (`cacheStale`).

3. **Usage errors exited 0 with no explanation.** `navgraph calls build -d abc`
   and `-d1` just dumped the full help text and returned success, so a script or
   agent couldn't tell the command had failed.
   → Fixed: parse failures now print a one-line reason to **stderr** and exit
   **2**; valid runs and explicit `help` still exit 0.

---

## Output / UX gaps to address next (ranked)

### 1. Module-qualified calls don't resolve — ✅ FIXED (Phase 4)
`callers`/`calls` used to miss every call made through an imported module
(`render.symbol`, `api.methodsMatch`, `cache.load` reported zero callers).
Import-aware resolution (`src/imports.zig` + `index.buildImportTable`) now binds
`mod.func()` to the imported file's `func` across Zig/JS/TS/Python, so these
resolve. A related `collectRefs` bug that dropped a qualified call sharing the
enclosing function's name was fixed too. *Remaining:* calls on values whose type
isn't tracked (enum methods like `x.tag()`) still fall through to external.

### 2. `callers`/`calls` don't show the call-site line — too little info
Each caller is printed at *its own definition* line (`parseZigFn … :566`), not
the line where the call actually happens. The `Reference.line` field already
holds the call-site line; it just isn't rendered. Showing `→ used at L620`
would let an agent jump straight to the usage instead of re-searching the body.

### 3. Attached flag values are rejected
`-d2` and `--depth=2` fail with "unknown flag" (now at least a clear error).
Agents frequently write these. Supporting `-d2` and `--flag=value` would remove
a common, silent-until-now footgun.

### 4. Large `const` initializers are dumped in `sig` view — too much info
`outline -v sig` prints ~160 chars of a comptime map's value
(`router_receivers`, keyword sets, etc.), which is noise when you only wanted
the shape. For container/collection constants, showing just the type
(`std.StaticStringMap(void)`) or the first entry would be cleaner. Verbosity
`names` already avoids this, but `sig` is the default.

### 5. `search` matches definition names only — occasional confusion
Searching for something that's only *used* (e.g. `fetch`) returns "no symbol
matching", which reads like the identifier is absent. A one-line hint, or an
opt-in `--refs` mode that also searches reference names, would help.

### 6. Ambiguity handling for same-named free functions
`Parent.name` disambiguates methods, but two same-named top-level functions in
different files (the two `build`s) can only both be shown. A `file:name` or
`path#name` selector would let a query target one precisely.

---

## Suggested priority

1. ~~Import-aware module resolution~~ — ✅ done (Phase 4); `callers`/`calls`/
   `unused`/`imports` are now trustworthy across files.
2. **Call-site lines in caller/callee trees** (gap 2) — small, high utility, now
   the top open item.
3. **Attached flag values** (gap 3) — small, removes a real friction point.
4. Then the output-tuning items (4–6) as polish, plus **relevance ranking**
   (fan-in/out counts) to surface important symbols first.
