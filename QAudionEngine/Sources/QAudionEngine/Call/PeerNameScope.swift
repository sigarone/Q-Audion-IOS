import Foundation

/// W-CALLERBUSY (2026-10-03, review of #169) — whose call the name / short number / avatar that `ContentView` holds
/// in `outgoingDisplayName`, `outgoingShortNumber` and `outgoingAvatarUrl` were resolved for.
///
/// ## The leak
///
/// Those three `@State` values are resolved from `AppState.callContactId` (`resolveOutgoingName`), and the 1:1
/// incoming ring reuses them (it prefers `outgoingDisplayName` over `AppState.incomingCallerName`), so the ring and
/// the connecting screen that follows show the identical name. The outcome screen after a busy / unreachable callee
/// deliberately keeps them past the moment `callContactId` becomes `nil` (it still has to say whom it dialled), and
/// until now nothing cleared them afterwards: the first frame of the NEXT incoming call, before its own
/// `onChange(of: callContactId)` had resolved the new caller, showed the person just dialled.
///
/// ## The rule
///
/// A resolved name may be shown for a call only when it was resolved for THAT call's contact. `ContentView` records
/// the contact id each resolution was made for (`outgoingResolvedFor`, `nil` when it cleared them) and the incoming
/// screen takes the resolved values only when ``matches(resolvedFor:callContactId:)``; otherwise it falls back to the
/// wire name and shows neither a stale number nor a stale avatar.
public enum PeerNameScope {

    /// `true` when values resolved for `resolvedFor` belong to the call whose contact is `callContactId`. Both ids
    /// must be present and equal (case-insensitive: wire ids drift in case across this code base): there is no
    /// outgoing call behind a `nil` contact, and nothing resolved can belong to a call with none.
    public static func matches(resolvedFor: String?, callContactId: String?) -> Bool {
        guard let resolvedFor, !resolvedFor.isEmpty, let callContactId, !callContactId.isEmpty else { return false }
        return resolvedFor.caseInsensitiveCompare(callContactId) == .orderedSame
    }

    /// The name the 1:1 incoming ring shows: the resolved name when it is this caller's and non-empty, else the
    /// name the wire carried, else `nil` (the screen then says "unknown").
    public static func incomingRingName(
        resolvedName: String, resolvedFor: String?, callContactId: String?, wireName: String
    ) -> String? {
        if matches(resolvedFor: resolvedFor, callContactId: callContactId), !resolvedName.isEmpty {
            return resolvedName
        }
        return wireName.isEmpty ? nil : wireName
    }
}
