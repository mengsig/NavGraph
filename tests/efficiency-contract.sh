#!/bin/sh
# Deterministic byte proxies for the context NavGraph replaces. These are not a
# substitute for paired model benchmarks; they stop accidental output/prompt
# bloat from erasing the large compression wins those benchmarks depend on.
set -eu

bin=$1
repo=$2
tmp=${TMPDIR:-/tmp}/navgraph-efficiency-contract.$$
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
    echo "efficiency-contract: $*" >&2
    exit 1
}

bytes() {
    wc -c <"$1" | tr -d ' '
}

assert_fraction() {
    compact=$1
    baseline=$2
    percent=$3
    label=$4
    compact_bytes=$(bytes "$compact")
    baseline_bytes=$(bytes "$baseline")
    [ $((compact_bytes * 100)) -le $((baseline_bytes * percent)) ] ||
        fail "$label grew to ${compact_bytes}B; expected <=${percent}% of ${baseline_bytes}B baseline"
}

"$bin" def readLines -C "$repo" --no-cache -v full >"$tmp/definition.txt"
grep -F 'pub fn readLines' "$tmp/definition.txt" >/dev/null || fail "definition view lost exact source"
assert_fraction "$tmp/definition.txt" "$repo/src/query.zig" 5 "symbol-scoped source"

"$bin" outline src/main.zig -C "$repo" --no-cache -k fn -v names -l 1000 >"$tmp/outline.txt"
grep -F 'fn rpcTools' "$tmp/outline.txt" >/dev/null || fail "outline lost server entry point"
assert_fraction "$tmp/outline.txt" "$repo/src/main.zig" 10 "file outline"

"$bin" neighbors readLines -C "$repo" --no-cache -v names -l 40 >"$tmp/neighbors.txt"
grep -F 'fn dispatch' "$tmp/neighbors.txt" >/dev/null || fail "neighbors lost dispatch caller"
neighbor_bytes=$(bytes "$tmp/neighbors.txt")
[ "$neighbor_bytes" -le 12000 ] || fail "neighbors view grew to ${neighbor_bytes}B"

"$bin" edits readLines -C "$repo" --no-cache -l 40 >"$tmp/edits.txt"
grep -F 'definition' "$tmp/edits.txt" >/dev/null || fail "edit view lost definition site"
edit_bytes=$(bytes "$tmp/edits.txt")
[ "$edit_bytes" -le 4000 ] || fail "edit-site receipt grew to ${edit_bytes}B"

# This guide is replayed by integrations that have not yet adopted lazy typed
# schemas. Keep detailed human documentation in README/capabilities, not here.
prompt_bytes=$(bytes "$repo/prompt.md")
[ "$prompt_bytes" -le 5000 ] || fail "agent guide regressed to ${prompt_bytes}B"

echo "efficiency-contract: def=$(bytes "$tmp/definition.txt")B outline=$(bytes "$tmp/outline.txt")B neighbors=${neighbor_bytes}B edits=${edit_bytes}B prompt=${prompt_bytes}B"
