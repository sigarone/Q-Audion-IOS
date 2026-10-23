#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Group call promotion and admission -- the numeric phone-log lines of the ring, the lone-call timer, the admission
question, the hand-over phases and the group audio unit driver must survive the phone-log shipper's vocabulary gate
(scripts/ship-ios-logs.py): the redactor is a fail-closed allow-list, and a body with one unknown word too many is
replaced by an attribute-only summary, i.e. lost.

The lines below are the exact shapes the pure builders in QAudionEngine/GroupCall/GroupDiagnostics.swift produce. They
are pinned by GroupPromotionDiagnosticsTests.swift too; this test reads that file and checks every `grp ...` line pinned
there as well, so the two cannot drift.

Run:  python scripts/test_ship_ios_grppromo_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every line ships verbatim; 1 = at least one was dropped or altered.
"""
import importlib.util
import os
import re
import sys
import types


def load(path):
    if "paramiko" not in sys.modules:
        try:
            import paramiko  # noqa: F401
        except ImportError:
            sys.modules["paramiko"] = types.ModuleType("paramiko")
    spec = importlib.util.spec_from_file_location("ship_ios_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ship_ios_under_test"] = mod
    spec.loader.exec_module(mod)
    return mod


HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "ship-ios-logs.py")
SWIFT_TEST = os.path.join(HERE, "..", "QAudionEngine", "Tests", "QAudionEngineTests", "GroupCall",
                          "GroupPromotionDiagnosticsTests.swift")
m = load(TARGET)


def red(line, tag="call"):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


def tag_of(line):
    return "group" if line.startswith("grp ") else "call"


LINES = [
    # ring: shown, busy drop (1:1 / group), local timeout, declined, ended by the server (alone), auto-join, accepted.
    "grp ring phase=1 code=0",
    "grp ring phase=2 code=1",
    "grp ring phase=2 code=3",
    "grp ring phase=3 code=0",
    "grp ring phase=4 code=0",
    "grp ring phase=5 code=5",
    "grp ring phase=6 code=0",
    "grp ring phase=7 code=0",
    # lone-call timer: armed, cancelled, left, ended.
    "grp alone phase=1 ms=50000",
    "grp alone phase=2 ms=50000",
    "grp alone phase=3 ms=50000",
    "grp alone phase=4 ms=50000",
    # ringing list size, admission question, leaving the group.
    "grp ringing n=2 roster=1",
    "grp ringing n=0 roster=3",
    "grp busy why=1 roster=3",
    "grp busy why=4 roster=1",
    "grp end why=1 role=1",
    "grp end why=3 role=0",
    # group audio unit driver.
    "grp audio phase=1 shared=1",
    "grp audio phase=2 shared=0",
    "grp audio phase=3 shared=1",
    "grp audio phase=4 shared=0",
    # hand-over phases added by this change.
    "grp swap phase=6 ms=120",
    "grp swap phase=7 ms=2400",
    "grp swap phase=10 ms=30000",
    "grp swap phase=11 ms=900",
    # more ways out of a group (hang-up, aborted promotion, roster mismatch, media never up) and the withdrawn question.
    "grp end why=5 role=1",
    "grp end why=6 role=0",
    "grp end why=7 role=0",
    "grp end why=8 role=1",
    "grp busy why=5 roster=2",
    "grp busy why=6 roster=2",
    # the signed promotion token: sent (not sent / sent / sent again), received (stored / dropped / stored evicting),
    # the auto-join decision (join, hold, ring, convert, fallback) and the roster rule.
    "grp promo tx=0 n=2",
    "grp promo tx=1 n=2",
    "grp promo tx=2 n=63",
    "grp promo rx=1 ok=1 code=0",
    "grp promo rx=1 ok=0 code=8",
    "grp promo rx=1 ok=0 code=15",
    "grp promo rx=1 ok=1 code=16",
    "grp promo dec=1 why=1",
    "grp promo dec=2 why=2",
    "grp promo dec=2 why=3",
    "grp promo dec=3 why=9",
    "grp promo dec=4 why=1",
    "grp promo dec=5 why=10",
    "grp promo roster=0 n=1",
    # tag "call": the audio-unit gate leaves a unit a live group holds, the refused 1:1 audio start.
    "admgate audit=1 held=1 grp=1",
    "audioIO skip=1 gate=1 nat=1 en=0",
    "audioIO skip=1 gate=1 nat=0 en=1",
]

failures = []
checked = 0
for line in LINES:
    checked += 1
    got = red(line, tag_of(line))
    if got != line:
        failures.append("%r -> %r" % (line, got))

# The lines pinned by the Swift tests ship verbatim too.
pinned = []
if os.path.isfile(SWIFT_TEST):
    with open(SWIFT_TEST, encoding="utf-8") as handle:
        text = handle.read()
    pinned = re.findall(r'"((?:grp (?:ring|alone|ringing|busy|end|audio|swap|promo)|audioIO skip)[^"\\]*)"', text)
    # Only complete lines: a literal that is just a prefix of a line is not a line.
    pinned = [p for p in pinned if re.search(r"\w=\d", p)]
if len(pinned) < 20:
    failures.append("the Swift tests pin only %d lines (expected at least 20): did the file move?" % len(pinned))
for line in pinned:
    checked += 1
    got = red(line, tag_of(line))
    if got != line:
        failures.append("pinned in GroupPromotionDiagnosticsTests.swift: %r -> %r" % (line, got))

# The new vocabulary must not have become a free pass: unrelated words next to the new ones still go through the gate.
for leak_line in ("grp promo zorkblatfoo=1 quuxwibblez=2",
                  "grp promo the user typed something private here",
                  "grp alone zorkblatfoo=1 quuxwibblez=2",
                  "grp ring zorkblatfoo=1 quuxwibblez=2 phase=1",
                  "grp end why=1 zorkblatfoo=1 quuxwibblez=2",
                  "grp alone the user typed something private here"):
    checked += 1
    leak = red(leak_line, "group")
    if "zorkblatfoo" in leak and "quuxwibblez" in leak or "private" in leak:
        failures.append("unknown words ride the new vocabulary: %r" % leak)

print("checks: %d, failures: %d" % (checked, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
