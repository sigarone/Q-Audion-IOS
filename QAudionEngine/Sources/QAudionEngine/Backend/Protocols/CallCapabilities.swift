import Foundation

/// Wire-format capability tags that travel inside `call_offer`/`call_answer`
/// (and their corresponding inbound events) under the `capabilities` field.
/// They let two peers agree at call setup which video/audio frame format to
/// use, without a separate roundtrip.
///
/// **Cross-platform contract:** Swift port of Kotlin
/// `com.bcrypto.qaudion.feature.call.domain.CallCapabilities` (Android) and
/// the equivalent TS constants in `qaudion-desktop`. The wire is plain JSON
/// strings, so any divergence between platforms is a simple string-equality
/// bug — easy to catch in cross-platform smoke tests + the KAT corpus.
///
/// **Design (option A in the cross-platform design):** capabilities live
/// inside the existing call-setup envelope. The bcrypto-server is pure
/// relay and never inspects them — agreement is a pure end-to-end
/// concern. Old clients that predate this field send no `capabilities`
/// key at all, which decodes to `nil` and is interpreted as "legacy peer".
///
/// Forward-compat: more tags can be added in v2 (`sframe-v2`,
/// `simulcast-v1`, etc.) without breaking older clients — they will
/// simply ignore unknown tags during the intersection.
public enum CallCapabilities {
    /// SFrame video frame format v1 (RFC 9605 + Q-Audion deviations §4-§5).
    public static let sframeV1: String = "sframe-v1"

    /// Capabilities advertised by THIS build of the iOS client.
    public static let local: [String] = [sframeV1]

    /// Outcome of a capability negotiation between local and peer.
    public struct Negotiated: Equatable, Sendable {
        /// True iff both sides advertise ``sframeV1``.
        public let useSFrame: Bool
        /// The intersection of advertised tags (sorted, deduped).
        public let agreedTags: [String]

        public init(useSFrame: Bool, agreedTags: [String]) {
            self.useSFrame = useSFrame
            self.agreedTags = agreedTags
        }
    }

    /// Compute the agreed capability set from the local list and the peer
    /// list. A `nil` peer list (decoded from a legacy client without the
    /// field, or from any older platform build) is treated as the empty
    /// list.
    ///
    /// Pure function — safe to call from any thread, no side effects.
    /// Returns by value (no preconditions / no traps) so XCTest can drive
    /// every edge case without crashing the test runner.
    public static func negotiate(
        local: [String] = local,
        peer: [String]?
    ) -> Negotiated {
        let peerSet = Set(peer ?? [])
        // De-duplicate while preserving the *local* declaration order, then
        // sort — matches Kotlin `local.filter { it in peerSet }.distinct().sorted()`
        // byte-for-byte for any possible input set.
        var seen = Set<String>()
        var intersection: [String] = []
        for tag in local where peerSet.contains(tag) && !seen.contains(tag) {
            seen.insert(tag)
            intersection.append(tag)
        }
        intersection.sort()
        return Negotiated(
            useSFrame: intersection.contains(sframeV1),
            agreedTags: intersection
        )
    }
}
