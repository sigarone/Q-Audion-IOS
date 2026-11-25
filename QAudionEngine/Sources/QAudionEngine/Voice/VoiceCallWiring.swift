import Foundation

/// The few things of the contact-voice check that the app layer reaches. Every one of them does nothing while the check is off.
public enum VoiceCallWiring {
    /// A call, incoming or outgoing, starts: the post-call work of earlier calls is cancelled and never resumed.
    public static func callStarting() {
        guard VoiceFeature.isEnabled else { return }
        VoiceProcess.shared.cancelPostCallWork()
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
