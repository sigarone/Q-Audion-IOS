import XCTest
import CryptoKit
@testable import QAudionEngine

final class BackupCipherTests: XCTestCase {

    func test_aeadEncryptDecrypt_roundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Q-Audion backup test payload".utf8)
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...UInt8.max) })

        let sealed = try BackupCipher.aeadEncrypt(plaintext: plaintext, key: key, nonce: nonce, aad: nil)
        XCTAssertEqual(sealed.nonce.count, 12)
        XCTAssertEqual(sealed.tag.count, 16)
        XCTAssertEqual(sealed.ciphertext.count, plaintext.count)

        let decrypted = try BackupCipher.aeadDecrypt(sealed, key: key, aad: nil)
        XCTAssertEqual(decrypted, plaintext)
    }

    func test_aeadEncrypt_withAad_roundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data((0..<512).map { UInt8($0 & 0xFF) })
        let aad = Data("qaudion.backup.v1".utf8)
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...UInt8.max) })

        let sealed = try BackupCipher.aeadEncrypt(plaintext: plaintext, key: key, nonce: nonce, aad: aad)
        let decrypted = try BackupCipher.aeadDecrypt(sealed, key: key, aad: aad)
        XCTAssertEqual(decrypted, plaintext)
    }

    func test_aeadDecrypt_wrongAad_throws() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Q-Audion".utf8)
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...UInt8.max) })

        let sealed = try BackupCipher.aeadEncrypt(plaintext: plaintext, key: key, nonce: nonce, aad: Data("aad-A".utf8))
        XCTAssertThrowsError(try BackupCipher.aeadDecrypt(sealed, key: key, aad: Data("aad-B".utf8)))
    }

    func test_aeadDecrypt_tampered_throws() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Q-Audion".utf8)
        let nonce = Data((0..<12).map { _ in UInt8.random(in: 0...UInt8.max) })

        let sealed = try BackupCipher.aeadEncrypt(plaintext: plaintext, key: key, nonce: nonce, aad: nil)
        // Tamper with one byte of ciphertext.
        var tamperedCt = sealed.ciphertext
        // `sealed.ciphertext` comes straight from `AES.GCM.SealedBox
        // .ciphertext`, and CryptoKit hands that back as a Data VIEW whose
        // indices need not start at 0. Swift's Data keeps absolute indices
        // on a slice, so `tamperedCt[0]` is an out-of-bounds subscript the
        // moment the view is offset — the exact hazard this repo already
        // documents in `FuzzCorpus.sliced`. That is what killed the whole
        // xctest process here (the run reported "0 failures" AND "** TEST
        // FAILED **": XCTest restarts after a crash and never counts the
        // case that died), and it is why this one test was excluded on
        // 2026-06-19. Index relative to `startIndex` instead.
        tamperedCt[tamperedCt.startIndex] ^= 0x01
        let tampered = BackupCipher.SealedBox(nonce: sealed.nonce, ciphertext: tamperedCt, tag: sealed.tag)
        XCTAssertThrowsError(try BackupCipher.aeadDecrypt(tampered, key: key, aad: nil))
    }

    func test_aeadEncrypt_rejectsWrongNonceSize() {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("Q-Audion".utf8)
        let badNonce = Data((0..<10).map { _ in UInt8(0) })  // 10B instead of 12B
        XCTAssertThrowsError(
            try BackupCipher.aeadEncrypt(plaintext: plaintext, key: key, nonce: badNonce, aad: nil)
        )
    }

    func test_scryptDeriveKey_succeedsAfterUnblock() throws {
        // scrypt is now implemented (§10 unblocked 2026-04-28).
        // N=131072 is slow; skip in fast-CI mode.
        try XCTSkipIf(ProcessInfo.processInfo.environment["FAST_TESTS"] != nil,
                      "Skip scrypt-heavy test in fast mode")
        let key = try BackupCipher.deriveKey(password: "test", salt: Data((0..<16).map { _ in UInt8(0) }))
        XCTAssertEqual(key.bitCount, 256)
    }
}
