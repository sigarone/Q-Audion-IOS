import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform KAT for `NfcSasComputation` — pins byte-exact parity with Android's
/// `app/.../nfc/SasComputation.kt`. Both vectors are pulled verbatim from that file's own
/// `init {}` self-check block (computed offline there with
/// `python hmac.new(b"qaudion-sas-v1", ikm, sha256)`), independently re-verified with a
/// from-scratch Python reference before this file was written — see the session's KAT
/// discipline (never hand-copy a derived value without an independent re-check).
final class NfcSasComputationKatTests: XCTestCase {

    func testVectorA_zerosVsFFs() throws {
        let a = Data(repeating: 0x00, count: 32)
        let b = Data(repeating: 0xFF, count: 32)
        XCTAssertEqual(try NfcSasComputation.computeSas(selfIkEdPub: a, peerIkEdPub: b), "759936")
        XCTAssertEqual(try NfcSasComputation.computeSas(selfIkEdPub: b, peerIkEdPub: a), "759936",
                       "must be commutative — sort_lex makes tap order irrelevant")
    }

    func testVectorB_countedBytes() throws {
        let a = Data((0..<32).map { UInt8($0) })
        let b = Data((32..<64).map { UInt8($0) })
        XCTAssertEqual(try NfcSasComputation.computeSas(selfIkEdPub: a, peerIkEdPub: b), "360896")
    }

    func testRejectsWrongLength() {
        let short = Data(repeating: 0x01, count: 16)
        let full = Data(repeating: 0x02, count: 32)
        XCTAssertThrowsError(try NfcSasComputation.computeSas(selfIkEdPub: short, peerIkEdPub: full))
    }

    func testRejectsSelfHandshake() {
        let a = Data(repeating: 0x03, count: 32)
        XCTAssertThrowsError(try NfcSasComputation.computeSas(selfIkEdPub: a, peerIkEdPub: a)) { error in
            XCTAssertEqual(error as? NfcSasComputation.SasError, .selfHandshake)
        }
    }

    func testOutputIsAlwaysSixDigits() throws {
        // A real Ed25519 keypair, to also exercise the non-small-order validation path.
        let key1 = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let key2 = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let sas = try NfcSasComputation.computeSas(selfIkEdPub: key1, peerIkEdPub: key2)
        XCTAssertEqual(sas.count, 6)
        XCTAssertTrue(sas.allSatisfy { $0.isNumber })
    }
}
