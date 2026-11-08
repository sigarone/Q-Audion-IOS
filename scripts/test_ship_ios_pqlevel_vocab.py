#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The per-call protection summary line must survive the phone-log shipper (scripts/ship-ios-logs.py) VERBATIM, and only that
exact grammar (QAudionApp/Services/CallService.swift emitPqLevelIfChanged, built by PqLevelLine.format in
QAudionEngine/Diagnostics/PqLevel.swift):

    QA-PQLEVEL v=1 call=<8 hex> kind=<1to1|group> level=<PQ2|PQ2S|PQ1|CL> auth=<H|C> sas=<0|1> dtls=<pq|cl|-> frame=<v5|v6|->
      relay=<..> dcmux=<..> inner=<legacy|v2|-> rvideo=<two|one|-> pin=<ok|anomaly|-> hold=<0|1|-> withdraw=<ok|ignored|->
      caps=<-|list> pqstate=<..> pq_sig=<..> outer=<sealed|off|-> reason=<..> rekey=<ok|refused|-> round=<n|->  [tl= kd= unk=]

The generic structured gate cannot read it (a bare line name, `pin=` is an identity-word key, `inner=legacy` is 12 characters),
so it is accepted by a whole-line rule; this test pins that the rule is exactly that narrow. It also runs every line of the
shared known-answer file (Resources/kat/pqc-hardening-v1-kat.json, section level.logLine) through the shipper.

Run:  python scripts/test_ship_ios_pqlevel_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every real line ships unchanged and every forged variant is refused; 1 otherwise.
"""
import importlib.util
import json
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
KAT = os.path.join(HERE, "..", "QAudionEngine", "Tests", "QAudionEngineTests", "Resources", "kat",
                   "pqc-hardening-v1-kat.json")
m = load(TARGET)


def red(line, tag="call"):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


def shipped(line, tag="call"):
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


REAL = ("QA-PQLEVEL v=1 call=0a1b2c3d kind=1to1 level=PQ2 auth=C sas=0 dtls=pq frame=v5 relay=same dcmux=same inner=legacy "
        "rvideo=- pin=- hold=0 withdraw=- caps=- pqstate=- pq_sig=- outer=sealed reason=- rekey=- round=-")
OKAY = [
    REAL,
    REAL.replace("level=PQ2", "level=PQ1").replace("dtls=pq", "dtls=cl").replace("frame=v5", "frame=-")
        .replace("relay=same dcmux=same", "relay=off dcmux=off").replace("outer=sealed reason=-", "outer=off reason=local_install"),
    REAL.replace("outer=sealed reason=-", "outer=off reason=peer_install").replace("sas=0", "sas=1"),
    REAL.replace("level=PQ2", "level=PQ2S"),
    REAL.replace("level=PQ2", "level=CL"),
    REAL.replace("caps=-", "caps=capsBindV1,innerSealV2"),
    REAL + " tl=pq kd=cl unk=2",
    REAL.replace("kind=1to1", "kind=group") + " tl=pq kd=pq unk=0",
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

# The lines of the shared known-answer file (their call prefix is a label, not hex: use a hex one).
with open(KAT, "rb") as fh:
    kat = json.loads(fh.read().decode("utf-8"))
for vec in kat["level"]["logLine"]["vectors"]:
    line = re.sub(r"call=\S+", "call=0a1b2c3d", vec["line"], count=1)
    checks += 1
    if red(line) != line:
        failures.append("known-answer line not shipped verbatim: %r -> %r" % (line, red(line)))

# Scoped to the call / stdout tags: not a free pass under another tag.
for tag in ("chat", "net", "ice", "media", "crypto", "livelog"):
    checks += 1
    if red(REAL, tag) == REAL:
        failures.append("the rule leaked under tag %r" % tag)

FORGED = [
    REAL + " ",
    REAL + "\n",
    REAL + " extra=1",
    REAL + " hello world",
    REAL + " +39 333 1234567",
    REAL + " 192.168.1.20",
    REAL + " dGhpcyBpcyBhIHNlY3JldCBibG9iIQ==",
    " " + REAL,
    "x " + REAL,
    "peer said: " + REAL,
    REAL + "\n" + REAL,
    REAL.replace("QA-PQLEVEL", "qa-pqlevel"),
    REAL.replace("QA-PQLEVEL", "QA-PQLEVELX"),
    REAL.replace("QA-PQLEVEL v=1", "QA-PQLEVEL v=2"),
    REAL.replace("call=0a1b2c3d", "call=0a1b2c3"),
    REAL.replace("call=0a1b2c3d", "call=0a1b2c3d4"),
    REAL.replace("call=0a1b2c3d", "call=0A1B2C3D"),
    REAL.replace("call=0a1b2c3d", "call=alice-bo"),
    REAL.replace("call=0a1b2c3d", "call=0a1b2c3d call=0a1b2c3d"),
    REAL.replace("kind=1to1", "kind=other"),
    REAL.replace("level=PQ2", "level=PQ3"),
    REAL.replace("auth=C", "auth=X"),
    REAL.replace("sas=0", "sas=2"),
    REAL.replace("dtls=pq", "dtls=maybe"),
    REAL.replace("relay=same", "relay=Alice"),
    REAL.replace("inner=legacy", "inner=secret"),
    REAL.replace("pin=-", "pin=1234"),
    REAL.replace("caps=-", "caps=hello"),
    REAL.replace("caps=-", "caps=capsBindV1,"),
    REAL.replace("caps=-", "caps=capsBindV1;innerSealV2"),
    REAL.replace("outer=sealed", "outer=maybe"),
    REAL.replace("reason=-", "reason=alice"),
    REAL.replace("round=-", "round=1234567890"),
    REAL.replace("round=-", "round=x"),
    REAL.replace(" hold=0", ""),
    REAL.replace(" hold=0", "  hold=0"),
    REAL.replace("rekey=- round=-", "round=- rekey=-"),
    REAL + " tl=pq",
    REAL + " tl=pq kd=pq",
    REAL + " tl=pq kd=pq unk=1000",
    REAL + " tl=maybe kd=pq unk=1",
    "QA-PQLEVEL " + "a" * 200,
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
