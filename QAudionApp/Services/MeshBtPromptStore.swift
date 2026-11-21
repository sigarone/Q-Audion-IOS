import Foundation
import QAudionEngine

/// Where each message set to Bluetooth only stands with the user (`MeshBtOnlyState`), per message id. Persisted so the
/// prompt and the "not delivered" state survive a restart. UI state only: whether a message may be sent through the
/// internet is decided by the hold on the stored message (`Message.bluetoothHold`), not by this table, so an entry lost
/// from it can never release a message. Eviction rules are in `MeshBtPromptTable`. No text, no key material.
final class MeshBtPromptStore {
    static let shared = MeshBtPromptStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let storageKey = "qaudion.mesh.btprompt.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(messageId: String) -> MeshBtOnlyState {
        lock.lock()
        defer { lock.unlock() }
        return load().state(of: messageId)
    }

    func set(_ state: MeshBtOnlyState, messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        var table = load()
        table.set(state, id: messageId, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func load() -> MeshBtPromptTable {
        guard let data = defaults.data(forKey: Self.storageKey),
              let table = try? JSONDecoder().decode(MeshBtPromptTable.self, from: data) else {
            return MeshBtPromptTable()
        }
        return table
    }
}
