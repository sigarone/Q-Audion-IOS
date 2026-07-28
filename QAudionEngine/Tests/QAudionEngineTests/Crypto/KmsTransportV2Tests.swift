import XCTest
import CryptoKit
@testable import QAudionEngine

/// Self-contained round-trip tests for the KMS Rotation v2 phone-held
/// wrap (§3.2): the v2 AAD layout, the key-class byte mapping, classical
/// + REAL ML-KEM hybrid decrypt, the returned per-delivery wrap secret
/// (fed to the qa-kms-pop-v1 PoP), and AAD tamper rejection. These do
/// NOT depend on the frozen KAT fixtures — KAT byte-equality is pinned
/// separately in KmsTransportV2KatTests.
final class KmsTransportV2Tests: XCTestCase {

    // §3.2 AAD = "qa-kms-psk-v2"(13) || key_id(16) || user_id(16)
    //          || device_id(16) || key_epoch(8 BE) || txn_id(16) || key_class_byte(1)
    func testAadLayoutAndLength() throws {
        // Hardcoded well-formed UUID literal — always decodes.
        // swiftlint:disable:next force_unwrapping
        let keyId   = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        // Hardcoded well-formed UUID literal — always decodes.
        // swiftlint:disable:next force_unwrapping
        let userId  = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        // Hardcoded well-formed UUID literal — always decodes.
        // swiftlint:disable:next force_unwrapping
        let devId   = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        // Hardcoded well-formed UUID literal — always decodes.
        // swiftlint:disable:next force_unwrapping
        let txnId   = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let aad = KmsTransport.buildAadV2(
            keyId: keyId, userId: userId, deviceId: devId,
            keyEpoch: 0x0102030405060708, txnId: txnId, keyClass: .hwOnly)
        XCTAssertEqual(aad.count, 13 + 16 + 16 + 16 + 8 + 16 + 1) // 86
        XCTAssertEqual(aad.prefix(13), Data("qa-kms-psk-v2".utf8))
        // key_class byte hw_only = 0x02 is the last byte
        XCTAssertEqual(aad.last, 0x02)
        // key_epoch is bytes [61..<69) big-endian
        let epochSlice = aad.subdata(in: (13+16+16+16)..<(13+16+16+16+8))
        XCTAssertEqual(Array(epochSlice), [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    }

    func testKeyClassByteMapping() {
        XCTAssertEqual(KmsTransport.KeyClassV2.shared.byte, 0x01)
        XCTAssertEqual(KmsTransport.KeyClassV2.hwOnly.byte, 0x02)
        XCTAssertEqual(KmsTransport.KeyClassV2.swOnly.byte, 0x03)
        XCTAssertEqual(KmsTransport.KeyClassV2(wire: "shared"), .shared)
        XCTAssertEqual(KmsTransport.KeyClassV2(wire: "hw_only"), .hwOnly)
        XCTAssertEqual(KmsTransport.KeyClassV2(wire: "sw_only"), .swOnly)
        XCTAssertNil(KmsTransport.KeyClassV2(wire: "bogus"))
        XCTAssertNil(KmsTransport.KeyClassV2(wire: nil))
    }

    private func aadFixture() -> (UUID, UUID, UUID, UInt64, UUID, KmsTransport.KeyClassV2) {
        // Hardcoded well-formed UUID literals — always decode.
        // swiftlint:disable:next force_unwrapping
        (UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
         // swiftlint:disable:next force_unwrapping
         UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
         // swiftlint:disable:next force_unwrapping
         UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
         // swiftlint:disable:next force_unwrapping
         7, UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, .shared)
    }

    func testV2Classical_RoundTrip_AndWrapSecret() throws {
        let psk = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        let (kid, uid, did, epoch, txn, kc) = aadFixture()
        let dev = Curve25519.KeyAgreement.PrivateKey()
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let dh = try eph.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(dev.publicKey.rawRepresentation)))
        let dhBytes = dh.withUnsafeBytes { Data($0) }
        let aead = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dhBytes),
            salt: Data("bcrypto-kms-salt-v1".utf8),
            info: Data("bcrypto-kms-psk-v2".utf8), outputByteCount: 32)
        let aad = KmsTransport.buildAadV2(keyId: kid, userId: uid, deviceId: did,
                                          keyEpoch: epoch, txnId: txn, keyClass: kc)
        var nonce = Data(count: 12); for i in 0..<12 { nonce[i] = UInt8(i + 0xC0) }
        let sealed = try AES.GCM.seal(psk, using: aead,
                                      nonce: try AES.GCM.Nonce(data: nonce),
                                      authenticating: aad)
        var pkg = Data(); pkg.append(Data(eph.publicKey.rawRepresentation))
        pkg.append(nonce); pkg.append(sealed.ciphertext); pkg.append(sealed.tag)

        let out = try KmsTransport.decryptPackageV2(
            pkg: pkg, x25519Priv: Data(dev.rawRepresentation),
            mlkemPriv: nil, mlkemPub: nil,
            keyId: kid, userId: uid, deviceId: did,
            keyEpoch: epoch, txnId: txn, keyClass: kc)
        XCTAssertEqual(out.psk, psk)
        XCTAssertEqual(out.wrapSecret, dhBytes, "classical wrap secret == ECDH (32B)")
    }

    func testV2Hybrid_RoundTrip_AndWrapSecret() throws {
        let psk = Data((0..<32).map { UInt8($0 ^ 0x33) })
        let (kid, uid, did, epoch, txn, _) = aadFixture()
        let kc = KmsTransport.KeyClassV2.hwOnly
        let dev = Curve25519.KeyAgreement.PrivateKey()
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let pqc = PqcKeyExchange()
        let mlkemKp = try pqc.generateKeyPair()             // real ML-KEM-1024
        let encaps = try pqc.encapsulate(remotePublicKey: mlkemKp.publicKey)
        let dh = try eph.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(dev.publicKey.rawRepresentation)))
        let dhBytes = dh.withUnsafeBytes { Data($0) }
        var ikm = Data(); ikm.append(dhBytes); ikm.append(encaps.sharedSecret) // 64B
        let aead = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data("bcrypto-kms-hybrid-salt-v1".utf8),
            info: Data("bcrypto-kms-hybrid-pqc-v2".utf8), outputByteCount: 32)
        let aad = KmsTransport.buildAadV2(keyId: kid, userId: uid, deviceId: did,
                                          keyEpoch: epoch, txnId: txn, keyClass: kc)
        var nonce = Data(count: 12); for i in 0..<12 { nonce[i] = UInt8(i + 0xD0) }
        let sealed = try AES.GCM.seal(psk, using: aead,
                                      nonce: try AES.GCM.Nonce(data: nonce),
                                      authenticating: aad)
        // hybrid wire: ephPub(32) || ct_pq(1568) || nonce(12) || ct+tag
        var pkg = Data(); pkg.append(Data(eph.publicKey.rawRepresentation))
        pkg.append(encaps.ciphertext); pkg.append(nonce)
        pkg.append(sealed.ciphertext); pkg.append(sealed.tag)

        let out = try KmsTransport.decryptPackageV2(
            pkg: pkg, x25519Priv: Data(dev.rawRepresentation),
            mlkemPriv: mlkemKp.privateKey, mlkemPub: mlkemKp.publicKey,
            keyId: kid, userId: uid, deviceId: did,
            keyEpoch: epoch, txnId: txn, keyClass: kc)
        XCTAssertEqual(out.psk, psk)
        XCTAssertEqual(out.wrapSecret, ikm, "hybrid wrap secret == dh||ss_pq (64B)")
    }

    func testV2_AadTamperRejects() throws {
        let psk = Data(repeating: 0xAB, count: 32)
        let (kid, uid, did, epoch, txn, kc) = aadFixture()
        let dev = Curve25519.KeyAgreement.PrivateKey()
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let dh = try eph.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(dev.publicKey.rawRepresentation)))
        let aead = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dh.withUnsafeBytes { Data($0) }),
            salt: Data("bcrypto-kms-salt-v1".utf8),
            info: Data("bcrypto-kms-psk-v2".utf8), outputByteCount: 32)
        let aad = KmsTransport.buildAadV2(keyId: kid, userId: uid, deviceId: did,
                                          keyEpoch: epoch, txnId: txn, keyClass: kc)
        var nonce = Data(count: 12); for i in 0..<12 { nonce[i] = UInt8(i) }
        let sealed = try AES.GCM.seal(psk, using: aead,
                                      nonce: try AES.GCM.Nonce(data: nonce),
                                      authenticating: aad)
        var pkg = Data(); pkg.append(Data(eph.publicKey.rawRepresentation))
        pkg.append(nonce); pkg.append(sealed.ciphertext); pkg.append(sealed.tag)
        // Decrypt with a WRONG epoch → AAD mismatch → auth failure.
        XCTAssertThrowsError(try KmsTransport.decryptPackageV2(
            pkg: pkg, x25519Priv: Data(dev.rawRepresentation),
            mlkemPriv: nil, mlkemPub: nil,
            keyId: kid, userId: uid, deviceId: did,
            keyEpoch: epoch &+ 1, txnId: txn, keyClass: kc))
    }
}
