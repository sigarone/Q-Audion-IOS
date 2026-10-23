#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The coordinate rule of the phone-log redactor (scripts/ship-ios-logs.py), WIRE_SPEC section 14.10.

No log line may carry a position, an accuracy, an age, a share id, a share key, a geo: URI, a map link or a GPX waypoint. The location
code never logs them; this rule is the net under it, and it has to hold in every redactor of the app:
  - QAudionApp/Services/LogRedactor.swift, both paths (redact and redactStructured), through LocationLogScrub.swift in the engine;
  - the Python parity port of the second path: scripts/test_redact_structured_parity.py;
  - this shipper.
All of them use the SAME seven patterns. This test pins that: the patterns of the shipper must be, character for character, the ones in
LocationLogScrub.swift and in the parity port, and every `redaction_cases` vector of location-kat.json (a byte-for-byte copy of the
server's file, pinned by SHA-256 here as in the Swift tests) must lose every `must_not_survive` substring, through the rule on its own and
through redact_body (the whole shipper pipeline, for a tag that ships and for one that does not).

Run:   python scripts/test_ship_ios_location_redaction.py
Exit:  0 = all checks pass, 1 = at least one failed.
"""
import hashlib
import importlib.util
import json
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
KAT_PATH = os.path.join(ROOT, "QAudionEngine", "Tests", "QAudionEngineTests", "Resources", "kat", "location-kat.json")
SWIFT_PATH = os.path.join(ROOT, "QAudionEngine", "Sources", "QAudionEngine", "Location", "LocationLogScrub.swift")
PARITY_PATH = os.path.join(HERE, "test_redact_structured_parity.py")
KAT_SHA256 = "72ac8c3f6987c252f2722b9b50c836e9218a3588748bbd9220e67b560b43d600"
KAT_LENGTH = 400081


def load(name, path):
    if "paramiko" not in sys.modules:
        try:
            import paramiko  # noqa: F401
        except ImportError:
            sys.modules["paramiko"] = types.ModuleType("paramiko")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


m = load("ship_ios_location_under_test", os.path.join(HERE, "ship-ios-logs.py"))
failures = []


def check(name, ok, detail=""):
    if ok:
        print("  ok   " + name)
    else:
        print("  FAIL " + name + (" -- " + detail if detail else ""))
        failures.append(name)


def swift_patterns():
    """The seven patterns of LocationLogScrub.swift, in order, as the text between #" and "#."""
    with open(SWIFT_PATH, encoding="utf-8") as handle:
        text = handle.read()
    start = text.index("private static let patterns")
    end = text.index("// swiftlint:enable")
    return re.findall(r'#"(.*)"#', text[start:end])


def shipped(line, tag):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


with open(KAT_PATH, "rb") as handle:
    kat_bytes = handle.read()
kat = json.loads(kat_bytes.decode("utf-8"))

print("=== the vector file")
check("location-kat.json is the pinned byte-for-byte copy", hashlib.sha256(kat_bytes).hexdigest() == KAT_SHA256)
check("its length is the pinned one", len(kat_bytes) == KAT_LENGTH)
check("no CR in it (line endings untouched)", b"\r" not in kat_bytes)
cases = kat["redaction_cases"]
check("20 redaction cases", len(cases) == 20, str(len(cases)))

print("=== the patterns are the same everywhere")
swift = swift_patterns()
check("seven patterns in LocationLogScrub.swift", len(swift) == 7, str(len(swift)))
check("the shipper uses them character for character", list(m.LOCATION_PATTERNS) == swift)
parity = load("redact_parity_under_test", PARITY_PATH)
check("so does the parity port of redactStructured", list(parity.LOCATION_PATTERNS) == swift)

print("=== every redaction case, the rule on its own")
for case in cases:
    out = m._scrub_location(case["line"])
    leaked = [needle for needle in case["must_not_survive"] if needle in out]
    check(case["name"], not leaked, "survived: %r in %r" % (leaked, out))
    check(case["name"] + " (idempotent)", m._scrub_location(out) == out)

print("=== every redaction case, the whole shipper (a tag that ships, and one that does not)")
for case in cases:
    for tag in ("chat", "stdout", "nosuchtag"):
        out = shipped(case["line"], tag)
        leaked = [needle for needle in case["must_not_survive"] if needle in out]
        check("%s via %s" % (case["name"], tag), not leaked, "survived: %r in %r" % (leaked, out))
    scrubbed = m._scrub_body(case["line"])
    leaked = [needle for needle in case["must_not_survive"] if needle in scrubbed]
    check(case["name"] + " via _scrub_body", not leaked, "survived: %r in %r" % (leaked, scrubbed))

print("=== other shapes of the same rule")
EXTRA = [
    ("full-width digits and keys (NFKC folds them first)", "lat＝45.464211 lon＝9.189982", ["45.464211", "9.189982"]),
    ("a quoted body inside a log string", 'sent body={\\"qa_loc\\":1,\\"m\\":\\"pin\\",\\"lat\\":454642110,\\"lon\\":91899820}', ["454642110", "91899820"]),
    ("a body after a prefix", 'chat sent {"qa_loc":1,"m":"pin","lat":454642110,"lon":91899820,"acc":12,"age":3,"ap":0} ok', ["454642110", "91899820"]),
    ("accuracy with a decimal", "fix accuracy=12.5 m", ["12.5"]),
    ("a share id without a digit", "sid=AAAAAAAAAAAAAAAAAAAAAA==", ["AAAAAAAAAAAAAAAAAAAAAA"]),
    ("a maps link with the pair as a query", "https://maps.google.com/?q=45.4642110,9.1899820", ["45.4642110", "9.1899820"]),
    ("a negative pair across the antimeridian", "pos -33.868820,-151.209290", ["-33.868820", "-151.209290"]),
]
for name, line, needles in EXTRA:
    out = shipped(line, "chat")
    leaked = [needle for needle in needles if needle in out]
    check(name, not leaked, "survived: %r in %r" % (leaked, out))

print("=== benign lines keep their numbers")
BENIGN = [
    "loss=1% lat=12ms jitter=3ms",
    "version 1.0.1223 build 4821",
    "latency=12 accept=1",
    "location accuracy granted",
    "ice connected role=caller retries=2",
    "rekey ok ctr=14",
    "call started 12:30:45 duration 3600",
]
for line in BENIGN:
    check("unchanged: " + line, m._scrub_location(line) == line, m._scrub_location(line))

print("")
if failures:
    print("RESULT: FAIL (%d)" % len(failures))
    for name in failures:
        print("  - " + name)
    sys.exit(1)
print("RESULT: PASS")
sys.exit(0)
