#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The QA-VOICE lines of the contact-voice check must survive the phone-log shipper (scripts/ship-ios-logs.py) VERBATIM, and only
that exact grammar. The lines are written by QAudionEngine (VoiceEngine for the per-call lines, VoiceDailyCounters for the daily
counters) through RTLog.info("call", ...). There are ten shapes:

    QA-VOICE v=1 ev=day calls= off= match= chk= nover= diff= sdiff= chg= schg= hs= spk= hf= unk= newdev= enr= enrtot= lrn= mk=
    QA-VOICE v=1 ev=dstr st=<1-4> calls= sdiff= m1= m2= m3= m4=
    QA-VOICE v=1 ev=start call=<8 hex> own= peer= tier= path= model=
    QA-VOICE v=1 ev=tap call=<8 hex> src=rx hz= cbmin= cbmax= n=
    QA-VOICE v=1 ev=store call=<8 hex|-> op= res= why=
    QA-VOICE v=1 ev=cstate call=<8 hex> st=
    QA-VOICE v=1 ev=state call=<8 hex> from= to= t= nw= blk= shown=
    QA-VOICE v=1 ev=learn call=<8 hex> from= to= ns= sp= days= why=
    QA-VOICE v=1 ev=upd call=<8 hex> res=
    QA-VOICE v=1 ev=end call=<8 hex> res= shadow= dur= vsp= acc= unc= blk= rsnr= rclip= rplc= rdt= rnb= rmix= rskip= rown= margin= sc= cov= newdev= emb50= emb95= vad95= route=

No line has a contact, a name, a number of the user, a score or a threshold. The generic structured gate cannot read them (bare
line names, `chk=` and the like are identity-word or unknown-word keys), so they are accepted by a whole-line rule; this test pins
that the rule is exactly that narrow. It also pins that a score line of the older owner-voice monitor, which carries a biometric
number, is never shipped verbatim by this rule.

Run:  python scripts/test_ship_ios_voice_vocab.py [path/to/ship-ios-logs.py]
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


P = "QA-VOICE v=1 ev="
DAY = (P + "day calls=12 off=1 match=9 chk=1 nover=1 diff=0 sdiff=0 chg=0 schg=2 hs=6 spk=4 hf=2 unk=0 newdev=1 enr=3 enrtot=11 lrn=2 mk=0")
DSTR = P + "dstr st=3 calls=4 sdiff=0 m1=2 m2=1 m3=0 m4=0"
START = P + "start call=5a000000 own=1 peer=- tier=0 path=srtp model=ok"
TAP = P + "tap call=5a000000 src=rx hz=48000 cbmin=480 cbmax=480 n=200"
STORE = P + "store call=- op=wipe res=ok why=account"
CSTATE = P + "cstate call=5a000000 st=lrn"
STATE = P + "state call=5a000000 from=off to=lrn t=0 nw=0 blk=0 shown=1"
LEARN = P + "learn call=5a000000 from=lrn to=prov ns=1 sp=62 days=1 why=added"
UPD = P + "upd call=5a000000 res=skip_tier"
END = (P + "end call=5a000000 res=na shadow=na dur=312 vsp=140 acc=21 unc=3 blk=3 rsnr=1 rclip=0 rplc=2 rdt=40 rnb=0 rmix=1 rskip=0 "
       "rown=0 margin=1 sc=- cov=0 newdev=0 emb50=210 emb95=480 vad95=2 route=ear")

OKAY = [
    DAY, DSTR, START, TAP, STORE, CSTATE, STATE, LEARN, UPD, END,
    # every value of every closed set, and the limits of every range
    DAY.replace("calls=12", "calls=9999").replace("mk=0", "mk=999").replace("enr=3", "enr=999"),
    DSTR.replace("st=3", "st=1"), DSTR.replace("st=3", "st=4"),
    START.replace("own=1", "own=0").replace("peer=-", "peer=1").replace("tier=0", "tier=2").replace("path=srtp", "path=dc")
        .replace("model=ok", "model=fail"),
    START.replace("peer=-", "peer=0").replace("tier=0", "tier=1").replace("model=ok", "model=na"),
    TAP.replace("hz=48000", "hz=16000"), TAP.replace("hz=48000", "hz=24000"), TAP.replace("hz=48000", "hz=32000"),
    TAP.replace("hz=48000", "hz=other").replace("cbmax=480", "cbmax=99999").replace("n=200", "n=9999"),
    STORE.replace("call=-", "call=0a1b2c3d").replace("op=wipe", "op=delete").replace("why=account", "why=contact"),
    STORE.replace("op=wipe", "op=write").replace("res=ok", "res=fail").replace("why=account", "why=-"),
    STORE.replace("op=wipe", "op=read").replace("res=ok", "res=absent").replace("why=account", "why=reinstall"),
    STORE.replace("op=wipe", "op=migrate").replace("res=ok", "res=stale").replace("why=account", "why=legacy"),
    CSTATE.replace("st=lrn", "st=off"), CSTATE.replace("st=lrn", "st=prov"), CSTATE.replace("st=lrn", "st=enr"),
    CSTATE.replace("st=lrn", "st=ref"),
    STATE.replace("from=off to=lrn", "from=chk to=match"), STATE.replace("from=off to=lrn", "from=diff to=nover"),
    STATE.replace("from=off to=lrn", "from=chg to=chk").replace("t=0", "t=99999").replace("shown=1", "shown=0"),
    LEARN.replace("from=lrn to=prov", "from=none to=lrn").replace("why=added", "why=short"),
    LEARN.replace("from=lrn to=prov", "from=prov to=enr").replace("why=added", "why=enrolled").replace("ns=1", "ns=8"),
    LEARN.replace("why=added", "why=slota").replace("sp=62", "sp=9999").replace("days=1", "days=9"),
    UPD.replace("skip_tier", "applied"), UPD.replace("skip_tier", "bound"), UPD.replace("skip_tier", "rate"),
    UPD.replace("skip_tier", "skip_state"), UPD.replace("skip_tier", "skip_short"), UPD.replace("skip_tier", "skip_off"),
    UPD.replace("skip_tier", "skip_cond"),
    END.replace("res=na", "res=match").replace("shadow=na", "shadow=diff").replace("route=ear", "route=spk"),
    END.replace("res=na", "res=nover").replace("sc=-", "sc=3").replace("route=ear", "route=bt").replace("cov=0", "cov=1"),
    END.replace("res=na", "res=off").replace("route=ear", "route=wired").replace("margin=1", "margin=4"),
    END.replace("route=ear", "route=car").replace("newdev=0", "newdev=1").replace("vad95=2", "vad95=999"),
    END.replace("route=ear", "route=unk").replace("dur=312", "dur=99999").replace("vsp=140", "vsp=99999"),
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
    for line in (END, DAY):
        checks += 1
        if red(line, tag) == line:
            failures.append("the rule leaked under tag %r" % tag)

FORGED = []
for base in (DAY, DSTR, START, TAP, STORE, CSTATE, STATE, LEARN, UPD, END):
    FORGED += [
        base + " ",
        base + "\n",
        base + " extra=1",
        base + " hello world",
        base + " +39 333 1234567",
        base + " 192.168.1.20",
        base + " dGhpcyBpcyBhIHNlY3JldCBibG9iIQ==",
        " " + base,
        "x " + base,
        "peer said: " + base,
        base + "\n" + base,
        base.replace("QA-VOICE", "qa-voice"),
        base.replace("QA-VOICE", "QA-VOICEX"),
        base.replace("v=1", "v=2"),
        base.replace("ev=", "ev= "),
        base + "​",
    ]
for base in (START, TAP, CSTATE, STATE, LEARN, UPD, END):
    FORGED += [
        base.replace("call=5a000000", "call=5a00000"),
        base.replace("call=5a000000", "call=5a0000000"),
        base.replace("call=5a000000", "call=5A000000"),
        base.replace("call=5a000000", "call=alice-bo"),
        base.replace("call=5a000000", "call=-"),
        base.replace("call=5a000000", "call=5a000000 call=5a000000"),
        base.replace("call=5a000000 ", ""),
    ]

FORGED += [
    # out-of-set and out-of-range values
    DAY.replace("calls=12", "calls=10000"), DAY.replace("calls=12", "calls=-1"), DAY.replace("calls=12", "calls=1.5"),
    DAY.replace("enr=3", "enr=1000"), DAY.replace("mk=0", "mk=1000"), DAY.replace("hs=6", "hs=x"),
    DAY.replace(" mk=0", ""), DAY.replace("off=1 match=9", "match=9 off=1"), DAY + " score=0.8",
    DSTR.replace("st=3", "st=0"), DSTR.replace("st=3", "st=5"), DSTR.replace("m4=0", "m4=10000"), DSTR.replace(" m4=0", ""),
    START.replace("own=1", "own=2"), START.replace("peer=-", "peer=2"), START.replace("tier=0", "tier=3"),
    START.replace("path=srtp", "path=udp"), START.replace("model=ok", "model=Alice"),
    TAP.replace("hz=48000", "hz=44100"), TAP.replace("src=rx", "src=tx"), TAP.replace("cbmin=480", "cbmin=100000"),
    TAP.replace("n=200", "n=10000"),
    STORE.replace("call=-", "call=alice"), STORE.replace("op=wipe", "op=erase"), STORE.replace("res=ok", "res=maybe"),
    STORE.replace("why=account", "why=alice"), STORE.replace("why=account", "why=contact:alice"),
    CSTATE.replace("st=lrn", "st=maybe"), CSTATE.replace("st=lrn", "st=none"),
    STATE.replace("from=off", "from=maybe"), STATE.replace("to=lrn", "to=cannot_verify"), STATE.replace("shown=1", "shown=2"),
    STATE.replace("t=0", "t=100000"), STATE.replace("nw=0", "nw=10000"), STATE.replace("blk=0", "blk=1000"),
    LEARN.replace("from=lrn", "from=off"), LEARN.replace("ns=1", "ns=9"), LEARN.replace("days=1", "days=10"),
    LEARN.replace("sp=62", "sp=10000"), LEARN.replace("why=added", "why=alice"),
    UPD.replace("skip_tier", "skip_alice"), UPD.replace("skip_tier", "applied bound"),
    END.replace("res=na", "res=maybe"), END.replace("shadow=na", "shadow=maybe"), END.replace("margin=1", "margin=5"),
    END.replace("sc=-", "sc=10"), END.replace("sc=-", "sc=0.5"), END.replace("cov=0", "cov=2"), END.replace("newdev=0", "newdev=2"),
    END.replace("vad95=2", "vad95=1000"), END.replace("route=ear", "route=Alice"), END.replace("route=ear", "route=pocket"),
    END.replace("dur=312", "dur=100000"), END.replace("acc=21", "acc=10000"), END.replace("blk=3 ", "blk=1000 "),
    END.replace(" sc=-", ""), END.replace("rsnr=1 rclip=0", "rclip=0 rsnr=1"),
    # a number that is a measured value: an LLR, a score, a threshold, a ratio
    END.replace("margin=1", "margin=1 llr=-3.2"), END.replace("margin=1", "margin=0.84"), STATE.replace("blk=0", "blk=0 b=0.61"),
    # the same numbers under other keys and in other notations (integer, negative, scientific, a key that ends in the word)
    END.replace("margin=1", "margin=1 asnorm_score=0.71"), END.replace("margin=1", "margin=1 vpscore=0.82"),
    END.replace("margin=1", "margin=1 llr=-3"), END.replace("margin=1", "margin=1 cos=1e-3"),
    END.replace("margin=1", "margin=1 score=3"), END.replace("margin=1", "margin=1 similarity: .5"),
    "QA-VOICE v=1 [OwnerCont] cos=0.83 v=0.42",
    P + "end call=5a000000 cos=0.83 v=0.42",
    P + "score call=5a000000 v=0.83",
    P + "end " + "a" * 200,
]

for line in FORGED:
    for tag in ("call", "stdout"):
        checks += 1
        if red(line, tag) == line:
            failures.append("forged line shipped verbatim: %r" % (line,))
        checks += 1
        if shipped(line, tag) == line:
            failures.append("forged line shipped verbatim by build_log_record: %r" % (line,))

# The score line of the owner-voice monitor (a biometric number) is not a shape of this grammar: the whole-line rule refuses it, in
# every tag, and so it can never be carried by a QA-VOICE line. (The line itself is no longer printed by the app; the generic gate
# of the shipper is not what refuses it, this rule is what keeps the family closed.)
for line in ("[OwnerCont] cos=0.83 v=0.42", "[OwnerCont] cos=0.91 v=0.77 lv=ok", "[OwnerCont] lv=unc", "[OwnerCont] learn_stage=keep"):
    checks += 1
    if m._RE_VOICE_FULL.match(line):
        failures.append("the voice rule accepts an owner-voice line: %r" % (line,))
    for tag in ("call", "stdout", "chat", "net", "ice", "media", "crypto"):
        checks += 1
        if "cos=" in line and shipped(line, tag) is not None:
            failures.append("a score line was shipped under %r: %r" % (tag, line))

# The measure rule: every notation of a voice number is dropped whatever the tag, and the neighbours that only look like it stay.
MEASURES = ["asnorm_score=0.71", "vpscore=0.82", "llr=-3", "cos=1e-3", "score=3", "cosine = -0.5", "logit=+2", "similarity:.25",
            "voice.score=0.1", "X_LLR=4E+2"]
for text in MEASURES:
    line = "voice check done " + text + " ok"
    checks += 1
    if not m._RE_VOICE_MEASURE.search(line.lower()):
        failures.append("the measure rule misses %r" % text)
    for tag in ("call", "stdout", "chat", "net"):
        checks += 1
        if red(line, tag) != "" or shipped(line, tag) is not None:
            failures.append("a voice measure was shipped under %r: %r" % (tag, line))
NEIGHBOURS = ["scale=0.5", "cost=3", "scoreboard=1", "scores=3", "cosmos=7", "sc=-", "sc=3", "llr=na", "score=none", "logit_count=4",
              "similarity_mode=fast", "cosine_table=ready", "latency=0.5", "calls=12", "margin=1", "t=1e-3"]
for text in NEIGHBOURS:
    checks += 1
    if m._RE_VOICE_MEASURE.search(("call 5a000000 " + text).lower()):
        failures.append("the measure rule refuses a neighbour: %r" % text)

# The pattern itself: one whole-line alternation, no other pattern accepts these lines.
checks += 1
if not getattr(m, "_RE_VOICE_FULL", None):
    failures.append("_RE_VOICE_FULL is missing")

print("%d checks, %d failures" % (checks, len(failures)))
for f in failures:
    print("FAIL:", f)
sys.exit(1 if failures else 0)
