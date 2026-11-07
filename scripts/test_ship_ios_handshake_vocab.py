#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The native DTLS handshake summary must survive the phone-log shipper (scripts/ship-ios-logs.py) VERBATIM, and only
that exact line:

    Q-AUDION dtls v=<4 hex> cipher=<4 hex> srtp=<4 hex> group=<4 hex> level=<-?1-2 digits> pqc_req=<0|1> ok=<0|1>

QAudionApp/AppState.swift forwards it at RTLog.warn("call", ...) after NativeHandshakeLogLine.normalized. The generic
structured gate rejected it (bare words "Q-AUDION" / "dtls", a 4-digit cipher value), so it is accepted by a narrow
whole-line rule; this test pins that the rule is exactly that narrow: any extra word, a longer field, a suffix, a
prefix or another tag-less context is still rejected or goes through the ordinary gates.

Run:  python scripts/test_ship_ios_handshake_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = the real line ships unchanged and every forged variant is refused; 1 otherwise.
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
    rec = m.build_log_record({"ms": 1, "lvl": "W", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


REAL = "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1"
OKAY = [
    REAL,
    "Q-AUDION dtls v=0304 cipher=c02c srtp=0001 group=0017 level=-1 pqc_req=0 ok=0",
    "Q-AUDION dtls v=fefd cipher=0000 srtp=0000 group=0000 level=0 pqc_req=0 ok=0",
    "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=10 pqc_req=1 ok=1",
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
        failures.append("the handshake rule leaked under tag %r" % tag)

FORGED = [
    REAL + " ",
    REAL + "\n",
    REAL + " extra=1",
    REAL + " hello world",
    REAL + " +39 333 1234567",
    REAL + " 192.168.1.20",
    REAL + " 192.168.1.20:5004",
    REAL + " dGhpcyBpcyBhIHNlY3JldCBibG9iIQ==",
    REAL + " ok=1",
    " " + REAL,
    "x " + REAL,
    "(openssl_stream_adapter.cc:12): " + REAL,
    "peer said: " + REAL,
    REAL + "\n" + REAL,
    REAL + "\r\nfoo",
    REAL.replace("Q-AUDION", "q-audion"),
    REAL.replace("Q-AUDION", "Q-AUDIONX"),
    REAL.replace("Q-AUDION dtls", "Q-AUDION  dtls"),
    REAL.replace("Q-AUDION dtls", "Q-AUDION dtlz"),
    REAL.replace("Q-AUDION", "Z-AUDION"),
    REAL.replace("v=0304", "v=03040"),
    REAL.replace("v=0304", "v=304"),
    REAL.replace("v=0304", "v=030g"),
    REAL.replace("v=0304", "v=0304 v=0304"),
    REAL.replace("cipher=1302", "cipher=13020000"),
    REAL.replace("cipher=1302", "cipher=13"),
    REAL.replace("cipher=1302", "cipher=1302abcdef123456"),
    REAL.replace("srtp=0008", "srtp=00080"),
    REAL.replace("group=11ec", "group=11ECX"),
    REAL.replace("group=11ec", "group=11EC"),
    REAL.replace("level=3", "level=123"),
    REAL.replace("level=3", "level=--3"),
    REAL.replace("level=3", "level=x"),
    REAL.replace("pqc_req=1", "pqc_req=2"),
    REAL.replace("ok=1", "ok=10"),
    REAL.replace("ok=1", "ok=x"),
    REAL.replace(" level=3", "  level=3"),
    REAL.replace(" srtp=0008", ""),
    REAL.replace("Q-AUDION dtls ", "Q-AUDION dtls v=0304 "),
    "Q-AUDION opus-enc tx_mode=1 tx_bw=3",
    "Q-AUDION dtls " + "a" * 200,
    "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=1" + "​",
    "Q-AUDION dtls v=0304 cipher=1302 srtp=0008 group=11ec level=3 pqc_req=1 ok=１",
]
for line in FORGED:
    for tag in ("call", "stdout"):
        checks += 1
        got = red(line, tag)
        if got == line:
            failures.append("a forged variant shipped verbatim under %r: %r" % (tag, line))
        # Nothing hidden may ride along either: no digit run of a phone number, no IP, no blob in what did ship.
        for needle in ("+39", "1234567", "192.168", "dGhpcy", "hello world", "extra=1"):
            checks += 1
            if needle in line and needle in got:
                failures.append("forged payload %r survived under %r: %r -> %r" % (needle, tag, line, got))

# The ordinary gates are unchanged: bare-word free text is still dropped whole.
checks += 1
if red("Q-AUDION hello there general") == "Q-AUDION hello there general":
    failures.append("free text shipped verbatim")

print("checks: %d, failures: %d" % (checks, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
