import XCTest
@testable import QAudionEngine

final class CrossPlatformTestVectors: XCTestCase {

    // MARK: - Padding Vectors

    func testPaddingVectors() {
        let padding = AdaptivePadding(targetFrameSize: 256)
        // Vector 1: small payload -> 256 bytes
        let payload1 = Data(repeating: 0x00, count: 10)
        let padded1 = padding.pad(encryptedPayload: payload1, confidenceScore: 1.0)
        XCTAssertEqual(padded1.count, 256)
        let high1 = Int(padded1[padded1.count - 2])
        let low1 = Int(padded1[padded1.count - 1])
        XCTAssertEqual((high1 << 8) | low1, 244)

        // Vector 2: large payload -> payload + 2
        let payload2 = Data(repeating: 0xFF, count: 255)
        let padded2 = padding.pad(encryptedPayload: payload2, confidenceScore: 1.0)
        XCTAssertEqual(padded2.count, 257)
        let high2 = Int(padded2[padded2.count - 2])
        let low2 = Int(padded2[padded2.count - 1])
        XCTAssertEqual((high2 << 8) | low2, 0)
    }

    // MARK: - Frame Wire Format

    func testFrameEncoderWireFormatMatch() {
        let frame = EncryptedFrame(
            flags: 0x00,
            sequenceNumber: 42,
            timestamp: 1234567890,
            nonce: Data(repeating: 0xAB, count: 12),
            payload: Data([0x01, 0x02, 0x03, 0x04, 0x05]),
            tag: Data(repeating: 0xCD, count: 16)
        )
        let wire = FrameEncoder.serialize(frame)

        // Verify byte positions (big-endian, must match Android)
        XCTAssertEqual(wire[0], 0x01)  // version
        XCTAssertEqual(wire[1], 0x00)  // flags
        // seqNum=42 -> 0x0000002A
        XCTAssertEqual(wire[2], 0x00)
        XCTAssertEqual(wire[3], 0x00)
        XCTAssertEqual(wire[4], 0x00)
        XCTAssertEqual(wire[5], 0x2A)
        // timestamp=1234567890 -> 0x00000000499602D2
        XCTAssertEqual(wire[6], 0x00)
        XCTAssertEqual(wire[7], 0x00)
        XCTAssertEqual(wire[8], 0x00)
        XCTAssertEqual(wire[9], 0x00)
        XCTAssertEqual(wire[10], 0x49)
        XCTAssertEqual(wire[11], 0x96)
        XCTAssertEqual(wire[12], 0x02)
        XCTAssertEqual(wire[13], 0xD2)
        // nonceLen=12
        XCTAssertEqual(wire[14], 0x0C)
        // payloadLen=5 -> 0x0005
        XCTAssertEqual(wire[27], 0x00)
        XCTAssertEqual(wire[28], 0x05)
    }

    // MARK: - HKDF Determinism (must match Android)

    func testDeterministicHkdf() throws {
        let secret = Data(repeating: 0xBE, count: 32)
        let sm1 = SessionManager()
        let state1 = try sm1.initSession(sharedSecret: Data(secret))
        let sm2 = SessionManager()
        let state2 = try sm2.initSession(sharedSecret: Data(secret))
        XCTAssertEqual(state1.rootKey, state2.rootKey, "Root keys must be deterministic")
        XCTAssertEqual(state1.chainKey, state2.chainKey, "Chain keys must be deterministic")
        let fk1 = try sm1.ratchet()
        let fk2 = try sm2.ratchet()
        XCTAssertEqual(fk1, fk2, "Frame keys must be deterministic")
    }

    func testHkdfWithPskDeterminism() throws {
        let secret = Data(repeating: 0xBB, count: 32)
        let psk = Data(repeating: 0xAA, count: 32)
        let sm1 = SessionManager()
        let state1 = try sm1.initSession(sharedSecret: secret, psk: psk)
        let sm2 = SessionManager()
        let state2 = try sm2.initSession(sharedSecret: secret, psk: psk)
        XCTAssertEqual(state1.rootKey, state2.rootKey, "PSK-mixed root keys must be deterministic")
        XCTAssertEqual(state1.chainKey, state2.chainKey, "PSK-mixed chain keys must be deterministic")
    }

    func testRatchetSequenceDeterminism() throws {
        let secret = Data(repeating: 0xCC, count: 32)
        let sm1 = SessionManager()
        _ = try sm1.initSession(sharedSecret: secret)
        let sm2 = SessionManager()
        _ = try sm2.initSession(sharedSecret: secret)

        // Ratchet 10 times and verify all frame keys match
        for i in 0..<10 {
            let fk1 = try sm1.ratchet()
            let fk2 = try sm2.ratchet()
            XCTAssertEqual(fk1, fk2, "Frame key \(i) must match across instances")
        }
    }

    // MARK: - AES-256-GCM Round-Trip

    func testAeadRoundTrip() throws {
        let key = Data((1...32).map { UInt8($0) })
        let plaintext = Data("Hello Q-Audion".utf8)
        let cipher = AeadCipher()
        let encrypted = try cipher.encrypt(plaintext: plaintext, key: key)
        XCTAssertEqual(encrypted.nonce.count, CryptoConstants.nonceSize)
        XCTAssertEqual(encrypted.tag.count, CryptoConstants.tagSize)
        XCTAssertNotEqual(encrypted.ciphertext, plaintext)
        let decrypted = try cipher.decrypt(cipherOutput: encrypted, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testAeadWithAssociatedData() throws {
        let key = Data(repeating: 0x42, count: 32)
        let plaintext = Data("Encrypted audio frame".utf8)
        let aad = Data("sequence:42".utf8)
        let cipher = AeadCipher()
        let encrypted = try cipher.encrypt(plaintext: plaintext, key: key, associatedData: aad)
        let decrypted = try cipher.decrypt(cipherOutput: encrypted, key: key, associatedData: aad)
        XCTAssertEqual(decrypted, plaintext)
        // Wrong AAD must fail
        XCTAssertThrowsError(try cipher.decrypt(cipherOutput: encrypted, key: key, associatedData: Data("wrong".utf8)))
    }

    // MARK: - Crypto Constants Match

    func testCryptoConstantsMatchAndroid() {
        XCTAssertEqual(CryptoConstants.mlKemAlgorithm, "ML-KEM-1024")
        XCTAssertEqual(CryptoConstants.aeadAlgorithm, "AES-256-GCM")
        XCTAssertEqual(CryptoConstants.keySizeBytes, 32)
        XCTAssertEqual(CryptoConstants.nonceSize, 12)
        XCTAssertEqual(CryptoConstants.tagSize, 16)
        XCTAssertEqual(CryptoConstants.ratchetIntervalFrames, 100)
        XCTAssertEqual(CryptoConstants.frameDurationMs, 20)
        XCTAssertEqual(CryptoConstants.sampleRate, 48000)
        XCTAssertEqual(CryptoConstants.samplesPerFrame, 960)
        XCTAssertEqual(String(data: CryptoConstants.hkdfInfoChain, encoding: .utf8), "q-audion-frame-key")
        XCTAssertEqual(String(data: CryptoConstants.hkdfInfoRoot, encoding: .utf8), "q-audion-root-ratchet")
        XCTAssertEqual(String(data: CryptoConstants.hkdfInfoPskMix, encoding: .utf8), "q-audion-psk-mix")
        XCTAssertEqual(String(data: CryptoConstants.hkdfInfoNextChain, encoding: .utf8), "q-audion-next-chain")
    }

    // MARK: - Capability Exchange QUAD Protocol

    func testQuadMagicBytes() {
        let offer = QAudionCapabilityExchange.createOffer(
            publicKey: Data(repeating: 0x01, count: 1568),
            pskFingerprints: []
        )
        // QUAD magic: 0x51 0x41 0x55 0x44
        XCTAssertEqual(offer[0], 0x51) // Q
        XCTAssertEqual(offer[1], 0x41) // A
        XCTAssertEqual(offer[2], 0x55) // U
        XCTAssertEqual(offer[3], 0x44) // D
        XCTAssertEqual(offer[4], 0x01) // version
        XCTAssertEqual(offer[5], 0x01) // type = OFFER
    }

    func testQuadAcceptFormat() {
        let accept = QAudionCapabilityExchange.createAccept(
            ciphertext: Data(repeating: 0x02, count: 1568),
            pskFingerprint: nil
        )
        XCTAssertEqual(accept[0], 0x51) // Q
        XCTAssertEqual(accept[1], 0x41) // A
        XCTAssertEqual(accept[2], 0x55) // U
        XCTAssertEqual(accept[3], 0x44) // D
        XCTAssertEqual(accept[4], 0x01) // version
        XCTAssertEqual(accept[5], 0x02) // type = ACCEPT
    }
}
