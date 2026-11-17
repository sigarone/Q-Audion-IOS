import Foundation

/// A first-in-first-out async mutex: `run` bodies execute one at a time, in the order they asked.
///
/// WHY. The CoreBluetooth earbud client keeps ONE pending write and ONE pending read (a
/// continuation each). One client now serves the KMS sweep, the diagnostics poll (a DIAG read every
/// 2 s) and an FE-5 pairing at once, and a second read started while the first is outstanding
/// replaces its continuation: the first caller then never resumes. Each public operation of the
/// client therefore runs inside this gate. It serialises whole operations, not single ATT
/// requests: a KEY_IMPORT (PoP-INPUTS, every fragment, the status read) is never interleaved with
/// another operation's frames.
///
/// Cancellation. A caller that is cancelled while it waits for its turn LEAVES the queue and `run`
/// throws `CancellationError`; its body never runs. This matters to the FE-5 pairing: the relay
/// bounds PAIR_FIN with a 10 s timeout and cancels the write when it runs out. A gate that kept the
/// cancelled caller in line would let the write go out the moment an earlier operation (a DIAG poll,
/// a key import) finished, after the person was told the pairing had failed, and the earbud would
/// seal a pairing nobody believed in. A body that is already running is not interrupted: it is the
/// body's own business to react to cancellation. A caller cancelled in the instant it is let in does
/// not start its body either.
///
/// Not reentrant: a body must not call `run` on the same gate again (it would wait for itself).
/// Pure Foundation, so it is unit-tested on its own (EarbudSerialGateTests).
public final class EarbudSerialGate: @unchecked Sendable {

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var busy = false
    private var nextWaiterId: UInt64 = 0
    private var waiters: [Waiter] = []

    public init() {}

    /// Runs `body` once every earlier caller has finished, and lets the next one in when it ends,
    /// by return or by throw.
    ///
    /// - Throws: `CancellationError` when the calling task is cancelled before `body` starts (while
    ///   it waits, or in the instant it is let in); `body` has not run then. Otherwise whatever
    ///   `body` throws.
    public func run<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    private func newWaiterId() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextWaiterId &+= 1
        return nextWaiterId
    }

    private func acquire() async throws {
        let id = newWaiterId()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                // Checked under the lock: the cancel handler either already ran (the flag is set, seen here)
                // or runs after the waiter is in the queue and removes it.
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                } else if busy {
                    waiters.append(Waiter(id: id, continuation: cont))
                    lock.unlock()
                } else {
                    busy = true
                    lock.unlock()
                    cont.resume()
                }
            }
        } onCancel: {
            lock.lock()
            let index = waiters.firstIndex { $0.id == id }
            let waiter = index.map { waiters.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume()
        }
    }
}
