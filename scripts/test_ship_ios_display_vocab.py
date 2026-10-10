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

failures = []
for text in LINES:
    got = shipped(text)
    if got != text:
        failures.append("%r -> %r" % (text, got))
for text in CADENCE_LINES:
    for tag in ("stdout", "call"):
        got = shipped(text, tag)
        if got != text:
            failures.append("[%s] %r -> %r" % (tag, text, got))

print("checks: %d, failures: %d" % (len(LINES) + 2 * len(CADENCE_LINES), len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
