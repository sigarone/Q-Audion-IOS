import XCTest
import CryptoKit
@testable import QAudionEngine

final class MessageCryptoV2Tests: XCTestCase {

    func testIsV2WireDetect() {
        XCTAssertTrue(MessageCryptoV2.isV2Wire(Data([0xE2, 0x05])))
        XCTAssertFalse(MessageCryptoV2.isV2Wire(Data([0xE3, 0x05])))
        XCTAssertFalse(MessageCryptoV2.isV2Wire(Data()))
    }

    func testParseHappyPath() throws {
        let epoch = "epoch-1"
        let salt = Data(repeating: 0x11, count: 32)
        let nonce = Data(repeating: 0x22, count: 12)
        let ct = Data([0xAA, 0xBB])
        let tag = Data(repeating: 0xCC, count: 16)
        var wire = Data()
        wire.append(0xE2)
        wire.append(UInt8(epoch.utf8.count))
        wire.append(Data(epoch.utf8))
        wire.append(salt)
        wire.append(nonce)
        wire.append(ct)
        wire.append(tag)

        let parsed = try MessageCryptoV2.parse(wire)
        XCTAssertEqual(parsed.epoch, epoch)
        XCTAssertEqual(parsed.salt, salt)
        XCTAssertEqual(parsed.nonce, nonce)
        XCTAssertEqual(parsed.ciphertext, ct)
        XCTAssertEqual(parsed.tag, tag)
    }

    func testParseRejectsWrongMagic() {
        XCTAssertThrowsError(try MessageCryptoV2.parse(Data([0xE3, 0x01, 0x65])))
    }

    func testParseRejectsTruncated() {
        XCTAssertThrowsError(try MessageCryptoV2.parse(Data([0xE2, 0x05, 0x68, 0x69])))
    }

    func testRoundTripEncryptDecrypt() throws {
        // We don't have an in-engine v2 encrypt path on iOS, so we craft
        // a wire blob by hand using AES-GCM directly.
        let psk = Data(repeating: 0x77, count: 32)
        let epoch = "test-epoch"
        let salt = Data(repeating: 0x11, count: 32)
        let nonce = Data(repeating: 0x22, count: 12)
        let plaintext = Data("hello world".utf8)
        let aad = Data("msg:alice:bob:cmid".utf8)

        // Derive same key MessageCryptoV2 will derive on decode.
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk),
            salt: salt,
            info: Data("q-audion-msg-key".utf8),
            outputByteCount: 32
        )

        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(plaintext,
                                        using: key,
                                        nonce: aesNonce,
                                        authenticating: aad)

        // Build the v2 wire envelope.
        var wire = Data()
        wire.append(0xE2)
        wire.append(UInt8(epoch.utf8.count))
        wire.append(Data(epoch.utf8))
        wire.append(salt)
        wire.append(nonce)
        wire.append(sealed.ciphertext)
        wire.append(sealed.tag)

        let opened = MessageCryptoV2.decrypt(wire: wire, psk: psk, aad: aad)
        XCTAssertEqual(opened, plaintext)
    }

    func testWrongPskFailsAead() throws {
        let psk1 = Data(repeating: 0x77, count: 32)
        let psk2 = Data(repeating: 0x88, count: 32)
        let epoch = "e1"
        let salt = Data(repeating: 0x11, count: 32)
        let nonce = Data(repeating: 0x22, count: 12)
        let aad = Data("msg:a:b:m".utf8)
        let key1 = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk1),
            salt: salt,
            info: Data("q-audion-msg-key".utf8),
            outputByteCount: 32
        )
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(Data("x".utf8), using: key1, nonce: aesNonce, authenticating: aad)
        var wire = Data()
        wire.append(0xE2)
        wire.append(UInt8(epoch.utf8.count))
        wire.append(Data(epoch.utf8))
        wire.append(salt)
        wire.append(nonce)
        wire.append(sealed.ciphertext)
        wire.append(sealed.tag)

        XCTAssertNil(MessageCryptoV2.decrypt(wire: wire, psk: psk2, aad: aad))
    }
}
