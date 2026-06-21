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
        case authenticated(tofuPinKey: Data?, v4Capable: Bool)
        /// No signature, and policy does NOT require one — proceed but WARN
        /// (legacy peer migration path, §4). `reason` is the user-facing hint.
        case proceedUnsignedWarn(reason: String)
        /// Fatal: abort the handshake. `code` is one of the §4 abort codes
        /// (`sig_invalid`, `identity_key_mismatch`, `sig_required_missing`,
        /// `sig_malformed`).
        case abort(code: String)
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
    ///
    /// Trust source (§5c): verification ALWAYS uses the pinned/server-fetched key
    /// when one exists; the bundle-carried key is accepted only if it equals that
    /// trusted key. On genuine first contact (neither pin nor server key) the
    /// bundle key is the TOFU candidate and is returned in `tofuPinKey` so the
    /// caller pins it ONLY after this returns `.authenticated`.
    public static func evaluate(
        signerIdentityKeyB64: String?,
        signatureB64: String?,
        transcript: Data,
        pinnedKey: Data?,
        serverFetchedKey: Data?,
        requireSigned: Bool,
        advertisedV4: Bool
    ) -> Verdict {

        // --- Signature ABSENT -------------------------------------------------
        guard let sigB64 = signatureB64, !sigB64.isEmpty,
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

        // Identity-mismatch is ALWAYS fatal (§4): a bundle key that disagrees
        // with the trusted key is the MITM/key-swap alarm.
        if bundleKey != trustedKey {
            return .abort(code: "identity_key_mismatch")
        }

        // --- Verify the detached Ed25519 signature over the recomputed §3
        //     transcript, using the TRUSTED key (never blindly the bundle key).
        let ok = HandshakeTranscript.verify(
            transcript: transcript,
            signature: signature,
            signerIdentityKey: trustedKey
        )
        guard ok else {
            // Present-but-invalid signature is ALWAYS fatal, regardless of policy.
            return .abort(code: "sig_invalid")
        }

        return .authenticated(
            tofuPinKey: isTofuFirstContact ? trustedKey : nil,
            v4Capable: advertisedV4
        )
    }
}
