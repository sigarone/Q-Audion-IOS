import Foundation

/// Whether the device's protected data is readable right now, readable from ANY queue.
///
/// The app layer updates it from `UIApplication.protectedDataWillBecomeUnavailableNotification` /
/// `protectedDataDidBecomeAvailableNotification` (and once at start-up). Work that runs off the main thread and
/// memory-maps files of the app's default Data Protection class (model inference writes and maps compiled copies of
/// its model) reads it to stay idle while the phone is locked: touching such a page after the lock faults.
/// A plain lock-guarded Bool, because `UIApplication.isProtectedDataAvailable` is main-thread-only.
public final class ProtectedDataFlag: @unchecked Sendable {
    public static let shared = ProtectedDataFlag()

    private let lock = NSLock()
    private var available = true

    public init() {}

    public var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return available
    }

    /// Returns true when the value actually changed.
    @discardableResult
    public func set(isAvailable value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = available != value
        available = value
        return changed
    }
}
