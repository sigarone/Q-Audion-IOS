import XCTest
import CryptoKit
@testable import QAudionEngine

/// In-call SAS derivation, transcript-v6 form (WIRE_SPEC §4): the words depend on the ROUND-1 session
/// key, `SHA-256(ACCEPT_v6)` AND the caller's committed `sasNonce`. There is no transcript-free and no
/// nonce-free SAS. The cross-platform byte vectors live in the v6 handshake KAT
/// (`HandshakeTranscriptV6Tests`); the tests here pin the construction by reconstructing it from first
/// principles and check the properties the commitment relies on (a different nonce, key or hash changes
/// the words).
final class ComputeSasUseCaseTests: XCTestCase {

    private let acceptHash = Data(repeating: 0xAB, count: 32)
    private let nonce = Data((0..<32).map { UInt8($0) })

    func testWordListSize() {
        XCTAssertEqual(PgpSasWordList.words.count, 256)
    }

    func testTheWordCountIsOneConstantAndTheKdfLengthFollowsIt() {
        XCTAssertEqual(SasConstants.wordCount, 6, "D5: 6 words = 48 bits")
        XCTAssertEqual(ComputeSasUseCase.sasWordCount, SasConstants.wordCount)
        XCTAssertEqual(ComputeSasUseCase.hkdfOutputBytes, 3 * SasConstants.wordCount)
        XCTAssertEqual(ComputeSasUseCase.hkdfOutputBytes, 18)
    }

    func testDerivationIsDeterministic() throws {
        let key = Data(repeating: 0x42, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash, sasNonce: nonce)
        let b = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash, sasNonce: nonce)
        XCTAssertEqual(a.words, b.words)
        XCTAssertEqual(a.words.count, ComputeSasUseCase.sasWordCount)
    }

    func testDifferentKeysProduceDifferentSas() throws {
        let s1 = try ComputeSasUseCase.invoke(
            sessionKey: Data(repeating: 0x01, count: 32), transcriptHash: acceptHash, sasNonce: nonce)
        let s2 = try ComputeSasUseCase.invoke(
            sessionKey: Data(repeating: 0x02, count: 32), transcriptHash: acceptHash, sasNonce: nonce)
        XCTAssertNotEqual(s1.words, s2.words)
    }

    /// The DTLS binding: the same session key under a different ACCEPT_v6 hash (a rewritten
    /// fingerprint, identity key, ciphertext or commitment) shows different words.
    func testDifferentTranscriptHashesProduceDifferentWords() throws {
        let key = Data(repeating: 0x66, count: 32)
        let a = try ComputeSasUseCase.invoke(
            sessionKey: key, transcriptHash: Data(repeating: 0x01, count: 32), sasNonce: nonce)
        let b = try ComputeSasUseCase.invoke(
            sessionKey: key, transcriptHash: Data(repeating: 0x02, count: 32), sasNonce: nonce)
        XCTAssertNotEqual(a.words, b.words)
    }

    /// The commitment's whole point: the nonce enters the words. Without this a callee could still
    /// grind (this test fails if the nonce is dropped from the derivation).
    func testTheNonceChangesTheWords() throws {
        let key = Data(repeating: 0x55, count: 32)
        var flipped = nonce
        flipped[0] ^= 0x01
        let a = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash, sasNonce: nonce)
        let b = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash, sasNonce: flipped)
        XCTAssertNotEqual(a.words, b.words)
    }

    func testEmptyKeyThrows() {
        XCTAssertThrowsError(
            try ComputeSasUseCase.invoke(sessionKey: Data(), transcriptHash: acceptHash, sasNonce: nonce)
        ) { err in
            XCTAssertEqual(err as? ComputeSasUseCase.SasError, .emptyKey)
        }
    }

    func testWrongHashLengthThrows() {
        let key = Data(repeating: 0x11, count: 32)
        for n in [0, 31, 33, 64] {
            XCTAssertThrowsError(
                try ComputeSasUseCase.invoke(
                    sessionKey: key, transcriptHash: Data(repeating: 0x01, count: n), sasNonce: nonce)
            ) { err in
                XCTAssertEqual(err as? ComputeSasUseCase.SasError, .badTranscriptHash)
            }
        }
    }

    func testWrongNonceLengthThrows() {
        let key = Data(repeating: 0x11, count: 32)
        for n in [0, 16, 31, 33, 64] {
            XCTAssertThrowsError(
                try ComputeSasUseCase.invoke(
                    sessionKey: key, transcriptHash: acceptHash, sasNonce: Data(repeating: 0x01, count: n))
            ) { err in
                XCTAssertEqual(err as? ComputeSasUseCase.SasError, .badNonce)
            }
        }
    }

    /// First-principles reconstruction: salt "qaudion-sas-v1", info "q-audion-sas-v6" || hash || nonce
    /// (15 + 32 + 32 = 79 bytes), L = 18, six big-endian uint24 indices modulo the 256-word list.
    func testMatchesFirstPrinciplesHkdfReconstruction() throws {
        let key = Data(repeating: 0x22, count: 32)
        let h = Data(repeating: 0x33, count: 32)
        var info = Data("q-audion-sas-v6".utf8)
        XCTAssertEqual(info.count, 15)
        info.append(h)
        info.append(nonce)
        XCTAssertEqual(info.count, 79)
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
        let actual = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: h, sasNonce: nonce)
        XCTAssertEqual(actual.words, expected)
    }

    /// The design-check vector of SASCOMMIT_DESIGN §2.6 (independent Python reference): the same words
    /// every platform must produce from the same synthetic inputs.
    func testDesignCheckVector() throws {
        let key = Data(repeating: 0x11, count: 32)
        let hash = Data(SHA256.hash(data: Data("design-check ACCEPT_v6 bytes".utf8)))
        XCTAssertEqual(hash.map { String(format: "%02x", $0) }.joined(),
                       "78c373629a88841eb5d67829551c86d127f3e62fa7b317ad8144029f399af43d")
        let designNonce = Data((0..<32).map { UInt8($0) })
        let sas = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: hash, sasNonce: designNonce)
        XCTAssertEqual(sas.words, ["bluebird", "baboon", "adrift", "pheasant", "Neptune", "crucial"])
    }

    // MARK: - matches / parse

    func testMatchesIsTrueForEqualSas() throws {
        let key = Data(repeating: 0x33, count: 32)
        let a = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash, sasNonce: nonce)
        let b = try ComputeSasUseCase.invoke(sessionKey: key, transcriptHash: acceptHash, sasNonce: nonce)
        XCTAssertTrue(ComputeSasUseCase.matches(a, b))
    }

    func testMatchesIsFalseForDifferentSas() throws {
        let a = try ComputeSasUseCase.invoke(
            sessionKey: Data(repeating: 0x01, count: 32), transcriptHash: acceptHash, sasNonce: nonce)
        let b = try ComputeSasUseCase.invoke(
            sessionKey: Data(repeating: 0x02, count: 32), transcriptHash: acceptHash, sasNonce: nonce)
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
