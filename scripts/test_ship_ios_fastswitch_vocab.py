#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Network-switch timing lines -- the call lines that measure how fast a media switch completes after a network change must
survive the phone-log shipper's vocabulary gate (scripts/ship-ios-logs.py), which is a fail-closed allow-list.

The shapes below are the ones QAudionWebRtcCallController logs (closed vocabulary, numbers and 0/1 flags only, no ids).

Run:  python scripts/test_ship_ios_fastswitch_vocab.py [path/to/ship-ios-logs.py]
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


HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "ship-ios-logs.py")
m = load(TARGET)


def red(line, tag="call"):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


LINES = [
    "restart_ice fast=1 probe=0 cached=1",
    "restart_ice fast=1 fallback=1 probe=1",
    "restart_ice fast=1 trig_sent_ms=1234",
    "restart_ice fast=0 trig_sent_ms=4800",
    "restart_ice fast=1 trig_rx_ms=2345",
    "restart_ice fast=0 trig_rx_ms=3600",
    "route tier=0",
    "route tier=1",
]

failures = []
for line in LINES:
    got = red(line)
    if got != line:
        failures.append("%r -> %r" % (line, got))

for leak_line in ("restart_ice fast=1 zorkblatfoo=1 quuxwibblez=2",
                  "restart_ice trig_sent_ms=5 zorkblatfoo=1 quuxwibblez=2"):
    leak = red(leak_line)
    if "zorkblatfoo" in leak and "quuxwibblez" in leak:
        failures.append("unknown words ride the new vocabulary: %r" % leak)

# The words live in the scoped FASTSWITCH_FORMAT_VOCAB only: not in the global vocabularies, and still unknown in
# any line that is not one of the exact call shapes (other tag, other shape, extra token).
for word in ("fast", "fallback", "probe", "prime"):
    if word in m.APP_VOCAB or word in m.TELEMETRY_VOCAB:
        failures.append("%r leaked into the global vocabulary" % word)
unrelated = [
    ("fast fallback probe retry handshake started", "call"),
    ("fast fallback probe retry handshake started", "chat"),
    ("restart_ice fast=1 fallback=1 probe=1 zorkblatfoo", "call"),
    ("restart_ice fast=1 fallback=1 probe=1", "chat"),
    ("fast=1 fallback=1 probe=1", "call"),
    ("restart_ice fast=1 trig_sent_ms=12 fallback fast probe", "call"),
]
for line, tag in unrelated:
    got = red(line, tag)
    if line in got and tag == "call" and line.startswith("restart_ice fast=1 fallback=1 probe=1") and "zork" not in line:
        continue  # the exact scoped line is allowed only under the call tag
    if any(w in got.split() for w in ("fast", "fallback", "probe")) and "=" not in got.split()[0]:
        failures.append("scoped word shipped in an unrelated line: %r (%s) -> %r" % (line, tag, got))
    if "zorkblatfoo" in got:
        failures.append("unknown word shipped next to the scoped line: %r -> %r" % (line, got))

print("checks: %d, failures: %d" % (len(LINES) + 2 + 4 + len(unrelated), len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
