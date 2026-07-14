import Foundation

/// Q-Audion Group Sender Keys (v3-group, magic 0xE4) — top-level session
/// manager. Direct port of Android's `qaudion-engine/.../crypto/
/// GroupSession.kt`. One `GroupState` per (group_id, group_epoch, self_id).
///
/// The session owns:
///  - exactly one OWN send chain (the chain we encrypt with)
///  - N-1 RECV chains (one per other group member, populated as their
///    `sender_key_init` / `sender_key_rotate` envelopes arrive)
///
/// **Cross-platform contract** with Android:
///  - Wire bytes / AAD / HKDF derivations all sit on `GroupSenderKey`
///    primitives (already byte-parity with Android — see W340).
///  - Envelope JSON shapes: `{qa_grp:1, t:"sender_key_init"|
///    "sender_key_rotate", g:<gid_hex>, e:<epoch>, seed:<base64>,
///    idx:<chain_idx>?}`. Sealed via the 1:1 ratchet on the
///    transport side.

// MARK: - State types

/// Per-sender chain — used both for our own send chain and for each
/// remote member's receive chain. Mirrors Android's `SenderChain`.
public final class GroupSenderChain {
    public var ck: Data            // 32-byte chain key
    public var nextIdx: UInt64
    public var lastSeenIdx: UInt64? // nil sentinel = "no message received yet"
    public var skipped: [(UInt64, GroupSkippedKey)]

    public init(ck: Data, nextIdx: UInt64, lastSeenIdx: UInt64?, skipped: [(UInt64, GroupSkippedKey)] = []) {
        self.ck = ck
        self.nextIdx = nextIdx
        self.lastSeenIdx = lastSeenIdx
        self.skipped = skipped
    }

    public static func newSend(ck: Data) -> GroupSenderChain {
        return GroupSenderChain(ck: ck, nextIdx: 0, lastSeenIdx: nil, skipped: [])
    }

    public static func newRecv(ck: Data, lastSeenIdx: UInt64?) -> GroupSenderChain {
        let nextIdx: UInt64 = lastSeenIdx.map { $0 &+ 1 } ?? 0
        return GroupSenderChain(ck: ck, nextIdx: nextIdx, lastSeenIdx: lastSeenIdx, skipped: [])
    }
}

public struct GroupSkippedKey: Equatable {
    public let key: Data
    public let nonce: Data
    public let expiresAtMs: Int64

    public init(key: Data, nonce: Data, expiresAtMs: Int64) {
        self.key = key
        self.nonce = nonce
        self.expiresAtMs = expiresAtMs
    }
}

/// Mutable per-(group, epoch, self) state.
public final class GroupState {
    public let groupIdBytes: Data
    public var groupEpoch: UInt32
    public var members: [String]
    public var admins: [String]
    public let selfId: String
    public var sendChain: GroupSenderChain
    /// Insertion-ordered map of senderId → recv chain.
    public var recvChains: [(String, GroupSenderChain)]

    public init(
        groupIdBytes: Data,
        groupEpoch: UInt32,
        members: [String],
        admins: [String],
        selfId: String,
        sendChain: GroupSenderChain,
        recvChains: [(String, GroupSenderChain)] = []
    ) {
        self.groupIdBytes = groupIdBytes
        self.groupEpoch = groupEpoch
        self.members = members
        self.admins = admins
        self.selfId = selfId
        self.sendChain = sendChain
        self.recvChains = recvChains
    }

    public func recvChain(for senderId: String) -> GroupSenderChain? {
        return recvChains.first(where: { $0.0 == senderId })?.1
    }

    public func setRecvChain(_ senderId: String, _ chain: GroupSenderChain) {
        if let idx = recvChains.firstIndex(where: { $0.0 == senderId }) {
            recvChains[idx] = (senderId, chain)
        } else {
            recvChains.append((senderId, chain))
        }
    }

    public func removeRecvChain(_ senderId: String) {
        recvChains.removeAll { $0.0 == senderId }
    }
}

// MARK: - Envelopes

public struct SenderKeyInitEnvelope: Codable, Equatable {
    public let qa_grp: Int
    public let t: String
    public let g: String       // group_id_hex
    public let e: UInt32       // group_epoch
    public let seed: String    // base64 of CK_current
    public let idx: UInt64     // sender's nextIdx (so recv installs lastSeen = idx-1)

    public init(qa_grp: Int = 1, t: String = "sender_key_init", g: String, e: UInt32, seed: String, idx: UInt64) {
        self.qa_grp = qa_grp; self.t = t; self.g = g; self.e = e; self.seed = seed; self.idx = idx
    }
}

public struct SenderKeyRotateEnvelope: Codable, Equatable {
    public let qa_grp: Int
    public let t: String
    public let g: String
    public let e: UInt32
    public let seed: String

    public init(qa_grp: Int = 1, t: String = "sender_key_rotate", g: String, e: UInt32, seed: String) {
        self.qa_grp = qa_grp; self.t = t; self.g = g; self.e = e; self.seed = seed
    }
}

public struct GroupEncryptResult: Equatable {
    public let wire: Data
    public let chainIdx: UInt64
}

public struct GroupRotatePackage: Equatable {
    public let rotateEnvelope: SenderKeyRotateEnvelope
    public let newSelfSeed: Data
}

public struct GroupMemberAddedPackage: Equatable {
    public let initForNewMember: SenderKeyInitEnvelope
}

// MARK: - Vault

public protocol GroupSessionVault: AnyObject {
    func save(_ state: GroupState)
    func load(groupIdBytes: Data, groupEpoch: UInt32, selfId: String) -> GroupState?
}

public final class InMemoryGroupSessionVault: GroupSessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: GroupState] = [:]

    public init() {}

    public func save(_ state: GroupState) {
        lock.lock()
        store[Self.key(state.groupIdBytes, state.groupEpoch, state.selfId)] = state
        lock.unlock()
    }

    public func load(groupIdBytes: Data, groupEpoch: UInt32, selfId: String) -> GroupState? {
        lock.lock(); defer { lock.unlock() }
        return store[Self.key(groupIdBytes, groupEpoch, selfId)]
    }

    private static func key(_ gid: Data, _ epoch: UInt32, _ selfId: String) -> String {
        return "\(GroupSenderKey.toHex(gid))|\(epoch)|\(selfId)"
    }
}

// MARK: - GroupSession

public final class GroupSession {

    public enum SessionError: Error, Equatable {
        case selfNotMember(String)
        case envelopeMismatch(String)
        case alreadyMember(String)
        case notMember(String)
        case rejectOwnSenderInstall
        case ratchet(String)
    }

    private let vault: GroupSessionVault?

    public init(vault: GroupSessionVault? = nil) {
        self.vault = vault
    }

    // MARK: - create

    /// Bootstrap a brand-new group. Recv chains are EMPTY — they get
    /// populated as `sender_key_init` envelopes arrive from the other
    /// members through the 1:1 ratchet.
    public func create(
        groupIdBytes: Data,
        groupEpoch: UInt32 = 1,
        members: [String],
        admins: [String] = [],
        selfId: String,
        selfSeed: Data? = nil
    ) throws -> GroupState {
        guard members.contains(selfId) else {
            throw SessionError.selfNotMember(selfId)
        }
        let seed: Data
        if let s = selfSeed {
            guard s.count == GroupSenderKey.keyLen else {
                throw SessionError.ratchet("selfSeed must be \(GroupSenderKey.keyLen) bytes")
            }
            seed = s
        } else {
            seed = Self.randomBytes(GroupSenderKey.keyLen)
        }
        let ck0 = try GroupSenderKey.deriveInitChainKey(
            skSeed: seed, groupIdBytes: groupIdBytes, senderId: selfId)
        let state = GroupState(
            groupIdBytes: groupIdBytes,
            groupEpoch: groupEpoch,
            members: members,
            admins: admins,
            selfId: selfId,
            sendChain: GroupSenderChain.newSend(ck: ck0)
        )
        persist(state)
        return state
    }

    // MARK: - sender-key install / rotate

    public func handleSenderKeyInit(state: GroupState, env: SenderKeyInitEnvelope, fromUserId: String) throws {
        guard env.qa_grp == 1, env.t == "sender_key_init" else {
            throw SessionError.envelopeMismatch("not a sender_key_init envelope")
        }
        guard fromUserId != state.selfId else {
            throw SessionError.rejectOwnSenderInstall
        }
        guard env.g == GroupSenderKey.toHex(state.groupIdBytes) else {
            throw SessionError.envelopeMismatch("envelope group_id mismatch")
        }
        guard env.e == state.groupEpoch else {
            throw SessionError.envelopeMismatch("envelope epoch mismatch")
        }
        guard let ckBytes = Data(base64Encoded: env.seed),
              ckBytes.count == GroupSenderKey.keyLen else {
            throw SessionError.envelopeMismatch("seed must be \(GroupSenderKey.keyLen) bytes")
        }
        let lastSeen: UInt64? = (env.idx == 0) ? nil : (env.idx - 1)
        state.setRecvChain(fromUserId, GroupSenderChain.newRecv(ck: ckBytes, lastSeenIdx: lastSeen))
        persist(state)
    }

    public func handleSenderKeyRotate(state: GroupState, env: SenderKeyRotateEnvelope, fromUserId: String) throws {
        guard env.qa_grp == 1, env.t == "sender_key_rotate" else {
            throw SessionError.envelopeMismatch("not a sender_key_rotate envelope")
        }
        guard fromUserId != state.selfId else {
            throw SessionError.rejectOwnSenderInstall
        }
        guard env.g == GroupSenderKey.toHex(state.groupIdBytes) else {
            throw SessionError.envelopeMismatch("envelope group_id mismatch")
        }
        guard env.e == state.groupEpoch else {
            throw SessionError.envelopeMismatch("envelope epoch mismatch")
        }
        guard let seed = Data(base64Encoded: env.seed), seed.count == GroupSenderKey.keyLen else {
            throw SessionError.envelopeMismatch("seed must be \(GroupSenderKey.keyLen) bytes")
        }
        let ck0 = try GroupSenderKey.deriveInitChainKey(
            skSeed: seed, groupIdBytes: state.groupIdBytes, senderId: fromUserId)
        state.setRecvChain(fromUserId, GroupSenderChain.newRecv(ck: ck0, lastSeenIdx: nil))
        persist(state)
    }

    /// Manual self-rotate (admin-driven periodic rekey). Generates a fresh
    /// seed and rebinds our send chain. Caller is expected to broadcast
    /// the `sender_key_rotate` envelope to every OTHER member via 1:1.
    public func rotateOwnSenderKey(state: GroupState, freshSeed: Data? = nil) throws -> GroupRotatePackage {
        let seed: Data
        if let s = freshSeed {
            guard s.count == GroupSenderKey.keyLen else {
                throw SessionError.ratchet("freshSeed must be \(GroupSenderKey.keyLen) bytes")
            }
            seed = s
        } else {
            seed = Self.randomBytes(GroupSenderKey.keyLen)
        }
        let newCk = try GroupSenderKey.deriveInitChainKey(
            skSeed: seed, groupIdBytes: state.groupIdBytes, senderId: state.selfId)
        state.sendChain = GroupSenderChain.newSend(ck: newCk)
        persist(state)
        return GroupRotatePackage(
            rotateEnvelope: SenderKeyRotateEnvelope(
                g: GroupSenderKey.toHex(state.groupIdBytes),
                e: state.groupEpoch,
                seed: seed.base64EncodedString()
            ),
            newSelfSeed: seed
        )
    }

    // MARK: - encrypt / decrypt

    /// Encrypt `plaintext` for the group using our send chain. Mutates
    /// state and persists BEFORE returning (write-ahead invariant).
    public func encryptForGroup(state: GroupState, plaintext: Data, clientMsgId: String = "") throws -> GroupEncryptResult {
        let idxAtSend = state.sendChain.nextIdx
        let (msgKey, nonce) = GroupSenderKey.deriveMsgKeys(ck: state.sendChain.ck)
        let aad = GroupSenderKey.buildGroupAd(
            groupIdBytes: state.groupIdBytes, senderId: state.selfId, chainIdx: idxAtSend)
        let ctWithTag = try GroupSenderKey.aesGcmEncrypt(
            key: msgKey, nonce: nonce, plaintext: plaintext, aad: aad)
        let wire = try GroupSenderKey.packGroupWire(
            groupIdBytes: state.groupIdBytes,
            groupEpoch: state.groupEpoch,
            senderId: state.selfId,
            chainIdx: idxAtSend,
            nonce: nonce,
            ciphertextWithTag: ctWithTag
        )
        state.sendChain.ck = GroupSenderKey.stepChain(ck: state.sendChain.ck)
        state.sendChain.nextIdx = idxAtSend &+ 1
        persist(state)
        return GroupEncryptResult(wire: wire, chainIdx: idxAtSend)
    }

    /// Decrypt a wire blob from `senderId`. Returns nil on any auth
    /// failure / replay / unknown sender / wire malformation. Production
    /// callers should prefer this over `decryptFromGroupOrThrow`.
    public func decryptFromGroup(state: GroupState, senderId: String, wire: Data, nowMs: Int64? = nil) -> Data? {
        do { return try decryptFromGroupOrThrow(state: state, senderId: senderId, wire: wire, nowMs: nowMs) }
        catch { return nil }
    }

    public func decryptFromGroupOrThrow(state: GroupState, senderId: String, wire: Data, nowMs: Int64? = nil) throws -> Data {
        let parsed = try GroupSenderKey.unpackGroupWire(wire)
        guard parsed.groupId == state.groupIdBytes else {
            throw SessionError.ratchet("group_id mismatch")
        }
        guard parsed.groupEpoch == state.groupEpoch else {
            throw SessionError.ratchet("group_epoch mismatch: wire=\(parsed.groupEpoch) state=\(state.groupEpoch)")
        }
        guard parsed.senderId == senderId else {
            throw SessionError.ratchet("sender_id mismatch")
        }
        guard let recv = state.recvChain(for: senderId) else {
            throw SessionError.ratchet("unknown sender for this group/epoch: \(senderId)")
        }
        let aad = GroupSenderKey.buildGroupAd(
            groupIdBytes: state.groupIdBytes, senderId: senderId, chainIdx: parsed.chainIdx)
        let ctWithTag = parsed.ciphertext + parsed.tag
        let incoming = parsed.chainIdx
        let lastSeen = recv.lastSeenIdx
        let now = nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)

        // Late delivery → skipped-cache lookup.
        if let ls = lastSeen, incoming <= ls {
            guard let pos = recv.skipped.firstIndex(where: { $0.0 == incoming }) else {
                throw SessionError.ratchet("replay or unknown message at idx=\(incoming) (last_seen=\(ls))")
            }
            let entry = recv.skipped.remove(at: pos).1
            guard entry.nonce == parsed.nonce else {
                recv.skipped.append((incoming, entry))
                throw SessionError.ratchet("skipped-cache nonce mismatch at idx=\(incoming)")
            }
            do {
                let pt = try GroupSenderKey.aesGcmDecrypt(
                    key: entry.key, nonce: entry.nonce, ciphertextWithTag: ctWithTag, aad: aad)
                persist(state)
                return pt
            } catch {
                recv.skipped.append((incoming, entry))
                throw SessionError.ratchet("skipped-cache AEAD failed at idx=\(incoming)")
            }
        }

        // Skip-ahead → derive + cache the missing keys.
        let expected: UInt64 = lastSeen.map { $0 &+ 1 } ?? 0
        if incoming > expected {
            let skipCount = incoming - expected
            guard skipCount <= GroupSenderKey.maxSkipAhead else {
                throw SessionError.ratchet("skip-ahead \(skipCount) exceeds MAX_SKIP_AHEAD=\(GroupSenderKey.maxSkipAhead)")
            }
            var cursor = recv.ck
            let expiresAt = now + GroupSenderKey.skippedKeysTtlMs
            var j = expected
            while j < incoming {
                let (mk, nc) = GroupSenderKey.deriveMsgKeys(ck: cursor)
                recv.skipped.append((j, GroupSkippedKey(key: mk, nonce: nc, expiresAtMs: expiresAt)))
                cursor = GroupSenderKey.stepChain(ck: cursor)
                j &+= 1
            }
            recv.ck = cursor
            evictExpired(recv: recv, nowMs: now)
            evictLruOverflow(recv: recv)
        }

        // In-order or just-caught-up.
        let (msgKey, derivedNonce) = GroupSenderKey.deriveMsgKeys(ck: recv.ck)
        guard derivedNonce == parsed.nonce else {
            throw SessionError.ratchet("derived-nonce vs wire-nonce mismatch at idx=\(incoming)")
        }
        let pt: Data
        do {
            pt = try GroupSenderKey.aesGcmDecrypt(
                key: msgKey, nonce: derivedNonce, ciphertextWithTag: ctWithTag, aad: aad)
        } catch {
            throw SessionError.ratchet("AEAD decrypt failed at idx=\(incoming)")
        }
        recv.ck = GroupSenderKey.stepChain(ck: recv.ck)
        recv.lastSeenIdx = incoming
        recv.nextIdx = incoming &+ 1
        persist(state)
        return pt
    }

    // MARK: - Membership ops

    public func handleMemberAdded(state: GroupState, newMember: String) throws -> GroupMemberAddedPackage {
        guard !state.members.contains(newMember) else {
            throw SessionError.alreadyMember(newMember)
        }
        state.members.append(newMember)
        persist(state)
        return GroupMemberAddedPackage(
            initForNewMember: SenderKeyInitEnvelope(
                g: GroupSenderKey.toHex(state.groupIdBytes),
                e: state.groupEpoch,
                seed: state.sendChain.ck.base64EncodedString(),
                idx: state.sendChain.nextIdx
            )
        )
    }

    public func handleMemberRemoved(state: GroupState, removed: String, freshSelfSeed: Data? = nil) throws -> GroupRotatePackage {
        guard state.members.contains(removed) else {
            throw SessionError.notMember(removed)
        }
        let seed: Data
        if let s = freshSelfSeed {
            guard s.count == GroupSenderKey.keyLen else {
                throw SessionError.ratchet("freshSelfSeed must be \(GroupSenderKey.keyLen) bytes")
            }
            seed = s
        } else {
            seed = Self.randomBytes(GroupSenderKey.keyLen)
        }
        state.members.removeAll { $0 == removed }
        state.removeRecvChain(removed)
        state.groupEpoch = state.groupEpoch &+ 1

        let newCk = try GroupSenderKey.deriveInitChainKey(
            skSeed: seed, groupIdBytes: state.groupIdBytes, senderId: state.selfId)
        state.sendChain = GroupSenderChain.newSend(ck: newCk)
        // Drop all existing recv chains — they're tied to the OLD epoch.
        state.recvChains.removeAll()
        persist(state)
        return GroupRotatePackage(
            rotateEnvelope: SenderKeyRotateEnvelope(
                g: GroupSenderKey.toHex(state.groupIdBytes),
                e: state.groupEpoch,
                seed: seed.base64EncodedString()
            ),
            newSelfSeed: seed
        )
    }

    // MARK: - LiveKit SFU media-key sink (non-mutating reads)

    /// NON-MUTATING read of our OWN current send-chain key (a COPY). Used as
    /// the LiveKit SFU media key sink: under the SFU, `encryptForGroup` is
    /// NOT called for media, so `sendChain.ck` never advances per-frame and
    /// equals `SK_0` for the current epoch. Feeding `base64(SK_0)` to the
    /// LiveKit key provider (keyed under our own userId) makes every
    /// receiver derive the identical per-participant AES-128-GCM frame key.
    /// Returns `nil` if the send chain is empty (should never happen for a
    /// bootstrapped state). Does NOT step the ratchet — callers get a
    /// defensive copy. Mirrors Desktop `GroupSession.currentSendKey`
    /// (`src/main/crypto/GroupSession.ts`) — must stay behaviourally
    /// identical cross-platform.
    public func currentSendKey(state: GroupState) -> Data? {
        let ck = state.sendChain.ck
        guard !ck.isEmpty else { return nil }
        return Data(ck)
    }

    /// NON-MUTATING read of a remote sender's current recv-chain key (a
    /// COPY), i.e. the `SK_0` we installed from their `sender_key_init` /
    /// `_rotate`. The LiveKit media key for that participant's frames is
    /// `base64(SK_0)` keyed under THAT sender's userId. Returns `nil` when
    /// we have not yet installed a chain for `senderId` (their bootstrap
    /// envelope has not arrived). Does NOT step the ratchet. Mirrors
    /// Desktop `GroupSession.currentRecvKey`.
    public func currentRecvKey(state: GroupState, senderId: String) -> Data? {
        guard let chain = state.recvChain(for: senderId), !chain.ck.isEmpty else { return nil }
        return Data(chain.ck)
    }

    public func gc(state: GroupState, nowMs: Int64? = nil) {
        let now = nowMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        var dirty = false
        for (_, recv) in state.recvChains {
            let before = recv.skipped.count
            evictExpired(recv: recv, nowMs: now)
            evictLruOverflow(recv: recv)
            if recv.skipped.count != before { dirty = true }
        }
        if dirty { persist(state) }
    }

    // MARK: - Internal

    private func persist(_ state: GroupState) {
        vault?.save(state)
    }

    private func evictExpired(recv: GroupSenderChain, nowMs: Int64) {
        recv.skipped.removeAll { $0.1.expiresAtMs <= nowMs }
    }

    private func evictLruOverflow(recv: GroupSenderChain) {
        while recv.skipped.count > GroupSenderKey.skippedKeysCacheMax {
            recv.skipped.removeFirst()
        }
    }

    private static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, n, base) == errSecSuccess ? 0 : -1
        }
        return d
    }
}
