import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain-backed [RatchetVault]. Persists each `(epochId, peerId)`
/// snapshot under its own keychain item with the `ThisDeviceOnly` class
/// `KeychainAccessibilityPolicy` assigns to `.ratchetState`
/// (AfterFirstUnlockThisDeviceOnly since W-KCAFTERUNLOCK, 2026-09-01) so
/// the chain keys can never leave the device unencrypted and are still
/// readable on a VoIP-push wake with the phone locked.
///
/// Mirror of Android's `EncryptedSharedPreferencesRatchetVault.kt` —
/// both use the platform's native secure store and the same opaque
/// snapshot codec.
///
/// **Synchrony contract:** matches the protocol — `save()` calls
/// `SecItemUpdate`/`SecItemAdd` synchronously and returns only after
/// the keychain has acknowledged the write. This is the write-ahead
/// invariant that prevents nonce reuse on a crash between encrypt and
/// network send.
public final class KeychainRatchetVault: RatchetVault, @unchecked Sendable {

    /// Keychain `kSecAttrService` value. Distinct from PSK vault so a
    /// future `keychain dump` migration can target the ratchet items
    /// without disturbing PSKs.
    public static let service = "com.bcrypto.qaudion.ratchet.v1"

    /// Keychain `kSecAttrService` for the v4 PQ-ratchet opaque session blobs.
    /// A SEPARATE service from the v3.1 ``service`` (same Keystore-backed trust
    /// boundary, same accessibility class) so a v4 blob can never collide
    /// with a v3.1 snapshot for the same `(epochId, peerId)` account. Mirrors
    /// Android's `KEY_PREFIX_V4` separate keyspace in the same encrypted store.
    public static let serviceV4 = "com.bcrypto.qaudion.ratchet.v4"

    public init() {}

    public func load(epochId: String, peerId: String) -> RatchetSnapshot? {
        // Unchanged contract: nil for "absent" AND for any read failure. A
        // caller that would bootstrap a fresh chain on nil reads through
        // `loadChecked` instead.
        return (try? loadChecked(epochId: epochId, peerId: peerId)) ?? nil
    }

    /// W-KCAFTERUNLOCK (2026-09-01) — `RatchetVault.loadChecked`: same read,
    /// but a locked Keychain (-25308) throws `VaultError.deviceLocked` instead
    /// of answering nil. `MessageRatchet.ensureSession` reads through THIS so
    /// it can never derive-and-persist a fresh chain over a snapshot it merely
    /// could not decrypt yet (audit memory
    /// reference_ios_stability_audit_2026_09_01, P1 item 5).
    public func loadChecked(epochId: String, peerId: String) throws -> RatchetSnapshot? {
        let blob = try readBlobChecked(service: Self.service, account: Self.account(epochId: epochId, peerId: peerId))
        guard let blob = blob else { return nil }
        return try? RatchetSnapshotCodec.decode(blob)
    }

    public func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) throws {
        let blob = RatchetSnapshotCodec.encode(snapshot)
        try writeBlob(service: Self.service, account: Self.account(epochId: epochId, peerId: peerId), blob: blob)
    }

    public func delete(epochId: String, peerId: String) {
        deleteBlob(service: Self.service, account: Self.account(epochId: epochId, peerId: peerId))
    }

    // ── v4 PQ-ratchet opaque session blob (separate Keychain service) ────────
    //
    // The v4 native session (``MessageRatchet/serializeV4Session(_:)``) is an
    // opaque Rust-core blob — stored raw, NEVER parsed/decoded as a
    // ``RatchetSnapshot``. Same write-ahead durability contract as ``save``:
    // ``saveV4`` returns only after `SecItemAdd`/`SecItemUpdate` acknowledges.

    public func loadV4(epochId: String, peerId: String) -> Data? {
        return readBlob(service: Self.serviceV4, account: Self.account(epochId: epochId, peerId: peerId))
    }

    public func saveV4(epochId: String, peerId: String, blob: Data) throws {
        // Store the opaque blob VERBATIM (no codec) under the v4 service.
        try writeBlob(service: Self.serviceV4, account: Self.account(epochId: epochId, peerId: peerId), blob: blob)
    }

    public func deleteV4(epochId: String, peerId: String) {
        deleteBlob(service: Self.serviceV4, account: Self.account(epochId: epochId, peerId: peerId))
    }

    /// P0-5 (2026-08-05, coordinated fix plan cluster 5) — bulk wipe for
    /// `remote_wipe` / account deletion. `delete(epochId:peerId:)` /
    /// `deleteV4(epochId:peerId:)` only ever remove ONE known `(epochId,
    /// peerId)` pair; neither wipe path knew every pair to call them with, so
    /// every ratchet chain-key snapshot (both v3.1 and v4 services) survived
    /// every wipe. One Keychain call per service, no account filter.
    public func wipeAll() {
        deleteAllInService(Self.service)
        deleteAllInService(Self.serviceV4)
    }

    // MARK: - Internal

    private static func account(epochId: String, peerId: String) -> String {
        return "\(epochId)|\(peerId)"
    }

    private func readBlob(service: String, account: String) -> Data? {
        return (try? readBlobChecked(service: service, account: account)) ?? nil
    }

    /// W-KCAFTERUNLOCK (2026-09-01) — the one real read. Attributes ride along
    /// with the data so a blob still on the legacy class is upgraded in place
    /// right after the read that proved it readable (see
    /// `KeychainAccessibilityMigration`). Only -25308 is surfaced as a throw;
    /// every other non-success status still answers `nil` exactly as before.
    private func readBlobChecked(service: String, account: String) throws -> Data? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var query = base
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch KeychainAccessibilityPolicy.classifyRead(status: status) {
        case .absent:
            return nil
        case .deviceLocked:
            throw VaultError.deviceLocked
        case .failed:
            return nil
        case .found:
            break
        }
        guard let attrs = item as? [String: Any] else { return nil }
        KeychainAccessibilityMigration.upgradeIfNeeded(
            attributes: attrs, baseQuery: base, category: .ratchetState, tag: "KeychainRatchetVault")
        return attrs[kSecValueData as String] as? Data
    }

    // SECURITY C-7: the write path now propagates Keychain failures.
    // The RatchetVault contract requires a durable flush BEFORE the
    // caller transmits the ciphertext; swallowing a failed write would
    // re-introduce the catastrophic nonce-reuse hazard (spec §6) — on a
    // crash we could resend a frame whose CK_{n+1} never persisted and
    // reuse a deterministic GCM nonce. `MessageRatchet.encrypt` treats a
    // throw here as fatal and never returns the wire blob.
    private func writeBlob(service: String, account: String, blob: Data) throws {
        let baseAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var addAttrs = baseAttrs
        addAttrs[kSecValueData as String] = blob
        // W-KCAFTERUNLOCK (2026-09-01) — class from the one policy; an inbound
        // message decrypted on a locked phone must be able to persist the
        // advanced chain. See KeychainAccessibilityPolicy.
        addAttrs[kSecAttrAccessible as String] = KeychainAccessibilityPolicy.secAttrAccessible(for: .ratchetState)

        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw VaultError.persistFailed(addStatus)
        }
        // Item already present — overwrite in place. The update MUST
        // succeed or the persisted chain state is stale.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: blob,
        ]
        let updateStatus = SecItemUpdate(baseAttrs as CFDictionary, updateAttrs as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw VaultError.persistFailed(updateStatus)
        }
    }

    private func deleteBlob(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private func deleteAllInService(_ service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // wipeAll() is deliberately non-throwing (best-effort, called from
        // LocalCryptoWipe.wipeAll() alongside independent steps that must not
        // block each other), but a failure here must not be silent — log it
        // so a stuck wipe is at least observable, matching the two-status
        // convention (success / item-not-found are the only expected codes)
        // used everywhere else in this file's throwing methods.
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[KeychainRatchetVault] wipeAll: SecItemDelete failed for service=\(service) status=\(status)")
        }
    }
}
