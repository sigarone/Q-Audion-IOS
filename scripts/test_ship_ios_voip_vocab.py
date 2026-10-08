#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
W-VOIPSYNC (2026-10-08) -- the `voip` diagnostic lines of the PushKit path must survive the phone-log shipper's
vocabulary gate (scripts/ship-ios-logs.py) VERBATIM. They are what tells, in one read of the crash ring, why PushKit
killed the app after a VoIP push ("Killing app because it never posted an incoming call...", incidents b0d7ba30 and
eb2a6367 of 2026-10-07): no `voip rx` = PushKit never called the delegate, `owner=0` = the provider was gone, `init`
above 1 = a second registration, `rx` without `report` = killed while CallKit had the report. A line the redactor
drops or rewrites would leave that question open again.

The lines below are the exact shapes `VoipPushDiagnostics` builds (pinned by VoipPushSyncReportTests in the engine),
logged through RTLog with tag "call", at realistic and at extreme values. Keep the three in sync.

Run:  python scripts/test_ship_ios_voip_vocab.py [path/to/ship-ios-logs.py]
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


# Same text as VoipPushDiagnostics in QAudionEngine/Sources/QAudionEngine/Integration/PushKitProvider.swift.
def rx(kind, owner, init, state, id8=None):
    line = "voip rx kind=%d owner=%d init=%d state=%d" % (kind, 1 if owner else 0, init, state)
    return line + (" call8=" + id8 if id8 else "")


def init(count, site):
    return "voip init count=%d site=%d" % (count, site)


def report(kind, ok, code, dup, ms, id8=None):
    line = "voip report kind=%d ok=%d code=%d dup=%d ms=%d" % (kind, 1 if ok else 0, code, 1 if dup else 0, ms)
    return line + (" call8=" + id8 if id8 else "")


def done(kind, ok, ms):
    return "voip done kind=%d ok=%d ms=%d" % (kind, 1 if ok else 0, ms)


def late(kind, ms):
    return "voip late kind=%d ms=%d" % (kind, ms)


LINES = [
    # first line of the PushKit callback
    rx(1, True, 1, 2, "b0d7ba30"),           # 1:1 push to a suspended app
    rx(4, True, 1, 2, "eb2a6367"),           # cancel push
    rx(2, True, 1, 0, "1bc455b8"),           # group push, foreground
    rx(3, True, 1, 2),                       # opaque wake: no id
    rx(0, False, 2, 2),                      # unparsed, no owner, second registration
    rx(1, False, 99999, 1, "00000000"),       # all digits: `id=` would be masked as a phone number
    rx(4, True, 1, 2, "ffffffff"),
    # registrations
    init(1, 1), init(1, 2), init(2, 2), init(99999, 1),
    "voip init skip=1 site=2",               # VoipPushDiagnostics.initSkippedLine()
    "voip init count=0 site=1",              # VoipPushDiagnostics.initNoReporterLine()
    # CallKit's answer
    report(1, True, 0, False, 40, "b0d7ba30"),
    report(4, True, 0, False, 61, "eb2a6367"),
    report(1, False, 3, False, 120, "b0d7ba30"),    # Focus / DnD
    report(1, False, 2, True, 5, "b0d7ba30"),       # duplicate of a WS report
    report(0, True, 0, False, 75, "0755614e"),      # placeholder
    report(2, False, 99999, True, 9999999, "abcdef01"),
    # before PushKit's completion
    done(1, True, 75), done(4, False, 3), done(0, True, 9999999),
    # CallKit silent for too long
    late(1, 2000), late(4, 2000), late(0, 2000),
]

failures = []
for text in LINES:
    got = shipped(text, "call")
    if got != text:
        failures.append("[call] %r -> %r" % (text, got))

# A first draft used words the gate does not know ("pushkit", "reg", "app"): three unknown words drop the body whole.
if shipped("pushkit rx kind=1 owner=1 reg=1 init=1 app=2") is not None:
    failures.append("the rejected draft now ships: re-check this test's premise")

print("checks: %d, failures: %d" % (len(LINES) + 1, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
