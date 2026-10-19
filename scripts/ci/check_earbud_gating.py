#!/usr/bin/env python3
"""check_earbud_gating.py - source gate: the earbud hardware stack is compiled only with QAUDION_EARBUD.

WHY. The earbud stack (the CoreBluetooth GATT client for the Q-Audion earbud and everything that
exists only to drive it) is a compile-time switch, like the VPN. The default build, every tag push,
must not contain it (hardware lab builds only; kept out of store builds). Nothing about that is
checked by the compiler of the default build: a reference to one of these symbols outside a
`#if QAUDION_EARBUD` region would either fail the default build (good, but only on macOS and late) or,
worse, reintroduce the code unnoticed. This script proves, on any machine with Python 3 and in a
second, that with QAUDION_EARBUD OFF none of the stack's symbols is left in the code the compiler
would see. scripts/ci/assert-no-earbud.sh proves the same on the built binary; the two are
independent on purpose.

HOW. It reads every .swift file, evaluates `#if / #elseif / #else / #endif` with QAUDION_EARBUD
= false in three-valued logic (any other condition - QAUDION_DEV_TOOLS, DEBUG, os(iOS),
canImport(X), ... - is UNKNOWN, i.e. possibly active), drops comments, and reports every line that
can be compiled with the flag off and still mentions a symbol of the stack. A region is skipped only
when its condition is definitely false: `#if QAUDION_EARBUD`, `#if QAUDION_DEV_TOOLS && QAUDION_EARBUD`,
the `#else` of `#if !QAUDION_EARBUD`... but NOT `#if QAUDION_EARBUD || DEBUG`.

It also checks the build specs and the workflow wiring that keep the default build free of it
(`--specs`, on by default).

USAGE   python3 -I scripts/ci/check_earbud_gating.py [--root DIR] [--no-specs]
EXIT    0 clean | 1 a reference outside the flag, or a spec/workflow check failed | 2 cannot run
"""
import argparse
import os
import re
import sys

# ---- the stack ------------------------------------------------------------------------------
# Whole-word identifiers. Types, members and files that exist only to talk to the earbud hardware.
SYMBOLS = [
    "IOSEarbudGattProxy",
    "CoreBluetoothSovereignRelay",
    "SovereignEarbudGattRelay",
    "QaudionEarbudGatt",
    "EarbudKeyImportService",
    "Fe5ExchangeService",
    "EarbudDiagViewModel",
    "EarbudDiagScreen",
    "earbudGattProxy",
    "rememberEarbudIdentifier",
]
# Plain substrings: string literals that identify the hardware or its server exchange.
LITERALS = [
    "f2c0aaaa-bcc0-4001",          # earbud GATT service UUID base
    "qaudion_paired_earbud_uuid",  # UserDefaults key of the remembered earbud
    "/api/v1/diag/fe5",            # earbud pairing exchange endpoints
]
# Regexes: the GATT UUID constants (they used to be in the engine's always-compiled enum).
PATTERNS = [
    r"EarbudGattConstants\.[A-Z_]+_UUID\b",
]
FLAG = "QAUDION_EARBUD"

_SYMBOL_RES = [(s, re.compile(r"\b" + re.escape(s) + r"\b")) for s in SYMBOLS]
_PATTERN_RES = [(p, re.compile(p)) for p in PATTERNS]

SKIP_DIRS = {".git", "graphify-out", ".build", "build", "DerivedData", "node_modules", ".cache"}

# Files that may name the stack outside the flag because they are not part of the app binary and exist to
# test the flag itself: the unit test looks the classes up BY NAME in the Objective-C runtime to prove they
# are absent (default build) or present (earbud build).
ALLOWED_FILES = {"QAudionAppTests/EarbudCompileConditionTests.swift"}

# ---- three-valued logic ------------------------------------------------------------------------
T, F, U = "T", "F", "U"


def not3(a):
    return {T: F, F: T, U: U}[a]


def and3(a, b):
    if a == F or b == F:
        return F
    if a == T and b == T:
        return T
    return U


def or3(a, b):
    if a == T or b == T:
        return T
    if a == F and b == F:
        return F
    return U


_TOKEN_RE = re.compile(r"\s*(&&|\|\||!|\(|\)|[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^()]*\))?|\S)")


def eval_condition(expr):
    """Evaluate a Swift compilation condition with QAUDION_EARBUD = false. Unknown atoms are U."""
    expr = expr.strip()
    tokens = []
    pos = 0
    while pos < len(expr):
        m = _TOKEN_RE.match(expr, pos)
        if not m:
            break
        tokens.append(m.group(1))
        pos = m.end()
    idx = 0

    def peek():
        return tokens[idx] if idx < len(tokens) else None

    def take():
        nonlocal idx
        tok = tokens[idx]
        idx += 1
        return tok

    def parse_or():
        v = parse_and()
        while peek() == "||":
            take()
            v = or3(v, parse_and())
        return v

    def parse_and():
        v = parse_not()
        while peek() == "&&":
            take()
            v = and3(v, parse_not())
        return v

    def parse_not():
        if peek() == "!":
            take()
            return not3(parse_not())
        return parse_atom()

    def parse_atom():
        tok = peek()
        if tok is None:
            return U
        take()
        if tok == "(":
            v = parse_or()
            if peek() == ")":
                take()
            return v
        if tok == FLAG:
            return F
        if tok == "true":
            return T
        if tok == "false":
            return F
        return U  # any other flag or platform/compiler/canImport condition: possibly active

    try:
        return parse_or()
    except Exception:  # an expression this tiny parser cannot read is treated as possibly active
        return U


# ---- comment stripping -----------------------------------------------------------------------------
class CommentStripper:
    """Strips // and /* */ comments (nested block comments, as Swift allows) and keeps string literals."""

    def __init__(self):
        self.block_depth = 0
        self.in_triple = False

    def strip_line(self, line):
        out = []
        i = 0
        n = len(line)
        in_str = False
        while i < n:
            c = line[i]
            two = line[i:i + 2]
            if self.block_depth > 0:
                if two == "/*":
                    self.block_depth += 1
                    i += 2
                elif two == "*/":
                    self.block_depth -= 1
                    i += 2
                else:
                    i += 1
                continue
            if self.in_triple:
                out.append(c)
                if line[i:i + 3] == '"""':
                    out.append(line[i + 1:i + 3])
                    self.in_triple = False
                    i += 3
                else:
                    i += 1
                continue
            if in_str:
                out.append(c)
                if c == "\\" and i + 1 < n:
                    out.append(line[i + 1])
                    i += 2
                    continue
                if c == '"':
                    in_str = False
                i += 1
                continue
            if line[i:i + 3] == '"""':
                self.in_triple = True
                out.append('"""')
                i += 3
                continue
            if c == '"':
                in_str = True
                out.append(c)
                i += 1
                continue
            if two == "//":
                break
            if two == "/*":
                self.block_depth += 1
                i += 2
                continue
            out.append(c)
            i += 1
        return "".join(out)


# ---- scanner -----------------------------------------------------------------------------------------
_DIRECTIVE_RE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


class Frame:
    def __init__(self, active, prev_or):
        self.active = active    # value of the branch currently open
        self.prev_or = prev_or  # OR of the conditions of the earlier branches


def scan_text(text, path="<text>"):
    """Return (hits, errors). A hit is (line_no, what, line_text); an error is (line_no, message)."""
    hits = []
    errors = []
    stack = []
    stripper = CommentStripper()
    for lineno, raw in enumerate(text.splitlines(), 1):
        code = stripper.strip_line(raw)
        m = _DIRECTIVE_RE.match(code)
        if m:
            kind, rest = m.group(1), m.group(2)
            if kind == "if":
                cond = eval_condition(rest)
                stack.append(Frame(cond, cond))
            elif kind == "elseif":
                if not stack:
                    errors.append((lineno, "#elseif without #if"))
                    continue
                fr = stack[-1]
                cond = eval_condition(rest)
                fr.active = and3(not3(fr.prev_or), cond)
                fr.prev_or = or3(fr.prev_or, cond)
            elif kind == "else":
                if not stack:
                    errors.append((lineno, "#else without #if"))
                    continue
                fr = stack[-1]
                fr.active = not3(fr.prev_or)
            else:  # endif
                if not stack:
                    errors.append((lineno, "#endif without #if"))
                    continue
                stack.pop()
            continue
        live = T
        for fr in stack:
            live = and3(live, fr.active)
        if live == F:
            continue
        for name, rx in _SYMBOL_RES:
            if rx.search(code):
                hits.append((lineno, name, raw.strip()))
        for lit in LITERALS:
            if lit in code:
                hits.append((lineno, lit, raw.strip()))
        for name, rx in _PATTERN_RES:
            if rx.search(code):
                hits.append((lineno, name, raw.strip()))
    if stack:
        errors.append((len(text.splitlines()), "%d unterminated #if" % len(stack)))
    return hits, errors


def swift_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if fn.endswith(".swift"):
                yield os.path.join(dirpath, fn)


# ---- build spec / workflow checks ------------------------------------------------------------------------
def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return f.read()


def check_specs(root):
    """Return a list of failure messages (empty = all good)."""
    fails = []

    def need(rel, ok, msg):
        if not ok:
            fails.append("%s: %s" % (rel, msg))

    default = read(root, "QAudionApp/project.yml")
    need("QAudionApp/project.yml", FLAG not in default,
         "the default spec must not mention %s (it would compile the stack into every build)" % FLAG)

    vpn = read(root, "QAudionApp/project-vpn.yml")
    need("QAudionApp/project-vpn.yml", FLAG not in vpn, "the VPN spec must not turn the earbud stack on")

    earbud = read(root, "QAudionApp/project-earbud.yml")
    flags = re.findall(r"^\s*OTHER_SWIFT_FLAGS:\s*(.+)$", earbud, re.M)
    need("QAudionApp/project-earbud.yml", len(flags) == 1 and "-D" + FLAG in flags[0].split(),
         "must set OTHER_SWIFT_FLAGS with -D%s exactly once" % FLAG)
    need("QAudionApp/project-earbud.yml", re.search(r"^include:\s*\n\s*-\s*project\.yml\s*$", earbud, re.M) is not None,
         "must include project.yml unchanged")
    need("QAudionApp/project-earbud.yml", "QAUDION_VPN" not in "".join(flags),
         "the earbud-only spec must not turn the VPN on")

    combo = read(root, "QAudionApp/project-vpn-earbud.yml")
    cflags = re.findall(r"^\s*OTHER_SWIFT_FLAGS:\s*(.+)$", combo, re.M)
    toks = cflags[0].split() if len(cflags) == 1 else []
    need("QAudionApp/project-vpn-earbud.yml", "-D" + FLAG in toks and "-DQAUDION_VPN" in toks,
         "must set both -DQAUDION_VPN and -D%s (union of the two specs)" % FLAG)
    need("QAudionApp/project-vpn-earbud.yml", re.search(r"^include:\s*\n\s*-\s*project-vpn\.yml\s*$", combo, re.M) is not None,
         "must include project-vpn.yml unchanged")

    wf = read(root, ".github/workflows/ios-testflight.yml")
    need(".github/workflows/ios-testflight.yml",
         "EARBUD_BUILD: ${{ github.event_name == 'workflow_dispatch' && github.event.inputs.earbud == 'true' && 'true' || 'false' }}" in wf,
         "EARBUD_BUILD must be true only for a workflow_dispatch with earbud=true (a tag push is always the default build)")
    need(".github/workflows/ios-testflight.yml", "scripts/ci/assert-no-earbud.sh" in wf,
         "the shipped IPA must be checked with scripts/ci/assert-no-earbud.sh")
    need(".github/workflows/ios-testflight.yml", re.search(r"^      earbud:\s*$", wf, re.M) is not None,
         "missing the workflow_dispatch input `earbud`")
    return fails


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=None, help="repository root (default: two levels above this script)")
    ap.add_argument("--no-specs", action="store_true", help="skip the build spec / workflow checks")
    args = ap.parse_args(argv)
    root = args.root or os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    if not os.path.isdir(os.path.join(root, "QAudionApp")):
        print("::error::check_earbud_gating: %s has no QAudionApp directory" % root)
        return 2

    status = 0
    scanned = 0
    for path in sorted(swift_files(root)):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        if rel in ALLOWED_FILES:
            scanned += 1
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            print("::error::check_earbud_gating: cannot read %s: %s" % (rel, e))
            return 2
        scanned += 1
        hits, errors = scan_text(text, rel)
        for lineno, msg in errors:
            print("::error file=%s,line=%d::check_earbud_gating: %s" % (rel, lineno, msg))
            status = 1
        for lineno, what, line in hits:
            print("::error file=%s,line=%d::%s is compiled without %s: %s" % (rel, lineno, what, FLAG, line[:120]))
            status = 1
    print("check_earbud_gating: scanned %d Swift file(s)" % scanned)
    if scanned == 0:
        print("::error::check_earbud_gating: no Swift file found under %s - the scan saw nothing" % root)
        return 2

    if not args.no_specs:
        try:
            fails = check_specs(root)
        except OSError as e:
            print("::error::check_earbud_gating: cannot read a spec or workflow: %s" % e)
            return 2
        for msg in fails:
            print("::error::check_earbud_gating: %s" % msg)
            status = 1
    print("check_earbud_gating: %s" % ("clean" if status == 0 else "FAILED"))
    return status


if __name__ == "__main__":
    sys.exit(main())
