#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
W-FALLBACKLATCH (2026-10-03) -- the SRTP-fallback latch log lines of CallService
must survive the phone-log shipper's vocabulary gate (scripts/ship-ios-logs.py).

Field evidence: the whole `audiosrtpfb ...` family was absent from Loki. The bare
word "audiosrtpfb" is 11 letters, not vocabulary and longer than UNKNOWN_MAX_LEN, so
each line failed the structured gate and was dropped, and the diagnosis of a call
silenced by a stale latch had no engage/reset line to read.

Run:  python scripts/test_ship_ios_fallbacklatch_vocab.py [path/to/ship-ios-logs.py]
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


# Every shape CallService emits for the latch (RTLog tag "call"). Keep in sync with
# CallService.engageAudioSrtpFallback / recoverAudioSrtpFallback / teardownAudioStack /
# activateIncomingCallAudio.
LINES = [
    "audiosrtpfb engage=1",
    "audiosrtpfb engage=0 why=2",
    "audiosrtpfb engage=0 why=3",
    "audiosrtpfb recover=1",
    "audiosrtpfb reset=1",
    "audiosrtpfb admreset=1 wedges=2",
    "audiosrtpfb latch=0 stale=1",
    "audiosrtpfb split=1",
    "audiosrtpfb split=2",
    "audiosrtpfb split=3",
]

failures = []
for line in LINES:
    got = red(line)
    if got != line:
        failures.append("%r -> %r" % (line, got))

# The vocabulary must not have become a free pass: an unrelated long word next to the
# new one is still masked / the line still goes through the gate.
leak = red("audiosrtpfb engage=1 zorkblatfoo=1 quuxwibblez=2")
if "zorkblatfoo" in leak and "quuxwibblez" in leak:
    failures.append("unknown words ride the new vocabulary: %r" % leak)

print("checks: %d, failures: %d" % (len(LINES) + 1, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
