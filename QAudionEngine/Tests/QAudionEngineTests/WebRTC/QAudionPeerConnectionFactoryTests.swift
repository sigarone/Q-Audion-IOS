import XCTest
#if canImport(WebRTC)
import WebRTC
#endif
@testable import QAudionEngine

final class QAudionPeerConnectionFactoryTests: XCTestCase {
    #if canImport(WebRTC)
    func testFactoryIsLazyAndIdempotent() {
        let f1 = QAudionPeerConnectionFactory.shared.factory
        let f2 = QAudionPeerConnectionFactory.shared.factory
        XCTAssertTrue(f1 === f2, "factory must be a singleton")
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
