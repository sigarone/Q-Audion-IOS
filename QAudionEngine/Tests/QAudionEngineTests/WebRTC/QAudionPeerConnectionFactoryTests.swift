import XCTest
#if canImport(WebRTC)
import WebRTC
#endif
@testable import QAudionEngine

final class QAudionPeerConnectionFactoryTests: XCTestCase {
    #if canImport(WebRTC)
    func testFactoryIsLazyAndIdempotent() async {
        let f1 = await QAudionPeerConnectionFactory.shared.factory()
        let f2 = await QAudionPeerConnectionFactory.shared.factory()
        XCTAssertTrue(f1 === f2, "factory must be a singleton")
    }

    /// W-PERSISTENTFACTORY (2026-09-09) — the whole redesign's correctness
    /// rests on `sharedFactory()` returning the SAME factory+ADM across
    /// repeated calls, not a fresh pair each time (the old, now-removed
    /// per-call `createFactory()` behavior). Pins that guarantee directly.
    func testSharedFactoryReturnsSameFactoryAndAdmAcrossCalls() async {
        let first = await QAudionPeerConnectionFactory.shared.sharedFactory()
        let second = await QAudionPeerConnectionFactory.shared.sharedFactory()
        XCTAssertTrue(first.factory === second.factory, "factory must persist across calls")
        XCTAssertTrue(first.audioProcessingModule === second.audioProcessingModule, "ADM must persist across calls")
    }

    /// W-ADMWEDGERESET — the safety-net counterpart: after a forced reset,
    /// the NEXT `sharedFactory()` call must rebuild rather than keep
    /// returning the (potentially wedged) prior instance.
    func testResetForWedgeRecoveryForcesRebuildOnNextCall() async {
        let before = await QAudionPeerConnectionFactory.shared.sharedFactory()
        QAudionPeerConnectionFactory.shared.resetForWedgeRecovery()
        let after = await QAudionPeerConnectionFactory.shared.sharedFactory()
        XCTAssertFalse(before.factory === after.factory, "resetForWedgeRecovery must force a fresh factory")
        XCTAssertFalse(before.audioProcessingModule === after.audioProcessingModule, "resetForWedgeRecovery must force a fresh ADM")
    }

    /// W-KEYLOGGATE (2026-09-24) — WebRTC's INFO-level native prints include
    /// derived key material (frame_crypto_transformer.cc), and whatever the
    /// debug (stderr) severity lets through ends up in the uploaded app log.
    /// Guards against lowering it back to `.info` (or below) by accident.
    func testStderrDebugLogLevelStaysAtWarningOrAbove() {
        let level = QAudionPeerConnectionFactory.stderrDebugLogLevel
        XCTAssertNotEqual(level, .info)
        XCTAssertNotEqual(level, .verbose)
        XCTAssertGreaterThanOrEqual(level.rawValue, RTCLoggingSeverity.warning.rawValue)
    }

    func testDefaultConfigurationHasUnifiedPlan() {
        let cfg = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [])
        XCTAssertEqual(cfg.sdpSemantics, .unifiedPlan)
        XCTAssertEqual(cfg.bundlePolicy, .maxBundle)
        XCTAssertEqual(cfg.rtcpMuxPolicy, .require)
        XCTAssertEqual(cfg.continualGatheringPolicy, .gatherContinually)
    }

    /// W-NATIVESRTPGATE (this task) — with no `nativeSrtpEnabledLocally`
    /// argument (every existing call site before this task), the extra
    /// native-SRTP-only fields must NOT be touched: a normal call's
    /// RTCConfiguration stays byte-for-byte what it was before this task.
    /// `cryptoOptions` defaults to `nil` and `tcpCandidatePolicy` defaults to
    /// `.enabled` on a fresh `RTCConfiguration()` per the WebRTC SDK's own
    /// documented defaults.
    func testDefaultConfigurationWithNativeSrtpDisabled_leavesTheNativeSrtpFieldsAtSdkDefaults() {
        let cfg = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [], nativeSrtpEnabledLocally: false)
        XCTAssertNil(cfg.cryptoOptions)
        XCTAssertEqual(cfg.tcpCandidatePolicy, .enabled)
    }

    /// W-NATIVESRTPGATE — with the flag true, every best-practice parameter
    /// this task adds must actually be set.
    func testDefaultConfigurationWithNativeSrtpEnabled_appliesTheBestPracticeParameters() {
        let cfg = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [], nativeSrtpEnabledLocally: true)
        XCTAssertNotNil(cfg.cryptoOptions)
        XCTAssertEqual(cfg.tcpCandidatePolicy, .disabled)
        XCTAssertEqual(cfg.audioJitterBufferMaxPackets, 50)
        XCTAssertFalse(cfg.audioJitterBufferFastAccelerate)
        XCTAssertEqual(cfg.audioJitterBufferMinDelayMs, 60)
    }

    func testIceServerConversionFromRelayServers() {
        let relays: [RelayServer] = [
            RelayServer(urls: ["turn:turn.example:3478"], username: "u", credential: "c", ttl: 1800),
            RelayServer(urls: ["stun:stun.example:3478"], username: nil, credential: nil, ttl: 3600),
        ]
        let iceServers = QAudionPeerConnectionFactory.iceServers(from: relays)
        XCTAssertEqual(iceServers.count, 2)
        XCTAssertEqual(iceServers[0].urlStrings, ["turn:turn.example:3478"])
        XCTAssertEqual(iceServers[0].username, "u")
        XCTAssertEqual(iceServers[0].credential, "c")
        XCTAssertEqual(iceServers[1].urlStrings, ["stun:stun.example:3478"])
    }
    #else
    func testWebRTCNotAvailableInThisTarget() {
        XCTAssertTrue(true, "WebRTC framework not available in this target — skipping")
    }
    #endif
}
