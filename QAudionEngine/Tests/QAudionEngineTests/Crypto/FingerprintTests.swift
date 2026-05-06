import XCTest
@testable import QAudionEngine

final class FingerprintTests: XCTestCase {

    func test_format_produces4Groups() throws {
        let pubkey = Data((0..<32).map { UInt8($0) })  // 32 bytes
        let fp = try Fingerprint.format(pubkey: pubkey)
        let parts = fp.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
    }

    func test_format_eachGroupIs4HexChars() throws {
        let pubkey = Data((0..<32).map { UInt8($0) })
        let fp = try Fingerprint.format(pubkey: pubkey)
        for p in fp.split(separator: ".") {
            XCTAssertEqual(p.count, 4)
            XCTAssertTrue(p.allSatisfy { "0123456789abcdef".contains($0) })
        }
    }

    func test_format_isLowercase() throws {
        let pubkey = Data((0..<32).map { UInt8($0) })
        let fp = try Fingerprint.format(pubkey: pubkey)
        XCTAssertEqual(fp, fp.lowercased())
    }

    func test_format_deterministic() throws {
        let pubkey = Data((0..<32).map { UInt8($0) })
        let fp1 = try Fingerprint.format(pubkey: pubkey)
        let fp2 = try Fingerprint.format(pubkey: pubkey)
        XCTAssertEqual(fp1, fp2)
    }

    func test_format_differentPubkeys_produceDifferent() throws {
        let pubA = Data((0..<32).map { UInt8($0) })
        let pubB = Data((0..<32).map { UInt8($0 + 1) })
        let fpA = try Fingerprint.format(pubkey: pubA)
        let fpB = try Fingerprint.format(pubkey: pubB)
        XCTAssertNotEqual(fpA, fpB)
    }

    func test_format_emptyPubkey_throws() {
        XCTAssertThrowsError(try Fingerprint.format(pubkey: Data())) { err in
            guard case Fingerprint.Error.emptyPubkey = err else {
                XCTFail("Expected .emptyPubkey"); return
            }
        }
    }

    func test_format_knownVector() throws {
        // pubkey = 32 bytes of 0x00 → SHA-256 = "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"
        // First 8 bytes hex: 66687aadf862bd77 → groups: 6668.7aad.f862.bd77
        let pubkey = Data(repeating: 0, count: 32)
        let fp = try Fingerprint.format(pubkey: pubkey)
        XCTAssertEqual(fp, "6668.7aad.f862.bd77")
    }

    func test_isValid_acceptsCanonical() {
        XCTAssertTrue(Fingerprint.isValid("a3f7.c291.8b4e.d012"))
    }

    func test_isValid_rejectsUppercase() {
        XCTAssertFalse(Fingerprint.isValid("A3F7.C291.8B4E.D012"))
    }

    func test_isValid_rejectsWrongGroupCount() {
        XCTAssertFalse(Fingerprint.isValid("a3f7.c291.8b4e"))
        XCTAssertFalse(Fingerprint.isValid("a3f7.c291.8b4e.d012.extra"))
    }

    func test_isValid_rejectsWrongGroupLength() {
        XCTAssertFalse(Fingerprint.isValid("a3.c291.8b4e.d012"))
        XCTAssertFalse(Fingerprint.isValid("a3f7c.c291.8b4e.d012"))
    }

    func test_isValid_rejectsNonHex() {
        XCTAssertFalse(Fingerprint.isValid("a3f7.c2g1.8b4e.d012"))  // 'g' not hex
    }
}
