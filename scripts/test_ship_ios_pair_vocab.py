#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
PAIR (2026-10-20) -- the lines the in-person pairing scanner writes when it turns a scanned QR down must survive the
phone-log shipper's tag and vocabulary gates (scripts/ship-ios-logs.py).

The lines (tag "pair", ProximityScanReport in QAudionApp/Views/Contacts/ProximityPairingSupportViews.swift):

    scan outcome=not_pair len=<n>
    scan outcome=invalid reason=<ProximityQrRejection token> len=<n>

Before, the tag "pair" was not in TAG_SCOPE_PREFIXES and the words scan / pair / invalid / alphabet / encoding /
canonical / layout were not vocabulary: a rejected scan left no trace in a log pull, and the specific check that failed
could not be read afterwards. The reason tokens are read from the Swift source (ProximityQrRejection), so a new reason
added there without the shipper fails here.

Run:  python scripts/test_ship_ios_pair_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every line ships verbatim and the vocabulary stayed scoped; 1 = a line was dropped or altered, or leaked.
"""
import importlib.util
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
TYPES = os.path.join(HERE, "..", "QAudionEngine", "Sources", "QAudionEngine", "Sovereign", "Proximity",
                     "ProximityPairingTypes.swift")
m = load(TARGET)


def red(line, tag="pair"):
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


def swift_reasons():
    """The raw values of `enum ProximityQrRejection` in the engine source."""
    with open(TYPES, encoding="utf-8") as fh:
        src = fh.read()
    block = re.search(r"enum ProximityQrRejection[^{]*\{(.*?)\n\}", src, re.S).group(1)
    reasons = []
    for case in re.findall(r"^\s*case\s+(\w+)(?:\s*=\s*\"([^\"]+)\")?\s*$", block, re.M):
        reasons.append(case[1] or case[0])
    return reasons


failures = []
checks = 0

REASONS = swift_reasons()
if len(REASONS) != 7:
    failures.append("expected 7 ProximityQrRejection tokens in the Swift source, found %r" % (REASONS,))

LINES = ["scan outcome=not_pair len=12", "scan outcome=not_pair len=129", "scan outcome=pairing len=129"]

# The Bluetooth transport of the pairing (2026-11-14) and the mesh hold of the pairing screen: closed grammar.
BLE_LINES = [
    "ble.begin role=disp sid=0a1b2c3d",
    "ble.begin role=scan sid=ffffffff",
    "ble.state role=disp state=powered_on",
    "ble.state role=scan state=unauthorized",
    "ble.state role=disp state=other",
    "ble.adv step=add ok=1 code=0",
    "ble.adv step=start ok=0 code=-12",
    "ble.peer ev=subscribed",
    "ble.peer ev=unsubscribed",
    "ble.scan ev=start",
    "ble.scan ev=found rssi=-67",
    "ble.scan ev=connect",
    "ble.scan ev=connected",
    "ble.scan ev=connect_failed code=14",
    "ble.scan ev=disconnected code=0",
    "ble.scan ev=services code=0 ok=1",
    "ble.scan ev=chars code=0 ok=0",
    "ble.scan ev=subscribed code=0 ok=1",
    "ble.timeout role=scan stage=connecting",
    "ble.timeout role=scan stage=svc",
    "ble.qr ev=shown ms=240",
    "ble.qr ev=forced ms=4001",
    "mesh hold=acquire n=1 antenna=1",
    "mesh hold=release n=0 antenna=0",
    "mesh hold=expired n=0 antenna=1",
]
LINES += BLE_LINES
for reason in REASONS:
    LINES.append("scan outcome=invalid reason=%s len=129" % reason)
    LINES.append("scan outcome=invalid reason=%s len=0" % reason)

for line in LINES:
    checks += 1
    got = red(line)
    if got != line:
        failures.append("%r -> %r" % (line, got))

# The tag gate: the line is not a free pass under another tag.
for tag in ("call", "net", "chat"):
    checks += 1
    got = red("scan outcome=invalid reason=length len=129", tag)
    if got == "scan outcome=invalid reason=length len=129":
        failures.append("the pair vocabulary leaked under tag %r" % tag)
    checks += 1
    got = red("ble.scan ev=found rssi=-67", tag)
    if got == "ble.scan ev=found rssi=-67":
        failures.append("the pair Bluetooth grammar leaked under tag %r" % tag)

# The shape gate: the vocabulary is only for the whole line, nothing before, nothing after.
for line in [
    "scan outcome=invalid reason=length len=129 zorkblatfoo=1 quuxwibblez=2",
    "zorkblatfoo scan outcome=invalid reason=length len=129",
    "scan outcome=invalid reason=somesecretword len=129",
    "scan outcome=invalid reason=length len=1234567",
    "scan outcome=other len=129",
    "scan outcome=invalid len=129",
    "ble.begin role=disp sid=0a1b2c3d4e5f6071",           # more than the 8 hex of the session prefix
    "ble.state role=disp state=somethingelse",
    "ble.scan ev=found rssi=-67 name=zorkblat",
    "ble.scan ev=teleport",
    "ble.timeout role=scan stage=nowhere",
    "ble.adv step=start ok=1 code=0 extra=1",
    "mesh hold=acquire n=1",
]:
    checks += 1
    got = red(line)
    if got == line:
        failures.append("an off-shape line shipped verbatim: %r" % line)

print("checks: %d, failures: %d" % (checks, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
