#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The microphone permission log lines of MicrophonePermission.swift
must survive the phone-log shipper's vocabulary gate (scripts/ship-ios-logs.py).

The word "micperm" and the keys "st" and "ask" are shipper vocabulary; without them the
structured gate drops the lines and a call without a microphone leaves no trace.

Run:  python scripts/test_ship_ios_micperm_vocab.py [path/to/ship-ios-logs.py]
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


# Every shape MicrophonePermission.swift writes (RTLog tag "call"): st = 0 undetermined, 1 denied, 2 granted;
# src = 1 dial, 2 answer, 3 foreground, 4 call-screen button, 5 first-use screen.
LINES = [
    "micperm st=0 src=3",
    "micperm st=1 src=1",
    "micperm st=2 src=4",
    "micperm ask=1 src=2",
    "micperm restart=1 src=3",
]

failures = []
for line in LINES:
    got = red(line)
    if got != line:
        failures.append("%r -> %r" % (line, got))

leak = red("micperm st=2 zorkblatfoo=1 quuxwibblez=2")
if "zorkblatfoo" in leak and "quuxwibblez" in leak:
    failures.append("unknown words ride the new vocabulary: %r" % leak)

print("checks: %d, failures: %d" % (len(LINES) + 1, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
