import Foundation

/// Bounded, lock-protected buffer of sequence-numbered elements, readable and writable from
/// any thread. It is the storage behind the app's in-memory log: the log shipper reads the new
/// entries and the log facade appends to it without going through the main thread.
///
/// Sequence numbers start at 1 and only grow. When the buffer is over `maxEntries`, the oldest
/// tenth is dropped in one step (no array shift per append).
public final class SequencedRing<Element>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [Element] = []
    private var nextSeq: Int64 = 1
    private let maxEntries: Int
    private let seqOf: @Sendable (Element) -> Int64

    public init(maxEntries: Int, seqOf: @escaping @Sendable (Element) -> Int64) {
        self.maxEntries = max(maxEntries, 10)
        self.seqOf = seqOf
    }

    /// Appends the element built from the sequence number assigned to it.
    @discardableResult
    public func append(_ make: (Int64) -> Element) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let seq = nextSeq
        nextSeq &+= 1
        storage.append(make(seq))
        if storage.count > maxEntries {
            storage.removeFirst(maxEntries / 10)
        }
        return seq
    }

    /// The elements newer than `since`, oldest first, at most `maxCount` of them (the newest
    /// ones when more are pending). `skippedOlder` counts the pending elements left out.
    /// Cost is proportional to the new elements, not to the buffer.
    public func entriesSince<T>(
        seq since: Int64, maxCount: Int, transform: (Element) -> T
    ) -> (entries: [T], skippedOlder: Int) {
        lock.lock()
        defer { lock.unlock() }
        var firstNew = storage.count
        while firstNew > 0 && seqOf(storage[firstNew - 1]) > since {
            firstNew -= 1
        }
        let available = storage.count - firstNew
        let take = min(available, max(maxCount, 0))
        var out: [T] = []
        out.reserveCapacity(take)
        var index = storage.count - take
        while index < storage.count {
            out.append(transform(storage[index]))
            index += 1
        }
        return (out, available - take)
    }

    /// A copy of the whole buffer, oldest first.
    public func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    /// Drops every element; the sequence keeps growing.
    public func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
