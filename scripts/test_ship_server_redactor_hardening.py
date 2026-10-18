#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Regression tests for the redactor of the server leg (scripts/ship-server-logs.py),
the sibling of test_ship_ios_redactor_hardening.py (which covers the phone leg).
SYNTHETIC fixtures only: every "secret" below is derived from a fixed counter
(sha256 of a label, or the byte list 1..32) -- never a real key. Fixtures use
neutral values: no host, region or private-range names, documentation-range IP
addresses only.

  Free words (W-FREEWORD)  base26 / base52 / syllable blocks of 3-11 letters between
                           structural tokens, mixed-case and case-encoded words,
                           homoglyphs, kv value carriers, number+letter tokens,
                           comma-number chunks, runs of bare numbers must not ship
                           (or only up to the per-body cap).
  Key-material words      `secret [..]` / `slat [..]` / `salt [..]` / `raw_key` /
  (W-KEYWORDS)            `derived_key` / `*_key [..]` lines are dropped whole,
                           whatever the bracket contains -- also with a zero-width /
                           format character hidden inside the key word.
  Compressed IPv6         '::' forms (2001:db8::1, fe80::1, ::1) are scrubbed: the
                           full-form rule cannot match them.
  + benign, readable server call lines must still ship (no over-blocking).

Every numeric bound below is a LITERAL on purpose: a check that reads the cap from
the script under test (MAX_UNKNOWN_WORDS, ...) can never fail when that cap is
raised. The caps of the server leg: 3 unknown words per body, 2 id-like tokens
(6+ digit numbers / hex id prefixes), 3 bare numbers in a row.

Run against the current script:   python scripts/test_ship_server_redactor_hardening.py
Run against another version:      python scripts/test_ship_server_redactor_hardening.py path/to/old-ship-server-logs.py
Exit 0 = all checks pass; 1 = at least one check failed.
"""
import base64
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
    spec = importlib.util.spec_from_file_location("ship_server_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ship_server_under_test"] = mod
    spec.loader.exec_module(mod)
    return mod


TARGET = (sys.argv[1] if len(sys.argv) > 1 else
          os.path.join(os.path.dirname(os.path.abspath(__file__)), "ship-server-logs.py"))
m = load(TARGET)
# most unknown words one body may carry on the server leg (a literal, see above).
CAP = 3
# a structured server call line: the prefix the real slog lines carry.
HD = 'level=INFO msg="call status: active" call_id=91fe5cf7 '


def red(line):
    """Shipped body ('' when the line is dropped)."""
    kept, body = m.redact_body(line, True, {})
    return body if kept else ""


B26 = string.ascii_lowercase
B52 = string.ascii_letters


def enc(data, alphabet):
    n = int.from_bytes(data, "big")
    out = ""
    while n:
        n, r = divmod(n, len(alphabet))
        out = alphabet[r] + out
    return out


# consonant-vowel syllables: an encoder whose output is pronounceable, so no
# lexical rule can tell it from a word.
CV = [c + v for c in "bdfgklmnprstvz" for v in "aeiou"]


def enc_syl(data):
    n = int.from_bytes(data, "big")
    out = []
    while n:
        n, r = divmod(n, len(CV))
        out.append(CV[r])
    return "".join(reversed(out))


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


FILL = ["ice=connected", "active", "role=caller", "retry=1", "net=wifi",
        "media_mode=p2p", "state=active"]


def interleave(blocks, fill=True):
    out = []
    for i, b in enumerate(blocks):
        out.append(b)
        if fill:
            out.append(FILL[i % len(FILL)])
    return " ".join(out)


# ---------------------------------------------------------------------------
# Free words
# ---------------------------------------------------------------------------
survivors_max = 0
long_survivors = 0
for i in range(-1, 24):
    for alpha in (B26, B52):
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
                body = tokens(red(HD + line))
                got = [b for b in bl if b in body and (shape != "pre" or b in bl[:3])]
                survivors_max = max(survivors_max, len(got))
                long_survivors += sum(1 for b in got if len(b) >= 10)
check(long_survivors == 0,
      "FW: %d block(s) of 10-11 letters survived (base26/base52 chunks)" % long_survivors)
check(survivors_max <= CAP,
      "FW: up to %d letter blocks survived in ONE body (cap is %d)" % (survivors_max, CAP))
# the shape that opened the hole: 11-letter blocks separated by the word 'active'.
s = enc(bytes(range(1, 33)), B26)
bl = chunks(s, 11)
line = HD + "state=active " + " active ".join(bl) + " ice=connected"
check(not any(b in red(line) for b in bl), "FW: 11-letter base26 blocks + 'active' shipped")
s = enc(bytes(range(1, 33)), B52)
bl = chunks(s, 11)
line = HD + ("ice=connected role=caller %s retry=1 %s net=wifi %s "
             "media_mode=p2p %s ice=connected" % tuple((bl + [""] * 4)[:4]))
check(not any(b and b in red(line) for b in bl), "FW: 11-letter base52 blocks + kv shipped")

# mixed-case random block (shape of a base52/base62 block)
for blk in ("aBcDeFgHiJk", "kXqJmZvBnRt", "QzJvKxWmPd", "xYzAbCdEf"):
    check(blk not in red(HD + "state=active ice=connected %s role=caller" % blk),
          "FW: mixed-case block %r shipped" % blk)
# case channel: a known word spelled in random mixed case carries one bit per letter
for blk in ("AcTiVe", "cOnNeCtEd", "rInGiNg", "CoNnEcTeD"):
    check(blk not in red(HD + "state=active ice=connected %s role=caller" % blk),
          "FW: case-encoded vocabulary word %r shipped" % blk)
# homoglyph (Cyrillic small ie, U+0435) inside a letters-only block
hg = "abcd\u0435fghijk"
check(hg not in red(HD + "state=active ice=connected %s role=caller" % hg),
      "FW: homoglyph block shipped")
# 1-2 letter blocks: at most CAP of them may ride along
sh = chunks(enc(secret(1), B26), 2)[:20]
body = tokens(red(HD + "state=active " + " ".join(sh)))
check(sum(1 for b in sh if b in body) <= CAP, "FW: 2-letter block run shipped")
# hyphen / underscore joined blocks
sj = chunks(enc(secret(2), B26), 3)
check("-".join(sj[:6]) not in red(HD + "state=active " + "-".join(sj[:6])),
      "FW: hyphen-joined blocks shipped")
check("_".join(sj[:6]) not in red(HD + "state=active " + "_".join(sj[:6])),
      "FW: underscore-joined blocks shipped")
# sibling holes in the same gate
b9 = chunks(enc(secret(3), B26), 9)
for shape, mk in (("kv value", lambda b: "%s=%s" % ("x", b)),
                  ("empty-value key", lambda b: "%s:" % b),
                  ("key carrier", lambda b: "%s=true" % b)):
    line = HD + "state=active " + " ".join(mk(b) for b in b9[:5])
    body = red(line)
    got = [b for b in b9[:5] if b in body]
    check(len(got) <= CAP, "FW: %s carriers: %d of 5 shipped" % (shape, len(got)))
check("1abcdefghij" not in red(HD + "state=active 1abcdefghij role=caller"),
      "FW: number+letters token shipped")
sl = ",".join(str(b) for b in secret(4)[:7]) + " " + ",".join(str(b) for b in secret(4)[7:14])
check(sl not in red(HD + "state=active " + sl), "FW: comma-number chunks shipped")
# base64 blocks below the blob thresholds
b64 = base64.b64encode(secret(5)).decode().replace("=", "")
b64c = chunks(b64, 8)
body = red(HD + "state=active " + interleave(b64c))
check(sum(1 for b in b64c if b in body) <= CAP, "FW: base64 8-char blocks shipped")

# pronounceable blocks (consonant-vowel syllables, 8-11 letters): a lexical
# filter cannot tell them from words. Bounded by the per-body cap (CAP) and by
# the length limit of an unknown word (9 letters): none of 10-11 letters ships.
syl_max = 0
syl_long = 0
for i in range(12):
    s = enc_syl(secret(i))
    for k in (8, 9, 10, 11):
        bl = chunks(s, k)
        for line in ("ice=connected " + interleave(bl),
                     "state=active " + " active ".join(bl) + " ice=connected"):
            body = tokens(red(HD + line))
            got = [b for b in bl if b in body]
            syl_max = max(syl_max, len(got))
            syl_long += sum(1 for b in got if len(b) >= 10)
check(syl_long == 0, "FW: %d pronounceable block(s) of 10-11 letters shipped" % syl_long)
check(syl_max <= CAP,
      "FW: up to %d pronounceable blocks shipped in ONE body (cap is %d)" % (syl_max, CAP))
check("zabekilumo" not in red(HD + "ice=connected role=caller zabekilumo state=active"),
      "FW: a single pronounceable 10-letter unknown word shipped")

# runs of bare numbers: at most 3 in a row ship (a 4th+ is a number list)
check("35ms 20ms 15ms 40ms 12ms" not in red(HD + "state=active 35ms 20ms 15ms 40ms 12ms"),
      "FW: run of 5 bare numbers shipped")
check("35ms 20ms 15ms" in red(HD + "state=active 35ms 20ms 15ms"),
      "FW: legit run of 3 bare numbers lost")

# decimal digits of a secret cut into 6-7 digit numbers (bare and as kv values):
# at most 2 (hex prefixes + 6+ digit numbers) survive per body.
dg = str(int.from_bytes(secret(10), "big"))
nb = [dg[i:i + 7] for i in range(0, 56, 7)]
body = tokens(red(HD + "state=active " + interleave(nb)))
check(sum(1 for b in nb if b in body) <= 2, "FW: 7-digit number blocks (bare) shipped")
body = red(HD + "state=active " + " ".join("%s=%s" % ("abcdefgh"[i], b) for i, b in enumerate(nb)))
check(sum(1 for b in nb if b in body) <= 2, "FW: 7-digit number blocks (kv) shipped")

# readable server call lines keep shipping (no over-blocking)
b = red(HD + "seq=12 rtt=35ms")
check(b and "[summary]" not in b and "seq=12" in b and "rtt=35ms" in b,
      "READ: plain structured call line was masked/dropped: %r" % b)
# two words outside the vocabulary (within the cap of 3) still ship
b = red(HD + "state=active handshake bandwidth seq=12")
check(b and "[summary]" not in b and "handshake" in b and "bandwidth" in b,
      "READ: call line with two readable unknown words was masked/dropped: %r" % b)

# ---------------------------------------------------------------------------
# Key-material words followed by a group
# ---------------------------------------------------------------------------
w1, w2 = "ABCDEF", "GHIJKL"          # synthetic
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
             "secret [%s] len 32" % enc(bytes(range(1, 33)), string.ascii_uppercase)[:22],
             # format characters (zero-width space / joiner, word joiner, BOM)
             # inside the key word: NFKC leaves them in, they must not defeat
             # the rule.
             "state=active sec\u200bret [%s] ice=connected" % w1,
             "state=active sa\u200dlt (%s) ice=connected" % w1,
             "state=active raw\u200b_key computed ice=connected",
             "state=active de\u2060rived_key ok ice=connected",
             "state=active sl\ufeffat {ab:cd} ice=connected",
             "state=active session_ke\u200by [%s] ice=connected" % w1):
    check(red(HD + line) == "", "KEYWORDS: line was not dropped: %r" % line)
check(red(HD + "state=active ice=connected role=caller") != "", "KEYWORDS: plain telemetry dropped")

# ---------------------------------------------------------------------------
# Compressed IPv6 addresses ('::' form): the full-form rule cannot match them.
# Documentation-range addresses only (RFC 3849), never real ones.
# ---------------------------------------------------------------------------
for ip6 in ("2001:db8::1", "fe80::1", "::1", "2001:db8::", "2001:db8:85a3::8a2e:370:7334"):
    for tpl in ("ip=%s role=caller", "peer %s state=active", "from %s ice=connected"):
        body = red(HD + tpl % ip6)
        check(ip6 not in body, "IPV6: %r survived in %r" % (ip6, body))
# the full form keeps being scrubbed
check("2001:db8:85a3:0:0:8a2e:370:7334" not in red(HD + "ip=2001:db8:85a3:0:0:8a2e:370:7334 role=caller"),
      "IPV6: full-form address survived")

# ---------------------------------------------------------------------------
print("checks=%d failures=%d  (%s)" % (checks, len(failures), os.path.basename(TARGET)))
for f in failures:
    print("  FAIL: " + f)
sys.exit(1 if failures else 0)
