import XCTest
import Foundation
@testable import QAudionEngine

/// W-BYPASSDUCK (2026-09-25) -- pins the TX echo ducker that runs only while VP-IO is bypassed AND the
/// output is the built-in loudspeaker: the gain law (attack / hold / release, floor), the near-end test
/// with its hysteresis, the eligibility rule, the buffer-duration arithmetic and the telemetry.
///
/// CONTEXT. The test iPhone's VP-IO never delivers a tap buffer, so its speakerphone calls run on the raw
/// mic with nothing cancelling the echo (call 7727f262: six minutes, volume 100, make-up AGC mean 4.81).
/// The design is Android's `SpeakerEchoSuppressor` (which has its own tests) reduced to that one state
/// and with a -12 dB floor. The properties worth a test rather than a comment:
///  * it can never take the gain outside [floor, 1], whatever the inputs;
///  * it is wall-clock, not per-buffer: the same 100 ms to the floor at any tap buffer size;
///  * local speech wins immediately over the far-end proxy, and does not chatter (hysteresis);
///  * it acts ONLY in the degraded state, and a silent mic is not gated;
///  * it sits AFTER the AGC law, or the AGC would hand the attenuation straight back.
///
/// Pure arithmetic only, except the last class (it needs the `AudioCapture` type for the AGC law).
final class BypassEchoDuckTests: XCTestCase {

    private typealias Duck = BypassEchoDuck

    /// One 20 ms buffer of a call in which the far end is audible and echo (not speech) is on the mic.
    private func stepEcho(_ state: Duck.State, ms: Int = 20) -> Duck.State {
        return Duck.step(state: state, farEndActive: true, micRms: 0.03, playedRms: 0.10, bufferMs: ms)
    }

    // MARK: - Constants

    func testTheFloorIsMinusTwelveDb() {
        XCTAssertEqual(Duck.floorGain, 0.25, accuracy: 0.0001)
        XCTAssertEqual(20 * log10(Double(Duck.floorGain)), -12.04, accuracy: 0.05)
        XCTAssertLessThan(Duck.floorGain, 1)
        XCTAssertGreaterThan(Duck.floorGain, 0.1, "deeper than Android's -16 dB: the iOS stage is uncalibrated")
    }

    func testTheRampsAreWallClock() {
        XCTAssertEqual(Duck.attackFullMs, 100)
        XCTAssertEqual(Duck.releaseFullMs, 300)
        XCTAssertEqual(Duck.releaseNearFullMs, 100)
        XCTAssertGreaterThan(Duck.releaseFullMs, Duck.attackFullMs, "release must be slower than attack (pumping)")
        XCTAssertLessThan(Duck.releaseNearFullMs, Duck.releaseFullMs, "a double-talk onset must be let through faster")
    }

    // MARK: - Gain law

    func testNothingHappensWhileTheFarEndIsQuiet() {
        var s = Duck.State()
        for _ in 0..<100 {
            s = Duck.bypassEchoDuckGain(farEndActive: false, nearSpeechDominant: false, state: s, bufferMs: 20)
        }
        XCTAssertEqual(s.gain, 1, accuracy: 0.0001)
        XCTAssertEqual(s.hangoverMs, 0)
    }

    /// 100 ms to the floor: five 20 ms buffers, then it stays there.
    func testAttackReachesTheFloorInAHundredMs() {
        var s = Duck.State()
        s = stepEcho(s)
        XCTAssertEqual(s.gain, 0.85, accuracy: 0.001)
        for _ in 0..<4 { s = stepEcho(s) }
        XCTAssertEqual(s.gain, Duck.floorGain, accuracy: 0.001)
        for _ in 0..<50 { s = stepEcho(s) }
        XCTAssertEqual(s.gain, Duck.floorGain, accuracy: 0.0001, "the floor is a hard limit")
    }

    /// The ramp is in ms: 100 ms is 100 ms whatever the hardware's tap buffer duration is.
    func testAttackTakesTheSameWallClockAtAnyBufferSize() {
        for ms in [5, 10, 20, 50, 100] {
            var s = Duck.State()
            var elapsed = 0
            while s.gain > Duck.floorGain + 0.0001 && elapsed < 1_000 {
                s = stepEcho(s, ms: ms)
                elapsed += ms
            }
            XCTAssertLessThanOrEqual(abs(elapsed - 100), ms, "attack at \(ms) ms buffers took \(elapsed) ms")
        }
    }

    /// The far end goes quiet: the gain is HELD for the hangover (the far-end proxy is stamped at RX
    /// arrival, ahead of the jitter buffer and the player queue), then released over 300 ms.
    func testHangoverHoldsThenReleases() {
        var s = Duck.State()
        for _ in 0..<5 { s = stepEcho(s) }
        XCTAssertEqual(s.gain, Duck.floorGain, accuracy: 0.001)
        XCTAssertEqual(s.hangoverMs, Duck.hangoverHoldMs)

        let held = Duck.hangoverHoldMs / 20
        for _ in 0..<held {
            s = Duck.step(state: s, farEndActive: false, micRms: 0.03, playedRms: 0.10, bufferMs: 20)
            XCTAssertEqual(s.gain, Duck.floorGain, accuracy: 0.001, "released during the hangover")
        }
        XCTAssertEqual(s.hangoverMs, 0)

        s = Duck.step(state: s, farEndActive: false, micRms: 0.03, playedRms: 0.10, bufferMs: 20)
        XCTAssertEqual(s.gain, Duck.floorGain + 0.05, accuracy: 0.001, "release is 20 ms of a 300 ms travel")
        for _ in 0..<14 {
            s = Duck.step(state: s, farEndActive: false, micRms: 0.03, playedRms: 0.10, bufferMs: 20)
        }
        XCTAssertEqual(s.gain, 1, accuracy: 0.001)
    }

    /// The far end coming back during the hangover re-arms it and keeps the gain down.
    func testFarEndReturningRearmsTheHangover() {
        var s = Duck.State()
        for _ in 0..<5 { s = stepEcho(s) }
        for _ in 0..<3 {
            s = Duck.step(state: s, farEndActive: false, micRms: 0.03, playedRms: 0.10, bufferMs: 20)
        }
        XCTAssertLessThan(s.hangoverMs, Duck.hangoverHoldMs)
        s = stepEcho(s)
        XCTAssertEqual(s.hangoverMs, Duck.hangoverHoldMs)
        XCTAssertEqual(s.gain, Duck.floorGain, accuracy: 0.001)
    }

    /// Local speech wins over the far-end proxy at once, cancels the hangover and releases in 100 ms.
    func testLocalSpeechReleasesFastAndWinsOverTheFarEnd() {
        var s = Duck.State()
        for _ in 0..<5 { s = stepEcho(s) }
        for _ in 0..<5 {
            s = Duck.bypassEchoDuckGain(farEndActive: true, nearSpeechDominant: true, state: s, bufferMs: 20)
        }
        XCTAssertEqual(s.gain, 1, accuracy: 0.001)
        XCTAssertEqual(s.hangoverMs, 0)
    }

    /// Whatever the inputs, the gain stays inside [floor, 1] and the hangover inside [0, hold].
    func testTheGainNeverLeavesItsRange() {
        var seed: UInt32 = 12_345
        func next() -> UInt32 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return seed >> 8
        }
        var s = Duck.State()
        for _ in 0..<5_000 {
            let far = next() % 3 != 0
            let near = next() % 5 == 0
            let ms = Int(next() % 120)   // includes 0: treated as 1
            s = Duck.bypassEchoDuckGain(farEndActive: far, nearSpeechDominant: near, state: s, bufferMs: ms)
            XCTAssertGreaterThanOrEqual(s.gain, Duck.floorGain)
            XCTAssertLessThanOrEqual(s.gain, 1)
            XCTAssertGreaterThanOrEqual(s.hangoverMs, 0)
            XCTAssertLessThanOrEqual(s.hangoverMs, Duck.hangoverHoldMs)
        }
    }

    // MARK: - Near-end test (hysteresis)

    func testEnteringAndLeavingLocalSpeechUseDifferentThresholds() {
        let played: Float = 0.10
        // Not dominant yet: needs 1.4x the played level (0.14 here; the values sit clear of the boundary).
        XCTAssertFalse(Duck.nextNearSpeechDominant(micRms: 0.13, playedRms: played, wasDominant: false))
        XCTAssertTrue(Duck.nextNearSpeechDominant(micRms: 0.15, playedRms: played, wasDominant: false))
        // Dominant: stays so down to 1.0x ...
        XCTAssertTrue(Duck.nextNearSpeechDominant(micRms: 0.12, playedRms: played, wasDominant: true))
        XCTAssertTrue(Duck.nextNearSpeechDominant(micRms: 0.10, playedRms: played, wasDominant: true))
        // ... and no lower.
        XCTAssertFalse(Duck.nextNearSpeechDominant(micRms: 0.099, playedRms: played, wasDominant: true))
        XCTAssertLessThan(Duck.nearExitRatio, Duck.nearEnterRatio)
    }

    /// A level that hovers between the two thresholds must not flip the decision every buffer.
    func testTheDecisionDoesNotChatterInsideTheHysteresisBand() {
        var dominant = false
        var flips = 0
        let levels: [Float] = [0.05, 0.15, 0.12, 0.13, 0.11, 0.12, 0.13, 0.12, 0.05]
        for level in levels {
            let now = Duck.nextNearSpeechDominant(micRms: level, playedRms: 0.10, wasDominant: dominant)
            if now != dominant { flips += 1 }
            dominant = now
        }
        XCTAssertEqual(flips, 2, "one entry, one exit")
    }

    /// Nothing was played: there is no echo, so the mic is never "echo".
    func testWithNothingPlayedTheMicIsNeverEcho() {
        XCTAssertTrue(Duck.nextNearSpeechDominant(micRms: 0.0, playedRms: 0.0, wasDominant: false))
    }

    // MARK: - step()

    /// A mic below the silence floor carries no echo worth ducking: no attack, no pumping of the noise floor.
    func testASilentMicIsNotGated() {
        var s = Duck.State()
        for _ in 0..<20 {
            s = Duck.step(state: s, farEndActive: true, micRms: 0.001, playedRms: 0.10, bufferMs: 20)
        }
        XCTAssertEqual(s.gain, 1, accuracy: 0.0001)
    }

    func testEchoLevelAboveTheSilenceFloorDucks() {
        var s = Duck.State()
        for _ in 0..<5 { s = stepEcho(s) }
        XCTAssertEqual(s.gain, Duck.floorGain, accuracy: 0.001)
        XCTAssertFalse(s.nearLatched)
    }

    /// The double-talk story end to end: echo ducks; the local user starts talking over it and is let
    /// through within 100 ms; keeps being let through while they keep talking near the played level;
    /// ducks again once only echo is left.
    func testDoubleTalkOnsetIsLetThrough() {
        var s = Duck.State()
        for _ in 0..<5 { s = stepEcho(s) }
        XCTAssertEqual(s.gain, Duck.floorGain, accuracy: 0.001)

        for _ in 0..<5 {
            s = Duck.step(state: s, farEndActive: true, micRms: 0.20, playedRms: 0.10, bufferMs: 20)
        }
        XCTAssertEqual(s.gain, 1, accuracy: 0.001, "the local speaker was still being gated 100 ms after starting to talk")
        XCTAssertTrue(s.nearLatched)

        for _ in 0..<10 {
            s = Duck.step(state: s, farEndActive: true, micRms: 0.11, playedRms: 0.10, bufferMs: 20)
        }
        XCTAssertEqual(s.gain, 1, accuracy: 0.001, "hysteresis: still local speech at 1.1x the played level")

        for _ in 0..<5 { s = stepEcho(s) }
        XCTAssertEqual(s.gain, Duck.floorGain, accuracy: 0.001)
        XCTAssertFalse(s.nearLatched)
    }

    // MARK: - Eligibility

    func testItRunsOnlyInTheDegradedState() {
        XCTAssertTrue(Duck.isEligible(flagEnabled: true, vpioActive: false, onSpeaker: true))
        XCTAssertFalse(Duck.isEligible(flagEnabled: false, vpioActive: false, onSpeaker: true), "the remote kill switch")
        XCTAssertFalse(Duck.isEligible(flagEnabled: true, vpioActive: true, onSpeaker: true), "VP-IO works: never touch it")
        XCTAssertFalse(Duck.isEligible(flagEnabled: true, vpioActive: false, onSpeaker: false), "earpiece / headset: no coupling")
        XCTAssertFalse(Duck.isEligible(flagEnabled: false, vpioActive: true, onSpeaker: false))
    }

    // MARK: - Remote kill switch

    /// The key is a contract with the published flags.json (and with the `FeatureFlags` doc table): a
    /// rename here would silently disarm the kill switch, so it is pinned. Default ON.
    func testTheKillSwitchKeyAndDefaultArePinned() {
        XCTAssertEqual(Duck.remoteFlagKey, "ios_bypass_echo_duck")
        XCTAssertTrue(Duck.remoteFlagDefault)
    }

    // MARK: - Buffer duration

    func testBufferDurationFromBytes() {
        XCTAssertEqual(Duck.bufferMs(byteCount: 1_920), 20)
        XCTAssertEqual(Duck.bufferMs(byteCount: 960), 10)
        XCTAssertEqual(Duck.bufferMs(byteCount: 5_760), 60)
        XCTAssertEqual(Duck.bufferMs(byteCount: 9_600), 100)
        XCTAssertEqual(Duck.bufferMs(byteCount: 0), 1)
        XCTAssertEqual(Duck.bufferMs(byteCount: 50), 1)
        XCTAssertEqual(Duck.bufferMs(byteCount: -10), 1)
    }

    // MARK: - Telemetry

    func testTotals() {
        var t = Duck.Totals()
        t.note(gain: 1.0, farEndActive: false, nearDominant: false)
        t.note(gain: 0.85, farEndActive: true, nearDominant: false)
        t.note(gain: 0.25, farEndActive: true, nearDominant: false)
        t.note(gain: 0.60, farEndActive: true, nearDominant: true)
        XCTAssertEqual(t.frames, 4)
        XCTAssertEqual(t.activeFrames, 3)
        XCTAssertEqual(t.farEndFrames, 3)
        XCTAssertEqual(t.nearFrames, 1)
        XCTAssertEqual(t.gainMin, 0.25, accuracy: 0.0001)
    }

    func testAttrsAreOmittedWhenTheDuckerNeverRan() {
        let off = Duck.diagAttrs(totals: Duck.Totals(), enabled: false)
        XCTAssertEqual(Set(off.keys), Set(["echo_duck_enabled"]))
        XCTAssertEqual(off["echo_duck_enabled"] as? Bool, false)
        let armedButIdle = Duck.diagAttrs(totals: Duck.Totals(), enabled: true)
        XCTAssertEqual(Set(armedButIdle.keys), Set(["echo_duck_enabled"]), "armed but never eligible = VP-IO worked")
        XCTAssertEqual(armedButIdle["echo_duck_enabled"] as? Bool, true)
    }

    func testAttrsWhenItRan() {
        var t = Duck.Totals()
        for _ in 0..<6 { t.note(gain: 1.0, farEndActive: false, nearDominant: false) }
        for _ in 0..<3 { t.note(gain: 0.25, farEndActive: true, nearDominant: false) }
        t.note(gain: 0.5, farEndActive: true, nearDominant: true)
        let attrs = Duck.diagAttrs(totals: t, enabled: true)
        XCTAssertEqual(attrs["echo_duck_frames"] as? Int, 10)
        XCTAssertEqual(attrs["echo_duck_active_pct"] as? Double, 40.0)
        XCTAssertEqual(attrs["echo_duck_gain_min"] as? Double, 0.25)
        XCTAssertEqual(attrs["echo_duck_near_pct"] as? Double, 25.0)
        XCTAssertEqual(attrs["echo_duck_enabled"] as? Bool, true)
    }

    func testNearPctIsOmittedWithoutFarEndAudio() {
        var t = Duck.Totals()
        t.note(gain: 1.0, farEndActive: false, nearDominant: false)
        let attrs = Duck.diagAttrs(totals: t, enabled: true)
        XCTAssertNil(attrs["echo_duck_near_pct"])
        XCTAssertEqual(attrs["echo_duck_active_pct"] as? Double, 0.0)
        XCTAssertEqual(attrs["echo_duck_gain_min"] as? Double, 1.0)
    }

    func testStartLine() {
        XCTAssertEqual(Duck.startLine(gen: 3, flagEnabled: true, vpioActive: false, onSpeaker: true),
                       "audioVp ev=duck gen=3 on=1 en=1 vpio=0 spk=1")
        XCTAssertEqual(Duck.startLine(gen: 3, flagEnabled: true, vpioActive: true, onSpeaker: true),
                       "audioVp ev=duck gen=3 on=0 en=1 vpio=1 spk=1")
        XCTAssertEqual(Duck.startLine(gen: 4, flagEnabled: false, vpioActive: false, onSpeaker: true),
                       "audioVp ev=duck gen=4 on=0 en=0 vpio=0 spk=1")
    }
}

#if canImport(AVFoundation)

/// W-BYPASSDUCK -- WHY the gain is folded in AFTER the make-up AGC law and not applied before it.
///
/// Android measured it (call 69a3c5d6, W-AGCUNDOESAEC): suppress by -16.5 dB, then a make-up AGC whose
/// mean gain was 2.80 multiplies it back -- net -7.5 dB where -16.5 was intended, and where the residual
/// stayed above the AGC's noise gate the loop adapted UPWARD and cancelled the suppressor outright. The
/// AGC law cannot tell a ducked echo from a quiet talker. This replays that with the real iOS AGC law.
final class BypassEchoDuckOrderingTests: XCTestCase {

    private func settledAgcGain(bufferRms: Float, maxGain: Float) -> Float {
        var gain: Float = 1
        for _ in 0..<600 {
            gain = AudioCapture.nextMakeUpAgcGain(previousGain: gain,
                                                  bufferRms: bufferRms,
                                                  bufferPeak: bufferRms * 3,
                                                  maxGain: maxGain)
        }
        return gain
    }

    func testFoldingTheDuckInAfterTheAgcKeepsTheAttenuation() {
        let rawEchoRms: Float = 0.05
        let maxGain = AudioCapture.selectMakeUpAgcMaxGain(vpioActive: false)
        let duck = BypassEchoDuck.floorGain

        // The way it is built: the AGC law measures the RAW buffer, the duck multiplies the result.
        let foldedAgc = settledAgcGain(bufferRms: rawEchoRms, maxGain: maxGain)
        let foldedOut = rawEchoRms * foldedAgc * duck

        // The way it must NOT be built: duck first, the AGC then sees the quieter signal and lifts it.
        let preAgc = settledAgcGain(bufferRms: rawEchoRms * duck, maxGain: maxGain)
        let preOut = rawEchoRms * duck * preAgc

        // Fixed values, worked by hand from the real law (agcTargetRms 0.12, ceiling 6.0, peak headroom 0.70):
        // raw rms 0.05 -> gain 0.12 / 0.05 = 2.4 (peak 0.15 x 2.4 is far under the headroom), and the duck is
        // the last factor: 0.05 x 2.4 x 0.25 = 0.03. Computing the expectation from `foldedOut` itself would
        // be an identity that no production change could break.
        XCTAssertEqual(foldedAgc, 2.4, accuracy: 0.01, "the AGC law no longer measures the raw buffer")
        XCTAssertEqual(foldedOut, 0.03, accuracy: 0.001, "the duck no longer survives as the last multiplier")
        XCTAssertGreaterThan(preAgc, foldedAgc, "the AGC is expected to compensate a pre-AGC duck")
        XCTAssertGreaterThan(preOut, foldedOut * 2,
                             "ducking before the AGC undoes over half of the attenuation — the reason it is folded in after")
    }
}

#endif
