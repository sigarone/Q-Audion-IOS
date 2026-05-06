import XCTest
@testable import QAudionEngine

/// Cross-platform parity tests for the peppered SHA-256 contact-discovery hash.
/// The pinned KAT below was computed in Python:
///
///   pepper = bytes([0x42] * 32)
///   e164   = "+39123456789"
///   sha256(pepper + e164.encode('utf-8')).hex()
///
/// Any drift here means iOS and Android compute different hashes for the
/// same phone number and the contact-discovery server-side join breaks
/// silently (peers appear to be missing from each other's contacts).
final class PepperedPhoneHashTests: XCTestCase {

    func testHashShapeIsLowercaseHex64Chars() throws {
        // SHA-256 → 32 bytes → 64 lowercase hex chars.
        let pepperBytes = Data(repeating: 0x42, count: 32)
        let h = try PepperedPhoneHash.hash(phone: "+39123456789", pepperBytes: pepperBytes)
        XCTAssertEqual(h.count, 64)
        let validChars = CharacterSet(charactersIn: "0123456789abcdef")
        for c in h.unicodeScalars {
            XCTAssertTrue(validChars.contains(c), "non-hex char in output: \(c)")
        }
    }

    func testDeterministic() throws {
        let pepperBytes = Data(repeating: 0x42, count: 32)
        let a = try PepperedPhoneHash.hash(phone: "+39123456789", pepperBytes: pepperBytes)
        let b = try PepperedPhoneHash.hash(phone: "+39123456789", pepperBytes: pepperBytes)
        XCTAssertEqual(a, b)
    }

    func testBase64PepperMatchesByteForm() throws {
        let pepperBytes = Data(repeating: 0xAA, count: 16)
        let pepperB64 = pepperBytes.base64EncodedString()
        let phone = "+39123456789"
        let viaBytes = try PepperedPhoneHash.hash(phone: phone, pepperBytes: pepperBytes)
        let viaB64 = try PepperedPhoneHash.hash(phone: phone, pepperBase64: pepperB64)
        XCTAssertEqual(viaBytes, viaB64,
                       "byte and base64 entry points must produce identical hashes")
    }

    func testEmptyPepperRejected() {
        XCTAssertThrowsError(try PepperedPhoneHash.hash(phone: "+39123456789", pepperBytes: Data()))
        XCTAssertThrowsError(try PepperedPhoneHash.hash(phone: "+39123456789", pepperBase64: ""))
    }

    func testInvalidBase64Rejected() {
        XCTAssertThrowsError(try PepperedPhoneHash.hash(phone: "+39123456789", pepperBase64: "not base64!@#"))
    }

    func testInvalidPhoneRejected() {
        let pepperBytes = Data(repeating: 0x01, count: 8)
        XCTAssertThrowsError(try PepperedPhoneHash.hash(phone: "garbage", pepperBytes: pepperBytes))
    }

    func testBatchHashSkipsInvalid() {
        let pepperBytes = Data(repeating: 0x01, count: 8)
        let results = PepperedPhoneHash.batchHash(phones: ["+39123456789", "garbage", "+33123456789"],
                                                  pepperBytes: pepperBytes)
        XCTAssertEqual(results.count, 3)
        XCTAssertNotNil(results[0].hash)
        XCTAssertNil(results[1].hash)
        XCTAssertNotNil(results[2].hash)
    }

    func testDifferentPhonesProduceDifferentHashes() throws {
        let pepperBytes = Data(repeating: 0x01, count: 16)
        let h1 = try PepperedPhoneHash.hash(phone: "+39123456789", pepperBytes: pepperBytes)
        let h2 = try PepperedPhoneHash.hash(phone: "+39987654321", pepperBytes: pepperBytes)
        XCTAssertNotEqual(h1, h2)
    }

    func testDifferentPeppersProduceDifferentHashes() throws {
        let phone = "+39123456789"
        let h1 = try PepperedPhoneHash.hash(phone: phone, pepperBytes: Data(repeating: 0x01, count: 16))
        let h2 = try PepperedPhoneHash.hash(phone: phone, pepperBytes: Data(repeating: 0x02, count: 16))
        XCTAssertNotEqual(h1, h2)
    }
}
