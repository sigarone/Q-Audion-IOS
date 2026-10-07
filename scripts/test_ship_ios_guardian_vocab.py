#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
W-GUARDIAN1CONTIG (2026-10-07) -- the Tier 1 guardian diagnostic line must survive the phone-log shipper's
vocabulary gate (scripts/ship-ios-logs.py) VERBATIM: it is the only measurement of the AASIST inference time on a
real phone. The redactor is a fail-closed allow-list (at most 2 unknown words per body); a body over budget is
dropped whole, and a 12-letter word such as "GuardianMode" matches the base64-blob rule.

The lines below are the exact shape `GuardianMode.diagnosticLine` builds (pinned by GuardianTier1ContiguityTests in
the engine), printed through the stdout tee (tag "stdout"), at realistic and at extreme values. Keep in sync.

Run:  python scripts/test_ship_ios_guardian_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every line ships verbatim; 1 = at least one was dropped or altered.
"""
import importlib.util
import os
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


TARGET = (sys.argv[1] if len(sys.argv) > 1 else
          os.path.join(os.path.dirname(os.path.abspath(__file__)), "ship-ios-logs.py"))
m = load(TARGET)


def shipped(line, tag="stdout"):
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


def line(count, ms, windows, skipped, dropped, nil):
    # Same text as GuardianMode.diagnosticLine.
    return ("[Guardian] count=%d ms=%d windows=%d skipped=%d dropped=%d nil=%d"
            % (count, ms, windows, skipped, dropped, nil))


LINES = [
    line(1, 85, 1, 0, 0, 0),          # first inference
    line(10, 412, 19, 9, 0, 0),       # every 10th
    line(0, 3, 1, 0, 0, 1),           # first nil score (model error): count stays 0
    line(0, 2, 199, 99, 0, 100),      # a Tier 1 that never scores
    line(12345, 9999, 99999, 99999, 999, 9999),
]

failures = []
for text in LINES:
    for tag in ("stdout", "call"):
        got = shipped(text, tag)
        if got != text:
            failures.append("[%s] %r -> %r" % (tag, text, got))

# The first form of the line was dropped whole; keep the reason visible if someone brings it back.
if shipped("[GuardianMode] tier1 inf n=1 ms=85 windows=1 dropped=0 nil=0") is not None:
    failures.append("the old form now ships: re-check this test's premise")

print("checks: %d, failures: %d" % (len(LINES) * 2 + 1, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
