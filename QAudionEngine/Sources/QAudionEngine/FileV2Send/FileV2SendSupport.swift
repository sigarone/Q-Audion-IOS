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
