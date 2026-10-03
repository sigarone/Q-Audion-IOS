import XCTest

/// Fail-fast guard for tests that await a call which only returns because of a deadline the code
/// under test enforces (the coordinator's flight deadline). If that deadline is ever removed or
/// broken, a plain `await` hangs the whole suite until the CI job times out; with this the test
/// fails in `seconds` with a clear message instead.
///
/// Deliberately not a task group: a group waits for every child on exit, and the hung child is
/// exactly the thing that never finishes. The operation runs in an unstructured task that is
/// simply abandoned on a timeout.
enum AuthTestTimeLimit {

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?

        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

        func resume(_ value: T?) {
            let c: CheckedContinuation<T?, Never>? = lock.withLock {
                let c = continuation
                continuation = nil
                return c
            }
            c?.resume(returning: value)
        }
    }

    /// The operation's result, or nil if it did not finish within `seconds`.
    static func within<T: Sendable>(_ seconds: TimeInterval,
                                    _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once<T>(continuation)
            Task { once.resume(await operation()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(nil)
            }
        }
    }
}
