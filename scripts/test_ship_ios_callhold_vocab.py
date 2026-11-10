#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The call hold log lines (WIRE_SPEC 16; CallHoldController.swift) must survive the phone-log shipper's vocabulary
gate (scripts/ship-ios-logs.py). The word "callhold" is shipper vocabulary; without it the structured gate drops
every line and a hold leaves no trace.

Run:  python scripts/test_ship_ios_callhold_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = all lines ship verbatim; 1 = at least one was dropped or altered.
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


def red(line, tag="call"):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


# Every shape CallHoldController.swift writes (RTLog tag "call").
LINES = [
    "callhold tx st=1 c=1 seq=7 m=1",
    "callhold tx st=2 c=2 seq=8 m=2",
    "callhold tx st=1 c=3 seq=65535 m=3",
    "callhold rx st=1 c=1 seq=7 ap=1",
    "callhold rx st=2 c=0 seq=7 ap=0",
    "callhold ackrx=1 seq=7",
    "callhold acktx=1 seq=7 leg=1",
    "callhold acktx=1 seq=7 leg=2",
    "callhold unacked=1 seq=7",
    "callhold expiry=1",
    "callhold clear=1 why=1",
    "callhold hint=1",
    "callhold hint=0",
    "callhold tone=1",
]

failures = []
for line in LINES:
    got = red(line)
    if got != line:
        failures.append("%r -> %r" % (line, got))

if failures:
    print("FAIL: %d call hold line(s) dropped or altered by the shipper:" % len(failures))
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("OK: %d call hold lines ship verbatim" % len(LINES))
