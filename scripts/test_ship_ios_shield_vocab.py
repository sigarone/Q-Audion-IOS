#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The per-call shield state line must survive the phone-log shipper (scripts/ship-ios-logs.py) VERBATIM, and only that exact
grammar:

    QA-SHIELD call=<8 hex> id=<pending|verified|to_verify|changed> pq=<pending|pq2|pq|reduced|cl> max=<0|1>

Run:  python scripts/test_ship_ios_shield_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every allowed combination ships unchanged and every forged variant is refused; 1 otherwise.
"""
import importlib.util
import itertools
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


REAL = "QA-SHIELD call=0a1b2c3d id=verified pq=pq2 max=1"
OKAY = [
    "QA-SHIELD call=0a1b2c3d id=%s pq=%s max=%s" % combo
    for combo in itertools.product(("pending", "verified", "to_verify", "changed"),
                                   ("pending", "pq2", "pq", "reduced", "cl"), ("0", "1"))
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
    REAL.replace("QA-SHIELD", "qa-shield"),
    REAL.replace("QA-SHIELD", "QA-SHIELDX"),
    REAL.replace("QA-SHIELD", "QA-SHIELD v=1"),
    REAL.replace("call=0a1b2c3d", "call=0a1b2c3"),
    REAL.replace("call=0a1b2c3d", "call=0a1b2c3d4"),
    REAL.replace("call=0a1b2c3d", "call=0A1B2C3D"),
    REAL.replace("call=0a1b2c3d", "call=alice-bo"),
    REAL.replace("id=verified", "id=alice"),
    REAL.replace("id=verified", "id=VERIFIED"),
    REAL.replace("id=verified", "id="),
    REAL.replace("pq=pq2", "pq=pq3"),
    REAL.replace("pq=pq2", "pq=maybe"),
    REAL.replace("max=1", "max=2"),
    REAL.replace("max=1", "max=yes"),
    REAL.replace(" max=1", ""),
    REAL.replace(" id=verified", "  id=verified"),
    REAL.replace("id=verified pq=pq2", "pq=pq2 id=verified"),
    REAL + " dGhpcyBpcyBhIHNlY3JldCBibG9iIQ==",
    "QA-SHIELD " + "a" * 200,
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
