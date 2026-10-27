import Foundation

/// The callee's "no valid OFFER after answering" decision, as a pure value so it can be tested without `AppState`.
///
/// A phone running a build that cannot speak the current signed handshake may send nothing the callee can parse as an
/// OFFER at all. The user who answered would then stay on "key exchange" until the generic timeouts. This watchdog
/// is armed when the user answers; when its window ends, a call that is still the answered one and whose OFFER has
/// not been processed, and the link was healthy, ends with `CallCloseReason.peerIncompatible`. A dead or unproven link
/// (our `call_accepted` never left, the socket is down) says nothing about the peer: no verdict, the existing setup
/// timeouts act. A malformed OFFER that did arrive never waits for
/// this: it already ends the call at once. No check is relaxed.
public enum CalleeOfferWatchdog {
    /// How long after the answer a valid OFFER may still arrive (the caller re-sends it every 5 s).
    public static let windowSeconds: TimeInterval = 30

    public enum Verdict: Equatable, Sendable {
        /// The call moved on (ended, replaced) or the OFFER was processed: nothing to do.
        case nothing
        /// Still the answered call, still no processed OFFER: end it as `peer_incompatible`.
        case endPeerIncompatible
    }

    /// `watchedCallId`: the call the watchdog was armed for. `activeCallId`: the call live now (nil when none).
    /// Ids are compared case-insensitively (the wire id and the CallKit uuid differ only in case).
    /// `linkHealthy`: `call_accepted` left on an authenticated socket and the socket is still authenticated.
    public static func verdict(watchedCallId: String, activeCallId: String?, offerProcessed: Bool, linkHealthy: Bool) -> Verdict {
        guard let active = activeCallId, !active.isEmpty,
              active.lowercased() == watchedCallId.lowercased() else { return .nothing }
        return (offerProcessed || !linkHealthy) ? .nothing : .endPeerIncompatible
    }
}
