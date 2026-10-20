import Foundation
import QAudionEngine

/// One-time removal of the vault entries that the former key rotation of Key management wrote and nothing reads
/// any more: the ephemeral public keys (`rotated_ephemeral.<seconds>`). They were never call keys.
enum KeyManagementCleanup {

    private static let doneKey = "com.qaudion.keymgmt.legacy_identity_entries_removed"

    static func removeLegacyIdentityEntriesOnce(
        defaults: UserDefaults = .standard,
        vault: SovereignKeyVault = SovereignKeyVault()
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        // An empty listing is a locked or a brand-new Keychain: there is nothing to remove yet, so ask again at the
        // next launch instead of recording that the work is done.
        guard !vault.listPskNames().isEmpty else { return }
        if LegacyIdentityKeyEntries.removeAll(from: vault) {
            defaults.set(true, forKey: doneKey)
        }
    }
}
