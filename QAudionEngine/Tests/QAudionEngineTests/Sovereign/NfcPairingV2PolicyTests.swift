import XCTest
import CryptoKit
@testable import QAudionEngine

/// The identity policy of NFC pairing v2 on the verified identity block (docs/security/NFC_PAIRING_V2.md section 9):
/// warnings only, and the name of a known contact. Also the grammar of the identity block and the strict signature
/// verification.
final class NfcPairingV2PolicyTests: XCTestCase {

    private func peer(userId: String = "peer-account-01") throws -> NfcPairingV2Identity {
        try NfcPairingV2Identity(publicKey: Data(repeating: 0x42, count: 32), userId: userId)
    }

    func testNoPinsAndNoServerAnswerMeansNoWarning() throws {
        let result = NfcPairingV2Policy.assess(peer: try peer(), pinnedKeys: [], contactName: nil, serverCheck: .unavailable)
        XCTAssertNil(result.warning)
        XCTAssertFalse(result.peerKnown)
        XCTAssertFalse(result.pinned)
    }

    func testPinnedKeyThatMatchesIsQuietAndOneThatDiffersWarns() throws {
        let same = NfcPairingV2Policy.assess(peer: try peer(), pinnedKeys: [Data(repeating: 0x42, count: 32)],
                                             contactName: "Anna", serverCheck: .confirmed)
        XCTAssertNil(same.warning)
        XCTAssertTrue(same.pinned)
        XCTAssertTrue(same.peerKnown)
        XCTAssertEqual(same.contactName, "Anna")

        // Several pins (per-device pins): one match is enough.
        let several = NfcPairingV2Policy.assess(
            peer: try peer(), pinnedKeys: [Data(repeating: 1, count: 32), Data(repeating: 0x42, count: 32)],
            contactName: nil, serverCheck: .unavailable)
        XCTAssertNil(several.warning)

        let different = NfcPairingV2Policy.assess(peer: try peer(), pinnedKeys: [Data(repeating: 1, count: 32)],
                                                  contactName: nil, serverCheck: .unavailable)
        XCTAssertNotNil(different.warning)
    }

    func testAccountThatDoesNotPublishTheProvenKeyWarns() throws {
        let mismatch = NfcPairingV2Policy.assess(peer: try peer(), pinnedKeys: [], contactName: nil, serverCheck: .mismatch)
        XCTAssertNotNil(mismatch.warning)
        let both = NfcPairingV2Policy.assess(peer: try peer(), pinnedKeys: [Data(repeating: 1, count: 32)], contactName: nil,
                                             serverCheck: .mismatch)
        XCTAssertNotNil(both.warning)
        XCTAssertNotEqual(both.warning, mismatch.warning, "both reasons are on the screen")
    }

    private func contact(userId: String, name: String, pubkey: Data?) throws -> ContactsStore.StoredContact {
        var json: [String: Any] = ["userId": userId, "displayName": name, "phoneHash": "h", "isVerified": false]
        if let pubkey { json["pubkey"] = pubkey.base64EncodedString() }
        return try JSONDecoder().decode(ContactsStore.StoredContact.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testContactNameFromAClaimedAccountIdNeedsIndependentConfirmation() throws {
        let identity = try peer(userId: "peer-account-01")
        let known = try contact(userId: "peer-account-01", name: "Anna", pubkey: nil)
        // The id is the peer's own claim: not enough on its own.
        XCTAssertNil(NfcPairingV2Policy.contactName(for: identity, contacts: [known]))
        XCTAssertNil(NfcPairingV2Policy.contactName(for: identity, contacts: [known], pinnedKeys: [Data(repeating: 1, count: 32)],
                                                    serverCheck: .mismatch))
        XCTAssertNil(NfcPairingV2Policy.contactName(for: identity, contacts: [known], serverCheck: .unavailable))
        // A pin of that account equal to the proven key, or the account's published keys, confirm it.
        XCTAssertEqual(NfcPairingV2Policy.contactName(for: identity, contacts: [known], pinnedKeys: [identity.publicKey]), "Anna")
        XCTAssertEqual(NfcPairingV2Policy.contactName(for: identity, contacts: [known], serverCheck: .confirmed), "Anna")
        // The contact that holds the same key is named without further proof.
        let byKey = try contact(userId: "other", name: "Bruno", pubkey: identity.publicKey)
        XCTAssertEqual(NfcPairingV2Policy.contactName(for: identity, contacts: [known, byKey]), "Bruno")
    }

    func testServerVerdict() {
        let key = Data(repeating: 7, count: 32)
        XCTAssertEqual(NfcPairingV2Policy.serverVerdict(published: [], presented: key), .unavailable)
        XCTAssertEqual(NfcPairingV2Policy.serverVerdict(published: [key], presented: key), .confirmed)
        XCTAssertEqual(NfcPairingV2Policy.serverVerdict(published: [Data(repeating: 8, count: 32)], presented: key), .mismatch)
    }

    func testIdentityBlockGrammar() throws {
        let key = Data(repeating: 3, count: 32)
        XCTAssertEqual(try NfcPairingV2Identity(publicKey: key, userId: "").block.count, 33, "n = 0: no account id")
        XCTAssertEqual(try NfcPairingV2Identity(publicKey: key, userId: String(repeating: "a", count: 64)).block.count, 97)
        XCTAssertThrowsError(try NfcPairingV2Identity(publicKey: key, userId: String(repeating: "a", count: 65))) {
            XCTAssertEqual(($0 as? NfcPairingV2Failure)?.token, .length)
        }
        for bad in ["ab|cd", "ab cd", "caf\u{e9}", "a\u{0}b", "a/b"] {
            XCTAssertThrowsError(try NfcPairingV2Identity(publicKey: key, userId: bad), bad) {
                XCTAssertEqual(($0 as? NfcPairingV2Failure)?.token, .userId)
            }
        }
        XCTAssertThrowsError(try NfcPairingV2Identity(publicKey: Data(count: 31), userId: "a"))
    }

    func testIdentityBlockParserChecksLengthsAndTrailingBytes() throws {
        let key = Data(repeating: 3, count: 32)
        let identity = try NfcPairingV2Identity(publicKey: key, userId: "abc.DEF_1-2")
        let parsed = try NfcPairingV2Crypto.parseIdentityBlock(identity.block + Data([1, 2, 3]))
        XCTAssertEqual(parsed.identity, identity)
        XCTAssertEqual(parsed.rest, Data([1, 2, 3]))
        XCTAssertThrowsError(try NfcPairingV2Crypto.parseIdentityBlock(Data(count: 32)))
        XCTAssertThrowsError(try NfcPairingV2Crypto.parseIdentityBlock(key + Data([5, 0x61])))
        XCTAssertThrowsError(try NfcPairingV2Crypto.parseIdentityBlock(key + Data([65]) + Data(repeating: 0x61, count: 65)))
    }

    func testSignatureVerificationIsStrict() throws {
        let seed = Data(repeating: 11, count: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let payload = Data("payload".utf8)
        let signature = try ProximityPairingCrypto.sign(payload, signingPrivateKey: seed)
        XCTAssertTrue(NfcPairingV2Crypto.verifySignature(signature, payload: payload, publicKey: key))
        // A flipped bit anywhere fails.
        var broken = signature
        broken[3] ^= 1
        XCTAssertFalse(NfcPairingV2Crypto.verifySignature(broken, payload: payload, publicKey: key))
        // S >= l (here: S replaced by l itself, and by 0xFF..FF) is refused before the library is asked.
        let order = Data([0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
                          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10])
        XCTAssertFalse(NfcPairingV2Crypto.verifySignature(Data(signature.prefix(32)) + order, payload: payload, publicKey: key))
        XCTAssertFalse(NfcPairingV2Crypto.verifySignature(Data(signature.prefix(32)) + Data(repeating: 0xFF, count: 32),
                                                          payload: payload, publicKey: key))
        // An all-zero signature under a small-order key.
        let neutral = Data([1] + [UInt8](repeating: 0, count: 31))
        XCTAssertFalse(NfcPairingV2Crypto.verifySignature(neutral + Data(count: 32), payload: payload, publicKey: neutral))
        // R of small order (the neutral element) is refused.
        XCTAssertFalse(NfcPairingV2Crypto.verifySignature(neutral + Data(signature.suffix(32)), payload: payload, publicKey: key))
        // Wrong lengths.
        XCTAssertFalse(NfcPairingV2Crypto.verifySignature(Data(count: 63), payload: payload, publicKey: key))
        XCTAssertFalse(NfcPairingV2Crypto.verifySignature(signature, payload: Data(), publicKey: key))
    }
}
