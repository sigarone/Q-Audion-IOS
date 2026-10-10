#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Hardening of the phone-log shipper's structured gate (scripts/ship-ios-logs.py) against given names, labels and
short codes: W-NAMEGATE.

Before, a body could carry up to two words that are not vocabulary, any alphabetic key=value value that read like a
word, and any short number after a verb. That is enough for "dial <name> ok count=1", "peer name=<name>" or
"dial 9999 ok". Now:
  * every free word of a body (outside key=value) must be vocabulary; a "word:" token counts as a free word;
  * the alphabetic value of a key=value must be made only of vocabulary words, and under a key that names an
    identity (name, label, caller, contact, display, ...) it can only be a boolean, a short number or a hex id
    prefix;
  * a number of 3+ digits without a unit is a measurement only in a context (after "key:", after a quantity word,
    before a unit word, or under a known key).

SYNTHETIC fixtures only: the names below are invented placeholders and the codes are 9999 / 7777 / 12345.

Part 1 (BLOCKED): none of the invented names or codes may appear in the shipped body, under the "call" and the
"stdout" tag. A line may ship as the attribute summary or not at all.
Part 2 (KEPT): the diagnostic lines of the app, with synthetic numbers, still ship verbatim.

Run:  python scripts/test_ship_ios_namegate.py [path/to/ship-ios-logs.py]
Exit 0 = every blocked line is blocked and every kept line ships verbatim; 1 = at least one check failed.
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


def shipped(line, tag):
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else ""


failures = []
checks = 0

# ---------------------------------------------------------------------------
# Part 1 -- BLOCKED. {N} = an invented name, {C} = an invented short code.
# ---------------------------------------------------------------------------
NAMES = ["Nomeuno", "nomeuno", "NOMEUNO", "Nomeuno Cognomeuno", "Test Utente"]
CODES = ["9999", "7777", "12345"]
NAME_TOKENS = ["nomeuno", "cognomeuno", "utente"]

NAME_LINES = [
    # the shapes that used to ship verbatim
    "peer name={N} state=active",
    "state=ringing label={N}",
    "dial {N} ok count=1",
    "incoming {N} ok state=ringing role=callee",
    "resolved {N} ok count=1 bytes=300",
    "ringing {N} state=ringing",
    # a name under an identity key, whatever the quoting
    "state=ringing contact={N}", "state=ringing caller={N}", "state=ringing callee={N}",
    'state=ringing callee="{N}"', "state=ringing name='{N}'", "state=ringing display={N}",
    "state=ringing to={N}", "state=ringing from={N}", "state=ringing owner={N} count=1",
    "state=ringing title={N} count=1", "state=ringing nick={N}", "state=ringing user={N}",
    "state=ringing subject={N}", "state=ringing group={N}", "state=ringing room={N}",
    "state=ringing note={N}", "state=ringing groupName={N}", "state=ringing firstname={N}",
    "(name={N}) state=ringing", "[label={N}] state=ringing", "{{callee: {N}}} state=ringing",
    # a name under an enum key, or as a bare word / label
    "state={N} role=caller", "reason={N} state=ringing", "role={N} state=ringing",
    "state=ringing {N}", "[{N}] ok state=ringing", "{N}: ok state=ringing", "dial {N}: ok count=1",
    "dial,{N},ok state=ringing",
]
CODE_LINES = [
    "dial {C} ok count=1", "code {C} ok count=1", "ext {C} ok count=1", "resolved {C} bytes=300",
    "dial {C}", "state=ringing name={C}", "state=ringing contactId={C}", "state=ringing label={C}",
]
# An invented key the app never printed next to a 3+ digit number: summarised until it is added.
UNKNOWN_KEY_LINES = ["state=ringing zorkblat={C}", "state=ringing qq={C} count=1"]


def must_block(line, forbidden):
    global checks
    for tag in ("call", "stdout"):
        checks += 1
        got = shipped(line, tag)
        low = got.lower()
        hit = [s for s in forbidden if s in low]
        if hit:
            failures.append("LEAK [%s] %r -> %r" % (tag, line, got))


for tmpl in NAME_LINES:
    for name in NAMES:
        must_block(tmpl.replace("{N}", name), NAME_TOKENS)
for tmpl in CODE_LINES + UNKNOWN_KEY_LINES:
    for code in CODES:
        must_block(tmpl.replace("{C}", code), CODES)

# The same lines with the name replaced by a vocabulary-looking word must NOT be what keeps them out: the
# structure around a name still ships (the summary carries the allowed attributes).
checks += 1
got = shipped("state=ringing role=callee label=Nomeuno", "call")
if "Nomeuno" in got:
    failures.append("LEAK label survived: %r" % got)

# ---------------------------------------------------------------------------
# Part 2 -- KEPT: lines that must keep shipping verbatim (numbers are synthetic).
# ---------------------------------------------------------------------------
KEPT = [
    # numbers and booleans under keys that look like identities stay
    "state=active ice=connected role=caller retries=2",
    "peer=3 state=active", "peer=true state=active", "group=false state=active",
    "to=8bc24df8 state=active", "peerReadyAgeMs=4321 state=active", "groupCount=12 state=active",
    # decimals, units and known keys with a 3+ digit number
    "[OwnerCont] cos=0.099 v=0.549 lv=unc",
    "aprof resolved_ms=60 block_b=256 requested_ms=60",
    "grp_recon n=0", "grp_recon n=250",
    "cryattach media=audio ok=1 ms=6",
    "audiosrtp muteapply m=1 src=act",
    "audiosrtp hb=1 tlsv=FEFC dtls=connected",
    "[Voice] bg=1 every=10 cpu=42 skip=3 run=2 high=0",
    "[Guardian] count=12 ms=9 windows=199 skipped=99 dropped=0 nil=100",
    "display bg=1",
    # app line families that used to ship through the allowance of unknown words
    "vidpause tx ok=1", "vidpause rx match=0", "vidinvite action=accept", "busytone play=1",
    "vidcap promote ok=0 reason=no_peer", "callready ignored=1 stale=1",
    "callctrl replaced=1 site=outgoing", "dchangup tx=0 why=nosealer",
    "sigsend fail kind=pqc_accept site=json reason=no_provider peer=5",
    "grp_receipt queued=1 kind=delivered",
    "filev2 send failed code=5", "inappring res=0",
    # labels (a vocabulary word and a short number) and the colon labels of the engine
    "senderId: audio0", "receiverId: janus1", "[PQC_DIAG_V5] kind=offer state=active",
    # numbers in a measurement context
    "(audio.cc:551): output: 0",
    "(video.cc:283): Resolution: 720 x 1280",
    "(video.cc:396): Frames decoded 300",
    "(session.cc:279): Remote peer requests ICE restart for 2.",
    "(network.cc:697): Count of networks: 3",
    "(session.cc:12): Set ICE receiving timeout to 500 ms",
    "HTTP 429",
]


def must_ship(line):
    global checks
    for tag in ("call", "stdout"):
        checks += 1
        got = shipped(line, tag)
        if got != line:
            failures.append("LOST [%s] %r -> %r" % (tag, line, got))


for line in KEPT:
    must_ship(line)

print("checks: %d, failures: %d" % (checks, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
