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
        XCTAssertEqual(offer[4], 0x01) // type = OFFER (0x01)
        XCTAssertEqual(offer[5], 0x01) // version (0x01)
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
        XCTAssertEqual(accept[4], 0x02) // type = ACCEPT (0x02)
        XCTAssertEqual(accept[5], 0x01) // version (0x01)
    }

    // MARK: - Sovereign Identity Wire Format (must match Android)

    func testSovereignIdentityLinkRoundTrip() {
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://voip.bcrypto.com", displayName: "Test")

        // Export and re-import
        let link = manager.exportAsLink(identity)
        XCTAssertTrue(link.hasPrefix("qaudion://id/"))

        let parsed = manager.parseIdentityLink(link)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.encryptionPublic, identity.encryptionPublic)
        XCTAssertEqual(parsed?.signingPublic, identity.signingPublic)
        XCTAssertEqual(parsed?.serverUrl, "https://voip.bcrypto.com")
        XCTAssertEqual(parsed?.displayName, "Test")
    }

    func testSovereignIdentityQrRoundTrip() {
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://voip.bcrypto.com", displayName: nil)

        let qrData = manager.exportAsQrData(identity)
        // Wire format: [version:1][encPub:32][sigPub:32][serverUrlLen:2][serverUrl:N][nameLen:2][name:M]
        XCTAssertEqual(qrData[0], 0x01) // version must match Android
        XCTAssertGreaterThanOrEqual(qrData.count, 1 + 32 + 32 + 2)
    }

    func testSovereignIdentityKeychainPersistence() throws {
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://voip.bcrypto.com", displayName: "Persist")
        try manager.saveIdentity(identity)
        let loaded = manager.loadIdentity()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.userId, identity.userId)
        XCTAssertEqual(loaded?.serverUrl, identity.serverUrl)
        XCTAssertEqual(loaded?.encryptionPublic, identity.encryptionPublic)
        XCTAssertEqual(loaded?.signingPublic, identity.signingPublic)
    }

    func testSovereignChallengeSign() throws {
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://voip.bcrypto.com", displayName: nil)
        let challenge = Data(repeating: 0xAB, count: 32)
        let signature = try manager.signChallenge(challenge, identity: identity)
        XCTAssertEqual(signature.count, 64) // Ed25519 signature
        XCTAssertTrue(manager.verifySignature(publicKey: identity.signingPublic, challenge: challenge, signature: signature))
        // Wrong challenge must fail
        XCTAssertFalse(manager.verifySignature(publicKey: identity.signingPublic, challenge: Data(repeating: 0x00, count: 32), signature: signature))
    }

    // MARK: - Opaque Mailbox (must match Android)

    func testOpaqueMailboxIdDeterminism() {
        let secret = Data(repeating: 0xDE, count: 32)
        let id1 = OpaqueMailbox.deriveMailboxId(sharedSecret: secret)
        let id2 = OpaqueMailbox.deriveMailboxId(sharedSecret: secret)
        XCTAssertEqual(id1, id2, "Mailbox ID must be deterministic")
        XCTAssertEqual(id1.count, 64, "Mailbox ID must be 64 hex chars (32 bytes)")
    }

    func testOpaqueCallMailboxIdDeterminism() {
        let secret = Data(repeating: 0xAB, count: 32)
        let callId = "test-call-123"
        let id1 = OpaqueMailbox.deriveCallMailboxId(sharedSecret: secret, callId: callId)
        let id2 = OpaqueMailbox.deriveCallMailboxId(sharedSecret: secret, callId: callId)
        XCTAssertEqual(id1, id2, "Call mailbox ID must be deterministic")
        // Different callId -> different mailbox
        let id3 = OpaqueMailbox.deriveCallMailboxId(sharedSecret: secret, callId: "other-call")
        XCTAssertNotEqual(id1, id3)
    }

    func testOpaqueEnvelopeRoundTrip() throws {
        let sharedKey = Data(repeating: 0xCC, count: 32)
        let encrypted = try OpaqueMailbox.encryptEnvelope(
            sharedKey: sharedKey, senderId: "alice", recipientId: "bob",
            msgType: "offer", payload: Data("hello".utf8)
        )
        let decrypted = OpaqueMailbox.decryptEnvelope(sharedKey: sharedKey, encryptedEnvelope: encrypted)
        XCTAssertNotNil(decrypted)
        XCTAssertEqual(decrypted?.senderId, "alice")
        XCTAssertEqual(decrypted?.recipientId, "bob")
        XCTAssertEqual(decrypted?.msgType, "offer")
        // Safe: XCTAssertNotNil(decrypted) above already confirmed non-nil.
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(String(data: decrypted!.payload, encoding: .utf8), "hello")
    }

    func testOpaqueEnvelopeWrongKey() throws {
        let correctKey = Data(repeating: 0xCC, count: 32)
        let wrongKey = Data(repeating: 0xDD, count: 32)
        let encrypted = try OpaqueMailbox.encryptEnvelope(
            sharedKey: correctKey, senderId: "alice", recipientId: "bob",
            msgType: "offer", payload: Data("secret".utf8)
        )
        let decrypted = OpaqueMailbox.decryptEnvelope(sharedKey: wrongKey, encryptedEnvelope: encrypted)
        XCTAssertNil(decrypted, "Wrong key must fail decryption")
    }

    // MARK: - HKDF Params Must Match Server

    func testHkdfParamsMatchServer() {
        // These MUST match the server's ComplianceInfoResponse.HkdfParams exactly
        XCTAssertEqual(String(data: CryptoConstants.hkdfInfoChain, encoding: .utf8), "q-audion-frame-key")
        XCTAssertEqual(String(data: CryptoConstants.hkdfInfoRoot, encoding: .utf8), "q-audion-root-ratchet")
        XCTAssertEqual(String(data: CryptoConstants.hkdfInfoPskMix, encoding: .utf8), "q-audion-psk-mix")
        XCTAssertEqual(String(data: CryptoConstants.hkdfInfoNextChain, encoding: .utf8), "q-audion-next-chain")
    }
}
