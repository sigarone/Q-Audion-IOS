import Foundation
import QAudionEngine

/// The contact-level identity shield of every stored contact, computed once and refreshed when the contacts, the pins, the verifications,
/// the keys the chat sessions are bound to or the server's published devices change.
///
/// The chat list draws one badge per row and the chat header one more: reading the contact store (it is decrypted on every read) and
/// the pin store once per badge would be quadratic in the number of conversations. Rows read the value from here instead.
/// The value itself comes from `ContactShieldEvaluator`, which hands the stores to the pure rules of `IdentityShieldRules`.
///
/// The work (Keychain reads for the pins and for the session bindings, the contact store) runs on a background queue, never on the main
/// actor; only the finished values are published on it. A change of one peer's bindings recomputes that peer alone.
@MainActor
final class ContactShieldCache: ObservableObject {

    static let shared = ContactShieldCache()

    @Published private(set) var shields: [String: IdentityShield] = [:]

    private let worker = ContactShieldWorker()
    private var observers: [NSObjectProtocol] = []
    private var lastSequence: UInt64 = 0

    private init() {
        worker.publish = { [weak self] sequence, values in
            Task { @MainActor [weak self] in self?.apply(sequence: sequence, values: values) }
        }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.contactsDidChange, PeerIdentityPinStore.didChangeNotification, .sasVerificationDidChange]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [worker] _ in worker.mark(peer: nil) }
            observers.append(token)
        }
        // One peer changed: its bindings (an install, a replace, a first decrypt, a decrypt under the previous session, a failed
        // write) or its published devices. The observer only records the peer; the worker drains the set, so no change is lost.
        let perPeer: [Notification.Name] = [MessageRatchet.bindingDidChangeNotification, PublishedDeviceSetCache.didChangeNotification]
        for name in perPeer {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [worker] note in
                worker.mark(peer: note.userInfo?["peerId"] as? String)
            }
            observers.append(token)
        }
        worker.mark(peer: nil)
    }

    /// The shield of `userId`; `.pending` for a user that is not a stored contact.
    func shield(for userId: String) -> IdentityShield {
        shields[userId] ?? .pending
    }

    /// Recompute every shield from the stores.
    func reload() {
        worker.mark(peer: nil)
    }

    /// The worker publishes the WHOLE map with a sequence number; two hops to the main actor may run in either order, so a map older
    /// than the one already shown is dropped (the newer one contains everything the older one said).
    private func apply(sequence: UInt64, values: [String: IdentityShield]) {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        if values != shields { shields = values }
    }
}

/// The off-main half of `ContactShieldCache`: a serial queue and the set of what is dirty. A mark that arrives while a drain runs lands
/// in the set the NEXT drain takes (the drain empties the set before it computes, and a mark always schedules a drain), so a change of a
/// peer is never dropped, however many changes of other peers arrive in between.
private final class ContactShieldWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "qaudion.contactshield", qos: .utility)
    private var dirtyPeers: Set<String> = []
    private var allDirty = false
    private var drainScheduled = false
    private var current: [String: IdentityShield] = [:]
    private var sequence: UInt64 = 0

    /// Called on the worker's queue with the whole map and its sequence number (growing by one per publish).
    var publish: (@Sendable (_ sequence: UInt64, _ values: [String: IdentityShield]) -> Void)?

    /// Records that `peer` (every contact when nil) must be recomputed.
    func mark(peer: String?) {
        queue.async {
            if let peer { self.dirtyPeers.insert(peer) } else { self.allDirty = true }
            guard !self.drainScheduled else { return }
            self.drainScheduled = true
            self.queue.async { self.drain() }
        }
    }

    private func drain() {
        drainScheduled = false
        let full = allDirty
        let peers = dirtyPeers
        allDirty = false
        dirtyPeers = []
        guard full || !peers.isEmpty else { return }
        let contacts = ContactsStore().load()
        if full {
            current = ContactShieldEvaluator.shields(for: contacts)
        } else {
            for (peer, value) in ContactShieldEvaluator.shields(forFew: contacts.filter { peers.contains($0.userId) }) { current[peer] = value }
        }
        sequence += 1
        publish?(sequence, current)
    }
}
