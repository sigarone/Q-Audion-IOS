import XCTest
import CryptoKit
@testable import QAudionEngine

/// In-call SAS derivation, transcript-v5 form (WIRE_SPEC §4): the words depend on the session key
/// AND `SHA-256(ACCEPT_v5)`. There is no transcript-free SAS. The cross-platform byte vectors live
/// in the v5 handshake KAT (`HandshakeTranscriptV5Tests`); the tests here pin the construction by
/// reconstructing it from first principles.
final class ComputeSasUseCaseTests: XCTestCase {

    private let acceptHash = Data(repeating: 0xAB, count: 32)

    func testWordListSize() {
        XCTAssertEqual(PgpSasWordList.words.count, 256)
    }

    func testDerivationIsDeterministic() throws {
        let key = Data(repeating: 0x42, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash)
        let b = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash)
        XCTAssertEqual(a.words, b.words)
        XCTAssertEqual(a.words.count, ComputeSasUseCase.sasWordCount)
    }

    func testDifferentKeysProduceDifferentSas() throws {
        let s1 = try ComputeSasUseCase.invoke(sessionKey: Data(repeating: 0x01, count: 32), transcriptHash: acceptHash)
        let s2 = try ComputeSasUseCase.invoke(sessionKey: Data(repeating: 0x02, count: 32), transcriptHash: acceptHash)
        XCTAssertNotEqual(s1.words, s2.words)
    }

    /// The core property of the DTLS binding: the same session key under a different ACCEPT_v5 hash
    /// (a rewritten fingerprint, identity key or ciphertext) shows different words.
    func testDifferentTranscriptHashesProduceDifferentWords() throws {
        let key = Data(repeating: 0x66, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: Data(repeating: 0x01, count: 32))
        let b = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: Data(repeating: 0x02, count: 32))
        XCTAssertNotEqual(a.words, b.words)
    }

    func testEmptyKeyThrows() {
        XCTAssertThrowsError(try ComputeSasUseCase.invoke(sessionKey: Data(), transcriptHash: acceptHash)) { err in
            XCTAssertEqual(err as? ComputeSasUseCase.SasError, .emptyKey)
        }
    }

    func testWrongHashLengthThrows() {
        let key = Data(repeating: 0x11, count: 32)
        for n in [0, 31, 33, 64] {
            XCTAssertThrowsError(
                try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: Data(repeating: 0x01, count: n))
            ) { err in
                XCTAssertEqual(err as? ComputeSasUseCase.SasError, .badTranscriptHash)
            }
        }
    }

    func testInitiatorFlagDoesNotChangeOutput() throws {
        let key = Data(repeating: 0x77, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, initiator: true, transcriptHash: acceptHash)
        let b = try ComputeSasUseCase.invoke(sessionKey: key, initiator: false, transcriptHash: acceptHash)
        XCTAssertEqual(a.words, b.words)
    }

    /// First-principles reconstruction: salt "qaudion-sas-v1", info "q-audion-sas-transcript" ||
    /// hash (55 bytes), L = 18, six big-endian uint24 indices modulo the 256-word list.
    func testMatchesFirstPrinciplesHkdfReconstruction() throws {
        let key = Data(repeating: 0x22, count: 32)
        let h = Data(repeating: 0x33, count: 32)
        var info = Data("q-audion-sas-transcript".utf8)
        XCTAssertEqual(info.count, 23)
        info.append(h)
        XCTAssertEqual(info.count, 55)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data("qaudion-sas-v1".utf8),
            info: info,
            outputByteCount: 18
        ).withUnsafeBytes { Data($0) }
        var expected = [String]()
        for i in 0..<6 {
            let a = Int(derived[i * 3]), b = Int(derived[i * 3 + 1]), c = Int(derived[i * 3 + 2])
            expected.append(PgpSasWordList.words[((a << 16) | (b << 8) | c) % PgpSasWordList.words.count])
        }
        let actual = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: h)
        XCTAssertEqual(actual.words, expected)
    }

    // MARK: - matches / parse

    func testMatchesIsTrueForEqualSas() throws {
        let key = Data(repeating: 0x33, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash)
        let b = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash)
        XCTAssertTrue(ComputeSasUseCase.matches(a, b))
    }

    func testMatchesIsFalseForDifferentSas() throws {
        let a = try ComputeSasUseCase.invoke(sessionKey: Data(repeating: 0x01, count: 32), transcriptHash: acceptHash)
        let b = try ComputeSasUseCase.invoke(sessionKey: Data(repeating: 0x02, count: 32), transcriptHash: acceptHash)
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
