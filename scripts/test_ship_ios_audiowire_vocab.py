#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Audio wire shape -- the audio-wire log lines must survive the phone-log shipper's vocabulary gate
(scripts/ship-ios-logs.py): the redactor is a fail-closed allow-list, and a body with one unknown word too many is
replaced by an attribute-only summary, i.e. lost.

The lines below are the exact shapes the pure builders in QAudionEngine/Diagnostics/AudioWireLines.swift and
GroupCall/GroupDiagnostics.swift produce. They are pinned by AudioWireLinesTests.swift too; this test reads that file
and checks every line pinned there as well, so the two cannot drift.

Run:  python scripts/test_ship_ios_audiowire_vocab.py [path/to/ship-ios-logs.py]
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
SWIFT_TEST = os.path.join(HERE, "..", "QAudionEngine", "Tests", "QAudionEngineTests", "Diagnostics", "AudioWireLinesTests.swift")
m = load(TARGET)


def red(line, tag="call"):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


def tag_of(line):
    return "group" if line.startswith("grp ") else "call"


LINES = [
    # window line: a quiet window, a window with padding-only packets, a probe burst, a window with a missing field.
    "audiowire win_ms=5000 tx_pkts=83 tx_bytes=22410 tx_hdr_bytes=996 tx_retx_pkts=0 rx_pkts=83 rx_bytes=22410",
    "audiowire win_ms=5012 tx_pkts=123 tx_bytes=22680 tx_hdr_bytes=1968 tx_retx_pkts=2 rx_pkts=84 rx_bytes=22680",
    "audiowire win_ms=5003 tx_pkts=408 tx_bytes=22680 tx_hdr_bytes=6528 tx_retx_pkts=0 rx_pkts=84 rx_bytes=22680",
    "audiowire win_ms=5000 tx_bytes=20000 tx_retx_pkts=0 rx_pkts=83 rx_bytes=22000",
    # codec line: the policy, a negotiation that still carries the extensions, a stack without the policy.
    "audiowire codec ptime=60 minptime=60 maxptime=60 cbr=1 fec=1 dtx=0 maxavg=32000 stereo=0 alevel=0 tcc=0",
    "audiowire codec ptime=60 minptime=60 maxptime=60 cbr=1 fec=1 dtx=0 maxavg=32000 stereo=0 alevel=1 tcc=1",
    "audiowire codec minptime=10 cbr=0 fec=0 dtx=0 stereo=0 alevel=0 tcc=0",
    # sender parameters read back, group publisher.
    "audiosrtp cap n=1 min=32000 max=32000 apt=0 prio=4 ok=1 src=1",
    "audiosrtp cap n=1 min=32000 max=32000 apt=0 prio=4 ok=1 src=4",
    "audiosrtp cap n=0 ok=0 src=2",
    "grp audio cap n=1 min=32000 max=32000 apt=0 ok=1",
    "grp audio cap n=1 min=0 max=0 apt=0 ok=0",
    "grp audio cap n=0 min=0 max=0 apt=0 ok=0",
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
    pinned = re.findall(r'"((?:audiowire|audiosrtp cap|grp audio cap)[^"\\]*)"', text)
    # Only complete lines: a literal that is just a prefix of a line (hasPrefix checks) is not a line.
    pinned = [p for p in pinned if re.search(r"\w=\d", p)]
if len(pinned) < 10:
    failures.append("the Swift tests pin only %d lines (expected at least 10): did the file move?" % len(pinned))
for line in pinned:
    checked += 1
    got = red(line, tag_of(line))
    if got != line:
        failures.append("pinned in AudioWireLinesTests.swift: %r -> %r" % (line, got))

# The vocabulary must not have become a free pass: unrelated words next to the new ones still go through the gate.
for leak_line in ("audiowire codec zorkblatfoo=1 quuxwibblez=2 cbr=1",
                  "audiowire win_ms=5000 zorkblatfoo=1 quuxwibblez=2",
                  "audiosrtp cap n=1 zorkblatfoo=1 quuxwibblez=2"):
    checked += 1
    leak = red(leak_line)
    if "zorkblatfoo" in leak and "quuxwibblez" in leak:
        failures.append("unknown words ride the new vocabulary: %r" % leak)

print("checks: %d, failures: %d" % (checked, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
