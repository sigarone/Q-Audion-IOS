#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Parity port + test of RuntimeLogSink.redactStructured (LogRedactor.swift since v1.0.1180;
RuntimeLogSink.redactStructured now just forwards to it, unchanged).

This mirrors the EXACT 5-step egress redactor used on BOTH iOS egress paths:
  - the text path  : LiveLogWorker (msg field; it was RuntimeLogSink.entriesSince() before v1.0.1180)
  - the structured path (P2, this change): TelemetryService.emit() attr values

It is NOT the Loki shipper (scripts/ship-ios-logs.py), which uses a different,
lower-threshold positive allow-list. This file proves the Swift regexes/thresholds
themselves: blob>=24, residual>=20, dotted-JWT, secret-keyword VALUES, while
PRESERVING call_id UUIDs (-> short8), labelled short fingerprints, and crash
frames "QAudionApp + N" / file:line.

Since the location messages (WIRE_SPEC section 14.10) the first step is the COORDINATE RULE (LocationLogScrub.swift, the same seven
patterns): a position, a geo: URI, a map link, a share id or key is removed before anything else runs. The `redaction_cases` of
QAudionEngine/Tests/QAudionEngineTests/Resources/kat/location-kat.json (a byte-for-byte copy of the server's file) are run through this
port below: every `must_not_survive` substring must be gone.

Run:  python scripts/test_redact_structured_parity.py
Exit: 0 = all parity assertions pass, 1 = a MUST-SCRUB leaked or a MUST-PRESERVE
        was destroyed.

Swift source of truth (QAudionApp/Services/LogRedactor.swift):
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

import hashlib
import json
import os
import re
import sys

REDACT = "***REDACTED***"
KAT_SHA256 = "72ac8c3f6987c252f2722b9b50c836e9218a3588748bbd9220e67b560b43d600"

# --- regexes (ported 1:1 from LogRedactor.swift, formerly RuntimeLogSink.swift) ---
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


# --- the coordinate rule (WIRE_SPEC section 14.10), ported 1:1 from LocationLogScrub.swift ---
# LogRedactor.redactStructured runs it right after scrubKeyMaterial, before anything is stashed or restored, and so does redact_structured
# below. The seven patterns are the SAME, character for character, in LocationLogScrub.swift and in scripts/ship-ios-logs.py;
# scripts/test_ship_ios_location_redaction.py pins that (and runs the `redaction_cases` of location-kat.json through the shipper); this file
# runs the same cases through the port of the redactor.
LOCATION_PLACEHOLDER = "***REDACTED***"
LOCATION_PATTERNS = (
    r'''\{\s*\\?"qa_loc\\?"\s*:[^}]*\}?''',
    r'''(?i)\bgeo:[^\s"'<>]*''',
    r'''(?i)https?://(?:[a-z0-9-]+\.)*(?:maps\.apple\.com|google\.[a-z.]+/maps|maps\.google\.[a-z.]+|goo\.gl/maps|maps\.app\.goo\.gl)[^\s"'<>]*''',
    r'''(?i)["']?\b(?:lat|lon|lng|latitude|longitude|acc|accuracy)\b["']?\s*[:=]\s*["']?[-+]?\d+(?:\.\d+)?(?![\d.])(?!\s?ms\b)["']?''',
    r'''(?i)\b(?:ll|sll|q|daddr|saddr|destination|query|center)\s*=\s*[-+]?\d+(?:\.\d+)?\s*(?:,|;|%2[Cc])\s*[-+]?\d+(?:\.\d+)?''',
    r'''(?<![\d.])[-+]?\d{1,3}\.\d{3,}(?:\s*[,;]\s*|\s*%2[Cc]\s*|\s+)[-+]?\d{1,3}\.\d{3,}(?!\d)''',
    r'''(?i)["']?\b(?:sid|k|share[_-]?key|share[_-]?id)\b["']?\s*[:=]\s*["']?[A-Za-z0-9+/_-]{20,}={0,2}["']?''',
)
LOCATION_RES = tuple(re.compile(p) for p in LOCATION_PATTERNS)


def scrub_location(text):
    """Every shape but the last holds a digit (or the prefix of a body, which always carries one): a text without a digit skips them;
    the share id and key rule always runs (a base64 text can have no digit)."""
    has_digit = re.search(r"[0-9]", text) is not None
    last = len(LOCATION_RES) - 1
    for index, rx in enumerate(LOCATION_RES):
        if not has_digit and index != last:
            continue
        text = rx.sub(LOCATION_PLACEHOLDER, text)
    return text


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
    # 0. the coordinate rule (WIRE_SPEC 14.10), before anything can be stashed or restored
    work = scrub_location(line)
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
    ("a latency is not a position (lat=12ms stays)",
     "abr loss=1% lat=12ms jitter=3ms",
     "lat=12ms"),
]

KAT_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "QAudionEngine", "Tests",
                        "QAudionEngineTests", "Resources", "kat", "location-kat.json")


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

    print("=== LOCATION redaction_cases (WIRE_SPEC 14.10: none of must_not_survive may remain)")
    with open(KAT_PATH, "rb") as handle:
        kat_bytes = handle.read()
    if hashlib.sha256(kat_bytes).hexdigest() != KAT_SHA256:
        failures.append("location-kat.json is not the pinned copy")
    cases = json.loads(kat_bytes.decode("utf-8"))["redaction_cases"]
    if len(cases) != 20:
        failures.append("location-kat.json: expected 20 redaction cases, found %d" % len(cases))
    for case in cases:
        out = redact_structured(case["line"])
        leaked = [needle for needle in case["must_not_survive"] if needle in out]
        status = "FAIL-LEAK" if leaked else "ok-scrubbed"
        print("  [%s] %s" % (status, case["name"]))
        if leaked:
            print("        IN : %r" % case["line"])
            print("        OUT: %r" % out)
            failures.append("location redaction leaked: " + case["name"])

    print("")
    if failures:
        print("RESULT: FAIL (%d)" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    total = len(MUST_SCRUB) + len(MUST_PRESERVE) + len(cases)
    print("RESULT: PASS  (%d/%d parity assertions)" % (total, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
