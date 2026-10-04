#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
CALL-METRICS (2026-10-04) -- the call-monitoring log lines of CallService (hb=1 / hb=2 / hb=3 and the audioroute line)
must survive the phone-log shipper's vocabulary gate (scripts/ship-ios-logs.py): the redactor is a fail-closed
allow-list, and a body with one unknown word too many is replaced by an attribute-only summary, i.e. lost.

The lines below are the exact shapes the pure builders in QAudionEngine/Diagnostics/CallMetrics.swift produce
(CallMetricsLines.hb2 / hb3, CallRouteDiagnostics.routeLine; the same strings are pinned by CallMetricsTests.swift),
at realistic and at extreme values. Keep in sync with those builders.

Run:  python scripts/test_ship_ios_callmetrics_vocab.py [path/to/ship-ios-logs.py]
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


def red(line, tag="call"):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


LINES = [
    # hb=1 in the sentinel-free form (a field is omitted when its stats row is missing). The long native tail (tsr=, dtls= ...)
    # is dropped by the 2-big-numbers budget on a real call, with or without this change: not covered here.
    "audiosrtp hb=1 outp=Receiver vol=100",
    "audiosrtp hb=1 tx=4760640 rx=4759290 ptx=26797 prx=17628 lost=0 jitter=1 outp=Receiver vol=100 rtt=7",
    "audiosrtp hb=1 ptx=312 prx=290 outp=BluetoothHFP vol=50 rtt=21",
    # hb=2: first heartbeat (nothing computable), a quiet one, and the spike case.
    "audiosrtp hb=2 relay=0 network_type=0",
    "audiosrtp hb=2 rtt=7 jitter_ms=77 target_ms=80 plc=0 fec_recv=44 fec_drop=45 nack=0 remote_loss=0 remote_rtt=20"
    " relay=0 network_type=1 rtt_max=12 jitter_max=3 rtt_remote_max=21 lost_max=0 plc_max=0 sample=5",
    "audiosrtp hb=2 rtt=337 jitter_ms=470 target_ms=455 plc=93600 fec_recv=83 fec_drop=2 nack=1 remote_loss=20"
    " remote_rtt=1734 relay=1 network_type=3 rtt_max=730 jitter_max=70 rtt_remote_max=1734 lost_max=12 plc_max=93600 sample=5",
    "audiosrtp hb=2 rtt=9 relay=0 network_type=1 rtt_max=9 sample=4",
    "audiosrtp hb=4 plc_silent_ms=4800 plc_hear_ms=20 plc_event=3",
    "audiosrtp hb=4 plc_event=0",
    # hb=3: native engine with the echo proxy, an empty bucket, the legacy engine.
    "audiosrtp hb=3 eng=1 vpio=1 duck=0 echo_act=120 echo_idle=380 echo_far=500"
    " echo_active_db=-23 echo_idle_db=-41 echo_suspect=1",
    "audiosrtp hb=3 eng=1 vpio=1 duck=0 echo_act=0 echo_idle=500 echo_far=0 echo_idle_db=-54 echo_suspect=0",
    "audiosrtp hb=3 eng=2 vpio=0 duck=1",
    # audioroute: Bluetooth hands-free at 16 kHz, loudspeaker, the call-start sample (no previous route), LE.
    "audioroute why=1 old=1 out=3 in=3 profile=1 sr=16000 out_ch=1 in_ch=1 vol=50",
    "audioroute why=2 old=3 out=2 in=1 profile=0 sr=48000 out_ch=2 in_ch=1 vol=75",
    "audioroute why=99 out=1 in=1 profile=0 sr=48000 out_ch=1 in_ch=1 vol=100",
    "audioroute why=1 old=1 out=3 in=3 profile=3 sr=24000 out_ch=1 in_ch=1 vol=30",
    "audioroute why=3 old=2 out=2 in=1 profile=0",
]

failures = []
for line in LINES:
    got = red(line)
    if got != line:
        failures.append("%r -> %r" % (line, got))

# The vocabulary must not have become a free pass: unrelated long words next to the new ones are still masked / the
# line still goes through the gate.
leak = red("audioroute why=1 zorkblatfoo=1 quuxwibblez=2")
if "zorkblatfoo" in leak and "quuxwibblez" in leak:
    failures.append("unknown words ride the new vocabulary: %r" % leak)
leak = red("audiosrtp hb=3 eng=1 zorkblatfoo=1 quuxwibblez=2")
if "zorkblatfoo" in leak and "quuxwibblez" in leak:
    failures.append("unknown words ride the hb=3 vocabulary: %r" % leak)

print("checks: %d, failures: %d" % (len(LINES) + 2, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
