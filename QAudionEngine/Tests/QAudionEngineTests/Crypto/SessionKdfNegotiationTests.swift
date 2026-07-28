import XCTest
@testable import QAudionEngine

/// KMS-rotation-v2 Phase-1 (D6) — v2/v3 session-KDF negotiation.
///
/// Frozen rule: v3 ONLY when BOTH legs support it; mixed-fleet (either peer
/// lacks v3) falls back to v2. A legacy bundle that omits the capability flag
/// (nil) is treated as v2.
final class SessionKdfNegotiationTests: XCTestCase {

    func testBothSupportV3SelectsV3() {
        XCTAssertEqual(SessionKdfNegotiation.resolve(localSupportsV3: true, peerSupportsV3: true), .v3)
    }

    func testEitherLacksV3FallsBackToV2() {
        XCTAssertEqual(SessionKdfNegotiation.resolve(localSupportsV3: true, peerSupportsV3: false), .v2)
        XCTAssertEqual(SessionKdfNegotiation.resolve(localSupportsV3: false, peerSupportsV3: true), .v2)
        XCTAssertEqual(SessionKdfNegotiation.resolve(localSupportsV3: false, peerSupportsV3: false), .v2)
    }

    func testPeerAdvertisesV3RequiresFlagAndVersion() {
        // Flag true + version at floor → v3.
        XCTAssertTrue(SessionKdfNegotiation.peerAdvertisesV3(capabilityV3: true,
                                                             peerHandshakeVersion: SessionKdfNegotiation.v3HandshakeVersion))
        // Flag absent (legacy bundle) → not v3.
        XCTAssertFalse(SessionKdfNegotiation.peerAdvertisesV3(capabilityV3: nil,
                                                              peerHandshakeVersion: 1))
        // Flag explicitly false → not v3.
        XCTAssertFalse(SessionKdfNegotiation.peerAdvertisesV3(capabilityV3: false,
                                                              peerHandshakeVersion: 1))
        // Flag true but handshake version below the floor → not v3.
        XCTAssertFalse(SessionKdfNegotiation.peerAdvertisesV3(capabilityV3: true,
                                                              peerHandshakeVersion: 0))
    }

    /// End-to-end shape: a v3 peer talking to a legacy v2 peer must agree on v2.
    func testMixedFleetEndToEndAgreesOnV2() {
        let peerV3 = SessionKdfNegotiation.peerAdvertisesV3(capabilityV3: nil, peerHandshakeVersion: 1)
        XCTAssertEqual(SessionKdfNegotiation.resolve(localSupportsV3: true, peerSupportsV3: peerV3), .v2)
    }
}
