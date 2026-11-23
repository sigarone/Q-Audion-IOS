#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The line of the late check of a call's second handshake signature must survive the phone-log shipper
(scripts/ship-ios-logs.py) VERBATIM, and only that exact grammar (QAudionEngine PqLateVerifier / QAudionCallIntegration
pqLateSettled):

    PQ-LATE result=<valid|invalid|otherkey|unavailable> attempt=<n> ms=<n>

It carries no id, name or key. The protection line (QA-PQLEVEL) may end with ` late=1` after a late check changed the call's state.

Run:  python scripts/test_ship_ios_pqlate_vocab.py [path/to/ship-ios-logs.py]
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


REAL = "PQ-LATE result=valid attempt=2 ms=3012"
LEVEL = ("QA-PQLEVEL v=1 call=0a1b2c3d kind=1to1 level=PQ2 auth=H sas=0 dtls=pq frame=v5 relay=same dcmux=same inner=legacy "
         "rvideo=- pin=ok hold=0 withdraw=- caps=- pqstate=pinned pq_sig=valid outer=sealed reason=- rekey=- round=- late=1")
OKAY = [
    REAL,
    "PQ-LATE result=invalid attempt=1 ms=1004",
    "PQ-LATE result=otherkey attempt=6 ms=30011",
    "PQ-LATE result=unavailable attempt=5 ms=30002",
    "PQ-LATE result=unavailable attempt=1 ms=0",
    LEVEL,
    LEVEL.replace("rekey=- round=- late=1", "rekey=refused round=3 rreason=chain_base late=1"),
]
FORGED = [
    REAL + " ",
    REAL + "\n",
    REAL + " extra=1",
    REAL + " call=0a1b2c3d",
    REAL + " 192.168.1.20",
    REAL + " hello world",
    " " + REAL,
    "x " + REAL,
    "peer said: " + REAL,
    REAL + "\n" + REAL,
    REAL.replace("PQ-LATE", "pq-late"),
    REAL.replace("PQ-LATE", "PQ-LATEX"),
    REAL.replace("result=valid", "result=absent"),
    REAL.replace("result=valid", "result=alice"),
    REAL.replace("result=valid", "result=valid result=valid"),
    REAL.replace("attempt=2", "attempt=123"),
    REAL.replace("attempt=2", "attempt=x"),
    REAL.replace("ms=3012", "ms=12345678"),
    REAL.replace("ms=3012", "ms=-1"),
    REAL.replace(" ms=3012", ""),
    REAL.replace("attempt=2 ms=3012", "ms=3012 attempt=2"),
    LEVEL + " late=1",
    LEVEL.replace("late=1", "late=2"),
    LEVEL.replace("late=1", "late=x"),
    LEVEL.replace(" late=1", " tl=pq kd=pq unk=0 late=1"),
    REAL + "​",
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
    checks += 1
    if red(REAL, tag) == REAL:
        failures.append("the rule leaked under tag %r" % tag)

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
