import Foundation
import QAudionEngine

/// One key of the list in Key management.
struct KeyManagementRow: Identifiable, Equatable {
    /// The vault account name: a KMS key id, `nfc-…`, `prox-…`, or the name a key was given.
    let id: String
    let origin: PskOrigin
    /// The first 64 bits of the key's fingerprint, `xxxx.xxxx.xxxx.xxxx`.
    let fingerprint: String
    /// 1 is the key the caller advertises first.
    let priority: Int
}

/// The list of Key management: the keys that take part in calls, in the order the caller advertises them
/// (`CallKeyPriority`, docs/security/CALL_KEY_PRIORITY.md; the same list the OFFER, the ACCEPT advert and every
/// re-key use), with the moves of the arrows and the deletion of a key.
///
/// The list refreshes on `.sovereignVaultDidChange`, which the vault posts for every write and delete
/// of a key (not for its device-internal entries), so a key delivered by the KMS, paired by NFC or paired in person
/// while the screen is open shows up at once.
@MainActor
final class KeyManagementCoordinator: ObservableObject {

    @Published private(set) var keys: [KeyManagementRow] = []
    /// What the screen shows in its error banner; nil when the last arrow press was stored.
    @Published private(set) var errorMessage: String?

    private var vaultObserver: NSObjectProtocol?

    init() {
        loadKeys()
        // No queue: the block runs on the posting thread and only schedules the reload. With a queue other than
        // the poster's, the poster would wait until the block had run there, and the vault is written from
        // background threads (the KMS poller) that can hold the lock of `CallKeyPriorityStore` while the main
        // thread waits for it in `loadKeys`.
        vaultObserver = NotificationCenter.default.addObserver(
            forName: .sovereignVaultDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // NotificationCenter callbacks are @Sendable in iOS 18+ — hop to
            // MainActor to satisfy this class's own @MainActor isolation.
            Task { @MainActor [weak self] in
                self?.errorMessage = nil
                self?.loadKeys()
            }
        }
    }

    deinit {
        if let token = vaultObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Reads the list again from the vault and the stored order.
    func loadKeys() {
        let vault = SovereignKeyVault()
        let ids = CallKeyPriorityStore.live(vault: vault).current().ids
        var rows: [KeyManagementRow] = []
        for (index, id) in ids.enumerated() {
            rows.append(KeyManagementRow(
                id: id,
                origin: vault.origin(name: id),
                fingerprint: CallKeyPriorityStore.shortFingerprint(label: vault.getFingerprint(name: id)),
                priority: index + 1))
        }
        keys = rows
    }

    /// One place up. The key is marked as placed by hand, so a key that arrives later does not take its place.
    func moveUp(_ id: String) {
        finishMove(CallKeyPriorityStore.live().moveUp(id))
    }

    /// One place down; see `moveUp`.
    func moveDown(_ id: String) {
        finishMove(CallKeyPriorityStore.live().moveDown(id))
    }

    /// Shows the list as it is stored, and the error banner when the move could not be stored.
    private func finishMove(_ move: CallKeyPriorityMove) {
        errorMessage = move.saved ? nil : String(
            localized: "key_management.order_not_saved",
            defaultValue: "Non è stato possibile salvare il nuovo ordine delle chiavi. Riprova.",
            comment: "Key management — error banner when an arrow press could not be stored")
        loadKeys()
    }

    /// Deletes the key from the vault; it leaves the list and loses its "placed by hand" mark.
    func deleteKey(_ id: String) {
        errorMessage = nil
        let vault = SovereignKeyVault()
        try? vault.deletePsk(name: id)
        CallKeyPriorityStore.live(vault: vault).syncWithVault()
        loadKeys()
    }
}
