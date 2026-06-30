import XCTest
import CryptoKit
@testable import QAudionEngine

/// Symmetric-null convergence gate (iOS↔desktop sealed-audio AEAD fix).
/// The PSK is mixed as the schema:2 HKDF Extract salt IFF its canonical
/// fingerprint lc_hex(SHA-256(psk)) byte-equals the negotiated fingerprint;
/// on any miss both ends converge on the no-PSK key instead of diverging.
/// Mirrors the desktop `pskFingerprintGate.spec.ts`.
final class PskFingerprintGateTests: XCTestCase {

    func testGateMatchesReturnsPsk() {
        let psk = Data(repeating: 0x07, count: 32)
        let fp = SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(QAudionCallIntegration.pskIfFingerprintMatches(psk, fp), psk)
    }

    func testGateMismatchReturnsNil() {
        let psk = Data(repeating: 0x07, count: 32)
        let fp = SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
        let wrong = String(fp.dropLast()) + (fp.hasSuffix("0") ? "1" : "0")
        XCTAssertNil(QAudionCallIntegration.pskIfFingerprintMatches(psk, wrong))
    }

    func testGateAbsentOrEmptyReturnsNil() {
        let psk = Data(repeating: 0x07, count: 32)
        let fp = SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
        XCTAssertNil(QAudionCallIntegration.pskIfFingerprintMatches(nil, fp))
        XCTAssertNil(QAudionCallIntegration.pskIfFingerprintMatches(Data(), fp))
        XCTAssertNil(QAudionCallIntegration.pskIfFingerprintMatches(psk, ""))
        XCTAssertNil(QAudionCallIntegration.pskIfFingerprintMatches(psk, nil))
    }
}
