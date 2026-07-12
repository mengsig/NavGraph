#!/bin/sh
# Black-box contracts for the checked-in polyglot corpus. This intentionally
# talks only to the built executable: unit tests may share implementation, but
# an agent depends on argv parsing, exit status, rendering, and indexing as one
# product.
set -eu

bin=$1
repo=$2
tmp=${TMPDIR:-/tmp}/navgraph-agent-contract.$$
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
    echo "agent-contract: $*" >&2
    exit 1
}

expect_contains() {
    file=$1
    literal=$2
    grep -F -- "$literal" "$file" >/dev/null || fail "expected '$literal' in $file"
}

expect_not_contains() {
    file=$1
    literal=$2
    if grep -F -- "$literal" "$file" >/dev/null; then
        fail "did not expect '$literal' in $file"
    fi
}

# A global result cap must apply before an agent knows how ambiguous or broad a
# selector is. Metadata/footer lines are allowed; semantic symbol rows are not.
"$bin" calls parse -C "$repo" --no-cache -l 1 -v names >"$tmp/calls-limit.txt"
symbols=$(awk '/^[[:space:]]*(fn|method|class|struct|enum|iface|type|var|const|field|macro|mod|route|test) / { n += 1 } END { print n + 0 }' "$tmp/calls-limit.txt")
[ "$symbols" -eq 1 ] || fail "calls -l 1 emitted $symbols semantic rows"
expect_contains "$tmp/calls-limit.txt" "nodes shown"

"$bin" callers parse -C "$repo" --no-cache -l 1 -j >"$tmp/callers-limit.json"
ids=$(grep -o '"id":' "$tmp/callers-limit.json" | wc -l | tr -d ' ')
[ "$ids" -eq 1 ] || fail "JSON callers -l 1 emitted $ids nodes"
expect_contains "$tmp/callers-limit.json" '"truncated":true'

"$bin" callers ServerSession.init -C "$repo" --no-cache --strict -j -l 2 >"$tmp/type-qualified.json"
expect_contains "$tmp/type-qualified.json" '"resolution_status":"exact"'
expect_contains "$tmp/type-qualified.json" '"resolution_reason":"type_qualifier"'

# A scoped usage recovery should not dump the entire command catalogue after a
# typo; it is generated from the same option registry as parsing/capabilities.
"$bin" help read >"$tmp/help-read.txt"
expect_contains "$tmp/help-read.txt" "USAGE: navgraph read <source> [options]"
if grep -F -- "COMMANDS:" "$tmp/help-read.txt" >/dev/null; then
    fail "help read emitted the full command catalogue"
fi

"$bin" calls parse -C "$repo" --no-cache --budget 1000 -v full >"$tmp/calls-budget.txt"
walk_text_bytes=$(wc -c <"$tmp/calls-budget.txt" | tr -d ' ')
[ "$walk_text_bytes" -le 1000 ] || fail "text walk --budget 1000 emitted ${walk_text_bytes}B"
expect_contains "$tmp/calls-budget.txt" "hard byte budget"

"$bin" calls parse -C "$repo" --no-cache --budget 1000 -v full -j >"$tmp/calls-budget.json"
walk_json_bytes=$(wc -c <"$tmp/calls-budget.json" | tr -d ' ')
[ "$walk_json_bytes" -le 1000 ] || fail "JSON walk --budget 1000 emitted ${walk_json_bytes}B"
expect_contains "$tmp/calls-budget.json" '"reason":"hard_byte_budget"'

# Public vocabulary must accept the same word diagnostics and help advertise.
"$bin" outline -C "$repo/testenv/rust_cli" --no-cache -k interface -l 2 -v names >"$tmp/interface.txt"
expect_contains "$tmp/interface.txt" "Evaluate"

# Every supported checked-in source file participates in at least this real CLI
# indexing/coverage scenario. Semantic assertions below protect the especially
# valuable cross-file fixtures.
"$bin" files -C "$repo/testenv" --no-cache -j -l 1000 >"$tmp/files.json"
find "$repo/testenv" -type f \( \
    -name '*.zig' -o -name '*.c' -o -name '*.h' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.hpp' -o -name '*.hh' -o \
    -name '*.cs' -o -name '*.py' -o -name '*.pyi' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.jsx' -o \
    -name '*.ts' -o -name '*.mts' -o -name '*.tsx' -o -name '*.lua' -o -name '*.go' -o -name '*.rs' -o -name '*.rb' -o -name '*.java' \
\) -print | while IFS= read -r source; do
    relative=${source#"$repo/testenv/"}
    grep -F -- "\"file\":\"$relative\"" "$tmp/files.json" >/dev/null || fail "fixture not indexed: $relative"
done

# Java ordinary dispatch: same-class, static import, and inherited lookup.
"$bin" calls Program.main -C "$repo/testenv/java_app" --no-cache --refs -d 1 -l 80 -v names >"$tmp/java-main.txt"
expect_contains "$tmp/java-main.txt" "Program.seedCatalog"
expect_contains "$tmp/java-main.txt" "Money.format"

"$bin" search format -C "$repo/testenv/java_app" --no-cache -e -v sig >"$tmp/java-signature.txt"
expect_contains "$tmp/java-signature.txt" "Money.format (int cents) -> String"

"$bin" path OrderService.placeOrderSafe OrderService.placeOrder -C "$repo/testenv/java_app" --no-cache -v names >"$tmp/java-path.txt"
expect_contains "$tmp/java-path.txt" "OrderService.placeOrderSafe"
expect_contains "$tmp/java-path.txt" "OrderService.placeOrder"

"$bin" calls DurableProduct.isSellable -C "$repo/testenv/java_app" --no-cache -d 1 -l 20 -v names >"$tmp/java-inherited.txt"
expect_contains "$tmp/java-inherited.txt" "Product.priceCents"

# Rust impl methods must remain attached when trait/type and impl span files.
"$bin" conforms Evaluate -C "$repo/testenv/rust_cli" --no-cache -j >"$tmp/rust-conforms.json"
expect_contains "$tmp/rust-conforms.json" '"parent":"Expr"'

# Parser-gap corpus: qualified members/fields must be discoverable, while
# receiverless Zig tags and nested Python bodies must not manufacture edges.
"$bin" outline -C "$repo/testenv/parser_gaps" --no-cache -v names >"$tmp/parser-outline.txt"
expect_contains "$tmp/parser-outline.txt" "Box.init"
expect_contains "$tmp/parser-outline.txt" "M.open"
expect_contains "$tmp/parser-outline.txt" "M.assigned"
expect_contains "$tmp/parser-outline.txt" "User.name"
expect_not_contains "$tmp/parser-outline.txt" "User.key"

"$bin" calls outer -C "$repo/testenv/parser_gaps" --no-cache --strict --refs -v names >"$tmp/parser-outer.txt"
expect_contains "$tmp/parser-outer.txt" "make_default"
expect_contains "$tmp/parser-outer.txt" "inner"
expect_not_contains "$tmp/parser-outer.txt" "fetch_user"

"$bin" calls inner -C "$repo/testenv/parser_gaps" --no-cache --strict --refs -v names >"$tmp/parser-inner.txt"
expect_contains "$tmp/parser-inner.txt" "fetch_user"

"$bin" calls decode -C "$repo/testenv/parser_gaps" --no-cache --strict --refs -v names >"$tmp/parser-decode.txt"
expect_not_contains "$tmp/parser-decode.txt" "symbol"

# The persisted parse cache is an optimization only: a warm agent query must be
# byte-for-byte equivalent to a forced clean rebuild on the same snapshot.
"$bin" outline -C "$repo/testenv/parser_gaps" --no-cache -j -l 100 >"$tmp/parser-cold.json"
"$bin" outline -C "$repo/testenv/parser_gaps" -j -l 100 >"$tmp/parser-cache-fill.json"
"$bin" outline -C "$repo/testenv/parser_gaps" -j -l 100 >"$tmp/parser-warm.json"
cmp -s "$tmp/parser-cold.json" "$tmp/parser-warm.json" || fail "warm-cache outline differs from no-cache output"

# A semantic path must abstain on ambiguous endpoints instead of choosing the
# first BFS seed. The structured result has to name candidates ready to pin.
if "$bin" path parse tokenize -C "$repo" --no-cache -j >"$tmp/ambiguous-path.json" 2>"$tmp/ambiguous-path.err"; then
    fail "ambiguous path unexpectedly succeeded"
fi
expect_contains "$tmp/ambiguous-path.json" '"ambiguous":true'
expect_contains "$tmp/ambiguous-path.json" '"candidates"'

# Source ranges are typed, normalized, and page-safe.
if "$bin" read src/query.zig:100-50 -C "$repo" --no-cache >"$tmp/bad-range.txt" 2>&1; then
    fail "descending source range unexpectedly succeeded"
fi
expect_contains "$tmp/bad-range.txt" "descending_range"

"$bin" read src/query.zig:1-3,2-4 -C "$repo" --no-cache -l 20 >"$tmp/merged-range.txt"
duplicates=$(awk -F '\t' '$1 ~ /^[0-9]+$/ { seen[$1] += 1 } END { d=0; for (n in seen) if (seen[n] > 1) d += 1; print d }' "$tmp/merged-range.txt")
[ "$duplicates" -eq 0 ] || fail "overlapping source ranges emitted duplicate lines"

"$bin" read src/query.zig -C "$repo" --no-cache -l 5 -j >"$tmp/read-page.json"
lines=$(grep -o '"line":' "$tmp/read-page.json" | wc -l | tr -d ' ')
[ "$lines" -le 5 ] || fail "whole-file source page emitted $lines lines for -l 5"
expect_contains "$tmp/read-page.json" '"truncated":true'
expect_contains "$tmp/read-page.json" '"next"'

"$bin" read src/query.zig -C "$repo" --no-cache -l 5 --after v1:5 -j >"$tmp/read-page-2.json"
expect_contains "$tmp/read-page-2.json" '"offset":5'

"$bin" read src/query.zig -C "$repo" --no-cache -l 200 --budget 1000 -j >"$tmp/read-budget.json"
read_bytes=$(wc -c <"$tmp/read-budget.json" | tr -d ' ')
[ "$read_bytes" -le 1000 ] || fail "read --budget 1000 emitted ${read_bytes}B"
expect_contains "$tmp/read-budget.json" '"truncated":true'

# The model-facing server surface is typed and read-only.
{
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"impact","view":"edit_sites","selector":"Expr.evaluate","max_bytes":4096}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"src/eval.rs","start_line":9999,"end_line":10008,"max_bytes":4096}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"map","limit":2,"max_bytes":4096}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"map","limit":2,"after":"v1:2","max_bytes":4096}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"diagnostics","view":"likely_local","limit":2,"max_bytes":4096}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"shutdown"}'
} | "$bin" serve -C "$repo/testenv/rust_cli" --no-cache >"$tmp/tools.json"
expect_contains "$tmp/tools.json" '"name":"navgraph.query"'
expect_contains "$tmp/tools.json" '"operation"'
expect_contains "$tmp/tools.json" '"exactness":"exact_sites_with_review_gaps"'
expect_contains "$tmp/tools.json" '"review_sites_present"'
expect_contains "$tmp/tools.json" '"exact":true,"editable":true'
expect_contains "$tmp/tools.json" '"code":"no_such_line"'
expect_not_contains "$tmp/tools.json" 'budget_too_small'
expect_contains "$tmp/tools.json" '"after":"v1:2"'
expect_contains "$tmp/tools.json" '"view":"likely_local"'

"$bin" capabilities >"$tmp/capabilities.json"
expect_contains "$tmp/capabilities.json" '"unsupported":["c","cpp","csharp","go"]'
expect_contains "$tmp/capabilities.json" 'use paths are not resolved'
zon_version=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$repo/build.zig.zon")
[ -n "$zon_version" ] || fail "could not read package version"
expect_contains "$tmp/capabilities.json" "\"version\":\"$zon_version\""

echo "agent-contract: all checks passed"
