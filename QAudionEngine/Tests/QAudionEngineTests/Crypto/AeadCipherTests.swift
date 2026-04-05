import XCTest
@testable import QAudionEngine

final class AeadCipherTests: XCTestCase {
    func testEncryptDecryptRoundTrip() throws {
        let cipher = AeadCipher()
        let key = Data(repeating: 0x42, count: 32)
        let plaintext = Data("Hello Q-Audion!".utf8)
        let output = try cipher.encrypt(plaintext: plaintext, key: key)
        XCTAssertEqual(output.nonce.count, CryptoConstants.nonceSize)
        XCTAssertEqual(output.tag.count, CryptoConstants.tagSize)
        XCTAssertEqual(output.ciphertext.count, plaintext.count)
        XCTAssertNotEqual(output.ciphertext, plaintext)
        let decrypted = try cipher.decrypt(cipherOutput: output, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }
    func testDecryptWithWrongKey() {
        let cipher = AeadCipher()
        let output = try! cipher.encrypt(plaintext: Data("Secret".utf8), key: Data(repeating: 0x42, count: 32))
        XCTAssertThrowsError(try cipher.decrypt(cipherOutput: output, key: Data(repeating: 0x43, count: 32)))
    }
    func testDecryptWithTamperedCiphertext() {
        let cipher = AeadCipher()
        var output = try! cipher.encrypt(plaintext: Data("Audio".utf8), key: Data(repeating: 0x42, count: 32))
        var tampered = output.ciphertext; tampered[0] ^= 0xFF
        output = AeadCipher.CipherOutput(nonce: output.nonce, ciphertext: tampered, tag: output.tag)
        XCTAssertThrowsError(try cipher.decrypt(cipherOutput: output, key: Data(repeating: 0x42, count: 32)))
    }
    func testInvalidKeySize() {
        XCTAssertThrowsError(try AeadCipher().encrypt(plaintext: Data([0x01]), key: Data(repeating: 0x42, count: 16)))
    }
    func testAssociatedData() throws {
        let cipher = AeadCipher()
        let key = Data(repeating: 0x42, count: 32)
        let output = try cipher.encrypt(plaintext: Data("Audio".utf8), key: key, associatedData: Data("header".utf8))
        let decrypted = try cipher.decrypt(cipherOutput: output, key: key, associatedData: Data("header".utf8))
        XCTAssertEqual(decrypted, Data("Audio".utf8))
        XCTAssertThrowsError(try cipher.decrypt(cipherOutput: output, key: key, associatedData: Data("wrong".utf8)))
    }
    func testEmptyPlaintext() throws {
        let cipher = AeadCipher()
        let output = try cipher.encrypt(plaintext: Data(), key: Data(repeating: 0x42, count: 32))
        XCTAssertEqual(try cipher.decrypt(cipherOutput: output, key: Data(repeating: 0x42, count: 32)), Data())
    }
}
