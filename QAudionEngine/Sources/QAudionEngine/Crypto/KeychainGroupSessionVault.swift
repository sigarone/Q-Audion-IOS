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
