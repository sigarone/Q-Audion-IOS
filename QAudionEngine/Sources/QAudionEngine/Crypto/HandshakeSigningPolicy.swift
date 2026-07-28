import Foundation

/// Phase-10b handshake-signing — the §4 negotiation / fail-closed decision layer
/// that sits between the byte-exact transcript (`HandshakeTranscript`, §3) and the
/// call orchestration (`QAudionCallIntegration`).
///
/// Pure value logic, no engine types in its signatures (CLAUDE.md §16) — it takes
/// `Data` / `Bool` / `String` and the already-built transcript, and returns a
/// verdict the orchestration acts on. This keeps the security-critical decision
/// in one small, directly-testable place instead of buried in the 1000-line
/// integration file (CLAUDE.md §14, type-checker budget).
///
/// Spec: `docs/phase18/HANDSHAKE-SIGNING-SPEC.md` §4 / §5c.
public enum HandshakeSigningPolicy {

    /// The 16-byte per-direction `epochId` the transcript binds. The OFFER/ACCEPT
    /// wire bundle does NOT carry an epoch_id and the iOS call handshake has no
    /// per-direction epoch concept yet (the audio session is keyed directly by
    /// the 32-byte session key). For this FIRST wiring both signer and verifier
    /// feed an all-zero 16-byte epoch — deterministic, reproducible on every
    /// platform, and (with the flag default-OFF) it changes no security property
    /// because everything else (pubkeys, caps, ratchetV, suiteId, offer_binding)
    /// is already bound. When the SPQR session-epoch lands on the wire this
    /// constant is replaced by the real per-direction epoch on both sides.
    /// Confirmed least-bad by the cross-platform review 2026-06-14.
    public static let placeholderEpochId = Data(count: 16)

    /// Phase-18 GO-LIVE 2026-06-21 (Pavel sign-off): advertised v4 in the SIGNED
    /// transcript, bumped 0x03→0x04 in lockstep with Android + Desktop. A SIGNED v4
    /// bundle trips `v4_capable_pinned` and makes stripping the capability bit
    /// detectable. MUST stay identical on all 3 platforms (verifier rebuilds the
    /// transcript with its own constant → mismatch = fatal sig failure).
    public static let ratchetV: UInt8 = 0x04
    /// suite_id 0x01 = the Phase-18 suite.
    public static let suiteId: UInt8 = 0x01

    /// `require_signed(peer)` (§4): a missing signature is fatal only when one of
    /// these holds. A present-but-invalid signature is ALWAYS fatal regardless.
    ///
    /// - `v4CapablePinned`: a SIGNED v4 bundle was ever verified for this peer.
    /// - `flagForcesSigned`: the `require_signed_handshake` global flag is ON.
    /// - `peerVerifiedChannel`: trust ≥ VERIFIED_CHANNEL for this peer.
    public static func requireSigned(
        v4CapablePinned: Bool,
        flagForcesSigned: Bool,
        peerVerifiedChannel: Bool
    ) -> Bool {
        return v4CapablePinned || flagForcesSigned || peerVerifiedChannel
    }

    /// The verdict the orchestration acts on after evaluating a received bundle.
    public enum Verdict: Equatable {
        /// Signature present, valid, and identity matches the pin (or first-seen
        /// TOFU candidate). `tofuPinKey` is set when this verification should
        /// also first-seen-pin the key (caller pins AFTER this success).
        /// `v4Capable` true when the verified bundle advertised v4+suite-1.
        /// `srtpDirKeyV1Capable` true when the verified bundle advertised the
        /// directional-SRTP-key capability (TURN_SPOOF/SRTP downgrade fix —
        /// TOFU-pin so a later unauthenticated bundle can't silently strip it).
        case authenticated(tofuPinKey: Data?, v4Capable: Bool, srtpDirKeyV1Capable: Bool)
        /// D11 trust-on-publish: the bundle key DIFFERS from the per-(peer,device)
        /// pin (or there is no pin yet for this device) but IS a member of the
        /// server-published per-device set, and its OWN signature verified under
        /// it. An AUTHENTICATED new device / rotation — the actuator silently
        /// re-pins `deviceKey` per-(peer,deviceId); NO banner. This is the iOS
        /// mirror of Desktop `new_device_pin`. NEVER blind-pins an observed key:
        /// `deviceKey` was proven ∈ the published set BEFORE this is returned.
        case authenticatedRepinFromPublished(deviceKey: Data, v4Capable: Bool, srtpDirKeyV1Capable: Bool)
        /// No signature, and policy does NOT require one — proceed but WARN
        /// (legacy peer migration path, §4). `reason` is the user-facing hint.
        case proceedUnsignedWarn(reason: String)
        /// Fatal-shaped verdict: `code` is one of the §4 codes (`sig_invalid`,
        /// `identity_key_mismatch`, `sig_required_missing`, `sig_malformed`).
        ///
        /// W-NOBRICK (user directive): the call ACTUATOR
        /// (`QAudionCallIntegration`) NEVER hard-drops media on this verdict — an
        /// `identity_key_mismatch` (key ∉ published set) is surfaced as a
        /// NON-BLOCKING in-call alert and the observed key is NOT pinned; SAS is
        /// the terminal out-of-band gate. The word "abort" is historical
        /// producer-language only.
        case abort(code: String)
    }

    /// Constant-time-ish membership test of a 32-byte Ed25519 pubkey in the
    /// server-published per-device set (`GET …/identity-key?all=1`). The keys are
    /// PUBLIC identity keys (not secret), so `Data ==` (a length-checked memcmp)
    /// is acceptable; we iterate the whole set so timing does not leak which
    /// element matched. Empty / nil set ⇒ never a member (degrade to legacy
    /// pin-only TOFU; D11 graceful fallback, never a fatal mismatch).
    static func isMember(_ key: Data, of set: Set<Data>?) -> Bool {
        guard let set = set, !set.isEmpty, key.count == 32 else { return false }
        return set.contains(key)
    }

    /// Evaluate a received bundle's signing material against the §4 / §5c rules.
    ///
    /// - `signerIdentityKeyB64` / `signatureB64`: the bundle's two optional
    ///   fields (nil when the peer is legacy/unsigned).
    /// - `transcript`: the §3 transcript recomputed from the RECEIVED bundle.
    /// - `pinnedKey`: the TOFU-pinned key for THIS call's peer, if any.
    /// - `serverFetchedKey`: the server/QR-fetched identity for this peer, if any
    ///   (used as the trust source on first contact when no pin exists yet).
    /// - `requireSigned`: result of `requireSigned(...)` for this peer.
    /// - `advertisedV4`: bundle advertised `ratchet_v>=4 && suite_id==0x01`.
    /// - `publishedKeySet`: D11 trust-on-publish floor — the server's published
    ///   per-device set of Ed25519 identity keys (`GET …/identity-key?all=1`). A
    ///   bundle key that differs from the pin but is a MEMBER of this set is an
    ///   AUTHENTICATED new device / rotation, not a mismatch alarm. nil/empty ⇒
    ///   no floor (degrade to legacy pin-only TOFU; never a fatal mismatch).
    ///
    /// Trust source (§5c): verification ALWAYS uses the pinned/server-fetched key
    /// when one exists; the bundle-carried key is accepted only if it equals that
    /// trusted key OR it is proven ∈ the published set (D11). On genuine first
    /// contact (neither pin nor server key nor set membership) the bundle key is
    /// the TOFU candidate and is returned in `tofuPinKey` so the caller pins it
    /// ONLY after this returns `.authenticated`.
    ///
    /// CALLER CONTRACT (D11): when the bundle key differs from the pin but is ∈
    /// the published set, the signature is verified UNDER THE BUNDLE KEY (its own
    /// authenticated rotation key), so the caller MUST have built `transcript`
    /// with `signerIdentityKey = bundleKey` for that case (the integration
    /// resolves the transcript signer key the same way — see `verifyKeyHint`).
    public static func evaluate(
        signerIdentityKeyB64: String?,
        signatureB64: String?,
        transcript: Data,
        pinnedKey: Data?,
        serverFetchedKey: Data?,
        requireSigned: Bool,
        advertisedV4: Bool,
        publishedKeySet: Set<Data>? = nil,
        advertisedSrtpDirKeyV1: Bool = false,
        sigV2B64: String? = nil,
        transcriptV2: Data? = nil
    ) -> Verdict {

        // W-TRANSCRIPTV2 dual-signature verify-both/prefer-v2 (multi-PSK-mixing
        // SYNTHESIS.md ship step 4): when the peer's envelope carries a non-empty
        // `sigV2B64`, verification uses ONLY the v2 pair (`sigV2B64`/`transcriptV2`) for
        // the WHOLE signature-validity decision below — the v1 fields
        // (`signatureB64`/`transcript`) are never consulted once v2 is in play, and a
        // present-but-WRONG sigV2 is fatal on its own (the normal "signature invalid" path
        // below), never a silent fall-back to the lenient v1-only check. If `sigV2B64` is
        // absent, behaviour is EXACTLY the v1 path as it existed before this step — an old,
        // v1-only peer is verified exactly as before and never rejected (this is what makes
        // the rollout staggerable by days rather than a flag day). If `sigV2B64` is present
        // but `transcriptV2` could not be rebuilt (`nil` — see
        // `HandshakeTranscript.advEnc`'s doc for when that happens), that is ALSO fatal
        // (`sig_invalid`) rather than a fall-back — mirrors the Android/Desktop reference
        // exactly: a present `sigV2` with an unbuildable transcript is never treated as
        // "sigV2 absent".
        let sigV2Present = !(sigV2B64 ?? "").isEmpty
        if sigV2Present && transcriptV2 == nil {
            return .abort(code: "sig_invalid")
        }
        let effectiveSignatureB64 = sigV2Present ? sigV2B64 : signatureB64
        let effectiveTranscript = sigV2Present ? transcriptV2! : transcript

        // --- Signature ABSENT -------------------------------------------------
        guard let sigB64 = effectiveSignatureB64, !sigB64.isEmpty,
              let sikB64 = signerIdentityKeyB64, !sikB64.isEmpty else {
            if requireSigned {
                return .abort(code: "sig_required_missing")
            }
            return .proceedUnsignedWarn(
                reason: "legacy peer sent an unsigned handshake; verify SAS"
            )
        }

        // --- Signature PRESENT: malformed inputs are fatal --------------------
        guard let bundleKey = Data(base64Encoded: sikB64), bundleKey.count == 32,
              let signature = Data(base64Encoded: sigB64), signature.count == 64 else {
            return .abort(code: "sig_malformed")
        }

        // --- Resolve the TRUSTED key (§5c) ------------------------------------
        // Prefer the pin, then the server/QR key. The bundle key is trusted only
        // on genuine first contact (no pin, no server key) — and even then it is
        // pinned only AFTER the signature verifies under it.
        let trustedKey: Data
        let isTofuFirstContact: Bool
        if let pin = pinnedKey {
            trustedKey = pin
            isTofuFirstContact = false
        } else if let server = serverFetchedKey {
            trustedKey = server
            isTofuFirstContact = false
        } else {
            trustedKey = bundleKey
            isTofuFirstContact = true
        }

        let bundleInSet = isMember(bundleKey, of: publishedKeySet)
        let matchesTrusted = (bundleKey == trustedKey)

        // --- Identity resolution / mismatch (D11 set-membership-aware) --------
        // A bundle key that disagrees with the trusted (pinned/server) key is a
        // key change. TRUST-ON-PUBLISH FLOOR: if the new key is ∈ the published
        // set it is an AUTHENTICATED rotation (handled on the verify path below
        // as `.authenticatedRepinFromPublished`); otherwise it is an
        // UNAUTHENTICATED change → `identity_key_mismatch`. The ACTUATOR surfaces
        // that as a non-blocking in-call alert and does NOT pin the observed key
        // (W-NOBRICK — never a hard media block; SAS is terminal).
        if !matchesTrusted && !bundleInSet {
            return .abort(code: "identity_key_mismatch")
        }

        // --- Verify the detached Ed25519 signature over the recomputed §3
        //     transcript. AUTHORITATIVE key choice (D11):
        //   • bundle key == trusted key → verify under the trusted key (pin /
        //     server), the established identity (legacy path).
        //   • bundle key ∈ published set (new device / authenticated rotation) →
        //     the bundle key itself is authoritative (its OWN signature proves
        //     possession AND set membership proves server-publication) — verify
        //     under the bundle key. NEVER blind-trust the bundle key on a bare
        //     mismatch: we only get here when bundleInSet is true.
        let verifyKey = matchesTrusted ? trustedKey : bundleKey
        let ok = HandshakeTranscript.verify(
            transcript: effectiveTranscript,
            signature: signature,
            signerIdentityKey: verifyKey
        )
        guard ok else {
            // Present-but-invalid signature is ALWAYS fatal, regardless of policy.
            return .abort(code: "sig_invalid")
        }

        if matchesTrusted {
            return .authenticated(
                tofuPinKey: isTofuFirstContact ? trustedKey : nil,
                v4Capable: advertisedV4,
                srtpDirKeyV1Capable: advertisedSrtpDirKeyV1
            )
        }
        // Not matching the trusted key but ∈ published set and self-signature
        // valid → authenticated new device / rotation. Silent additive re-pin.
        return .authenticatedRepinFromPublished(
            deviceKey: bundleKey,
            v4Capable: advertisedV4,
            srtpDirKeyV1Capable: advertisedSrtpDirKeyV1
        )
    }

    /// D11 helper for the call integration: given the resolved trust facts, which
    /// key will `evaluate` verify the signature UNDER — so the caller can build
    /// the §3 transcript with `signerIdentityKey` set to that exact key. Mirrors
    /// the authoritative-key choice in `evaluate`:
    ///   • a present bundle key that differs from the pinned/server key but is ∈
    ///     the published set → the BUNDLE key (set-proven rotation).
    ///   • otherwise → the pinned key, else the server key, else the bundle key
    ///     (genuine first-contact TOFU candidate).
    /// Returns nil only when there is no parseable bundle key at all (the policy
    /// will then hit the ABSENT / malformed branch where the transcript bytes are
    /// irrelevant).
    ///
    /// CORRECTNESS (must hold): in every case where `evaluate` actually REACHES
    /// signature verification (i.e. `matchesTrusted || bundleInSet`), this hint
    /// equals `evaluate`'s `verifyKey`:
    ///   • matchesTrusted → both = trustedKey.
    ///   • !matchesTrusted && bundleInSet → both = bundleKey.
    /// The remaining case (`!matchesTrusted && !bundleInSet`) is the
    /// UNAUTHENTICATED change: `evaluate` returns `.abort(identity_key_mismatch)`
    /// BEFORE verifying, so the transcript this hint built (= trustedKey) is never
    /// consumed. Do NOT "simplify" this to always return bundleKey on a mismatch
    /// — that would build the transcript under an UNTRUSTED key for the
    /// abort-before-verify case (semantically wrong; the key is never set-proven).
    public static func verifyKeyHint(
        bundleKey: Data?,
        pinnedKey: Data?,
        serverFetchedKey: Data?,
        publishedKeySet: Set<Data>?
    ) -> Data? {
        let trustedKey: Data?
        if let pin = pinnedKey { trustedKey = pin } else if let server = serverFetchedKey { trustedKey = server } else { trustedKey = bundleKey }
        if let bk = bundleKey, bk != trustedKey, isMember(bk, of: publishedKeySet) {
            return bk
        }
        return trustedKey
    }
}
