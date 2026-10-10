#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""
The display-work marker lines (DisplayWorkMarker.line in QAudionEngine) must survive the phone-log shipper's
vocabulary gate (scripts/ship-ios-logs.py) VERBATIM, under the "call" tag: they are what tells "display-only call
work paused in the background" (bg=1) from "ran and measured zero" in a call's log. Keep in sync with
DisplayWorkMarker and BackgroundDisplayWorkTests.

The same gate covers the check-period lines of the contact-voice check (ContactVoiceVerifier.cadenceLine, printed
through the stdout tee, tag "stdout"): they say which period is active ("[Voice] bg=1 every=10"). Keep in sync with
ContactVoiceVerifier.cadenceLine and BackgroundCadenceTests.

And the CPU-governor summary lines (BackgroundCpuGovernor.Summary.logLine, same stdout tee): the measured average
CPU as a percentage of one core, the checks skipped and run since the previous summary, and whether checks are
being held back ("[Voice] bg=1 every=10 cpu=42 skip=3 run=2 high=0", "[Guardian] bg=1 cpu=250 skip=0 run=7 high=1").
Keep in sync with BackgroundCpuGovernor and BackgroundCpuGovernorTests.

And the numeric diagnostics of a call (CallResourceLine.line and CallResourceLine.answerLine, same stdout tee): the
process CPU over the last interval as a percentage of one core, the raw application state (0 active, 1 inactive,
2 background), whether protected data is not available, the thermal state (0 nominal .. 3 critical) and whether Low
Power Mode is on ("[Call] cpu=42 st=0 lock=0 therm=0 low=0"), and, once per answered incoming call,
"[Call] answer st=0 lock=0". Whole numbers only, words already admitted. Keep in sync with CallResourceLine and
CallResourceLoggerTests.

And the avatar lines that say why a picture was or was not sent or applied (tag "avatar", AvatarAnnounceCoordinator.logSent,
logSkip and logInbound): "send ok=1 ... why=1|2|3 bytes=N side=L min=S" (why: 1 content changed, 2 new contact device, 3 asked for,
reserved; bytes and pixels of the file sent), "skip same ... code=4" (same content already sent), "skip call ... code=5" (inside the
first seconds of a call), "skip brake ... code=5" (right after an attempt: anti-burst brake), "resize bytes=N out=K side=L min=S" (a local file above the avatar rule was resized once for sending), and the receive lines
"recv applied=1 bytes=N out=K side=L min=S" (a picture applied: bytes received, bytes kept in the cache after the reduction),
"recv applied=0 code=8 kind=1|2 bytes=N" (image cut short), "code=9 bytes=N"
(same picture as the one kept). Numbers only, words already admitted. A shipped line may carry at most two long numbers or
hex ids: that is why the send line has no "version", and why the width/height keys are "side" and "min" (a key like "w" or
"width" drops the whole line). The lines that carry a sender id with the key "from" are not here because the shipper redacts that
key by design. Keep in sync with AvatarAnnounceCoordinator and AvatarAnnounceReductionTests.

Run:  python scripts/test_ship_ios_display_vocab.py [path/to/ship-ios-logs.py]
Exit 0 = every line ships verbatim; 1 = at least one was dropped or altered.
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


def shipped(line, tag="call"):
    rec = m.build_log_record({"ms": 1, "lvl": "I", "tag": tag, "msg": line})
    return rec["body"]["stringValue"] if rec else None


LINES = ["display bg=1", "display bg=0"]

# Same text as ContactVoiceVerifier.cadenceLine (whole seconds), shipped under the stdout tee's tag.
CADENCE_LINES = ["[Voice] bg=1 every=10", "[Voice] bg=0 every=3", "[Voice] bg=1 every=12", "[Voice] bg=1 every=9"]

GOVERNOR_LINES = [
    "[Voice] bg=1 every=10 cpu=42 skip=3 run=2 high=0",
    "[Voice] bg=1 every=10 cpu=90 skip=1 run=2 high=1",
    "[Voice] bg=0 every=3 cpu=30 skip=0 run=1 high=0",
    "[Voice] bg=1 every=10 cpu=0 skip=0 run=3 high=0",
    "[Voice] bg=1 every=12 cpu=9999 skip=9999 run=9999 high=1",
    "[Guardian] bg=1 cpu=250 skip=0 run=7 high=1",
    "[Guardian] bg=1 cpu=48 skip=2 run=1 high=0",
    "[Guardian] bg=0 cpu=30 skip=0 run=1 high=0",
]

# Same text as CallResourceLine.line: every state, both ends of the CPU range, every flag on and off.
CALL_RESOURCE_LINES = [
    "[Call] cpu=42 st=0 lock=0 therm=0 low=0",
    "[Call] cpu=0 st=0 lock=0 therm=0 low=0",
    "[Call] cpu=9999 st=2 lock=1 therm=3 low=1",
    "[Call] cpu=0 st=1 lock=1 therm=1 low=0",
    "[Call] cpu=7 st=2 lock=0 therm=2 low=1",
    "[Call] cpu=100 st=2 lock=1 therm=0 low=0",
    "[Call] cpu=63 st=1 lock=0 therm=3 low=1",
    # CallResourceLine.answerLine: every st (0-2) with every lock (0-1).
    "[Call] answer st=0 lock=0",
    "[Call] answer st=0 lock=1",
    "[Call] answer st=1 lock=0",
    "[Call] answer st=1 lock=1",
    "[Call] answer st=2 lock=0",
    "[Call] answer st=2 lock=1",
]

# Same text as AvatarAnnounceCoordinator.logSent / logSkip / logInbound ("to=" carries the 8-hex contact prefix), with the limit
# values: the smallest and the largest avatar (8 MiB is the receive cap), a 1 pixel side, the 16384 pixel limit of the hints.
AVATAR_LINES = [
    "send ok=1 del=0 to=8bc24df8 trig=1 why=1 bytes=64000 side=512 min=512",
    "send ok=1 del=0 to=8bc24df8 trig=2 why=2 bytes=123456 side=512 min=384",
    "send ok=1 del=0 to=8bc24df8 trig=3 why=3 bytes=99999 side=512 min=1",
    "send ok=1 del=0 to=8bc24df8 trig=4 why=1 bytes=1 side=1 min=1",
    "send ok=1 del=0 to=8bc24df8 trig=4 why=1 bytes=8388608 side=16384 min=16384",
    "send ok=1 del=0 to=8bc24df8 trig=1 why=1 bytes=0 side=0 min=0",
    "skip same to=8bc24df8 code=4 trig=1 bytes=64000",
    "skip same to=8bc24df8 code=4 trig=3 bytes=8388608",
    "skip same to=8bc24df8 code=4 trig=2 bytes=1",
    "skip call to=8bc24df8 code=5 trig=2 age=25",
    "skip call to=8bc24df8 code=5 trig=1 age=0",
    "skip call to=8bc24df8 code=5 trig=3 age=89",
    "skip brake to=8bc24df8 code=5 trig=1 age=0",
    "skip brake to=8bc24df8 code=5 trig=2 age=119",
    "resize bytes=4194304 out=35000 side=512 min=384",
    "resize bytes=8388608 out=102400 side=512 min=1",
    "resize bytes=123456 out=99999 side=512 min=512",
    "recv applied=1 bytes=4194304 out=35000 side=512 min=384",
    "recv applied=1 bytes=8388608 out=102400 side=512 min=1",
    "recv applied=1 bytes=64000 out=64000 side=512 min=512",
    "recv applied=1 bytes=1 out=1 side=1 min=1",
    "recv applied=0 code=8 kind=1 bytes=64000",
    "recv applied=0 code=8 kind=2 bytes=8388608",
    "recv applied=0 code=8 kind=1 bytes=0",
    "recv applied=0 code=9 bytes=64000",
    "recv applied=0 code=9 bytes=8388608",
    "recv applied=0 code=9 bytes=1",
]

failures = []
for text in AVATAR_LINES:
    got = shipped(text, "avatar")
    if got != text:
        failures.append("[avatar] %r -> %r" % (text, got))
for text in LINES:
    got = shipped(text)
    if got != text:
        failures.append("%r -> %r" % (text, got))
for text in CADENCE_LINES + GOVERNOR_LINES + CALL_RESOURCE_LINES:
    for tag in ("stdout", "call"):
        got = shipped(text, tag)
        if got != text:
            failures.append("[%s] %r -> %r" % (tag, text, got))

print("checks: %d, failures: %d" % (len(AVATAR_LINES) + len(LINES) + 2 * len(CADENCE_LINES + GOVERNOR_LINES + CALL_RESOURCE_LINES), len(failures)))
for f in failures:
    print("FAIL", f)
sys.exit(1 if failures else 0)
