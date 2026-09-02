import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform parity tests for the in-call SAS derivation. The pinned
/// vector below was computed from Python's `hmac.new(...)` against the
/// canonical `qaudion-sas-v1` / `sas-words-v1` constants and is the
/// source of truth for byte-parity with Android (`ComputeSasUseCaseTest`).
/// If this test ever fails, the salt or info drifted from the Android
/// constants — fix that first, never adjust the expected output.
final class ComputeSasUseCaseTests: XCTestCase {

    func testWordListSize() {
        XCTAssertEqual(PgpSasWordList.words.count, 256)
    }

    /// Pinned cross-platform KAT vector.
    /// Session key = 0x00..0x1F (32 bytes).
    /// Reference Python:
    ///   prk = hmac.new(b"qaudion-sas-v1", bytes(range(32)), hashlib.sha256).digest()
    ///   T1  = hmac.new(prk, b"sas-words-v1\x01", hashlib.sha256).digest()
    ///   okm = T1[:18]   # = 20 28 26 c7 a2 9a 43 22 22 78 c2 84 06 6e 4e 6e ca c2
    ///   indices = [38, 154, 34, 132, 78, 194]
    /// → ["bookshelf", "pupil", "blockade", "mural", "drifter", "snapshot"]
    func testPinnedVectorV2SaltProducesExpectedWords() throws {
        let sessionKey = Data((0..<32).map { UInt8($0) })
        let sas = try ComputeSasUseCase.invoke(sessionKey: sessionKey)
        XCTAssertEqual(sas.words,
                       ["bookshelf", "pupil", "blockade", "mural", "drifter", "snapshot"],
                       "Pinned cross-platform vector — if this fails, the salt or info drifted from `qaudion-sas-v1` / `sas-words-v1`.")
    }

    func testDerivationIsDeterministic() throws {
        let key = Data(repeating: 0x42, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key)
        let b = try ComputeSasUseCase.invoke(sessionKey: key)
        XCTAssertEqual(a.words, b.words)
    }

    func testDifferentKeysProduceDifferentSas() throws {
        let k1 = Data(repeating: 0x01, count: 32)
        let k2 = Data(repeating: 0x02, count: 32)
        let s1 = try ComputeSasUseCase.invoke(sessionKey: k1)
        let s2 = try ComputeSasUseCase.invoke(sessionKey: k2)
        XCTAssertNotEqual(s1.words, s2.words)
    }

    func testEmptyKeyThrows() {
        XCTAssertThrowsError(try ComputeSasUseCase.invoke(sessionKey: Data())) { err in
            guard case ComputeSasUseCase.SasError.emptyKey = err else {
                XCTFail("expected .emptyKey, got \(err)"); return
            }
        }
    }

    func testInitiatorFlagDoesNotChangeOutput() throws {
        // Both peers must derive the same SAS — the flag is reserved.
        let key = Data(repeating: 0x77, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, initiator: true)
        let b = try ComputeSasUseCase.invoke(sessionKey: key, initiator: false)
        XCTAssertEqual(a.words, b.words)
    }

    // MARK: - matches / parse

    func testMatchesIsTrueForEqualSas() throws {
        let key = Data(repeating: 0x33, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key)
        let b = try ComputeSasUseCase.invoke(sessionKey: key)
        XCTAssertTrue(ComputeSasUseCase.matches(a, b))
    }

    func testMatchesIsFalseForDifferentSas() throws {
        let a = try ComputeSasUseCase.invoke(sessionKey: Data(repeating: 0x01, count: 32))
        let b = try ComputeSasUseCase.invoke(sessionKey: Data(repeating: 0x02, count: 32))
        XCTAssertFalse(ComputeSasUseCase.matches(a, b))
    }

    func testParseAcceptsSeveralSeparators() {
        XCTAssertNotNil(ComputeSasUseCase.parse("a b c d e f"))
        XCTAssertNotNil(ComputeSasUseCase.parse("a-b-c-d-e-f"))
        XCTAssertNotNil(ComputeSasUseCase.parse("a · b · c · d · e · f"))
        XCTAssertNotNil(ComputeSasUseCase.parse("a,b,c,d,e,f"))
    }

    func testParseRejectsWrongCount() {
        XCTAssertNil(ComputeSasUseCase.parse("only three words here"))
        XCTAssertNil(ComputeSasUseCase.parse("a b c d e f g"))
    }

    func testParseUppercasesAndTrims() throws {
        let parsed = ComputeSasUseCase.parse(" foo bar baz qux quux corge ")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.words, ["FOO", "BAR", "BAZ", "QUX", "QUUX", "CORGE"])
    }

    func testDisplayUppercasesWithBulletSeparator() {
        let s = ComputeSasUseCase.Sas(words: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"])
        XCTAssertEqual(s.display, "ALPHA · BETA · GAMMA · DELTA · EPSILON · ZETA")
    }

    // MARK: - CALL-4/HSID-002 (2026-09-02 protocol audit) — transcriptHash param

    func testTranscriptHashNilIsByteIdenticalToBeforeThisFix() throws {
        // The pinned cross-platform KAT vector above MUST still hold when the
        // new parameter is omitted (its default) — this fix must not have
        // touched the legacy, transcript-independent derivation path at all.
        let sessionKey = Data((0..<32).map { UInt8($0) })
        let withDefault = try ComputeSasUseCase.invoke(sessionKey: sessionKey)
        let withExplicitNil = try ComputeSasUseCase.invoke(sessionKey: sessionKey, transcriptHash: nil)
        XCTAssertEqual(withDefault.words, ["bookshelf", "pupil", "blockade", "mural", "drifter", "snapshot"])
        XCTAssertEqual(withDefault.words, withExplicitNil.words)
    }

    func testTranscriptHashChangesTheWordsForTheSameSessionKey() throws {
        let key = Data(repeating: 0x55, count: 32)
        let legacy = try ComputeSasUseCase.invoke(sessionKey: key)
        let bound = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: Data(repeating: 0xAA, count: 32))
        XCTAssertNotEqual(
            legacy.words, bound.words,
            "supplying a transcript hash must change the derivation label (SasTranscriptBindV1), never silently reuse the legacy info string"
        )
    }

    func testDifferentTranscriptHashesProduceDifferentWordsForTheSameSessionKey() throws {
        // CALL-4 core property: two calls that negotiated DIFFERENT
        // capability sets (hence different transcript hashes) must show
        // DIFFERENT SAS words to the user even if, hypothetically, their
        // session keys ever coincided — this is the "fold into the SAS
        // input too, under its own label" half of the fix, independent of
        // the session-key fold tested in SessionKeyTranscriptBoundTests.
        let key = Data(repeating: 0x66, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: Data(repeating: 0x01, count: 32))
        let b = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: Data(repeating: 0x02, count: 32))
        XCTAssertNotEqual(a.words, b.words)
    }

    func testTranscriptHashDerivationIsDeterministic() throws {
        let key = Data(repeating: 0x77, count: 32)
        let hash = Data(repeating: 0x09, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: hash)
        let b = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: hash)
        XCTAssertEqual(a.words, b.words)
    }

    /// First-principles reconstruction of the exact HKDF this fix's own doc
    /// specifies: same salt (`SasConstants.saltBytes`, unchanged), `info =
    /// HkdfLabels.sasTranscriptBindV1(23) || transcriptHash(32)` REPLACING
    /// (not appending to) `SasConstants.infoWordsBytes`.
    ///
    /// ITEM 2/3 FOLLOW-UP (2026-09-02) — the label reconciled to Android's
    /// canonical value `"q-audion-sas-transcript"` (23 bytes, no `-v1`
    /// suffix) — see `HkdfLabels.sasTranscriptBindV1`'s doc.
    func testTranscriptHashMatchesFirstPrinciplesHkdfReconstruction() throws {
        let key = Data(repeating: 0x22, count: 32)
        let hash = Data(repeating: 0x33, count: 32)
        var expectedInfo = Data("q-audion-sas-transcript".utf8)
        expectedInfo.append(hash)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data("qaudion-sas-v1".utf8),
            info: expectedInfo,
            outputByteCount: 18
        ).withUnsafeBytes { Data($0) }
        var expectedIndices = [Int]()
        for i in 0..<6 {
            let a = Int(derived[i * 3]), b = Int(derived[i * 3 + 1]), c = Int(derived[i * 3 + 2])
            expectedIndices.append(((a << 16) | (b << 8) | c) % PgpSasWordList.words.count)
        }
        let expectedWords = expectedIndices.map { PgpSasWordList.words[$0] }
        let actual = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: hash)
        XCTAssertEqual(actual.words, expectedWords)
    }
}
