import Foundation

/// W-RINGBACKCONFIRMED (2026-09-02) — pure-Swift port of the Android/Desktop
/// `QAudionSynth` procedural synthesizer. See
/// `qaudion-android-new/.../feature/call/audio/QAudionSynth.kt` and
/// `qaudion-desktop/src/renderer/lib/QAudionSynth.ts` — same algorithm, same
/// constants, so the three platforms play recognisably the same sound
/// identity for the outgoing-call cues.
///
/// No audio assets ship with the app — every tone is computed on the fly.
/// Output is `[Float]` in [-1, 1] at `defaultSampleRate`, ready to copy into
/// an `AVAudioPCMBuffer` (see `QAudionRingtonePlayer`).
enum QAudionSynth {

    static let defaultSampleRate: Double = 48_000

    // MARK: - Palette of frequencies (Hz)
    // D Dorian pentatonic anchored at A2 → A5 — must stay numerically
    // identical to the Android/Desktop copies.
    private static let a2 = 110.00
    private static let d3 = 146.83
    private static let a3 = 220.00
    private static let d4 = 293.66
    private static let e4 = 329.63
    private static let a4 = 440.00

    /// Standard busy-tone frequency (Europe/ITU): 425 Hz.
    private static let busyToneHz = 425.0

    // MARK: - Public rendering API

    /// Outgoing call ring — the "reaching the callee, don't know yet" period
    /// from t=0 in `startCall()`, before `call_ready` confirms the far end's
    /// phone is genuinely ringing. Softer, slower breathing pad.
    static func renderOutgoingRingLoop(sampleRate: Double = defaultSampleRate) -> [Float] {
        var buf = [Float](repeating: 0, count: Int(sampleRate * 3.0))
        addSine(&buf, frequency: d3, amp: 0.18, sampleRate: sampleRate)
        addSine(&buf, frequency: a3, amp: 0.14, sampleRate: sampleRate)
        addPad(&buf, amp: 0.12, sampleRate: sampleRate)
        applyTremolo(&buf, sampleRate: sampleRate, rateHz: 0.33, depth: 0.35)
        applyLoopFade(&buf, sampleRate: sampleRate, fadeMs: 120)
        return softSaturate(buf)
    }

    /// CONFIRMED ringback: the far end's phone is genuinely ringing
    /// (`call_ready` received). Takes over from `renderOutgoingRingLoop`.
    /// Classic single-tone telephone cadence (one long burst, one long
    /// silence — the "tuut ... tuut ..." pattern) at the standard 425 Hz
    /// busy-tone family, but a clearly different rhythm.
    static func renderConfirmedRingbackLoop(sampleRate: Double = defaultSampleRate) -> [Float] {
        var buf = [Float](repeating: 0, count: Int(sampleRate * 4.0))
        addToneBurst(&buf, sampleRate: sampleRate, startSec: 0.0, durSec: 1.0, freq: busyToneHz, amp: 0.22)
        return softSaturate(buf)
    }

    /// The far end answered and the PQC key exchange is running
    /// (`call_answer` received). Takes over from `renderConfirmedRingbackLoop`
    /// the instant the peer answers; `renderCallConnected` takes over from
    /// THIS once the call is actually up. A quick ascending three-note
    /// D-Dorian figure (A3-D4-E4), repeated — brighter and busier than
    /// either ring loop, reading as "actively working" rather than "waiting".
    static func renderKeyExchangeLoop(sampleRate: Double = defaultSampleRate) -> [Float] {
        var buf = [Float](repeating: 0, count: Int(sampleRate * 1.5))
        addSine(&buf, frequency: d3, amp: 0.05, sampleRate: sampleRate)
        playBell(&buf, sampleRate: sampleRate, startSec: 0.00, freq: a3, durSec: 0.22, amp: 0.16)
        playBell(&buf, sampleRate: sampleRate, startSec: 0.20, freq: d4, durSec: 0.22, amp: 0.18)
        playBell(&buf, sampleRate: sampleRate, startSec: 0.40, freq: e4, durSec: 0.30, amp: 0.20)
        applyLoopFade(&buf, sampleRate: sampleRate, fadeMs: 60)
        return softSaturate(buf)
    }

    /// Short swell when the handshake completes and audio bridges.
    static func renderCallConnected(sampleRate: Double = defaultSampleRate) -> [Float] {
        var buf = [Float](repeating: 0, count: Int(sampleRate * 0.8))
        playBell(&buf, sampleRate: sampleRate, startSec: 0.00, freq: d4, durSec: 0.6, amp: 0.35)
        playBell(&buf, sampleRate: sampleRate, startSec: 0.05, freq: a4, durSec: 0.6, amp: 0.28)
        applyAdsr(&buf, sampleRate: sampleRate, attackMs: 12, releaseMs: 350)
        return softSaturate(buf)
    }

    /// One-shot descending dissolve for call end.
    static func renderCallEnded(sampleRate: Double = defaultSampleRate) -> [Float] {
        var buf = [Float](repeating: 0, count: Int(sampleRate * 0.9))
        playBell(&buf, sampleRate: sampleRate, startSec: 0.0, freq: a4, durSec: 0.5, amp: 0.32)
        playBell(&buf, sampleRate: sampleRate, startSec: 0.2, freq: e4, durSec: 0.6, amp: 0.28)
        playBell(&buf, sampleRate: sampleRate, startSec: 0.4, freq: d4, durSec: 0.5, amp: 0.22)
        applyAdsr(&buf, sampleRate: sampleRate, attackMs: 8, releaseMs: 500)
        return softSaturate(buf)
    }

    // MARK: - DSP primitives (direct port from QAudionSynth.kt/.ts)

    private static func addSine(_ buf: inout [Float], frequency: Double, amp: Double, sampleRate: Double) {
        let omega = 2.0 * Double.pi * frequency
        for i in 0..<buf.count {
            let t = Double(i) / sampleRate
            buf[i] += Float(sin(omega * t) * amp)
        }
    }

    /// Bell = fundamental + 3rd + 5th partials with inharmonic ratios
    /// (1 : 2.756 : 5.404) and exponential decay — the characteristic
    /// metallic timbre without crossing into cartoon territory.
    private static func playBell(
        _ buf: inout [Float], sampleRate: Double, startSec: Double, freq: Double, durSec: Double, amp: Double
    ) {
        let startIdx = max(0, Int(startSec * sampleRate))
        let endIdx = min(buf.count, Int((startSec + durSec) * sampleRate))
        let n = max(0, endIdx - startIdx)
        guard n > 0 else { return }
        let w1 = 2.0 * Double.pi * freq
        let w2 = 2.0 * Double.pi * freq * 2.756
        let w3 = 2.0 * Double.pi * freq * 5.404
        let decay = 1.0 / durSec
        for i in 0..<n {
            let local = Double(i) / sampleRate
            let env = exp(-decay * local * 4.5)
            let s1 = sin(w1 * local)
            let s2 = sin(w2 * local) * 0.48
            let s3 = sin(w3 * local) * 0.22
            buf[startIdx + i] += Float((s1 + s2 + s3) * env * amp)
        }
    }

    /// Plain gated sine burst — no partials, no exponential decay, just
    /// enough ramp (8 ms) at each edge to keep the square gating click-free.
    private static func addToneBurst(
        _ buf: inout [Float], sampleRate: Double, startSec: Double, durSec: Double, freq: Double, amp: Double
    ) {
        let startIdx = max(0, Int(startSec * sampleRate))
        let endIdx = min(buf.count, Int((startSec + durSec) * sampleRate))
        let n = max(0, endIdx - startIdx)
        guard n > 0 else { return }
        let ramp = max(1, Int(sampleRate * 8.0 / 1000.0))
        let w = 2.0 * Double.pi * freq
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let att = i < ramp ? Double(i) / Double(ramp) : 1.0
            let rel = i > n - ramp ? Double(n - i) / Double(ramp) : 1.0
            buf[startIdx + i] += Float(sin(w * t) * att * rel * amp)
        }
    }

    /// Breathy chorused pad built from three detuned high sines.
    private static func addPad(_ buf: inout [Float], amp: Double, sampleRate: Double) {
        let freqs = [a3, a4 * 1.007, e4 * 0.993]
        for i in 0..<buf.count {
            let t = Double(i) / sampleRate
            var sum = 0.0
            for (k, f) in freqs.enumerated() {
                let phi = 2.0 * Double.pi * f * t + Double(k) * 0.31
                sum += sin(phi)
            }
            buf[i] += Float((sum / Double(freqs.count)) * amp)
        }
    }

    private static func applyTremolo(_ buf: inout [Float], sampleRate: Double, rateHz: Double, depth: Double) {
        let w = 2.0 * Double.pi * rateHz
        for i in 0..<buf.count {
            let t = Double(i) / sampleRate
            let gain = 1.0 - depth * (0.5 + 0.5 * sin(w * t))
            buf[i] *= Float(gain)
        }
    }

    private static func applyAdsr(_ buf: inout [Float], sampleRate: Double, attackMs: Double, releaseMs: Double) {
        let a = sampleRate * attackMs / 1000.0
        let r = sampleRate * releaseMs / 1000.0
        let n = buf.count
        for i in 0..<n {
            let att = Double(i) < a ? Double(i) / a : 1.0
            let rel = Double(i) > Double(n) - r ? (Double(n) - Double(i)) / r : 1.0
            buf[i] *= Float(att * rel)
        }
    }

    /// Fade in/out the loop edges to guarantee a click-free loop point.
    private static func applyLoopFade(_ buf: inout [Float], sampleRate: Double, fadeMs: Double) {
        let n = Int(sampleRate * fadeMs / 1000.0)
        guard n > 0, buf.count >= n * 2 else { return }
        for i in 0..<n {
            let k = Float(i) / Float(n)
            buf[i] *= k
            buf[buf.count - 1 - i] *= k
        }
    }

    /// Soft non-linear clamp so peaks stay polite even when amps overlap.
    private static func softSaturate(_ buf: [Float]) -> [Float] {
        buf.map { x in
            let xd = Double(x)
            let y = xd / pow(1.0 + pow(xd, 4) * 0.25, 0.25)
            return Float(max(-0.98, min(0.98, y)))
        }
    }
}
