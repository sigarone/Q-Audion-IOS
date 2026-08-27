import XCTest
@testable import QAudionEngine

// This file's Decodable structs mirror KAT JSON fixture keys verbatim
// (snake_case, no CodingKeys) — renaming would silently break decoding
// against the shared cross-platform fixture.
// swiftlint:disable identifier_name

/// W-GRPAUDIOKEY (2026-08-27) — group-call SFU-outage fallback-audio
/// session/frame-key KAT verifier (iOS).
///
/// FROZEN contract `group-audio-kat.json` (vendored byte-for-byte, shared
/// with Desktop's `qaudion-desktop/scripts/group-sender-keys-kat-dump.mjs
/// buildAudioKat`, Android's mirror). Every vector is driven through the
/// REAL production `GroupSenderKey` derivations added for this feature
/// (`deriveAudioSessionKey`/`deriveAudioFrameKey`/`buildAudioNonce`/
/// `buildAudioAd`/`packAudioWire`/`unpackAudioWire`, plus the already-
/// existing `deriveInitChainKey`/`aesGcmEncrypt`/`aesGcmDecrypt`) — never
/// re-implemented locally — so a drift in the actual shipping code fails
/// this test, not a hand-copied stand-in.
///
/// `audio-kat-004/005/006`'s `plaintext_hex` is a deterministic 120-byte
/// pattern, NOT the padded-block Opus envelope (`GroupFallbackAudioSealer`'s
/// own primitive, separately covered by `GroupFallbackAudioSealerTests`) —
/// this KAT isolates `audio_key`/`frame_key`/nonce/AAD/AES-256-GCM/wire
/// pack-unpack, matching the fixture's own `note_plaintext` field.
///
/// ⚠️ Requires `swift test` (CryptoKit) — authored on win32 which cannot run
/// CryptoKit. The byte construction was independently verified offline
/// against the JSON using Python's `cryptography` package (HKDF-SHA256 +
/// AES-256-GCM, RFC 5869 / NIST SP 800-38D — same standards CryptoKit
/// implements): every vector below matched byte-for-byte. CI is the gate
/// for the actual Swift/CryptoKit code path.
final class GroupAudioSessionKeyKatTests: XCTestCase {

    private struct FrameKeyEntry: Decodable {
        let n: String
        let frame_key_hex: String
    }

    private struct Vector: Decodable {
        let id: String
        let description: String
        let group_id_hex: String?
        let sender_id: String?
        let group_epoch: Int?
        let sk_seed_hex: String?
        let ck0_hex: String?
        let audio_key_hex: String
        let differs_from: String?
        let frame_keys: [FrameKeyEntry]?
        let epoch_id: Int?
        let frame_counter: String?
        let nonce_random_prefix_hex: String?
        let plaintext_hex: String?
        let frame_key_hex: String?
        let nonce_hex: String?
        let aad_hex: String?
        let ciphertext_with_tag_hex: String?
        let wire_hex: String?
    }

    private struct File: Decodable {
        let version: String
        let vectors: [Vector]
    }

    /// audio-kat-001/002 — the FULL production path: `SK_seed` -> `CK_0`
    /// (`GroupSenderKey.deriveInitChainKey`, the SAME call
    /// `GroupSession.create`/`handleMemberRemoved` already make in
    /// production) -> `audio_key` (`GroupSenderKey.deriveAudioSessionKey`,
    /// this feature's new derivation). 002 uses a fresh `SK_seed` (mirrors a
    /// member-remove epoch reseed) and must land on a DIFFERENT `audio_key`.
    func testAudioKeyDerivationMatchesProductionSK0Path() throws {
        guard let kat = loadKat() else {
            XCTFail("group-audio-kat.json not found (Bundle.module + fs fallback both missed)")
            return
        }
        XCTAssertEqual(kat.version, "v3-group-audio-session-keys-1")
        let byId = Dictionary(uniqueKeysWithValues: kat.vectors.map { ($0.id, $0) })
        var derivedAudioKeys: [String: Data] = [:]

        for id in ["audio-kat-001", "audio-kat-002"] {
            guard let v = byId[id],
                  let groupIdHex = v.group_id_hex, let senderId = v.sender_id,
                  let skSeedHex = v.sk_seed_hex, let ck0Hex = v.ck0_hex else {
                XCTFail("[\(id)] missing required fields")
                continue
            }
            let skSeed = Data(audioKatHex: skSeedHex)
            let groupId = Data(audioKatHex: groupIdHex)

            let ck0 = try GroupSenderKey.deriveInitChainKey(skSeed: skSeed, groupIdBytes: groupId, senderId: senderId)
            XCTAssertEqual(ck0.hexAudioKat(), ck0Hex, "[\(id)] CK_0 (production deriveInitChainKey) drift")

            let audioKey = GroupSenderKey.deriveAudioSessionKey(ck0: ck0)
            XCTAssertEqual(audioKey.count, GroupSenderKey.audioKeyLen)
            XCTAssertEqual(audioKey.hexAudioKat(), v.audio_key_hex, "[\(id)] audio_key drift")
            derivedAudioKeys[id] = audioKey
        }

        if let a = derivedAudioKeys["audio-kat-001"], let b = derivedAudioKeys["audio-kat-002"] {
            XCTAssertNotEqual(a, b, "audio-kat-002's fresh CK_0 (epoch reseed) must yield a DIFFERENT audio_key than audio-kat-001")
        } else {
            XCTFail("expected both audio-kat-001 and audio-kat-002 to derive successfully")
        }
    }

    /// audio-kat-003 — sequential `frame_key_n` for n=0..4 off one fixed
    /// `audio_key`, via `GroupSenderKey.deriveAudioFrameKey`.
    func testFrameKeySequence() throws {
        guard let kat = loadKat() else {
            XCTFail("group-audio-kat.json not found")
            return
        }
        guard let v = kat.vectors.first(where: { $0.id == "audio-kat-003" }),
              let frameKeys = v.frame_keys else {
            XCTFail("audio-kat-003 vector missing")
            return
        }
        let audioKey = Data(audioKatHex: v.audio_key_hex)
        for entry in frameKeys {
            guard let n = UInt64(entry.n) else {
                XCTFail("bad frame counter literal: \(entry.n)")
                continue
            }
            let frameKey = GroupSenderKey.deriveAudioFrameKey(audioKey: audioKey, frameCounter: n)
            XCTAssertEqual(frameKey.hexAudioKat(), entry.frame_key_hex, "[audio-kat-003 n=\(n)] frame_key drift")
        }
    }

    /// audio-kat-004/005/006 — full worked seal: `frame_key` -> nonce -> AAD
    /// -> AES-256-GCM -> wire pack, EACH intermediate value pinned, plus a
    /// round trip back through `unpackAudioWire`/`aesGcmDecrypt` to confirm
    /// the wire is genuinely openable, not just byte-identical on the way
    /// out. 006 additionally cross-checks that a DIFFERENT `sender_id`/
    /// `epoch_id` (and therefore AAD) produces a completely different
    /// ciphertext/wire than 004 for the SAME `frame_counter`.
    func testFullWorkedSeal() throws {
        guard let kat = loadKat() else {
            XCTFail("group-audio-kat.json not found")
            return
        }
        for id in ["audio-kat-004", "audio-kat-005", "audio-kat-006"] {
            guard let v = kat.vectors.first(where: { $0.id == id }),
                  let senderId = v.sender_id, let epochIdInt = v.epoch_id,
                  let frameCounterStr = v.frame_counter, let frameCounter = UInt64(frameCounterStr),
                  let noncePrefixHex = v.nonce_random_prefix_hex,
                  let plaintextHex = v.plaintext_hex,
                  let expectedFrameKeyHex = v.frame_key_hex,
                  let expectedNonceHex = v.nonce_hex,
                  let expectedAadHex = v.aad_hex,
                  let expectedCtHex = v.ciphertext_with_tag_hex,
                  let expectedWireHex = v.wire_hex else {
                XCTFail("[\(id)] missing required fields")
                continue
            }
            let epochId = UInt32(epochIdInt)
            let audioKey = Data(audioKatHex: v.audio_key_hex)
            let noncePrefix = Data(audioKatHex: noncePrefixHex)
            let plaintext = Data(audioKatHex: plaintextHex)

            let frameKey = GroupSenderKey.deriveAudioFrameKey(audioKey: audioKey, frameCounter: frameCounter)
            XCTAssertEqual(frameKey.hexAudioKat(), expectedFrameKeyHex, "[\(id)] frame_key drift")

            let nonce = GroupSenderKey.buildAudioNonce(randomPrefix: noncePrefix, frameCounter: frameCounter)
            XCTAssertEqual(nonce.hexAudioKat(), expectedNonceHex, "[\(id)] nonce drift")

            let aad = GroupSenderKey.buildAudioAd(senderId: senderId, epochId: epochId)
            XCTAssertEqual(aad.hexAudioKat(), expectedAadHex, "[\(id)] AAD drift")

            let ctWithTag = try GroupSenderKey.aesGcmEncrypt(key: frameKey, nonce: nonce, plaintext: plaintext, aad: aad)
            XCTAssertEqual(ctWithTag.hexAudioKat(), expectedCtHex, "[\(id)] ciphertext_with_tag drift")

            let wire = try GroupSenderKey.packAudioWire(epochId: epochId, nonce: nonce, ciphertextWithTag: ctWithTag)
            XCTAssertEqual(wire.hexAudioKat(), expectedWireHex, "[\(id)] wire drift")

            // Round trip: unpack the wire and decrypt back to the original
            // plaintext — confirms this isn't just a one-way byte match.
            let parsed = try GroupSenderKey.unpackAudioWire(wire)
            XCTAssertEqual(parsed.epochId, epochId, "[\(id)] unpacked epoch_id drift")
            XCTAssertEqual(parsed.frameCounter, frameCounter, "[\(id)] frame_counter recovered from nonce tail drift")
            XCTAssertEqual(parsed.nonce, nonce, "[\(id)] unpacked nonce drift")
            XCTAssertEqual(parsed.ciphertextWithTag, ctWithTag, "[\(id)] unpacked ciphertext drift")
            let decrypted = try GroupSenderKey.aesGcmDecrypt(
                key: frameKey, nonce: parsed.nonce, ciphertextWithTag: parsed.ciphertextWithTag, aad: aad)
            XCTAssertEqual(decrypted, plaintext, "[\(id)] round-trip decrypt did not recover the original plaintext")
        }

        // Cross-check: 004 and 006 share frame_counter=0 but differ in
        // sender_id/epoch_id — their AAD, and therefore ciphertext and wire,
        // must be completely different.
        if let v4 = kat.vectors.first(where: { $0.id == "audio-kat-004" }),
           let v6 = kat.vectors.first(where: { $0.id == "audio-kat-006" }) {
            XCTAssertNotEqual(v4.aad_hex, v6.aad_hex, "different (sender_id, epoch_id) must bind to different AAD")
            XCTAssertNotEqual(v4.ciphertext_with_tag_hex, v6.ciphertext_with_tag_hex)
            XCTAssertNotEqual(v4.wire_hex, v6.wire_hex)
        } else {
            XCTFail("expected both audio-kat-004 and audio-kat-006 to be present")
        }
    }

    private func loadKat() -> File? {
        if let url = Bundle.module.url(forResource: "group-audio-kat", withExtension: "json"),
           let d = try? Data(contentsOf: url),
           let f = try? JSONDecoder().decode(File.self, from: d) { return f }
        // Filesystem fallback — walk up looking for the vendored copy.
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<8 {
            let c = dir.appendingPathComponent("QAudionEngine/Tests/QAudionEngineTests/Crypto/Resources/group-audio-kat.json")
            if fm.fileExists(atPath: c.path),
               let d = try? Data(contentsOf: c),
               let f = try? JSONDecoder().decode(File.self, from: d) { return f }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

private extension Data {
    init(audioKatHex hex: String) {
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            data.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        self = data
    }
    func hexAudioKat() -> String { map { String(format: "%02x", $0) }.joined() }
}
// swiftlint:enable identifier_name
