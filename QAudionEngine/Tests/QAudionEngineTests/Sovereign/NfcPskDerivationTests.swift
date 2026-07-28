import XCTest
import CryptoKit
@testable import QAudionEngine

final class NfcPskDerivationTests: XCTestCase {

    // MARK: - 32-byte output

    func testDeriveReturns32Bytes() throws {
        let aPriv = Curve25519.KeyAgreement.PrivateKey()
        let bPriv = Curve25519.KeyAgreement.PrivateKey()
        let psk = try NfcPskDerivation.derivePsk(myPriv: aPriv, peerPub: bPriv.publicKey)
        XCTAssertEqual(psk.count, 32, "PSK must be exactly 32 bytes")
    }

    // MARK: - Symmetry: A→B == B→A

    func testDeriveIsSymmetric() throws {
        let aPriv = Curve25519.KeyAgreement.PrivateKey()
        let bPriv = Curve25519.KeyAgreement.PrivateKey()

        let pskA = try NfcPskDerivation.derivePsk(myPriv: aPriv, peerPub: bPriv.publicKey)
        let pskB = try NfcPskDerivation.derivePsk(myPriv: bPriv, peerPub: aPriv.publicKey)

        XCTAssertEqual(pskA, pskB, "PSK must be identical for both peers")
    }

    // MARK: - Different key pairs produce different PSKs

    func testDifferentKeyPairsProduceDifferentPsks() throws {
        let aPriv = Curve25519.KeyAgreement.PrivateKey()
        let bPriv = Curve25519.KeyAgreement.PrivateKey()
        let cPriv = Curve25519.KeyAgreement.PrivateKey()

        let pskAB = try NfcPskDerivation.derivePsk(myPriv: aPriv, peerPub: bPriv.publicKey)
        let pskAC = try NfcPskDerivation.derivePsk(myPriv: aPriv, peerPub: cPriv.publicKey)

        XCTAssertNotEqual(pskAB, pskAC, "Different peer keys must yield different PSKs")
    }

    // MARK: - Exact hkdfInfo bytes

    func testHkdfInfoBytes() {
        let expected = Data("Q-Audion NFC Collaborative PSK v1".utf8)
        XCTAssertEqual(NfcPskDerivation.hkdfInfo, expected,
                       "hkdfInfo must be the UTF-8 encoding of 'Q-Audion NFC Collaborative PSK v1'")
    }

    // MARK: - KAT vector (pending Android cross-validation)

    func testKatVector() throws {
        // a_priv: 0x01..0x20 (bytes 1..32)
        let aPrivBytes = Data((1...32).map { UInt8($0) })
        // b_priv: 0x21..0x40 (bytes 33..64)
        let bPrivBytes = Data((33...64).map { UInt8($0) })

        let aPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPrivBytes)
        let bPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bPrivBytes)

        // expected_psk: pending Android cross-validation — skip until confirmed
        try XCTSkipUnless(false, "KAT vector pending Android cross-validation")

        // Placeholder — the actual expected_psk value will be inserted after
        // Android smoke-test confirms the derivation. See cross_platform_vectors.json
        // "nfc_psk_v1" block for the slot.
        _ = try NfcPskDerivation.derivePsk(myPriv: aPriv, peerPub: bPriv.publicKey)
    }
}
