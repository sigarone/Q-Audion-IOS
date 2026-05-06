import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform crypto guard for the iOS KMS transport.
///
/// Mirrors the test scenarios in Android's
/// `apps/qaudion-android-new/qaudion-engine/src/test/java/com/bcrypto/
/// qaudion/crypto/KmsTransportTest.kt` and Desktop's
/// `apps/qaudion-desktop/test/KmsTransport.spec.ts` — but pinned to
/// the iOS-side primitives so a regression on either label / IKM
/// order / tier discrimination fails the build before merge.
///
/// ## Round-trip self-tests
///
/// We can't ship cross-platform KAT vectors here (those live in
/// `tools/kat/kms/` and are a WIRE_SPEC §5 P1 follow-up). What we
/// CAN test is that an iOS-emitted package decrypts cleanly on iOS
/// — a self-consistency check that pins the wire shape, the HKDF
/// labels, and the AES-GCM split. Cross-platform byte-equality is
/// later validated by running the same KAT vector on all three
/// platforms.
final class KmsTransportTests: XCTestCase {

    // MARK: - Classical (60+ bytes) round-trip

    func testClassical_RoundTrip() throws {
        let psk = Data((0..<32).map { UInt8($0) })  // pinned 32B test PSK

        // Generate the device's X25519 keypair.
        let devPriv = Curve25519.KeyAgreement.PrivateKey()
        let devPub  = Data(devPriv.publicKey.rawRepresentation)

        // Encrypt — exactly the path the server would walk:
        //   1) ephemeral X25519 keypair
        //   2) ECDH against device's pubkey
        //   3) HKDF(salt='bcrypto-kms-salt-v1', info='bcrypto-kms-psk-v1')
        //   4) AES-GCM(nonce=12B random, plaintext=psk)
        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephPub  = Data(ephPriv.publicKey.rawRepresentation)
        let dh = try ephPriv.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devPub))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dh.withUnsafeBytes { Data($0) }),
            salt: Data("bcrypto-kms-salt-v1".utf8),
            info: Data("bcrypto-kms-psk-v1".utf8),
            outputByteCount: 32
        )
        var nonce = Data(count: 12)
        for i in 0..<12 { nonce[i] = UInt8(i + 0xA0) }
        let sealed = try AES.GCM.seal(psk, using: key, nonce: AES.GCM.Nonce(data: nonce))
        var pkg = Data(); pkg.append(ephPub); pkg.append(nonce)
        pkg.append(sealed.ciphertext); pkg.append(sealed.tag)

        XCTAssertEqual(pkg.count, 32 + 12 + 32 + 16, "classical pkg should be 92 bytes")

        // Decrypt via the production code path.
        let recovered = try KmsTransport.decryptPackage(
            pkg: pkg,
            x25519Priv: Data(devPriv.rawRepresentation),
            mlkemPub: nil,
            mlkemPriv: nil
        )
        XCTAssertEqual(recovered, psk, "classical decrypt must reproduce the original PSK")
    }

    // MARK: - Binding-Hybrid (92 bytes, server's production tier)

    func testBindingHybrid_RoundTrip() throws {
        let psk = Data((0..<32).map { UInt8($0 + 100) })

        let devPriv = Curve25519.KeyAgreement.PrivateKey()
        let devPub  = Data(devPriv.publicKey.rawRepresentation)
        // Stand-in for a real ML-KEM pubkey — we only hash it, not
        // decapsulate, so any byte sequence works for this test.
        let mlkemPub = Data((0..<1568).map { UInt8($0 % 256) })

        // Server-side encrypt:
        //   IKM = dh || SHA-256(mlkemPub)
        //   HKDF(salt='bcrypto-kms-hybrid-salt-v1',
        //        info='bcrypto-kms-hybrid-pqc-v1')
        let ephPriv = Curve25519.KeyAgreement.PrivateKey()
        let ephPub  = Data(ephPriv.publicKey.rawRepresentation)
        let dh = try ephPriv.sharedSecretFromKeyAgreement(
            with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devPub))
        let dhBytes = dh.withUnsafeBytes { Data($0) }
        var ikm = Data(capacity: 64)
        ikm.append(dhBytes)
        ikm.append(contentsOf: SHA256.hash(data: mlkemPub))
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data("bcrypto-kms-hybrid-salt-v1".utf8),
            info: Data("bcrypto-kms-hybrid-pqc-v1".utf8),
            outputByteCount: 32
        )
        var nonce = Data(count: 12)
        for i in 0..<12 { nonce[i] = UInt8(i + 0xB0) }
        let sealed = try AES.GCM.seal(psk, using: key, nonce: AES.GCM.Nonce(data: nonce))
        var pkg = Data(); pkg.append(ephPub); pkg.append(nonce)
        pkg.append(sealed.ciphertext); pkg.append(sealed.tag)

        XCTAssertEqual(pkg.count, 92, "binding-hybrid pkg must be exactly 92 bytes")

        // Decrypt: classical-first will fail the AES-GCM auth tag,
        // KmsTransport then retries as binding-hybrid using mlkemPub.
        let recovered = try KmsTransport.decryptPackage(
            pkg: pkg,
            x25519Priv: Data(devPriv.rawRepresentation),
            mlkemPub: mlkemPub,
            mlkemPriv: nil
        )
        XCTAssertEqual(recovered, psk, "binding-hybrid decrypt must reproduce PSK")
    }

    // MARK: - Tier discrimination

    func testTier_TooShort() throws {
        let pkg = Data(count: 50)  // < MIN_CLASSICAL = 60
        XCTAssertThrowsError(
            try KmsTransport.decryptPackage(
                pkg: pkg, x25519Priv: Data(count: 32), mlkemPub: nil, mlkemPriv: nil)
        ) { err in
            guard case KmsTransport.Error.packageTooShort = err else {
                XCTFail("expected packageTooShort, got \(err)")
                return
            }
        }
    }

    func testTier_LegacyHybridRequiresMlkemPriv() throws {
        let pkg = Data(count: 1700)  // >= MIN_LEGACY but garbage bytes
        XCTAssertThrowsError(
            try KmsTransport.decryptPackage(
                pkg: pkg, x25519Priv: Data(count: 32), mlkemPub: nil, mlkemPriv: nil)
        ) { err in
            guard case KmsTransport.Error.missingMlkemPrivateKey = err else {
                XCTFail("expected missingMlkemPrivateKey, got \(err)")
                return
            }
        }
    }
}
