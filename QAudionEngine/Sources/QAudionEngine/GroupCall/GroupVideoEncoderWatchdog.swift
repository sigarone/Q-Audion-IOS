import Foundation

/// The safety net behind the camera's first-frame watch (`GroupMediaSession.watchFirstFrame`):
/// a camera that is on, with the publisher PeerConnection connected, whose encoder still has
/// produced no frame after a while is not going to start by itself (an encoder whose
/// `InitEncode` failed stays failed, and libwebrtc has no fallback codec for the group VP8).
/// The session then re-configures the publisher to a single layer, once per watch, and logs it.
///
/// Pure decision, so it is unit-testable without a PeerConnection.
public enum GroupVideoEncoderWatchdog {

    /// How long a connected publisher with the camera on may go without an encoded frame
    /// before the single-layer fallback. A healthy encoder produces its first frame within a
    /// second or two of the `configure`; this is far past that, short of the 30 s at which the
    /// failure is only reported (`grp video ... phase=5 ok=0`).
    public static let defaultFallbackSeconds: Double = 8

    /// - Parameters:
    ///   - framesAtStart: frames encoded when the watch began (nil = no stats then).
    ///   - framesNow: frames encoded now (nil = no stats: nothing is known, never fall back).
    ///   - elapsedMs: time since the watch began.
    ///   - thresholdMs: the stall length that triggers the fallback.
    ///   - publisherConnected: the publisher PeerConnection is `connected` (before that the
    ///     sender may legitimately be idle).
    ///   - alreadyFellBack: the fallback already ran for this watch (it runs once).
    public static func shouldFallBackToSingleLayer(framesAtStart: Int?, framesNow: Int?, elapsedMs: Int64,
                                                   thresholdMs: Int64, publisherConnected: Bool,
                                                   alreadyFellBack: Bool) -> Bool {
        guard !alreadyFellBack, publisherConnected, let framesNow = framesNow else { return false }
        if framesNow > (framesAtStart ?? 0) { return false }
        return elapsedMs >= thresholdMs
    }
}
