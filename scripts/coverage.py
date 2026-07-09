#!/usr/bin/env python3
"""
NavGraph test-coverage estimator (call-graph reachability).

Zig 0.16 emits DWARF5 line programs that kcov 43 cannot parse (even a trivial
`zig test` binary reports 0 lines), so there is no working line-coverage tool
for this codebase. This script measures a conservative proxy instead, using
NavGraph itself (dogfooding):

  A function/method in src/ is "covered" if it is reachable, through NavGraph's
  resolved call graph, from a symbol that is directly exercised by a `test`
  block. Seeds = every fn/method whose name is referenced inside a `test { ... }`
  body. The covered set is the transitive callee-closure of those seeds.

Because NavGraph does not index `test` blocks as symbols and only follows edges
it can resolve, this UNDERCOUNTS: real line coverage is >= the number reported.

Usage:  scripts/coverage.py [--list] [--json]
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
NG = "navgraph"


def ng_json(args):
    out = subprocess.run([NG, *args, "-j"], cwd=ROOT, capture_output=True, text=True)
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def all_symbols():
    """id -> symbol dict, for every symbol under src/."""
    data = ng_json(["outline", "src"]) or []
    syms = {}
    for f in data:
        for s in f.get("symbols", []):
            syms[s["id"]] = s
    return syms


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def test_block_identifiers():
    """Set of identifiers appearing inside any `test \"...\" { ... }` body in src/."""
    idents = set()
    for path in SRC.rglob("*.zig"):
        text = path.read_text(encoding="utf-8", errors="replace")
        i = 0
        n = len(text)
        while True:
            m = re.search(r'(^|\n)\s*test\b[^\{]*\{', text[i:])
            if not m:
                break
            start = i + m.end() - 1  # index of the opening brace
            depth = 0
            j = start
            while j < n:
                c = text[j]
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            body = text[start + 1 : j]
            idents.update(IDENT.findall(body))
            i = j + 1
    return idents


def collect_ids(node, acc):
    if isinstance(node, dict):
        if "id" in node:
            acc.add(node["id"])
        for child in node.get("callees", []):
            collect_ids(child, acc)


def main():
    syms = all_symbols()
    by_name = {}
    for s in syms.values():
        by_name.setdefault(s["name"], []).append(s)

    testable = {sid: s for sid, s in syms.items() if s["kind"] in ("fn", "method")}
    tident = test_block_identifiers()

    # Seeds: fn/method symbols whose name is referenced in a test body.
    seeds = [s for s in syms.values() if s["name"] in tident and s["kind"] in ("fn", "method")]

    covered = set()
    for s in seeds:
        if s["id"] in covered:
            continue
        tree = ng_json(["calls", f'{s["name"]}@{s["file"]}', "-d", "40"]) or []
        acc = set()
        for root in tree:
            collect_ids(root, acc)
        covered |= acc
    covered |= {s["id"] for s in seeds}

    covered_testable = {sid for sid in testable if sid in covered}
    uncovered = sorted(
        (testable[sid] for sid in testable if sid not in covered),
        key=lambda s: (s["file"], s["line"]),
    )

    total = len(testable)
    pct = 100.0 * len(covered_testable) / total if total else 100.0

    if "--json" in sys.argv:
        print(json.dumps({
            "covered": len(covered_testable),
            "total": total,
            "percent": round(pct, 2),
            "uncovered": [{"name": s["name"], "file": s["file"], "line": s["line"]} for s in uncovered],
        }, indent=2))
        return

    print("=" * 60)
    print(f" NavGraph fn/method test-reachability: {len(covered_testable)}/{total} = {pct:.2f}%")
    print(" (conservative: real line coverage is >= this)")
    print("=" * 60)
    if "--list" in sys.argv and uncovered:
        print(f" {len(uncovered)} unreached fn/method (target for new tests):")
        for s in uncovered:
            print(f"   {s['file']}:{s['line']}  {s['name']}")


if __name__ == "__main__":
    main()
