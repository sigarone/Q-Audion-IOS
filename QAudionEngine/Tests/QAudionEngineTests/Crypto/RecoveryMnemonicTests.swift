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

    // MARK: - W16.A: BIP-39 wordlist invariants

    /// The canonical BIP-39 English wordlist contains exactly 2048 entries.
    /// Cross-platform restore (iOS ↔ Android ↔ Desktop) depends on every
    /// platform indexing into the same fixed-size list, so any drift here
    /// is a hard regression.
    func test_wordlist_isExactly2048Entries() {
        XCTAssertEqual(RecoveryMnemonic.wordList.count, 2048,
                       "BIP-39 English wordlist must contain exactly 2048 entries")
    }

    /// Sentinel anchors at both ends of the canonical list. If either drifts
    /// the list is no longer the upstream BIP-39 reference.
    func test_wordlist_firstAndLastEntriesMatchBip39() {
        XCTAssertEqual(RecoveryMnemonic.wordList.first, "abandon")
        XCTAssertEqual(RecoveryMnemonic.wordList.last, "zoo")
    }

    /// The canonical list is published in alphabetical order. The recovery
    /// hash algorithm doesn't rely on order, but the index→word mapping does
    /// for cross-platform mnemonic vectors. Pin the order.
    func test_wordlist_isAlphabeticallySorted() {
        let list = RecoveryMnemonic.wordList
        for i in 1..<list.count {
            XCTAssertLessThan(list[i - 1], list[i],
                              "wordList not sorted at index \(i): \(list[i - 1]) >= \(list[i])")
        }
    }

    /// No duplicate entries — required by BIP-39 spec.
    func test_wordlist_hasNoDuplicates() {
        let list = RecoveryMnemonic.wordList
        XCTAssertEqual(Set(list).count, list.count, "wordList contains duplicates")
    }

    /// Pin a handful of known BIP-39 indices. If the upstream list ever
    /// shifts, these will fail loudly instead of producing silently
    /// incompatible mnemonics across platforms.
    func test_wordlist_pinnedBip39Indices() {
        let list = RecoveryMnemonic.wordList
        XCTAssertEqual(list[0], "abandon")
        XCTAssertEqual(list[1], "ability")
        XCTAssertEqual(list[2], "able")
        XCTAssertEqual(list[3], "about")
        // BIP-39 test vector: entropy 00000000…0000 → 12-word mnemonic
        // "abandon abandon abandon abandon abandon abandon abandon abandon
        //  abandon abandon abandon about". The 12th word is index 3 of the
        // wordlist via the 11-bit chunking algorithm.
        XCTAssertEqual(list[2047], "zoo")
    }

    /// All entries are lowercase ASCII (no diacritics) so the canonical
    /// form fed to SHA-256 is byte-stable across IDE encoding settings.
    func test_wordlist_allLowercaseAscii() {
        for word in RecoveryMnemonic.wordList {
            XCTAssertEqual(word, word.lowercased(),
                           "non-lowercase entry: \(word)")
            XCTAssertTrue(word.allSatisfy { $0.isASCII },
                          "non-ASCII entry: \(word)")
        }
    }
}
