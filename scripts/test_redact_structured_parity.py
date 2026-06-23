#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Parity port + test of RuntimeLogSink.redactStructured (RuntimeLogSink.swift).

This mirrors the EXACT 5-step egress redactor used on BOTH iOS egress paths:
  - the text path  : RuntimeLogSink.entriesSince() (msg field)
  - the structured path (P2, this change): TelemetryService.emit() attr values

It is NOT the Loki shipper (scripts/ship-ios-logs.py), which uses a different,
lower-threshold positive allow-list. This file proves the Swift regexes/thresholds
themselves: blob>=24, residual>=20, dotted-JWT, secret-keyword VALUES, while
PRESERVING call_id UUIDs (-> short8), labelled short fingerprints, and crash
frames "QAudionApp + N" / file:line.

Run:  python scripts/test_redact_structured_parity.py
Exit: 0 = all parity assertions pass, 1 = a MUST-SCRUB leaked or a MUST-PRESERVE
        was destroyed.

Swift source of truth (RuntimeLogSink.swift):
  uuidRegex        : \b[0-9a-fA-F]{8}-{4}-{4}-{4}-{12}\b
  fingerprintRegex : (?i)\b(keyfp|selectedpskfingerprint|short8|h8|fp)([\s:=]+)([0-9a-fA-F]{8,16})\b
  jwtRegex         : [A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}
  secretPrefixed   : (?i)(bearer|authorization|token|secret|api[-_]?key|password|psk|seed|
                          mnemonic|privkey|private[-_]?key|mlkem|sframe|kyber)([":'=]\s*)[^\s\x01]+
  blobWithHyphen   : [A-Za-z0-9+/=_-]{24,}
  residualRegex    : (?<![0-9a-fA-Fx])[A-Za-z0-9+/=_-]{20,}
Order: stash UUID -> stash fingerprint -> JWT -> secret-keyword -> blob>=24
       -> residual>=20 -> restore.
"""

import re
import sys

REDACT = "***REDACTED***"

# --- regexes (ported 1:1 from RuntimeLogSink.swift) ---
UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
FINGERPRINT_RE = re.compile(
    r"(?i)\b(keyfp|selectedpskfingerprint|short8|h8|fp)([\s:=]+)([0-9a-fA-F]{8,16})\b")
JWT_RE = re.compile(
    r"[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}")
# Swift value-run is [^\s\x{0001}]+ ; \x01 is the stash sentinel byte.
SECRET_PREFIXED_RE = re.compile(
    r"(?i)(bearer|authorization|token|secret|api[-_]?key|password|psk|seed|mnemonic|"
    r"privkey|private[-_]?key|mlkem|sframe|kyber)([\"':=]\s*)[^\s\x01]+")
BLOB_RE = re.compile(r"[A-Za-z0-9+/=_-]{24,}")
# Swift fixed-width-1 negative lookbehind ports directly to Python.
RESIDUAL_RE = re.compile(r"(?<![0-9a-fA-Fx])[A-Za-z0-9+/=_-]{20,}")


def _stash_matches(rx, text, stash):
    """Replace each match with \\x01K<idx>\\x01 sentinel; append original to stash.
    Left-to-right, non-overlapping (mirror of RuntimeLogSink.stashMatches)."""
    out = []
    last = 0
    for m in rx.finditer(text):
        out.append(text[last:m.start()])
        idx = len(stash)
        stash.append(m.group(0))
        out.append("\x01K%d\x01" % idx)
        last = m.end()
    out.append(text[last:])
    return "".join(out)


def redact_structured(line):
    work = line
    stash = []
    # 1a. stash call_id UUIDs
    work = _stash_matches(UUID_RE, work, stash)
    # 1b. stash labelled short-hex fingerprints (whole match)
    work = _stash_matches(FINGERPRINT_RE, work, stash)
    # 2. dotted JWT
    work = JWT_RE.sub(REDACT, work)
    # 3. secret keyword VALUES, then hyphen-inclusive blob >= 24
    work = SECRET_PREFIXED_RE.sub(REDACT, work)
    work = BLOB_RE.sub(REDACT, work)
    # 4. fail-closed residual >= 20 (runs BEFORE restore: \x01 sentinels
    #    break stashed runs into short tokens so they survive)
    work = RESIDUAL_RE.sub(REDACT, work)
    # 5. restore stashed UUIDs + fingerprints
    for i, u in enumerate(stash):
        work = work.replace("\x01K%d\x01" % i, u)
    return work


# ---------------------------------------------------------------------------
# Test vectors
# ---------------------------------------------------------------------------
# MUST-SCRUB: the secret token must NOT appear verbatim in the output.
MUST_SCRUB = [
    ("JWT (3-segment)",
     "auth eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQ_signature",
     "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"),
    ("bearer keyword value",
     "header Authorization: Bearer abc123DEFxyzTOKENvalue9988",
     "abc123DEFxyzTOKENvalue9988"),
    ("psk keyword value",
     "selected psk=SUPERSECRETpreSharedKey0001",
     "SUPERSECRETpreSharedKey0001"),
    ("token= keyword value",
     "login token=qwertyuiopASDFGHJKL1234567",
     "qwertyuiopASDFGHJKL1234567"),
    ("base64 blob >= 24",
     "blob TWFueUhhbmRzTWFrZUxpZ2h0V29ya0Jhc2U2NA==",
     "TWFueUhhbmRzTWFrZUxpZ2h0V29ya0Jhc2U2NA=="),
    ("hex key blob >= 24",
     "raw 0011223344556677889900aabbccddeeff00112233",
     "0011223344556677889900aabbccddeeff00112233"),
    ("residual mixed-alnum >= 20 (no keyword, < blob's own charset triggers)",
     "weird MixedAlnumResidual2026Z value",
     "MixedAlnumResidual2026Z"),
]

# MUST-PRESERVE: the diagnostic substring MUST survive verbatim in the output.
MUST_PRESERVE = [
    ("call_id UUID (correlate-call short8 source)",
     "call started call_id=3f2504e0-4f89-41d3-9a0c-0305e82c3301 ok",
     "3f2504e0-4f89-41d3-9a0c-0305e82c3301"),
    ("crash frame QAudionApp + N",
     "crash backtrace QAudionApp + 12345 in frame",
     "QAudionApp + 12345"),
    ("file:line diagnostic",
     "fatal at CallController.swift:128 boom",
     "CallController.swift:128"),
    ("labelled keyfp short fingerprint",
     "PSK selected keyfp=a1b2c3d4 converged",
     "keyfp=a1b2c3d4"),
    ("short8 labelled fingerprint",
     "leg join short8=deadbeef matched",
     "short8=deadbeef"),
]


def main():
    failures = []

    print("=== MUST-SCRUB (secret must be removed) ===")
    for name, inp, secret in MUST_SCRUB:
        out = redact_structured(inp)
        leaked = secret in out
        status = "FAIL-LEAK" if leaked else "ok-scrubbed"
        print("  [%s] %s" % (status, name))
        if leaked:
            print("        IN : %r" % inp)
            print("        OUT: %r" % out)
            failures.append("MUST-SCRUB leaked: " + name)

    print("=== MUST-PRESERVE (diagnostic must survive) ===")
    for name, inp, keep in MUST_PRESERVE:
        out = redact_structured(inp)
        preserved = keep in out
        status = "ok-preserved" if preserved else "FAIL-DESTROYED"
        print("  [%s] %s" % (status, name))
        if not preserved:
            print("        IN : %r" % inp)
            print("        OUT: %r" % out)
            failures.append("MUST-PRESERVE destroyed: " + name)

    print("")
    if failures:
        print("RESULT: FAIL (%d)" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    total = len(MUST_SCRUB) + len(MUST_PRESERVE)
    print("RESULT: PASS  (%d/%d parity assertions)" % (total, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
