import XCTest
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
}
