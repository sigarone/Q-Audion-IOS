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

    // MARK: - PSK-mix ship-step-2 (parse-only): parseSelection

    func testParseSelectionEmptyOrNilIsNoSelection() {
        XCTAssertEqual(QAudionCallIntegration.parseSelection(""), [])
        XCTAssertEqual(QAudionCallIntegration.parseSelection(nil), [])
    }

    func testParseSelectionSingleFingerprintIsUnchanged() {
        let fp = String(repeating: "a", count: 64)
        XCTAssertEqual(QAudionCallIntegration.parseSelection(fp), [fp])
    }

    func testParseSelectionTwoValidFingerprintsBothReturned() {
        let fp1 = String(repeating: "a", count: 64)
        let fp2 = String(repeating: "b", count: 64)
        XCTAssertEqual(QAudionCallIntegration.parseSelection("\(fp1),\(fp2)"), [fp1, fp2])
    }

    func testParseSelectionFourValidFingerprintsAllReturned() {
        let fps = (0..<4).map { String(repeating: String(format: "%x", $0), count: 64) }
        XCTAssertEqual(QAudionCallIntegration.parseSelection(fps.joined(separator: ",")), fps)
    }

    func testParseSelectionRejectsOddOrEmptyEntries() {
        let fp1 = String(repeating: "a", count: 64)
        let fp2 = String(repeating: "b", count: 64)
        // "a,,b" — empty middle entry.
        XCTAssertEqual(QAudionCallIntegration.parseSelection("\(fp1),,\(fp2)"), [])
        // "a,b," — trailing comma / empty final entry.
        XCTAssertEqual(QAudionCallIntegration.parseSelection("\(fp1),\(fp2),"), [])
    }

    func testParseSelectionRejectsUppercaseHex() {
        let fp = String(repeating: "A", count: 64)
        XCTAssertEqual(QAudionCallIntegration.parseSelection(fp), [])
        let mixedList = "\(String(repeating: "a", count: 64)),\(String(repeating: "B", count: 64))"
        XCTAssertEqual(QAudionCallIntegration.parseSelection(mixedList), [])
    }

    func testParseSelectionRejectsWrongLength() {
        XCTAssertEqual(QAudionCallIntegration.parseSelection(String(repeating: "a", count: 63)), [])
        XCTAssertEqual(QAudionCallIntegration.parseSelection(String(repeating: "a", count: 65)), [])
        let short = String(repeating: "a", count: 63)
        let ok = String(repeating: "b", count: 64)
        XCTAssertEqual(QAudionCallIntegration.parseSelection("\(short),\(ok)"), [])
    }

    func testParseSelectionRejectsMoreThanFourEntries() {
        let fps = (0..<5).map { String(repeating: String(format: "%x", $0), count: 64) }
        XCTAssertEqual(QAudionCallIntegration.parseSelection(fps.joined(separator: ",")), [])
    }

    // MARK: - PSK-mix ship-step-2: gate tolerates a comma-joined `fp`

    func testGateMatchesWithinCommaJoinedSelection() {
        let psk = Data(repeating: 0x09, count: 32)
        let fp = SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
        let other = String(repeating: "c", count: 64)
        XCTAssertEqual(QAudionCallIntegration.pskIfFingerprintMatches(psk, "\(other),\(fp)"), psk)
        XCTAssertEqual(QAudionCallIntegration.pskIfFingerprintMatches(psk, "\(fp),\(other)"), psk)
    }

    func testGateMalformedSelectionFailsClosed() {
        let psk = Data(repeating: 0x09, count: 32)
        let fp = SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
        // A malformed multi-selection string that happens to CONTAIN the real
        // fp as a substring must still be rejected outright (no partial
        // parse), not treated as a match.
        XCTAssertNil(QAudionCallIntegration.pskIfFingerprintMatches(psk, "\(fp),,x"))
    }
}
