import CryptoKit
import XCTest
import QAudionEngine
@testable import QAudionApp

final class GroupMembershipEnvelopeSigningTests: XCTestCase {

    private func fixedEnvelope() -> Data {
        GroupMembershipEnvelope.build(
            actorUserId: "user-a", eProposed: 7,
            groupIdWire: "11111111-2222-3333-4444-555555555555",
            operation: GroupMembershipEnvelope.opLeave,
            tsUnixSeconds: 1_700_000_000, subjectUserId: "user-a")
    }

    func testEnvelopeBytesAreUnchanged() {
        let expected = #"{"by":"user-a","e_proposed":7,"g":"11111111-2222-3333-4444-555555555555","t":"member_left","ts":1700000000,"uid":"user-a"}"#
        XCTAssertEqual(fixedEnvelope(), Data(expected.utf8))
    }

    /// The signature covers exactly the envelope bytes, as before: it verifies over them with the
    /// public key, and the signature the previous code path produced verifies the same way.
    func testSignatureCoversExactlyTheEnvelopeBytes() throws {
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://test.local", displayName: nil)
        let envelope = fixedEnvelope()

        let signature = try manager.signGroupMembershipEnvelope(envelope, identity: identity)
        let legacy = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.signingPrivate)
            .signature(for: envelope)

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identity.signingPublic)
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: envelope))
        XCTAssertTrue(publicKey.isValidSignature(legacy, for: envelope))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: envelope + Data([0])))
    }

    func testBytesThatAreNotAnEnvelopeAreRefused() {
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://test.local", displayName: nil)
        for bytes in [Data(), Data(repeating: 0x42, count: 73), Data("qaudion-mesh-announce-v1".utf8) + Data(repeating: 1, count: 49)] {
            XCTAssertThrowsError(try manager.signGroupMembershipEnvelope(bytes, identity: identity)) {
                XCTAssertEqual($0 as? GroupMembershipEnvelope.SigningError, .notAnEnvelope)
            }
        }
    }
}
