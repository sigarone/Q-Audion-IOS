import Foundation
import UIKit
import QAudionEngine

/// Gives the post-call work of the contact-voice check the time of a background-task assertion. The engine package does not use
/// `UIApplication`; this hands it the two calls. Nothing runs here while the check is off: the engine asks only when a call that
/// had a check ends.
enum VoiceBackgroundTaskBridge {
    static func install() {
        VoiceCallWiring.setBackgroundTasks(begin: begin, end: end)
        // The store of the contact voice belongs to the signed-in account, which is read here, once for the whole process: the
        // post-call write of a call and the deletion of a contact outside a call happen when no call object exists. The user id is
        // read from the keychain (what `AppState.currentUserIdSnapshot` returns), never from the main thread: the store runs on
        // background queues. Nobody signed in gives nil and the store refuses.
        VoiceCallWiring.setAccountProvider { TokenVault.loadUserId() }
        // The lines of the contact-voice check go to the log. The per-call lines (each has a call number) are written only for an
        // account that has the diagnostic flag; the id-free daily counters are written whenever the check runs.
        VoiceCallWiring.setLogging(
            sink: { RTLog.info("call", $0) },
            diagLinesEnabled: { diagLinesFlag() })
        // What a call reads once at its start: the owner setting together with the entitlement, and the owner template (read only, for a
        // diagnostic counter).
        VoiceCallWiring.setOwnerPolicy(
            ownerOn: { ContactVoiceSettings.shared.ownerOn }, ownerTemplate: { ContactVoiceSettings.ownerTemplate() },
            available: { ContactVoiceSettings.shared.available })
        // The card of the call screen follows the state of the check.
        VoiceCallWiring.setDisplayHandler { display in
            DispatchQueue.main.async { VoiceCheckModel.shared.set(display) }
        }
    }

    /// The flag is read on the main thread (the flags are main-actor state); the lines are written from the worker of the call, which
    /// waits for the answer: a handful of lines per call, and the main thread never waits for that worker.
    private static func diagLinesFlag() -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { FeatureFlags.bool("voice.diag_lines", false) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { FeatureFlags.bool("voice.diag_lines", false) } }
    }

    private static func begin(_ name: String, _ onExpiration: @escaping () -> Void) -> Int? {
        var raw: Int?
        let work = {
            let id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: onExpiration)
            raw = id == .invalid ? nil : id.rawValue
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
        return raw
    }

    private static func end(_ token: Int) {
        let id = UIBackgroundTaskIdentifier(rawValue: token)
        // From the expiration handler (main thread) the assertion must be ended before the handler returns.
        if Thread.isMainThread {
            UIApplication.shared.endBackgroundTask(id)
        } else {
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
        }
    }
}
