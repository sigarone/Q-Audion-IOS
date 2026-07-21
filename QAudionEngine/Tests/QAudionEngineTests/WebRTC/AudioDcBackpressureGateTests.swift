import XCTest
@testable import QAudionEngine

/// W-DCBACKPRESSURE (2026-07-21) — tests for the pure decision
/// `AudioDcBackpressureGate.shouldDrop`.
///
/// iOS's sealed-audio DataChannel (`sendAudioFrameData` in
/// QAudionPeerConnection.swift) shipped with NO backpressure protection at
/// all, unlike Android's sibling implementation (Wave 2C-15 hotfix,
/// 2026-04-29, `PeerConnectionHolder.kt`), on the exact same wire mechanism.
/// Root-caused via call `f884668c` (2026-07-21): iOS's own telemetry went
/// dark ~11s into a 1:1 call, well before Android's ICE state noticed
/// anything wrong — consistent with the DC becoming unhealthy under
/// sustained backpressure with nothing shedding load on iOS's send side.
///
/// No WebRTC/RTCDataChannel import needed: the decision is pure, so it runs
/// on the macOS CI runner (`swift test`) without the WebRTC binary.
final class AudioDcBackpressureGateTests: XCTestCase {

    func testBelowThresholdIsNotDropped() {
        XCTAssertFalse(AudioDcBackpressureGate.shouldDrop(bufferedAmount: 1000, threshold: 1500))
    }

    func testAtThresholdIsNotDropped() {
        XCTAssertFalse(AudioDcBackpressureGate.shouldDrop(bufferedAmount: 1500, threshold: 1500))
    }

    func testAboveThresholdIsDropped() {
        XCTAssertTrue(AudioDcBackpressureGate.shouldDrop(bufferedAmount: 1501, threshold: 1500))
    }

    func testWellAboveThresholdIsDropped() {
        XCTAssertTrue(AudioDcBackpressureGate.shouldDrop(bufferedAmount: 50_000, threshold: 1500))
    }

    // The exact threshold Android shipped (1500 bytes ~= 12 frames of 120B +
    // SCTP header overhead) -- if this ever needs to change, update it AND
    // this test together, deliberately, in both PeerConnectionHolder.kt and
    // QAudionPeerConnection.swift at once.
    func testDefaultThresholdMatchesAndroid() {
        XCTAssertFalse(AudioDcBackpressureGate.shouldDrop(bufferedAmount: 1500, threshold: 1500))
        XCTAssertTrue(AudioDcBackpressureGate.shouldDrop(bufferedAmount: 1500 + 1, threshold: 1500))
    }
}
