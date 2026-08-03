import XCTest
import CryptoKit
@testable import QAudionEngine

/// SEC-WIREUNIFY (2026-08-03) — pins `FileAttachmentCipher` and
/// `FileAttachmentAnnounce` (the iOS side of the `qa_fa_announce:1`
/// cross-platform port) against REAL hex output captured from Android's
/// own running implementation via `FileAttachmentCrossPlatformKatGeneratorTest.kt`
/// (`qaudion-android-new/qaudion-engine/src/test/java/com/bcrypto/qaudion/
/// file/FileAttachmentCrossPlatformKatGeneratorTest.kt`, run
/// 2026-08-03T08:14:47Z). Every hex literal below was extracted verbatim
/// from that run's JUnit XML — not hand-derived — so a byte mismatch here
/// means the iOS port diverges from Android's actual wire behavior, not a
/// theoretical spec misread.
final class FileAttachmentCipherKatTests: XCTestCase {

    private func fromHex(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        return data
    }

    // MARK: - FileAttachmentCipher.sealChunk / openChunk

    private let contentKey = "0101010101010101010101010101010101010101010101010101010101010101"
    private let fileId = "02020202020202020202020202020202"
    private let senderId = "03030303030303030303030303030303"
    private let plaintextHex =
        "48656c6c6f2c20512d417564696f6e2063726f73732d706c6174666f726d2066696c65206174746163686d656e74204b415420766563746f7221"

    func test_sealChunk_chunk0_matchesAndroidKat() throws {
        let ck = fromHex(contentKey)
        let fid = fromHex(fileId)
        let sid = fromHex(senderId)
        let pt = fromHex(plaintextHex)
        XCTAssertEqual(ck.count, 32)
        XCTAssertEqual(fid.count, 16)
        XCTAssertEqual(sid.count, 16)
        XCTAssertEqual(pt.count, 58)

        let nonce = try FileAttachmentCipher.deriveNonce(contentKey: ck, fileId: fid, senderId: sid, chunkIdx: 0)
        XCTAssertEqual(nonce, fromHex("c3f2718c7667f146ec1662239819d125ae748dcb52fbefa9"))

        let aad = try FileAttachmentCipher.buildAad(fileId: fid, senderId: sid, chunkIdx: 0, totalChunks: 2)
        XCTAssertEqual(
            aad,
            fromHex("71617564696f6e2d66612d76317c02020202020202020202020202020202030303030303030303030303030303030000000000000002")
        )

        let ct = try FileAttachmentCipher.sealChunk(
            contentKey: ck, fileId: fid, senderId: sid, chunkIdx: 0, totalChunks: 2, plaintext: pt)
        XCTAssertEqual(
            ct,
            fromHex("0e9b0e1b49ca33eb629cc9326504de2c4a508bc1acaecfe9e315420248cf51d527896704d423a0b71405bfa08f9f0e57a9bc34c6b92dcc2a04d7e535e2acac8bfa6128cd27b544fbf993")
        )

        let opened = try FileAttachmentCipher.openChunk(
            contentKey: ck, fileId: fid, senderId: sid, chunkIdx: 0, totalChunks: 2, ciphertext: ct)
        XCTAssertEqual(opened, pt)
    }

    func test_sealChunk_chunk1_matchesAndroidKat() throws {
        let ck = fromHex(contentKey)
        let fid = fromHex(fileId)
        let sid = fromHex(senderId)
        let pt = fromHex(plaintextHex)

        let nonce = try FileAttachmentCipher.deriveNonce(contentKey: ck, fileId: fid, senderId: sid, chunkIdx: 1)
        XCTAssertEqual(nonce, fromHex("156e9ef37b72eb918de1050d30d9b7895eb467beb1ca2bea"))

        let aad = try FileAttachmentCipher.buildAad(fileId: fid, senderId: sid, chunkIdx: 1, totalChunks: 2)
        XCTAssertEqual(
            aad,
            fromHex("71617564696f6e2d66612d76317c02020202020202020202020202020202030303030303030303030303030303030000000100000002")
        )

        let ct = try FileAttachmentCipher.sealChunk(
            contentKey: ck, fileId: fid, senderId: sid, chunkIdx: 1, totalChunks: 2, plaintext: pt)
        XCTAssertEqual(
            ct,
            fromHex("83218a58a1b06555c36eab36fd1c7137cdab224e6b45d80bd7bcf849bbf7f3e62c78670a30cf7896471285e267e2ac577b83da1a60221cf4ffcaea3c05ee3b08cc091e850c2ce35c6941")
        )

        let opened = try FileAttachmentCipher.openChunk(
            contentKey: ck, fileId: fid, senderId: sid, chunkIdx: 1, totalChunks: 2, ciphertext: ct)
        XCTAssertEqual(opened, pt)
    }

    /// Cross-protocol confusion defence: a ciphertext sealed by the OLDER
    /// `AttachmentEncryption` (`qa_ctl:1`) pipeline must NOT verify against
    /// `FileAttachmentCipher.openChunk`, and vice versa — the two AAD
    /// prefixes (`q-audion-attachment-aead-v1` vs `qaudion-fa-v1|`) must
    /// stay disjoint.
    func test_crossProtocolConfusion_rejected() throws {
        let ck = fromHex(contentKey)
        let fid = fromHex(fileId)
        let sid = fromHex(senderId)
        let pt = fromHex(plaintextHex)
        let faCiphertext = try FileAttachmentCipher.sealChunk(
            contentKey: ck, fileId: fid, senderId: sid, chunkIdx: 0, totalChunks: 2, plaintext: pt)

        // Attempt to open a file-attachment ciphertext as chunkIdx=1 (wrong
        // AAD binding) must fail closed.
        XCTAssertThrowsError(
            try FileAttachmentCipher.openChunk(
                contentKey: ck, fileId: fid, senderId: sid, chunkIdx: 1, totalChunks: 2, ciphertext: faCiphertext)
        )
    }

    // MARK: - FileAttachmentAnnounce.seal / deriveWrapKey

    func test_deriveWrapKey_and_ecdh_matchAndroidKat() throws {
        let ephPrivSeed = fromHex("1111111111111111111111111111111111111111111111111111111111111111")
        let recipientPrivSeed = fromHex("2222222222222222222222222222222222222222222222222222222222222222")
        let deviceId = fromHex("04040404040404040404040404040404")
        let faContentKey = fromHex("0505050505050505050505050505050505050505050505050505050505050505")
        let fid = fromHex(fileId)
        let sid = fromHex(senderId)

        let ephPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephPrivSeed)
        XCTAssertEqual(
            Data(ephPriv.publicKey.rawRepresentation),
            fromHex("7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13"),
            "ephPub must match Android's BouncyCastle-derived X25519 public key from the same raw seed"
        )

        let recipientPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientPrivSeed)
        XCTAssertEqual(
            Data(recipientPriv.publicKey.rawRepresentation),
            fromHex("0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20"),
            "recipientPub must match Android's BouncyCastle-derived X25519 public key from the same raw seed"
        )

        let shared = try ephPriv.sharedSecretFromKeyAgreement(with: recipientPriv.publicKey)
        let sharedRaw = shared.withUnsafeBytes { Data($0) }
        XCTAssertEqual(
            sharedRaw,
            fromHex("9e004098efc091d4ec2663b4e9f5cfd4d7064571690b4bea97ab146ab9f35056"),
            "raw X25519 ECDH output must match Android's BouncyCastle X25519Agreement result"
        )

        let wrapKey = FileAttachmentAnnounce.deriveWrapKey(
            sharedSecret: sharedRaw, fileId: fid, senderId: sid, recipientDeviceId: deviceId)
        XCTAssertEqual(
            wrapKey,
            fromHex("b2169ce32001cb746c3cac4024e8aac676afe473556b4efdc8581013b333fd03")
        )

        // seal() mints its own fresh ephemeral key (by design — matches
        // Android, see FileAttachmentAnnounce.kt's own KAT-generator
        // rationale), so only the round-trip is asserted here, not a fixed
        // ciphertext.
        let recipient = try FileAttachmentAnnounce.RecipientDevice(
            deviceId: deviceId, identityPub: Data(recipientPriv.publicKey.rawRepresentation))
        let sealed = try FileAttachmentAnnounce.seal(
            contentKey: faContentKey, fileId: fid, senderId: sid, recipientDevices: [recipient])
        XCTAssertEqual(sealed.wraps.count, 1)
        let opened = try FileAttachmentAnnounce.open(
            myIdentityPriv: recipientPrivSeed,
            senderEphPub: sealed.senderEphPub,
            fileId: fid,
            senderId: sid,
            myDeviceId: deviceId,
            wrappedContentKey: sealed.wraps[0].wrappedContentKey
        )
        XCTAssertEqual(opened, faContentKey)
    }

    /// Wrong device id must fail the AEAD wrap open (wrong AAD binding).
    func test_open_wrongDeviceId_fails() throws {
        let recipientPrivSeed = fromHex("2222222222222222222222222222222222222222222222222222222222222222")
        let deviceId = fromHex("04040404040404040404040404040404")
        let wrongDeviceId = fromHex("06060606060606060606060606060606")
        let faContentKey = fromHex("0505050505050505050505050505050505050505050505050505050505050505")
        let fid = fromHex(fileId)
        let sid = fromHex(senderId)

        let recipientPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: recipientPrivSeed)
        let recipient = try FileAttachmentAnnounce.RecipientDevice(
            deviceId: deviceId, identityPub: Data(recipientPriv.publicKey.rawRepresentation))
        let sealed = try FileAttachmentAnnounce.seal(
            contentKey: faContentKey, fileId: fid, senderId: sid, recipientDevices: [recipient])

        XCTAssertThrowsError(
            try FileAttachmentAnnounce.open(
                myIdentityPriv: recipientPrivSeed,
                senderEphPub: sealed.senderEphPub,
                fileId: fid,
                senderId: sid,
                myDeviceId: wrongDeviceId,
                wrappedContentKey: sealed.wraps[0].wrappedContentKey
            )
        )
    }
}
