#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The per-call key bookkeeping lines (QAudionEngine, written through CapsBindLog.line to RTLog.info("call", ...)) must survive the
phone-log shipper (scripts/ship-ios-logs.py) VERBATIM, and only that exact grammar. Every value is a decimal number from a
closed range:

    live adopt gen=<n> role=<0|1> chain=<0|1> fk=<5|6>
    live close gen=<n> staged=<n> why=<1..4>
    live chain refuse round=<n> why=<1..7>
    live defer why=<1..3>
    live stage round=<n> chain=<0|1> staged=<n>
    live confirm round=<n> retained=<n>
    live fail round=<n>
    live offerer drop round=<n>
    live fk why=<1..3>
    capsbind ext=<0|1> own=<0|1> peer=<0|1> round=<n> chain=<0|1> fk=<0|1>

The generic gate gives bare words a budget of zero, so each shape is accepted by a whole-line rule. This test pins that the rule
is exactly that narrow.

Run:  python scripts/test_ship_ios_live_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every real line ships unchanged and every forged variant is refused; 1 otherwise.
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


def shipped(line, tag="call"):
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


OKAY = [
    "live adopt gen=1 role=0 chain=0 fk=5",
    "live adopt gen=123456789 role=1 chain=1 fk=6",
    "live close gen=7 staged=3 why=1",
    "live close gen=7 staged=16 why=4",
    "live chain refuse round=3 why=5",
    "live chain refuse round=2147483646 why=6",
    "live chain refuse round=2 why=7",
    "live defer why=1",
    "live defer why=3",
    "live stage round=2 chain=1 staged=2",
    "live stage round=0 chain=0 staged=1",
    "live confirm round=1 retained=2",
    "live fail round=4",
    "live offerer drop round=2",
    "live fk why=2",
    "capsbind ext=1 own=1 peer=1 round=1 chain=1 fk=0",
    "capsbind ext=0 own=0 peer=0 round=2147483646 chain=0 fk=0",
]

failures = []
checks = 0

for line in OKAY:
    for tag in ("call", "stdout"):
        checks += 1
        if red(line, tag) != line:
            failures.append("redact_body(%r, %r) -> %r" % (line, tag, red(line, tag)))
        checks += 1
        if shipped(line, tag) != line:
            failures.append("build_log_record(%r, %r) -> %r" % (line, tag, shipped(line, tag)))

# Scoped to the call / stdout tags: not a free pass under another tag.
for tag in ("chat", "net", "ice", "media", "crypto", "livelog"):
    for line in OKAY[:3]:
        checks += 1
        if red(line, tag) == line:
            failures.append("the rule leaked under tag %r: %r" % (tag, line))

FORGED = []
for base in OKAY:
    FORGED.append(base + " ")
    FORGED.append(base + "\n")
    FORGED.append(base + " extra=1")
    FORGED.append(base + " id=abc")
    FORGED.append(base + " cid=0a1b2c3d")
    FORGED.append(base + "0a")
    FORGED.append(base + " hello world")
    FORGED.append(" " + base)
    FORGED.append("x " + base)
    FORGED.append(base + "\n" + base)
    FORGED.append(base.upper())
FORGED += [
    "live adopt gen=1 role=2 chain=0 fk=5",
    "live adopt gen=1 role=0 chain=2 fk=5",
    "live adopt gen=1 role=0 chain=0 fk=7",
    "live adopt gen=a role=0 chain=0 fk=5",
    "live adopt gen=1234567890 role=0 chain=0 fk=5",
    "live adopt gen=1 role=0 chain=0 fk=5 gen=1",
    "live adopt role=0 gen=1 chain=0 fk=5",
    "live close gen=7 staged=123 why=1",
    "live close gen=7 staged=3 why=5",
    "live close gen=7 staged=3 why=0",
    "live chain refuse round=3 why=8",
    "live chain refuse round=3 why=0",
    "live chain refuse round=12345678901 why=1",
    "live chain refuse round=3 why=1 reason=chain_base",
    "live defer why=4",
    "live defer why=0",
    "live stage round=2 chain=1 staged=100",
    "live stage round=-1 chain=1 staged=1",
    "live confirm round=1 retained=100",
    "live confirm round=1",
    "live fail round=",
    "live fail round=1 why=1",
    "live offerer drop round=x",
    "live fk why=4",
    "live fk",
    "live",
    "live adopt",
    "live adopt gen=1 role=0 chain=0 fk=5 call=0a1b2c3d",
    "live adopt call=0a1b2c3d gen=1 role=0 chain=0 fk=5",
    "capsbind ext=1 own=1 peer=1 round=1 chain=1 fk=2",
    "capsbind ext=2 own=1 peer=1 round=1 chain=1 fk=1",
    "capsbind ext=1 own=1 peer=1 round=12345678901 chain=1 fk=1",
    "capsbind ext=1 own=1 peer=1 round=1 chain=1",
    "capsbind ext=1 own=1 peer=1 round=1 fk=1 chain=1",
    "peer said: live fail round=4",
    "live fail round=4​",
    "live  fail round=4",
    "Live fail round=4",
]
for line in FORGED:
    for tag in ("call", "stdout"):
        checks += 1
        if red(line, tag) == line:
            failures.append("forged line shipped verbatim: %r" % (line,))
        checks += 1
        if shipped(line, tag) == line:
            failures.append("forged line shipped verbatim by build_log_record: %r" % (line,))

print("%d checks, %d failures" % (checks, len(failures)))
for f in failures:
    print("FAIL:", f)
sys.exit(1 if failures else 0)
