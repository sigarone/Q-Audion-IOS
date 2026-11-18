#!/usr/bin/env python3
"""Check of the text that a pull request adds to this public repository.

Comments, commit messages and pull request titles say what the code does. They do not point to internal notes, finding
or plan codes, other repositories or hosts of the project, real calls or past events. This script reads what a pull
request ADDS and fails when that text breaks a rule of the table RULES (or names a word of NAME_HASHES).

What is read
  * the lines the pull request adds (git diff BASE...HEAD, no context lines) in *.swift *.yml *.yaml *.py *.sh *.md
    *.plist *.xcstrings, reduced to their text part: the comments of the language (Swift: // /// and nested /* */, found
    by a lexer over the whole file at HEAD, so that a // inside a string is not a comment; Python: the tokenizer;
    yml and sh: # outside quotes), the whole line in Markdown, the "comment" and "value" fields of a String Catalog,
    the text of a property list;
  * the title and the body of the pull request, and the whole message of every commit of the pull request.
Lines the pull request did not add are never read, and a line it removed never counts.
Not read: the file WIRE_SPEC.md at the repository root, code, string literals of Swift, Python and shell, and anything
the rules below do not name (hex strings that are hashes or test vectors, W-<TAG> log markers, the words "memory",
"audit", "field" alone).

Escape hatch for the rare line that is fine: put the text held in MARKER on it. The line is skipped and the number of
skipped lines is printed.

Names: the names this repository must not spell out are kept as SHA-256 hashes of the lowercase name, the way
check_release_notes.py keeps brand names. A word of the text is lowercased and looked up by hash; a name made of
several words joined by "-" or "_" is one token, and the words of a path or a URL are tokens of their own. A hash hides
a name from a text search, not from someone who guesses it.

USAGE   check_public_text.py --base SHA --head SHA [--pr-json FILE] [--repo DIR] [--show-text]
          --pr-json   JSON with "title" and "body" (the pull request of the API, or the event payload of the workflow)
          --show-text print the matched text after each hit (local use; the CI log keeps to file, line and rule)
EXIT    0 clean, 1 at least one hit, 2 the input could not be read.
"""
import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tokenize

MARKER = "public-text" ": ok"
EXTENSIONS = (".swift", ".yml", ".yaml", ".py", ".sh", ".md", ".plist", ".xcstrings")
EXCLUDED_FILES = ("WIRE_SPEC.md",)  # paths from the repository root whose added lines are not read (see RULES)

BOTH = "both"      # a rule for comments and for commit and pull request texts
COMMIT = "commit"  # a rule for commit and pull request texts only
COMMENT = "comment"  # the scope of a comment read from a source file
SHIPPED = "shipped"  # the scope of a text the app shows: a "value" of a String Catalog, a property list

# One row per rule: id, where it applies, regular expression (case-insensitive), reason. Add a row to add a rule; the
# self-test of this table is scripts/ci/test_check_public_text.py.
# No rule reads WIRE_SPEC.md at the repository root (EXCLUDED_FILES): it is a contract text kept byte-identical in every
# copy of it, so it cannot carry MARKER and its added lines are skipped. No other file is left out.
RULES = (
    ("internal-note", BOTH,
     r"\baudit memory\b|\bmemory files?\b|\bcrypto_protocol_audit\b|(?<![a-z0-9_])(?:reference|project|feedback)_[a-z]",
     "points at an internal note or audit"),
    ("finding-code", BOTH,
     r"(?<![a-z0-9])(?:adr|trust|task)-\d+\b|\bsecurity[ :]+c-\d+\b",
     "internal finding or plan code"),
    ("call-id", BOTH,
     r"(?<![a-z0-9])call(?:[ _-]?id)?(?![a-z])(?:[^a-z0-9_]+[a-z0-9_]+){0,2}?[^a-z0-9_]+[0-9a-f]{8}(?![a-z0-9_])",
     "id of a real call"),
    ("incident", BOTH,
     r"\bincidents?\b",
     "tells of a real incident"),
    ("co-author", COMMIT,
     r"^\s*co-authored-by\s*:",
     "this repository takes no Co-Authored-By trailer"),
)
COMPILED = tuple((rid, where, re.compile(rx, re.I), why) for rid, where, rx, why in RULES)

# Names kept out of the text, as SHA-256 of the lowercase name -> what kind of name it is.
NAME_HASHES = {
    "7b8a3dcf93c18c0693b69a77d523fbfeb0cc6208a9ba8d444c007f1873e87462": "repository",
    "c9fc332d6bee21b534d04a588b7b38bd34c8595dc5303082bb56259b7796be1b": "repository",
    "5e95b51a7af3639f41f5817c1b9069a9f9de5622643c51b6fc1346d97dfc1f1f": "repository",
    "83ef091403cd6ecb1e5c8f19c70605673542a9d5ba73c6a6a71ed42ec954bdce": "repository",
    "cf90d792e03f01fc3d58d6a0664d83d65d2850af62f77ca83d8bb03ace682b7c": "repository",
    "42e8c5b5c0497f39c19def881d2d49fe4088099e4ddf76ef0ac64c19f9668c4f": "repository",
    "b115aa69979549872d25cf36be63adbace7df146771849d2a9bae78bbc5fba91": "repository",
    "b5d350606cc7822329b752d6cc8359b1dfeab11174af2b9791f79b3b9b4853e1": "repository",
    "457d34253dc3af278ecddd3eac77d593edc7bd9505b3443abd4f84e2e6575079": "repository",
    "dd292ab6f0ded21a272755831bb5f3d983a47a0b3c9c8fbf182a0baa0393d9fb": "repository",
    "507451424ce6ca0c535b01aa9021b453dfd2f850c37dce4378524d0a80fcd761": "repository",
    "864badae422ed4f5c002806fc134eb464005b01d3477c151e89d6eb32155949b": "repository",
    "acf9e97160368047fd4a304b4c5c555cc210cd162144e376cb1b6099fed854c5": "host",
    "2fcc9256ec1186625790e592f0427f659ed67e297001c1cf06e47ce1aa12c0a1": "host",
    "ec61bcb4e4f93d6fc5ddede12d64ea8ecdaee68afb173f41411370c864ac89d8": "host",
    "8446fb5c6362a912e6822bd05ffa902266d2f774ccd90856248a0a70563deb8d": "host",
}
# Listed names that are also a word of the product: fine in a text the app shows (a German compound word), not in a
# comment.
SHIPPED_TEXT_OK_HASHES = frozenset({
    "83ef091403cd6ecb1e5c8f19c70605673542a9d5ba73c6a6a71ed42ec954bdce",
})
# Names that contain a listed name and are fine: the span they cover is not reported.
OKAY_NAME_HASHES = frozenset({
    "d57395c95def49ed935fd6225e8d4927e94c43bde016d62d1158d1a820ccf81b",
})
MAX_NAME_WORDS = 4  # the most words in a name of NAME_HASHES or OKAY_NAME_HASHES

TOKEN_RE = re.compile(r"[a-z0-9]+(?:[-_][a-z0-9]+)*")
SPLIT_RE = re.compile(r"[-_]")


class Hit:
    def __init__(self, where, line, rule, reason, text="", is_file=False):
        self.where, self.line, self.rule, self.reason = where, line, rule, reason
        self.text, self.is_file = text, is_file

    def place(self):
        return self.where if self.line is None else "%s:%d" % (self.where, self.line)


def _sha(word):
    return hashlib.sha256(word.encode("utf-8")).hexdigest()


def name_kind(text, shipped=False):
    """The kind ("repository", "host") of the first listed name in the text, or None."""
    for m in TOKEN_RE.finditer(text.lower()):
        words = SPLIT_RE.split(m.group())
        okay, found = [], []
        for i in range(len(words)):
            for j in range(i + 1, min(len(words), i + MAX_NAME_WORDS) + 1):
                digest = _sha("-".join(words[i:j]))
                if digest in OKAY_NAME_HASHES:
                    okay.append((i, j))
                elif digest in NAME_HASHES and not (shipped and digest in SHIPPED_TEXT_OK_HASHES):
                    found.append((i, j, NAME_HASHES[digest]))
        for i, j, kind in found:
            if not any(a <= i and j <= b for a, b in okay):
                return kind
    return None


def problems_in(text, scope):
    """[(rule id, reason)] for one line of text; scope is COMMENT, SHIPPED or COMMIT (a commit or pull request text)."""
    out = []
    for rid, where, rx, why in COMPILED:
        if (where == BOTH or scope == COMMIT) and rx.search(text):
            out.append((rid, why))
    kind = name_kind(text, scope == SHIPPED)
    if kind:
        out.append(("internal-name", "name of a private %s" % kind))
    return out


# ---------------------------------------------------------------- comments of each language

_SWIFT_CODE_STOP = re.compile(r'[/"#\n]')
_SWIFT_NESTED_STOP = re.compile(r'[/"#\n()]')
_SWIFT_STRING_STOP = re.compile(r'[\\"\n]')
_SWIFT_MULTI_OPEN = re.compile(r'"""[^\S\n]*(?:\n|\Z)')  # a multi-line string opens only when a line break follows


def swift_comments(text):
    """{line number: text of the comments on that line} for a Swift source: // /// and nested /* */ outside strings."""
    n = len(text)
    out = {}

    def add(line, s):
        out.setdefault(line, []).append(s)

    def block(i, line):
        depth, start = 1, i + 2
        i += 2
        while i < n and depth:
            two = text[i:i + 2]
            if two == "/*":
                depth += 1
                i += 2
            elif two == "*/":
                depth -= 1
                i += 2
            elif text[i] == "\n":
                add(line, text[start:i])
                line += 1
                i += 1
                start = i
            else:
                i += 1
        add(line, text[start:max(start, i - 2 if depth == 0 else i)])
        return i, line

    def string(i, line, hashes):
        multi = _SWIFT_MULTI_OPEN.match(text, i) is not None
        i += 3 if multi else 1
        close = ('"""' if multi else '"') + "#" * hashes
        esc = "\\" + "#" * hashes
        while i < n:
            m = _SWIFT_STRING_STOP.search(text, i)
            if not m:
                return n, line
            i = m.start()
            c = text[i]
            if c == "\n":
                if not multi:
                    return i, line  # an unterminated one-line string: go on with the code
                line += 1
                i += 1
            elif c == "\\":
                if text.startswith(esc, i):
                    j = i + len(esc)
                    if j < n and text[j] == "(":
                        i, line = code(j + 1, line, True)
                    else:
                        if j < n and text[j] == "\n":
                            line += 1
                        i = j + 1
                else:
                    i += 1
            else:
                if text.startswith(close, i):
                    return i + len(close), line
                i += 1
        return i, line

    def code(i, line, nested):
        depth = 0
        stop = _SWIFT_NESTED_STOP if nested else _SWIFT_CODE_STOP
        while i < n:
            m = stop.search(text, i)
            if not m:
                return n, line
            i = m.start()
            c = text[i]
            if c == "\n":
                line += 1
                i += 1
            elif c == "/":
                if text.startswith("//", i):
                    j = text.find("\n", i)
                    j = n if j < 0 else j
                    add(line, text[i + 2:j])
                    i = j
                elif text.startswith("/*", i):
                    i, line = block(i, line)
                else:
                    i += 1
            elif c == '"':
                i, line = string(i, line, 0)
            elif c == "#":
                j = i
                while j < n and text[j] == "#":
                    j += 1
                if j < n and text[j] == '"':
                    i, line = string(j, line, j - i)
                else:
                    i = j
            elif c == "(":
                depth += 1
                i += 1
            else:  # ")"
                if depth == 0:
                    return i + 1, line
                depth -= 1
                i += 1
        return i, line

    code(0, 1, False)
    return {k: " ".join(v) for k, v in out.items()}


def hash_comment(line):
    """The comment of one line of yml or shell: the text after a # that starts a word, outside quotes; else ''."""
    quote, prev, i, n = None, " ", 0, len(line)
    while i < n:
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                prev = "x"
                continue
            if c == quote:
                quote = None
        elif c in "\"'" and not prev.isalnum():
            quote = c
        elif c == "#" and prev in " \t":
            return line[i + 1:]
        prev = c
        i += 1
    return ""


def py_comments(text):
    """{line number: comment text} for a Python source, from the tokenizer (the line scan when it cannot tokenize)."""
    out = {}
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT:
                out[tok.start[0]] = tok.string[1:]
        return out
    except Exception:
        return {k: v for k, v in ((i, hash_comment(s)) for i, s in enumerate(text.splitlines(), 1)) if v}


_PLIST_COMMENT = re.compile(r"<!--(.*?)-->")
_PLIST_TAG = re.compile(r"<[^>]*>")
_XCSTRINGS_FIELD = re.compile(r'^\s*"(comment|value)"\s*:\s*"(.*)"\s*,?\s*$')


def text_of_added_line(ext, line):
    """(text, scope) of the part of an added line that is read, for the formats that need no view of the whole file."""
    if ext in (".yml", ".yaml", ".sh"):
        return hash_comment(line), COMMENT
    if ext == ".md":
        return line, COMMENT
    if ext == ".plist":
        return " ".join(_PLIST_COMMENT.findall(line) + [_PLIST_TAG.sub(" ", _PLIST_COMMENT.sub(" ", line))]), SHIPPED
    if ext == ".xcstrings":
        m = _XCSTRINGS_FIELD.match(line)
        return (m.group(2), COMMENT if m.group(1) == "comment" else SHIPPED) if m else ("", COMMENT)
    return "", COMMENT


# ---------------------------------------------------------------- reading the pull request

class GitError(Exception):
    pass


def git(repo, *args, raw=False):
    p = subprocess.run(["git", "-C", repo, "-c", "core.quotepath=off", *args], capture_output=True)
    if p.returncode != 0:
        raise GitError("git %s: %s" % (" ".join(args[:2]), p.stderr.decode("utf-8", "replace").strip()))
    return p.stdout if raw else p.stdout.decode("utf-8", "replace")


_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def added_lines(repo, base, head, direct=False):
    """{path: {line number at HEAD: text}} of the lines BASE...HEAD adds in the files of EXTENSIONS."""
    spec = [base, head] if direct else ["%s...%s" % (base, head)]
    # The prefixes are fixed: a diff.noprefix or diff.srcPrefix setting of the machine must not change the header lines.
    # The inter-hunk context is fixed: a diff.interHunkContext setting would fuse hunks and print context lines.
    out = git(repo, "diff", "--unified=0", "--inter-hunk-context=0", "--no-color", "--no-ext-diff", "--find-renames",
              "--diff-filter=d", "--src-prefix=a/", "--dst-prefix=b/", *spec, "--", *["*" + e for e in EXTENSIONS])
    files, path, cur, in_hunk = {}, None, 0, False
    for raw in out.split("\n"):
        if raw.startswith("diff --git "):
            in_hunk, path = False, None
        elif not in_hunk and raw.startswith("+++ "):
            p = raw[4:].rstrip("\t")
            path = p[2:] if p.startswith("b/") and p.lower().endswith(EXTENSIONS) else None
            if path in EXCLUDED_FILES:
                path = None
        elif raw.startswith("@@"):
            m = _HUNK.match(raw)
            in_hunk = True
            cur = int(m.group(1)) if m else 0
        elif in_hunk and path:
            if raw.startswith("+"):
                files.setdefault(path, {})[cur] = raw[1:].rstrip("\r")
                cur += 1
    return files


def commit_messages(repo, base, head):
    out = git(repo, "log", "--format=%H%x1f%B%x1e", "%s..%s" % (base, head))
    msgs = []
    for rec in out.split("\x1e"):
        sha, _, msg = rec.strip("\n").partition("\x1f")
        if sha.strip():
            msgs.append((sha.strip(), msg))
    return msgs


def head_text(repo, head, path):
    try:
        return git(repo, "show", "%s:%s" % (head, path), raw=True).decode("utf-8", "replace")
    except GitError:
        return None


def check_added(path, added, whole_file):
    """Hits and the number of skipped lines for the added lines of one file; whole_file is the file at HEAD or None."""
    ext = os.path.splitext(path)[1].lower()
    comments = None
    if whole_file is not None:
        if ext == ".swift":
            comments = swift_comments(whole_file)
        elif ext == ".py":
            comments = py_comments(whole_file)
    hits, skipped = [], 0
    for number in sorted(added):
        line = added[number]
        if MARKER in line:
            skipped += 1
            continue
        scope = COMMENT
        if ext == ".swift":
            text = comments.get(number, "") if comments is not None else line.partition("//")[2]
        elif ext == ".py":
            text = comments.get(number, "") if comments is not None else hash_comment(line)
        else:
            text, scope = text_of_added_line(ext, line)
        for rid, why in problems_in(text, scope) if text.strip() else ():
            hits.append(Hit(path, number, rid, why, text.strip(), True))
    return hits, skipped


def check_text(label, text):
    """Hits and the number of skipped lines for the text of a commit, the title or the body of the pull request."""
    hits, skipped = [], 0
    for number, line in enumerate((text or "").splitlines(), 1):
        if MARKER in line:
            skipped += 1
            continue
        for rid, why in problems_in(line, COMMIT):
            hits.append(Hit(label, number, rid, why, line.strip()))
    return hits, skipped


def read_pr(path):
    with open(path, encoding="utf-8") as f:
        obj = json.load(f)
    if isinstance(obj, dict) and isinstance(obj.get("pull_request"), dict):
        obj = obj["pull_request"]
    if not isinstance(obj, dict):
        raise ValueError("not a pull request object")
    return str(obj.get("title") or ""), str(obj.get("body") or "")


def check_range(repo, base, head, pr=None):
    """Everything the range adds: (hits, skipped lines, added lines read, files, texts read). pr is (title, body)."""
    hits, skipped, nlines, texts = [], 0, 0, 0
    files = added_lines(repo, base, head)
    for path in sorted(files):
        h, s = check_added(path, files[path], head_text(repo, head, path))
        hits += h
        skipped += s
        nlines += len(files[path])
    labelled = []
    if pr is not None:
        labelled += [("PR title", pr[0]), ("PR body", pr[1])]
    labelled += [("commit " + sha[:7], msg) for sha, msg in commit_messages(repo, base, head)]
    for label, text in labelled:
        h, s = check_text(label, text)
        hits += h
        skipped += s
        texts += 1
    return hits, skipped, nlines, len(files), texts


def _escape(s, prop=False):
    s = s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return s.replace(":", "%3A").replace(",", "%2C") if prop else s


def main(argv=None):
    ap = argparse.ArgumentParser(description="Blocks internal references in the text a pull request adds.")
    ap.add_argument("--base", required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--pr-json")
    ap.add_argument("--repo", default=".")
    ap.add_argument("--show-text", action="store_true")
    args = ap.parse_args(argv)
    if args.base.startswith("-") or args.head.startswith("-"):
        print("public text: base and head must be commits", file=sys.stderr)
        return 2
    try:
        pr = read_pr(args.pr_json) if args.pr_json else None
        hits, skipped, nlines, nfiles, ntexts = check_range(args.repo, args.base, args.head, pr)
    except (GitError, OSError, ValueError) as e:
        print("public text: cannot read the input: %s" % e, file=sys.stderr)
        return 2
    on_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    for h in hits:
        msg = "%s: %s: %s" % (h.place(), h.rule, h.reason)
        print(msg + ("\n    " + h.text if args.show_text else ""), file=sys.stderr)
        if on_actions:
            where = "file=%s,line=%d," % (_escape(h.where, True), h.line) if h.is_file else ""
            print("::error %stitle=Public text check::%s" % (where, _escape("%s: %s" % (h.rule, h.reason))))
    print("public text: %d added lines in %d files, %d texts read, %d hits; lines skipped by the marker: %d"
          % (nlines, nfiles, ntexts, len(hits), skipped))
    if hits:
        print("Say what the code does instead. A line that is fine as it stands can carry: %s" % MARKER,
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
