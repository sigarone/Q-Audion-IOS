import Foundation

/// W-ACCEPTDEVSTALE (2026-09-08, adversarial review of W-SASPIN /
/// W-CAPTURELIVE-SIGNAL) — pure lookup rule for the device id fed into the
/// caller's ACCEPT-leg verdict (`HandshakeSigningPolicy.evaluate` /
/// `applyAuthenticatedSideEffects`).
///
/// ## The bug this fences
///
/// `AppState.senderDeviceIdByPeer` stashes the server-stamped device id from
/// `call_incoming`, keyed by PEER, and is never cleared. That is correct for
/// the responder's OFFER read: the `call_incoming` for THIS exact call always
/// immediately precedes and overwrites it before the OFFER lands. It is WRONG
/// for the caller reading an ACCEPT: if peer X last called us from device A
/// (stashing A) and we later call X and X answers from a DIFFERENT device B,
/// the peer-keyed stash still holds stale A. Feeding A into the verdict would
/// repin `peer|A` instead of `peer|B` — silently corrupting an unrelated
/// account if `peer|A` was not yet SAS-verified (a verified `peer|A` is
/// protected separately by `PeerIdentityPinStore`'s write-once/verified-pin
/// guard, but an unverified one is not).
///
/// The fix is a SEPARATE stash keyed by call id rather than peer id, written
/// at the same `call_incoming` site. An outgoing call never receives an
/// inbound `call_incoming` for itself, so this correctly resolves to `nil` at
/// ACCEPT time — the same "legacy single-key + set-membership floor, never a
/// fatal mismatch" behaviour the code already documents, except now it is
/// actually always true instead of true only when the peer never called us
/// before.
public enum AcceptDeviceIdResolution {

    /// Resolve the device id to feed into a caller's ACCEPT-leg verdict for
    /// `callId`. Looks up ONLY the call-scoped stash — never a peer-scoped
    /// one, which by construction cannot distinguish "this call's answerer"
    /// from "whichever device this peer called FROM last, on some other
    /// call". Case-insensitive on `callId` to survive the iOS-uppercase /
    /// Android-lowercase call-id echo mismatch (W461).
    ///
    /// - Parameters:
    ///   - callId: the call id the ACCEPT bundle answers (e.g.
    ///     `AndroidHandshakeEnvelope.Parsed.callId`).
    ///   - callScopedStash: `AppState.senderDeviceIdByCallId` — device id by
    ///     lowercased call id, populated only from an INBOUND `call_incoming`.
    /// - Returns: the device id if this exact call had one stamped, else
    ///   `nil` (never a value borrowed from a different call).
    public static func callerAcceptDeviceId(
        callId: String,
        callScopedStash: [String: String]
    ) -> String? {
        callScopedStash[callId.lowercased()]
    }
}
