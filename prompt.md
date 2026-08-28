# NavGraph agent guide

Use NavGraph first when the question is about supported source code. It returns
symbols, exact source spans, relations, and edit sites with far less context than
whole-file reads. Grep and ordinary reads remain valid for unsupported files,
non-symbol text, and verification after NavGraph has narrowed the evidence.

Supported: Zig, C/C++, C#, Java (`.java`), Python, JavaScript,
TypeScript/TSX, Lua, Go, Rust, and Ruby.
<!-- navgraph-supported-languages: zig,c,cpp,csharp,python,javascript,typescript,tsx,lua,go,rust,ruby,java -->

## Default workflow

1. Orient: `status -j` (a bounded summary; `--full` for the freshness/parse/
   resolution dump), `files --sort symbols`, `hot`, or `outline <path>`.
2. Locate evidence: `search <name>`, `def <symbol> -v full`, `docs`, `strings`,
   or `todos`.
3. Follow structure: `neighbors`, `calls`, `callers`, `path`, `imports`,
   `importers`, `hierarchy`, `conforms`, `routes --clients`, or `events`.
4. Follow values: `flow <symbol>`; use `taint <source> --to <sink>` for the
   bounded security view.
5. Plan edits: `diff --exact-source`, `affected --since <ref>`, and
   `edits <symbol>`. Use `rename ... --preview` before any rename.
6. Read only the remaining evidence: `read file:A-B,C-D` or a continuation
   returned by a bounded source query.

Prefer `outline` over reading a file for structure, `def -v full` over reading a
file for one body, `callers` over repository-wide use-site grep, and `edits` over
assembling rename sites manually. Use `-v names` for discovery, `sig` for
planning, and `full` only for the definitions you need to inspect.

## Trust and bounds

- Pin ambiguous symbols with `Parent.name` or `name@path`. A semantic traversal
  must not be treated as authoritative until its endpoint is unambiguous.
- `?` marks a heuristic edge. JSON edges add resolution status/reason. Use
  `--strict` for exact-only traversal; exact is confidence, not compiler proof.
- `edits` lists only exact/editable spans; any `review_sites` are omitted gaps,
  not safe rename sites.
- `-l N` is a hard semantic cap where offered. Use `--budget BYTES` on commands
  declaring it, `--max-nodes N` for graph nodes, and `--summary` for name-only trees.
  Honor `truncated` and `next`; never infer completeness from a bounded page.
- Parse health, resolution health, skipped paths, freshness, and snapshot/build
  identity are part of the answer. Verify uncertain edits with the real build or
  test tool.
- Exit 0 means useful results, 1 means a valid no-match/abstention, and 2 means
  invalid input. Do not count no-match as a semantic hit.

## Composition and abstention

NavGraph should own semantic discovery; other tools may filter or verify its
output (`navgraph ... -j | jq`, `navgraph ... | grep`). Fall back directly when
the task is greenfield, the exact file/range is already known, the file type is
unsupported (Markdown, config, shell, generated data), or a dynamic construct is
outside the static graph. When a semantic query forces a fallback, record what
was missing so the graph contract can improve.

In MCP mode, use the compact typed `navgraph.query` surface and its universal
`max_bytes` bound. Capability/build
negotiation belongs in the client at session setup; do not spend model turns
loading the full human CLI manifest. Read-only agents must not receive mutating
commands. Reload the long-lived snapshot after edits.
