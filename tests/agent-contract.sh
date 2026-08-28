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
server_pid=

cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

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

wait_for_literal() {
    file=$1
    literal=$2
    attempts=0
    while ! grep -F -- "$literal" "$file" >/dev/null 2>&1; do
        if [ -n "$server_pid" ] && ! kill -0 "$server_pid" 2>/dev/null; then
            fail "server exited while waiting for '$literal'"
        fi
        attempts=$((attempts + 1))
        [ "$attempts" -lt 500 ] || fail "timed out waiting for '$literal'"
        sleep 0.01
    done
}

expect_metadata_broken_pipe() {
    label=$1
    shift
    status_file="$tmp/broken-pipe-$label.status"
    stderr_file="$tmp/broken-pipe-$label.err"
    {
        if "$bin" "$@"; then
            producer_status=0
        else
            producer_status=$?
        fi
        printf '%s\n' "$producer_status" >"$status_file"
    } 2>"$stderr_file" | head -c 1 >/dev/null
    [ -f "$status_file" ] || fail "$label pipe producer did not record its status"
    producer_status=$(cat "$status_file")
    case "$producer_status" in
        0|141) ;;
        *) fail "$label pipe producer exited $producer_status instead of cleanly or with conventional SIGPIPE 141" ;;
    esac
    [ ! -s "$stderr_file" ] || fail "$label pipe leaked an internal write error"

    # A small help payload can fit in the pipe before `head` closes, making 0 a
    # legitimate race outcome. A pre-closed output descriptor deterministically
    # exercises the same writer failure path and must use 141 without noise.
    closed_stderr="$tmp/closed-output-$label.err"
    if "$bin" "$@" 1>&- 2>"$closed_stderr"; then
        closed_status=0
    else
        closed_status=$?
    fi
    [ "$closed_status" -eq 141 ] || fail "$label closed-output producer did not use conventional exit 141"
    [ ! -s "$closed_stderr" ] || fail "$label closed output leaked an internal write error"
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
expect_metadata_broken_pipe help help
expect_metadata_broken_pipe capabilities capabilities

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
if "$bin" read src/query.zig:100-50 -C "$repo" >"$tmp/bad-range.txt" 2>&1; then
    fail "descending source range unexpectedly succeeded"
fi
expect_contains "$tmp/bad-range.txt" "descending_range"

"$bin" read src/query.zig:1-3,2-4 -C "$repo" -l 20 >"$tmp/merged-range.txt"
duplicates=$(awk -F '\t' '$1 ~ /^[0-9]+$/ { seen[$1] += 1 } END { d=0; for (n in seen) if (seen[n] > 1) d += 1; print d }' "$tmp/merged-range.txt")
[ "$duplicates" -eq 0 ] || fail "overlapping source ranges emitted duplicate lines"

"$bin" read src/query.zig -C "$repo" -l 5 -j >"$tmp/read-page.json"
lines=$(grep -o '"line":' "$tmp/read-page.json" | wc -l | tr -d ' ')
[ "$lines" -le 5 ] || fail "whole-file source page emitted $lines lines for -l 5"
expect_contains "$tmp/read-page.json" '"truncated":true'
expect_contains "$tmp/read-page.json" '"next"'

"$bin" read src/query.zig -C "$repo" -l 5 --after v1:5 -j >"$tmp/read-page-2.json"
expect_contains "$tmp/read-page-2.json" '"offset":5'

"$bin" read src/query.zig -C "$repo" -l 200 --budget 1000 -j >"$tmp/read-budget.json"
read_bytes=$(wc -c <"$tmp/read-budget.json" | tr -d ' ')
[ "$read_bytes" -le 1000 ] || fail "read --budget 1000 emitted ${read_bytes}B"
expect_contains "$tmp/read-budget.json" '"truncated":true'

# Source reads are an authority boundary, not a generic filesystem primitive.
# Exercise one-shot, legacy MCP, and the typed facade against absolute, parent,
# and symlink escapes while retaining ordinary non-indexed/config reads.
mkdir -p "$tmp/authority-root/ignored"
printf '%s\n' 'pub fn inside() void {}' >"$tmp/authority-root/app.zig"
printf '%s\n' 'safe-config=true' >"$tmp/authority-root/ignored/config.txt"
printf '%s\n' 'NAVGRAPH_ESCAPE_SENTINEL' >"$tmp/outside-secret.txt"
ln -s ../outside-secret.txt "$tmp/authority-root/outside-link"

"$bin" read ignored/config.txt -C "$tmp/authority-root" -j >"$tmp/contained-config.json"
expect_contains "$tmp/contained-config.json" 'safe-config=true'
[ ! -e "$tmp/authority-root/.navgraph" ] || fail "standalone read created an index/cache despite cacheEffect=none"

# Index construction uses the same authority boundary. An explicitly-scoped
# source symlink must not smuggle outside bytes into the in-memory graph (which
# source queries could otherwise return without touching disk again).
printf '%s\n' 'pub fn NAVGRAPH_OUTSIDE_INDEX_SENTINEL() void {}' >"$tmp/outside-index.zig"
ln -s ../outside-index.zig "$tmp/authority-root/outside-source.zig"
if "$bin" outline -C "$tmp/authority-root/outside-source.zig" --no-cache -j >"$tmp/outside-index.json" 2>"$tmp/outside-index.err"; then
    :
else
    outside_index_status=$?
    [ "$outside_index_status" -eq 1 ] || fail "contained index rejection exited $outside_index_status"
fi
expect_not_contains "$tmp/outside-index.json" 'NAVGRAPH_OUTSIDE_INDEX_SENTINEL'

# Cache I/O is also workspace-scoped: a repository-controlled `.navgraph`
# symlink must neither be read nor followed for writes.
mkdir -p "$tmp/cache-root" "$tmp/cache-outside"
printf '%s\n' 'pub fn cache_safe() void {}' >"$tmp/cache-root/app.zig"
ln -s ../cache-outside "$tmp/cache-root/.navgraph"
"$bin" outline -C "$tmp/cache-root" -j >"$tmp/cache-symlink.json" 2>"$tmp/cache-symlink.err"
expect_contains "$tmp/cache-symlink.json" 'cache_safe'
[ ! -e "$tmp/cache-outside/cache" ] || fail "cache write escaped through a .navgraph symlink"

for escape in /etc/passwd ../outside-secret.txt outside-link; do
    safe_name=$(printf '%s' "$escape" | tr '/.' '__')
    if "$bin" read "$escape" -C "$tmp/authority-root" -j >"$tmp/escape-$safe_name.json" 2>"$tmp/escape-$safe_name.err"; then
        fail "one-shot read escaped root via $escape"
    fi
    expect_contains "$tmp/escape-$safe_name.json" '"error":"path_outside_root"'
    expect_not_contains "$tmp/escape-$safe_name.json" 'NAVGRAPH_ESCAPE_SENTINEL'
    expect_not_contains "$tmp/escape-$safe_name.json" 'root:x:'
done

{
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"navgraph","arguments":{"args":["read","/etc/passwd","-j"]}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"navgraph","arguments":{"args":["read","../outside-secret.txt","-j"]}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"navgraph","arguments":{"args":["read","outside-link","-j"]}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"/etc/passwd"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"../outside-secret.txt"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"outside-link"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"navgraph","arguments":{"args":["read","ignored/config.txt","-j"]}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"ignored/config.txt"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"shutdown"}'
} | "$bin" serve -C "$tmp/authority-root" --no-cache >"$tmp/mcp-root-containment.jsonl"
expect_contains "$tmp/mcp-root-containment.jsonl" 'path_outside_root'
expect_contains "$tmp/mcp-root-containment.jsonl" 'source path must be relative to and remain beneath the repository root'
expect_not_contains "$tmp/mcp-root-containment.jsonl" 'NAVGRAPH_ESCAPE_SENTINEL'
expect_not_contains "$tmp/mcp-root-containment.jsonl" 'root:x:'
[ "$(grep -c 'path_outside_root' "$tmp/mcp-root-containment.jsonl")" -eq 4 ] || fail "legacy/symlink MCP escape rejection count drifted"
[ "$(grep -c '"code":-32602' "$tmp/mcp-root-containment.jsonl")" -eq 2 ] || fail "typed lexical escapes were not rejected during decode"
[ "$(grep -c 'safe-config=true' "$tmp/mcp-root-containment.jsonl")" -eq 2 ] || fail "contained ignored/config MCP reads did not survive authority hardening"

# A long-lived server binds the directory authority opened at startup, not the
# mutable spelling supplied to -C. Retarget that spelling, update the original
# directory, reload, and prove graph plus source reads stay on the bound root.
mkdir -p "$tmp/session-root-a/ignored" "$tmp/session-root-b/ignored"
printf '%s\n' 'pub fn authority_a_initial() void {}' >"$tmp/session-root-a/app.zig"
printf '%s\n' 'ROOT_A_INITIAL' >"$tmp/session-root-a/ignored/config.txt"
printf '%s\n' 'pub fn authority_b_secret() void {}' >"$tmp/session-root-b/app.zig"
printf '%s\n' 'ROOT_B_SOURCE_SENTINEL' >"$tmp/session-root-b/ignored/config.txt"
ln -s "$tmp/session-root-a" "$tmp/session-root-link"
mkfifo "$tmp/session-input"
"$bin" serve -C "$tmp/session-root-link" --no-cache <"$tmp/session-input" >"$tmp/session-output.jsonl" 2>"$tmp/session-stderr.txt" &
server_pid=$!
exec 3>"$tmp/session-input"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"ignored/config.txt"}}}' >&3
wait_for_literal "$tmp/session-output.jsonl" '"id":1'
expect_contains "$tmp/session-output.jsonl" 'ROOT_A_INITIAL'

rm "$tmp/session-root-link"
ln -s "$tmp/session-root-b" "$tmp/session-root-link"
printf '%s\n' 'pub fn authority_a_reloaded() void {}' >"$tmp/session-root-a/app.zig"
printf '%s\n' 'ROOT_A_AFTER_RELOAD' >"$tmp/session-root-a/ignored/config.txt"
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"navgraph.reload","arguments":{"noCache":true}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"map","query":"authority_a_reloaded","limit":5}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"map","query":"authority_b_secret","limit":5}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"ignored/config.txt"}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"navgraph","arguments":{"args":["read","ignored/config.txt","-j"]}}}' >&3
wait_for_literal "$tmp/session-output.jsonl" '"id":6'

# Renaming the bound directory must not stale an absolute canonical pathname.
# The retained descriptor remains the authority, and both reload plus live
# filesystem reads/status must derive its current location from that handle.
mv "$tmp/session-root-a" "$tmp/session-root-a-renamed"
printf '%s\n' 'pub fn authority_a_after_rename() void {}' >"$tmp/session-root-a-renamed/app.zig"
printf '%s\n' 'ROOT_A_AFTER_RENAME' >"$tmp/session-root-a-renamed/ignored/config.txt"
printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"navgraph.reload","arguments":{"noCache":true}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"map","query":"authority_a_after_rename","limit":5}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"ignored/config.txt"}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"navgraph","arguments":{"args":["read","ignored/config.txt","-j"]}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"navgraph","arguments":{"args":["status","-j"]}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":12,"method":"shutdown"}' >&3
exec 3>&-
wait "$server_pid"
server_pid=
expect_contains "$tmp/session-output.jsonl" 'authority_a_reloaded'
grep -F -- '"id":4' "$tmp/session-output.jsonl" >"$tmp/session-id4.json"
expect_contains "$tmp/session-id4.json" '"items":[]'
[ "$(grep -c 'ROOT_A_AFTER_RELOAD' "$tmp/session-output.jsonl")" -eq 2 ] || fail "bound typed/legacy source reads drifted after reload"
expect_contains "$tmp/session-output.jsonl" 'authority_a_after_rename'
[ "$(grep -c 'ROOT_A_AFTER_RENAME' "$tmp/session-output.jsonl")" -eq 2 ] || fail "bound typed/legacy source reads failed after directory rename"
grep -F -- '"id":11' "$tmp/session-output.jsonl" >"$tmp/session-id11.json"
expect_not_contains "$tmp/session-id11.json" 'OutsideRoot'
expect_not_contains "$tmp/session-id11.json" 'unavailable'
expect_not_contains "$tmp/session-output.jsonl" 'ROOT_B_SOURCE_SENTINEL'
[ ! -s "$tmp/session-stderr.txt" ] || fail "root-retarget server emitted unexpected stderr"

# A single-file server binds the exact startup target, not merely its parent
# directory and basename. Retargeting an in-root symlink must make reload fail
# atomically and leave the prior safe snapshot available.
mkdir -p "$tmp/single-root"
printf '%s\n' '// SINGLE_SAFE_SOURCE' 'pub fn single_safe_symbol() void {}' >"$tmp/single-root/safe.zig"
printf '%s\n' '// SINGLE_SECRET_SOURCE' 'pub fn single_secret_symbol() void {}' >"$tmp/single-root/secret.zig"
ln -s safe.zig "$tmp/single-root/entry.zig"
mkfifo "$tmp/single-input"
"$bin" serve -C "$tmp/single-root/entry.zig" --no-cache <"$tmp/single-input" >"$tmp/single-output.jsonl" 2>"$tmp/single-stderr.txt" &
server_pid=$!
exec 3>"$tmp/single-input"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"map","query":"single_safe_symbol","limit":5}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"entry.zig"}}}' >&3
wait_for_literal "$tmp/single-output.jsonl" '"id":2'
expect_contains "$tmp/single-output.jsonl" 'single_safe_symbol'
expect_contains "$tmp/single-output.jsonl" 'SINGLE_SAFE_SOURCE'

rm "$tmp/single-root/entry.zig"
ln -s secret.zig "$tmp/single-root/entry.zig"
printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"navgraph.reload","arguments":{"noCache":true}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"map","query":"single_safe_symbol","limit":5}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"map","query":"single_secret_symbol","limit":5}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"navgraph.query","arguments":{"operation":"source","path":"entry.zig"}}}' >&3
printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"shutdown"}' >&3
exec 3>&-
wait "$server_pid"
server_pid=
grep -F -- '"id":3' "$tmp/single-output.jsonl" >"$tmp/single-id3.json"
expect_contains "$tmp/single-id3.json" '"error":{"code":-32603'
expect_contains "$tmp/single-id3.json" 'OutsideRoot'
grep -F -- '"id":4' "$tmp/single-output.jsonl" >"$tmp/single-id4.json"
expect_contains "$tmp/single-id4.json" 'single_safe_symbol'
grep -F -- '"id":5' "$tmp/single-output.jsonl" >"$tmp/single-id5.json"
expect_contains "$tmp/single-id5.json" '"items":[]'
[ "$(grep -c 'SINGLE_SAFE_SOURCE' "$tmp/single-output.jsonl")" -eq 2 ] || fail "failed single-file reload did not preserve the safe snapshot"
expect_not_contains "$tmp/single-output.jsonl" 'SINGLE_SECRET_SOURCE'
[ ! -s "$tmp/single-stderr.txt" ] || fail "single-file retarget server emitted unexpected stderr"

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
