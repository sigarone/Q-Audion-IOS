#!/usr/bin/env python3
"""Gate for the curated release notes (QAudionApp/Resources/ReleaseNotes/release-notes.json).

The notes are written by hand when a version is tagged: short, positive lines about what the
user gets. This check fails when an entry is malformed, misses one of the app languages, or
uses wording that does not belong in public release notes. Brand names are kept as SHA-256
hashes so this file does not spell them out.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
NOTES = ROOT / "QAudionApp" / "Resources" / "ReleaseNotes" / "release-notes.json"
LANGUAGES = ("it", "en", "de", "es", "fr", "pt-BR")
MAX_LINES = 4
MAX_CHARS = 140
VERSION_RE = re.compile(r"^1\.0\.\d+$")

# Wording that stays out of public notes (matched as lowercase fragments, in every app language).
DENY_FRAGMENTS = (
    "crash", "bug", "vulnerab", "exploit", "nonce", "key reuse", "cve", "mitm", "attack", "leak",
    "flaw", "weakness", "breach", "hack", "bypass", "replay", "fix", "patch", "regress",
    "attacco", "falla", "debolezza", "violazione", "correzione", "errore",
    "absturz", "angriff", "schwachstelle", "sicherheitslücke", "fehler",
    "ataque", "fallo", "fallo de", "vulnerabilidad", "error", "falha", "ataque",
    "faille", "attaque", "défaut", "plantage",
)
# Product and brand names, as SHA-256 of the lowercase word.
DENY_WORD_HASHES = frozenset({
    "ec8202b6f9fb16f9e26b66367afa4e037752f3c09a18cefab426165e06a424b1",
    "3f40462915a3e6026a4d790127b95ded4d870f6ab18d9af2fcbc454168255237",
    "570f73605251d439fd949a6619b0455be69444a60df592d84619b1f2424bdf6f",
    "7941501a4929547ea04e2a6adcc9deef9620375c0b738dc9ef888a0c1f71aed3",
    "998ba664f4d67e09c901f61f9c98d910130d53a8660beb19dbdd5bbc59f81ab2",
    "8c9101702979738baebb90074f98d217c4fb0219e80fdc99c530d79d833fe2b0",
    "5077841ff0064e122b403b261d0eacb077145b56beab5baab7035a098ceccf75",
    "7c2a0c2c84bcb97b9fb94c055b79001a532b4d5d4b1004c23a3951a83779440c",
    "2c38fed6649ab2bb30432d2c31fc0fe38ab38567f276158edefa983f94ec3e43",
    "e1ba4807a15d8579f79cfd90a07fc015e6125565c9271eb94aded0b2ebf86163",
    "b1799e6e18de8f6f7d073bff4c2d0d728b8578057b0cb36f3cbc3516396c003a",
    "050f993ea2322d4b6940f8560a253a11709fdc5ab08fd994bceb096846ea1645",
})


def line_problems(text):
    low = text.lower()
    out = [f"avoid '{f}'" for f in DENY_FRAGMENTS if f in low]
    for word in re.split(r"[^\w]+", low):
        if word and hashlib.sha256(word.encode()).hexdigest() in DENY_WORD_HASHES:
            out.append("product or brand name")
    return out


def violations(entries):
    problems = []
    if not isinstance(entries, list):
        return ["the file must hold a list of entries"]
    seen = set()
    for entry in entries:
        version = entry.get("version") if isinstance(entry, dict) else None
        if not isinstance(version, str) or not VERSION_RE.match(version):
            problems.append(f"bad version: {version!r}")
            continue
        if version in seen:
            problems.append(f"{version}: listed twice")
        seen.add(version)
        notes = entry.get("notes")
        if not isinstance(notes, dict):
            problems.append(f"{version}: notes missing")
            continue
        for lang in LANGUAGES:
            lines = notes.get(lang)
            if not isinstance(lines, list) or not lines:
                problems.append(f"{version}: no lines for {lang}")
                continue
            if len(lines) > MAX_LINES:
                problems.append(f"{version}/{lang}: more than {MAX_LINES} lines")
            for text in lines:
                if not isinstance(text, str) or not text.strip():
                    problems.append(f"{version}/{lang}: empty line")
                    continue
                if len(text) > MAX_CHARS:
                    problems.append(f"{version}/{lang}: line longer than {MAX_CHARS} characters")
                for p in line_problems(text):
                    problems.append(f"{version}/{lang}: {p}: {text}")
        for lang in notes:
            if lang not in LANGUAGES:
                problems.append(f"{version}: unknown language {lang}")
    return problems


def main():
    entries = json.loads(NOTES.read_text(encoding="utf-8"))
    problems = violations(entries)
    for p in problems:
        print("release notes:", p, file=sys.stderr)
    if problems:
        return 1
    print(f"release notes ok ({len(entries)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
