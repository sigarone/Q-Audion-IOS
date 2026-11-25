import Foundation
import UIKit
import QAudionEngine

/// Gives the post-call work of the contact-voice check the time of a background-task assertion. The engine package does not use
/// `UIApplication`; this hands it the two calls. Nothing runs here while the check is off: the engine asks only when a call that
/// had a check ends.
enum VoiceBackgroundTaskBridge {
    static func install() {
        VoiceCallWiring.setBackgroundTasks(begin: begin, end: end)
        // The lines of the contact-voice check go to the log. The per-call lines (each has a call number) are written only for an
        // account that has the diagnostic flag; the id-free daily counters are written whenever the check runs.
        VoiceCallWiring.setLogging(
            sink: { RTLog.info("call", $0) },
            diagLinesEnabled: { FeatureFlags.bool("voice.diag_lines", false) })
        // The card of the call screen follows the state of the check.
        VoiceCallWiring.setDisplayHandler { display in
            DispatchQueue.main.async { VoiceCheckModel.shared.set(display) }
        }
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
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
    }
}
