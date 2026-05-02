import Foundation
import CryptoKit
import QAudionEngine

/// W371 — top-level group-chat bridge.
///
/// Owns one [GroupSession] per active group (lazy-init, persisted via
/// the W364 KeychainGroupSessionVault). Provides `send` / `receive`
/// entry points so GroupChatScreen and the AppState dispatcher can
/// stop being beta-banner-only.
///
/// **Wire format:** every group message rides the GroupSenderKey
/// 0xE4 wire envelope (W340 + W345). The outer transport is a fan-out
/// of `opaque_message` frames — one per remaining member — bound to
/// the per-pair PSK / v3 ratchet on the 1:1 layer. This means a
/// member who isn't online when the message is sent gets it on
/// reconnect via `msg_pending_sync` like any other message.
///
/// **Bootstrap key:** the room key for the GroupSession is bootstrapped
/// from the same deterministic SHA-256(callId || "qaudion-group-v1")
/// the W354 GroupCallController uses, so all members agree on the
/// chain seed without any extra signaling. PCS at membership-change
/// time is provided by the W345 `handleMemberRemoved` epoch bump.
@MainActor
public final class GroupChatService {

    public static let shared = GroupChatService()

    private static let vault: GroupSessionVault = KeychainGroupSessionVault()
    private let engine: GroupSession = GroupSession(vault: GroupChatService.vault)

    private var sessions: [String: GroupState] = [:]   // groupId → state

    public init() {}

    /// Convert a hex group id (the on-wire form) to its raw bytes.
    private func bytes(for groupId: String) -> Data? {
        return try? GroupSenderKey.fromHex(groupId)
    }

    /// Lazy-init or recover a `GroupState` for the given group + self
    /// id. Loads from KeychainGroupSessionVault if a snapshot exists,
    /// otherwise bootstraps a fresh session with the deterministic
    /// per-group seed (so iOS, Android, Desktop all derive the same
    /// CK_0 without coordination).
    public func session(groupId: String, members: [String], selfId: String) -> GroupState? {
        if let cached = sessions[groupId] { return cached }
        guard let gid = bytes(for: groupId), !members.contains(where: { $0.isEmpty }), !selfId.isEmpty else {
            return nil
        }
        if let existing = Self.vault.load(groupIdBytes: gid, groupEpoch: 1, selfId: selfId) {
            // Vault returned an already-live GroupState (the protocol
            // is "engine-owned snapshot"; iOS impl uses a codec
            // round-trip but the public type stays GroupState).
            sessions[groupId] = existing
            return existing
        }
        // Fresh session — derive a deterministic seed (so peers agree).
        let seed = Self.deterministicSeed(groupId: groupId)
        do {
            let state = try engine.create(
                groupIdBytes: gid,
                groupEpoch: 1,
                members: members,
                admins: [],
                selfId: selfId,
                selfSeed: seed
            )
            sessions[groupId] = state
            return state
        } catch {
            print("[GroupChatService] session create failed: \(error)")
            return nil
        }
    }

    /// Encrypt a UTF-8 plaintext for the group. Returns the wire
    /// bytes (magic 0xE4 envelope) ready to be base64'd into an
    /// `opaque_message` fan-out.
    public func encrypt(plaintext: String, groupId: String, members: [String], selfId: String) -> Data? {
        guard let state = session(groupId: groupId, members: members, selfId: selfId) else {
            return nil
        }
        let pt = Data(plaintext.utf8)
        do {
            let result = try engine.encryptForGroup(state: state, plaintext: pt)
            return result.wire
        } catch {
            print("[GroupChatService] encrypt failed: \(error)")
            return nil
        }
    }

    /// Decrypt a wire blob received from `senderId`. Returns the UTF-8
    /// plaintext, or nil on AEAD / replay / unknown-sender failure.
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
    /// + epoch bump so the next message rebuilds.
    public func invalidate(groupId: String) {
        sessions.removeValue(forKey: groupId)
    }

    // MARK: - Helpers

    /// Bootstrap seed = SHA-256(groupId || "qaudion-group-chat-v1") so
    /// every member arrives at the same CK_0 without signaling. Same
    /// strategy GroupCallController uses for the room key (W354), with
    /// a different label so the chat seed and call key don't collide.
    private static func deterministicSeed(groupId: String) -> Data {
        var ikm = Data(groupId.utf8)
        ikm.append(Data("qaudion-group-chat-v1".utf8))
        return Data(SHA256.hash(data: ikm))
    }

}
