import Foundation
import CryptoKit

/// Q-Audion Group Sender Keys (v3-group, magic 0xE4) — per-sender chain
/// ratchet primitives. Direct port of Android's `GroupSenderKey.kt`.
///
/// **Goal**: forward secrecy intra-epoch per-sender. Each member maintains
/// their own sender chain (a symmetric ratchet identical in algebra to the
/// 1:1 ratchet, minus the lex-direction concept). Group messages are
/// encrypted with the sender's current chain key; receivers decrypt with
/// the sender's chain they were previously bootstrapped onto.
///
/// **Wire layout** (spec §2):
/// ```
///   magic(0xE4) | group_id_len(u8) | group_id(L_g) | group_epoch(u32 BE)
///   | sender_id_len(u8) | sender_id(L_s, UTF-8) | chain_idx(u64 BE)
///   | nonce(12, derived NOT random) | ciphertext | gcm_tag(16)
/// ```
///
/// **HKDF derivations** (HKDF-SHA256, salt empty unless noted):
/// ```
///   SK_0       = HKDF(IKM=SK_seed, salt="group-sender-init-v1",
///                     info=group_id_raw || 0x00 || utf8(sender_id), L=32)
///   msg_key_n  = HKDF(IKM=CK_n,    salt=∅, info="grp-msg-key",      L=32)
///   nonce_n    = HKDF(IKM=CK_n,    salt=∅, info="grp-msg-nonce",    L=12)
///   CK_{n+1}   = HKDF(IKM=CK_n,    salt=∅, info="grp-ratchet-step", L=32)
/// ```
///
/// **AAD**: `utf8("grp:" + groupIdHex + ":" + senderId + ":" +
/// chainIdxDecimal)` — raw UTF-8, NOT CBOR. The CBOR-AAD migration
/// applies only to 1:1 (magic 0xE3); group AAD CBOR migration is a
/// future task tracked separately.
///
/// **Critical interop pitfalls** (mirrored from Android kdoc):
///  - `group_id` is RAW BYTES on the wire, but the AAD uses lowercase HEX.
///  - The HKDF init info contains a literal NUL byte separator:
///    `group_id_raw || 0x00 || utf8(sender_id)`. Easy to miss.
///  - `group_epoch` is implicit in the per-epoch session container; it is
///    NOT mixed into the §3.3 init info. Do not add it.
public enum GroupSenderKey {

    /// Wire magic byte distinguishing v3-group (0xE4) from 1:1 v3 (0xE3).
    public static let magicGroupV3: UInt8 = 0xE4

    public static let keyLen = 32
    public static let nonceLen = 12
    public static let tagLen = 16

    /// Cap on `(incoming_idx - last_seen_recv_idx - 1)` per spec §12.
    public static let maxSkipAhead: UInt64 = 10_000
    public static let skippedKeysCacheMax = 256
    public static let skippedKeysTtlMs: Int64 = 7 * 24 * 3600 * 1000

    private static let initSalt = Data("group-sender-init-v1".utf8)
    private static let infoMsgKey = Data("grp-msg-key".utf8)
    private static let infoMsgNonce = Data("grp-msg-nonce".utf8)
    private static let infoRatchetStep = Data("grp-ratchet-step".utf8)
    private static let emptySalt = Data()

    // MARK: - Errors

    public enum GroupRatchetError: Error, Equatable {
        case wireFormat(String)
        case invalidArguments(String)
        case aeadFailed(String)
    }

    // MARK: - Public derivations

    /// Derive `SK_0` from a sender seed per spec §3.3.
    ///
    /// SK_0 = HKDF(IKM=SK_seed, salt="group-sender-init-v1",
    ///             info=group_id_raw || 0x00 || utf8(sender_id), L=32)
    public static func deriveInitChainKey(
        skSeed: Data, groupIdBytes: Data, senderId: String
    ) throws -> Data {
        guard skSeed.count == keyLen else {
            throw GroupRatchetError.invalidArguments("SK_seed must be \(keyLen) bytes, got \(skSeed.count)")
        }
        let senderBytes = Data(senderId.utf8)
        var info = Data(capacity: groupIdBytes.count + 1 + senderBytes.count)
        info.append(groupIdBytes)
        info.append(0x00)            // literal NUL separator — critical
        info.append(senderBytes)
        return hkdf(ikm: skSeed, salt: initSalt, info: info, length: keyLen)
    }

    /// Build the group AAD per spec §5:
    ///   utf8("grp:" + groupIdHex + ":" + senderId + ":" + chainIdxDecimal)
    public static func buildGroupAd(
        groupIdBytes: Data, senderId: String, chainIdx: UInt64
    ) -> Data {
        return Data("grp:\(toHex(groupIdBytes)):\(senderId):\(chainIdx)".utf8)
    }

    /// Per-message triplet: derive (msg_key, nonce) from CK_n. Does NOT consume CK.
    public static func deriveMsgKeys(ck: Data) -> (key: Data, nonce: Data) {
        let mk = hkdf(ikm: ck, salt: emptySalt, info: infoMsgKey, length: keyLen)
        let nc = hkdf(ikm: ck, salt: emptySalt, info: infoMsgNonce, length: nonceLen)
        return (mk, nc)
    }

    /// Single ratchet step: returns CK_{n+1}.
    public static func stepChain(ck: Data) -> Data {
        return hkdf(ikm: ck, salt: emptySalt, info: infoRatchetStep, length: keyLen)
    }

    /// True iff `wire[0] == 0xE4`. Cheap dispatch probe.
    public static func isGroupWire(_ wire: Data) -> Bool {
        guard !wire.isEmpty else { return false }
        return wire[wire.startIndex] == magicGroupV3
    }

    // MARK: - Parsed wire

    public struct ParsedGroupWire: Equatable {
        public let groupId: Data
        public let groupEpoch: UInt32
        public let senderId: String
        public let chainIdx: UInt64
        public let nonce: Data
        public let ciphertext: Data
        public let tag: Data
    }

    // MARK: - Pack / Unpack

    public static func packGroupWire(
        groupIdBytes: Data,
        groupEpoch: UInt32,
        senderId: String,
        chainIdx: UInt64,
        nonce: Data,
        ciphertextWithTag: Data
    ) throws -> Data {
        guard (1...255).contains(groupIdBytes.count) else {
            throw GroupRatchetError.invalidArguments("group_id_len \(groupIdBytes.count) not in [1,255]")
        }
        let senderIdBytes = Data(senderId.utf8)
        guard (1...255).contains(senderIdBytes.count) else {
            throw GroupRatchetError.invalidArguments("sender_id_len \(senderIdBytes.count) not in [1,255]")
        }
        guard nonce.count == nonceLen else {
            throw GroupRatchetError.invalidArguments("nonce must be \(nonceLen) bytes")
        }
        guard ciphertextWithTag.count >= tagLen else {
            throw GroupRatchetError.invalidArguments("wire payload missing GCM tag")
        }
        var out = Data(capacity: 2 + groupIdBytes.count + 4 + 1 + senderIdBytes.count + 8 + nonceLen + ciphertextWithTag.count)
        out.append(magicGroupV3)
        out.append(UInt8(groupIdBytes.count))
        out.append(groupIdBytes)
        // group_epoch u32 BE
        out.append(UInt8((groupEpoch >> 24) & 0xFF))
        out.append(UInt8((groupEpoch >> 16) & 0xFF))
        out.append(UInt8((groupEpoch >> 8) & 0xFF))
        out.append(UInt8(groupEpoch & 0xFF))
        out.append(UInt8(senderIdBytes.count))
        out.append(senderIdBytes)
        // chain_idx u64 BE
        for i in (0..<8).reversed() {
            out.append(UInt8((chainIdx >> (i * 8)) & 0xFF))
        }
        out.append(nonce)
        out.append(ciphertextWithTag)
        return out
    }

    public static func unpackGroupWire(_ wire: Data) throws -> ParsedGroupWire {
        guard !wire.isEmpty else {
            throw GroupRatchetError.wireFormat("empty wire")
        }
        let base = wire.startIndex
        guard wire[base] == magicGroupV3 else {
            throw GroupRatchetError.wireFormat("bad magic byte (expected 0xE4)")
        }
        guard wire.count >= 2 else {
            throw GroupRatchetError.wireFormat("wire too short for group_id_len")
        }
        let groupIdLen = Int(wire[base + 1])
        guard groupIdLen >= 1 else {
            throw GroupRatchetError.wireFormat("group_id_len must be >= 1")
        }
        let off1 = base + 2 + groupIdLen
        guard wire.count >= (off1 - base) + 4 + 1 else {
            throw GroupRatchetError.wireFormat("wire too short (group_id+epoch+sid_len)")
        }
        let groupId = wire.subdata(in: (base + 2)..<off1)
        var groupEpoch: UInt32 = 0
        for i in 0..<4 {
            groupEpoch = (groupEpoch << 8) | UInt32(wire[off1 + i])
        }
        let senderIdLen = Int(wire[off1 + 4])
        guard senderIdLen >= 1 else {
            throw GroupRatchetError.wireFormat("sender_id_len must be >= 1")
        }
        let off2 = off1 + 5
        let minLen = (off2 - base) + senderIdLen + 8 + nonceLen + tagLen
        guard wire.count >= minLen else {
            throw GroupRatchetError.wireFormat("wire too short: \(wire.count) < \(minLen)")
        }
        guard let senderId = String(data: wire.subdata(in: off2..<(off2 + senderIdLen)),
                                     encoding: .utf8) else {
            throw GroupRatchetError.wireFormat("sender_id not valid UTF-8")
        }
        let idxOff = off2 + senderIdLen
        var chainIdx: UInt64 = 0
        for i in 0..<8 {
            chainIdx = (chainIdx << 8) | UInt64(wire[idxOff + i])
        }
        let nonceOff = idxOff + 8
        let ctOff = nonceOff + nonceLen
        let nonce = wire.subdata(in: nonceOff..<ctOff)
        let ctPlusTag = wire.subdata(in: ctOff..<wire.endIndex)
        let cipher = ctPlusTag.prefix(ctPlusTag.count - tagLen)
        let tag = ctPlusTag.suffix(tagLen)
        return ParsedGroupWire(
            groupId: groupId,
            groupEpoch: groupEpoch,
            senderId: senderId,
            chainIdx: chainIdx,
            nonce: nonce,
            ciphertext: Data(cipher),
            tag: Data(tag)
        )
    }

    // MARK: - AEAD

    public static func aesGcmEncrypt(
        key: Data, nonce: Data, plaintext: Data, aad: Data
    ) throws -> Data {
        precondition(key.count == keyLen, "key must be \(keyLen) bytes")
        precondition(nonce.count == nonceLen, "nonce must be \(nonceLen) bytes")
        let symKey = SymmetricKey(data: key)
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: aesNonce, authenticating: aad)
        return sealed.ciphertext + sealed.tag
    }

    public static func aesGcmDecrypt(
        key: Data, nonce: Data, ciphertextWithTag: Data, aad: Data
    ) throws -> Data {
        precondition(key.count == keyLen, "key must be \(keyLen) bytes")
        precondition(nonce.count == nonceLen, "nonce must be \(nonceLen) bytes")
        guard ciphertextWithTag.count >= tagLen else {
            throw GroupRatchetError.wireFormat("ciphertextWithTag too short")
        }
        let symKey = SymmetricKey(data: key)
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let ctOnly = ciphertextWithTag.prefix(ciphertextWithTag.count - tagLen)
        let tag = ciphertextWithTag.suffix(tagLen)
        let box = try AES.GCM.SealedBox(nonce: aesNonce,
                                          ciphertext: ctOnly,
                                          tag: tag)
        return try AES.GCM.open(box, using: symKey, authenticating: aad)
    }

    // MARK: - Hex helpers (lowercase, matching Buffer.toString('hex'))

    public static func toHex(_ bytes: Data) -> String {
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s.append(hexChars[Int(b >> 4)])
            s.append(hexChars[Int(b & 0x0F)])
        }
        return s
    }

    public static func fromHex(_ hex: String) throws -> Data {
        guard hex.count % 2 == 0 else {
            throw GroupRatchetError.invalidArguments("hex string must have even length")
        }
        var out = Data(capacity: hex.count / 2)
        var iter = hex.unicodeScalars.makeIterator()
        while let hi = iter.next() {
            guard let lo = iter.next() else {
                throw GroupRatchetError.invalidArguments("hex string truncated")
            }
            guard let hiV = hexValue(hi), let loV = hexValue(lo) else {
                throw GroupRatchetError.invalidArguments("non-hex character")
            }
            out.append(UInt8((hiV << 4) | loV))
        }
        return out
    }

    private static let hexChars: [Character] = Array("0123456789abcdef")
    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
        let v = scalar.value
        switch v {
        case 0x30...0x39: return UInt8(v - 0x30)
        case 0x61...0x66: return UInt8(v - 0x61 + 10)
        case 0x41...0x46: return UInt8(v - 0x41 + 10)
        default: return nil
        }
    }

    // MARK: - HKDF

    private static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

// MARK: - W-GRPAUDIOKEY: per-epoch audio session keys (2026-08-27)
//
// Group-call SFU-outage fallback audio (QUAD `AUDIO_DATA` opcode 0x06,
// `GroupCallController`'s W-GRPFALLBACKAUDIO-IOS section) used to run its
// own ML-KEM-1024 pairwise handshake per peer to establish a session key.
// That mesh is retired: this codebase ALREADY redistributes `SK_0`/`CK_0`
// to every group member on every membership change (`sender_key_init`/
// `sender_key_rotate`, sealed over the pairwise 1:1 ratchet — see the file
// header doc), and already reuses that SAME value as the LiveKit SFU media
// key (`GroupSession.currentSendKey`/`currentRecvKey`). `audio_key` below
// is a second, ADDITIVE, non-consuming derivation from that same `CK_0` —
// it does NOT read or advance `deriveMsgKeys`/`stepChain`'s chain, which
// stays reserved for the pre-existing WS-relay-mesh group audio/text path
// (`encryptForGroup`/`decryptFromGroup`). Establishing it costs zero
// handshake round-trips and zero new network messages: every group member
// already holds the inputs.
//
// Byte-identical to Desktop's (`GroupSenderKey.ts` audio-derivation
// section) and Android's (`GroupSenderKey.kt`) copies of this same
// derivation — see `group-audio-kat.json` / `GroupAudioSessionKeyKatTests`
// for the shared cross-platform KAT vectors this matches byte-for-byte.
//
// Derivations (HKDF-SHA256, salt empty):
// ```
//   audio_key    = HKDF(IKM=CK_0_at_epoch_start, salt=∅,
//                        info="grp-audio-session-key-v1",           L=32)
//   frame_key_n  = HKDF(IKM=audio_key,           salt=∅,
//                        info="grp-audio-frame-key" || BE64(n),     L=32)
// ```
// Nonce = random(4, generated once per epoch) || BE64(frame_counter).
// AAD   = u16_BE(len(sender_id_utf8)) || utf8(sender_id) || u32_BE(epoch_id).
// Wire  = tag(1)=0x04 || epoch_id BE(4) || nonce(12) || ct_len BE(2) || ct+tag
//   — an INNER frame riding inside the existing QUAD `AUDIO_DATA` outer
//   batch envelope; that outer batch format is untouched.
extension GroupSenderKey {

    /// Wire tag for one sealed `AUDIO_DATA` inner frame. Distinct from
    /// `magicGroupV3` (0xE4): this rides inside the QUAD opcode-0x06 outer
    /// envelope over `group_call_forward`, not the plain `GroupSenderKey`
    /// wire `encryptForGroup`/`decryptFromGroup` produce/consume.
    public static let audioFrameTag: UInt8 = 0x04
    public static let audioKeyLen = 32
    public static let audioNonceLen = 12
    public static let audioNonceRandomLen = 4
    public static let audioTagLen = 16

    private static let infoAudioSessionKey = Data("grp-audio-session-key-v1".utf8)
    private static let infoAudioFrameKeyPrefix = Data("grp-audio-frame-key".utf8)
    /// MEDIA-7 (2026-09-02 protocol audit, backlog item 5A) — domain-separation
    /// label for the LiveKit/SFU frame-encryption key, distinct from
    /// `infoAudioSessionKey` above (the WS-relay fallback-audio key, ALREADY
    /// domain-separated per this file's W-GRPAUDIOKEY section doc) and from
    /// the group MESSAGE ratchet's own `grp-msg-key`/`grp-ratchet-step`
    /// labels. Exact string required byte-for-byte on every platform that
    /// turns this on — see `deriveSfuMediaKey` and
    /// `GroupCallController.grpSfuMediaKeyV1Enabled`.
    private static let infoSfuMediaKey = Data("grp-sfu-media-key-v1".utf8)

    /// `audio_key = HKDF(IKM=CK_0, salt=∅, info="grp-audio-session-key-v1", L=32)`.
    /// `ck0` is the sender's own current send-chain key snapshot for this
    /// group/epoch (`GroupSession.currentSendKey`) or the installed peer's
    /// recv-chain snapshot (`GroupSession.currentRecvKey`) — the SAME `CK_0`
    /// value the LiveKit media key already pins per epoch. Recompute
    /// whenever `GroupState.groupEpoch` changes.
    public static func deriveAudioSessionKey(ck0: Data) -> Data {
        return hkdf(ikm: ck0, salt: emptySalt, info: infoAudioSessionKey, length: audioKeyLen)
    }

    /// MEDIA-7 (backlog item 5A) — `sfu_key = HKDF(IKM=SK_0, salt=∅,
    /// info="grp-sfu-media-key-v1", L=32)`. `sk0` is the same raw send-chain
    /// (`GroupSession.currentSendKey`) or installed recv-chain
    /// (`GroupSession.currentRecvKey`) snapshot `GroupCallController`
    /// currently hands the LiveKit key provider UNMODIFIED — this wraps it
    /// in a domain-separated derivation before that handoff, exactly the
    /// same shape `deriveAudioSessionKey` already applies for the WS-relay
    /// fallback-audio key immediately above. Gated behind
    /// `GroupCallController.grpSfuMediaKeyV1Enabled` (default false) — the
    /// caller chooses `sk0` verbatim or this derived value, never both.
    public static func deriveSfuMediaKey(sk0: Data) -> Data {
        return hkdf(ikm: sk0, salt: emptySalt, info: infoSfuMediaKey, length: audioKeyLen)
    }

    /// `frame_key_n = HKDF(IKM=audio_key, salt=∅, info="grp-audio-frame-key" || BE64(n), L=32)`.
    /// `frameCounter` is a per-sender-per-epoch monotonic counter starting
    /// at 0, incremented once per outbound frame sealed this epoch — never
    /// reset except on a fresh `audio_key`.
    public static func deriveAudioFrameKey(audioKey: Data, frameCounter: UInt64) -> Data {
        var info = infoAudioFrameKeyPrefix
        info.append(be64(frameCounter))
        return hkdf(ikm: audioKey, salt: emptySalt, info: info, length: audioKeyLen)
    }

    /// `nonce = random(4) || BE64(frame_counter)`. `randomPrefix` is
    /// generated once when `audio_key` is (re)derived for a fresh epoch and
    /// held fixed for that epoch's lifetime; `frameCounter` never repeats
    /// within one (audio_key, randomPrefix) pair, so (key, nonce) never
    /// repeats either.
    public static func buildAudioNonce(randomPrefix: Data, frameCounter: UInt64) -> Data {
        var nonce = Data(randomPrefix)
        nonce.append(be64(frameCounter))
        return nonce
    }

    /// `AAD = u16_BE(len(sender_id_utf8)) || utf8(sender_id) || u32_BE(epoch_id)`.
    /// Intentionally a distinct, simpler binary layout from
    /// `buildGroupAd`'s `"grp:...":`-string AAD above — do not conflate the
    /// two; they cover different wire families.
    public static func buildAudioAd(senderId: String, epochId: UInt32) -> Data {
        let senderBytes = Data(senderId.utf8)
        var aad = Data(capacity: 2 + senderBytes.count + 4)
        let len = UInt16(senderBytes.count)
        aad.append(UInt8((len >> 8) & 0xFF))
        aad.append(UInt8(len & 0xFF))
        aad.append(senderBytes)
        aad.append(UInt8((epochId >> 24) & 0xFF))
        aad.append(UInt8((epochId >> 16) & 0xFF))
        aad.append(UInt8((epochId >> 8) & 0xFF))
        aad.append(UInt8(epochId & 0xFF))
        return aad
    }

    /// `tag(1)=0x04 || epoch_id BE(4) || nonce(12) || ciphertext_len BE(2) || ciphertext+tag`.
    public static func packAudioWire(epochId: UInt32, nonce: Data, ciphertextWithTag: Data) throws -> Data {
        guard nonce.count == audioNonceLen else {
            throw GroupRatchetError.invalidArguments("audio nonce must be \(audioNonceLen) bytes")
        }
        guard ciphertextWithTag.count >= audioTagLen, ciphertextWithTag.count <= Int(UInt16.max) else {
            throw GroupRatchetError.invalidArguments("audio ciphertext(+tag) length out of range: \(ciphertextWithTag.count)")
        }
        var out = Data(capacity: 1 + 4 + audioNonceLen + 2 + ciphertextWithTag.count)
        out.append(audioFrameTag)
        out.append(UInt8((epochId >> 24) & 0xFF))
        out.append(UInt8((epochId >> 16) & 0xFF))
        out.append(UInt8((epochId >> 8) & 0xFF))
        out.append(UInt8(epochId & 0xFF))
        out.append(nonce)
        let len = UInt16(ciphertextWithTag.count)
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
        out.append(ciphertextWithTag)
        return out
    }

    public struct ParsedAudioWire: Equatable {
        public let epochId: UInt32
        public let nonce: Data
        public let ciphertextWithTag: Data
        /// Extracted from the nonce's own trailing 8 bytes (`nonce = random(4) || BE64(frame_counter)`)
        /// — the wire never encodes `frame_counter` as a separate field.
        public let frameCounter: UInt64
    }

    public static func unpackAudioWire(_ wire: Data) throws -> ParsedAudioWire {
        let base = wire.startIndex
        let minLen = 1 + 4 + audioNonceLen + 2 + audioTagLen
        guard wire.count >= minLen else {
            throw GroupRatchetError.wireFormat("audio wire too short: \(wire.count) < \(minLen)")
        }
        guard wire[base] == audioFrameTag else {
            throw GroupRatchetError.wireFormat("bad audio frame tag (expected 0x04)")
        }
        var epochId: UInt32 = 0
        for i in 0..<4 { epochId = (epochId << 8) | UInt32(wire[base + 1 + i]) }
        let nonceOff = base + 5
        let nonce = wire.subdata(in: nonceOff..<(nonceOff + audioNonceLen))
        let lenOff = nonceOff + audioNonceLen
        let ctLen = (Int(wire[lenOff]) << 8) | Int(wire[lenOff + 1])
        let ctOff = lenOff + 2
        // Index-relative (not `wire.count`-relative): `ctOff` is an absolute
        // position derived from `base = wire.startIndex`, so the comparison
        // must be against `wire.endIndex` to stay correct for a `Data` whose
        // `startIndex` is not 0 (e.g. a raw slice rather than a fresh buffer
        // or `.subdata(in:)` copy).
        guard ctLen >= audioTagLen, ctOff + ctLen == wire.endIndex else {
            throw GroupRatchetError.wireFormat("audio wire length mismatch: declared_ct_len=\(ctLen) actual_remaining=\(wire.endIndex - ctOff)")
        }
        let ciphertextWithTag = wire.subdata(in: ctOff..<(ctOff + ctLen))
        var frameCounter: UInt64 = 0
        let counterOff = nonce.startIndex + audioNonceRandomLen
        for i in 0..<8 { frameCounter = (frameCounter << 8) | UInt64(nonce[counterOff + i]) }
        return ParsedAudioWire(epochId: epochId, nonce: nonce, ciphertextWithTag: ciphertextWithTag, frameCounter: frameCounter)
    }

    private static func be64(_ v: UInt64) -> Data {
        var d = Data(capacity: 8)
        for i in (0..<8).reversed() { d.append(UInt8((v >> (i * 8)) & 0xFF)) }
        return d
    }
}
