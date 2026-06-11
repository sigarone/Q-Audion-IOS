import Foundation

/// Post-call Opus quality tuner for iOS.
///
/// Port of Android AudioAutoTuner slow loop (2026-06-10 multi-model review).
/// iOS transport is WebSocket relay (not BLE L2CAP), so the BLE pacing fast
/// loop has no iOS equivalent. Only the Opus bitrate/PLR slow-tune applies.
///
/// Metric: rxLossRate = rxDecryptErrors / framesReceived.
/// AEAD failures before the PQC handshake (~first 1 s) inflate this number;
/// the MIN_FRAMES gate (100 frames ≈ 2 s @ 50 fps) excludes calls too short
/// for a reliable estimate.
///
/// Bitrate hard cap: 40 kbps — same as Android. Sealed frame is
/// [nonce(12)|ct(120)|tag(16)]; payload ≤ 119 B → ≤ 47.6 kbps @ 20 ms.
/// 40 kbps leaves margin and is the Opus WB speech quality plateau.
///
/// FEC: always on (iOS parity with Android). Only bitrate and PLR are tuned.
///
/// Results persist via AudioCodecPrefs (UserDefaults). The next call's
/// codec is reconfigured with these values in onStateChanged(.active).
public final class AudioAutoTuner {

    public static let shared = AudioAutoTuner()
    private init() {}

    private static let opusMaxBitrateKbps = 40
    private static let minFramesForTune: Int64 = 100

    /// Snapshot from the last completed call. Nil when autoTune is disabled
    /// or the call was too short.
    public private(set) var lastReport: SessionReport?

    public struct SessionReport {
        public let framesReceived: Int64
        public let framesDecrypted: Int64
        public let rxDecryptErrors: Int64
        public let lossRate: Float
        public let bitrateKbps: Int
        public let plp: Int
    }

    /// Call from CallService.teardownAudioStack() BEFORE per-call counters reset.
    /// - Parameters:
    ///   - framesReceived: total audio_frame envelopes off the WS (pre-decrypt)
    ///   - framesDecrypted: frames successfully decrypted and played
    ///   - rxDecryptErrors: AEAD + format failures during decryption
    public func tunePostCall(framesReceived: Int64,
                             framesDecrypted: Int64,
                             rxDecryptErrors: Int64) {
        lastReport = nil
        guard AudioCodecPrefs.autoTuneEnabled else { return }
        guard framesReceived >= Self.minFramesForTune else { return }

        let lossRate: Float = framesReceived > 0
            ? Float(rxDecryptErrors) / Float(framesReceived)
            : 0

        let curBr  = AudioCodecPrefs.bitrateKbps
        let curPlp = AudioCodecPrefs.plp

        let (newBr, newPlp): (Int, Int)
        if lossRate > 0.25 {
            (newBr, newPlp) = (24, 40)
        } else if lossRate > 0.10 {
            (newBr, newPlp) = (28, 30)
        } else if lossRate < 0.03 {
            // Clean link: recover bitrate + decay PLR hint (same QA-PLP-DECAY
            // logic as Android 2026-06-11 — prevents PLR from staying pinned
            // at 40 after congestion clears, wasting bitrate on FEC redundancy).
            newBr  = min(curBr + 2, Self.opusMaxBitrateKbps)
            newPlp = max(curPlp - 10, 10)
        } else {
            // Neutral zone — hold steady.
            (newBr, newPlp) = (curBr, curPlp)
        }

        if newBr != curBr || newPlp != curPlp {
            AudioCodecPrefs.setBitrateKbps(newBr)
            AudioCodecPrefs.setPlp(newPlp)
            let lossStr = String(format: "%.1f", lossRate * 100)
            let line = "[AudioAutoTuner] loss=\(lossStr)% → bitrate=\(newBr)kbps plp=\(newPlp)%"
            print(line)
        }

        lastReport = SessionReport(
            framesReceived:  framesReceived,
            framesDecrypted: framesDecrypted,
            rxDecryptErrors: rxDecryptErrors,
            lossRate:        lossRate,
            bitrateKbps:     newBr,
            plp:             newPlp
        )
    }
}
