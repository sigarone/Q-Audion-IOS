#!/usr/bin/env python3
"""
gen_changelog.py -- generate the in-app changelog data from real git tag
history and write it as Swift source (WhatsNewData.generated.swift).

WHY: the "Cosa c'e di nuovo" screen (WhatsNewScreen.swift) used to be
100% hand-maintained (WhatsNewData.swift, one ReleaseNote per curated
milestone). This script derives the SAME ReleaseNote shape from the
repo's actual `v*` tags + the real commit subjects between adjacent
tags -- no fabricated text, no manual curation required at release time.

SOURCE OF TRUTH: `git tag --sort=-version:refname` matching `v*`
(the pattern ios-release.ps1 already creates: `v$Version`, e.g.
"v1.0.732"). For each of the most recent N tags (default 20):
  - date  = the tag's commit date (ISO, YYYY-MM-DD)
  - changes = `git log <prevTag>..<tag> --no-merges --pretty=%s`,
    with the mechanical "chore: bump version to X" bump commit (which
    ios-release.ps1 creates on every single release) filtered out.
    Everything else is kept VERBATIM -- these are already descriptive
    Conventional Commits subjects (feat(scope): ..., fix(scope): ...).
    No rewriting, no summarizing, no fabrication.

If a tag's commit range has ZERO subjects left after filtering (e.g. a
version bump with nothing else), the tag is skipped entirely -- an
empty changelog entry would be noise, not information.

OUTPUT: QAudionApp/Views/Settings/WhatsNewData.generated.swift --
a `ReleaseNote.generatedReleaseNotes: [ReleaseNote]` array, picked up
automatically by XcodeGen (QAudionApp/project.yml globs `path: .` for
sources, so any tracked .swift file under QAudionApp/ is compiled in
without any project.yml edit). This file is regenerated (overwritten)
every release -- see ios-release.ps1, which calls this script after
the version tag is created and before the tag+HEAD are pushed, so the
generated file rides along in the SAME push as the release.

Usage:
  python scripts/gen_changelog.py                  # writes the .swift file
  python scripts/gen_changelog.py --limit 20        # (default) last 20 tags
  python scripts/gen_changelog.py --dry-run         # print, don't write
  python scripts/gen_changelog.py --tag-pattern 'v*'

No network access. No external LLM. Pure `git log` parsing.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPO_ROOT / "QAudionApp" / "Views" / "Settings" / "WhatsNewData.generated.swift"

# Matches the mechanical per-release bump commit ios-release.ps1 always
# creates ("chore: bump version to 1.0.732"). Filtered out as pure noise --
# it carries no information beyond the version number, which is already
# the entry's `id`.
BUMP_COMMIT_RE = re.compile(r"^chore:\s*bump version to\s+[\d.]+\s*$", re.IGNORECASE)


def run_git(args):
    # NOTE: do NOT use subprocess' text=True here. On Windows it decodes
    # stdout with locale.getpreferredencoding() (commonly cp1252/mbcs),
    # not UTF-8 -- commit subjects containing em-dashes ("—") or section
    # signs ("§") get mojibaked (e.g. "—" -> "â€""). git itself always
    # emits UTF-8 on this repo (core.quotepath/commit encoding default).
    # Capture raw bytes and decode explicitly as UTF-8 instead. Same class
    # of bug as the W472-fix note in ios-release.ps1.
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT)] + args,
        capture_output=True, check=True,
    )
    return result.stdout.decode("utf-8")


def get_tags(pattern):
    """Tags matching `pattern`, newest first (by version sort, matches
    ios-release.ps1's own `--sort=-version:refname` convention)."""
    out = run_git(["tag", "--sort=-version:refname", "-l", pattern])
    return [t for t in out.splitlines() if t.strip()]


def tag_date(tag):
    """ISO short date (YYYY-MM-DD) of the commit the tag points at."""
    out = run_git(["log", "-1", "--format=%ad", "--date=short", tag])
    return out.strip()


def swift_string_literal(s):
    """Escape a Python string for embedding as a Swift string literal."""
    escaped = (
        s.replace("\\", "\\\\")
         .replace("\"", "\\\"")
    )
    return escaped


def build_entries(tags, limit):
    """For each tag (newest first), collect the filtered commit-subject
    list between it and the previous (older) tag. Skips tags that end up
    with zero substantive commits."""
    entries = []
    for i, tag in enumerate(tags):
        if len(entries) >= limit:
            break
        prev_tag = tags[i + 1] if i + 1 < len(tags) else None
        commit_range = f"{prev_tag}..{tag}" if prev_tag else tag
        out = run_git(["log", commit_range, "--no-merges", "--pretty=%s"])
        subjects = [s.strip() for s in out.splitlines() if s.strip()]
        changes = [s for s in subjects if not BUMP_COMMIT_RE.match(s)]
        if not changes:
            continue
        entries.append({
            "version": tag,
            "date": tag_date(tag),
            "changes": changes,
        })
    return entries


def render_swift(entries):
    lines = []
    lines.append("// AUTO-GENERATED by scripts/gen_changelog.py -- DO NOT EDIT BY HAND.")
    lines.append("// Regenerated on every release (see ios-release.ps1). Source of truth:")
    lines.append("// real `git log` between adjacent version tags in THIS repo. See the")
    lines.append("// header of gen_changelog.py for the exact derivation rule.")
    lines.append("import Foundation")
    lines.append("")
    lines.append("extension ReleaseNote {")
    lines.append("    /// Auto-generated changelog entries, newest-first, derived from real")
    lines.append("    /// git tag/commit history. Complements (does not replace) the")
    lines.append("    /// hand-curated `releaseNotes` in WhatsNewData.swift.")
    lines.append("    public static let generatedReleaseNotes: [ReleaseNote] = [")
    for e in entries:
        lines.append(f'        .init(id: "{swift_string_literal(e["version"])}",')
        lines.append(f'              date: "{swift_string_literal(e["date"])}",')
        lines.append(f'              title: "{swift_string_literal(e["version"])}",')
        lines.append("              bullets: [")
        for c in e["changes"]:
            lines.append(f'                "{swift_string_literal(c)}",')
        lines.append("              ]),")
    lines.append("    ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, default=20, help="max number of tags/entries to emit (default 20)")
    parser.add_argument("--tag-pattern", default="v*", help="git tag glob pattern (default 'v*', matches ios-release.ps1)")
    parser.add_argument("--dry-run", action="store_true", help="print the generated Swift to stdout, do not write the file")
    parser.add_argument("--output", default=str(OUTPUT_PATH), help="output .swift path")
    args = parser.parse_args()

    try:
        tags = get_tags(args.tag_pattern)
    except subprocess.CalledProcessError as e:
        print(f"error: git tag listing failed: {e.stderr}", file=sys.stderr)
        return 1

    if not tags:
        print(f"warning: no tags matched pattern '{args.tag_pattern}' -- writing empty changelog", file=sys.stderr)

    entries = build_entries(tags, args.limit)
    swift_src = render_swift(entries)

    if args.dry_run:
        print(swift_src)
        print(f"\n// {len(entries)} entries (from {len(tags)} tags matching '{args.tag_pattern}')", file=sys.stderr)
        return 0

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # Explicit UTF-8, no BOM (default for encoding="utf-8" in Python) --
    # matches every other .swift file in this repo.
    out_path.write_text(swift_src, encoding="utf-8", newline="\n")
    print(f"[gen_changelog] wrote {len(entries)} entries to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
