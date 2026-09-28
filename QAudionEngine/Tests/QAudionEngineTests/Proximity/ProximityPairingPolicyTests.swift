import XCTest
@testable import QAudionEngine

/// Pure decisions the pairing state machines rely on, pinned so a refactor
/// cannot quietly change them.
final class ProximityDisplayerFrameIndexTests: XCTestCase {

    /// The displayer replaces its session instead of wrapping to frame 0,
    /// which would re-issue frame keys it already showed.
    func testFrameIndexNeverWraps() {
        XCTAssertEqual(ProximityDisplayerSession.nextFrameIndex(after: 0), 1)
        XCTAssertEqual(ProximityDisplayerSession.nextFrameIndex(after: 41), 42)
        XCTAssertEqual(ProximityDisplayerSession.nextFrameIndex(after: UInt32.max - 1), UInt32.max)
        XCTAssertNil(ProximityDisplayerSession.nextFrameIndex(after: UInt32.max))
    }
}

#if canImport(SwiftUI) && os(iOS)
final class ProximityPairingDriverPolicyTests: XCTestCase {

    /// Spec §11 / review K2: only failures that say nothing about who was on
    /// the other end may put a fresh code up without a person asking for it.
    func testOnlyFailuresThatSayNothingAboutThePeerRestartOnTheirOwn() {
        let restarting: [ProximityPairingError] = [
            .expiredQrCode,
            .timeout("handshake"),
            .transportFailed("radio"),
            .sessionBusy,
            .peerAborted(ProximityPairing.AbortReason.frameExpired.rawValue),
            .peerAborted(ProximityPairing.AbortReason.timeout.rawValue),
        ]
        for error in restarting {
            XCTAssertTrue(ProximityPairingViewDriver.restartsOnItsOwn(error), String(describing: error))
        }
        let staying: [ProximityPairingError] = [
            .bluetoothUnavailable("off"),
            .identityUnavailable,
            .invalidQrCode("scan"),
            .protocolViolation("framing"),
            .authenticationFailed("mac"),
            .identityRejected("self"),
            .userRejected,
            .cancelled,
            .cryptoFailure("kem"),
            .peerAborted(ProximityPairing.AbortReason.userRejected.rawValue),
            .peerAborted(ProximityPairing.AbortReason.authenticationFailed.rawValue),
            .peerAborted(ProximityPairing.AbortReason.protocolViolation.rawValue),
            .peerAborted(ProximityPairing.AbortReason.identityRejected.rawValue),
            .peerAborted(ProximityPairing.AbortReason.cancelled.rawValue),
            .peerAborted(ProximityPairing.AbortReason.internalError.rawValue),
            .peerAborted(0),
            .peerAborted(9),
            .peerAborted(255),
        ]
        for error in staying {
            XCTAssertFalse(ProximityPairingViewDriver.restartsOnItsOwn(error), String(describing: error))
        }
    }

    /// Spec §12 server check: the presented Ed25519 key must be one the
    /// claimed account published; an empty answer proves nothing either way.
    func testServerVerdict() {
        let presented = Data(repeating: 0x11, count: 32)
        let other = Data(repeating: 0x22, count: 32)
        XCTAssertEqual(ProximityPairingViewDriver.serverVerdict(published: [], presented: presented), .unknown)
        XCTAssertEqual(ProximityPairingViewDriver.serverVerdict(published: [other, presented], presented: presented),
                       .confirmed)
        XCTAssertEqual(ProximityPairingViewDriver.serverVerdict(published: [other], presented: presented), .mismatch)

        var backing = Data([0x00])
        backing.append(presented)
        let slice: Data = backing[1...]
        XCTAssertEqual(ProximityPairingViewDriver.serverVerdict(published: [presented], presented: slice), .confirmed)
    }

    /// What reaches the host app: everything but the key, and "not confirmed"
    /// unless the driver says so.
    func testSummaryDefaultsToUnconfirmed() throws {
        let peer = try ProximityPeerIdentity(userId: "bob",
                                             signingPublicKey: Data(repeating: 0x01, count: 32),
                                             encryptionPublicKey: Data(repeating: 0x02, count: 32))
        let result = ProximityPairingResult(role: .scanner, peer: peer, psk: Data(repeating: 0x03, count: 32),
                                            pskFingerprint: "fp", sas: "123456", identityWarning: nil)
        let summary = ProximityPairingSummary(result)
        XCTAssertFalse(summary.serverIdentityConfirmed)
        XCTAssertEqual(summary.peer, peer)
        XCTAssertEqual(summary.pskFingerprint, "fp")
        XCTAssertTrue(ProximityPairingSummary(result, serverIdentityConfirmed: true).serverIdentityConfirmed)
    }
}
#endif
