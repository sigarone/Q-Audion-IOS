#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The display-work marker lines (DisplayWorkMarker.line in QAudionEngine) must survive the phone-log shipper's
vocabulary gate (scripts/ship-ios-logs.py) VERBATIM, under the "call" tag: they are what tells "display-only call
work paused in the background" (bg=1) from "ran and measured zero" in a call's log. Keep in sync with
DisplayWorkMarker and BackgroundDisplayWorkTests.

The same gate covers the check-period lines of the contact-voice check (ContactVoiceVerifier.cadenceLine, printed
through the stdout tee, tag "stdout"): they say which period is active ("[Voice] bg=1 every=10"). Keep in sync with
ContactVoiceVerifier.cadenceLine and BackgroundCadenceTests.

And the CPU-governor summary lines (BackgroundCpuGovernor.Summary.logLine, same stdout tee): the measured average
CPU as a percentage of one core, the checks skipped and run since the previous summary, and whether checks are
being held back ("[Voice] bg=1 every=10 cpu=42 skip=3 run=2 high=0", "[Guardian] bg=1 cpu=250 skip=0 run=7 high=1").
Keep in sync with BackgroundCpuGovernor and BackgroundCpuGovernorTests.

Run:  python scripts/test_ship_ios_display_vocab.py [path/to/ship-ios-logs.py]
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


def shipped(line, tag="call"):
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


LINES = ["display bg=1", "display bg=0"]

# Same text as ContactVoiceVerifier.cadenceLine (whole seconds), shipped under the stdout tee's tag.
CADENCE_LINES = ["[Voice] bg=1 every=10", "[Voice] bg=0 every=3", "[Voice] bg=1 every=12", "[Voice] bg=1 every=9"]

GOVERNOR_LINES = [
    "[Voice] bg=1 every=10 cpu=42 skip=3 run=2 high=0",
    "[Voice] bg=1 every=10 cpu=90 skip=1 run=2 high=1",
    "[Voice] bg=0 every=3 cpu=30 skip=0 run=1 high=0",
    "[Voice] bg=1 every=10 cpu=0 skip=0 run=3 high=0",
    "[Voice] bg=1 every=12 cpu=9999 skip=9999 run=9999 high=1",
    "[Guardian] bg=1 cpu=250 skip=0 run=7 high=1",
    "[Guardian] bg=1 cpu=48 skip=2 run=1 high=0",
    "[Guardian] bg=0 cpu=30 skip=0 run=1 high=0",
]

failures = []
for text in LINES:
    got = shipped(text)
    if got != text:
        failures.append("%r -> %r" % (text, got))
for text in CADENCE_LINES + GOVERNOR_LINES:
    for tag in ("stdout", "call"):
        got = shipped(text, tag)
        if got != text:
            failures.append("[%s] %r -> %r" % (tag, text, got))

print("checks: %d, failures: %d" % (len(LINES) + 2 * len(CADENCE_LINES + GOVERNOR_LINES), len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
