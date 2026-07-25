import Foundation

/// W-ASSURANCE (multi-PSK-mixing SYNTHESIS.md ship step 6/8) — the TOTAL, first-match-
/// wins policy that turns this call's live cryptographic signals into a single,
/// user-facing trust verdict.
///
/// **Structural sibling of `HwOnlyCallPolicy`** — same shape (a total decision function
/// over a fixed input tuple, one enum case per outcome, first match wins), same
/// discipline (W-NOBRICK: every branch below leaves the call running; a security
/// finding is signaled, never used to drop/block a connection).
///
/// **What's reachable.** `N` stays capped at ≤1 everywhere and no capability flag is
/// flipped (see `KeyConfirmation`'s doc) — this function does NOT implement N>=2
/// PSK-mixing (that plan, `canonicalOrder`/`K_mix` aggregation, was proposed and then
/// explicitly rejected as too risky/unnecessary). What DID ship (W-NFCBADGE,
/// 2026-07-23): the app layer (`AppState.emitKeyConfirmationTelemetry`, via
/// `resolveNfcMixInputs` below) now feeds `mixRoles = [.nfc]` — instead of the old
/// hardcoded `[.psk]`/`[]` placeholder — whenever the SINGLE selected PSK's vault entry
/// actually came from a live NFC tap (`PskOrigin.nfc`, `SovereignKeyVault.origin(name:)`).
/// So for a real call whose one selected key is NFC-derived, `S2`–`S6` ARE reachable in
/// production, exactly like `S0`/`S1`/`S7`–`S10` always were — `mixRoles` containing
/// `.nfc` no longer requires `N>=2`, it only requires the one key iOS already selects to
/// be NFC-origin. See `iosOriginatesS2Witness`'s doc below for the narrower claim that
/// DOES still hold (iOS cannot itself be read as the HCE/witness side of a tap).
///
/// **Never share a widget.** The value this function returns is the LIVE, per-call
/// verdict (computed fresh from THIS handshake). A contact's history record ("this
/// contact has been authenticated in person before") is a SEPARATE, longer-lived
/// concept — never let one render as if it were the other.
///
/// This is the iOS port of the Android reference
/// `apps/qaudion-android-new/qaudion-engine/src/main/java/com/bcrypto/qaudion/crypto/AssuranceState.kt`
/// and Desktop's `src/main/calling/AssuranceState.ts` — all three MUST agree on the
/// shared cross-platform KAT vectors (`AssuranceStatePolicyTests.swift`).
public enum AssuranceState: Equatable {

    /// S0 — the peer's app doesn't advertise `pskMixV1` at all. Evaluated BEFORE every
    /// other state (in particular before S7): a legacy peer must never be accused of
    /// stripping a PSK/NFC secret it never had the capability to mix in the first place.
    case peerLegacy
    /// S1 — the peer's `kc_mac` arrived but did not verify: an active-attack signature
    /// (permuted/shrunk advert list, reflected MAC, swapped identity keys, …).
    case kcFailed
    /// S2 — UNREACHABLE this step (requires `N>=2`, step 7, not shipped). Implemented
    /// so the function is total and so step 7 doesn't need to touch this file again.
    case nfcAuthenticated
    /// S3 — an NFC secret was mixed and `kc_mac` verified, but it was bound to a
    /// DIFFERENT peer identity key than the one on this call.
    case nfcIdentityMismatch
    /// S4 — NFC secret correctly bound to this identity but restored from an
    /// un-attestable backup (no secure-element witness on this device).
    case nfcUnattestable
    /// S5 — NFC mixed + `kc_mac` verified + bound + witnessed, but the Ed25519
    /// transcript signature did not verify.
    case identityUnverified
    /// S6 — NFC genuinely mixed this call but the peer's `kc_mac` never arrived
    /// (5000ms deadline elapsed, or the peer doesn't support key confirmation).
    case nfcPresentUnconfirmed
    /// S7 — this contact's NFC secret was expected (a PAST call previously reached
    /// `S2`) but this call fell back to plain PSK (or no PSK at all) without it — a
    /// genuine per-contact regression.
    ///
    /// W-NFCCOMMON (2026-07-24, Pavel correction): no longer ALSO fires merely because
    /// the peer advertises a mutual NFC-tier fingerprint this call didn't mix — that is
    /// a routine outcome (vault-selection priority picked a different secret, e.g. KMS)
    /// and not a downgrade worth a suspended-badge security event. That fact is instead
    /// exposed as its own independent, always-on "NFC in comune" signal (see
    /// `mutualPeerAdvertisedRoles`), additive to whichever of `S2`/`S8`/`S9`/`S10`
    /// actually fires — never folded into this single-select verdict.
    case expectedNfcStripped
    /// S8 — ordinary `N>=1` pre-shared-key call, no NFC involved, `kc_mac` verified.
    case pskConfirmed
    /// S9 — same as S8 but `kc_mac` did not arrive/verify.
    case pskUnconfirmed
    /// S10 — `N==0`: no pre-shared key at all, PQC-only session.
    case pqcOnly

    /// The set of secret "kinds" this call actually mixed into `K_mix` this session.
    /// `NFC`/`PSK`/`HW_KEY` mirror the design's `presenceAuth` tiers — a purely
    /// descriptive tag, not itself a trust decision.
    public enum MixSecretRole: String, Equatable, Hashable {
        case nfc = "NFC"
        case psk = "PSK"
        case hwKey = "HW_KEY"
    }

    /// R6 (multi-PSK-mixing design doc, authoritative per this feature's own spec):
    /// iOS never ORIGINATES (hosts/emulates) the witness side of an NFC tap — it is
    /// always the READER. Corroborating evidence already in this codebase:
    /// `NfcCollaborativeExchange` is documented as "Drives an **iOS-reader** NFC
    /// collaborative pairing session", and `NfcApduExchange` (the live-pairing path)
    /// is the ISO-7816 READER against an Android `HostApduService` card — CoreNFC on
    /// iOS exposes reader-mode (`NFCTagReaderSession`) only, with no public
    /// host-card-emulation API, so this device can never be the one an Android peer
    /// taps to attest ITS OWN presence. This is a statement about iOS's structural
    /// ROLE in the exchange (reader vs. card), not about whether `decide()` can
    /// return `S2` for an iOS call — see below.
    ///
    /// `decide()` itself stays a total, platform-agnostic pure function — `S2` was
    /// always fully implemented and reachable given the right synthetic inputs (see
    /// `AssuranceStatePolicyTests.testS2ReachableGivenSyntheticInputsPureFunctionOnly`).
    /// **As of W-NFCBADGE (2026-07-23) that reachability is real, not just synthetic:**
    /// `AppState.emitKeyConfirmationTelemetry` (via `resolveNfcMixInputs` below) wires
    /// a genuine NFC-tap-derived PSK's selection into `decide()`'s `mixRoles`/
    /// `nfcBound`/`witnessOk` for a live call, so `S2` fires for real once a user has
    /// paired via `NfcExchangeView` and then calls that peer. That does not contradict
    /// this constant: iOS reaches `S2` as the READER consuming a witness event an
    /// Android HCE card originated — it still never originates that witness itself
    /// (the asymmetry this constant documents), which is why the constant's value
    /// stays `false` even though the call-site wiring it used to say "does not exist
    /// yet" now does.
    public static let iosOriginatesS2Witness = false

    /// TOTAL decision function — first match wins, exactly the order documented on
    /// each case above (`S0, S1, S2, S3, S4, S5, S6, S7, S8, S9, S10`). Every possible
    /// input combination reaches a `return` (see `AssuranceStatePolicyTests`'s
    /// exhaustiveness test) — there is no "no match" case.
    ///
    /// - Parameters:
    ///   - peerSupportsMix: the peer advertised `pskMixV1` in its handshake capabilities.
    ///   - n: number of secrets actually mixed into `K_mix` this call (`0`, `1`, or,
    ///     from step 7 on, up to `4`).
    ///   - mixRoles: which secret kinds `n` is made of (empty when `n==0`).
    ///   - peerAdvertisedRoles: the peer's advertised per-fingerprint PSK roles for
    ///     fingerprints THIS side also holds (caller pre-filters to mutually-held
    ///     fingerprints before calling `decide` — this function does no fp-matching
    ///     itself). NOT consulted by `decide()` as of W-NFCCOMMON (kept for cross-
    ///     platform signature parity) — `1` denotes an NFC-tier fingerprint in the
    ///     peer's advert, and the caller uses `peerAdvertisedRoles.contains(1)` as its
    ///     OWN independent "NFC in comune" UI signal instead, rendered alongside
    ///     whatever this function returns.
    ///   - expectedNfc: this contact previously reached `S2` (the persisted
    ///     `presenceFloor`), so an NFC secret is expected on every subsequent call.
    ///   - kcStatus: this call's key-confirmation outcome (`KeyConfirmation.Status`).
    ///   - sigOk: the OFFER/ACCEPT Ed25519 transcript signature verified.
    ///   - nfcBound: the mixed NFC secret is bound to THIS peer's identity key (not a
    ///     different one it was originally established with).
    ///   - witnessOk: the NFC secret's provenance is attestable on this device (not
    ///     merely restored from an un-attestable backup).
    ///   - floorRecorded: this contact has a persisted `presenceFloor` (previously
    ///     reached `S2`). Accepted for cross-platform signature parity with
    ///     Android/Desktop and forward-compatibility with step 8's floor-persistence
    ///     wiring; NOT consulted by any branch below this step (see note on `S7`) —
    ///     the live-vs-history separation documented on the type keeps a floor-based
    ///     escalation a composition OUTSIDE `decide()`, not a branch inside it.
    ///   - mediaDwellMs: milliseconds of connected media on this call so far. Same
    ///     parity/forward-compat note as `floorRecorded` — the ≥10s persistence-write
    ///     gate lives in the (not-yet-built) persistence layer, not in this function.
    public static func decide(
        peerSupportsMix: Bool,
        n: Int,
        mixRoles: [MixSecretRole],
        peerAdvertisedRoles: [Int],
        expectedNfc: Bool,
        kcStatus: KeyConfirmation.Status,
        sigOk: Bool,
        nfcBound: Bool,
        witnessOk: Bool,
        floorRecorded: Bool,
        mediaDwellMs: Int
    ) -> AssuranceState {
        // S0 — legacy peer. Evaluated first, before everything else (including S7):
        // never accuse a peer of stripping a capability it never had.
        guard peerSupportsMix else { return .peerLegacy }

        // S1 — kc_mac verification failed. Dominates every NFC-specific state below:
        // an active-attack signature always outranks a partial-good-signal reading.
        guard kcStatus != .wrong else { return .kcFailed }

        let nfcMixed = mixRoles.contains(.nfc)

        if nfcMixed && kcStatus == .verified {
            if sigOk && nfcBound && witnessOk {
                return .nfcAuthenticated // S2 — unreachable this step (N<=1 everywhere)
            }
            if !nfcBound {
                return .nfcIdentityMismatch // S3
            }
            if !witnessOk {
                return .nfcUnattestable // S4 (nfcBound is true here, else S3 above fired)
            }
            // sigOk must be false to reach here (S2's guard already excluded the
            // all-true case, and nfcBound/witnessOk are both true).
            return .identityUnverified // S5
        }

        if nfcMixed && kcStatus == .absent {
            return .nfcPresentUnconfirmed // S6
        }

        // W-NFCCOMMON: deliberately `expectedNfc` alone now — see `.expectedNfcStripped`'s
        // doc for why a mere mutual-advert-without-floor must not hijack this branch.
        if expectedNfc && !nfcMixed {
            return .expectedNfcStripped // S7
        }

        if n >= 1 {
            return kcStatus == .verified ? .pskConfirmed : .pskUnconfirmed // S8 / S9
        }

        return .pqcOnly // S10 — final catch-all, keeps decide() total for any n < 1
    }
    // W-PSKBLIND (2026-07-25) removed `mutualPeerAdvertisedRoles`. It intersected a
    // peer's advertised (fingerprint, role) pairs with the fingerprints this side
    // holds — correct only while the wire carries static fingerprints. Under the
    // §3.3.1 blinded advertisement those values are per-call HMAC tags, so the
    // intersection is empty and the answer is silently wrong rather than absent.
    //
    // `PskAdvertResolver.resolve` is the replacement and is strictly more capable: it
    // recognises BOTH dialects, and under v3 it recovers the peer's role from which
    // preimage reproduced the tag instead of reading a wire array that no longer
    // exists. Its `mutualPeerRoles` is this function's return value.

    // MARK: - W-NFCBADGE — wiring helper for `decide()`'s NFC-specific inputs
    // (mechanism/keychain access lives at the call site, AppState.swift's
    // `emitKeyConfirmationTelemetry`; this stays a pure function so it is
    // unit-testable without a Keychain).

    /// Design pivot (2026-07-23, Pavel): the earlier N>=2 PSK-mixing plan
    /// (`canonicalOrder`, `K_mix` aggregation) was rejected. Session-key
    /// derivation stays exactly as it is today — always exactly ONE selected
    /// PSK. The only new idea this function wires: if THAT one selected key
    /// was created via an NFC tap, treat it as `AssuranceState.decide()`'s
    /// `.nfc` mix role instead of the generic `.psk` one, so S2-S7's
    /// NFC-specific branches can finally discriminate for real (previously
    /// every call site hardcoded `mixRoles: [.psk]` / `nfcBound: false` /
    /// `witnessOk: false`, which is why the doc on `decide()` used to say S2
    /// was unreachable "this step").
    ///
    /// - Parameters:
    ///   - n: same `n` `decide()` takes — `0` or `1` today (unchanged cap).
    ///   - selectedIsNfcOrigin: whether the vault entry backing the selected
    ///     PSK has `PskOrigin.nfc` (i.e. `SovereignKeyVault.origin(name:)`,
    ///     surfaced to the app layer via `AppState.resolvePskDisplayMeta`'s
    ///     `method == "NFC"` — reused, not re-derived).
    ///   - selectedFingerprintHex: `KcMacReadyEvent.selectedFp` — for an
    ///     `nfc-` vault entry this hex string IS the peer's raw 32-byte
    ///     Ed25519 identity pubkey captured at the tap itself
    ///     (`NfcApduExchange`'s `peerIdentityPub`, persisted verbatim as the
    ///     Keychain label by `NfcExchangeView.persistPsk`) — see that type's
    ///     doc. `nil`/malformed ⇒ cannot establish binding, same as no NFC.
    ///   - verifiedPeerIdentityKey: this call's own verified peer identity
    ///     key — the SAME value `sigOk`'s own verdict is anchored to
    ///     elsewhere in `QAudionCallIntegration`, surfaced via
    ///     `PeerIdentityPinStore.pinnedKey(contactId:)`. Reused, never
    ///     re-derived, so there is exactly one notion of "the verified peer
    ///     identity for this call".
    ///   - priorPresenceAuth: this contact's persisted
    ///     `ContactsStore.PresenceAuth` (`peerIdentityKey`/`witnessTier`
    ///     only), when one exists for the SAME identity key as
    ///     `verifiedPeerIdentityKey`. `nil` on the very first confirming call
    ///     for a fresh tap (nothing persisted yet) or when an existing record
    ///     belongs to a DIFFERENT (stale/rotated) identity — never read a
    ///     record that doesn't pertain to THIS identity.
    /// - Returns: `mixRoles`/`nfcBound`/`witnessOk` ready to feed `decide()`
    ///   verbatim.
    ///
    /// `nfcBound` logic: bound iff the identity captured at tap time equals
    /// this call's verified identity. `witnessOk` logic: when bound, honor a
    /// PRIOR persisted downgrade (`witnessTier == "backup_restore"`) if one
    /// exists for this same identity so a recorded downgrade sticks across
    /// calls; otherwise default to attestable — an `nfc`-origin vault entry
    /// cannot exist on this device except via a live tap on THIS device
    /// (`PskOrigin.nfc.isExportable == false`, no import surface — see that
    /// enum's doc), so "restored from an un-attestable backup" is not a
    /// reachable case for a first-time confirmation.
    public static func resolveNfcMixInputs(
        n: Int,
        selectedIsNfcOrigin: Bool,
        selectedFingerprintHex: String?,
        verifiedPeerIdentityKey: Data?,
        priorPresenceAuth: (peerIdentityKey: Data, witnessTier: String)?
    ) -> (mixRoles: [MixSecretRole], nfcBound: Bool, witnessOk: Bool) {
        guard selectedIsNfcOrigin else {
            return (n >= 1 ? [.psk] : [], false, false)
        }
        guard let fpHex = selectedFingerprintHex,
              let capturedIdentity = DeviceRenewBlob.hexDecode(fpHex),
              capturedIdentity.count == 32
        else {
            // The vault entry's OWN recorded identity is missing or
            // malformed — this can never be trusted as an NFC-authenticated
            // secret at all, so degrade fully to plain PSK rather than
            // claim NFC with an unbound/unverifiable identity.
            return (n >= 1 ? [.psk] : [], false, false)
        }
        guard let verified = verifiedPeerIdentityKey else {
            // Well-formed NFC-origin key, but nothing to verify its binding
            // against yet (e.g. no verified peer identity on this call) —
            // still an NFC secret, just not (yet) provably bound.
            return ([.nfc], false, false)
        }

        let nfcBound = (capturedIdentity == verified)
        var witnessOk = false
        if nfcBound {
            if let prior = priorPresenceAuth, prior.peerIdentityKey == verified {
                witnessOk = prior.witnessTier != "backup_restore"
            } else {
                witnessOk = true
            }
        }
        return ([.nfc], nfcBound, witnessOk)
    }

    // MARK: - W-ASSURANCE/W-FLOOR (ship steps 6/8) — persistence-write POLICY
    // (mechanism lives in ContactsStore.applyAssuranceOutcome)

    /// The `>=10s of connected media` dwell floor `decide()`'s own doc says
    /// deliberately does NOT live inside `decide()` — this is that promised
    /// separate, independently-testable function. Kept here (not in
    /// `ContactsStore`) so the POLICY question ("does this call's verdict
    /// qualify to write `contact.presenceAuth`") stays a pure function next
    /// to the `AssuranceState` it reads, separate from the Codable
    /// persistence MECHANISM.
    public static let presenceAuthDwellFloorMs = 10_000

    /// `true` only for `S2` (`.nfcAuthenticated`) with at least
    /// `presenceAuthDwellFloorMs` of connected media. `S2` is unreachable
    /// from any real call until ship step 7 (N stays <=1 everywhere today),
    /// so this only ever returns `true` under the synthetic inputs
    /// `AssuranceStatePolicyTests`/`ContactsStoreTests` feed it — exactly the
    /// "write it correctly, exercised only by synthetic S2 inputs" contract
    /// the ship-step-6/8 task describes.
    public static func qualifiesForPresenceAuthWrite(state: AssuranceState, mediaDwellMs: Int) -> Bool {
        state == .nfcAuthenticated && mediaDwellMs >= presenceAuthDwellFloorMs
    }
}
