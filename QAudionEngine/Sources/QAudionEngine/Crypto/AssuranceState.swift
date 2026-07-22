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
/// **What's reachable THIS step.** `N` stays capped at ≤1 everywhere and no capability
/// flag is flipped (see `KeyConfirmation`'s doc) — `S2` therefore cannot fire from any
/// real call today (`mixRoles` can never contain `.nfc` while `N<=1`). `S0`, `S1`,
/// `S3`–`S10` ARE reachable today and MUST render correctly; `S2` is implemented and
/// exercised by tests as a pure-function branch, not yet reachable in production.
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
    /// S7 — this contact's NFC secret was expected (previously reached this trust
    /// level, or the peer still advertises a matching role-1 fingerprint) but this
    /// call fell back to plain PSK (or no PSK at all) without it.
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
    /// no NFC ceremony on iOS reaches the witness trust level `S2`
    /// (`.nfcAuthenticated`) depends on. Corroborating evidence already in this
    /// codebase: `NfcCollaborativeExchange` is documented as "Drives an **iOS-reader**
    /// NFC collaborative pairing session" — CoreNFC on iOS exposes reader-mode
    /// (`NFCTagReaderSession`) only, with no public host-card-emulation API (unlike
    /// Android's `HostApduService`), so this device can never independently attest
    /// the witness role `S2`'s origination requires.
    ///
    /// `decide()` itself stays a total, platform-agnostic pure function — `S2` is
    /// fully implemented and reachable given the right synthetic inputs (see
    /// `AssuranceStatePolicyTests.testS2ReachableGivenSyntheticInputsPureFunctionOnly`).
    /// This constant documents that iOS's OWN call-handling code is never expected to
    /// construct those inputs from a real ceremony. **Scope note:** the wiring that
    /// would prove this end-to-end (iOS's actual NFC-mix call-integration code, not
    /// yet built — deferred to the phase that wires `AssuranceState` into
    /// `QAudionCallIntegration`/`AppState`) does not exist yet, so this is a pinned
    /// architectural fact carried over from the design brief, corroborated by — but
    /// not independently re-derived from — Apple's CoreNFC capability surface.
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
    ///     itself). `1` denotes an NFC-tier fingerprint in the peer's advert.
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

        if (expectedNfc || peerAdvertisedRoles.contains(1)) && !nfcMixed {
            return .expectedNfcStripped // S7
        }

        if n >= 1 {
            return kcStatus == .verified ? .pskConfirmed : .pskUnconfirmed // S8 / S9
        }

        return .pqcOnly // S10 — final catch-all, keeps decide() total for any n < 1
    }

    /// W-KCMAC (ship step 5) — the fp-matching helper `decide()`'s own doc says
    /// callers must run BEFORE calling in: filters a peer's advertised
    /// `(fingerprint, role)` pairs down to only the fingerprints THIS side also
    /// holds, in the SAME index-paired-with-role convention
    /// `HandshakeTranscript.advEnc`/`AndroidHandshakeBundle.pskRoles` already use
    /// (role absent, or the roles array shorter than the fingerprints array at
    /// that index, ⇒ `0`). Order-preserving over `peerFingerprints`, never
    /// re-sorted. `peerFingerprints == nil` ⇒ `[]`.
    public static func mutualPeerAdvertisedRoles(
        peerFingerprints: [String]?,
        peerRoles: [Int]?,
        localFingerprints: Set<String>
    ) -> [Int] {
        guard let fps = peerFingerprints else { return [] }
        var out: [Int] = []
        out.reserveCapacity(fps.count)
        for (idx, fp) in fps.enumerated() where localFingerprints.contains(fp) {
            let role = (peerRoles != nil && idx < peerRoles!.count) ? peerRoles![idx] : 0
            out.append(role)
        }
        return out
    }
}
