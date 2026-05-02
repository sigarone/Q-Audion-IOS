import XCTest
import CryptoKit
@testable import QAudionEngine

/// W380 — consolidated cross-platform KAT regression gate.
///
/// One test class that exercises every wire-format / cipher / KDF
/// surface that has a pinned cross-platform vector. If ANY of these
/// fails, the iOS engine has drifted from Android / Desktop and
/// interop is silently broken. The test class fails LOUDLY rather
/// than per-feature so a regression is unmissable in CI.
///
/// Adding a new pinned vector here is preferred over scattering it
/// across feature-specific test files — keeps the cross-platform
/// contract surface enumerable in one place.
final class CrossPlatformKatTests: XCTestCase {

    // MARK: - SAS — pinned KAT (W338)

    func test_W338_SAS_pinnedKat_bookshelf_pupil_blockade() throws {
        // sessionKey = bytes(range(32))
        // expected: bookshelf, pupil, blockade, mural, drifter, snapshot
        let key = Data((0..<32).map { UInt8($0) })
        let sas = try ComputeSasUseCase.invoke(sessionKey: key)
        XCTAssertEqual(sas.words,
                       ["bookshelf", "pupil", "blockade", "mural", "drifter", "snapshot"],
                       "SAS KAT drift — engine now produces different words for the canonical vector. Fix the salt or info before changing this expectation.")
    }

    // MARK: - PgpSasWordList — fixed 256-entry list

    func test_W338_PgpSasWordList_size_andFirstLast() {
        XCTAssertEqual(PgpSasWordList.words.count, 256)
        XCTAssertEqual(PgpSasWordList.words.first, "aardvark")
        XCTAssertEqual(PgpSasWordList.words.last, "Zulu")
    }

    // MARK: - SasConstants — exact bytes

    func test_W338_SasConstants_bytes() {
        XCTAssertEqual(SasConstants.salt, "qaudion-sas-v1")
        XCTAssertEqual(SasConstants.infoWords, "sas-words-v1")
        XCTAssertEqual(SasConstants.infoDigits, "sas-digits-v1")
        XCTAssertEqual(SasConstants.saltBytes, Data("qaudion-sas-v1".utf8))
    }

    // MARK: - Wire format detection (W336)

    func test_W336_MessageWireFormat_detect() {
        XCTAssertEqual(MessageWireFormat.detect(Data([0xE3, 0x00])), .v3)
        XCTAssertEqual(MessageWireFormat.detect(Data([0xE2, 0x00])), .v2)
        XCTAssertEqual(MessageWireFormat.detect(Data([0x42, 0x00])), .v1)
        XCTAssertEqual(MessageWireFormat.detect(Data()), .v1)
    }

    // MARK: - GroupSenderKey wire (W340)

    func test_W340_GroupSenderKey_isGroupWire() {
        XCTAssertTrue(GroupSenderKey.isGroupWire(Data([0xE4, 0x01])))
        XCTAssertFalse(GroupSenderKey.isGroupWire(Data([0xE3, 0x01])))
    }

    func test_W340_GroupSenderKey_aadLayout() {
        let aad = GroupSenderKey.buildGroupAd(
            groupIdBytes: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            senderId: "alice",
            chainIdx: 42)
        XCTAssertEqual(String(data: aad, encoding: .utf8), "grp:deadbeef:alice:42")
    }

    // MARK: - WireRelayFrameCodec (W334)

    func test_W334_WireRelayFrameCodec_audioMux() {
        let frame = EncryptedFrame(
            sequenceNumber: 0x12345678,
            timestamp: 0,
            nonce: Data(repeating: 0xAA, count: 12),
            payload: Data([0xDE, 0xAD]),
            tag: Data(repeating: 0xCC, count: 16))
        let wire = WireRelayFrameCodec.encodeAudio(frame)
        XCTAssertEqual(wire[0], 0x01) // mux=AUDIO
        XCTAssertEqual(wire.count, 1 + 12 + 8 + 2 + 2 + 16)
    }

    // MARK: - PepperedPhoneHash (W343 byte form)

    func test_W343_PepperedPhoneHash_bytePepperShapeIsHex64() throws {
        let hash = try PepperedPhoneHash.hash(
            phone: "+39123456789",
            pepperBytes: Data(repeating: 0x42, count: 32))
        XCTAssertEqual(hash.count, 64)  // SHA-256 → 32 bytes → 64 hex
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for c in hash.unicodeScalars { XCTAssertTrue(hex.contains(c)) }
    }

    // MARK: - DeviceLinkingProtocol QR scheme (W344)

    func test_W344_DeviceLinkingProtocol_schemeAndUrlSafe() {
        let proto = DeviceLinkingProtocol()
        let qr = proto.generateLinkQr(
            userId: "user-123",
            devicePubKey: Data(repeating: 0xFF, count: 32))
        let uri = proto.encodeLinkQr(qr)
        XCTAssertTrue(uri.hasPrefix("qaudion://link/"))
        let payload = String(uri.dropFirst("qaudion://link/".count))
        XCTAssertFalse(payload.contains("+"))
        XCTAssertFalse(payload.contains("/"))
        XCTAssertFalse(payload.contains("="))
    }

    // MARK: - HKDF labels (cross-platform)

    func test_HKDF_labels_unchanged() {
        // These literal strings are the cross-platform contract.
        // Any drift = silent decryption mismatch — fail loudly.
        XCTAssertEqual(SasConstants.salt, "qaudion-sas-v1")
        XCTAssertEqual(SasConstants.infoWords, "sas-words-v1")
        // (Other labels are private; tests are end-to-end via the
        // pinned KAT vectors above.)
    }

    // MARK: - CanonicalCBOR (W336) — buildMessageAD layout

    func test_W336_CanonicalCBOR_buildMessageADLayout() {
        let bytes = CanonicalCbor.buildMessageAD(
            senderId: "alice",
            recipientId: "bob",
            clientMsgId: "msg-42")
        // 0xA4 (map(4)) + 4 entries sorted m,r,s,v
        XCTAssertEqual(bytes[0], 0xA4)
        // First key = "m" (1 byte)
        XCTAssertEqual(bytes[1], 0x61)
        XCTAssertEqual(bytes[2], 0x6D)
    }
}
