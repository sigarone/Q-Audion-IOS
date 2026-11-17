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
/// Not reentrant: a body must not call `run` on the same gate again (it would wait for itself).
/// Pure Foundation, so it is unit-tested on its own (EarbudSerialGateTests).
public final class EarbudSerialGate: @unchecked Sendable {

    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Runs `body` once every earlier caller has finished, and lets the next one in when it ends,
    /// by return or by throw. A caller that is cancelled while it waits still waits its turn.
    public func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(cont)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                cont.resume()
            }
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
            next.resume()
        }
    }
}
