import XCTest
import CryptoKit
@testable import QAudionEngine

final class DeviceLinkingProtocolTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let proto = DeviceLinkingProtocol()
        let pub = Data(repeating: 0x42, count: 32)
        let code = Data(repeating: 0x77, count: 16)
        let original = DeviceLinkingProtocol.LinkQrData(
            devicePubKey: pub,
            userId: "user-12345-uuid",
            oneTimeCode: code
        )
        let uri = proto.encodeLinkQr(original)
        XCTAssertTrue(uri.hasPrefix("qaudion://link/"))
        let decoded = try proto.decodeLinkQr(uri)
        XCTAssertEqual(decoded, original)
    }

    func testEncodedUriUsesBase64UrlSafe() throws {
        let proto = DeviceLinkingProtocol()
        // Pick payload that is likely to produce '+' / '/' in stdb64.
        let pub = Data(repeating: 0xFF, count: 32)
        let data = DeviceLinkingProtocol.LinkQrData(
            devicePubKey: pub,
            userId: "u",
            oneTimeCode: Data(repeating: 0xFE, count: 16)
        )
        let uri = proto.encodeLinkQr(data)
        let payload = String(uri.dropFirst("qaudion://link/".count))
        XCTAssertFalse(payload.contains("+"))
        XCTAssertFalse(payload.contains("/"))
        XCTAssertFalse(payload.contains("="))  // NO_WRAP / no padding
    }

    func testDecodeRejectsWrongScheme() {
        let proto = DeviceLinkingProtocol()
        XCTAssertThrowsError(try proto.decodeLinkQr("https://example.com/abc")) { err in
            guard case DeviceLinkingProtocol.LinkError.invalidScheme = err else {
                XCTFail("expected .invalidScheme, got \(err)"); return
            }
        }
    }

    func testDecodeRejectsTooShortPayload() {
        let proto = DeviceLinkingProtocol()
        // Empty base64url under the scheme.
        XCTAssertThrowsError(try proto.decodeLinkQr("qaudion://link/"))
    }

    func testGenerateLinkQrYieldsRandomCode() {
        let proto = DeviceLinkingProtocol()
        let pub = Data(repeating: 0x01, count: 32)
        let a = proto.generateLinkQr(userId: "x", devicePubKey: pub)
        let b = proto.generateLinkQr(userId: "x", devicePubKey: pub)
        XCTAssertEqual(a.oneTimeCode.count, 16)
        XCTAssertEqual(b.oneTimeCode.count, 16)
        XCTAssertNotEqual(a.oneTimeCode, b.oneTimeCode, "RNG should produce unique codes")
    }

    // MARK: - Sync key derivation

    func testSyncKeyAgreement() throws {
        let proto = DeviceLinkingProtocol()
        let alicePriv = Curve25519.KeyAgreement.PrivateKey()
        let bobPriv = Curve25519.KeyAgreement.PrivateKey()
        let alicePub = alicePriv.publicKey.rawRepresentation
        let bobPub = bobPriv.publicKey.rawRepresentation

        let aliceSync = try proto.deriveSyncKey(localPrivateKey: alicePriv, remotePubKey: bobPub)
        let bobSync = try proto.deriveSyncKey(localPrivateKey: bobPriv, remotePubKey: alicePub)
        XCTAssertEqual(aliceSync.count, 32)
        XCTAssertEqual(aliceSync, bobSync, "X25519 + HKDF must agree on both sides")
    }

    func testSyncKeyRejectsBadPublicKeyLength() throws {
        let proto = DeviceLinkingProtocol()
        let priv = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try proto.deriveSyncKey(
            localPrivateKey: priv,
            remotePubKey: Data(repeating: 0x01, count: 16)))
    }

    // MARK: - Snapshot round trip

    func testSnapshotRoundTrip() throws {
        let proto = DeviceLinkingProtocol()
        let alicePriv = Curve25519.KeyAgreement.PrivateKey()
        let bobPriv = Curve25519.KeyAgreement.PrivateKey()
        let aliceSync = try proto.deriveSyncKey(
            localPrivateKey: alicePriv,
            remotePubKey: bobPriv.publicKey.rawRepresentation)
        let bobSync = try proto.deriveSyncKey(
            localPrivateKey: bobPriv,
            remotePubKey: alicePriv.publicKey.rawRepresentation)

        let contacts: [Any] = [["userId": "u1", "name": "A"],
                                 ["userId": "u2", "name": "B"]]
        let settings: [String: Any] = ["theme": "dark"]
        let trust: [Any] = [["userId": "u1", "trust": 1]]

        let blob = try proto.createStateSnapshot(
            syncKey: aliceSync, contacts: contacts, settings: settings, trustData: trust)
        let restored = try proto.restoreFromSnapshot(blob, syncKey: bobSync)
        XCTAssertEqual(restored["version"] as? Int, 1)
        XCTAssertNotNil(restored["timestamp"] as? Int64
            ?? (restored["timestamp"] as? NSNumber).map { $0.int64Value })
        XCTAssertNotNil(restored["contacts"])
        XCTAssertNotNil(restored["settings"])
        XCTAssertNotNil(restored["trust"])
    }

    func testSnapshotWrongKeyFails() throws {
        let proto = DeviceLinkingProtocol()
        let key1 = Data(repeating: 0xAA, count: 32)
        let key2 = Data(repeating: 0xBB, count: 32)
        let blob = try proto.createStateSnapshot(
            syncKey: key1, contacts: [], settings: [String: Any](), trustData: [])
        XCTAssertThrowsError(try proto.restoreFromSnapshot(blob, syncKey: key2)) { err in
            guard case DeviceLinkingProtocol.LinkError.decryptFailed = err else {
                XCTFail("expected .decryptFailed, got \(err)"); return
            }
        }
    }

    // MARK: - base64url helpers

    func testBase64URLRoundTrip() {
        let cases: [Data] = [
            Data(),
            Data([0x00]),
            Data([0xFF, 0xFE, 0xFD]),
            Data((0..<200).map { UInt8($0 & 0xFF) }),
        ]
        for d in cases {
            let s = DeviceLinkingProtocol.base64URLEncode(d)
            XCTAssertFalse(s.contains("+"))
            XCTAssertFalse(s.contains("/"))
            XCTAssertFalse(s.contains("="))
            XCTAssertEqual(DeviceLinkingProtocol.base64URLDecode(s), d)
        }
    }
}
