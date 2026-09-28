import Foundation

/// W-LIVELOGOFFMAIN (2026-09-21) — the log lines the shipper has prepared (redacted and
/// serialised, once) and not yet had confirmed by the server.
///
/// Before this, the shipper re-read and re-redacted EVERY unconfirmed ring entry on each
/// attempt (up to the whole 5000-entry ring, on the main thread) and only advanced its
/// cursor on success, so a server that kept answering 429 made each attempt more
/// expensive than the last. Now a line is prepared exactly once, waits here, and leaves
/// only when a chunk containing it is confirmed. Bounded by entries AND bytes; when a
/// bound is hit the OLDEST lines go first and every one is counted, so the loss is
/// visible instead of silent.
///
/// Pure value type: no clock, no locks, no I/O. Not thread-safe by itself; the owner
/// (the shipper's worker actor) is the only writer.
public struct LiveLogBacklog: Equatable, Sendable {

    public struct Item: Equatable, Sendable {
        /// Sequence number the line had in the runtime log ring (ascending in the backlog).
        public let seq: Int64
        public let line: String
        /// UTF-8 size of the line plus its trailing newline: what it adds to a chunk.
        public let bytes: Int
    }

    /// A chunk-sized prefix of the backlog. Nothing is removed by looking at it.
    public struct Batch: Equatable, Sendable {
        public let lines: [String]
        /// Sequence number of the last line in `lines`: the cursor to confirm.
        public let lastSeq: Int64
        /// Bytes `lines` add to a chunk (newlines included).
        public let byteCount: Int
    }

    public let maxEntries: Int
    public let maxBytes: Int

    /// Lines dropped for want of room (or reported as dropped by the collector) so far.
    public private(set) var droppedTotal: Int = 0

    private var items: [Item] = []
    /// `items[head...]` are the live lines; everything before `head` is already gone.
    private var head: Int = 0
    private var liveBytes: Int = 0
    private var droppedUnreported: Int = 0

    public init(maxEntries: Int, maxBytes: Int) {
        self.maxEntries = max(maxEntries, 1)
        self.maxBytes = max(maxBytes, 1)
    }

    public var count: Int { return items.count - head }
    public var isEmpty: Bool { return items.count == head }
    public var byteCount: Int { return liveBytes }

    // MARK: - Growing

    /// Add one prepared line at the tail. If that puts the backlog over either bound the
    /// oldest lines are dropped (and counted) until it fits again.
    public mutating func append(seq: Int64, line: String) {
        let bytes = line.utf8.count + 1
        items.append(Item(seq: seq, line: line, bytes: bytes))
        liveBytes += bytes
        trimToBounds()
    }

    /// Count lines that never made it into the backlog because more were pending than it
    /// could hold (the collector skips the oldest ones instead of preparing them).
    public mutating func noteDropped(_ lines: Int) {
        if lines <= 0 { return }
        droppedTotal += lines
        droppedUnreported += lines
    }

    /// Lines dropped since the last call; resets the reported count (not `droppedTotal`).
    public mutating func takeUnreportedDropCount() -> Int {
        let pending = droppedUnreported
        droppedUnreported = 0
        return pending
    }

    // MARK: - Shipping

    /// The next chunk's lines: from the oldest, at most `maxLines`, and at most
    /// `byteBudget` bytes of chunk content. The first line is always included even if it
    /// alone exceeds the budget (the chunk builder truncates it), so a giant line can
    /// never wedge the queue. Nil when empty.
    public func peekBatch(maxLines: Int, byteBudget: Int) -> Batch? {
        if head >= items.count || maxLines <= 0 { return nil }
        var lines: [String] = []
        var total = 0
        var lastSeq: Int64 = items[head].seq
        var index = head
        while index < items.count && lines.count < maxLines {
            let item = items[index]
            if !lines.isEmpty && total + item.bytes > byteBudget { break }
            lines.append(item.line)
            total += item.bytes
            lastSeq = item.seq
            index += 1
        }
        return Batch(lines: lines, lastSeq: lastSeq, byteCount: total)
    }

    /// The server confirmed a chunk ending at `seq`: remove every line up to and
    /// including it. Keyed by sequence number rather than by count, so it stays right
    /// even if the oldest lines were dropped for room while the chunk was in flight.
    /// Returns how many lines were removed.
    @discardableResult
    public mutating func removeThrough(seq: Int64) -> Int {
        var removed = 0
        while head < items.count && items[head].seq <= seq {
            liveBytes -= items[head].bytes
            head += 1
            removed += 1
        }
        compactIfNeeded()
        return removed
    }

    /// Forget everything (consent withdrawn). The drop counters are kept.
    public mutating func removeAll() {
        items.removeAll()
        head = 0
        liveBytes = 0
    }

    // MARK: - Internals

    private mutating func trimToBounds() {
        while head < items.count && (items.count - head > maxEntries || liveBytes > maxBytes) {
            liveBytes -= items[head].bytes
            head += 1
            droppedTotal += 1
            droppedUnreported += 1
        }
        compactIfNeeded()
    }

    /// Reclaim the dead prefix now and then instead of shifting the array on every drop.
    private mutating func compactIfNeeded() {
        if head >= items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
            return
        }
        if head >= 256 && head * 2 >= items.count {
            items.removeFirst(head)
            head = 0
        }
    }
}
