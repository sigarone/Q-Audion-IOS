import Foundation

/// Wire packets announced by the send/receive code, waiting for the bubble of the same row to exist on screen. Bounded
/// (oldest dropped) and time limited: whatever is not claimed within `ttlMs` is forgotten, so history and other
/// conversations never animate and nothing accumulates. Keeps only the packet text that the app itself produced or
/// received (never a plain text, never a key).
public final class EnigmaPending {
    public struct Item {
        public let id: String
        public let direction: EnigmaDirection
        public let packetBytes: Int
        public let wire: String
        public let atMs: Int64

        public init(id: String, direction: EnigmaDirection, packetBytes: Int, wire: String, atMs: Int64) {
            self.id = id
            self.direction = direction
            self.packetBytes = packetBytes
            self.wire = wire
            self.atMs = atMs
        }
    }

    private let maxItems: Int
    private let ttlMs: Int64
    private var items: [Item] = []

    public init(maxItems: Int = 8, ttlMs: Int64 = 5_000) {
        self.maxItems = max(1, maxItems)
        self.ttlMs = ttlMs
    }

    public var size: Int { items.count }

    public func add(_ item: Item) {
        expire(nowMs: item.atMs)
        items.removeAll { $0.id == item.id }
        if items.count >= maxItems { items.removeFirst() }
        items.append(item)
    }

    /// Removes and returns every item for which `claim` returns true.
    public func takeIf(nowMs: Int64, _ claim: (Item) -> Bool) -> [Item] {
        expire(nowMs: nowMs)
        if items.isEmpty { return [] }
        var taken: [Item] = []
        var kept: [Item] = []
        kept.reserveCapacity(items.count)
        for item in items {
            if claim(item) {
                taken.append(item)
            } else {
                kept.append(item)
            }
        }
        items = kept
        return taken
    }

    public func contains(id: String, direction: EnigmaDirection) -> Bool {
        items.contains { $0.id == id && $0.direction == direction }
    }

    public func expire(nowMs: Int64) {
        if items.isEmpty { return }
        items.removeAll { nowMs - $0.atMs > ttlMs }
    }

    public func clear() {
        items.removeAll()
    }
}
