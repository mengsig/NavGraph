#!/usr/bin/env bash
#
# Measure NavGraph's own test-line coverage over src/ using kcov.
#
# Requires: zig 0.16, kcov (`sudo pacman -S kcov`, or build from source into
# ~/.local). Builds the two Debug test binaries (`mod-tests` = the library/root
# module, `exe-tests` = the CLI/main module), runs each under kcov filtered to
# src/, merges the two runs, and prints the combined line-coverage percentage.
#
# Usage:  ./scripts/coverage.sh            # print summary + write HTML report
#         ./scripts/coverage.sh --quiet    # print only the percentage
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KCOV="${KCOV:-kcov}"
if ! command -v "$KCOV" >/dev/null 2>&1; then
    if [ -x "$HOME/.local/bin/kcov" ]; then
        KCOV="$HOME/.local/bin/kcov"
    else
        echo "coverage: kcov not found. Install with 'sudo pacman -S kcov' or build it into ~/.local." >&2
        exit 1
    fi
fi

OUT="$ROOT/coverage-out"
rm -rf "$OUT"
mkdir -p "$OUT"

# Emit the test executables to zig-out/bin without running them.
zig build test-bin >/dev/null

INCLUDE="--include-path=$ROOT/src"

run_kcov() {
    # $1 = label, $2 = binary path
    "$KCOV" $INCLUDE --clean "$OUT/$1" "$2" >/dev/null 2>&1 || {
        # A nonzero test exit still yields coverage data; only bail if no data.
        [ -d "$OUT/$1" ] || { echo "coverage: kcov failed on $2" >&2; exit 1; }
    }
}

run_kcov mod zig-out/bin/mod-tests
run_kcov exe zig-out/bin/exe-tests

"$KCOV" --merge "$OUT/merged" "$OUT/mod" "$OUT/exe" >/dev/null 2>&1

SUMMARY="$OUT/merged/kcov-merged/coverage.json"
if [ ! -f "$SUMMARY" ]; then
    # Fall back to a per-binary summary if the merge layout differs.
    SUMMARY="$(find "$OUT" -name coverage.json | head -1)"
fi

PCT="$(grep -o '"percent_covered"[^,]*' "$SUMMARY" | head -1 | grep -oE '[0-9.]+')"

if [ "${1:-}" = "--quiet" ]; then
    echo "$PCT"
else
    echo "=================================================="
    echo " NavGraph src/ line coverage: ${PCT}%"
    echo " HTML report: $OUT/merged/index.html"
    echo "=================================================="
    # Per-file breakdown, worst-covered first.
    python3 - "$SUMMARY" <<'PY' 2>/dev/null || true
import json, sys, os
data = json.load(open(sys.argv[1]))
rows = []
for f in data.get("files", []):
    pct = f.get("percent_covered", "0")
    rows.append((float(pct), f.get("file", "?")))
rows.sort()
print(" Per-file (lowest first):")
for pct, path in rows:
    print(f"   {pct:6.2f}%  {os.path.relpath(path)}")
PY
fi
