import XCTest
@testable import QAudionEngine

/// The name of a received file comes from the peer: it is used as one path component and shown to the user.
final class FileV2LocalNameTests: XCTestCase {

    func test_anOrdinaryNameIsKept() {
        XCTAssertEqual(FileV2LocalName.sanitised("Relazione 2026 (v2).pdf"), "Relazione 2026 (v2).pdf")
        XCTAssertEqual(FileV2LocalName.sanitised("già così.txt"), "già così.txt")
    }

    func test_noNameOrAnEmptyOne_getsTheFallback() {
        XCTAssertEqual(FileV2LocalName.sanitised(nil), FileV2LocalName.fallback)
        XCTAssertEqual(FileV2LocalName.sanitised(""), FileV2LocalName.fallback)
        XCTAssertEqual(FileV2LocalName.sanitised("   "), FileV2LocalName.fallback)
        XCTAssertEqual(FileV2LocalName.sanitised("..."), FileV2LocalName.fallback)
        XCTAssertEqual(FileV2LocalName.sanitised("\u{1}\u{2}"), FileV2LocalName.fallback)
    }

    func test_pathSeparatorsNeverSurvive() {
        XCTAssertEqual(FileV2LocalName.sanitised("../../etc/passwd"), ".._.._etc_passwd")
        XCTAssertEqual(FileV2LocalName.sanitised("a\\b:c"), "a_b_c")
        XCTAssertFalse(FileV2LocalName.sanitised("/abs/path").contains("/"))
    }

    func test_controlAndBidirectionalCharactersAreRemoved() {
        // "exe" that reads as "fdp" once the right-to-left override is honoured
        XCTAssertEqual(FileV2LocalName.sanitised("invoice\u{202E}fdp.exe"), "invoicefdp.exe")
        XCTAssertEqual(FileV2LocalName.sanitised("a\u{200B}b\u{FEFF}c\u{2028}d\u{7F}e"), "abcde")
        XCTAssertEqual(FileV2LocalName.sanitised("a\nb\tc\u{85}d"), "abcd")
    }

    func test_aLongNameIsCut_atACharacterBoundary_keepingAShortExtension() {
        let long = String(repeating: "a", count: 300) + ".pdf"
        let cut = FileV2LocalName.sanitised(long)
        XCTAssertLessThanOrEqual(cut.utf8.count, FileV2LocalName.maxBytes)
        XCTAssertTrue(cut.hasSuffix(".pdf"))

        let multibyte = String(repeating: "è", count: 200)     // 2 bytes each: must not be split in the middle
        let cutMultibyte = FileV2LocalName.sanitised(multibyte)
        XCTAssertLessThanOrEqual(cutMultibyte.utf8.count, FileV2LocalName.maxBytes)
        XCTAssertEqual(cutMultibyte, String(repeating: "è", count: cutMultibyte.count))
    }
}
