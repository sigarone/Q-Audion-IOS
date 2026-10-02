import Foundation
import QAudionEngine

/// User-facing label of an allow-listed call close reason (`CallCloseReason`), shown in the call
/// history. `nil` for no reason or for anything outside the allow-list: a free-form string is never
/// rendered.
enum CallCloseReasonLabel {
    static func text(for token: String?) -> String? {
        guard let reason = CallCloseReason.accepted(token) else { return nil }
        switch reason {
        case .dtlsFpMismatch:
            return String(localized: "call_history.close.dtls_fp_mismatch",
                          defaultValue: "terminata: impronta di connessione non valida",
                          comment: "Call history row subtitle — the call ended because the media connection's certificate fingerprint did not match the one signed in the handshake")
        case .kcmacMismatch:
            return String(localized: "call_history.close.kcmac_mismatch",
                          defaultValue: "terminata: conferma delle chiavi non riuscita",
                          comment: "Call history row subtitle — the call ended because the two phones could not confirm they derived the same keys")
        case .handshakeMalformed:
            return String(localized: "call_history.close.handshake_malformed",
                          defaultValue: "terminata: handshake non valido",
                          comment: "Call history row subtitle — the call ended because the other side's secure handshake was malformed")
        case .identityUnresolved:
            return String(localized: "call_history.close.identity_unresolved",
                          defaultValue: "terminata: identità non verificata",
                          comment: "Call history row subtitle — the call was closed before the other person's identity was verified (the words were never confirmed)")
        case .identityKeyMismatch:
            return String(localized: "call_history.close.identity_key_mismatch",
                          defaultValue: "terminata: chiave di identità cambiata",
                          comment: "Call history row subtitle — the call was closed while the other person's identity key differed from the one already trusted")
        case .sasCommitMismatch:
            return String(localized: "call_history.close.sas_commit_mismatch",
                          defaultValue: "terminata: codice di sicurezza non valido",
                          comment: "Call history row subtitle — the call ended because the security code the other side revealed did not match what it had committed to")
        case .sasRevealTimeout:
            return String(localized: "call_history.close.sas_reveal_timeout",
                          defaultValue: "terminata: codice di sicurezza non ricevuto",
                          comment: "Call history row subtitle — the call ended because the other side's security code never arrived")
        }
    }
}
