#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
BLOCK (2026-10-19) -- the `block drop=1 kind=<k>` lines the app writes when it drops something from a contact the user
blocked must survive the phone-log shipper's vocabulary gate (scripts/ship-ios-logs.py) VERBATIM. They are the only
evidence, in a log pull, that a block held: a message, a call offer, a push, a group invite or a notification that
arrived from a blocked contact and was dropped. A line the redactor drops or rewrites leaves "did the block work?"
unanswerable again (the first version of these lines shipped only 6 of 11 kinds).

The shapes below are the exact lines of the app, by tag:
  chat   msg undec svc mesh file            (QAudionApp/AppState.swift)
  call   offer opaque missed notif grpcall  (AppState.swift; notif also NotificationCenterService.swift)
  call   push id=<8 hex>  grpcall id=<8 hex>  (the PushKit report-and-end of a blocked caller / group creator)
  group  grp                                (AppState.applyMemberAdded / handleGroupMembershipChanged)
Keep the three in sync.

The kind words that are not general vocabulary (svc, file, missed, notif, grpcall, opaque) are accepted ONLY on these
exact lines (BLOCK_FORMAT_VOCAB, whole-line match, tags chat / call / group): the second half of this test pins that they
did not become vocabulary for every other line.

Run:  python scripts/test_ship_ios_block_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every line ships verbatim; 1 = at least one was dropped or altered.
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


TARGET = (sys.argv[1] if len(sys.argv) > 1 else
          os.path.join(os.path.dirname(os.path.abspath(__file__)), "ship-ios-logs.py"))
m = load(TARGET)


def shipped(line, tag):
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


def kind(k):
    return "block drop=1 kind=" + k


def with_id(k, id8):
    return kind(k) + " id=" + id8


# (tag, line)
LINES = [
    # chat
    ("chat", kind("msg")),
    ("chat", kind("undec")),
    ("chat", kind("svc")),
    ("chat", kind("mesh")),
    ("chat", kind("file")),
    # call
    ("call", kind("offer")),
    ("call", kind("opaque")),
    ("call", kind("missed")),
    ("call", kind("notif")),
    ("call", kind("grpcall")),
    # PushKit report-and-end of a blocked 1:1 caller and of a blocked group creator
    ("call", with_id("push", "b0d7ba30")),
    ("call", with_id("push", "eb2a6367")),
    ("call", with_id("grpcall", "1bc455b8")),
    ("call", with_id("grpcall", "ffffffff")),
    # group
    ("group", kind("grp")),
]

failures = []
for tag, text in LINES:
    got = shipped(text, tag)
    if got != text:
        failures.append("[%s] %r -> %r" % (tag, text, got))

# A call id whose first 8 characters are all digits: `id=<digits>` is the shape the redactor masks as a phone number.
# The app cannot control the digits of a call id, so this is the case to know about: it must not leak the digits,
# whatever it becomes (it may be summarised, it must not ship as a number).
digits = shipped(with_id("push", "12345678"), "call")
if digits is not None and "12345678" in digits:
    failures.append("[call] an all-digit call id head shipped verbatim: %r" % (digits,))

# Nothing of a contact rides on these lines: a body that carries a name or a user id must not ship it.
for tag, text in [
    ("call", kind("offer") + " from=Anna"),
    ("chat", kind("msg") + " peer=00000000-0000-4000-8000-000000000001"),
]:
    got = shipped(text, tag)
    if got is not None and ("Anna" in got or "00000000-0000-4000-8000-000000000001" in got):
        failures.append("[%s] identity leaked: %r -> %r" % (tag, text, got))

# The mesh packet used to be logged under the tag "mesh", which the shipper's tag gate drops: it must stay under "chat".
if shipped(kind("mesh"), "mesh") is not None:
    failures.append("the tag 'mesh' ships now: re-check this test's premise (the app logs kind=mesh under 'chat')")

# --- Scoping: the block-only words are not general vocabulary -------------------------------------------------------
BLOCK_WORDS = ["svc", "file", "missed", "notif", "grpcall", "opaque"]
checks = 0

# 1. Not in the global vocabularies, so no other line spends them for free.
for word in BLOCK_WORDS:
    checks += 1
    if word in m.APP_VOCAB or word in m.TELEMETRY_VOCAB or m._word_known(word):
        failures.append("'%s' is general vocabulary again: it must only be known on the block lines" % word)

# 2. The recognised shape is the whole line, under the three tags only.
for tag in ["chat", "call", "group"]:
    checks += 1
    if not m._is_block_format_body(tag, kind("svc")):
        failures.append("[%s] the exact block line is not recognised" % tag)
for tag, body in [
    ("net", kind("svc")),                         # another tag
    ("avatar", kind("file")),                     # another tag
    ("chat", kind("svc") + " extra=1"),           # something after it
    ("chat", "x " + kind("svc")),                 # something before it
    ("chat", "block drop=1 kind=bogus"),          # a kind the app never writes
    ("call", "block drop=1 kind=offer id=b0d7ba30"),   # offer carries no call id
    ("call", "block drop=1 kind=push id=B0D7BA30"),    # the call id head is lower-case hex
    ("call", "block drop=1 kind=push id=b0d7ba3"),     # exactly 8 characters
    ("chat", "svc file missed notif grpcall"),    # the words alone
    (None, kind("svc")),
]:
    checks += 1
    if m._is_block_format_body(tag, body):
        failures.append("[%s] %r must not widen the vocabulary" % (tag, body))

# 3. A body outside the shape that uses the words does not ship them: no unknown-word slot is gained.
for tag, body in [
    ("chat", "svc file missed notif grpcall"),
    ("chat", kind("svc") + " file=notif"),
    ("net", kind("svc")),
]:
    checks += 1
    got = shipped(body, tag)
    if got == body:
        failures.append("[%s] %r shipped verbatim although it is not a block line" % (tag, body))

# 4. The scoped vocabulary is switched off again after a block line (it must not leak into the next line).
checks += 1
shipped(kind("svc"), "chat")
if m._active_extra_vocab != frozenset():
    failures.append("the block vocabulary stayed active after the line")
checks += 1
if shipped("svc file missed notif grpcall", "chat") == "svc file missed notif grpcall":
    failures.append("the block vocabulary leaked into the next line")

# --- The kinds the app writes are the kinds this test pins -------------------------------------------------------------
# A new "block drop=1 kind=<k>" in the app that is not in LINES above (and in the shipper's whole-line rule) would be
# summarised again and the traffic it records would stay invisible. Only the two files that write these lines are read.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PINNED = set(re.findall(r"kind=([a-z]+)", " ".join(text for _, text in LINES)))
SOURCES = ["QAudionApp/AppState.swift", "QAudionApp/Services/NotificationCenterService.swift"]
seen = set()
for rel in SOURCES:
    checks += 1
    path = os.path.join(ROOT, *rel.split("/"))
    if not os.path.exists(path):
        failures.append("%s not found: the kinds the app writes cannot be compared" % rel)
        continue
    with open(path, encoding="utf-8") as handle:
        seen.update(re.findall(r"block drop=1 kind=([a-z]+)", handle.read()))
checks += 1
if not seen:
    failures.append("no 'block drop=1 kind=' line found in the app sources: the comparison is empty")
for k in sorted(seen - PINNED):
    failures.append("the app writes 'block drop=1 kind=%s' but this test (and the shipper rule) do not pin it" % k)
for k in sorted(PINNED - seen):
    failures.append("this test pins kind=%s but the app no longer writes it" % k)

total = len(LINES) + 3 + checks
print("checks: %d, failures: %d" % (total, len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
