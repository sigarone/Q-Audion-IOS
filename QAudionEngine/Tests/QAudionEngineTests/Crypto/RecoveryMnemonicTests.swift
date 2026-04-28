import XCTest
@testable import QAudionEngine

final class RecoveryMnemonicTests: XCTestCase {

    func test_generate_produces12Words() {
        let words = RecoveryMnemonic.generate()
        XCTAssertEqual(words.count, 12)
    }

    func test_generate_allWordsLowercase() {
        let words = RecoveryMnemonic.generate()
        for w in words {
            XCTAssertEqual(w, w.lowercased())
        }
    }

    func test_generate_allWordsInWordlist() {
        let words = RecoveryMnemonic.generate()
        let set = Set(RecoveryMnemonic.wordList)
        for w in words {
            XCTAssertTrue(set.contains(w), "\(w) not in wordlist")
        }
    }

    func test_canonicalHash_returns64HexChars() throws {
        let words = ["abandon","ability","able","about","above","absent","absorb","abstract","absurd","abuse","access","accident"]
        let hash = try RecoveryMnemonic.canonicalHash(words: words)
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func test_canonicalHash_isDeterministic() throws {
        let words = ["abandon","ability","able","about","above","absent","absorb","abstract","absurd","abuse","access","accident"]
        let hash1 = try RecoveryMnemonic.canonicalHash(words: words)
        let hash2 = try RecoveryMnemonic.canonicalHash(words: words)
        XCTAssertEqual(hash1, hash2)
    }

    func test_canonicalHash_caseInsensitive() throws {
        let lower = ["abandon","ability","able","about","above","absent","absorb","abstract","absurd","abuse","access","accident"]
        let mixed = ["ABANDON","Ability","ABLE","About","ABOVE","Absent","ABSORB","Abstract","ABSURD","Abuse","ACCESS","Accident"]
        let h1 = try RecoveryMnemonic.canonicalHash(words: lower)
        let h2 = try RecoveryMnemonic.canonicalHash(words: mixed)
        XCTAssertEqual(h1, h2)
    }

    func test_canonicalHash_rejectsWrongCount() {
        let words = ["abandon","ability","able"]
        XCTAssertThrowsError(try RecoveryMnemonic.canonicalHash(words: words)) { err in
            guard case RecoveryMnemonic.Error.invalidWordCount(let n) = err else {
                XCTFail("Expected .invalidWordCount, got \(err)"); return
            }
            XCTAssertEqual(n, 3)
        }
    }

    func test_validate_acceptsKnownWords() throws {
        let words = ["abandon","ability","able","about","above","absent","absorb","abstract","absurd","abuse","access","accident"]
        XCTAssertNoThrow(try RecoveryMnemonic.validate(words: words))
    }

    func test_validate_rejectsUnknownWord() {
        let words = ["abandon","ability","able","about","above","absent","absorb","abstract","absurd","abuse","access","unknownword"]
        XCTAssertThrowsError(try RecoveryMnemonic.validate(words: words)) { err in
            guard case RecoveryMnemonic.Error.unknownWord(let w) = err else {
                XCTFail("Expected .unknownWord, got \(err)"); return
            }
            XCTAssertEqual(w, "unknownword")
        }
    }
}
