#!/usr/bin/env python3
"""Build the in-app "What's new" data.

Inputs: the version tags (v1.0.NNNN) for the list of releases and their dates, and the
curated, hand-written notes in QAudionApp/Resources/ReleaseNotes/release-notes.json.
A release without a curated entry gets a neutral generic line. Commit and pull request
titles are never used. Output: QAudionApp/Resources/changelog.json, newest first, at most
MAX_ENTRIES releases. The notes file is checked first (scripts/ci/check_release_notes.py).

Usage:
    python3 scripts/gen_ios_changelog.py
"""
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "QAudionApp" / "Resources" / "changelog.json"
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
MAX_ENTRIES = 20

GENERIC = {
    "it": ["Miglioramenti di qualità e affidabilità"],
    "en": ["Quality and reliability improvements"],
    "de": ["Verbesserungen bei Qualität und Zuverlässigkeit"],
    "es": ["Mejoras de calidad y fiabilidad"],
    "fr": ["Améliorations de la qualité et de la fiabilité"],
    "pt-BR": ["Melhorias de qualidade e confiabilidade"],
}


def load_gate():
    path = ROOT / "scripts" / "ci" / "check_release_notes.py"
    spec = importlib.util.spec_from_file_location("check_release_notes", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def git(*args):
    out = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, check=True).stdout
    return out.decode("utf-8", errors="replace")


def version_tags():
    tags = []
    for line in git("tag", "--list").splitlines():
        m = TAG_RE.match(line.strip())
        if m:
            tags.append((tuple(int(g) for g in m.groups()), line.strip()))
    tags.sort()
    return [t for _, t in tags]


def main():
    gate = load_gate()
    curated = json.loads(gate.NOTES.read_text(encoding="utf-8"))
    problems = gate.violations(curated)
    if problems:
        for p in problems:
            print("release notes:", p, file=sys.stderr)
        return 1
    by_version = {e["version"]: e["notes"] for e in curated}
    entries = []
    for tag in reversed(version_tags()[-MAX_ENTRIES:]):
        version = tag[1:]
        date = git("log", "-1", "--format=%aI", tag).strip()[:10]
        entries.append({"version": version, "date": date, "notes": by_version.get(version, GENERIC)})
    if not entries:
        print("no version tags found", file=sys.stderr)
        return 1
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(entries, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {len(entries)} releases to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
