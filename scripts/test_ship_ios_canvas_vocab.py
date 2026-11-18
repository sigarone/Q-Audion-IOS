#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The secure canvas log lines (ScreenshotLockService.swift, PrivacyShield.swift) must survive the phone-log shipper's vocabulary
gate (scripts/ship-ios-logs.py). The word "callhold" is shipper vocabulary; without it the structured gate drops
every line and a hold leaves no trace.

Run:  python scripts/test_ship_ios_canvas_vocab.py [path/to/ship-ios-logs.py]
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


def red(line, tag="privacy"):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


# Every shape the secure canvas code writes (RTLog tag "privacy").
LINES = [
    "canvas hosted=1",
    "canvas hosted=0 why=1",
    "capcover shown=1",
    "capcover shown=0",
    "canvas hosted=0 own=1 display=0",
    "canvas hosted=1 own=1 display=0",
    "canvas hosted=1 own=1 display=1",
    "canvas hosted=1 own=0 display=0",
    "canvas hosted=0 own=2 display=0",
    "canvas hosted=1 own=2 display=1",
]

# The "call" lines of the screen share (AppState.swift) and of the encoder session (VideoCallPipeline.swift).
CALL_LINES = [
    "vcap capture end=1 why=1",
    "vcap capture end=1 why=2",
    "vcap capture end=1 why=4",
    "vcap encfail st=-12903 ask=1 rec=1 code=0",
    "vcap encfail st=-12903 ask=1 rec=0 code=-12908",
]

failures = []
for line in LINES:
    got = red(line)
    if got != line:
        failures.append("%r -> %r" % (line, got))
for line in CALL_LINES:
    got = red(line, "call")
    if got != line:
        failures.append("%r -> %r" % (line, got))

if failures:
    print("FAIL: %d secure canvas line(s) dropped or altered by the shipper:" % len(failures))
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("OK: %d secure canvas and share lines ship verbatim" % (len(LINES) + len(CALL_LINES)))
