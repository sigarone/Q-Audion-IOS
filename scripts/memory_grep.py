#!/usr/bin/env python3
"""
memory_grep.py -- given a crash/symptom string, return the top-K most relevant
past-incident entries from the local memory corpus.

100% LOCAL. NO network. NO LLM. NO SSH. Pure keyword/token-overlap scoring over
the on-disk memory Markdown files. Safe to run anywhere; reads only, writes
nothing.

Corpus (read-only):
  - Index:  .../memory/MEMORY.md
  - Plus every *.md in that same memory/ directory (the per-incident files the
    index links to).

The memory dir is resolved in this order:
  1. --memory-dir <path>
  2. env QAUDION_MEMORY_DIR
  3. the known BCRYPTO project memory dir:
     <home>/.claude/projects/D--users-f10379a-DEV-APP-BCRYPTO/memory

Scoring (deterministic, explainable):
  - Tokenize query and each candidate unit into lowercase alnum tokens (>=2 ch).
  - A "unit" is one bullet/paragraph block; MEMORY.md is split on its '- [..]'
    index bullets, per-incident files on blank lines.
  - Score = sum over distinct query tokens of:
        idf(token) * (term-overlap-count in unit)
    where idf = log((N+1)/(df+1)) + 1 over the unit corpus, so rare technical
    tokens (e.g. 'no_peer_media', 'unseal', 'sigtrap') outweigh common words.
  - Small bonus for an exact substring hit of the whole (normalized) query.
  - Filename tokens count too (a hit in 'project_ios_ios_call_crash.md' helps).

Usage:
  python scripts/memory_grep.py "callee crash duplicate device-key SIGTRAP"
  python scripts/memory_grep.py "half_open no_peer_media android relay" -k 3
  python scripts/memory_grep.py "video one side purple transceiver" --full
  python scripts/memory_grep.py "ICE never converged" --memory-dir /path/to/memory

Options:
  query           One or more words describing the crash/symptom (required).
  -k / --top-k    Number of incidents to return (default 5).
  --full          Print the full matched unit text (default: a trimmed snippet).
  --memory-dir    Override the memory directory.
  --min-score     Drop results below this score (default 0.0 = keep all top-K).
"""

import os
import re
import sys
import math
import argparse
from pathlib import Path


def _ascii(s):
    """Force ASCII so output is safe on any console codepage (cp1252 etc).
    The memory corpus contains unicode (arrows, ellipsis, accents); replace
    the unrepresentable bytes rather than crash."""
    return s.encode("ascii", "replace").decode("ascii")


def out(line=""):
    print(_ascii(line))


TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9_./-]*", re.IGNORECASE)

# Common English/markdown stop tokens that carry no diagnostic signal. Kept
# small so technical terms survive.
STOP = {
    "the", "and", "for", "with", "this", "that", "from", "was", "were", "are",
    "but", "not", "via", "per", "see", "use", "used", "uses", "out", "into",
    "all", "any", "its", "it's", "has", "had", "have", "than", "then", "when",
    "what", "why", "how", "who", "you", "your", "our", "one", "two", "new",
    "old", "now", "yes", "non", "che", "del", "una", "uno", "gia", "anche",
    "md", "http", "https", "com",
}


def tokenize(text):
    toks = []
    for m in TOKEN_RE.finditer(text.lower()):
        t = m.group(0)
        if len(t) < 2:
            continue
        if t in STOP:
            continue
        toks.append(t)
    return toks


def resolve_memory_dir(cli_dir):
    if cli_dir:
        return Path(cli_dir)
    env = os.environ.get("QAUDION_MEMORY_DIR")
    if env:
        return Path(env)
    return (
        Path.home()
        / ".claude" / "projects"
        / "D--users-f10379a-DEV-APP-BCRYPTO" / "memory"
    )


def split_units(path, text):
    """Split a memory file into scoring units.

    MEMORY.md: each '- [Title](file)' index bullet (possibly multi-line) is one
    unit. Per-incident files: blank-line separated blocks. Each unit keeps a
    reference to its source path.
    """
    name = path.name
    units = []
    if name.lower() == "memory.md":
        cur = []
        for line in text.split("\n"):
            if re.match(r"^\s*-\s*\[", line) and cur:
                units.append("\n".join(cur).strip())
                cur = [line]
            else:
                cur.append(line)
        if cur:
            units.append("\n".join(cur).strip())
        units = [u for u in units if u and u.lstrip().startswith("- [")]
    else:
        for block in re.split(r"\n\s*\n", text):
            block = block.strip()
            if block:
                units.append(block)
    return [(path, u) for u in units if u]


def load_corpus(mem_dir):
    """Return (units, df, n_units). units = list of (path, text, tokenset_list)."""
    if not mem_dir.exists():
        print("ERROR: memory dir not found: %s" % mem_dir, file=sys.stderr)
        sys.exit(2)
    md_files = sorted(mem_dir.glob("*.md"))
    if not md_files:
        print("ERROR: no *.md files in %s" % mem_dir, file=sys.stderr)
        sys.exit(2)

    raw_units = []
    for p in md_files:
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except Exception as e:
            print("  skip %s: %s" % (p.name, e), file=sys.stderr)
            continue
        raw_units.extend(split_units(p, text))

    units = []
    df = {}
    for path, text in raw_units:
        # filename tokens contribute to the unit's bag-of-words
        body_tokens = tokenize(text)
        name_tokens = tokenize(path.stem)
        tokens = body_tokens + name_tokens
        tokenset = set(tokens)
        # term frequency map
        tf = {}
        for t in tokens:
            tf[t] = tf.get(t, 0) + 1
        units.append({"path": path, "text": text, "tf": tf, "tokenset": tokenset})
        for t in tokenset:
            df[t] = df.get(t, 0) + 1

    return units, df, len(units)


def score_units(query, units, df, n_units):
    q_tokens = tokenize(query)
    q_set = list(dict.fromkeys(q_tokens))  # distinct, order-stable
    norm_query = " ".join(query.lower().split())

    def idf(t):
        return math.log((n_units + 1) / (df.get(t, 0) + 1)) + 1.0

    scored = []
    for u in units:
        tf = u["tf"]
        s = 0.0
        matched = []
        for t in q_set:
            c = tf.get(t, 0)
            if c:
                s += idf(t) * c
                matched.append(t)
        if s <= 0:
            continue
        # exact-substring bonus (whole normalized query appears verbatim).
        # BOTH sides must be whitespace-collapsed: memory units are multi-line,
        # so comparing the collapsed query against the RAW (newline-bearing) text
        # made this bonus almost never fire for multi-word queries.
        norm_text = " ".join(u["text"].lower().split())
        if norm_query and norm_query in norm_text:
            s += 5.0
        scored.append({
            "path": u["path"], "text": u["text"], "score": s, "matched": matched,
        })
    scored.sort(key=lambda r: r["score"], reverse=True)
    return scored


def snippet(text, max_chars=320):
    one = " ".join(text.split())
    if len(one) <= max_chars:
        return one
    return one[:max_chars].rstrip() + " ..."


def main():
    ap = argparse.ArgumentParser(
        description="Local keyword-rank retrieval over the memory corpus (no network, no LLM)."
    )
    ap.add_argument("query", nargs="+", help="crash/symptom words")
    ap.add_argument("-k", "--top-k", type=int, default=5, help="results to return")
    ap.add_argument("--full", action="store_true", help="print full unit text")
    ap.add_argument("--memory-dir", type=str, default="", help="override memory dir")
    ap.add_argument("--min-score", type=float, default=0.0, help="drop below this score")
    args = ap.parse_args()

    query = " ".join(args.query)
    mem_dir = resolve_memory_dir(args.memory_dir)

    units, df, n_units = load_corpus(mem_dir)
    results = score_units(query, units, df, n_units)
    results = [r for r in results if r["score"] >= args.min_score]

    out("=" * 72)
    out("MEMORY RECALL  (local only, no network, no LLM)")
    out("query: %s" % query)
    out("corpus: %d units from %s" % (n_units, mem_dir))
    out("=" * 72)

    if not results:
        out("")
        out("No matching past incidents. Try different / fewer keywords.")
        return

    for i, r in enumerate(results[: args.top_k], 1):
        rel = r["path"].name
        out("")
        out("#%d  score=%.2f  [%s]" % (i, r["score"], rel))
        out("    matched: %s" % ", ".join(r["matched"]))
        body = r["text"] if args.full else snippet(r["text"])
        for line in body.split("\n"):
            out("    " + line)


if __name__ == "__main__":
    main()
