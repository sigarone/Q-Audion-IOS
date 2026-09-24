#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
Differential adversarial fuzz for the shipper redactors (scripts/ship-ios-logs.py,
scripts/ship-server-logs.py --server). SYNTHETIC secrets only: random bytes from
a seeded PRNG (never a real key), encoded / split / wrapped in many shapes:
base64/base64url/base62/base58/base52/base32/base26, hex, JWT, uuid after id=,
IPv4/IPv6, e-mail, phone, PSK words, SAS words, decimal/hex byte lists with 14
separators, indexed key=value bytes, secrets cut into blocks of 3-11 letters
between structural tokens, kv key/value/empty-value carriers, vtag/version/epoch
channels, unicode look-alikes (Cyrillic, zero-width, full-width), joined tokens.

A case LEAKS when MORE THAN 50% of its secret-bearing characters survive verbatim
in the shipped body. Exit 0 = no leak (families in KNOWN_OPEN are only reported).

  python scripts/test_ship_redactor_fuzz.py [N=4000] [seed=7]
  python scripts/test_ship_redactor_fuzz.py N seed --server      (server leg)
  python scripts/test_ship_redactor_fuzz.py N seed --target path/to/other.py
  add --show to print the (synthetic) lines of the first leaking cases
"""
import sys, os, random, string, base64, collections, types, importlib.util

def _load(path):
    if "paramiko" not in sys.modules:
        try:
            import paramiko  # noqa: F401
        except ImportError:
            sys.modules["paramiko"] = types.ModuleType("paramiko")
    spec = importlib.util.spec_from_file_location("shipper_under_fuzz", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["shipper_under_fuzz"] = mod
    spec.loader.exec_module(mod)
    return mod

_args = [a for a in sys.argv[1:] if not a.startswith("--")]
IS_SERVER = "--server" in sys.argv
_here = os.path.dirname(os.path.abspath(__file__))
if "--target" in sys.argv:
    path = sys.argv[sys.argv.index("--target") + 1]
    _args = [a for a in _args if a != path]
else:
    path = os.path.join(_here, "ship-server-logs.py" if IS_SERVER else "ship-ios-logs.py")
N = int(_args[0]) if len(_args) > 0 and _args[0].isdigit() else 4000
SEED = int(_args[1]) if len(_args) > 1 and _args[1].isdigit() else 7
m = _load(path)
rnd = random.Random(SEED)

def R(line, tag="stdout"):
    if IS_SERVER:
        kept, body = m.redact_body(line, True, {})
        return body if kept else ""
    scope, safe = m.resolve_scope(tag)
    kept, body = m.redact_body(line, safe, m.extract_attributes(line))
    return body if kept else ""

B62 = string.digits + string.ascii_uppercase + string.ascii_lowercase
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
B52 = string.ascii_letters
B26 = string.ascii_lowercase
B26U = string.ascii_uppercase
B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
WORDS = ("apple river tiger moon happy cloud stone maple orbit velvet copper harbor "
         "lantern meadow pebble quartz saddle timber willow yellow zephyr anchor bridge "
         "candle dragon eagle forest garden hammer island jungle kitten ladder mirror "
         "nectar oxygen pillow rabbit silver thunder umbrella violin walnut window").split()

def enc_base(data, alpha):
    n = int.from_bytes(data, "big"); base = len(alpha); out = ""
    while n:
        n, r = divmod(n, base); out = alpha[r] + out
    return out or alpha[0]

def chunks(s, k):
    return [s[i:i + k] for i in range(0, len(s), k)]

FILL = ["state=active", "ice=connected", "role=caller", "retry=1", "node=helsinki",
        "media_mode=p2p", "active", "connected", "ok", "call", "peer", "rtt=35ms", "seq=12"]

def filler(i):
    return FILL[i % len(FILL)]

def join_with_fill(blocks, mode):
    parts = []
    for i, b in enumerate(blocks):
        parts.append(b)
        if mode == "fill":
            parts.append(filler(rnd.randrange(len(FILL))))
        elif mode == "kvfill":
            parts.append(rnd.choice(FILL[:6]))
    return " ".join(parts)

def homoglyph(s):
    # Cyrillic look-alikes for some ASCII letters (kept as non-NFKC-foldable chars)
    tab = {"a": "\u0430", "e": "\u0435", "o": "\u043e", "p": "\u0440", "c": "\u0441", "x": "\u0445", "y": "\u0443"}
    return "".join(tab.get(c, c) if rnd.random() < 0.35 else c for c in s)

def zw(s):
    return "".join(c + ("\u200b" if rnd.random() < 0.3 else "") for c in s)

def fullwidth(s):
    return "".join(chr(0xFF00 + ord(c) - 0x20) if 0x21 <= ord(c) <= 0x7e and rnd.random() < 0.5 else c for c in s)

# ---- families: each returns (line, blocks) where blocks are the secret-bearing strings
fams = {}
def fam(name):
    def deco(f):
        fams[name] = f
        return f
    return deco

def letters_family(alpha, label):
    def f(sec):
        s = enc_base(sec, alpha)
        k = rnd.choice([3, 4, 5, 6, 7, 8, 9, 10, 11])
        bl = chunks(s, k)
        mode = rnd.choice(["fill", "kvfill", "plain"])
        pre = rnd.choice(["", "state=active ", "ice=connected role=caller ", "[CallService] "])
        return pre + join_with_fill(bl, mode) + rnd.choice(["", " ice=connected", " seq=12 rtt=35ms"]), bl
    fams["blocks_" + label] = f
for alpha, label in ((B26, "b26"), (B26U, "b26U"), (B52, "b52"), (B62, "b62"), (B58, "b58"), (B32, "b32")):
    letters_family(alpha, label)

@fam("base64_bare")
def _(sec):
    s = base64.b64encode(sec).decode()
    return rnd.choice(["", "state=active "]) + s + " ice=connected", [s]

@fam("base64url_split")
def _(sec):
    s = base64.urlsafe_b64encode(sec).decode().rstrip("=")
    k = rnd.choice([4, 6, 8, 10, 11]); bl = chunks(s, k)
    return "state=active " + join_with_fill(bl, "fill"), bl

@fam("base64_kv")
def _(sec):
    s = base64.b64encode(sec).decode()
    k = rnd.choice(["token", "data", "x", "blob", "val", "k0", "session", "peer"])
    return "%s=%s state=active" % (k, s), [s]

@fam("hex")
def _(sec):
    s = sec.hex(); s = s.upper() if rnd.random() < 0.3 else s
    k = rnd.choice([0, 6, 8, 11, 16])
    bl = [s] if not k else chunks(s, k)
    return "state=active " + join_with_fill(bl, "fill"), bl

@fam("hex_kv_blocks")
def _(sec):
    s = sec.hex(); bl = chunks(s, rnd.choice([4, 6, 8, 11]))
    keys = ["a", "x", "id", "g", "to", "peer", "fp", "h", "q", "z", "val", "chunk"]
    toks = ["%s=%s" % (rnd.choice(keys), b) for b in bl]
    return "state=active " + " ".join(toks), bl

@fam("hex_spaced_pairs")
def _(sec):
    s = " ".join("%02x" % b for b in sec)
    return "state=active " + s, [s]

@fam("jwt")
def _(sec):
    a = base64.urlsafe_b64encode(b'{"alg":"none"}').decode().rstrip("=")
    b = base64.urlsafe_b64encode(sec).decode().rstrip("=")
    c = base64.urlsafe_b64encode(sec[::-1]).decode().rstrip("=")
    return rnd.choice(["", "token=", "auth ", "jwt="]) + "%s.%s.%s state=active" % (a, b, c), [b, c]

@fam("uuid_id")
def _(sec):
    h = sec[:16].hex(); u = "%s-%s-%s-%s-%s" % (h[:8], h[8:12], h[12:16], h[16:20], h[20:32])
    return rnd.choice(["id=%s role=caller", "peer=%s state=active", "call_id=%s", "user %s ok", "uid:%s"]) % u, [u, h[:8]]

@fam("ipv4")
def _(sec):
    ip = ".".join(str(b) for b in sec[:4])
    return rnd.choice(["ip=%s role=caller", "from %s state=active", "addr:%s", "srflx %s"]) % ip, [ip]

@fam("ipv6")
def _(sec):
    g = ["%x" % int.from_bytes(sec[i:i + 2], "big") for i in range(0, 16, 2)]
    ip = ":".join(g) if rnd.random() < 0.5 else "%s:%s::%s" % (g[0], g[1], g[7])
    return rnd.choice(["ip=%s role=caller", "peer %s state=active"]) % ip, [ip]

@fam("email")
def _(sec):
    u = base64.b32encode(sec[:6]).decode().lower().rstrip("=")
    e = "%s@example.com" % u
    return rnd.choice(["mail=%s state=active", "from %s ok", "user %s"]) % e, [e, u]

@fam("phone")
def _(sec):
    p = "+39" + "".join(str(b % 10) for b in sec[:10])
    return rnd.choice(["phone=%s state=active", "call %s ok", "tel:%s", "dial %s"]) % p, [p, p[3:]]

@fam("psk_words")
def _(sec):
    n = rnd.choice([4, 6, 8])
    ws = [WORDS[b % len(WORDS)] for b in sec[:n]]
    sep = rnd.choice([" ", "-", "_", ","])
    return rnd.choice(["psk=", "verify ", "", "state=active ", "words: "]) + sep.join(ws), ws

@fam("sas_words")
def _(sec):
    ws = [WORDS[b % len(WORDS)] for b in sec[:4]]
    return rnd.choice(["sas ", "SAS: ", "safety number ", "emoji ", "peer ok "]) + " ".join(ws), ws

@fam("psk_words_fill")
def _(sec):
    ws = [WORDS[b % len(WORDS)] for b in sec[:6]]
    return "state=active " + join_with_fill(ws, "fill"), ws

def numlist(sec, sep, bracket, k=None):
    nums = [str(b) for b in (sec if k is None else sec[:k])]
    s = sep.join(nums)
    return {"": s, "[]": "[" + s + "]", "()": "(" + s + ")", "{}": "{" + s + "}", "<>": "<" + s + ">"}[bracket]

@fam("bytelist_dec")
def _(sec):
    sep = rnd.choice([",", ", ", ";", "; ", " ", "|", "/", ".", ":", "-", "\t", "\n", " , ", ",,"])
    br = rnd.choice(["", "[]", "()", "{}", "<>"])
    lead = rnd.choice(["", "derived_key ", "bytes ", "k ", "secret ", "hkdf out ", "x "])
    s = numlist(sec, sep, br)
    return lead + s + rnd.choice(["", " len 32", " state=active ice=connected"]), [str(b) for b in sec[:8]]

@fam("bytelist_dec_chunks")
def _(sec):
    k = rnd.choice([3, 4, 5, 6, 7])
    bl = [",".join(str(b) for b in sec[i:i + k]) for i in range(0, len(sec), k)]
    return "state=active " + join_with_fill(bl, "fill"), bl

@fam("bytelist_hex")
def _(sec):
    sep = rnd.choice([" ", ",", ":", "-", ";", ", ", "|"])
    pre = rnd.choice(["", "0x"])
    s = sep.join(pre + "%02x" % b for b in sec)
    return rnd.choice(["", "k ", "bytes "]) + s + " state=active", [s[:12]]

@fam("bytes_single_interleaved")
def _(sec):
    # KNOWN-OPEN residual: one number per token between vocabulary words looks exactly
    # like a call-statistics line; not asserted (reported only).
    toks = []
    for b in sec:
        toks.append(rnd.choice(["rtt", "loss", "seq", "ok", "active", "count"]))
        toks.append(str(b))
    return "state=active " + " ".join(toks), [str(b) for b in sec[:8]]

@fam("bytes_kv_indexed")
def _(sec):
    stem = rnd.choice(["k", "b", "byte", "x", "q"])
    toks = ["%s%d=%d" % (stem, i, b) for i, b in enumerate(sec)]
    return "state=active " + " ".join(toks), toks[:8]

@fam("bytes_kv_keys")
def _(sec):
    keys = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t"]
    toks = ["%s=%d" % (keys[i % len(keys)] + (str(i // len(keys)) if i >= len(keys) else ""), b) for i, b in enumerate(sec)]
    return "state=active " + " ".join(toks), toks[:8]

@fam("num_tok_suffix")
def _(sec):
    s = enc_base(sec, B62)
    bl = ["%d%s" % (rnd.randrange(10), "".join(rnd.choice(B26) for _ in range(rnd.randrange(3, 11)))) for _ in range(6)]
    return "state=active " + " ".join(bl), bl

@fam("kv_key_carrier")
def _(sec):
    s = enc_base(sec, B26); bl = chunks(s, rnd.choice([5, 8, 11, 14]))
    toks = ["%s=%s" % (b, rnd.choice(["1", "true", "0"])) for b in bl]
    return "state=active " + " ".join(toks), bl

@fam("kv_empty_value_carrier")
def _(sec):
    s = enc_base(sec, B26); bl = chunks(s, rnd.choice([4, 7, 10, 11]))
    return "state=active " + " ".join(b + ":" for b in bl), bl

@fam("kv_value_short")
def _(sec):
    s = enc_base(sec, B26); bl = chunks(s, rnd.choice([3, 5, 7, 9]))
    toks = ["%s=%s" % (rnd.choice("abcdefghijklmnopqrstuvwxyz"), b) for b in bl]
    return "state=active " + " ".join(toks), bl

@fam("enum_channel")
def _(sec):
    s = enc_base(sec, B26); bl = chunks(s, rnd.choice([6, 8, 11]))
    keys = ["state", "reason", "mode", "kind", "role", "status", "type", "phase"]
    toks = ["%s=%s" % (keys[i % len(keys)], b) for i, b in enumerate(bl)]
    return " ".join(toks), bl

@fam("vtag_version_epoch")
def _(sec):
    ch = chunks(enc_base(sec, B26), 8)
    toks = ["chunk%d=v1-%s" % (i, c) for i, c in enumerate(ch)]
    toks += ["netSeq=%d.%d.%d" % (sec[i], sec[i + 1], sec[i + 2]) for i in range(0, 9, 3)]
    toks += ["somethingCached=1%s" % "".join(str(b % 10) for b in sec[i:i + 9]) for i in (0, 9, 18)]
    return "state=active " + " ".join(toks), ch + [t.split("=")[1] for t in toks[len(ch):]]

@fam("unicode_homoglyph_b64")
def _(sec):
    s = base64.b64encode(sec).decode().replace("+", "").replace("/", "").replace("=", "")
    parts = chunks(s, rnd.choice([10, 11]))
    line = " ".join(homoglyph(p) for p in parts)
    return "state=active " + line, parts

@fam("unicode_homoglyph_glued")
def _(sec):
    s = enc_base(sec, B52)
    g = homoglyph(s)
    return "state=active " + g, chunks(s, 11)

@fam("zero_width_b64")
def _(sec):
    s = base64.b64encode(sec).decode()
    return "state=active " + zw(s), [s[:16]]

@fam("fullwidth_kv")
def _(sec):
    s = base64.b64encode(sec).decode()
    return fullwidth("token=" + s + " state=active"), [s]

@fam("split_short_2_1")
def _(sec):
    s = enc_base(sec, B26); bl = chunks(s, rnd.choice([1, 2]))
    return "state=active " + " ".join(bl), bl

@fam("hyphen_joined")
def _(sec):
    s = enc_base(sec, B26); bl = chunks(s, rnd.choice([2, 3, 4]))
    toks = ["-".join(bl[i:i + 3]) for i in range(0, len(bl), 3)]
    return "state=active " + " ".join(toks), bl

@fam("underscore_joined")
def _(sec):
    s = enc_base(sec, B26); bl = chunks(s, rnd.choice([3, 4, 5]))
    toks = ["_".join(bl[i:i + 2]) for i in range(0, len(bl), 2)]
    return "state=active " + " ".join(toks), bl

@fam("camel_blocks")
def _(sec):
    s = enc_base(sec, B52); bl = chunks(s, rnd.choice([6, 8, 11]))
    return "state=active " + " ".join(bl), bl

@fam("in_json")
def _(sec):
    s = base64.b64encode(sec).decode()
    return '{"state":"active","k":"%s","n":1}' % s, [s]

@fam("long_line")
def _(sec):
    s = enc_base(sec, B26); bl = chunks(s, 9)
    return ("state=active ice=connected " * 12) + " ".join(bl), bl

def leak_fraction(body, blocks):
    """fraction of secret-bearing characters (blocks >= 3 chars) still verbatim in body"""
    blocks = list(dict.fromkeys(b for b in blocks if len(b) >= 3))   # unique blocks
    tot = sum(len(b) for b in blocks)
    if not tot:
        return 0.0
    left = sum(len(b) for b in blocks if b in body)
    return left / tot

KNOWN_OPEN = {"bytes_single_interleaved"}
if IS_SERVER:
    # the server leg has never had the key-byte list / compressed-IPv6 rules of the
    # iOS leg (not part of the 2026-09-24 red-team findings; server lines are
    # server-authored). Reported, not asserted.
    KNOWN_OPEN |= {"bytelist_dec", "bytelist_hex", "hex_spaced_pairs", "ipv6"}
THRESH = 0.5001   # a case LEAKS when MORE THAN 50% of its secret-bearing characters survive verbatim
stats = collections.defaultdict(lambda: [0, 0, 0.0, 0.0])   # n, leaks, max_frac, sum_frac
leaks = []
names = sorted(fams)
for i in range(N):
    name = names[i % len(names)]
    ln = rnd.choice([16, 24, 32, 32, 32, 48, 64])
    sec = bytes(rnd.randrange(256) for _ in range(ln))
    tag = rnd.choice(["stdout", "call", "crypto", "net", "media"])
    line, blocks = fams[name](sec)
    body = R(line, tag)
    frac = leak_fraction(body, blocks)
    st = stats[name]
    st[0] += 1
    st[2] = max(st[2], frac); st[3] += frac
    if frac >= THRESH:
        st[1] += 1
        if name not in KNOWN_OPEN and len(leaks) < 40:
            leaks.append((name, line[:160], body[:160]))
tot_leaks = sum(v[1] for k, v in stats.items() if k not in KNOWN_OPEN)
print("%-28s %5s %6s %8s %8s" % ("family", "cases", "leaks", "maxfrac", "meanfrac"))
for name in names:
    n, l, mx, sm = stats[name]
    print("%-28s %5d %6d %8.2f %8.3f%s" % (name, n, l, mx, sm / max(n, 1), "   (known-open, not asserted)" if name in KNOWN_OPEN else ""))
print("TOTAL cases=%d leaks(>%.0f%%)=%d" % (N, THRESH * 100, tot_leaks))
if "--show" in sys.argv:
    for name, line, body in leaks[:10]:
        print("  LEAK[%s] line=%r -> body=%r" % (name, line, body))
sys.exit(1 if tot_leaks else 0)
