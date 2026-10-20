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
        /// The vault's recorded class (`SovereignKeyVault.getKeyClass(name:)`); the
        /// advert order ranks `.hwOnly` entries first. `.shared` is what an entry
        /// with no recorded class already means.
        public let keyClass: SovereignKeyVault.KeyClass
        public let material: Data
        public let createdAt: Date?

        public init(
            name: String, origin: PskOrigin, keyClass: SovereignKeyVault.KeyClass = .shared,
            material: Data, createdAt: Date?
        ) {
            self.name = name
            self.origin = origin
            self.keyClass = keyClass
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
    /// (the entries of the former identity QR) — neither of which the wire protocol or
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
    /// the rest by the call-key priority (`CallKeyPriority`,
    /// docs/security/CALL_KEY_PRIORITY.md: the list the user can reorder in
    /// Key management; without a stored list the first-run order, hw_only keys,
    /// then KMS keys newest delivery first, then every other key
    /// oldest-registered first, tie-broken by name so the result never depends
    /// on Keychain's unspecified enumeration order), then map each surviving
    /// entry to its canonical fingerprint.
    ///
    /// Pure — no Keychain access — so it is unit-testable with plain
    /// `Entry` fixtures.
    public static func fingerprintsForAdvertisement(
        _ entries: [Entry], priority: CallKeyPriority = CallKeyPriority()
    ) -> [String] {
        eligibleSortedEntries(entries, priority: priority).map { canonicalFingerprint(forPsk: $0.material) }
    }

    /// W-NFCVISIBLE (2026-07-24, cross-platform audit) — the SAME filter+order
    /// `fingerprintsForAdvertisement` applies, extracted so both it and
    /// `rolesForAdvertisement` derive from ONE deterministic computation —
    /// two independent re-filters/re-sorts of the same input would still be
    /// order-identical (both pure functions), but sharing this avoids ever
    /// needing to keep two copies of the filter/sort logic in sync by hand.
    private static func eligibleSortedEntries(_ entries: [Entry], priority: CallKeyPriority) -> [Entry] {
        let eligible = entries.filter { isEligibleMatchCandidate(origin: $0.origin) }
        var byName: [String: Entry] = [:]
        for entry in eligible where byName[entry.name] == nil {
            byName[entry.name] = entry
        }
        let candidates = eligible.map { entry -> CallKeyPriority.Candidate in
            CallKeyPriority.Candidate(
                id: entry.name,
                group: CallKeyPriority.group(origin: entry.origin, keyClass: entry.keyClass),
                createdAt: entry.createdAt)
        }
        // The stored list is for the whole vault; the order of THESE entries is what it gives once the keys it
        // does not know are placed by the rule and the ones that are not here are left out.
        let ordered = CallKeyPriority.reconciled(stored: priority.stored, candidates: candidates)
        return ordered.ids.compactMap { byName[$0] }
    }

    /// W-NFCVISIBLE — parallel array to `fingerprintsForAdvertisement`, same
    /// order: `1` marks an NFC-origin fingerprint in this advert, else `0`.
    /// Lets a peer that ALSO holds this same fingerprint recognise "we share
    /// an NFC secret" independent of whether THIS call's session key ends up
    /// mixing a different (e.g. KMS) secret due to vault selection priority.
    /// The verdict never trusts this declared role: `AssuranceState.resolveNfcConfirmed`
    /// judges the LOCAL key's origin and bound identity. Mirrors
    /// Android's `PqcHandshake.kt` OFFER/ACCEPT role computation and Desktop's
    /// `AndroidBundleHandshake.ts` equivalent, shipped in the same commit series.
    public static func rolesForAdvertisement(
        _ entries: [Entry], priority: CallKeyPriority = CallKeyPriority()
    ) -> [Int] {
        eligibleSortedEntries(entries, priority: priority).map { PskAdvertV3.role(for: $0.origin) }
    }

    /// W-PSKBLIND (2026-07-25) — the same eligible entries, in the same order, as
    /// `fingerprintsForAdvertisement`/`rolesForAdvertisement`, but carrying the raw
    /// MATERIAL the §3.3.1 blinded tags need.
    ///
    /// Deriving all three from `eligibleSortedEntries` is the point: a v3 tag list and
    /// a static fingerprint list then describe the same secrets in the same priority
    /// positions, which the responder is required to honour. Two independently
    /// filtered/sorted lists would be a silent way for the advertised order to drift
    /// from the order the wire signature bound.
    public static func candidatesForAdvertisement(
        _ entries: [Entry], priority: CallKeyPriority = CallKeyPriority()
    ) -> [PskAdvertResolver.Candidate] {
        eligibleSortedEntries(entries, priority: priority).map {
            PskAdvertResolver.Candidate(
                staticFp: canonicalFingerprint(forPsk: $0.material),
                psk: $0.material,
                localRole: PskAdvertV3.role(for: $0.origin)
            )
        }
    }

    /// The form the call paths use: the order is the one the user keeps in Key management, read (and brought up to
    /// date with the vault) through `store`. The OFFER, the ACCEPT advert and every re-key build their advert from
    /// the same stored list, so they cannot disagree about which key comes first.
    public static func candidatesForAdvertisement(
        _ entries: [Entry], store: CallKeyPriorityStore
    ) -> [PskAdvertResolver.Candidate] {
        candidatesForAdvertisement(entries, priority: store.current())
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
        // W-IDKEYEXCL — `.identityKey` added alongside `.deviceInternal`: an
        // X25519 identity pubkey (this device's own rotated identity, or an
        // imported peer's) shares this vault's storage but is not a shared
        // secret and must never be treated as call-PSK material, same
        // reasoning as `.callDerived`.
        origin != .callDerived && origin != .deviceInternal && origin != .identityKey
    }
}
