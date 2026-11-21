import Foundation
import QAudionEngine

/// The contact-level identity shield of every stored contact, computed once and refreshed when the contacts or the pins change.
///
/// The chat list draws one badge per row and the chat header one more: reading the contact store (it is decrypted on every read) and
/// the pin store once per badge would be quadratic in the number of conversations. Rows read the value from here instead.
/// The value itself comes from `ContactShieldEvaluator`, which hands the stores to the pure rules of `IdentityShieldRules`.
@MainActor
final class ContactShieldCache: ObservableObject {

    static let shared = ContactShieldCache()

    @Published private(set) var shields: [String: IdentityShield] = [:]

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.contactsDidChange, PeerIdentityPinStore.didChangeNotification, .sasVerificationDidChange]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reload() }
            }
            observers.append(token)
        }
        reload()
    }

    /// The shield of `userId`; `.pending` for a user that is not a stored contact.
    func shield(for userId: String) -> IdentityShield {
        shields[userId] ?? .pending
    }

    /// Recompute every shield from the stores (one enumeration of the pins for the whole list).
    func reload() {
        let computed = ContactShieldEvaluator.shields(for: ContactsStore().load())
        if computed != shields { shields = computed }
    }
}
