import Foundation
import CryptoKit
import QAudionEngine

/// W371 — top-level group-chat bridge.
/// W390 (deep-fix #2/4) — REAL `sender_key_init` distribution. The
/// previous transitional path bootstrapped each member's send chain
/// from a deterministic SHA-256(groupId || label) seed so peers could
/// agree on CK_0 without signaling. That works for symmetric crypto
/// agreement but it is **not** the cross-platform protocol Android
/// implements — and crucially it gives every member of a group the
/// same send-chain seed, breaking sender attribution and PCS.
///
/// The REAL protocol (matches Android, FIPS-style sender-key trees):
///   1. Each member generates their OWN random 32-byte seed.
///   2. The member ships a `sender_key_init` envelope (`qa_grp:1`)
///      to every OTHER member, wrapped in the 1:1 ratchet (so the
///      seed is forward-secret under the per-pair PSK).
///   3. Recipients call `engine.handleSenderKeyInit(...)` to install
///      the sender's recv chain — exact same engine API the Android
///      implementation uses.
///   4. Group messages then ride the 0xE4 wire envelope using each
///      member's independent send chain — sender_id in the AAD makes
///      attribution unambiguous, and a per-member rotate is local
///      (no all-members re-keying required).
///
/// **Wire format:** every group message rides the GroupSenderKey
/// 0xE4 wire envelope (W340 + W345). The outer transport is a fan-out
/// of `opaque_message` frames — one per remaining member — bound to
/// the per-pair PSK / v3 ratchet on the 1:1 layer.
///
/// **Backward compatibility:** if a peer hasn't received our init
/// envelope yet (offline at create-time) and we ship a group msg, the
/// recipient gets the wire bytes but `decryptFromGroup` returns nil
/// (no recv chain installed). The `msg_pending_sync` queue delivers
/// the init envelope on reconnect; the message can be retried, OR the
/// fan-out logic ships init+message back-to-back so the init lands
/// first in store-and-forward order.
@MainActor
public final class GroupChatService {

    public static let shared = GroupChatService()

    private static let vault: GroupSessionVault = KeychainGroupSessionVault()
    private let engine: GroupSession = GroupSession(vault: GroupChatService.vault)

    private var sessions: [String: GroupState] = [:]   // groupId → state

    /// Tracks which (groupId, recipientId) pairs have already received
    /// our `sender_key_init` envelope so we don't re-emit on every
    /// send. Survives a session as long as the AppState lives;
    /// persistence across launches is handled by the engine's vault
    /// (if recv chains for that recipient are installed, they keep
    /// our send chain → no re-init needed).
    private var shippedInits: [String: Set<String>] = [:]

    /// W395 — buffer-and-replay for inbound `sender_key_init` /
    /// `sender_key_rotate` envelopes that arrive before the local
    /// user has joined the group (and therefore before
    /// loadExistingSession returns a state). Keyed by groupId; each
    /// pending entry remembers the senderId, the envelope JSON, and
    /// the type ("sender_key_init" / "sender_key_rotate"). When the
    /// local user later bootstraps the group via session(...), the
    /// buffered envelopes are replayed in arrival order.
    private struct BufferedCtl: Equatable {
        let fromUserId: String
        let envelopeJson: String
        let kind: String   // "sender_key_init" | "sender_key_rotate"
    }
    private var bufferedInits: [String: [BufferedCtl]] = [:]

    public init() {}

    public struct PendingSenderKeyInit: Equatable {
        public let recipientId: String
        /// JSON-encoded `SenderKeyInitEnvelope` payload that the caller
        /// must wrap into a 1:1 chat ciphertext (existing PSK / v3
        /// ratchet path) and ship via `ChatMessageSendService`.
        public let envelopeJson: String
    }

    /// Convert a hex group id (the on-wire form) to its raw bytes.
    private func bytes(for groupId: String) -> Data? {
        return try? GroupSenderKey.fromHex(groupId)
    }

    /// Look up an existing session WITHOUT bootstrapping. Returns nil
    /// if neither the in-memory cache nor the vault has a snapshot for
    /// this (groupId, selfId). Used by inbound `sender_key_init`
    /// handlers — we don't want to bootstrap a session for a group the
    /// local user hasn't joined yet (would race with the membership
    /// signaling layer).
    private func loadExistingSession(groupId: String, selfId: String) -> GroupState? {
        if let cached = sessions[groupId] { return cached }
        guard let gid = bytes(for: groupId), !selfId.isEmpty else { return nil }
        if let existing = Self.vault.load(groupIdBytes: gid, groupEpoch: 1, selfId: selfId) {
            sessions[groupId] = existing
            return existing
        }
        return nil
    }

    /// Lazy-init or recover a `GroupState` for the given group + self
    /// id. Loads from KeychainGroupSessionVault if a snapshot exists,
    /// otherwise bootstraps a fresh session with a random seed (W390 —
    /// no more deterministic shortcut).
    /// Returns the state if the session is valid; nil on bad input.
    public func session(groupId: String, members: [String], selfId: String) -> GroupState? {
        if let cached = sessions[groupId] { return cached }
        guard let gid = bytes(for: groupId), !members.contains(where: { $0.isEmpty }), !selfId.isEmpty else {
            return nil
        }
        if let existing = Self.vault.load(groupIdBytes: gid, groupEpoch: 1, selfId: selfId) {
            sessions[groupId] = existing
            // W395 — replay any buffered ctl envelopes that arrived
            // before this session was bootstrapped.
            replayBufferedCtl(groupId: groupId, state: existing, selfId: selfId)
            return existing
        }
        // Fresh session — random seed (W390). The matching
        // sender_key_init envelopes for every other member are
        // produced by `pendingInitsAfterBootstrap(...)`.
        do {
            let state = try engine.create(
                groupIdBytes: gid,
                groupEpoch: 1,
                members: members,
                admins: [],
                selfId: selfId,
                selfSeed: nil // engine generates 32 bytes via SecureRandom
            )
            sessions[groupId] = state
            // W395 — replay any inbound ctl envelopes that arrived
            // before our local bootstrap.
            replayBufferedCtl(groupId: groupId, state: state, selfId: selfId)
            return state
        } catch {
            print("[GroupChatService] session create failed: \(error)")
            return nil
        }
    }

    /// W395 — drain buffered sender_key_{init,rotate} envelopes for
    /// the freshly-bootstrapped session. Called from session(...)
    /// after a successful create / vault-load. FIFO order so the
    /// install/rotate sequence the senders shipped is preserved.
    private func replayBufferedCtl(groupId: String, state: GroupState, selfId: String) {
        guard let buffered = bufferedInits.removeValue(forKey: groupId), !buffered.isEmpty else {
            return
        }
        print("[GroupChatService] replaying \(buffered.count) buffered ctl envelopes for group \(groupId)")
        for entry in buffered {
            switch entry.kind {
            case "sender_key_init":
                if let data = entry.envelopeJson.data(using: .utf8),
                   let env = try? JSONDecoder().decode(SenderKeyInitEnvelope.self, from: data) {
                    do { try engine.handleSenderKeyInit(state: state, env: env, fromUserId: entry.fromUserId) }
                    catch { print("[GroupChatService] replay sender_key_init failed: \(error)") }
                }
            case "sender_key_rotate":
                if let data = entry.envelopeJson.data(using: .utf8),
                   let env = try? JSONDecoder().decode(SenderKeyRotateEnvelope.self, from: data) {
                    do { try engine.handleSenderKeyRotate(state: state, env: env, fromUserId: entry.fromUserId) }
                    catch { print("[GroupChatService] replay sender_key_rotate failed: \(error)") }
                }
            default:
                break
            }
        }
    }

    /// Byte-exact inputs for a `group_msg_send` frame: the raw 0xE4
    /// wire bytes PLUS the epoch to stamp on the frame (mirrors
    /// Android's `state.groupEpoch.toInt()` in SendGroupMessageUseCase).
    /// Returns nil if the group session can't be loaded/bootstrapped or
    /// the engine encrypt fails.
    public func encryptForWire(plaintext: String, groupId: String, members: [String], selfId: String) -> (wire: Data, groupEpoch: UInt32)? {
        guard let state = session(groupId: groupId, members: members, selfId: selfId) else {
            return nil
        }
        do {
            let result = try engine.encryptForGroup(state: state, plaintext: Data(plaintext.utf8))
            return (result.wire, state.groupEpoch)
        } catch {
            print("[GroupChatService] encryptForWire failed: \(error)")
            return nil
        }
    }

    /// Decrypt a wire blob received from `senderId`. Returns the UTF-8
    /// plaintext, or nil on AEAD / replay / unknown-sender failure.
    /// **Note**: returns nil if no recv chain is installed for senderId
    /// (i.e. their `sender_key_init` envelope hasn't arrived yet). The
    /// caller can then queue the wire blob for retry.
    public func decrypt(wire: Data, senderId: String, groupId: String, members: [String], selfId: String) -> String? {
        guard let state = session(groupId: groupId, members: members, selfId: selfId) else {
            return nil
        }
        guard let pt = engine.decryptFromGroup(state: state, senderId: senderId, wire: wire) else {
            return nil
        }
        return String(data: pt, encoding: .utf8)
    }

    /// Drop the cached state for a group. Used after `handleMemberRemoved`
    /// + epoch bump so the next message rebuilds. W395: also clears
    /// the buffered-ctl queue so a stale init from before the epoch
    /// bump doesn't get replayed against the new chain.
    public func invalidate(groupId: String) {
        sessions.removeValue(forKey: groupId)
        shippedInits.removeValue(forKey: groupId)
        bufferedInits.removeValue(forKey: groupId)
    }

    // MARK: - W390 sender_key_init distribution

    /// Returns the list of `sender_key_init` envelopes that must be
    /// shipped via 1:1 ratchet to every other member of the group so
    /// they can install OUR send chain on their side.
    ///
    /// Idempotent: tracks which recipients have already been shipped
    /// and only returns the missing ones. When all members have been
    /// shipped, returns an empty list.
    ///
    /// Caller protocol:
    ///   1. Before the first `encrypt(...)` for a group, call this.
    ///   2. For each PendingSenderKeyInit, ship the JSON via the
    ///      existing 1:1 ratchet path (ChatMessageSendService). The
    ///      recipient's chat dispatcher detects the `qa_grp:1` marker
    ///      and routes to `handleInboundSenderKeyInit(...)`.
    ///   3. Then ship the actual encrypted group message wire bytes.
    public func pendingInitsAfterBootstrap(groupId: String, members: [String], selfId: String) -> [PendingSenderKeyInit] {
        guard let state = session(groupId: groupId, members: members, selfId: selfId) else {
            return []
        }
        let already = shippedInits[groupId] ?? Set<String>()
        let recipients = members.filter { $0 != selfId && !already.contains($0) }
        guard !recipients.isEmpty else { return [] }

        // Build the SenderKeyInitEnvelope from our send chain. The seed
        // we ship is the CURRENT chain key (CK_n) — the recipient's
        // engine.handleSenderKeyInit installs lastSeen = idx-1, so they
        // pick up exactly where we are.
        let env = SenderKeyInitEnvelope(
            g: GroupSenderKey.toHex(state.groupIdBytes),
            e: state.groupEpoch,
            seed: state.sendChain.ck.base64EncodedString(),
            idx: state.sendChain.nextIdx
        )
        guard let jsonData = try? JSONEncoder().encode(env),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return []
        }

        var pending: [PendingSenderKeyInit] = []
        var newSet = already
        for r in recipients {
            pending.append(PendingSenderKeyInit(recipientId: r, envelopeJson: jsonString))
            newSet.insert(r)
        }
        shippedInits[groupId] = newSet
        return pending
    }

    /// Called by AppState's 1:1 chat inbound dispatcher when the
    /// decrypted plaintext parses as `{qa_grp:1, t:"sender_key_init", ...}`.
    /// Installs the sender's recv chain on our local GroupState so we
    /// can subsequently decrypt their group messages.
    public func handleInboundSenderKeyInit(
        envelopeJson: String,
        fromUserId: String,
        selfId: String
    ) {
        guard let data = envelopeJson.data(using: .utf8),
              let env = try? JSONDecoder().decode(SenderKeyInitEnvelope.self, from: data) else {
            print("[GroupChatService] handleInboundSenderKeyInit: malformed JSON from \(fromUserId)")
            return
        }
        // W395: if no local session yet, BUFFER instead of drop. When
        // the local user later joins (via session(...) bootstrap), the
        // engine.handleSenderKeyInit is replayed in arrival order.
        guard let state = loadExistingSession(groupId: env.g, selfId: selfId) else {
            bufferCtl(groupId: env.g, fromUserId: fromUserId,
                      envelopeJson: envelopeJson, kind: "sender_key_init")
            return
        }
        do {
            try engine.handleSenderKeyInit(state: state, env: env, fromUserId: fromUserId)
        } catch {
            print("[GroupChatService] handleInboundSenderKeyInit failed (group=\(env.g), from=\(fromUserId)): \(error)")
        }
    }

    /// Companion to `handleInboundSenderKeyInit` for periodic rotates
    /// (admin-driven re-key). Same wire shape but `t` is
    /// `sender_key_rotate` and the envelope carries the seed (not the
    /// current chain-key snapshot).
    public func handleInboundSenderKeyRotate(
        envelopeJson: String,
        fromUserId: String,
        selfId: String
    ) {
        guard let data = envelopeJson.data(using: .utf8),
              let env = try? JSONDecoder().decode(SenderKeyRotateEnvelope.self, from: data) else {
            print("[GroupChatService] handleInboundSenderKeyRotate: malformed JSON from \(fromUserId)")
            return
        }
        guard let state = loadExistingSession(groupId: env.g, selfId: selfId) else {
            // W395 — same buffering as init.
            bufferCtl(groupId: env.g, fromUserId: fromUserId,
                      envelopeJson: envelopeJson, kind: "sender_key_rotate")
            return
        }
        do {
            try engine.handleSenderKeyRotate(state: state, env: env, fromUserId: fromUserId)
        } catch {
            print("[GroupChatService] handleInboundSenderKeyRotate failed (group=\(env.g), from=\(fromUserId)): \(error)")
        }
    }

    /// W395 — append a ctl envelope to the buffer for a not-yet-
    /// bootstrapped group. Bounded at 32 entries per group so a flood
    /// of inits from a stranger can't OOM the device. Oldest entry
    /// is dropped on overflow.
    private func bufferCtl(groupId: String, fromUserId: String, envelopeJson: String, kind: String) {
        var arr = bufferedInits[groupId] ?? []
        arr.append(BufferedCtl(fromUserId: fromUserId, envelopeJson: envelopeJson, kind: kind))
        if arr.count > 32 {
            arr.removeFirst(arr.count - 32)
        }
        bufferedInits[groupId] = arr
        print("[GroupChatService] buffered \(kind) for group \(groupId) from \(fromUserId) (queue depth = \(arr.count))")
    }

    /// Lightweight detector for the 1:1 chat inbound dispatcher.
    /// Returns the envelope type (`"sender_key_init"` or
    /// `"sender_key_rotate"`) if the plaintext parses as a
    /// `qa_grp:1` envelope, else nil. Lets the dispatcher decide
    /// routing without fully decoding the structure twice.
    public static func detectGroupCtlType(_ plaintext: String) -> String? {
        guard let data = plaintext.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qa = obj["qa_grp"] as? Int, qa == 1,
              let t = obj["t"] as? String else {
            return nil
        }
        return t
    }
}
