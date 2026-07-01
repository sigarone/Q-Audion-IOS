import XCTest
@testable import QAudionEngine

/// CALLEE-UPGRADE-PURPLE FIX (2026-07-01) — tests for the pure phantom-video
/// decision `VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver`.
/// Mirrors the Android suite for `shouldIgnorePhantomVideoTransceiver`
/// (qaudion-android-new 39ea0e5f, PeerConnectionHolderTest.kt), adapted to the
/// iOS 4-parameter signature (no cached-transceiver identity and no
/// local-mirror shape on iOS — the single choke point is
/// `didAdd rtpReceiver` in QAudionPeerConnection).
///
/// No WebRTC import needed: the decision is deliberately RTC-type-free so it
/// runs on the macOS CI runner (`swift test`) without the WebRTC binary.
final class VideoTransceiverPhantomGuardTests: XCTestCase {

    // THE BUG: callee upgrade, established video on mid "0", the phantom
    // arrives recv-only with no sender track on mid "2". Ignore it — keep the
    // renderer sink on the established mid.
    func testEstablishedMidPlusRecvOnlyNoSenderDifferentMidPhantomIsIgnored() {
        XCTAssertTrue(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "0", liveMid: "2", isRecvOnly: true, hasSenderTrack: false))
    }

    // The mid values themselves don't matter, only inequality with the
    // established mid.
    func testPhantomIgnoredForAnyDifferentMidValue() {
        XCTAssertTrue(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "0", liveMid: "1", isRecvOnly: true, hasSenderTrack: false))
    }

    // CRITICAL: establishedMid == nil → this IS the first real inbound video
    // (first-video / caller-upgrade). Must NOT be ignored even when it looks
    // exactly like the phantom shape — it has to bind normally, or the working
    // path breaks.
    func testFirstVideoWithNoEstablishedMidIsNeverIgnored() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: nil, liveMid: "0", isRecvOnly: true, hasSenderTrack: false))
    }

    // A re-fire for the SAME established mid (wrapper churn / re-negotiation)
    // is not a phantom — forwarded normally.
    func testSameMidRefireIsNotAPhantom() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "0", liveMid: "0", isRecvOnly: true, hasSenderTrack: false))
    }

    // A genuinely new bidirectional transceiver carrying a sender track at a
    // new mid is a real video m-line, NOT the empty phantom. Forward normally.
    func testDifferentMidSendRecvWithSenderIsNotAPhantom() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "0", liveMid: "2", isRecvOnly: false, hasSenderTrack: true))
    }

    // recv-only in direction but a sender track is present — not the EMPTY
    // phantom (the phantom has no sender track). Forward normally.
    func testDifferentMidRecvOnlyWithSenderTrackIsNotAPhantom() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "0", liveMid: "2", isRecvOnly: true, hasSenderTrack: true))
    }

    // Not recv-only and no sender track (e.g. inactive/sendOnly oddity) —
    // does not match the phantom shape. Forward normally (fail open).
    func testDifferentMidNotRecvOnlyNoSenderIsNotAPhantom() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "0", liveMid: "2", isRecvOnly: false, hasSenderTrack: false))
    }

    // Unresolvable transceiver (liveMid == nil, as passed when the receiverId
    // lookup finds nothing) → NEVER ignored — fail open to old behavior,
    // never drop a track we can't classify.
    func testUnresolvableTransceiverIsNeverIgnored() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "0", liveMid: nil, isRecvOnly: true, hasSenderTrack: false))
    }

    // Empty live mid = "no mid" (pre-association transceiver) → forward
    // normally; an empty string must never compare-match or trigger the guard.
    func testEmptyLiveMidIsTreatedAsNoMid() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "0", liveMid: "", isRecvOnly: true, hasSenderTrack: false))
    }

    // Defensive: an empty established mid must behave like "not established"
    // (the production path never stores "" — belt and braces).
    func testEmptyEstablishedMidBehavesLikeNotEstablished() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: "", liveMid: "2", isRecvOnly: true, hasSenderTrack: false))
    }

    // Nothing established, nothing resolvable → forward normally.
    func testBothMidsNilIsNeverIgnored() {
        XCTAssertFalse(VideoTransceiverPhantomGuard.shouldIgnorePhantomVideoTransceiver(
            establishedMid: nil, liveMid: nil, isRecvOnly: true, hasSenderTrack: false))
    }
}
