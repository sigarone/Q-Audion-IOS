import Foundation

/// The few things of the contact-voice check that the app layer reaches. Every one of them does nothing while the check is off.
public enum VoiceCallWiring {
    /// A call, incoming or outgoing, starts: the post-call work of earlier calls is cancelled and never resumed.
    public static func callStarting() {
        guard VoiceFeature.isEnabled else { return }
        VoiceProcess.shared.cancelPostCallWork()
    }

    /// Where the lines of the log go, and whether the per-call lines are written for this account (the `voice.diag_lines` flag of the
    /// account). The id-free daily counters are written whatever the second closure says, whenever the engine runs.
    public static func setLogging(sink: @escaping (String) -> Void, diagLinesEnabled: @escaping () -> Bool) {
        VoiceProcess.shared.setLogging(sink: sink, diagLinesEnabled: diagLinesEnabled)
    }

    /// Receives the state that the voice card shows, and nil when there is nothing to show (no check, or the call is over).
    /// Called on a background queue: the app moves it to the main thread.
    public static func setDisplayHandler(_ handler: @escaping (VoiceCheckDisplay?) -> Void) {
        VoiceProcess.shared.setDisplayHandler(handler)
    }

    /// The contact was deleted or blocked: the calls with it write nothing any more and its record is deleted. Works before any call
    /// of the process, and does nothing when no record was ever written.
    public static func contactRemoved(userId: String) {
        VoiceProcess.shared.forgetContact(userId)
    }

    /// The voice step of the local wipe (logout, account change, remote wipe, account deletion): every running or post-call engine is
    /// stopped and discarded, then the records, `meta.bin` and the key are deleted under the store's lock. False when something is
    /// left or a step failed; the caller reports it like any other failed step.
    @discardableResult
    public static func wipeAll() -> Bool {
        VoiceProcess.shared.wipeAll()
    }

    /// The source of the background-task assertion that the post-call work runs under (the app provides it once).
    public static func setBackgroundTasks(
        begin: @escaping (_ name: String, _ onExpiration: @escaping () -> Void) -> Int?,
        end: @escaping (_ token: Int) -> Void
    ) {
        VoiceProcess.shared.backgroundTasks = ClosureBackgroundTasks(begin: begin, end: end)
    }

    private final class ClosureBackgroundTasks: VoiceBackgroundTasks {
        private let beginTask: (String, @escaping () -> Void) -> Int?
        private let endTask: (Int) -> Void

        init(begin: @escaping (String, @escaping () -> Void) -> Int?, end: @escaping (Int) -> Void) {
            beginTask = begin
            endTask = end
        }

        func begin(name: String, onExpiration: @escaping () -> Void) -> Int? { beginTask(name, onExpiration) }
        func end(_ token: Int) { endTask(token) }
    }
}
