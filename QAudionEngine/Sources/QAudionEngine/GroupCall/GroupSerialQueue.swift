import Foundation

/// Group calls v2 (spec §4.3) — "all renegotiations of a PC are strictly
/// serialized through one queue per PC (debounce 150 ms, never two in
/// flight)".
///
/// One instance per PeerConnection. `run` executes operations first-in
/// first-out and NEVER lets two overlap, even though each operation awaits
/// (an actor alone would not guarantee that: it re-enters at every `await`).
/// `debounce` coalesces bursts: only the last operation registered under a key
/// within the quiet window runs, and it then runs through the same FIFO.
public actor GroupSerialQueue {

    public static let defaultDebounceMs: UInt64 = 150

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private let debounceMs: UInt64
    private let sleepMs: @Sendable (UInt64) async -> Void

    /// Operations that have started running, in order — read by tests.
    public private(set) var startedCount = 0
    /// Highest number of operations ever running at once (must stay 1).
    public private(set) var maxConcurrent = 0
    private var running = 0

    public init(debounceMs: UInt64 = GroupSerialQueue.defaultDebounceMs,
                sleepMs: @escaping @Sendable (UInt64) async -> Void = { ms in
                    try? await Task.sleep(nanoseconds: ms * 1_000_000)
                }) {
        self.debounceMs = debounceMs
        self.sleepMs = sleepMs
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Baton pass: `busy` stays true for the next waiter.
            waiters.removeFirst().resume()
        }
    }

    /// Runs `operation` after every previously submitted one has finished.
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        running += 1
        startedCount += 1
        if running > maxConcurrent { maxConcurrent = running }
        defer {
            running -= 1
            release()
        }
        return try await operation()
    }

    /// Schedules `operation` to run once the key has been quiet for the
    /// debounce window (default 150 ms). A newer call with the same key
    /// replaces the pending one.
    public func debounce(key: String, _ operation: @escaping @Sendable () async -> Void) {
        debounceTasks[key]?.cancel()
        let window = debounceMs
        let sleeper = sleepMs
        debounceTasks[key] = Task { [weak self] in
            await sleeper(window)
            if Task.isCancelled { return }
            await self?.runDebounced(key: key, operation)
        }
    }

    private func runDebounced(key: String, _ operation: @escaping @Sendable () async -> Void) async {
        debounceTasks[key] = nil
        await run { await operation() }
    }

    /// Drops every pending debounced operation (call teardown).
    public func cancelPending() {
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
    }
}
