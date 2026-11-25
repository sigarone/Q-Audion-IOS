import Foundation

/// The flag of the contact-voice check. It is off: with it off nothing of the check runs in a call. No tap sink is installed, no
/// poll is started, no queue, model or store is created or touched, and no inference time is reported to the budget. Every entry
/// point of the call wiring reads it first and returns.
enum VoiceFeature {
    private static let lock = NSLock()
    private static var provider: () -> Bool = { false }

    /// The value of the flag now.
    static var isEnabled: Bool {
        lock.lock()
        let read = provider
        lock.unlock()
        return read()
    }

    /// Replaces the source of the flag (tests; the app sets it when the feature ships).
    static func setProvider(_ read: @escaping () -> Bool) {
        lock.lock()
        provider = read
        lock.unlock()
    }

    /// Back to off.
    static func reset() {
        setProvider { false }
    }
}
