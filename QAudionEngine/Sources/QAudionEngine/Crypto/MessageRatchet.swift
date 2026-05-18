import Foundation
import CryptoKit

/// Q-Audion messaging wire format **v3.1** — symmetric ratchet engine.
///
/// Direct port of Android's `MessageRatchet.kt`. Every byte on the wire
/// (and every HKDF input) MUST match the Android engine exactly — the
/// two implementations talk to each other through the AAD-bound AEAD
/// envelope, so any drift means silent decryption failure.
///
/// **Goal**: forward secrecy intra-epoch. Each direction maintains a
/// 32-byte chain key; every send/receive HKDF-derives the per-message
/// AEAD key + nonce, then advances the chain key and zeroizes the
/// previous one.
///
/// **Wire format** (v3.1 — see spec §2):
/// ```
///   offset   size   field
///   0        1      magic (0xE3)
///   1        1      epoch_len (uint8, 1..255)
///   2        L      epoch (UTF-8)
///   2+L      1      direction_flag (0x01 = lo->hi, 0x02 = hi->lo)
///   3+L      8      chain_idx (uint64 BE)
///   11+L     N      ciphertext
///   11+L+N   16     AES-GCM tag
/// ```
///
/// **AAD format** (v3.1 — canonical CBOR, spec §3):
/// ```
///   aad = canonical-CBOR({"m": clientMsgId, "r": recipientId,
///                         "s": senderId, "v": 3})
/// ```
///
/// **HKDF init info** (v3.1 — canonical CBOR, spec §4.1):
/// ```
///   info_lo_to_hi = canonical-CBOR(["v3", "lo->hi", lo, hi])
///   info_hi_to_lo = canonical-CBOR(["v3", "hi->lo", lo, hi])
/// ```
///
/// **Nonce IKM** (v3.1 — spec §4.2):
/// ```
///   nonce_n = HKDF(IKM = CK_n || u8(chain_idx & 0xFF),
///                  salt = ∅, info = "msg-nonce-v3.1", L = 12)
/// ```
public final class MessageRatchet {

    // MARK: - Constants (must match Android byte-for-byte)

    /// Wire magic byte distinguishing v3 from v2 (0xE2) and v1.
    public static let magicV3: UInt8 = 0xE3
    /// `direction_flag` advertised by the lex-min peer.
    public static let dirLoToHi: UInt8 = 0x01
    /// `direction_flag` advertised by the lex-max peer.
    public static let dirHiToLo: UInt8 = 0x02

    public static let keyLen = 32
    public static let nonceLen = 12
    public static let tagLen = 16

    /// Hard cap on `(incoming_idx - last_seen_recv_idx - 1)` per spec §9.
    public static let maxSkipAhead: UInt64 = 10_000
    /// LRU bound on the per-session skipped-keys cache.
    public static let skippedKeysCacheMax = 256
    /// TTL for skipped-key cache entries (7 days, in ms).
    public static let skippedKeysTtlMs: Int64 = 7 * 24 * 3600 * 1000

    // HKDF labels — case-sensitive UTF-8, MUST match the spec byte-for-byte.
    private static let initSalt = Data("ratchet-init-v3".utf8)
    private static let infoMsgKey = Data("msg-key".utf8)
    private static let infoMsgNonce = Data("msg-nonce-v3.1".utf8)
    private static let infoRatchetStep = Data("ratchet-step".utf8)
    private static let emptySalt = Data()

    // MARK: - State

    private let vault: RatchetVault

    public init(vault: RatchetVault) {
        self.vault = vault
    }

    // MARK: - Errors

    public enum RatchetError: Error, Equatable {
        case invalidArguments(String)
        case wireFormat(String)
        case epochMismatch(wire: String, state: String)
        case directionMismatch(wire: UInt8, expected: UInt8)
        case replayOrUnknownIdx(idx: UInt64, lastSeen: UInt64?)
        case skipAheadExceeded(skip: UInt64)
        case aeadFailed(String)
    }

    // MARK: - Public API

    /// True iff `wire[0] == 0xE3`. Cheap probe used by the message
    /// router to dispatch incoming bytes between v2 and v3.x paths.
    public static func isV3Wire(_ wire: Data) -> Bool {
        guard !wire.isEmpty else { return false }
        return wire[wire.startIndex] == magicV3
    }

    /// Build the v3.1 AAD: canonical CBOR
    ///   `{"m": clientMsgId, "r": recipientId, "s": senderId, "v": 3}`.
    public static func buildMessageAD(
        senderId: String, recipientId: String, clientMsgId: String
    ) -> Data {
        return CanonicalCbor.buildMessageAD(
            senderId: senderId,
            recipientId: recipientId,
            clientMsgId: clientMsgId
        )
    }

    /// Initialize or recover the ratchet session for `(epochId, peerId)`.
    /// Idempotent: repeated calls with the same arguments return
    /// equivalent sessions.
    public func ensureSession(
        epochId: String,
        selfId: String,
        peerId: String,
        pskRoot: Data
    ) throws -> RatchetSession {
        guard selfId != peerId else {
            throw RatchetError.invalidArguments("selfId and peerId must differ")
        }
        let epochBytes = Data(epochId.utf8)
        guard (1...255).contains(epochBytes.count) else {
            throw RatchetError.invalidArguments(
                "epochId must encode to 1..255 UTF-8 bytes (got \(epochBytes.count))")
        }

        if let existing = vault.load(epochId: epochId, peerId: peerId) {
            guard existing.selfId == selfId else {
                throw RatchetError.invalidArguments(
                    "vault snapshot belongs to a different self ('\(existing.selfId)', expected '\(selfId)')")
            }
            return Self.toLiveSession(existing)
        }

        let selfIsLo = Self.lexLess(selfId, peerId)
        let lo = selfIsLo ? selfId : peerId
        let hi = selfIsLo ? peerId : selfId
        let infoLoToHi = CanonicalCbor.buildInitInfo(direction: "lo->hi", lo: lo, hi: hi)
        let infoHiToLo = CanonicalCbor.buildInitInfo(direction: "hi->lo", lo: lo, hi: hi)
        let ckLoToHi0 = Self.hkdf(ikm: pskRoot, salt: Self.initSalt, info: infoLoToHi, length: Self.keyLen)
        let ckHiToLo0 = Self.hkdf(ikm: pskRoot, salt: Self.initSalt, info: infoHiToLo, length: Self.keyLen)

        let session = RatchetSession(
            epochId: epochId,
            selfId: selfId,
            peerId: peerId,
            sendDirFlag: selfIsLo ? Self.dirLoToHi : Self.dirHiToLo,
            recvDirFlag: selfIsLo ? Self.dirHiToLo : Self.dirLoToHi,
            ckSend: selfIsLo ? ckLoToHi0 : ckHiToLo0,
            nextSendIdx: 0,
            ckRecv: selfIsLo ? ckHiToLo0 : ckLoToHi0,
            lastSeenRecvIdx: nil,
            skippedKeys: []
        )
        try persist(session)
        return session
    }

    /// Encrypt `plaintext` under the session's send chain.
    /// Mutates `session` (advances `ckSend`, `nextSendIdx`) and **persists
    /// the new state to the vault BEFORE returning** — the write-ahead
    /// invariant against nonce reuse on crash.
    public func encrypt(
        session: RatchetSession,
        plaintext: Data,
        aad: Data,
        clientMsgId: String  // logging only; AAD already binds it
    ) throws -> Data {
        let chainIdx = session.nextSendIdx
        let (msgKey, nonce) = try Self.deriveMsgKeyAndNonce(ck: session.ckSend, chainIdx: chainIdx)

        let ctWithTag = try Self.aesGcmEncrypt(key: msgKey, nonce: nonce, plaintext: plaintext, aad: aad)

        let wire = try Self.packWire(
            epoch: session.epochId,
            dirFlag: session.sendDirFlag,
            chainIdx: chainIdx,
            ciphertextWithTag: ctWithTag
        )

        // Step the chain BEFORE persisting so we save CK_{n+1}.
        let ckNext = Self.hkdf(ikm: session.ckSend, salt: Self.emptySalt,
                                info: Self.infoRatchetStep, length: Self.keyLen)
        // SECURITY C-8: scrub the superseded CK_n before reassignment.
        Self.zeroizing(&session.ckSend, replaceWith: ckNext)
        session.nextSendIdx = chainIdx &+ 1
        // SECURITY C-7: persist must durably flush BEFORE we hand the
        // ciphertext to the caller. If it throws, the wire blob is never
        // returned — no transmit, no nonce-reuse window on crash.
        try persist(session)

        return wire
    }

    /// Decrypt a v3.1 wire frame. Returns nil on any failure (replay,
    /// MAX_SKIP_AHEAD exceeded, AEAD failure, malformed wire). Production
    /// callers should prefer this over `decryptOrThrow` to avoid leaking
    /// rejection class through error messages.
    public func decrypt(
        session: RatchetSession,
        wire: Data,
        aad: Data
    ) -> Data? {
        do { return try decryptOrThrow(session: session, wire: wire, aad: aad) }
        catch { return nil }
    }

    /// Diagnostic decrypt — surfaces the underlying `RatchetError`.
    /// Tests / KAT verifiers use this to assert the failure class.
    public func decryptOrThrow(
        session: RatchetSession,
        wire: Data,
        aad: Data
    ) throws -> Data {
        let parsed = try Self.unpackWire(wire)
        guard parsed.epoch == session.epochId else {
            throw RatchetError.epochMismatch(wire: parsed.epoch, state: session.epochId)
        }
        guard parsed.dirFlag == session.recvDirFlag else {
            throw RatchetError.directionMismatch(wire: parsed.dirFlag, expected: session.recvDirFlag)
        }

        let incoming = parsed.chainIdx
        let lastSeen = session.lastSeenRecvIdx
        // expected = (lastSeen ?? 0xFFFF...) + 1, but we treat nil as
        // "haven't seen any" so expected = 0.
        let expected: UInt64 = (lastSeen.map { $0 &+ 1 }) ?? 0

        // Late delivery — must be in skipped cache.
        if let ls = lastSeen, incoming <= ls {
            guard let entry = removeSkipped(session: session, idx: incoming) else {
                throw RatchetError.replayOrUnknownIdx(idx: incoming, lastSeen: lastSeen)
            }
            do {
                let pt = try Self.aesGcmDecrypt(
                    key: entry.key,
                    nonce: entry.nonce,
                    ciphertextWithTag: parsed.ciphertextWithTag,
                    aad: aad
                )
                try persist(session)
                return pt
            } catch {
                // Re-insert so a corrupted frame doesn't burn the cached key.
                session.skippedKeys.append((incoming, entry))
                throw RatchetError.aeadFailed("skipped-cache AEAD failed at idx=\(incoming): \(error)")
            }
        }

        // Skip-ahead: derive and cache the missing keys.
        if incoming > expected {
            let skipCount = incoming - expected
            guard skipCount <= Self.maxSkipAhead else {
                throw RatchetError.skipAheadExceeded(skip: skipCount)
            }
            var cursor = session.ckRecv
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let expiresAt = now + Self.skippedKeysTtlMs
            var j = expected
            while j < incoming {
                let (mk, nc) = try Self.deriveMsgKeyAndNonce(ck: cursor, chainIdx: j)
                session.skippedKeys.append((j, SkippedKey(key: mk, nonce: nc, expiresAtMs: expiresAt)))
                cursor = Self.hkdf(ikm: cursor, salt: Self.emptySalt,
                                    info: Self.infoRatchetStep, length: Self.keyLen)
                j &+= 1
            }
            // SECURITY C-8: scrub the superseded receive chain key.
            Self.zeroizing(&session.ckRecv, replaceWith: cursor)
            evictExpired(session: session, nowMs: now)
            evictLruOverflow(session: session)
        }

        // In-order (or just-caught-up).
        let (msgKey, nonce) = try Self.deriveMsgKeyAndNonce(
            ck: session.ckRecv, chainIdx: incoming)
        let pt: Data
        do {
            pt = try Self.aesGcmDecrypt(
                key: msgKey, nonce: nonce,
                ciphertextWithTag: parsed.ciphertextWithTag, aad: aad)
        } catch {
            throw RatchetError.aeadFailed("AEAD decrypt failed at idx=\(incoming): \(error)")
        }
        let ckNext = Self.hkdf(ikm: session.ckRecv, salt: Self.emptySalt,
                                info: Self.infoRatchetStep, length: Self.keyLen)
        // SECURITY C-8: scrub the superseded receive chain key.
        Self.zeroizing(&session.ckRecv, replaceWith: ckNext)
        session.lastSeenRecvIdx = incoming
        try persist(session)
        return pt
    }

    /// Garbage-collect expired skipped-key entries.
    ///
    /// SECURITY C-7: `throws` because it persists the pruned snapshot and
    /// a silent persistence failure must surface to the caller.
    public func gc(session: RatchetSession, nowMs: Int64? = nil) throws {
        let now = nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let before = session.skippedKeys.count
        evictExpired(session: session, nowMs: now)
        evictLruOverflow(session: session)
        if session.skippedKeys.count != before {
            try persist(session)
        }
    }

    // MARK: - Internal helpers

    // SECURITY C-7: persistence failure is fatal on the encrypt path —
    // the wire blob must NOT be returned/transmitted if CK_{n+1} did not
    // durably flush (nonce-reuse hazard, spec §6). Propagate the throw.
    private func persist(_ session: RatchetSession) throws {
        try vault.save(
            epochId: session.epochId,
            peerId: session.peerId,
            snapshot: Self.toSnapshot(session)
        )
    }

    // SECURITY C-8: ARC does not zero-fill released buffers. Before a
    // chain key (`ckSend`/`ckRecv`) is overwritten with `CK_{n+1}`, the
    // old `Data` is explicitly scrubbed with the hardened, optimiser-
    // proof `CryptoConstants.zeroize` (memset_s on Darwin — see H-11/L-10)
    // so the superseded key cannot be recovered from freed heap pages.
    // We keep the field typed as `Data` (not `SecureBytes`) to avoid any
    // risk to the byte-for-byte Android wire/HKDF compatibility; an
    // explicit scrub of the old buffer is the conservative equivalent.
    private static func zeroizing(_ old: inout Data, replaceWith next: Data) {
        CryptoConstants.zeroize(&old)
        old = next
    }

    private func removeSkipped(session: RatchetSession, idx: UInt64) -> SkippedKey? {
        guard let pos = session.skippedKeys.firstIndex(where: { $0.0 == idx }) else { return nil }
        let entry = session.skippedKeys.remove(at: pos).1
        return entry
    }

    // SECURITY L-11: a skipped key is a live 32-byte AES-256-GCM message
    // key. On eviction (TTL expiry or LRU overflow) scrub the key/nonce
    // buffers with the hardened zeroize. The entry MUST already be
    // removed from `session.skippedKeys` before this runs: `Data` is
    // copy-on-write, so the buffer is only uniquely owned (and therefore
    // actually scrubbed in place) once no other `SkippedKey` references
    // it — otherwise `withUnsafeMutableBytes` would COW-copy and zero a
    // throwaway. ARC does not zero-fill freed pages, hence the explicit
    // scrub. Best-effort: residual COW copies inside `Data`'s allocator
    // are out of our control; this clears the canonical buffer.
    private func zeroizeRemovedSkipped(_ removed: [(UInt64, SkippedKey)]) {
        for (_, sk) in removed {
            var k = sk.key
            var n = sk.nonce
            CryptoConstants.zeroize(&k)
            CryptoConstants.zeroize(&n)
        }
    }

    private func evictExpired(session: RatchetSession, nowMs: Int64) {
        var removed: [(UInt64, SkippedKey)] = []
        var kept: [(UInt64, SkippedKey)] = []
        kept.reserveCapacity(session.skippedKeys.count)
        for entry in session.skippedKeys {
            if entry.1.expiresAtMs <= nowMs {
                removed.append(entry)
            } else {
                kept.append(entry)
            }
        }
        guard !removed.isEmpty else { return }
        session.skippedKeys = kept
        zeroizeRemovedSkipped(removed)
    }

    private func evictLruOverflow(session: RatchetSession) {
        var removed: [(UInt64, SkippedKey)] = []
        while session.skippedKeys.count > Self.skippedKeysCacheMax {
            removed.append(session.skippedKeys.removeFirst())
        }
        if !removed.isEmpty {
            zeroizeRemovedSkipped(removed)
        }
    }

    // MARK: - Pure helpers (static)

    /// Lex compare on raw UTF-8 bytes (locale-independent).
    private static func lexLess(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        let lim = min(ab.count, bb.count)
        for i in 0..<lim {
            if ab[i] != bb[i] { return ab[i] < bb[i] }
        }
        return ab.count < bb.count
    }

    /// HKDF-SHA256 — exact byte-equivalent to BouncyCastle's
    /// `HKDFBytesGenerator` over `(ikm, salt, info, length)`.
    private static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let key = SymmetricKey(data: ikm)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    private static func deriveMsgKeyAndNonce(
        ck: Data, chainIdx: UInt64
    ) throws -> (key: Data, nonce: Data) {
        let msgKey = hkdf(ikm: ck, salt: emptySalt, info: infoMsgKey, length: keyLen)
        // SECURITY L-16: the nonce IKM folds in only the LOW BYTE of
        // chain_idx (`chainIdx & 0xFF`), not the full 64-bit index. This
        // is wire-load-bearing — Android's MessageRatchet derives the
        // nonce byte-for-byte the same way, so widening it here would
        // silently break every cross-platform decrypt. It is NOT a nonce-
        // reuse bug at the protocol level: the nonce's primary entropy is
        // the full 32-byte chain key `CK_n`, which advances (HKDF "ratchet
        // -step") on EVERY send/receive, so two different messages never
        // share the same (CK_n, idx-low-byte) pair within a chain. The
        // low byte is only a cheap extra domain separator. Using the
        // full-width chain_idx in the nonce IKM would be cleaner defence-
        // in-depth but requires a coordinated cross-platform wire bump
        // (v3.2) — DO NOT change unilaterally. Comment-only.
        let idxLowByte = UInt8(chainIdx & 0xFF)
        var nonceIkm = Data(capacity: ck.count + 1)
        nonceIkm.append(ck)
        nonceIkm.append(idxLowByte)
        let nonce = hkdf(ikm: nonceIkm, salt: emptySalt, info: infoMsgNonce, length: nonceLen)
        return (msgKey, nonce)
    }

    /// AES-256-GCM encryption with caller-supplied deterministic nonce.
    /// Output is `ciphertext || tag` (16-byte tag appended — same shape
    /// Java/Kotlin produces and what we then split back out on decrypt).
    private static func aesGcmEncrypt(
        key: Data, nonce: Data, plaintext: Data, aad: Data
    ) throws -> Data {
        precondition(key.count == keyLen, "key must be \(keyLen) bytes")
        precondition(nonce.count == nonceLen, "nonce must be \(nonceLen) bytes")
        let symKey = SymmetricKey(data: key)
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: aesNonce, authenticating: aad)
        return sealed.ciphertext + sealed.tag
    }

    private static func aesGcmDecrypt(
        key: Data, nonce: Data, ciphertextWithTag: Data, aad: Data
    ) throws -> Data {
        precondition(key.count == keyLen, "key must be \(keyLen) bytes")
        precondition(nonce.count == nonceLen, "nonce must be \(nonceLen) bytes")
        guard ciphertextWithTag.count >= tagLen else {
            throw RatchetError.wireFormat("ciphertextWithTag too short")
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

    /// Pack wire bytes per spec §2.
    private static func packWire(
        epoch: String, dirFlag: UInt8, chainIdx: UInt64, ciphertextWithTag: Data
    ) throws -> Data {
        guard ciphertextWithTag.count >= tagLen else {
            throw RatchetError.wireFormat("wire payload missing GCM tag")
        }
        let epochBytes = Data(epoch.utf8)
        guard (1...255).contains(epochBytes.count) else {
            throw RatchetError.wireFormat("epoch length \(epochBytes.count) not in [1,255]")
        }
        var out = Data(capacity: 2 + epochBytes.count + 1 + 8 + ciphertextWithTag.count)
        out.append(magicV3)
        out.append(UInt8(epochBytes.count))
        out.append(epochBytes)
        out.append(dirFlag)
        for i in (0..<8).reversed() {
            out.append(UInt8((chainIdx >> (i * 8)) & 0xFF))
        }
        out.append(ciphertextWithTag)
        return out
    }

    private struct ParsedWire {
        let epoch: String
        let dirFlag: UInt8
        let chainIdx: UInt64
        let ciphertextWithTag: Data
    }

    private static func unpackWire(_ wire: Data) throws -> ParsedWire {
        guard !wire.isEmpty else { throw RatchetError.wireFormat("empty wire") }
        let base = wire.startIndex
        guard wire[base] == magicV3 else {
            throw RatchetError.wireFormat("bad magic byte (expected 0xE3)")
        }
        guard wire.count >= 2 else {
            throw RatchetError.wireFormat("wire too short for epoch_len byte")
        }
        let epochLen = Int(wire[base + 1])
        guard epochLen >= 1 else { throw RatchetError.wireFormat("epoch_len must be >= 1") }

        let headerBeforeDir = 2 + epochLen
        let minLen = headerBeforeDir + 1 + 8 + tagLen
        guard wire.count >= minLen else {
            throw RatchetError.wireFormat("wire too short: \(wire.count) < \(minLen)")
        }
        guard let epoch = String(data: wire.subdata(in: (base + 2)..<(base + 2 + epochLen)),
                                 encoding: .utf8) else {
            throw RatchetError.wireFormat("epoch not valid UTF-8")
        }
        let dirFlag = wire[base + headerBeforeDir]
        guard dirFlag == dirLoToHi || dirFlag == dirHiToLo else {
            throw RatchetError.wireFormat(String(format: "bad direction_flag 0x%02x", dirFlag))
        }
        let idxOff = base + headerBeforeDir + 1
        var chainIdx: UInt64 = 0
        for i in 0..<8 {
            chainIdx = (chainIdx << 8) | UInt64(wire[idxOff + i])
        }
        let ctOff = idxOff + 8
        let ctWithTag = wire.subdata(in: ctOff..<wire.endIndex)
        return ParsedWire(epoch: epoch, dirFlag: dirFlag,
                          chainIdx: chainIdx, ciphertextWithTag: ctWithTag)
    }

    // MARK: - Snapshot ↔ session

    private static func toSnapshot(_ s: RatchetSession) -> RatchetSnapshot {
        let entries = s.skippedKeys.map { (idx, sk) in
            RatchetSnapshot.SkippedEntry(idx: idx, key: sk.key, nonce: sk.nonce, expiresAtMs: sk.expiresAtMs)
        }
        return RatchetSnapshot(
            epochId: s.epochId,
            selfId: s.selfId,
            peerId: s.peerId,
            sendDirFlag: s.sendDirFlag,
            recvDirFlag: s.recvDirFlag,
            ckSend: s.ckSend,
            nextSendIdx: s.nextSendIdx,
            ckRecv: s.ckRecv,
            lastSeenRecvIdx: s.lastSeenRecvIdx,
            skipped: entries
        )
    }

    private static func toLiveSession(_ snap: RatchetSnapshot) -> RatchetSession {
        // Preserve insertion order (LRU eviction relies on it). The snapshot
        // already stored the entries in order; sort just by idx for safety.
        let ordered = snap.skipped.sorted { $0.idx < $1.idx }
        return RatchetSession(
            epochId: snap.epochId,
            selfId: snap.selfId,
            peerId: snap.peerId,
            sendDirFlag: snap.sendDirFlag,
            recvDirFlag: snap.recvDirFlag,
            ckSend: snap.ckSend,
            nextSendIdx: snap.nextSendIdx,
            ckRecv: snap.ckRecv,
            lastSeenRecvIdx: snap.lastSeenRecvIdx,
            skippedKeys: ordered.map { ($0.idx, SkippedKey(key: $0.key, nonce: $0.nonce, expiresAtMs: $0.expiresAtMs)) }
        )
    }
}
