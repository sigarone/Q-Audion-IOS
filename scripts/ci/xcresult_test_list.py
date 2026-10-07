#!/usr/bin/env python3
"""Print every test case an .xcresult bundle executed, one per line: RESULT<TAB>Suite/test.

CI diagnostic, never fails the job. A test that is skipped (XCTSkip) shows as Skipped and a test that never ran does
not show at all, which is exactly what a "the wiring invariants are in the green run" proof needs: the run log of
`xcodebuild test` does not list the cases by name.

usage: xcresult_test_list.py BUNDLE.xcresult [OUT.txt] [SUITE_FILTER ...]
  OUT.txt        also write the full list there (an artifact)
  SUITE_FILTER   suite names whose lines are echoed in a short summary at the end
"""
import json
import subprocess
import sys


def main() -> int:
    bundle = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else None
    filters = sys.argv[3:]
    proc = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle, "--compact"],
        capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        print(f"xcresulttool failed (exit {proc.returncode}): {proc.stderr.strip()[:500]}")
        return 0
    try:
        doc = json.loads(proc.stdout)
    except ValueError as exc:
        print(f"xcresulttool output is not JSON: {exc}")
        return 0

    rows = []

    def walk(node, suites):
        kind = node.get("nodeType", "")
        name = node.get("name", "")
        if kind == "Test Case":
            rows.append((node.get("result", "?"), "/".join(suites + [name])))
        nxt = suites + [name] if kind == "Test Suite" else suites
        for child in node.get("children", []) or []:
            walk(child, nxt)

    for top in doc.get("testNodes", []) or []:
        walk(top, [])

    rows.sort(key=lambda r: r[1])
    lines = [f"{result}\t{name}" for result, name in rows]
    counts = {}
    for result, _ in rows:
        counts[result] = counts.get(result, 0) + 1

    print(f"{bundle}: {len(rows)} test cases, " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if out_path:
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
    for flt in filters:
        matched = [ln for ln in lines if f"/{flt}/" in ln or ln.split("\t", 1)[1].startswith(flt + "/")]
        print(f"--- {flt}: {len(matched)} cases")
        for ln in matched:
            print(ln)
    return 0


if __name__ == "__main__":
    sys.exit(main())
