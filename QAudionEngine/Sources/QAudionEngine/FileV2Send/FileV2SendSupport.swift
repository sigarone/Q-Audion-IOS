import Foundation

/// A value behind a lock. The body is synchronous, so the lock is never held across a suspension point (and no `lock()` is
/// called from an async function, which the compiler rejects in Swift 6 mode).
final class FileV2Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// A mutex for async code: one holder at a time, the others wait in order. The pipeline takes it around the short critical
/// sections that must not interleave across transfers: wrapping a new key and writing the begin record, a create and the journal
/// write of its object, and the sweep of orphaned uploads (which must never see an object whose create has answered and whose
/// record is not yet in a journal).
///
/// A task that is cancelled while it waits leaves the queue and throws `CancellationError`; it never holds the gate.
actor FileV2AsyncGate {
    private var held = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID: UInt64 = 0

    func withGate<Result: Sendable>(_ body: @Sendable () async throws -> Result) async throws -> Result {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        if !held {
            held = true
            return
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
                // Cancelled before the waiter was registered: the handler below ran before there was anything to remove.
                if Task.isCancelled { cancelWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            // The gate passes straight to the next waiter: `held` stays true.
            waiters.removeFirst().continuation.resume()
        }
    }
}

/// A counting semaphore for async code: at most `slots` holders at a time, the others wait in the order they came. The pipeline gives
/// ONE of these to all the transfers it runs, with as many slots as the memory budget allows parts to be held at once, so that
/// the budget is the pipeline's and not each transfer's: ten files sent together hold no more than one file does.
///
/// The slot is held by `withSlot` for the duration of its body and given back on every path. A task that is cancelled while it waits
/// leaves the queue and throws `CancellationError`; it never holds a slot.
actor FileV2AsyncSemaphore {
    private var available: Int
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextWaiterID: UInt64 = 0

    init(slots: Int) {
        self.available = max(1, slots)
    }

    func withSlot<Result: Sendable>(_ body: @Sendable () async throws -> Result) async throws -> Result {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        if available > 0 {
            available -= 1
            return
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
                // Cancelled before the waiter was registered: the handler below ran before there was anything to remove.
                if Task.isCancelled { cancelWaiter(id) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            // The slot passes straight to the next waiter: `available` stays as it is.
            waiters.removeFirst().continuation.resume()
        }
    }
}

/// What the pipeline holds in memory while it works, counted where it is held: a sealed part from the moment it is allocated until
/// its upload ends, and the plaintext and sealed chunk of the chunk being sealed. The peaks are what the tests compare with the
/// memory budget.
final class FileV2SendGauge: @unchecked Sendable {
    private struct State {
        var heldBytes: Int64 = 0
        var peakBytes: Int64 = 0
        var heldParts = 0
        var peakParts = 0
    }

    private let state = FileV2Locked(State())

    func addPart(bytes: Int) {
        state.withValue {
            $0.heldBytes += Int64(bytes)
            $0.heldParts += 1
            $0.peakBytes = max($0.peakBytes, $0.heldBytes)
            $0.peakParts = max($0.peakParts, $0.heldParts)
        }
    }

    func releasePart(bytes: Int) {
        state.withValue {
            $0.heldBytes -= Int64(bytes)
            $0.heldParts -= 1
        }
    }

    func add(bytes: Int) {
        state.withValue {
            $0.heldBytes += Int64(bytes)
            $0.peakBytes = max($0.peakBytes, $0.heldBytes)
        }
    }

    func release(bytes: Int) {
        state.withValue { $0.heldBytes -= Int64(bytes) }
    }

    var diagnostics: FileV2SendDiagnostics {
        state.withValue { FileV2SendDiagnostics(peakHeldBytes: $0.peakBytes, peakConcurrentParts: $0.peakParts) }
    }

    var heldBytes: Int64 { state.withValue { $0.heldBytes } }
}
