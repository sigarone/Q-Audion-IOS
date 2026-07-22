import Foundation

/// W-ORPHANPEER (2026-07-22) — what to do with a local contact whose account
/// no longer exists on the server. Third of a three-platform port; Desktop
/// shipped `src/renderer/lib/peerOrphanPolicy.ts` (e5a6041) and Android
/// `data/contact/PeerOrphanPolicy.kt` (07302722). The three clients have to
/// agree about who exists.
///
/// These devices' local databases have survived many reinstalls and hold
/// contacts pointing at accounts the server no longer has a user row for. They
/// render as permanent short8 placeholders and — the part that actually
/// matters — look reachable. Confirmed against the server's own access log
/// before any of this was written: `GET /api/v1/users/{id}` returns a real 404
/// for them, fourteen of fourteen.
///
/// ## The distinction that makes this safe
///
/// "The account does not exist" is NOT "the account is unreachable right now",
/// and only the first may hide anything. A network failure, a 401, a 5xx, a
/// timeout or a request that never left the device all mean "we do not know",
/// and not knowing must hide nobody.
///
/// On iOS that needs care for a specific reason: `AccountApi.getPublicUser`
/// returns a non-optional and throws for everything, so the idiomatic
/// `try? await ...` collapses a deleted account and a dropped connection into
/// the same `nil`. There is such a call in the tree already
/// (`InCallContainer.swift`, peer-name fetch) — it is fine for its own purpose
/// and must not be reused as the orphan signal. `getPublicUserIfExists`
/// exists for this, shaped exactly like the pre-existing `lookupByExtension`.
///
/// ## Reversible by construction
///
/// Nothing is deleted and nothing is persisted. The orphan set lives in memory
/// for the life of the process and is re-derived from live lookups on every
/// launch, so a restored backup, a corrected environment or a fixed server bug
/// brings the contact straight back with no user action, and the mark also
/// lifts mid-session the moment a lookup succeeds.
///
/// Message history is never hidden. Those messages are end-to-end encrypted
/// and exist nowhere else; the account being gone does not make them
/// disposable.
///
/// ## Known limit, shared by all three platforms
///
/// A contact is only discovered as an orphan if something actually looks its
/// profile up, and every client only looks up peers whose local row cannot
/// already produce a name. So a stale contact that still carries a good local
/// alias is never probed and stays visible. That is on purpose for now: the
/// contacts that manifest the problem are exactly the ones stuck on a short8
/// placeholder, which is precisely the case that does get probed. Making it
/// exhaustive means a launch-time sweep over the whole address book, which is
/// a separate decision about request volume — recorded here rather than left
/// as a silent gap.
///
/// ## Wired so far
///
/// The address book and the "who can I reach" pickers, via
/// ``shouldHideContact(_:)``. ``shouldHideConversation(peerIsOrphan:messageCount:)``
/// is defined and tested but not yet called from any chat list, on any
/// platform.

/// What a profile lookup actually told us about a peer.
public enum ProfileLookupOutcome: Sendable, Equatable, CaseIterable {
    /// The server answered and the user exists.
    case exists
    /// The server answered 404 — no such user row. The one actionable case.
    case absent
    /// Offline, 401, 5xx, timeout, cancelled. Tells us nothing.
    case unknown
}

/// Classify the result of a `GET /api/v1/users/{id}` round-trip.
///
/// - Parameters:
///   - succeeded: whether the call returned a decoded profile at all.
///   - httpStatus: the HTTP status when the call failed carrying one
///     (`BCryptoError.httpError(status)`); `nil` for transport-level failures
///     that never got a status — offline, DNS, TLS, timeout, cancellation.
public func classifyProfileLookup(succeeded: Bool, httpStatus: Int?) -> ProfileLookupOutcome {
    if succeeded { return .exists }
    return httpStatus == 404 ? .absent : .unknown
}

/// Should this peer be treated as an orphan — hidden from the address book and
/// from every "who can I reach" picker?
///
/// Takes the outcome rather than a `Bool` on purpose, so a call site cannot
/// pass "the lookup failed" where "the user is gone" was meant.
public func isOrphanPeer(_ outcome: ProfileLookupOutcome) -> Bool {
    outcome == .absent
}

/// Should this contact disappear from the address book and from the pickers
/// that answer "who can I call or write to"?
///
/// NOT from label resolution: an existing conversation with an orphan keeps its
/// row and still gets a name, because the history stays readable.
public func shouldHideContact(_ peerIsOrphan: Bool) -> Bool {
    peerIsOrphan
}

/// Should a conversation with an orphan peer disappear from the chat list?
///
/// Only when it carries nothing at all. One message is enough to keep it — see
/// the type-level note on why history is never hidden.
public func shouldHideConversation(peerIsOrphan: Bool, messageCount: Int) -> Bool {
    peerIsOrphan && messageCount <= 0
}
