import CryptoKit
import XCTest
@testable import QAudionEngine

/// CL-5.10 — KAT guard tests for EarbudAckPopRelay.buildPopInputsFrame (FLAG-2).
///
/// FLAG-2 (FROZEN 2026-06-18): In the 82-byte PoP-INPUTS frame, offset +16 MUST hold
/// uuid16(txn_id), NOT uuid16(key_id). The SE binds the PoP to txn_id; using key_id
/// makes the PoP unverifiable server-side.
///
/// Frame layout (offsets are into the 82-byte blob including the 2-byte sentinel):
///   [0..2)   sentinel  0xFF 0xFF
///   [2..18)  +0  txn_id(16)
///   [18..34) +16 txn_id(16)  ← FLAG-2: NOT key_id
///   [34..66) +32 server_id(32)
///   [66..82) +64 server_nonce(16)
final class EarbudAckPopRelayKatTests: XCTestCase {

    // ─── Stub GATT proxy (no BLE) ─────────────────────────────────────────────

    private final class StubGatt: EarbudKeyGattProxy, @unchecked Sendable {
        var isConnected: Bool = false
        func startKeyImport(pkg: Data, popInputs: Data) async throws -> KeyImportOutcome { .err("stub") }
        func readAttestPop() async throws -> Data { Data(count: 32) }
    }

    // ─── Test fixtures ────────────────────────────────────────────────────────

    private let txnId  = "11111111-2222-3333-4444-555555555555"
    private let keyId  = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let nonce16 = Data((0x10..<0x20).map { UInt8($0) })  // 16B

    private let h = EarbudGattConstants.KEYIMPORT_FRAG_HEADER  // 2

    private func makeKey(
        txnId: String? = nil,
        serverNonce: String? = nil,
        keyId: String? = nil
    ) -> PendingKey {
        let effectiveTxnId    = txnId    ?? self.txnId
        let effectiveKeyId    = keyId    ?? self.keyId
        let effectiveNonce    = serverNonce ?? nonce16.base64EncodedString()
        return PendingKey(
            keyId: effectiveKeyId,
            keyName: "hw-test",
            fingerprint: "fp",
            encryptedPackage: Data(count: EarbudGattConstants.KEYIMPORT_PKG_LEN).base64EncodedString(),
            ephemeralPubkey: "",
            nonce: "",
            keyClass: "hw_only",
            txnId: effectiveTxnId,
            serverNonce: effectiveNonce,
            earbudId: "ear-1"
        )
    }

    private func relay() -> EarbudAckPopRelay {
        EarbudAckPopRelay(gatt: StubGatt())
    }

    // ─── FLAG-2: txn_id at +16, NOT key_id ───────────────────────────────────

    func testFlag2TxnIdAtOffset16NotKeyId() throws {
        // Ensure txnId ≠ keyId so they produce different uuid16 bytes
        XCTAssertNotEqual(txnId, keyId)

        guard let frame = relay().buildPopInputsFrame(key: makeKey()) else {
            XCTFail("buildPopInputsFrame returned nil"); return
        }

        let txn16  = try KmsTransport.uuid16(txnId)
        let kid16  = try KmsTransport.uuid16(keyId)

        let at16 = Data(frame[(h+16)..<(h+32)])
        XCTAssertEqual(txn16, at16, "FLAG-2: offset +16 must hold txn_id")
        XCTAssertNotEqual(kid16, at16, "FLAG-2: key_id must NOT appear at offset +16")
    }

    func testFlag2TxnIdAtOffset0AlsoTxnId() throws {
        guard let frame = relay().buildPopInputsFrame(key: makeKey()) else {
            XCTFail("buildPopInputsFrame returned nil"); return
        }
        let txn16 = try KmsTransport.uuid16(txnId)
        XCTAssertEqual(txn16, Data(frame[h..<(h+16)]), "+0 must hold txn_id")
    }

    func testFlag2BothTxnSlotsAreIdentical() throws {
        guard let frame = relay().buildPopInputsFrame(key: makeKey()) else {
            XCTFail("buildPopInputsFrame returned nil"); return
        }
        let slot0  = Data(frame[h..<(h+16)])
        let slot16 = Data(frame[(h+16)..<(h+32)])
        XCTAssertEqual(slot0, slot16, "two txn_id slots must be identical")
    }

    // ─── Full frame structure pin ──────────────────────────────────────────────

    func testFrameIs82Bytes() {
        guard let frame = relay().buildPopInputsFrame(key: makeKey()) else {
            XCTFail("buildPopInputsFrame returned nil"); return
        }
        XCTAssertEqual(EarbudGattConstants.KEYIMPORT_POP_FRAME_LEN, frame.count)
        XCTAssertEqual(82, frame.count)
    }

    func testSentinelIsFFFF() {
        guard let frame = relay().buildPopInputsFrame(key: makeKey()) else {
            XCTFail("buildPopInputsFrame returned nil"); return
        }
        XCTAssertEqual(0xFF, frame[0], "sentinel byte 0 must be 0xFF")
        XCTAssertEqual(0xFF, frame[1], "sentinel byte 1 must be 0xFF")
    }

    func testServerIdAt32() {
        guard let frame = relay().buildPopInputsFrame(key: makeKey()) else {
            XCTFail("buildPopInputsFrame returned nil"); return
        }
        let serverId = KmsServerIdentity.serverIdBytes
        XCTAssertEqual(32, serverId.count, "server_id must be 32B")
        let at32 = Data(frame[(h+32)..<(h+64)])
        XCTAssertEqual(serverId, at32, "+32 must hold KmsServerIdentity.serverIdBytes")
    }

    func testServerNonceAt64() {
        guard let frame = relay().buildPopInputsFrame(key: makeKey()) else {
            XCTFail("buildPopInputsFrame returned nil"); return
        }
        let at64 = Data(frame[(h+64)..<(h+80)])
        XCTAssertEqual(nonce16, at64, "+64 must hold server_nonce")
    }

    func testServerIdIs32Bytes() {
        XCTAssertEqual(32, KmsServerIdentity.serverIdBytes.count)
    }

    /// Pin the expected server_id hex so any label typo is caught cross-platform.
    func testServerIdKnownVector() {
        let expected = Data([
            0x94, 0xb4, 0x00, 0x0e, 0x40, 0xb5, 0xa7, 0x16,
            0xd3, 0xd8, 0x06, 0xbb, 0x79, 0xc5, 0x0f, 0x29,
            0x04, 0xa4, 0xc8, 0xd8, 0xfd, 0xc5, 0xf4, 0x29,
            0x38, 0x3d, 0x10, 0x5f, 0x61, 0x99, 0x7a, 0x7e
        ])
        XCTAssertEqual(expected, KmsServerIdentity.serverIdBytes,
                       "server_id KAT vector mismatch — label changed?")
    }

    // ─── Nil guard conditions ──────────────────────────────────────────────────

    func testNilWhenTxnIdMissing() {
        let noTxn = PendingKey(
            keyId: keyId, keyName: "hw", fingerprint: "fp",
            encryptedPackage: Data(count: EarbudGattConstants.KEYIMPORT_PKG_LEN).base64EncodedString(),
            ephemeralPubkey: "", nonce: "",
            keyClass: "hw_only",
            txnId: nil,
            serverNonce: nonce16.base64EncodedString(),
            earbudId: "ear-1"
        )
        XCTAssertNil(relay().buildPopInputsFrame(key: noTxn), "nil txnId must return nil frame")
    }

    func testNilWhenTxnIdEmpty() {
        let key = PendingKey(
            keyId: keyId, keyName: "hw", fingerprint: "fp",
            encryptedPackage: Data(count: EarbudGattConstants.KEYIMPORT_PKG_LEN).base64EncodedString(),
            ephemeralPubkey: "", nonce: "",
            keyClass: "hw_only",
            txnId: "",
            serverNonce: nonce16.base64EncodedString(),
            earbudId: "ear-1"
        )
        XCTAssertNil(relay().buildPopInputsFrame(key: key), "empty txnId must return nil frame")
    }

    func testNilWhenTxnIdMalformed() {
        let key = PendingKey(
            keyId: keyId, keyName: "hw", fingerprint: "fp",
            encryptedPackage: Data(count: EarbudGattConstants.KEYIMPORT_PKG_LEN).base64EncodedString(),
            ephemeralPubkey: "", nonce: "",
            keyClass: "hw_only",
            txnId: "not-a-uuid",
            serverNonce: nonce16.base64EncodedString(),
            earbudId: "ear-1"
        )
        XCTAssertNil(relay().buildPopInputsFrame(key: key), "malformed txnId must return nil frame")
    }

    func testNilWhenServerNonceMissing() {
        let key = PendingKey(
            keyId: keyId, keyName: "hw", fingerprint: "fp",
            encryptedPackage: Data(count: EarbudGattConstants.KEYIMPORT_PKG_LEN).base64EncodedString(),
            ephemeralPubkey: "", nonce: "",
            keyClass: "hw_only",
            txnId: txnId,
            serverNonce: nil,
            earbudId: "ear-1"
        )
        XCTAssertNil(relay().buildPopInputsFrame(key: key), "nil serverNonce must return nil frame")
    }

    func testNilWhenServerNonceWrongLength() {
        // 15B nonce (not 16) → nil
        let short = Data(count: 15).base64EncodedString()
        let key = PendingKey(
            keyId: keyId, keyName: "hw", fingerprint: "fp",
            encryptedPackage: Data(count: EarbudGattConstants.KEYIMPORT_PKG_LEN).base64EncodedString(),
            ephemeralPubkey: "", nonce: "",
            keyClass: "hw_only",
            txnId: txnId,
            serverNonce: short,
            earbudId: "ear-1"
        )
        XCTAssertNil(relay().buildPopInputsFrame(key: key), "15B nonce must return nil frame")
    }

    func testNilWhenServerNonceBadBase64() {
        let key = PendingKey(
            keyId: keyId, keyName: "hw", fingerprint: "fp",
            encryptedPackage: Data(count: EarbudGattConstants.KEYIMPORT_PKG_LEN).base64EncodedString(),
            ephemeralPubkey: "", nonce: "",
            keyClass: "hw_only",
            txnId: txnId,
            serverNonce: "not-valid-base64!!!",
            earbudId: "ear-1"
        )
        XCTAssertNil(relay().buildPopInputsFrame(key: key), "bad base64 nonce must return nil frame")
    }

    // ─── uuid16 helper (used by relay) ────────────────────────────────────────

    func testUuid16ProducesCorrectBytes() throws {
        // "11111111-2222-3333-4444-555555555555"
        // hex: 11111111222233334444555555555555
        let expected = Data([
            0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33,
            0x44, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55
        ])
        XCTAssertEqual(expected, try KmsTransport.uuid16(txnId))
    }

    func testUuid16RejectsMalformed() {
        XCTAssertThrowsError(try KmsTransport.uuid16("not-a-uuid"))
        XCTAssertThrowsError(try KmsTransport.uuid16(""))
        XCTAssertThrowsError(try KmsTransport.uuid16("11111111-2222-3333-4444-55555555555Z"))  // bad hex
    }
}
