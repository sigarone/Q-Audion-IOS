import XCTest
import Foundation
@testable import QAudionEngine

final class AttachmentEncryptionTests: XCTestCase {

    private func makeMeta(byteLength: Int) throws -> AttachmentEncryption.Meta {
        return try AttachmentEncryption.Meta(
            attachmentId: Data(repeating: 0xAA, count: 16),
            senderUuid: Data(repeating: 0xBB, count: 16),
            mime: "audio/opus",
            byteLength: byteLength
        )
    }

    func testRoundTrip() throws {
        let chainKey = Data(repeating: 0x77, count: 32)
        let plaintext = Data("hello voice note".utf8)
        let meta = try makeMeta(byteLength: plaintext.count)
        let enc = try AttachmentEncryption.encryptAttachment(
            messageChainKey: chainKey, plaintext: plaintext, meta: meta)
        XCTAssertGreaterThan(enc.ciphertext.count, plaintext.count) // includes 16-byte tag
        XCTAssertEqual(enc.sha256Plain.count, 32)

        let dec = try AttachmentEncryption.decryptAttachment(
            messageChainKey: chainKey,
            ciphertext: enc.ciphertext,
            meta: meta,
            expectedSha256Plain: enc.sha256Plain
        )
        XCTAssertEqual(dec, plaintext)
    }

    func testWrongChainKeyFailsAead() throws {
        let chainA = Data(repeating: 0xAA, count: 32)
        let chainB = Data(repeating: 0xBB, count: 32)
        let pt = Data("x".utf8)
        let meta = try makeMeta(byteLength: pt.count)
        let enc = try AttachmentEncryption.encryptAttachment(
            messageChainKey: chainA, plaintext: pt, meta: meta)
        XCTAssertThrowsError(try AttachmentEncryption.decryptAttachment(
            messageChainKey: chainB,
            ciphertext: enc.ciphertext,
            meta: meta,
            expectedSha256Plain: enc.sha256Plain))
    }

    func testWrongAttachmentIdFails() throws {
        let chain = Data(repeating: 0x77, count: 32)
        let pt = Data("x".utf8)
        let meta = try makeMeta(byteLength: pt.count)
        let tampered = try AttachmentEncryption.Meta(
            attachmentId: Data(repeating: 0xCC, count: 16), // changed
            senderUuid: meta.senderUuid,
            mime: meta.mime,
            byteLength: meta.byteLength)
        let enc = try AttachmentEncryption.encryptAttachment(
            messageChainKey: chain, plaintext: pt, meta: meta)
        XCTAssertThrowsError(try AttachmentEncryption.decryptAttachment(
            messageChainKey: chain,
            ciphertext: enc.ciphertext,
            meta: tampered,
            expectedSha256Plain: enc.sha256Plain))
    }

    func testTamperedSha256Fails() throws {
        let chain = Data(repeating: 0x77, count: 32)
        let pt = Data("voice".utf8)
        let meta = try makeMeta(byteLength: pt.count)
        let enc = try AttachmentEncryption.encryptAttachment(
            messageChainKey: chain, plaintext: pt, meta: meta)
        var bogusSha = enc.sha256Plain
        bogusSha[bogusSha.startIndex] ^= 0xFF
        XCTAssertThrowsError(try AttachmentEncryption.decryptAttachment(
            messageChainKey: chain,
            ciphertext: enc.ciphertext,
            meta: meta,
            expectedSha256Plain: bogusSha))
    }

    func testLengthMismatchOnEncrypt() throws {
        let chain = Data(repeating: 0x77, count: 32)
        let pt = Data("five.".utf8) // 5 bytes
        let meta = try makeMeta(byteLength: 99)  // declares 99
        XCTAssertThrowsError(try AttachmentEncryption.encryptAttachment(
            messageChainKey: chain, plaintext: pt, meta: meta))
    }

    func testDeriveKeysDeterministic() throws {
        let chain = Data(repeating: 0x77, count: 32)
        let attId = Data(repeating: 0xAA, count: 16)
        let sender = Data(repeating: 0xBB, count: 16)
        let (k1, n1) = try AttachmentEncryption.deriveAttachmentKeys(
            messageChainKey: chain, attachmentId: attId, senderUuid: sender)
        let (k2, n2) = try AttachmentEncryption.deriveAttachmentKeys(
            messageChainKey: chain, attachmentId: attId, senderUuid: sender)
        XCTAssertEqual(k1, k2)
        XCTAssertEqual(n1, n2)
        XCTAssertEqual(k1.count, 32)
        XCTAssertEqual(n1.count, 24)
    }

    func testDifferentAttachmentIdProducesDifferentKey() throws {
        let chain = Data(repeating: 0x77, count: 32)
        let sender = Data(repeating: 0xBB, count: 16)
        let (k1, _) = try AttachmentEncryption.deriveAttachmentKeys(
            messageChainKey: chain,
            attachmentId: Data(repeating: 0x01, count: 16),
            senderUuid: sender)
        let (k2, _) = try AttachmentEncryption.deriveAttachmentKeys(
            messageChainKey: chain,
            attachmentId: Data(repeating: 0x02, count: 16),
            senderUuid: sender)
        XCTAssertNotEqual(k1, k2)
    }

    func testLargePayloadRoundTrip() throws {
        let chain = Data(repeating: 0x77, count: 32)
        let pt = Data((0..<200_000).map { UInt8($0 & 0xFF) })  // 200 KB
        let meta = try makeMeta(byteLength: pt.count)
        let enc = try AttachmentEncryption.encryptAttachment(
            messageChainKey: chain, plaintext: pt, meta: meta)
        let dec = try AttachmentEncryption.decryptAttachment(
            messageChainKey: chain,
            ciphertext: enc.ciphertext,
            meta: meta,
            expectedSha256Plain: enc.sha256Plain)
        XCTAssertEqual(dec, pt)
    }

    /// Shared cross-platform Known-Answer-Test vector — byte-identical with
    /// Android `AttachmentEncryptionKatTest.kt` and the Desktop reference
    /// `AttachmentEncryption.spec.ts`. This is the DURABLE proof that iOS
    /// seals/opens group + 1:1 attachment blobs byte-for-byte the same as the
    /// other two platforms (same HKDF-SHA256 labels, same canonical-CBOR AAD,
    /// same XChaCha20-Poly1305 construction, same ct||tag wire layout).
    ///
    /// The vector was independently recomputed from the WIRE_SPEC §5.1.3
    /// construction. If either assertion fails, one platform drifted — fix
    /// the drifted side, do NOT edit this vector on one platform only.
    func testCrossPlatformKAT() throws {
        let chainKey = Data(repeating: 0xAA, count: 32)
        let attId = Data(repeating: 0x11, count: 16)
        let sender = Data(repeating: 0xA1, count: 16)
        let plaintext = Data("voice note bytes go here".utf8)
        let meta = try AttachmentEncryption.Meta(
            attachmentId: attId, senderUuid: sender, mime: "audio/opus",
            byteLength: plaintext.count)

        let expectedCt =
            "36c9e852ab519ceedea88a24349219f277315a8f68a40ef3c01ae20fc6ac101d1485e26ffe0d3fb3"
        let expectedSha =
            "5141ddddddcd70cbb76bf1d3bc1ff76a8c6717b2bcfd16e95b11baa9dbb2815c"

        // Encrypt → must reproduce the frozen ciphertext + sha bit-for-bit.
        let enc = try AttachmentEncryption.encryptAttachment(
            messageChainKey: chainKey, plaintext: plaintext, meta: meta)
        XCTAssertEqual(Self.hex(enc.ciphertext), expectedCt,
                       "iOS ciphertext drifted from the shared cross-platform KAT")
        XCTAssertEqual(Self.hex(enc.sha256Plain), expectedSha)

        // Decrypt the Android/Desktop-emitted frozen ciphertext with the iOS impl.
        let recovered = try AttachmentEncryption.decryptAttachment(
            messageChainKey: chainKey,
            ciphertext: Self.unhex(expectedCt),
            meta: meta,
            expectedSha256Plain: Self.unhex(expectedSha))
        XCTAssertEqual(recovered, plaintext)
    }

    private static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    private static func unhex(_ s: String) -> Data {
        var out = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            // Only fed hardcoded even-length hex literals (frozen KAT vectors above).
            // swiftlint:disable:next force_unwrapping
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }
}
