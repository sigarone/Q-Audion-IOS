import Foundation
import CryptoKit

/// C-3 (2026-07-26) — the on-disk shape of a persisted SAS verification, and the
/// only place that decides whether one still applies.
///
/// A stored SAS confirmation used to be the SAS fingerprint alone. Two callers then
/// treated its mere PRESENCE as "the user verified this contact", never comparing it
/// to anything, so after the server rotated a contact's identity key the stale
/// record kept rendering that contact as verified — the user's most durable trust
/// signal vouching for a key they had never seen. `PeerTrustEvaluator` documented
/// the hole as though it were a limitation: "we can only check was ANY SAS ever
/// confirmed for this peer".
///
/// The record now carries the identity key the ceremony was performed against, so a
/// rotation invalidates it by construction rather than by someone remembering to
/// call `clear`.
///
/// This type lives in the engine, not next to the Keychain wrapper it serves, for a
/// blunt reason: `QAudionAppTests` is not compiled by the CI job that runs on every
/// push, and `QAudionEngineTests` is. A rule that decides whether a verification
/// still holds does not belong in the half of the repo the gate cannot see.
public struct SasBinding: Equatable, Sendable {

    /// SHA-256/16 of the SAS words the two users read to each other.
    public let sasFingerprint: String

    /// SHA-256/16 of the identity key PINNED for the peer at confirmation time.
    ///
    /// Derived from the pin rather than from the key observed on the call, on
    /// purpose: the pin is what a rotation has to move, so the check answers "is
    /// this still the identity I compared" instead of merely "did the bytes on this
    /// particular call happen to match".
    public let identityTag: String

    /// Cannot occur inside either half — both are lowercase hex.
    public static let separator: Character = ":"

    public init(sasFingerprint: String, identityTag: String) {
        self.sasFingerprint = sasFingerprint
        self.identityTag = identityTag
    }

    /// The single string written to the Keychain.
    public var encoded: String { "\(sasFingerprint)\(Self.separator)\(identityTag)" }

    /// Parse a stored value.
    ///
    /// Returns `nil` for anything that is not a complete binding, INCLUDING a value
    /// written before the binding existed — such a record has no separator, and
    /// reporting it as absent costs one benign re-verify. Accepting it instead would
    /// keep the vulnerability alive for exactly the accounts verified longest ago,
    /// which is the opposite of what a fix should do. The same store already required
    /// a one-off re-verify when the M-7 hash change landed, so the precedent is set.
    public static func decode(_ raw: String) -> SasBinding? {
        let parts = raw.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return SasBinding(sasFingerprint: String(parts[0]), identityTag: String(parts[1]))
    }

    /// The identity binding for a pinned Ed25519 key.
    public static func identityTag(forPinnedKey key: Data) -> String {
        SHA256.hash(data: key).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Does this record still apply to `currentIdentityTag`?
    ///
    /// Constant-time, and the SAS half is deliberately NOT consulted: outside a call
    /// there are no SAS words to compare, and the identity half is the one a rotation
    /// invalidates. This is the check the two presence-only call sites needed.
    public func appliesTo(currentIdentityTag: String) -> Bool {
        Self.constantTimeEquals(identityTag, currentIdentityTag)
    }

    /// Full in-call check: the SAS words of THIS call and the identity they were
    /// compared against must both match.
    public func matches(sasFingerprint fp: String, identityTag tag: String) -> Bool {
        // Both compared unconditionally — `&&` between the calls would short-circuit
        // on the first and reintroduce the timing signal M-7 removed.
        let a = Self.constantTimeEquals(sasFingerprint, fp)
        let b = Self.constantTimeEquals(identityTag, tag)
        return a && b
    }

    /// Byte-wise, no data-dependent early return. Length still short-circuits:
    /// both inputs are hex of a fixed-size hash, so length is not secret.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        if ab.count != bb.count { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
