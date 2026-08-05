import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain-backed [GroupSessionVault]. Persists each
/// `(groupId, groupEpoch, selfId)` snapshot under its own keychain
/// item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Mirror
/// of the 1:1 `KeychainRatchetVault` (W357) for group sessions.
///
/// **Key derivation**: account string =
/// `<groupIdHex>|<groupEpoch>|<selfId>`. Service =
/// `com.bcrypto.qaudion.group.v1` so a future migration that drops
/// the group vault doesn't disturb 1:1 ratchet items.
public final class KeychainGroupSessionVault: GroupSessionVault, @unchecked Sendable {

    public static let service = "com.bcrypto.qaudion.group.v1"

    public init() {}

    public func save(_ state: GroupState) {
        let blob = GroupSessionSnapshotCodec.encode(state)
        writeBlob(account: Self.account(state.groupIdBytes, state.groupEpoch, state.selfId), blob: blob)
    }

    public func load(groupIdBytes: Data, groupEpoch: UInt32, selfId: String) -> GroupState? {
        let acct = Self.account(groupIdBytes, groupEpoch, selfId)
        guard let blob = readBlob(account: acct) else { return nil }
        return try? GroupSessionSnapshotCodec.decode(blob)
    }

    /// W-GRPDEL (2026-08-02) — see the protocol doc. Deletes every keychain
    /// item of this service whose account matches `<groupIdHex>|<any epoch>|<selfId>`.
    ///
    /// The epoch is not known here (the descending probe in
    /// `GroupChatService.loadFromVault` exists precisely because it is not),
    /// so the items are enumerated and filtered by account rather than
    /// deleted by an exact query. Two things are deliberate:
    ///
    ///   - The `kSecAttrService` is pinned to this class's own service
    ///     (`com.bcrypto.qaudion.group.v1`), so the 1:1 ratchet vault and
    ///     every other keychain item this app owns are structurally out of
    ///     reach — the filter cannot over-reach even if the account matching
    ///     were wrong.
    ///   - Deletion is per-account, and only for accounts matching BOTH the
    ///     group prefix and the identity suffix. Another group the user is
    ///     still in keeps its snapshots.
    ///
    /// `errSecItemNotFound` from the enumeration is the normal "no crypto
    /// state for this group" case and is swallowed.
    public func purge(groupIdBytes: Data, selfId: String) {
        let prefix = "\(GroupSenderKey.toHex(groupIdBytes))|"
        let suffix = "|\(selfId)"
        for account in allAccounts() where account.hasPrefix(prefix) && account.hasSuffix(suffix) {
            deleteBlob(account: account)
        }
    }

    /// P0-5 (2026-08-05, coordinated fix plan cluster 5) — bulk wipe for
    /// `remote_wipe` / account deletion. `purge(groupIdBytes:selfId:)` only
    /// clears ONE known group's snapshots; neither wipe path knew every group
    /// the user was ever in, so every group session key survived every wipe.
    /// One Keychain call, no account filter — removes every group snapshot
    /// regardless of group/epoch/self.
    public func wipeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Deliberately non-throwing (best-effort, called from LocalCryptoWipe
        // .wipeAll() alongside independent steps), but not silent — log an
        // unexpected status so a stuck wipe is observable.
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[KeychainGroupSessionVault] wipeAll: SecItemDelete failed status=\(status)")
        }
    }

    // MARK: - Internal

    private static func account(_ gid: Data, _ epoch: UInt32, _ selfId: String) -> String {
        return "\(GroupSenderKey.toHex(gid))|\(epoch)|\(selfId)"
    }

    private func readBlob(account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status != errSecSuccess { return nil }
        return item as? Data
    }

    /// Every account string currently stored under this vault's service.
    /// Empty on `errSecItemNotFound` (nothing saved yet) and on any other
    /// status — a keychain that will not enumerate must not crash a delete.
    private func allAccounts() -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &items)
        guard status == errSecSuccess, let rows = items as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func deleteBlob(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(q as CFDictionary)
    }

    private func writeBlob(account: String, blob: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        var add = base
        add[kSecValueData as String] = blob
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            _ = SecItemUpdate(base as CFDictionary,
                                [kSecValueData as String: blob] as CFDictionary)
        }
    }
}
