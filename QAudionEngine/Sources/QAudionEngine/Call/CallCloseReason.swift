import Foundation

/// The close reasons of the v5/v6 handshake, the only free-form reasons a call end may carry into telemetry
/// and the call history. An allow-list: anything else is never recorded as a reason, and each case has a
/// stable key for its user-facing label.
///
/// - `dtls_fp_mismatch`, `kcmac_mismatch`, `handshake_malformed`: the signed handshake or the key
///   confirmation ended the call.
/// - `sas_commit_mismatch`, `sas_reveal_timeout` (transcript v6): the caller's SAS nonce did not open its
///   commitment (or the REVEAL was ill-formed), or no verified REVEAL arrived within `CONFIRM_TIMEOUT` (15 s) of this
///   device's first ACCEPT send. Security reasons: the peer is notified like for `kcmac_mismatch`.
/// - `identity_unresolved`, `identity_key_mismatch`: the peer's identity could not be trusted (no pin and
///   no server key, or a key that differs from the pin); the call is held pending the SAS and was closed
///   before the user confirmed it.
public enum CallCloseReason: String, CaseIterable, Sendable {
    case dtlsFpMismatch = "dtls_fp_mismatch"
    case kcmacMismatch = "kcmac_mismatch"
    case handshakeMalformed = "handshake_malformed"
    case identityUnresolved = "identity_unresolved"
    case identityKeyMismatch = "identity_key_mismatch"
    case sasCommitMismatch = "sas_commit_mismatch"
    case sasRevealTimeout = "sas_reveal_timeout"

    /// The allow-list check: the reason when `wire` is exactly one of the seven tokens, else `nil`.
    public static func accepted(_ wire: String?) -> CallCloseReason? {
        guard let wire = wire else { return nil }
        return CallCloseReason(rawValue: wire)
    }

    /// The seven tokens, so an egress redactor can recognise them verbatim and leave them intact.
    public static var allTokens: [String] { allCases.map { $0.rawValue } }

    /// Key of the user-facing label (Localizable.xcstrings): `call_history.close.<token>`.
    public var labelKey: String { "call_history.close." + rawValue }

    /// The reason a call end reports: a handshake fatal always wins; otherwise the identity hold the call
    /// was still in when it ended (`heldIdentityCode`, the verdict code of the media hold), when that is
    /// one of the two identity reasons. Every other hold code (invalid signature, downgrade) is not a
    /// close reason and yields `nil`.
    public static func forEnd(fatalReason: String?, heldIdentityCode: String?) -> CallCloseReason? {
        if let fatal = accepted(fatalReason) { return fatal }
        guard let held = accepted(heldIdentityCode) else { return nil }
        switch held {
        case .identityUnresolved, .identityKeyMismatch: return held
        default: return nil
        }
    }
}
