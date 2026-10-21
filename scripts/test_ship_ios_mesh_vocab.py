#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
MESH (2026-10-21) -- the Bluetooth mesh diagnostic events (docs/mesh/MESH_LINK_SPEC.md section 13) must reach Loki
through the phone-log shipper (scripts/ship-ios-logs.py) VERBATIM, and only those. They are the evidence, in a log pull,
of what the radio did: which links came up and why they went down, how many frames of a packet were accepted, which
frame failed, why a packet was dropped or not relayed, whether the outbox is still retrying.

The lines are written by QAudionEngine/Sources/QAudionEngine/Mesh/MeshLog.swift under the tag "mesh". Before, the tag
was not in TAG_SCOPE_PREFIXES, so every mesh line was dropped at the tag gate; and the generic structure gates cannot
read these shapes (link handles c1 / p2, tokens like too_many_frames, one-letter keys p= and l=). The shipper now
accepts a mesh line when the WHOLE body matches a closed grammar (an alternative per event, every value a closed token,
a number or a bounded hex prefix), and nothing else is widened.

This test pins, against the Swift sources (so a new event or reason token added there without the shipper fails here):
  - every event name of `MeshLog.Event` has a sample line, and every sample line is shipped unchanged;
  - every reason / result / state token the Swift code can write is accepted;
  - the lines carry no identifier longer than 6 / 8 hex characters, and a line with a full node id, an address, a name,
    free text, an extra field, a wrong tag or a wrong shape is NOT shipped as is;
  - nothing leaked into the general vocabulary or into other tags.

Run:  python scripts/test_ship_ios_mesh_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = ok; 1 = a line was dropped or altered, or leaked.
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
ROOT = os.path.join(HERE, "..")
MESH_DIR = os.path.join(ROOT, "QAudionEngine", "Sources", "QAudionEngine", "Mesh")
APP_DIR = os.path.join(ROOT, "QAudionApp")
m = load(TARGET)


def read(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as fh:
        return fh.read()


def shipped(line, tag="mesh"):
    """What the shipper would send for `line`, or None if it is dropped."""
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


failures = []
checks = 0


def check(cond, what):
    global checks
    checks += 1
    if not cond:
        failures.append(what)


# --- the Swift sources ------------------------------------------------------------------------------------------

log_src = read(MESH_DIR, "MeshLog.swift")
EVENTS = re.findall(r'case\s+\w+\s*=\s*"([a-z.]+)"', log_src.split("public enum Event")[1].split("public var level")[0])
EVENTS += re.findall(r"^\s*case\s+([a-z]+)\s*$", log_src.split("public enum Event")[1].split("public var level")[0], re.M)
EVENTS = sorted(set(EVENTS))

framing_src = read(MESH_DIR, "MeshLinkFraming.swift")
FRAME_REASONS = re.findall(r'case\s+\w+\s*=\s*"([a-z_]+)"',
                           framing_src.split("public enum MeshFrameFailure")[1].split("}")[0])
FRAME_REASONS += re.findall(r"^\s*case\s+(rejected|timeout)\s*$",
                            framing_src.split("public enum MeshFrameFailure")[1].split("}")[0], re.M)
MALFORMED = re.findall(r'case\s+\w+\s*=\s*"([a-z_]+)"',
                       framing_src.split("public enum MalformedReason")[1].split("}")[0])
relay_src = read(MESH_DIR, "MeshRelayGate.swift")
SKIPS = re.findall(r"^\s*case\s+(mode|ttl|dup|rate)\s*$", relay_src.split("public enum SkipReason")[1].split("}")[0], re.M)

ble_src = read(APP_DIR, "Services", "BleMeshTransport.swift")
runtime_src = read(APP_DIR, "Services", "MeshRuntime.swift")
drain_src = read(APP_DIR, "Services", "MeshOutboxDrain.swift")
appstate_src = read(APP_DIR, "AppState.swift")

DROP_REASONS = sorted(set(MALFORMED + ["short_frame"] +
                          re.findall(r'registerMalformed\(link, reason: "([a-z_]+)"\)', ble_src) +
                          re.findall(r'\("reason", "(set_expired|set_evicted)"\)', ble_src)))
RADIO_REASONS = sorted(set(
    t for line in (ble_src + runtime_src).splitlines() if ".radio" in line
    for t in re.findall(r'\("reason", "([a-z_]+)"\)', line)))
DOWN_REASONS = sorted(set(re.findall(r'(?:tearDown|disconnect)\([^)]*reason: "([a-z]+)"', ble_src) +
                          re.findall(r'downReason = "([a-z]+)"', ble_src)))
APP_RESULTS = sorted(set(re.findall(r'logMeshRx\([^)]*result: "([a-z_]+)"\)', appstate_src)))
APP_STATES = sorted(set(re.findall(r'logApp\([^)]*state: "([a-z]+)"', drain_src)))

check(len(EVENTS) == 17, "expected 17 events in MeshLog.Event, found %r" % (EVENTS,))
check(len(FRAME_REASONS) == 6, "MeshFrameFailure tokens: %r" % (FRAME_REASONS,))
check(len(MALFORMED) == 4, "MalformedReason tokens: %r" % (MALFORMED,))
check(sorted(SKIPS) == ["dup", "mode", "rate", "ttl"], "relay skip reasons: %r" % (SKIPS,))
check(len(RADIO_REASONS) >= 8, "radio reasons found: %r" % (RADIO_REASONS,))
check(set(DOWN_REASONS) <= {"remote", "timeout", "evicted", "blocked", "stop"}, "link.down reasons: %r" % (DOWN_REASONS,))
check(len(APP_RESULTS) >= 8, "app.rx results found: %r" % (APP_RESULTS,))
check(set(APP_STATES) <= {"sent", "queued", "failed"}, "app.tx states: %r" % (APP_STATES,))

# --- sample lines -----------------------------------------------------------------------------------------------

PH = "ba7816bf"
NH = "21fe31"
LINES = [
    "identity ok=1 nh=%s src=key" % NH,
    "identity ok=0 src=locked",
    "identity ok=0 src=missing",
    "link.up link=c1 role=c n=2",
    "link.up link=p13 role=p n=1",
    "link.ready link=c1 mtu=0 l=182 sub=1",
    "link.ready link=p3 mtu=0 l=20 sub=0",
    "link.refused reason=cap role=p",
    "link.refused reason=blocked role=p",
    "ann.tx link=c1 nbrs=2 bytes=126 ok=1",
    "ann.rx link=c1 nh=%s nbrs=2 bound=1" % NH,
    "tx ph=%s type=1 bytes=483 route=direct links=1 okLinks=1 frames=3 l=182 result=sent reason=none ms=240" % PH,
    "tx ph=%s type=5 bytes=163 route=flood links=0 okLinks=0 frames=0 l=0 result=queued reason=no_links ms=0" % PH,
    "tx ph=%s type=1 bytes=483 route=direct links=1 okLinks=0 frames=3 l=182 result=failed reason=write_failed ms=2001" % PH,
    "rx link=p1 ph=%s type=1 bytes=483 frames=3 forUs=1 relay=0" % PH,
    "guard.block link=c1 streak=10 ms=60000",
    "relay ph=%s ttl=4 p=800 fwd=2 okLinks=2" % PH,
    "relay ph=%s ttl=3 p=1000 fwd=1 okLinks=0" % PH,
    "outbox pending=3 retried=1 gaveUp=0",
]
for reason in RADIO_REASONS:
    LINES.append("radio state=error mode=full reason=%s" % reason)
    LINES.append("radio state=on mode=direct reason=%s" % reason)
for state in ("off", "starting", "on", "error"):
    for mode in ("full", "direct", "visible"):
        LINES.append("radio state=%s mode=%s reason=start" % (state, mode))
for reason in DOWN_REASONS:
    LINES.append("link.down link=c2 reason=%s heldMs=34210" % reason)
for reason in FRAME_REASONS:
    LINES.append("tx.frame.fail link=c1 ph=%s idx=1 total=3 reason=%s" % (PH, reason))
    LINES.append("tx ph=%s type=1 bytes=483 route=flood links=2 okLinks=0 frames=3 l=20 result=failed reason=%s ms=2001"
                 % (PH, reason))
for reason in DROP_REASONS:
    LINES.append("rx.drop link=c1 reason=%s streak=3" % reason)
for reason in SKIPS:
    LINES.append("relay ph=%s ttl=4 p=0 fwd=0 okLinks=0 reason=%s" % (PH, reason))
for kind in ("msg", "rcpt"):
    for state in APP_STATES or ["sent", "queued", "failed"]:
        LINES.append("app.tx ph=%s kind=%s state=%s attempt=12" % (PH, kind, state))
    for result in APP_RESULTS:
        LINES.append("app.rx ph=%s kind=%s result=%s" % (PH, kind, result))

seen_events = set()
for line in LINES:
    got = shipped(line)
    check(got == line, "not shipped verbatim: %r -> %r" % (line, got))
    seen_events.add(line.split(" ")[0])
check(seen_events == set(EVENTS),
      "events without a sample line, or sample lines of events the Swift source does not have: %r"
      % (sorted(seen_events.symmetric_difference(set(EVENTS))),))

# Every value in every sample is a short token, a number, a 6 / 8 hex prefix or a link handle: no identifier survives.
for line in LINES:
    for value in re.findall(r"=(\S+)", line):
        check(len(value) <= 24 and not re.fullmatch(r"[0-9a-f]{9,}", value), "long value in %r" % line)

# The tag is part of the rule: the same line under another tag is not given the free pass.
for tag in ("call", "chat", "net", "unknown", "meshing"):
    got = shipped("link.up link=c1 role=c n=2", tag)
    check(got != "link.up link=c1 role=c n=2" or tag == "meshing",
          "a mesh line was shipped verbatim under tag %r" % tag)

# --- lines that must NOT ship as they are -----------------------------------------------------------------------

NODE_ID = "21fe31dfa154a261"
FORGED = [
    "identity ok=1 nh=%s src=key" % NODE_ID,                                  # a full node id
    "ann.rx link=c1 nh=%s nbrs=2 bound=1" % NODE_ID,
    "ann.rx link=c1 nh=%s nbrs=2 bound=1 name=Marco" % NH,                    # an extra field
    "ann.rx link=AA:BB:CC:DD:EE:FF nh=%s nbrs=2 bound=1" % NH,                # an address as the handle
    "ann.rx link=3F2504E0-4F89-11D3-9A0C-0305E82C3301 nh=%s nbrs=2 bound=1" % NH,
    "rx link=c1 ph=%s type=1 bytes=483 frames=3 forUs=1 relay=0" % ("ba7816bf" * 8),   # a long hash
    "rx link=c1 ph=%s type=1 bytes=483 frames=3 forUs=1 relay=0 from=%s" % (PH, NODE_ID),
    "radio state=on mode=direct reason=Marco_Rossi",
    "radio state=on mode=direct reason=start extra",
    "app.rx ph=%s kind=msg result=stored 3f2504e0-4f89-11d3-9a0c-0305e82c3301" % PH,
    "outbox pending=3 retried=1 gaveUp=0\nsecond line",
    "tx ph=%s type=1 bytes=483 route=direct links=1 okLinks=1 frames=3 l=182 result=sent reason=none ms=240 id=1" % PH,
    "Mesh link.up link=c1 role=c n=2",
    "link.up link=c1 role=c n=2 ",
    "link.up link=c1 role=x n=2",
    "relay ph=%s ttl=4 p=800 fwd=2 okLinks=2 reason=other" % PH,
]
for line in FORGED:
    got = shipped(line)
    check(got != line, "a line that is not in the grammar was shipped as is: %r" % line)

# --- nothing leaked into the general vocabulary -------------------------------------------------------------------

for word in ("okLinks", "heldMs", "gaveUp", "forUs", "undecryptable", "readdressed", "evicted"):
    check(not m._word_known(word.lower()), "%r became general vocabulary" % word)
check("ph" not in m._KV_HEXID_KEYS and "nh" not in m._KV_HEXID_KEYS, "ph / nh became general hex-id keys")
check(("mesh", "mesh") in m.TAG_SCOPE_PREFIXES, "the mesh tag is not in TAG_SCOPE_PREFIXES")

if failures:
    print("FAIL: %d of %d checks" % (len(failures), checks))
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("OK: %d checks, %d mesh lines ship verbatim" % (checks, len(LINES)))
