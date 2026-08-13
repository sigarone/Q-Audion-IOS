import Foundation
import QAudionEngine

/// Post-call Opus quality tuner for iOS.
///
/// Port of Android AudioAutoTuner slow loop (2026-06-10 multi-model review).
/// iOS transport is WebSocket relay (not BLE L2CAP), so the BLE pacing fast
/// loop has no iOS equivalent.
///
/// Metric: rxLossRate = rxDecryptErrors / framesReceived.
/// AEAD failures before the PQC handshake (~first 1 s) inflate this number;
/// the MIN_FRAMES gate (100 frames ≈ 2 s @ 50 fps) excludes calls too short
/// for a reliable estimate.
///
/// W523 (2026-08-13) — bitrate is NO LONGER tuned. It used to move between 24
/// and 40 kbps per call (same shape as Android's AudioAutoTuner, ported
/// verbatim); Android later split its `opusBitrateKbps` — the phone's own
/// network-facing encoder — away from anything an auto-tuner touches, because
/// a per-device drifting bitrate produces a per-device varying packet size,
/// which defeats the constant-size CBR wire format's whole reason to exist
/// (`AudioConstants.opusBitrate`'s doc: "the whole ecosystem ships frames of
/// the same on-wire size for traffic-analysis resistance"). This port carried
/// the pre-split behavior over; see `AudioCodecPrefs.bitrateKbps` for the fix.
/// PLP/FEC redundancy still tunes — it changes nothing about wire packet
/// size, only how much of the fixed payload budget goes to loss protection.
/// `hypotheticalBitrateKbps` below is reported for visibility only (what the
/// retired logic would have chosen), never applied.
///
/// Results persist via AudioCodecPrefs (UserDefaults). The next call's
/// codec is reconfigured with these values in onStateChanged(.active).
public final class AudioAutoTuner {

    public static let shared = AudioAutoTuner()
    private init() {}

    private static let minFramesForTune: Int64 = 100

    /// Snapshot from the last completed call. Nil when autoTune is disabled
    /// or the call was too short.
    public private(set) var lastReport: SessionReport?

    public struct SessionReport {
        public let framesReceived: Int64
        public let framesDecrypted: Int64
        public let rxDecryptErrors: Int64
        public let lossRate: Float
        /// The FIXED CBR bitrate actually in use — always `AudioCodecPrefs.bitrateKbps`.
        public let bitrateKbps: Int
        public let plp: Int
    }

    /// What the retired per-call bitrate ratchet would have chosen from THIS
    /// call's loss alone, evaluated fresh each time against the fixed 32 kbps
    /// baseline (not a multi-call trajectory — that concept no longer applies
    /// once bitrate doesn't persist). Reported for visibility only; never
    /// fed back into `AudioCodecPrefs`.
    private static func hypotheticalBitrateKbps(lossRate: Float) -> Int {
        if lossRate > 0.25 { return 24 }
        if lossRate > 0.10 { return 28 }
        if lossRate < 0.03 { return min(AudioCodecPrefs.bitrateKbps + 2, 40) }
        return AudioCodecPrefs.bitrateKbps
    }

    /// Call from CallService.teardownAudioStack() BEFORE per-call counters reset.
    /// - Parameters:
    ///   - framesReceived: total audio_frame envelopes off the WS (pre-decrypt)
    ///   - framesDecrypted: frames successfully decrypted and played
    ///   - rxDecryptErrors: AEAD + format failures during decryption
    ///   - callId: active call id, for the telemetry timeline (W574c)
    public func tunePostCall(framesReceived: Int64,
                             framesDecrypted: Int64,
                             rxDecryptErrors: Int64,
                             callId: String? = nil) {
        lastReport = nil
        guard AudioCodecPrefs.autoTuneEnabled else {
            // W574c — make the "tuner did nothing" case visible on the
            // server timeline too: a disabled tuner and a short call were
            // previously indistinguishable from a tuner that never ran.
            emitTelemetry(callId: callId, attrs: ["skipped": "disabled"])
            return
        }
        guard framesReceived >= Self.minFramesForTune else {
            emitTelemetry(callId: callId, attrs: [
                "skipped": "too_short",
                "frames_received": framesReceived
            ])
            return
        }

        let lossRate: Float = framesReceived > 0
            ? Float(rxDecryptErrors) / Float(framesReceived)
            : 0

        // Bitrate is fixed — see the type doc. PLP (FEC redundancy) still
        // tunes: it only reallocates the fixed payload budget toward loss
        // protection, never changes the wire packet size.
        let curPlp = AudioCodecPrefs.plp
        let newPlp: Int
        if lossRate > 0.25 {
            newPlp = 40
        } else if lossRate > 0.10 {
            newPlp = 30
        } else if lossRate < 0.03 {
            // Decay PLR hint on a clean link (QA-PLP-DECAY, Android
            // 2026-06-11) — prevents it staying pinned at 40 after congestion
            // clears, wasting payload budget on FEC redundancy nobody needs.
            newPlp = max(curPlp - 10, 10)
        } else {
            newPlp = curPlp // neutral zone — hold steady
        }

        let fixedBr = AudioCodecPrefs.bitrateKbps
        let hypotheticalBr = Self.hypotheticalBitrateKbps(lossRate: lossRate)

        if newPlp != curPlp {
            AudioCodecPrefs.setPlp(newPlp)
            let lossStr = String(format: "%.1f", lossRate * 100)
            let line = "[AudioAutoTuner] loss=\(lossStr)% → plp=\(newPlp)% (bitrate fixed at \(fixedBr)kbps)"
            print(line)
        }

        lastReport = SessionReport(
            framesReceived:  framesReceived,
            framesDecrypted: framesDecrypted,
            rxDecryptErrors: rxDecryptErrors,
            lossRate:        lossRate,
            bitrateKbps:     fixedBr,
            plp:             newPlp
        )

        // W574c — ship the tune decision to the server timeline. Until now
        // the tuner only print()ed locally, so the maintainer dashboard had
        // ZERO visibility on what the auto-tune loop decided per call.
        emitTelemetry(callId: callId, attrs: [
            "frames_received":       framesReceived,
            "rx_decrypt_errors":     rxDecryptErrors,
            "loss_rate_pct":         Double(lossRate * 100).rounded(),
            "bitrate_kbps":          fixedBr,
            "hypothetical_bitrate_kbps": hypotheticalBr,
            "plp":                   newPlp,
            "changed":               (newPlp != curPlp),
            // Explicit codec + FEC so the server timeline records the fixed
            // transport (Opus with in-band FEC), not just the tuned PLP.
            "codec":                 "opus",
            "fec":                   true
        ])
    }

    /// W574c — single emit point so every tunePostCall outcome (tuned /
    /// skipped) lands on the per-call telemetry timeline as
    /// `call.audio.tune`.
    private func emitTelemetry(callId: String?, attrs: [String: Any]) {
        Task { @MainActor in
            TelemetryService.shared.emit(kind: "call.audio.tune", callId: callId, attrs: attrs)
        }
    }
}
