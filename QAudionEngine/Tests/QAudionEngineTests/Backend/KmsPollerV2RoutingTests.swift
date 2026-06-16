import XCTest
@testable import QAudionEngine

/// §6 routing + §3.5 anti-rollback decision logic (pure, no network).
final class KmsPollerV2RoutingTests: XCTestCase {
    private func entry(protoVersion: Int, keyType: String?, keyClass: String?,
                       epoch: String?) -> PendingKey {
        PendingKey(keyId: "11111111-1111-1111-1111-111111111111",
                   keyName: "n", fingerprint: "fp", status: "delivered",
                   encryptedPackage: "AAAA", ephemeralPubkey: "", nonce: "",
                   keyType: keyType, earbudId: nil, keyClass: keyClass,
                   keyEpoch: epoch, slotId: "33333333-3333-3333-3333-333333333333",
                   txnId: "44444444-4444-4444-4444-444444444444",
                   serverNonce: "AAECAwQFBgcICQoLDA0ODw==",
                   userId: "66666666-6666-6666-6666-666666666666",
                   deviceId: "77777777-7777-7777-7777-777777777777",
                   protoVersion: protoVersion)
    }

    func testRouteSelection() {
        XCTAssertEqual(KmsPollerService.route(for: entry(protoVersion: 1, keyType: nil, keyClass: nil, epoch: nil)), .v1Legacy)
        XCTAssertEqual(KmsPollerService.route(for: entry(protoVersion: 2, keyType: "sovereign", keyClass: "hw_only", epoch: "5")), .v2Sovereign)
        XCTAssertEqual(KmsPollerService.route(for: entry(protoVersion: 2, keyType: "x25519", keyClass: "shared", epoch: "5")), .v2PhoneHeld)
    }

    func testEpochRejectsNonMonotonic() {
        // active epoch 5 already committed → an entry with epoch 5 or lower is rejected.
        XCTAssertTrue(KmsPollerService.shouldRejectEpoch(incoming: 5, active: 5))
        XCTAssertTrue(KmsPollerService.shouldRejectEpoch(incoming: 4, active: 5))
        XCTAssertFalse(KmsPollerService.shouldRejectEpoch(incoming: 6, active: 5))
        XCTAssertFalse(KmsPollerService.shouldRejectEpoch(incoming: 1, active: nil))
    }
}
