import Foundation
import QAudionEngine

/// W-CALLERBUSY (2026-10-03) — the message the outgoing screen shows when the callee could not take the call.
/// "Occupato" is the word Android shows for `call_busy`; the unreachable one reuses the sentence the old
/// `call_peer_offline` handler wrote to `errorMessage` (which no call screen ever read).
enum CallerOutcomeText {
    static func message(for outcome: CallerTerminalOutcome) -> String {
        switch outcome {
        case .busy:
            return String(localized: "call.outgoing.busy",
                          defaultValue: "Occupato",
                          comment: "Outgoing call screen message — the person being called is already in another call")
        case .peerOffline:
            return String(localized: "call.outgoing.peer_offline",
                          defaultValue: "Il destinatario non è raggiungibile.",
                          comment: "Outgoing call screen message — the person being called cannot be reached right now")
        }
    }
}
