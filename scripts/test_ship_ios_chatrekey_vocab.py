#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The chat session update line must survive the phone-log shipper (scripts/ship-ios-logs.py) VERBATIM, and only that exact
grammar:

    CHAT-REKEY <held|applied|applied_release|discarded|buffer_drop>

Run:  python scripts/test_ship_ios_chatrekey_vocab.py [path/to/ship-ios-logs.py]
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


REAL = "CHAT-REKEY applied_release"
OKAY = ["CHAT-REKEY %s" % w for w in ("held", "applied", "applied_release", "discarded", "buffer_drop")]

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
    REAL.replace("CHAT-REKEY", "chat-rekey"),
    REAL.replace("CHAT-REKEY", "CHAT-REKEYX"),
    REAL.replace("CHAT-REKEY", "CHAT-REKEY v=1"),
    REAL.replace("applied_release", "applied_releasex"),
    REAL.replace("applied_release", "APPLIED"),
    REAL.replace("applied_release", ""),
    REAL.replace("applied_release", "applied,held"),
    REAL.replace("applied_release", "alice"),
    REAL + " dGhpcyBpcyBhIHNlY3JldCBibG9iIQ==",
    "CHAT-REKEY " + "a" * 200,
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
