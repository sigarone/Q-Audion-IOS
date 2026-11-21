import Foundation

/// The messages the user answered "send over the internet" for. The network outbox sends a row to a Bluetooth-only contact only
/// when its id is here. A short list of message ids in `UserDefaults`: no text, no key material.
final class UserNetworkApprovalStore {
    static let shared = UserNetworkApprovalStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let storageKey = "qaudion.mesh.usernetworkapprovals.v1"
    private static let maxEntries = 500

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func approve(messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        var ids = defaults.stringArray(forKey: Self.storageKey) ?? []
        guard !ids.contains(messageId) else { return }
        ids.append(messageId)
        if ids.count > Self.maxEntries { ids.removeFirst(ids.count - Self.maxEntries) }
        defaults.set(ids, forKey: Self.storageKey)
    }

    func isApproved(messageId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (defaults.stringArray(forKey: Self.storageKey) ?? []).contains(messageId)
    }
}
