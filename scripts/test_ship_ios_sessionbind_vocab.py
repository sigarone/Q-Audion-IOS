#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The session binding failure line must survive the phone-log shipper (scripts/ship-ios-logs.py) VERBATIM, and only that exact
grammar:

    SESSION-BIND write_failed slot=<cur|prev|rec>

Run:  python scripts/test_ship_ios_sessionbind_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every allowed line ships unchanged and every forged variant is refused; 1 otherwise.
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


REAL = "SESSION-BIND write_failed slot=rec"
OKAY = ["SESSION-BIND write_failed slot=%s" % slot for slot in ("cur", "prev", "rec")]

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

for tag in ("chat", "net", "ice", "media", "crypto", "livelog"):
    checks += 1
    if red(REAL, tag) == REAL:
        failures.append("the rule leaked under tag %r" % tag)

FORGED = [
    REAL + " ",
    REAL + "\n",
    REAL + " extra=1",
    REAL + " hello world",
    " " + REAL,
    "x " + REAL,
    REAL + "\n" + REAL,
    REAL.replace("SESSION-BIND", "session-bind"),
    REAL.replace("SESSION-BIND", "SESSION-BINDX"),
    REAL.replace("SESSION-BIND", "SESSION-BIND v=1"),
    REAL.replace("write_failed", "write_failedx"),
    REAL.replace("write_failed", "read_failed"),
    REAL.replace("slot=rec", "slot=cache"),
    REAL.replace("slot=rec", "slot=REC"),
    REAL.replace("slot=rec", "slot="),
    REAL.replace("slot=rec", "slot=rec,prev"),
    REAL.replace("slot=rec", "slot=alice"),
    REAL.replace(" slot=rec", ""),
    REAL.replace(" slot=rec", "  slot=rec"),
    REAL + " dGhpcyBpcyBhIHNlY3JldCBibG9iIQ==",
    "SESSION-BIND " + "a" * 200,
    REAL + "​",
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
