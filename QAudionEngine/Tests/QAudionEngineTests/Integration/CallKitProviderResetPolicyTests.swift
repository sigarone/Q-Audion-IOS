import XCTest
@testable import QAudionEngine

/// W-CKPCRESET (2026-09-02) — pins the pure decision `providerDidReset`
/// acts on, without a live `CXProvider`/`RTCPeerConnection`. Same discipline
/// as `CallKitWorkOffloadPolicyTests` / `RestartIceDecisionsTests`.
/// Evidence: audit memory reference_ios_stability_audit_2026_09_01, P2.
final class CallKitProviderResetPolicyTests: XCTestCase {

    private typealias Policy = CallKitProviderResetPolicy

    // MARK: - Kill switch default

    /// Pure fix, no known-risk technique involved (unlike the group-call
    /// adaptiveStream class of change) — default ON.
    func test_default_isEnabled() {
        XCTAssertTrue(Policy.closesActivePeerConnectionEnabled)
    }

    // MARK: - peerConnectionAction

    func test_closesAndNotifies_whenActive1to1CallAndEnabled() {
        XCTAssertEqual(
            Policy.peerConnectionAction(hasActivePeerConnection: true, isGroupCall: false, enabled: true),
            .closeAndNotifyPeer
        )
    }

    func test_leavesUntouched_whenNoPeerConnection() {
        XCTAssertEqual(
            Policy.peerConnectionAction(hasActivePeerConnection: false, isGroupCall: false, enabled: true),
            .leaveUntouched
        )
    }

    func test_leavesUntouched_whenGroupCall_evenWithAPeerConnection() {
        // Belt and braces: a group call's media is LiveKit's, not this
        // PeerConnection's, even in a state where both happened to be set.
        XCTAssertEqual(
            Policy.peerConnectionAction(hasActivePeerConnection: true, isGroupCall: true, enabled: true),
            .leaveUntouched
        )
    }

    func test_leavesUntouched_whenKillSwitchOff() {
        XCTAssertEqual(
            Policy.peerConnectionAction(hasActivePeerConnection: true, isGroupCall: false, enabled: false),
            .leaveUntouched
        )
    }

    /// Calling with no `enabled:` argument uses the shipped default.
    func test_defaultArgumentMatchesTheKillSwitch() {
        XCTAssertEqual(
            Policy.peerConnectionAction(hasActivePeerConnection: true, isGroupCall: false),
            Policy.peerConnectionAction(hasActivePeerConnection: true, isGroupCall: false, enabled: Policy.closesActivePeerConnectionEnabled)
        )
    }
}
