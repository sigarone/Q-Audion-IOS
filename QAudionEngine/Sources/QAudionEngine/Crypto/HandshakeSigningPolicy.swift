import Foundation

/// Handshake-signing decision layer (transcript v6) — sits between the byte-exact transcript
/// (`HandshakeTranscript`, WIRE_SPEC §3.7) and the call orchestration (`QAudionCallIntegration`).
///
/// Pure value logic, no engine types in its signatures (CLAUDE.md §16) — it takes `Data` / `Bool`
/// / `String` and the already-built transcript, and returns a verdict the orchestration acts on.
///
/// **Policy (WIRE_SPEC §3.8, F8).**
/// - A bundle without `sigV6`, without `signerIdentityKey` or without `dtlsFingerprint` — or with
///   any of them malformed — is MALFORMED: every client emits all three, so the call ENDS
///   (`.malformed`). There is no unsigned/legacy peer any more.
/// - An INVALID signature or an unknown identity key keeps the W-NOBRICK policy: the verdict is
///   `.abort`, the call is not dropped, and media is held pending an in-call SAS comparison. The
///   SAS now also covers both DTLS fingerprints (the session key is bound to the v6 ACCEPT
///   transcript), so stripping a signature and then confirming the SAS no longer helps an attacker.
/// - The SAS commitment rules (`sasCommitMalformedCode`, `firstRoundMalformedCode`) are malformed codes too:
///   a round-1 OFFER without a valid commitment, a rekey OFFER or an ACCEPT that carries one, or a first
///   OFFER of a call whose round is not 1 ends the call (`handshake_malformed`).
public enum HandshakeSigningPolicy {

    /// The 16-byte per-direction `epochId` the transcript binds. The OFFER/ACCEPT wire bundle does
    /// NOT carry an epoch id; both signer and verifier feed an all-zero 16-byte epoch —
    /// deterministic and reproducible on every platform (everything else is already bound).
    public static let placeholderEpochId = Data(count: 16)

    /// Advertised ratchet version in the SIGNED transcript. MUST stay identical on all platforms
    /// (the verifier rebuilds the transcript with its own constant).
    public static let ratchetV: UInt8 = 0x04
    /// suite_id 0x01 = the Phase-18 suite.
    public static let suiteId: UInt8 = 0x01

    /// The verdict the orchestration acts on after evaluating a received bundle.
    public enum Verdict: Equatable {
        /// Signature present, valid, and identity matches the pin (or the server-fetched key, or
        /// a server-published key). `tofuPinKey` is set whenever the peer had NO pin yet (the key was
        /// then authenticated by the server, never taken from the bundle alone).
        case authenticated(tofuPinKey: Data?, v4Capable: Bool, srtpDirKeyV1Capable: Bool, ratchetV5Capable: Bool)
        /// D11 trust-on-publish: the bundle key DIFFERS from the per-(peer,device) pin (or there is
        /// no pin yet) but IS a member of the server-published per-device set, and its OWN
        /// signature verified under it. Silent additive re-pin; NEVER blind-pins an observed key.
        case authenticatedRepinFromPublished(deviceKey: Data, v4Capable: Bool, srtpDirKeyV1Capable: Bool, ratchetV5Capable: Bool)
        /// F8: a required field is missing or malformed. The call ENDS. `code` is one of
        /// `sig_missing`, `sig_malformed`, `dtlsfp_missing`, `dtlsfp_malformed`,
        /// `transcript_unbuildable`, `commit_missing`, `commit_malformed`, `commit_unexpected`,
        /// `first_round_not_1`.
        case malformed(code: String)
        /// Invalid signature / unknown identity (`sig_invalid`, `identity_key_mismatch`,
        /// `identity_unresolved` = no pin and no server key to verify against,
        /// `ratchet_v5_downgrade`): W-NOBRICK — the call is NOT dropped, media is held pending the
        /// SAS, the observed key is NOT pinned.
        case abort(code: String)
    }

    /// Constant-time-ish membership test of a 32-byte Ed25519 pubkey in the server-published
    /// per-device set. The keys are PUBLIC identity keys, so `Data ==` is acceptable; empty/nil
    /// set => never a member (no floor; never a fatal mismatch).
    static func isMember(_ key: Data, of set: Set<Data>?) -> Bool {
        guard let set = set, !set.isEmpty, key.count == 32 else { return false }
        return set.contains(key)
    }

    /// R-COMMIT-FIELD: the malformed code of a bundle's `sasCommit` field, `nil` when it is valid.
    ///
    /// - A round-1 OFFER carries exactly 32 bytes of canonical base64: absent is `commit_missing`, a
    ///   present value that is not canonical base64 of 32 bytes is `commit_malformed`.
    /// - A rekey OFFER (round >= 2) and every ACCEPT carry NONE: any value, even an empty or null one
    ///   (the parser maps a JSON null to the empty string), is `commit_unexpected`.
    /// - A missing or out-of-range round is left to the transcript builder (`transcript_unbuildable`).
    public static func sasCommitMalformedCode(isOffer: Bool, round: Int?, sasCommitB64: String?) -> String? {
        if isOffer {
            guard let round = round, round >= 1 else { return nil }
            if round == 1 {
                guard let text = sasCommitB64 else { return "commit_missing" }
                return SasCommit.decodeCanonicalBase64(text, expectedLength: SasCommit.commitLength) == nil
                    ? "commit_malformed" : nil
            }
            return sasCommitB64 == nil ? nil : "commit_unexpected"
        }
        return sasCommitB64 == nil ? nil : "commit_unexpected"
    }

    /// R-COMMIT-FIRST-ROUND: the first OFFER a callee accepts for a callId must be round 1. `nil` when
    /// valid, `first_round_not_1` otherwise.
    public static func firstRoundMalformedCode(isFirstOfferOfCall: Bool, round: Int?) -> String? {
        guard isFirstOfferOfCall else { return nil }
        return round == 1 ? nil : "first_round_not_1"
    }

    /// WIRE_SPEC §3.7.4 pending OFFER: an OFFER that overtook the `call_incoming` (no call context yet) is
    /// checked as a FIRST OFFER when it arrives: round 1 and a valid `sasCommit`. `nil` when it may be held,
    /// a code when it must be dropped (no state, no hangup: there is no call to end yet).
    public static func pendingOfferMalformedCode(round: Int?, sasCommitB64: String?) -> String? {
        if let code = firstRoundMalformedCode(isFirstOfferOfCall: true, round: round) { return code }
        return sasCommitMalformedCode(isOffer: true, round: round, sasCommitB64: sasCommitB64)
    }

    /// Evaluate a received bundle's signing material.
    ///
    /// - `signerIdentityKeyB64` / `sigV6B64` / `dtlsFingerprintText`: the bundle's three fields
    ///   (nil when absent).
    /// - `transcript`: the v6 transcript recomputed from the RECEIVED bundle, built with the
    ///   bundle's own `signerIdentityKey` (the signer signed its OWN key; every path that reaches
    ///   signature verification has bundle key == trusted key or a set-proven bundle key);
    ///   `nil` when it could not be built (the peer-supplied inputs have the wrong shape) — which
    ///   is a malformed bundle.
    /// - `pinnedKey` / `serverFetchedKey` / `publishedKeySet`: trust sources (§5c, D11).
    /// - `advertisedV4` / `advertisedSrtpDirKeyV1` / `advertisedRatchetV5`: capability bits the
    ///   verified bundle advertised (only meaningful once the signature verifies).
    /// - `ratchetV5CapablePinned`: the sticky per-peer pin (anti-downgrade).
    public static func evaluate(
        signerIdentityKeyB64: String?,
        sigV6B64: String?,
        dtlsFingerprintText: String?,
        transcript: Data?,
        pinnedKey: Data?,
        serverFetchedKey: Data?,
        publishedKeySet: Set<Data>? = nil,
        advertisedV4: Bool,
        advertisedSrtpDirKeyV1: Bool = false,
        advertisedRatchetV5: Bool = false,
        ratchetV5CapablePinned: Bool = false
    ) -> Verdict {

        // --- F8: every field present and well-formed, else the call ends ------------------
        guard let sigB64 = sigV6B64, !sigB64.isEmpty else { return .malformed(code: "sig_missing") }
        guard let sikB64 = signerIdentityKeyB64, !sikB64.isEmpty else { return .malformed(code: "sig_missing") }
        guard let fpText = dtlsFingerprintText, !fpText.isEmpty else { return .malformed(code: "dtlsfp_missing") }
        guard DtlsFingerprint.parseCanonical(fpText) != nil else { return .malformed(code: "dtlsfp_malformed") }
        guard let bundleKey = Data(base64Encoded: sikB64), bundleKey.count == 32,
              let signature = Data(base64Encoded: sigB64), signature.count == 64 else {
            return .malformed(code: "sig_malformed")
        }
        guard let transcript = transcript else { return .malformed(code: "transcript_unbuildable") }

        // --- Resolve the TRUSTED key (§5c) ------------------------------------------------
        // Prefer the pin, then the server/QR key, then the server-published per-device set. With NONE
        // of the three (no pin, and the server identity fetch failed or has not landed) there is no
        // authoritative identity to verify against: the bundle key is NEVER trusted blindly and
        // never pinned. Like Android, the verdict is `.abort("identity_unresolved")` — the call is
        // not dropped (W-NOBRICK), media is held pending the in-call SAS, which the session key
        // (bound to the v6 transcript, hence to the signer key and both DTLS fingerprints) covers.
        let trustedKey: Data
        if let pin = pinnedKey {
            trustedKey = pin
        } else if let server = serverFetchedKey {
            trustedKey = server
        } else if let set = publishedKeySet, !set.isEmpty {
            // The published set is a server source too: a bundle key that is a member of it is
            // server-authenticated; any other key is an unauthenticated change.
            guard isMember(bundleKey, of: set) else { return .abort(code: "identity_key_mismatch") }
            trustedKey = bundleKey
        } else {
            // SAS-PIN: the signature is still checked under the bundle key (proof of possession), so only
            // a round that key really signed is `identity_unresolved`, and a SAS confirmation of the call
            // can only ever pin (or vouch for) a key that signed its rounds. A bundle claiming a key it did
            // not sign with is `sig_invalid`, like on every other path.
            guard HandshakeTranscript.verify(transcript: transcript, signature: signature, signerIdentityKey: bundleKey) else {
                return .abort(code: "sig_invalid")
            }
            return .abort(code: "identity_unresolved")
        }

        let bundleInSet = isMember(bundleKey, of: publishedKeySet)
        let matchesTrusted = (bundleKey == trustedKey)

        // A bundle key that disagrees with the trusted (pinned/server) key is a key change. If the
        // new key is in the published set it is an AUTHENTICATED rotation (handled on the verify
        // path below); otherwise it is an UNAUTHENTICATED change: `identity_key_mismatch`.
        if !matchesTrusted && !bundleInSet {
            return .abort(code: "identity_key_mismatch")
        }

        // Verify the detached Ed25519 signature over the recomputed v6 transcript, under the
        // authoritative key: the trusted key when the bundle key matches it, else the
        // set-proven bundle key.
        let verifyKey = matchesTrusted ? trustedKey : bundleKey
        guard HandshakeTranscript.verify(transcript: transcript, signature: signature, signerIdentityKey: verifyKey) else {
            // Present-but-invalid signature: hold media pending SAS (W-NOBRICK).
            return .abort(code: "sig_invalid")
        }

        // Sticky half of the ratchetV5 anti-downgrade invariant: a peer that has ever proven
        // ratchetV5-capable and now presents a validly-signed bundle honestly claiming
        // `ratchetV5=false` is flagged. Checked BEFORE the success verdicts so it reflects the
        // peer's PRIOR state.
        if !advertisedRatchetV5 && ratchetV5CapablePinned {
            return .abort(code: "ratchet_v5_downgrade")
        }

        if matchesTrusted {
            return .authenticated(
                tofuPinKey: pinnedKey == nil ? trustedKey : nil,
                v4Capable: advertisedV4,
                srtpDirKeyV1Capable: advertisedSrtpDirKeyV1,
                ratchetV5Capable: advertisedRatchetV5
            )
        }
        return .authenticatedRepinFromPublished(
            deviceKey: bundleKey,
            v4Capable: advertisedV4,
            srtpDirKeyV1Capable: advertisedSrtpDirKeyV1,
            ratchetV5Capable: advertisedRatchetV5
        )
    }
}
