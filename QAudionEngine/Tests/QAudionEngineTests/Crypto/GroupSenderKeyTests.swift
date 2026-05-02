import XCTest
@testable import QAudionEngine

final class GroupSenderKeyTests: XCTestCase {

    // MARK: - Wire round trip

    func testPackUnpackRoundTrip() throws {
        let groupId = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let nonce = Data(repeating: 0x42, count: 12)
        let ctWithTag = Data(repeating: 0xAB, count: 8) + Data(repeating: 0xCC, count: 16)

        let wire = try GroupSenderKey.packGroupWire(
            groupIdBytes: groupId,
            groupEpoch: 7,
            senderId: "alice",
            chainIdx: 0xCAFEBABE,
            nonce: nonce,
            ciphertextWithTag: ctWithTag
        )

        XCTAssertEqual(wire[0], 0xE4) // magic
        let parsed = try GroupSenderKey.unpackGroupWire(wire)
        XCTAssertEqual(parsed.groupId, groupId)
        XCTAssertEqual(parsed.groupEpoch, 7)
        XCTAssertEqual(parsed.senderId, "alice")
        XCTAssertEqual(parsed.chainIdx, 0xCAFEBABE)
        XCTAssertEqual(parsed.nonce, nonce)
        XCTAssertEqual(parsed.ciphertext, Data(repeating: 0xAB, count: 8))
        XCTAssertEqual(parsed.tag, Data(repeating: 0xCC, count: 16))
    }

    func testIsGroupWire() {
        XCTAssertTrue(GroupSenderKey.isGroupWire(Data([0xE4, 0x01, 0x00])))
        XCTAssertFalse(GroupSenderKey.isGroupWire(Data([0xE3, 0x01, 0x00])))
        XCTAssertFalse(GroupSenderKey.isGroupWire(Data()))
    }

    // MARK: - HKDF derivations

    func testDeriveInitChainKey() throws {
        let seed = Data(repeating: 0x77, count: 32)
        let groupId = Data([0x01, 0x02, 0x03])
        let ck0 = try GroupSenderKey.deriveInitChainKey(skSeed: seed, groupIdBytes: groupId, senderId: "alice")
        XCTAssertEqual(ck0.count, 32)
        // Different sender → different ck0.
        let ck0Bob = try GroupSenderKey.deriveInitChainKey(skSeed: seed, groupIdBytes: groupId, senderId: "bob")
        XCTAssertNotEqual(ck0, ck0Bob)
    }

    func testDeriveInitChainKeyRejectsWrongSeedLength() {
        let badSeed = Data(repeating: 0x77, count: 16)
        XCTAssertThrowsError(try GroupSenderKey.deriveInitChainKey(
            skSeed: badSeed, groupIdBytes: Data([0x01]), senderId: "alice"))
    }

    func testDeriveMsgKeysProducesDistinctKeyAndNonce() {
        let ck = Data(repeating: 0x99, count: 32)
        let (mk, nc) = GroupSenderKey.deriveMsgKeys(ck: ck)
        XCTAssertEqual(mk.count, 32)
        XCTAssertEqual(nc.count, 12)
        // The two outputs use different `info` strings — they MUST differ
        // even with same IKM/salt.
        XCTAssertNotEqual(mk.prefix(12), nc.prefix(12))
    }

    func testStepChainAdvances() {
        let ck0 = Data(repeating: 0x55, count: 32)
        let ck1 = GroupSenderKey.stepChain(ck: ck0)
        XCTAssertEqual(ck1.count, 32)
        XCTAssertNotEqual(ck0, ck1)
    }

    // MARK: - AAD

    func testBuildGroupAdLayout() {
        let groupId = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let aad = GroupSenderKey.buildGroupAd(
            groupIdBytes: groupId, senderId: "alice", chainIdx: 42)
        // utf8("grp:deadbeef:alice:42")
        XCTAssertEqual(String(data: aad, encoding: .utf8),
                       "grp:deadbeef:alice:42")
    }

    func testBuildGroupAdUsesLowercaseHex() {
        let groupId = Data([0xff, 0x00, 0x10, 0xaa])
        let aad = GroupSenderKey.buildGroupAd(
            groupIdBytes: groupId, senderId: "x", chainIdx: 0)
        XCTAssertEqual(String(data: aad, encoding: .utf8), "grp:ff0010aa:x:0")
    }

    // MARK: - AEAD round trip

    func testAesGcmEncryptDecryptRoundTrip() throws {
        let key = Data(repeating: 0x12, count: 32)
        let nonce = Data(repeating: 0x34, count: 12)
        let aad = Data("grp:test:alice:1".utf8)
        let plaintext = Data("hello group".utf8)

        let ctWithTag = try GroupSenderKey.aesGcmEncrypt(
            key: key, nonce: nonce, plaintext: plaintext, aad: aad)
        XCTAssertEqual(ctWithTag.count, plaintext.count + GroupSenderKey.tagLen)

        let decrypted = try GroupSenderKey.aesGcmDecrypt(
            key: key, nonce: nonce, ciphertextWithTag: ctWithTag, aad: aad)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testAesGcmAadMismatchFails() throws {
        let key = Data(repeating: 0x12, count: 32)
        let nonce = Data(repeating: 0x34, count: 12)
        let goodAad = Data("grp:abc:alice:1".utf8)
        let wrongAad = Data("grp:abc:alice:2".utf8)
        let ct = try GroupSenderKey.aesGcmEncrypt(
            key: key, nonce: nonce, plaintext: Data("x".utf8), aad: goodAad)
        XCTAssertThrowsError(try GroupSenderKey.aesGcmDecrypt(
            key: key, nonce: nonce, ciphertextWithTag: ct, aad: wrongAad))
    }

    // MARK: - Hex helpers

    func testToHexLowercase() {
        XCTAssertEqual(GroupSenderKey.toHex(Data([0xDE, 0xAD, 0xBE, 0xEF])), "deadbeef")
        XCTAssertEqual(GroupSenderKey.toHex(Data([0x00, 0x01, 0x10, 0xFF])), "000110ff")
        XCTAssertEqual(GroupSenderKey.toHex(Data()), "")
    }

    func testFromHexRoundTrip() throws {
        XCTAssertEqual(try GroupSenderKey.fromHex("deadbeef"), Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(try GroupSenderKey.fromHex("DEADBEEF"), Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(try GroupSenderKey.fromHex(""), Data())
    }

    func testFromHexRejectsOdd() {
        XCTAssertThrowsError(try GroupSenderKey.fromHex("abc"))
    }

    // MARK: - End-to-end mini scenario

    func testSenderEncryptReceiverDecryptOnce() throws {
        // Both peers bootstrap from the same SK_seed; lex on the wire
        // means sender role decides who packs.
        let seed = Data(repeating: 0xAA, count: 32)
        let groupId = Data([0xDE, 0xAD])
        let senderId = "alice"

        // Sender side: derive CK_0, then (msg_key, nonce), AAD, AEAD seal.
        let ck0 = try GroupSenderKey.deriveInitChainKey(
            skSeed: seed, groupIdBytes: groupId, senderId: senderId)
        let (msgKey, nonce) = GroupSenderKey.deriveMsgKeys(ck: ck0)
        let chainIdx: UInt64 = 0
        let aad = GroupSenderKey.buildGroupAd(
            groupIdBytes: groupId, senderId: senderId, chainIdx: chainIdx)
        let plaintext = Data("hi group".utf8)
        let ctWithTag = try GroupSenderKey.aesGcmEncrypt(
            key: msgKey, nonce: nonce, plaintext: plaintext, aad: aad)
        let wire = try GroupSenderKey.packGroupWire(
            groupIdBytes: groupId,
            groupEpoch: 1,
            senderId: senderId,
            chainIdx: chainIdx,
            nonce: nonce,
            ciphertextWithTag: ctWithTag
        )

        // Receiver side: parse wire, reconstruct the same CK_0 from seed,
        // derive (msg_key, nonce), build same AAD, AEAD open.
        let parsed = try GroupSenderKey.unpackGroupWire(wire)
        XCTAssertEqual(parsed.senderId, senderId)
        XCTAssertEqual(parsed.chainIdx, chainIdx)

        let recvCk0 = try GroupSenderKey.deriveInitChainKey(
            skSeed: seed, groupIdBytes: parsed.groupId, senderId: parsed.senderId)
        let (rk, rn) = GroupSenderKey.deriveMsgKeys(ck: recvCk0)
        XCTAssertEqual(rn, parsed.nonce, "deterministic nonce must match wire")
        let recvAad = GroupSenderKey.buildGroupAd(
            groupIdBytes: parsed.groupId, senderId: parsed.senderId, chainIdx: parsed.chainIdx)
        let decrypted = try GroupSenderKey.aesGcmDecrypt(
            key: rk, nonce: rn,
            ciphertextWithTag: parsed.ciphertext + parsed.tag,
            aad: recvAad
        )
        XCTAssertEqual(decrypted, plaintext)
    }
}
