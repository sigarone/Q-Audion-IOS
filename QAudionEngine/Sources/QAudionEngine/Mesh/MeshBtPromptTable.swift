import Foundation

/// The user-interface state of each message set to Bluetooth only, per message id: the prompt that waits for an answer, the
/// answer "no", and the persistent "not delivered" state. It holds UI state only. Whether a message may be sent through the
/// internet is decided by the flag on the stored message (`Message.bluetoothHold`), so nothing this table does, evicting
/// included, can release a held message.
///
/// The table is capped. At the cap it evicts only `.declined` entries, oldest first by their stored time; a `.prompted` or
/// `.undelivered` entry is never evicted, so the table can go over the cap rather than lose a state the user must see.
public struct MeshBtPromptTable: Codable, Equatable, Sendable {

    public struct Item: Codable, Equatable, Sendable {
        public var state: MeshBtOnlyState
        public var atMs: Int64

        public init(state: MeshBtOnlyState, atMs: Int64) {
            self.state = state
            self.atMs = atMs
        }
    }

    public static let maxEntries = 500

    public private(set) var items: [String: Item]

    public init(items: [String: Item] = [:]) {
        self.items = items
    }

    public func state(of id: String) -> MeshBtOnlyState {
        items[id]?.state ?? .idle
    }

    /// `.idle` removes the entry.
    public mutating func set(_ state: MeshBtOnlyState, id: String, nowMs: Int64, maxEntries: Int = MeshBtPromptTable.maxEntries) {
        if state == .idle {
            items.removeValue(forKey: id)
            return
        }
        items[id] = Item(state: state, atMs: nowMs)
        while items.count > maxEntries {
            guard let victim = items
                .filter({ $0.key != id && $0.value.state == .declined })
                .min(by: { $0.value.atMs < $1.value.atMs }) else { return }
            items.removeValue(forKey: victim.key)
        }
    }
}
