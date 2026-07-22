import Foundation
import CryptoKit

/// W-PSKMIX step 3 (iOS hygiene) — pure helpers for building the
/// `pskFingerprints` list this device advertises to a peer in the OFFER's
/// handshake-capability negotiation (WIRE_SPEC §3.3).
///
/// Deliberately free of any Keychain/Security dependency: the
/// filter+order+normalise logic lives here as plain data transforms over
/// `Entry` values, so it is unit-testable without touching the real
/// `SovereignKeyVault`. The one real call site
/// (`QAudionCallIntegration`'s OFFER builder) reads the vault, wraps each
/// entry as `Entry`, and hands the array to `fingerprintsForAdvertisement`.
public enum PskAdvertising {

    /// One vault entry, reduced to exactly what the advert builder needs.
    public struct Entry {
        public let name: String
        public let origin: PskOrigin
        public let material: Data
        public let createdAt: Date?

        public init(name: String, origin: PskOrigin, material: Data, createdAt: Date?) {
            self.name = name
            self.origin = origin
            self.material = material
            self.createdAt = createdAt
        }
    }

    /// `lc_hex(SHA-256(psk))` — the WIRE_SPEC §3.3 canonical fingerprint,
    /// the ONLY form ever placed on the wire (a full 64-character lowercase
    /// hex string). Some vault entries are labelled in a DIFFERENT format in
    /// their Keychain `kSecAttrLabel` — a 16-hex prefix
    /// (`AppState.installKmsPreBootstrapPsk`) or the dotted-group display
    /// form `Fingerprint.format(pubkey:)` produces
    /// (`KeyRotationCoordinator`) — neither of which the wire protocol or
    /// the matching gate (`QAudionCallIntegration.pskIfFingerprintMatches`)
    /// ever recognises. Recomputing from the raw key material here, instead
    /// of trusting whatever string happens to be stored as the entry's
    /// label, means such an entry is advertised in a form the peer can
    /// actually match — rather than being silently unmatchable dead weight
    /// in the advertised list.
    public static func canonicalFingerprint(forPsk psk: Data) -> String {
        SHA256.hash(data: psk).map { String(format: "%02x", $0) }.joined()
    }

    /// Filter out device-internal bookkeeping entries (this device's own
    /// long-term identity keys and the KMS name/epoch sidecars — anything
    /// with `origin == .deviceInternal`, i.e. the `__device.*` / `__kmsname.*`
    /// / `__kms.active_epoch.*` Keychain-account conventions) AND call/control-
    /// channel-derived entries (`origin == .callDerived` — Android's `"call-"`/
    /// `"msg-psk"` rows, and iOS's own `"auto:<prefix>:<peerId>"` group-control-
    /// channel ratchet seed installed by `AppState.installKmsPreBootstrapPsk`).
    /// The latter exclusion mirrors Android's `PqcHandshake.loadEligiblePsks`,
    /// which never puts `CALL_DERIVED` rows in its allowlist: that seed is
    /// meant to evolve forward for the group-control ratchet, not be mixed
    /// as a static 1:1-call audio PSK — a rotation or compromise on either
    /// side would otherwise unintentionally couple into the other. Then order
    /// the rest deterministically (oldest-registered first, tie-broken by name
    /// so the result never depends on Keychain's unspecified enumeration
    /// order), then map each surviving entry to its canonical fingerprint.
    ///
    /// Pure — no Keychain access — so it is unit-testable with plain
    /// `Entry` fixtures.
    public static func fingerprintsForAdvertisement(_ entries: [Entry]) -> [String] {
        entries
            .filter { $0.origin != .deviceInternal && $0.origin != .callDerived }
            .sorted(by: isOrderedBefore)
            .map { canonicalFingerprint(forPsk: $0.material) }
    }

    /// W-PSKMIX step 5 — the RECEIVE-side twin of the exclusion above.
    ///
    /// `fingerprintsForAdvertisement` keeps a `.callDerived` entry off the
    /// wire on the ADVERTISE side. That alone is not defense-in-depth: three
    /// call sites independently scan/match the LOCAL vault by fingerprint
    /// against a peer-supplied value with no origin check at all —
    /// `AppState.routeInboundAndroidOffer`/`routeInboundAndroidAccept`
    /// building the responder/caller's `eligiblePsks` catalogue from the
    /// peer's advertised fingerprint list, and
    /// `QAudionCallIntegration`'s post-ACCEPT lookup of the responder's
    /// echoed `selectedPskFingerprint`. Today nothing on a fixed client ever
    /// puts a `.callDerived` fingerprint on the wire, so there is nothing for
    /// these sites to match against in practice — but an unpatched peer, a
    /// future regression in `fingerprintsForAdvertisement`, or a build
    /// predating that fix would leave these paths silently accepting one.
    /// Each call site filters its vault-name candidates through this
    /// predicate before ever comparing fingerprints, so a `.callDerived`
    /// entry is never a valid match candidate — exactly as it is never
    /// advertised.
    ///
    /// Pure — takes an already-resolved `PskOrigin`, no Keychain access — so
    /// it is unit-testable without touching the real `SovereignKeyVault`,
    /// same as `fingerprintsForAdvertisement` above.
    public static func isEligibleMatchCandidate(origin: PskOrigin) -> Bool {
        origin != .callDerived
    }

    /// Stable-order comparator: earliest `createdAt` first; entries with no
    /// recorded creation date sort after those that have one; a tie (or two
    /// entries both missing a date) breaks by `name`. So two calls over the
    /// same vault state — even across separate app launches — always
    /// produce the identical order, unlike raw Keychain enumeration order.
    static func isOrderedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (l?, r?) where l != r: return l < r
        case (nil, .some): return false
        case (.some, nil): return true
        default: return lhs.name < rhs.name
        }
    }
}
