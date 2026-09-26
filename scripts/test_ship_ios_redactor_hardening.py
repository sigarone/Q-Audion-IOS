#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Regression tests for the 2026-09-24 hardening of the phone-log redactor
(scripts/ship-ios-logs.py), one group per red-team finding. SYNTHETIC fixtures
only: every "secret" below is derived from a fixed counter (sha256 of a label,
or the byte list 1..32) -- never a real key.

  Finding 1 (critical) free words: base26 / base52 blocks of 3-11 letters
                       interleaved with structural tokens must not ship.
  Finding 2 (high)     kv-precision side channels (version / vtag / epoch10 /
                       enum values under ANY key) must not ship.
  Finding 3 (medium)   `secret [..]` / `slat [..]` / `salt [..]` / `raw_key`
                       / `derived_key` lines are dropped whole, whatever the
                       bracket contains.
  Finding 4 (low)      identity words are not waived by a measure suffix
                       (peerSessionIdMs).
  + sibling holes found while fixing them (kv carrier keys / empty-value keys /
    short kv values, number+letter tokens, comma-number chunks, homoglyphs,
    1-2 letter blocks, indexed kv bytes).
  + benign, readable lines must still ship (no over-blocking).

Run against the current script:   python scripts/test_ship_ios_redactor_hardening.py
Run against another version:      python scripts/test_ship_ios_redactor_hardening.py path/to/old-ship-ios-logs.py
Exit 0 = all checks pass; 1 = at least one check failed (the OLD script fails
the finding checks, the FIXED one passes them).
"""
import hashlib
import importlib.util
import os
import string
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


def red(line, tag="stdout"):
    """Shipped body ('' when the line is dropped)."""
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line), tag)
    return body if kept else ""


B26 = string.ascii_lowercase
B52 = string.ascii_letters
B62 = string.digits + string.ascii_uppercase + string.ascii_lowercase


def enc(data, alphabet):
    n = int.from_bytes(data, "big")
    out = ""
    while n:
        n, r = divmod(n, len(alphabet))
        out = alphabet[r] + out
    return out


def secret(i):
    """Synthetic 32-byte secret #i (i == -1 -> the bytes 1..32)."""
    if i < 0:
        return bytes(range(1, 33))
    return hashlib.sha256(b"synthetic-redactor-fixture-%d" % i).digest()


def chunks(s, k):
    return [s[j:j + k] for j in range(0, len(s), k)]


def tokens(body):
    return body.replace("[", " ").replace("]", " ").split()


checks = 0
failures = []


def check(cond, label):
    global checks
    checks += 1
    if not cond:
        failures.append(label)


FILL = ["ice=connected", "active", "role=caller", "retry=1", "node=helsinki",
        "media_mode=p2p", "state=active"]


def interleave(blocks, fill=True):
    out = []
    for i, b in enumerate(blocks):
        out.append(b)
        if fill:
            out.append(FILL[i % len(FILL)])
    return " ".join(out)


# ---------------------------------------------------------------------------
# Finding 1 (critical): free words
# ---------------------------------------------------------------------------
survivors_max = 0
long_survivors = 0
n_lines = 0
for i in range(-1, 24):
    for alpha, aname in ((B26, "b26"), (B52, "b52")):
        s = enc(secret(i), alpha)
        for k in (3, 4, 5, 6, 8, 9, 10, 11):
            bl = chunks(s, k)
            for shape in ("fill", "active", "pre"):
                if shape == "fill":
                    line = "ice=connected " + interleave(bl)
                elif shape == "active":
                    line = "state=active " + " active ".join(bl) + " ice=connected"
                else:
                    line = "[CallService] " + interleave(bl[:3]) + " state=active"
                body = tokens(red(line))
                got = [b for b in bl if b in body and (shape != "pre" or b in bl[:3])]
                n_lines += 1
                survivors_max = max(survivors_max, len(got))
                long_survivors += sum(1 for b in got if len(b) >= 10)
check(long_survivors == 0,
      "F1: %d block(s) of 10-11 letters survived (base26/base52 chunks)" % long_survivors)
check(survivors_max <= 2,
      "F1: up to %d letter blocks survived in ONE body (cap is 2)" % survivors_max)
# the red-team's exact shape: 11-letter blocks separated by the word 'active'.
s = enc(bytes(range(1, 33)), B26)
bl = chunks(s, 11)
line = "state=active " + " active ".join(bl) + " ice=connected"
check(not any(b in red(line) for b in bl), "F1: 11-letter base26 blocks + 'active' shipped")
s = enc(bytes(range(1, 33)), B52)
bl = chunks(s, 11)
line = ("ice=connected role=caller %s retry=1 %s node=helsinki %s "
        "media_mode=p2p %s ice=connected" % tuple((bl + [""] * 4)[:4]))
check(not any(b and b in red(line) for b in bl), "F1: 11-letter base52 blocks + kv shipped")

# mixed-case random block (shape of a base52/base62 block)
for blk in ("aBcDeFgHiJk", "kXqJmZvBnRt", "QzJvKxWmPd", "xYzAbCdEf"):
    check(blk not in red("state=active ice=connected %s role=caller" % blk),
          "F1: mixed-case block %r shipped" % blk)
# homoglyph (Cyrillic) letters inside a letters-only block
hg = "abcd\u0435fghijk"
check(hg not in red("state=active ice=connected %s role=caller" % hg),
      "F1: homoglyph block shipped")
# 1-2 letter blocks: at most MAX_UNKNOWN_WORDS of them may ride along
sh = chunks(enc(secret(1), B26), 2)[:20]
body = tokens(red("state=active " + " ".join(sh)))
check(sum(1 for b in sh if b in body) <= 2, "F1: 2-letter block run shipped")
# hyphen / underscore / dot joined blocks
sj = chunks(enc(secret(2), B26), 3)
check(not any(t in red("state=active " + "-".join(sj[:6])) for t in ("-".join(sj[:6]),)),
      "F1: hyphen-joined blocks shipped")
check("_".join(sj[:6]) not in red("state=active " + "_".join(sj[:6])),
      "F1: underscore-joined blocks shipped")
# sibling holes in the same gate
b9 = chunks(enc(secret(3), B26), 9)
for shape, mk in (("kv value", lambda b: "%s=%s" % ("x", b)),
                  ("empty-value key", lambda b: "%s:" % b),
                  ("key carrier", lambda b: "%s=true" % b)):
    line = "state=active " + " ".join(mk(b) for b in b9[:5])
    body = red(line)
    got = [b for b in b9[:5] if b in body]
    check(len(got) <= 2, "F1: %s carriers: %d of 5 shipped" % (shape, len(got)))
check("1abcdefghij" not in red("state=active 1abcdefghij role=caller"),
      "F1: number+letters token shipped")
sl = ",".join(str(b) for b in secret(4)[:7]) + " " + ",".join(str(b) for b in secret(4)[7:14])
check(sl not in red("state=active " + sl), "F1: comma-number chunks shipped")
# base64 blocks below the blob thresholds
import base64
b64 = base64.b64encode(secret(5)).decode().replace("=", "")
b64c = chunks(b64, 8)
check(sum(1 for b in b64c if b in red("state=active " + interleave(b64c))) <= 2,
      "F1: base64 8-char blocks shipped")

# hex id prefixes: 8 hex chars stay readable, longer ones and more than
# MAX_HEXKV_TOKENS of them do not.
check("to=8bc24df8" in red("state=active to=8bc24df8 role=caller"), "F1: legit 8-hex id prefix lost")
check("to=8bc24df8aa" not in red("state=active to=8bc24df8aa role=caller"), "F1: 10-hex prefix shipped")
hx = ["%08x" % int.from_bytes(secret(9)[i:i + 4], "big") for i in range(0, 24, 4)]
body = red("state=active " + " ".join("k%s=%s" % ("abcdef"[i], h) for i, h in enumerate(hx)))
check(sum(1 for h in hx if h in body) <= 2, "F1: more than 2 hex-prefix kv tokens shipped")

# decimal digits of a secret cut into 6-7 digit numbers (bare and as kv values):
# at most MAX_IDLIKE_TOKENS (hex prefixes + 6+ digit numbers) survive per body.
dg = str(int.from_bytes(secret(10), "big"))
nb = [dg[i:i + 7] for i in range(0, 56, 7)]
body = tokens(red("state=active " + interleave(nb)))
check(sum(1 for b in nb if b in body) <= 2, "F1: 7-digit number blocks (bare) shipped")
body = red("state=active " + " ".join("%s=%s" % ("abcdefgh"[i], b) for i, b in enumerate(nb)))
check(sum(1 for b in nb if b in body) <= 2, "F1: 7-digit number blocks (kv) shipped")

# readable benign lines keep shipping (no over-blocking)
for line in ("state=active ice=connected role=caller transport=P2pSrtp scorex100=54",
             "ice=connected role=caller retry=2 media_mode=datachannel rtt=35ms",
             "[CallService] state=active isInCall=false callState=idle",
             "reason=endCall err=wsUnavailable selfver=1758433211 media_mode=p2p epoch=v5-ctrl",
             "peerReadyAgeMs=-1 lastKfrAgeMs=2034 maxbps=4500000 sdp_len=3177 version=1.0.1177",
             "[BCryptoWS] ping sent (age=1.4s)",
             "state=active to=8bc24df8 role=caller"):
    b = red(line)
    check(b and "[REDACTED" not in b and "[summary]" not in b,
          "READ: benign line was masked/dropped: %r -> %r" % (line, b))

# ---------------------------------------------------------------------------
# Finding 2 (high): kv-precision side channels
# ---------------------------------------------------------------------------
vt = chunks(enc(secret(6), B26), 8)
line = " ".join("chunk%d=v1-%s" % (i, c) for i, c in enumerate(vt))
check(not any(c in red(line) for c in vt), "F2: vtag under any key shipped")
check("v1-abcdefgh" not in red("zzchunk=v1-abcdefgh state=active"), "F2: vtag suffix shipped")
check("epoch=v5-ctrl" in red("epoch=v5-ctrl state=active"), "F2: legit epoch=v5-ctrl lost")
check("wire=v4" in red("wire=v4 state=active"), "F2: legit wire=v4 lost")
check("epoch=v5-abcdefgh" not in red("epoch=v5-abcdefgh state=active"),
      "F2: epoch tag with a free suffix shipped")
check("netSeq=192.168.1" not in red("netSeq=192.168.1 state=active"), "F2: version under any key shipped")
check("ver=203.0.113" not in red("ver=203.0.113 state=active"), "F2: IPv4-fragment 'version' shipped")
check("version=1.0.1177" in red("version=1.0.1177 state=active"), "F2: legit version lost")
check("1758433211" not in red("somethingCached=1758433211 state=active"),
      "F2: epoch10 under any key shipped")
check("1758433211" not in red("stampAny=1758433211 state=active"), "F2: epoch10 under stamp key shipped")
check("selfver=1758433211" in red("selfver=1758433211 state=active"), "F2: legit selfver lost")
check("version=1758433211" in red("version=1758433211 state=active"), "F2: legit version epoch lost")
en = chunks(enc(secret(7), B26), 11)
body = red(" ".join("%s=%s" % (k, b) for k, b in zip(("state", "reason", "kind", "mode"), en)))
check(not any(b in body for b in en), "F2: enum channel: 11-letter values shipped")
en9 = chunks(enc(secret(8), B26), 9)
body = red(" ".join("%s=%s" % (k, b) for k, b in zip(("state", "reason", "kind", "mode", "phase"), en9)))
check(sum(1 for b in en9[:5] if b in body) <= 2, "F2: enum channel: 9-letter values above the cap")
check("state=active" in red("state=active ice=connected"), "F2: legit enum lost")
many = " ".join("epoch=v%d" % i for i in range(1, 10))
check(red(many).count("epoch=v") <= m.KV_MAX_OPEN if hasattr(m, "KV_MAX_OPEN") else True,
      "F2: open-class kv tokens above the per-body budget")

# ---------------------------------------------------------------------------
# Finding 3 (medium): key-material words followed by a group
# ---------------------------------------------------------------------------
w1, w2 = "ABCDEF", "GHIJKL"          # synthetic
for tag in ("stdout", "crypto", "call"):
    for line in ("(x.cc:1): secret [%s:%s] len 32" % (w1, w2),
                 "(x.cc:1): secret [%s:%s] len 32 slat << [] len 0" % (w1, w2),
                 "(x.cc:1): secret (%s:%s) slat << [] len 0" % (w1, w2),
                 "state=active raw_key [%s:%s] ice=connected" % (w1, w2),
                 "state=active salt [%s:%s] ice=connected" % (w1, w2),
                 "state=active slat [xy:zt] ice=connected",
                 "state=active slat (7) ice=connected",
                 "state=active secret {a b} ice=connected",
                 "state=active secret: <q> ice=connected",
                 "state=active derived_key ok ice=connected",
                 "state=active raw key computed ice=connected",
                 "state=active rawkey computed ice=connected",
                 "state=active DERIVED-KEY [%s] ice=connected" % w1,
                 "state=active session_key [%s] ice=connected" % w1,
                 "state=active root_keys (%s) ice=connected" % w1,
                 "secret [%s] len 32" % enc(bytes(range(1, 33)), string.ascii_uppercase)[:22]):
        check(red(line, tag) == "", "F3[%s]: line was not dropped: %r" % (tag, line))
check(red("state=active ice=connected role=caller") != "", "F3: plain telemetry dropped")
kvbytes = " ".join("k%d=%d" % (i, b) for i, b in enumerate(bytes(range(1, 33))))
check(red("state=active " + kvbytes) == "", "F3: indexed key=value bytes shipped")
check(red("state=active k0=1 k1=2 k2=3 k3=4 k4=5") != "", "F3: 5 indexed tokens must still ship")

# ---------------------------------------------------------------------------
# Finding 4 (low): identity word before the measure suffix
# ---------------------------------------------------------------------------
for k, v, want in (("peerSessionIdMs", "1234567", False), ("userIdCount", "5", False),
                   ("deviceIdLen", "4", False), ("callIdAgeMs", "12", False),
                   ("peerIdx", "3", False), ("emailCount", "2", False),
                   ("phoneNumberLen", "10", False), ("ipCount", "3", False),
                   ("peerReadyAgeMs", "-1", True), ("userCount", "3", True),
                   ("callerRetryCount", "2", True), ("activationCount", "1", True),
                   ("userId", "3", False), ("id", "3", False)):
    check(m._kv_is_benign(k, v) == want, "F4: _kv_is_benign(%r, %r) != %s" % (k, v, want))
check("peerSessionIdMs=1234567" not in red("peerSessionIdMs=1234567 state=active"),
      "F4: peerSessionIdMs shipped")
check("peerReadyAgeMs=-1" in red("peerReadyAgeMs=-1 state=active"), "F4: legit peerReadyAgeMs lost")

# ---------------------------------------------------------------------------
# Follow-up 2026-09-25: the vocabulary of the NEW RTLog lines. The lines below are
# the ones the app builds in W-VPIOOBS (audioVp ev=arm/ff/fire/cfg), W-DCWEDGE
# (dcmux wedge= / wedgesw=) and W-GHOSTCALL (cancelpush ghost= / missed=,
# answerguard refuse= / nocall=, endguard ignore=), each written like its real
# format string with SYNTHETIC numbers and a made-up 8-hex call id prefix, sent
# with the tag "call" (RTLog.info("call", ...)). All of them must ship VERBATIM: a
# line the redactor deletes or blobs is a call-diagnosis line that never reaches
# the log store. The second pass sets the per-body unknown-word allowance to 0:
# with the default of 2 a single dropped vocabulary word hides behind that slack,
# so a later vocabulary cleanup could lose it without any line changing.
# ---------------------------------------------------------------------------
RTLOG_NEW = (
    "audioVp ev=arm gen=3 since_start_ms=0 eng_ms=12",
    "audioVp ev=ff gen=3 ms=210 eng_ms=15",
    "audioVp ev=fire gen=3 since_start_ms=1204 stale=0 er=1",
    "audioVp ev=cfg gen=2 eng_ms=150",
    "dcmux wedge=1 why=buf buf=1600 over=1000 drops=0",
    "dcmux wedge=0 why=drained buf=300 low=3000 rxago=0 wsec=3",
    "dcmux wedgesw=1",
    "dcmux wedgesw=0",
    "cancelpush ghost=1 id=1A2B3C4D",
    "cancelpush missed=1 id=1A2B3C4D",
    "answerguard refuse=1 why=3 id=1A2B3C4D",
    "answerguard nocall=1 id=1A2B3C4D",
    "endguard ignore=1 id=1A2B3C4D",
)


def drop_caches():
    # the redactor memoises its word / kv verdicts (functools.lru_cache): drop them
    # around the change of MAX_UNKNOWN_WORDS so no verdict is answered from an
    # entry computed under the other allowance.
    for f in list(vars(m).values()):
        if hasattr(f, "cache_clear"):
            f.cache_clear()


def rtlog_misses():
    drop_caches()
    return [l for l in RTLOG_NEW if red(l, "call") != l]


bad = rtlog_misses()
check(not bad, "RTLOG: new call-diagnosis lines not shipped verbatim: %r" % (bad,))
slack = m.MAX_UNKNOWN_WORDS
m.MAX_UNKNOWN_WORDS = 0
try:
    bad = rtlog_misses()
finally:
    m.MAX_UNKNOWN_WORDS = slack
    drop_caches()
check(not bad, "RTLOG: with no unknown-word allowance a vocabulary word of the "
      "new call-diagnosis lines is missing: %r" % (bad,))

# ---------------------------------------------------------------------------
# Copilot follow-up to #120 (2026-09-26): the 22 words #120 added for the
# dcmux / audioVp / cancelpush / answerguard / endguard "call"-tagged
# diagnosis lines used to live in the GLOBAL APP_VOCAB, so ANY tag / ANY
# message shape could spend one of the two unknown-word budget slots on a
# word like "wedge" for free. They are now scoped to only the specific line
# shapes they belong to (CALL_FORMAT_VOCAB / _is_call_format_body). The
# original Copilot review reproduction: "wedge" opportunistically used in a
# non-call-format body must NOT gain an extra unknown-word slot from it.
# ---------------------------------------------------------------------------
drop_caches()
COPILOT_REPRO = "state=active zork=1 blarg=2 wedge=1"
check(red(COPILOT_REPRO, "call") != COPILOT_REPRO,
      "SCOPE-120: 'state=active zork=1 blarg=2 wedge=1' shipped verbatim -- "
      "'wedge' bought a 3rd unknown-word slot outside its intended format")
check("wedge=1" not in red(COPILOT_REPRO, "call"),
      "SCOPE-120: 'wedge' survived into the fallback body too: %r"
      % (red(COPILOT_REPRO, "call"),))
# without the opportunistic 'wedge=1' the same 2 unknown words (zork, blarg)
# already fit the default budget and ship verbatim -- confirms 'wedge' was
# the one consuming the 3rd slot, not some other change in body shape.
check(red("state=active zork=1 blarg=2", "call") == "state=active zork=1 blarg=2",
      "SCOPE-120: sanity baseline changed -- test fixture needs updating")
# the SAME word, in its real dcmux format string under the SAME tag, must
# still ship verbatim (the scoping must not be so narrow it re-breaks #120).
check(red("dcmux wedge=1 why=buf buf=1600 over=1000 drops=0", "call")
      == "dcmux wedge=1 why=buf buf=1600 over=1000 drops=0",
      "SCOPE-120: dcmux wedge= line regressed after scoping APP_VOCAB")
# the recognized line SHAPE with the WRONG tag must not get the extra vocab
# either -- scoping is tag AND shape, not shape alone.
check(red("dcmux wedge=1 why=buf buf=1600 over=1000 drops=0", "net") == "",
      "SCOPE-120: dcmux-shaped body shipped under a non-'call' tag")
drop_caches()

# ---------------------------------------------------------------------------
print("checks=%d failures=%d  (%s)" % (checks, len(failures), os.path.basename(TARGET)))
for f in failures:
    print("  FAIL: " + f)
sys.exit(1 if failures else 0)
