import XCTest
import CryptoKit
@testable import QAudionEngine

// swiftlint:disable identifier_name

/// Cross-platform known-answer test for the identity bundle v2 self-signature.
/// The fixture is a byte copy of the cross-platform one: iOS must build the
/// identical preimage, sign it verifiably and accept the shared signature.
final class IdentityBundleV2KatTests: XCTestCase {

    private struct Kat: Decodable {
        let ed25519_seed_hex: String
        let uuid_hex: String
        let ed25519_pub_hex: String
        let created_at_ms: Int64
        let preimage_len: Int
        let preimage_sha256_hex: String
        let self_sig_hex: String
    }

    private func hex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    private func load() throws -> Kat {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "identity-bundle-v2-kat", withExtension: "json"))
        return try JSONDecoder().decode(Kat.self, from: Data(contentsOf: url))
    }

    private func preimage(_ k: Kat) throws -> Data {
        try IdentityKeyV2Preimage.buildV2(
            uuidRaw: hex(k.uuid_hex),
            ed25519Pub: hex(k.ed25519_pub_hex),
            ikPqPub: Data((0..<1568).map { UInt8($0 % 251) }),
            ikX25519Pub: Data((0..<32).map { UInt8(($0 * 3) % 256) }),
            createdAtMs: k.created_at_ms
        )
    }

    func testPreimageMatchesSharedVector() throws {
        let k = try load()
        let pre = try preimage(k)
        XCTAssertEqual(pre.count, k.preimage_len)
        XCTAssertEqual(pre.count, IdentityKeyV2Preimage.preimageLenV2)
        let digest = SHA256.hash(data: pre).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, k.preimage_sha256_hex)
    }

    func testAppSignPathProducesSignatureVerifiableUnderSharedKey() throws {
        let k = try load()
        let seed = hex(k.ed25519_seed_hex)
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: hex(k.ed25519_pub_hex))
        // The same builder and signer the app calls when publishing.
        let sig = try IdentityKeyV2Preimage.signV2(
            signingPrivate: seed,
            uuidRaw: hex(k.uuid_hex),
            ed25519Pub: hex(k.ed25519_pub_hex),
            ikPqPub: Data((0..<1568).map { UInt8($0 % 251) }),
            ikX25519Pub: Data((0..<32).map { UInt8(($0 * 3) % 256) }),
            createdAtMs: k.created_at_ms
        )
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(pub.isValidSignature(sig, for: try preimage(k)))
    }

    func testPublishFingerprintOldFormatTriggersPublishAndSameDoesNot() {
        let ed = Data(repeating: 1, count: 32)
        let pq = Data(repeating: 2, count: 1568)
        let x = Data(repeating: 3, count: 32)
        let oldStored = "v2|\(ed.base64EncodedString())|\(pq.base64EncodedString())|\(x.base64EncodedString())"
        let current = IdentityPublishFingerprint.v2(deviceId: "dev-1", ed25519Pub: ed, ikPqPub: pq, ikX25519Pub: x)
        XCTAssertTrue(IdentityPublishFingerprint.needsPublish(stored: oldStored, current: current))
        XCTAssertTrue(IdentityPublishFingerprint.needsPublish(stored: nil, current: current))
        XCTAssertFalse(IdentityPublishFingerprint.needsPublish(stored: current, current: current))
        let otherDevice = IdentityPublishFingerprint.v2(deviceId: "dev-2", ed25519Pub: ed, ikPqPub: pq, ikX25519Pub: x)
        XCTAssertNotEqual(current, otherDevice)
    }

    func testSharedSignatureVerifiesAndTamperIsRejected() throws {
        let k = try load()
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: hex(k.ed25519_pub_hex))
        let pre = try preimage(k)
        XCTAssertTrue(pub.isValidSignature(hex(k.self_sig_hex), for: pre))
        var bad = hex(k.self_sig_hex)
        bad[5] ^= 1
        XCTAssertFalse(pub.isValidSignature(bad, for: pre))
        var otherPre = pre
        otherPre[40] ^= 1
        XCTAssertFalse(pub.isValidSignature(hex(k.self_sig_hex), for: otherPre))
    }
}
