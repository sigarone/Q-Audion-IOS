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

And the avatar lines that say why a picture was or was not sent or applied (tag "avatar", AvatarAnnounceCoordinator.logSkip
and logInbound): the skip lines ("skip same ... code=4" key exchange with unchanged version and pair key, "skip already sent ...
code=2" cooldown running), and the receive refusals ("recv applied=0 code=8 kind=1|2" image cut short, "code=9" same picture as the
one kept). Numbers only, words already admitted; the lines that carry a sender id with the key "from" are not here because the
shipper redacts that key by design. Keep in sync with AvatarAnnounceCoordinator and AvatarAnnounceReductionTests.

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

# Same text as AvatarAnnounceCoordinator.logSkip / logInbound (versions are epoch seconds; "to=" carries the 8-hex contact prefix).
AVATAR_LINES = [
    "skip already sent to=8bc24df8 code=2 trig=2 version=1760000000 age=30 cd=21600",
    "skip already sent to=8bc24df8 code=2 trig=1 version=1760000000 age=1800 cd=3600",
    "skip same to=8bc24df8 code=4 trig=3 version=1760000000 age=21 cd=21600",
    "skip same to=8bc24df8 code=4 trig=3 version=7 age=1234567 cd=21600",
    "skip same to=8bc24df8 code=4 trig=3 version=1760000000 age=-1 cd=21600",
    "recv applied=0 code=8 kind=1",
    "recv applied=0 code=8 kind=2",
    "recv applied=0 code=9",
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
