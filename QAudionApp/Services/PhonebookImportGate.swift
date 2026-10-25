import Foundation
import Contacts

/// When the app may read the address book and send contact hashes to the server by itself.
///
/// Scanning the address book and discovering contacts is something the user starts explicitly, with "Importa" on the
/// import screen. A later refresh (pull to refresh, a contact deleted) must never ask for the Contacts permission and never
/// upload anything unless that permission is already given AND the user has completed an import before; otherwise it only
/// reloads what is already stored.
struct PhonebookImportGate {
    static let key: String = "qaudion.contacts.phonebook_import_done.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True once the user completed an import ("Importa" on the import screen ran to its results).
    var importCompleted: Bool {
        defaults.bool(forKey: Self.key)
    }

    func markImportCompleted() {
        defaults.set(true, forKey: Self.key)
    }

    /// Forgets the import: after a logout, a wipe, an account deletion, or when the Contacts permission is found revoked, the
    /// next refresh must not scan until the user runs "Importa" again.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    /// A refresh may scan and upload only with the permission already given and a previous explicit import.
    static func mayScanOnRefresh(importCompleted: Bool, status: CNAuthorizationStatus) -> Bool {
        guard importCompleted else { return false }
        switch status {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// Same rule on the stored flag. A permission found revoked (neither authorized nor limited) clears the flag, so a later
    /// regrant needs a new "Importa". "Not decided yet" is a revoked state too (the permission was reset).
    func mayScanOnRefresh(status: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)) -> Bool {
        let allowed: Bool = Self.mayScanOnRefresh(importCompleted: true, status: status)
        if !allowed && importCompleted { clear() }
        return allowed && importCompleted
    }
}
