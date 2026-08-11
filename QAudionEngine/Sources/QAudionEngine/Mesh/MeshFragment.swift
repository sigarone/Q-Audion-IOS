import Foundation

/// Fragmentation for payloads too large for one BLE GATT write.
///
/// A payload above ``MeshFragmenter/threshold`` gets split by
/// ``MeshFragmenter`` into ordered chunks sharing one random
/// ``MeshFragmentHeader/fragmentSetId``; each chunk is meant to be wrapped
/// by the caller into its own `MeshPacket(type: .fragment, ...)``.
/// ``MeshFragmentReassembler`` is the receive-side buffer.
public struct MeshFragmentHeader: Equatable, Sendable {
    public static let maxFragmentsPerSet = 100

    public let fragmentSetId: UInt32
    public let index: Int
    public let total: Int

    public enum HeaderError: Error, Equatable {
        case totalOutOfRange(Int)
        case indexOutOfRange(Int, total: Int)
    }

    public init(fragmentSetId: UInt32, index: Int, total: Int) throws {
        guard (1...Self.maxFragmentsPerSet).contains(total) else {
            throw HeaderError.totalOutOfRange(total)
        }
        guard (0..<total).contains(index) else {
            throw HeaderError.indexOutOfRange(index, total: total)
        }
        self.fragmentSetId = fragmentSetId
        self.index = index
        self.total = total
    }
}

/// Pure chunker — no I/O, no CoreBluetooth type, unit-testable on the bare
/// Swift Package Manager test target.
public enum MeshFragmenter {

    /// Conservative threshold below the common ~500B negotiated BLE GATT
    /// MTU ceiling, leaving room for the FRAGMENT packet's own header
    /// overhead (see `MeshPacket.encode()`'s layout) plus whatever
    /// GATT/L2CAP framing the real transport adds on top.
    public static let threshold = 420

    public static func shouldFragment(_ payload: Data) -> Bool {
        payload.count > threshold
    }

    /// Splits `payload` into ordered `(header, chunk)` pairs. Does NOT
    /// build `MeshPacket`s itself — the caller wraps each chunk into its own
    /// `MeshPacket(type: .fragment, payload: chunk)`, keeping this function
    /// transport-agnostic and trivially testable.
    public static func fragment(
        _ payload: Data,
        fragmentSetId: UInt32 = UInt32.random(in: UInt32.min...UInt32.max),
        chunkSize: Int = MeshFragmenter.threshold
    ) throws -> [(header: MeshFragmentHeader, chunk: Data)] {
        precondition(chunkSize > 0, "chunkSize must be positive")
        let total = max(1, (payload.count + chunkSize - 1) / chunkSize)
        guard total <= MeshFragmentHeader.maxFragmentsPerSet else {
            throw MeshFragmentHeader.HeaderError.totalOutOfRange(total)
        }
        var out: [(MeshFragmentHeader, Data)] = []
        out.reserveCapacity(total)
        for i in 0..<total {
            let from = payload.index(payload.startIndex, offsetBy: i * chunkSize)
            let to = payload.index(from, offsetBy: min(chunkSize, payload.count - i * chunkSize))
            let header = try MeshFragmentHeader(fragmentSetId: fragmentSetId, index: i, total: total)
            out.append((header, payload[from..<to]))
        }
        return out
    }
}

/// Receive-side reassembly buffer. Holds no CoreBluetooth type —
/// unit-testable on the plain Swift Package Manager test target without a
/// device or simulator. Bounds memory from a malformed or hostile sender via
/// ``maxBytesPerSet``/``maxBytesGlobal``, and a stalled set is dropped by
/// ``sweepExpired(setTimeoutMs:)`` once ``defaultSetTimeoutMs`` elapses since
/// its first fragment — the caller is expected to invoke that periodically;
/// this class runs no timer of its own.
public final class MeshFragmentReassembler {

    public enum Outcome: Equatable {
        case awaitingMoreFragments
        case complete(Data)
        case rejected(String)
    }

    private struct SetKey: Hashable {
        let senderId: MeshNodeId
        let fragmentSetId: UInt32
    }

    private final class SetBuffer {
        let total: Int
        let firstSeenAtMs: Int64
        var chunks: [Int: Data] = [:]
        var bufferedBytes: Int = 0
        init(total: Int, firstSeenAtMs: Int64) {
            self.total = total
            self.firstSeenAtMs = firstSeenAtMs
        }
    }

    public static let defaultSetTimeoutMs: Int64 = 30_000
    public static let maxBytesPerSet = 64 * 1024
    public static let maxBytesGlobal = 512 * 1024

    private let lock = NSLock()
    private var sets: [SetKey: SetBuffer] = [:]
    private var setOrder: [SetKey] = []
    private var globalBufferedBytes = 0

    /// Test/production clock seam — matches the pattern used by
    /// ``MeshTopology``.
    public var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    public init() {}

    public func offer(senderId: MeshNodeId, header: MeshFragmentHeader, chunk: Data) -> Outcome {
        lock.lock()
        defer { lock.unlock() }

        let key = SetKey(senderId: senderId, fragmentSetId: header.fragmentSetId)
        let buffer: SetBuffer
        if let existing = sets[key] {
            buffer = existing
        } else {
            buffer = SetBuffer(total: header.total, firstSeenAtMs: clock())
            sets[key] = buffer
            setOrder.append(key)
        }
        if buffer.total != header.total {
            return .rejected("total mismatch for existing set (had \(buffer.total), got \(header.total))")
        }
        if buffer.chunks[header.index] != nil {
            // Duplicate delivery — a flood mesh can legitimately deliver
            // the same fragment more than once. Idempotent no-op, not an
            // error.
            return buffer.chunks.count == buffer.total ? assemble(key: key, buffer: buffer) : .awaitingMoreFragments
        }
        let prospectiveSetBytes = buffer.bufferedBytes + chunk.count
        let prospectiveGlobalBytes = globalBufferedBytes + chunk.count
        if prospectiveSetBytes > Self.maxBytesPerSet {
            removeSet(key)
            return .rejected("per-set byte cap exceeded")
        }
        if prospectiveGlobalBytes > Self.maxBytesGlobal {
            // Global cap protects against many concurrent senders, not
            // just one hostile one — leave this set intact, just drop the
            // chunk.
            return .rejected("global byte cap exceeded — fragment dropped, set left intact")
        }
        buffer.chunks[header.index] = chunk
        buffer.bufferedBytes += chunk.count
        globalBufferedBytes += chunk.count

        return buffer.chunks.count == buffer.total ? assemble(key: key, buffer: buffer) : .awaitingMoreFragments
    }

    private func assemble(key: SetKey, buffer: SetBuffer) -> Outcome {
        removeSet(key)
        var out = Data()
        out.reserveCapacity(buffer.chunks.values.reduce(0) { $0 + $1.count })
        for idx in 0..<buffer.total {
            guard let chunk = buffer.chunks[idx] else {
                return .rejected("internal: missing chunk \(idx) after size check")
            }
            out.append(chunk)
        }
        return .complete(out)
    }

    /// Drops any set whose first fragment arrived more than `setTimeoutMs`
    /// ago and is still incomplete. Returns how many sets were discarded.
    /// Must be called under `lock`... no — this is a public entry point, so
    /// it acquires the lock itself like every other method here.
    @discardableResult
    public func sweepExpired(setTimeoutMs: Int64 = MeshFragmentReassembler.defaultSetTimeoutMs) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let stale = setOrder.filter { key in
            guard let buffer = sets[key] else { return false }
            return now - buffer.firstSeenAtMs > setTimeoutMs
        }
        for key in stale { removeSet(key) }
        return stale.count
    }

    /// Caller already holds `lock`.
    private func removeSet(_ key: SetKey) {
        if let buffer = sets.removeValue(forKey: key) {
            globalBufferedBytes -= buffer.bufferedBytes
        }
        setOrder.removeAll { $0 == key }
    }
}
