#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
W-DTLSWAIT (2026-10-07) -- the `dtls wait` line of the DTLS handshake wait must survive the phone-log shipper's
vocabulary gate (scripts/ship-ios-logs.py) VERBATIM: it is the only record of what the candidate pair and the DTLS
byte counters were doing during a call whose ICE came up but whose DTLS never finished. The redactor is a fail-closed
allow-list: at most 2 unknown words per body (a body over budget is dropped whole), at most 2 numbers of 6+ digits,
and an UNPROTECTED key=value token of 12 or more characters is masked as a blob (`cps=succeeded`, `cps=in-progress`
and `cps=checking` all were; only keys that name an enum, such as `state=`, are protected for a longer word).

The lines below are the exact shape `DtlsWaitLine.format` builds (QAudionEngine/Diagnostics/DtlsWaitLine.swift, pinned
by DtlsWaitLineTests.swift in the engine), logged through RTLog.info("call", ...) and, for safety, also through the
stdout tee. Besides the hard-coded cases this script reads every `"dtls wait ..."` literal out of the Swift test, so
the two cannot drift apart, and walks the whole closed word space of the line at its extreme numbers.

Run:  python scripts/test_ship_ios_dtlswait_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every line ships verbatim; 1 = at least one was dropped or altered.
"""
import importlib.util
import itertools
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
SWIFT_TEST = os.path.join(HERE, "..", "QAudionEngine", "Tests", "QAudionEngineTests", "Diagnostics",
                          "DtlsWaitLineTests.swift")
m = load(TARGET)


def shipped(line, tag="call"):
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


def line(count, ms, lct, nt, rct, cps, sent, recv, state):
    # Same text as DtlsWaitLine.format; sent / recv None = the counter row is missing (omitted).
    out = "dtls wait count=%d ms=%d lct=%s nt=%d rct=%s cps=%s" % (count, ms, lct, nt, rct, cps)
    if sent is not None:
        out += " sent=%d" % sent
    if recv is not None:
        out += " recv=%d" % recv
    return out + " state=%s" % state


LINES = [
    line(1, 0, "host", 3, "host", "running", 0, 0, "connecting"),                  # first line of a call
    line(7, 6034, "relay", 1, "srflx", "ok", 123456, 789012, "connecting"),        # realistic, bytes both ways
    line(3, 2150, "host", 3, "host", "ok", 1420, 0, "connecting"),                 # the stalled shape
    line(2, 480, "prflx", 6, "prflx", "ok", 2210, 2046, "connected"),              # the line that ends it
    line(2, 1000, "none", 0, "none", "none", None, None, "none"),                  # nothing known yet
    line(4, 3000, "host", 2, "host", "waiting", 900, None, "new"),                 # one counter missing
    line(1, 0, "host", 0, "host", "frozen", 0, 0, "new"),
    line(20, 99999, "relay", 4, "relay", "failed", 9999999, 9999999, "failed"),    # the capped extremes
    line(5, 4000, "other", 5, "other", "cancel", 0, 0, "closed"),
]

failures = []
checks = 0


def must_ship(text, why=""):
    global checks
    for tag in ("call", "stdout"):
        checks += 1
        got = shipped(text, tag)
        if got != text:
            failures.append("[%s] %s%r -> %r" % (tag, why, text, got))


for text in LINES:
    must_ship(text)

# Every literal the Swift test pins must ship too (so a new case there is covered here without editing this file).
if os.path.exists(SWIFT_TEST):
    src = open(SWIFT_TEST, encoding="utf-8").read()
    pinned = sorted(set(re.findall(r'"(dtls wait [^"]*)"', src)))
    if len(pinned) < 8:
        failures.append("expected at least 8 pinned lines in DtlsWaitLineTests.swift, found %d" % len(pinned))
    for text in pinned:
        must_ship(text, "swift-pinned ")
else:
    failures.append("missing %s" % SWIFT_TEST)

# The closed word space, at the widest numbers: 8 x 7 x 6 x 6 combinations of pair state / DTLS state / types.
TYPES = ["host", "srflx", "prflx", "relay", "none", "other"]
PAIR = ["frozen", "waiting", "running", "ok", "failed", "cancel", "other", "none"]
DTLS = ["new", "connecting", "connected", "closed", "failed", "other", "none"]
for lct, rct, cps, state in itertools.product(TYPES, TYPES, PAIR, DTLS):
    must_ship(line(20, 99999, lct, 6, rct, cps, 9999999, 9999999, state), "grid ")

# The premises behind the word choices: these forms were masked or dropped. If one of them starts to ship, the
# shortening in DtlsWaitLine.pairStateWord may be relaxed; until then keep it.
for bad in ("dtls wait count=1 ms=0 lct=host nt=3 rct=host cps=succeeded sent=0 recv=0 state=connecting",
            "dtls wait count=1 ms=0 lct=host nt=3 rct=host cps=in-progress sent=0 recv=0 state=connecting",
            "dtls wait count=1 ms=0 lct=host nt=3 rct=host cps=cancelled sent=0 recv=0 state=connecting",
            # three numbers of 6+ digits: why ms and the byte counters are capped
            "dtls wait count=20 ms=123456 lct=relay nt=6 rct=relay cps=waiting sent=234567 recv=345678 "
            "state=connecting"):
    checks += 1
    if shipped(bad) == bad:
        failures.append("premise changed, the old form now ships: %r (re-check DtlsWaitLine)" % bad)

print("checks: %d, failures: %d" % (checks, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
