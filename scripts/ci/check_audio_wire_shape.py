#!/usr/bin/env python3
"""check_audio_wire_shape.py - source gate: the audio sender is pinned to the audio wire policy.

WHY. The audio wire policy (Opus 60 ms frames, 32 kbps CBR, constant packet size and rate) is partly set in the
SDP, which has unit tests, and partly on the RTP sender's parameters (`RTCRtpEncodingParameters`:
min = max = 32 kbps, a fixed packet time, DSCP). The sender parameters are exercised on the simulator by the engine
tests; this gate proves on the SOURCES, on any machine with Python 3 and in a second, that the pin is still wired
where it has to be:

  * the 1:1 sender states `adaptiveAudioPacketTime = false` and is pinned when it is created, after every local /
    remote description and at activation; the re-pin targets the sender that carries the microphone track and is
    applied once more when the read-back disagrees;
  * the group publisher's audio sender states it too and is re-pinned after every offer / answer;
  * `adaptiveAudioPacketTime` is never assigned anything but the literal `false` (a variable, an expression or a
    key-value-coding write all fail), and nothing enables the field trials that reopen a 20 ms profile or double
    the bitrate (adaptive ptime, RED for Opus);
  * an Opus codec built without a profile takes the fleet profile, not the 20 ms capture constant.

HOW. Comments are dropped (a line comment outside a string literal), then each rule is a count of code lines or a
pattern on a code line.

USAGE   python3 -I scripts/ci/check_audio_wire_shape.py [--root DIR]
EXIT    0 clean | 1 a rule failed | 2 cannot run
"""
import argparse
import os
import re
import sys

ENGINE = os.path.join("QAudionEngine", "Sources", "QAudionEngine")
PEER = os.path.join(ENGINE, "WebRTC", "QAudionPeerConnection.swift")
GROUP = os.path.join(ENGINE, "GroupCall", "GroupPeerConnections.swift")
OPUS = os.path.join(ENGINE, "Audio", "OpusCodec.swift")

# (file, code substring, minimum number of lines that contain it, why)
REQUIRED = [
    (PEER, "encoding.adaptiveAudioPacketTime = false", 1, "1:1 sender states a fixed packet time"),
    (PEER, "applyNativeAudioSenderBitrateCap(on: preAttachedSender, source: 1)", 1, "1:1 sender pinned when created"),
    (PEER, "reassertNativeAudioSenderCap(source: 2)", 2, "1:1 sender re-pinned after the local description (offer and answer)"),
    (PEER, "reassertNativeAudioSenderCap(source: 3)", 1, "1:1 sender re-pinned after the remote description"),
    (PEER, "nativeAudioSender ?? pc.senders.first(where: { $0.track?.trackId == audioTrackId })", 1,
     "the re-pin targets the sender that carries the microphone track"),
    (PEER, "if !applyNativeAudioSenderBitrateCap(on: sender, source: source)", 1,
     "a read-back that is not accepted is applied once more"),
    (PEER, "emitNativeAudioDiagLine(AudioWireLines.senderCapLine(", 2, "1:1 pin reads back and logs"),
    (GROUP, "encoding.adaptiveAudioPacketTime = false", 1, "group sender states a fixed packet time"),
    (GROUP, "applyAudioSenderProfile(audioTransceiver.sender)", 1, "group sender pinned when created"),
    (GROUP, "reassertAudioSenderProfile()", 3, "group sender re-pinned after the offer and the answer"),
    (OPUS, "frameDurationMs: Int = AudioProfile.defaultProfile.frameDurationMs", 1, "profile-less encoder takes the fleet frame duration"),
    (OPUS, "blockBytes: Int = AudioProfile.defaultProfile.blockBytes", 1, "profile-less encoder takes the fleet block"),
]

# Code that must not appear anywhere in the sources of the app and the engine.
FORBIDDEN = [
    ("WebRTC-Audio-AdaptivePtime", "field trial that reopens a 20 ms packet time"),
    ("WebRTC-Audio-Red-For-Opus", "field trial that doubles the negotiated bitrate"),
    ("frameDurationMs: Int = AudioConstants.frameDurationMs,\n                    blockBytes: Int = AudioConstants.blockBytesStandard",
     "a profile-less Opus config must not default to the 20 ms / 120 byte standard profile"),
]


# Any assignment to the property: the right-hand side runs to the next `;` (or the end of the line) and must be the
# literal `false`, optionally followed by the `}` of a one-line closure. `==`, `!=`, `<=`, `>=` are comparisons.
ASSIGN_RE = re.compile(r"adaptiveAudioPacketTime\s*=(?!=)\s*([^;]*)")
FALSE_RHS_RE = re.compile(r"^false\s*\}*\s*$")
# The property by name in a string literal: a key-value-coding write (`setValue(_:forKey:)`) bypasses the assignment.
KVC_RE = re.compile(r"[\"']adaptiveAudioPacketTime[\"']")


def adaptive_ptime_violations(lines):
    """The code lines that assign `adaptiveAudioPacketTime` anything but the literal `false`, or name it in a string."""
    out = []
    for number, line in enumerate(lines, 1):
        for match in ASSIGN_RE.finditer(line):
            if not FALSE_RHS_RE.match(match.group(1).strip()):
                out.append((number, line.strip()))
        if KVC_RE.search(line):
            out.append((number, line.strip()))
    return out


def strip_comment(line):
    """The line without its `//` comment; a `//` inside a string literal is not a comment."""
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        else:
            if ch == '"':
                in_string = True
            elif ch == "/" and line[i:i + 2] == "//":
                return line[:i]
        i += 1
    return line


def code_of(path):
    with open(path, encoding="utf-8") as handle:
        return [strip_comment(line.rstrip("\n")) for line in handle]


def swift_files(root):
    for base in (os.path.join(root, "QAudionEngine", "Sources"), os.path.join(root, "QAudionApp")):
        for folder, _dirs, names in os.walk(base):
            if os.sep + "COpus" in folder:
                continue
            for name in names:
                if name.endswith(".swift"):
                    yield os.path.join(folder, name)


def run(root):
    failures = []
    cache = {}
    for rel, needle, minimum, why in REQUIRED:
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            failures.append("%s: file missing (%s)" % (rel, why))
            continue
        lines = cache.setdefault(path, code_of(path))
        count = sum(1 for line in lines if needle in line)
        if count < minimum:
            failures.append("%s: %r found %d time(s), %d required (%s)" % (rel, needle, count, minimum, why))
    for path in swift_files(root):
        lines = cache.setdefault(path, code_of(path))
        text = "\n".join(lines)
        for needle, why in FORBIDDEN:
            if needle in text:
                failures.append("%s: %r (%s)" % (os.path.relpath(path, root), needle.splitlines()[0], why))
        for number, code in adaptive_ptime_violations(lines):
            failures.append("%s:%d: %r (adaptive packet time must only ever be assigned the literal false)"
                            % (os.path.relpath(path, root), number, code))
    return failures


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
    args = parser.parse_args(argv)
    if not os.path.isdir(os.path.join(args.root, "QAudionEngine")):
        print("check_audio_wire_shape: %s is not the repository root" % args.root, file=sys.stderr)
        return 2
    failures = run(args.root)
    for failure in failures:
        print("FAIL " + failure)
    if failures:
        return 1
    print("check_audio_wire_shape: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
