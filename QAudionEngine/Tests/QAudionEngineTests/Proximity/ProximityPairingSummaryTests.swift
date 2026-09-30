import XCTest
@testable import QAudionEngine

/// W-PAIRFB (in-person pairing feedback) — pins the pure mapping logic this
/// sweep added to `ProximityPairingTypes.swift`:
///
///   1. `ProximityPairingSummary`'s two initialisers agree
///      (`serverIdentityConfirmed` is now COMPUTED from the richer
///      `serverCheckOutcome`, never a separately-stored bool that could
///      drift from it).
///   2. `ProximityPairingTelemetryEvent.FailureCause.init(_:)` maps every
///      `ProximityPairingError` case to a closed, string-payload-free cause
///      token — the whole point being that a userId/claim embedded in an
///      error's associated `String` can never reach telemetry.
///
/// None of this needs `#if canImport(SwiftUI) && os(iOS)` — unlike
/// `ProximityPairingViewDriver` (SwiftUI, iOS-only), these are plain value
/// types in `ProximityPairingTypes.swift`, which has no platform gate.
final class ProximityPairingSummaryTests: XCTestCase {

    private func makeResult(sas: String = "123456") -> ProximityPairingResult {
        let peer = try! ProximityPeerIdentity(
            userId: "test-user-01",
            signingPublicKey: Data(repeating: 0x11, count: 32),
            encryptionPublicKey: Data(repeating: 0x22, count: 32)
        )
        return ProximityPairingResult(
            role: .scanner, peer: peer, psk: Data(repeating: 0x33, count: 32),
            pskFingerprint: "deadbeef", sas: sas, identityWarning: nil
        )
    }

    // MARK: - ProximityPairingSummary

    func test_defaultInit_isUnavailableAndNotConfirmed() {
        let summary = ProximityPairingSummary(makeResult())
        XCTAssertEqual(summary.serverCheckOutcome, .unavailable)
        XCTAssertFalse(summary.serverIdentityConfirmed)
        XCTAssertEqual(summary.elapsedMs, 0)
    }

    func test_confirmedOutcome_reportsServerIdentityConfirmedTrue() {
        let summary = ProximityPairingSummary(makeResult(), serverCheckOutcome: .confirmed, elapsedMs: 4_200)
        XCTAssertTrue(summary.serverIdentityConfirmed, "serverIdentityConfirmed must be true ONLY for .confirmed")
        XCTAssertEqual(summary.elapsedMs, 4_200)
    }

    func test_mismatchOutcome_isNotReportedAsConfirmed() {
        let summary = ProximityPairingSummary(makeResult(), serverCheckOutcome: .mismatch)
        XCTAssertFalse(summary.serverIdentityConfirmed,
                       "a mismatch must never be read as 'the server confirmed this' by a caller only checking the bool")
    }

    func test_backCompatBoolInit_mapsToTheSameOutcomes() {
        XCTAssertEqual(ProximityPairingSummary(makeResult(), serverIdentityConfirmed: true).serverCheckOutcome, .confirmed)
        XCTAssertEqual(ProximityPairingSummary(makeResult(), serverIdentityConfirmed: false).serverCheckOutcome, .unavailable)
        XCTAssertFalse(ProximityPairingSummary(makeResult()).serverIdentityConfirmed, "existing call sites/tests construct this with no outcome at all")
    }

    func test_serverCheckOutcome_rawValues_matchTheTelemetryWireContract() {
        // pairing.proximity.completed's server_check attribute is exactly
        // these three tokens (task contract: ok|unavailable|mismatch).
        XCTAssertEqual(ProximityServerCheckOutcome.confirmed.rawValue, "ok")
        XCTAssertEqual(ProximityServerCheckOutcome.unavailable.rawValue, "unavailable")
        XCTAssertEqual(ProximityServerCheckOutcome.mismatch.rawValue, "mismatch")
    }

    // MARK: - ProximityPairingTelemetryEvent.FailureCause

    /// Every `ProximityPairingError` case must map to SOME `FailureCause` —
    /// this loops the exhaustive `restartsOnItsOwn`-style case list so a
    /// future case added to the error enum is caught by the compiler
    /// (`init(_:)`'s switch has no `default:`), not silently dropped here.
    func test_failureCause_mapsEveryPairingErrorCase_withNoAssociatedPayload() {
        let cases: [ProximityPairingError] = [
            .bluetoothUnavailable("claim: userId-should-never-leak"),
            .identityUnavailable,
            .invalidQrCode("claim"),
            .expiredQrCode,
            .timeout("claim"),
            .transportFailed("claim"),
            .protocolViolation("claim"),
            .authenticationFailed("claim"),
            .identityRejected("claim"),
            .sessionBusy,
            .peerAborted(7),
            .userRejected,
            .cancelled,
            .cryptoFailure("claim"),
        ]
        for error in cases {
            let cause = ProximityPairingTelemetryEvent.FailureCause(error)
            // The whole point of the mapping: whatever string payload the
            // error carried never appears in the cause's own textual form.
            XCTAssertFalse(cause.rawValue.contains("claim"),
                           "FailureCause(\(error)) leaked the error's associated string payload")
        }
        XCTAssertEqual(ProximityPairingTelemetryEvent.FailureCause(.identityUnavailable), .identityUnavailable)
        XCTAssertEqual(ProximityPairingTelemetryEvent.FailureCause(.expiredQrCode), .expiredQrCode)
        XCTAssertEqual(ProximityPairingTelemetryEvent.FailureCause(.cancelled), .other,
                       "cancelled has no dedicated telemetry cause (cancellation is its own event kind) -- folds to .other")
    }

    func test_telemetryEvent_startedCarriesOnlyARoleEnum() {
        let event = ProximityPairingTelemetryEvent.started(role: .displayer)
        guard case .started(let role) = event else { return XCTFail() }
        XCTAssertEqual(role, .displayer)
    }
}
