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

    func testDefaultConfigurationHasUnifiedPlan() {
        let cfg = QAudionPeerConnectionFactory.defaultConfiguration(iceServers: [])
        XCTAssertEqual(cfg.sdpSemantics, .unifiedPlan)
        XCTAssertEqual(cfg.bundlePolicy, .maxBundle)
        XCTAssertEqual(cfg.rtcpMuxPolicy, .require)
        XCTAssertEqual(cfg.continualGatheringPolicy, .gatherContinually)
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
