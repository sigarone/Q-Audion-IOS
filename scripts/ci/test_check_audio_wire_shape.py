#!/usr/bin/env python3
"""Tests for scripts/ci/check_audio_wire_shape.py (stdlib only, offline).

Run:  python3 -I scripts/ci/test_check_audio_wire_shape.py

Two layers: the gate on a small synthetic tree (each rule fails when its line is removed or a forbidden line is
added, comments do not count), and the real repository, which must be clean - that last test is what fails when
somebody drops the sender pin, assigns adaptive packet time anything but false or gives the Opus config a 20 ms default.
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

_spec = importlib.util.spec_from_file_location("check_audio_wire_shape", os.path.join(HERE, "check_audio_wire_shape.py"))
gate = importlib.util.module_from_spec(_spec)
sys.modules["check_audio_wire_shape"] = gate
_spec.loader.exec_module(gate)


def good_tree():
    """The smallest tree that satisfies every rule, as {relative path: text}."""
    return {
        gate.PEER: "\n".join([
            "encoding.adaptiveAudioPacketTime = false",
            "applyNativeAudioSenderBitrateCap(on: preAttachedSender, source: 1)",
            "reassertNativeAudioSenderCap(source: 2)",
            "reassertNativeAudioSenderCap(source: 2)",
            "reassertNativeAudioSenderCap(source: 3)",
            "guard let sender = nativeAudioSender ?? pc.senders.first(where: { $0.track?.trackId == audioTrackId }) else { return }",
            "if !applyNativeAudioSenderBitrateCap(on: sender, source: source) {",
            "emitNativeAudioDiagLine(AudioWireLines.senderCapLine(",
            "emitNativeAudioDiagLine(AudioWireLines.senderCapLine(",
        ]),
        gate.GROUP: "\n".join([
            "encoding.adaptiveAudioPacketTime = false",
            "applyAudioSenderProfile(audioTransceiver.sender)",
            "reassertAudioSenderProfile()",
            "reassertAudioSenderProfile()",
            "reassertAudioSenderProfile()",
        ]),
        gate.OPUS: "\n".join([
            "frameDurationMs: Int = AudioProfile.defaultProfile.frameDurationMs,",
            "blockBytes: Int = AudioProfile.defaultProfile.blockBytes) {",
        ]),
    }


class SyntheticTreeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.files = good_tree()
        os.makedirs(os.path.join(self.tmp, "QAudionApp"))

    def write(self):
        for rel, text in self.files.items():
            path = os.path.join(self.tmp, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text + "\n")

    def failures(self):
        self.write()
        return gate.run(self.tmp)

    def test_the_good_tree_is_clean(self):
        self.assertEqual(self.failures(), [])

    def test_every_required_line_is_required(self):
        for rel, needle, _minimum, _why in gate.REQUIRED:
            self.files = good_tree()
            self.files[rel] = "\n".join(line for line in self.files[rel].splitlines() if needle not in line)
            self.assertTrue(self.failures(), "dropping %r must fail the gate" % needle)

    def test_a_missing_file_fails(self):
        self.write()
        os.remove(os.path.join(self.tmp, gate.GROUP))
        self.assertTrue(gate.run(self.tmp))

    def test_adaptive_packet_time_switched_on_fails(self):
        self.files[gate.PEER] += "\nencoding.adaptiveAudioPacketTime = true"
        self.assertTrue(any("adaptive packet time" in f for f in self.failures()))

    def test_any_assignment_other_than_the_literal_false_fails(self):
        for code in ("encoding.adaptiveAudioPacketTime = flag",
                     "encoding.adaptiveAudioPacketTime=true",
                     "encoding.adaptiveAudioPacketTime = !false",
                     "encoding.adaptiveAudioPacketTime = false || other",
                     "encoding.adaptiveAudioPacketTime = isEnabled()",
                     "encoding.adaptiveAudioPacketTime = falsey",
                     "encoding.adaptiveAudioPacketTime = false ? true : false",
                     "encoding.adaptiveAudioPacketTime =",
                     "encoding.adaptiveAudioPacketTime = false; other.adaptiveAudioPacketTime = true",
                     'encoding.setValue(true, forKey: "adaptiveAudioPacketTime")',
                     "if x { $0.adaptiveAudioPacketTime = true }"):
            self.files = good_tree()
            self.files[gate.GROUP] += "\n" + code
            self.assertTrue(any("adaptive packet time" in f for f in self.failures()), code)

    def test_the_literal_false_comparisons_and_reads_pass(self):
        for code in ("encoding.adaptiveAudioPacketTime = false",
                     "encoding.adaptiveAudioPacketTime=false",
                     "encoding.adaptiveAudioPacketTime = false;",
                     "encodings.forEach { $0.adaptiveAudioPacketTime = false }",
                     "a.adaptiveAudioPacketTime = false; b.adaptiveAudioPacketTime = false",
                     "let apt = first.adaptiveAudioPacketTime ? 1 : 0",
                     "if first.adaptiveAudioPacketTime == false { }",
                     "if first.adaptiveAudioPacketTime != true { }",
                     "readAdaptive == 0 // encoding.adaptiveAudioPacketTime = true"):
            self.files = good_tree()
            self.files[gate.GROUP] += "\n" + code
            self.assertEqual(self.failures(), [], code)

    def test_the_two_field_trials_fail_anywhere_in_the_app_or_engine(self):
        for trial in ("WebRTC-Audio-AdaptivePtime", "WebRTC-Audio-Red-For-Opus"):
            self.files = good_tree()
            self.files[os.path.join("QAudionApp", "Other.swift")] = 'let t = "%s/Enabled/"' % trial
            self.assertTrue(any(trial in f for f in self.failures()), trial)

    def test_a_20ms_default_for_a_profileless_config_fails(self):
        self.files[gate.OPUS] += (
            "\n                    frameDurationMs: Int = AudioConstants.frameDurationMs,"
            "\n                    blockBytes: Int = AudioConstants.blockBytesStandard) {")
        self.assertTrue(any("20 ms" in f for f in self.failures()))

    def test_a_comment_does_not_count_as_code(self):
        self.files[gate.PEER] = "\n".join("// " + line for line in self.files[gate.PEER].splitlines())
        self.assertTrue(self.failures())
        self.files = good_tree()
        self.files[gate.PEER] += "\n// encoding.adaptiveAudioPacketTime = true"
        self.assertEqual(self.failures(), [])

    def test_a_double_slash_inside_a_string_is_not_a_comment(self):
        self.assertEqual(gate.strip_comment('let u = "http://x" // note'), 'let u = "http://x" ')
        self.assertEqual(gate.strip_comment('let t = "a\\"//b"'), 'let t = "a\\"//b"')


class RealRepositoryTests(unittest.TestCase):
    def test_the_repository_is_clean(self):
        self.assertEqual(gate.run(ROOT), [])


if __name__ == "__main__":
    unittest.main()
