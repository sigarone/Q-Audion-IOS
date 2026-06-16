import Foundation

/// KMS-rotation-v2 Phase-1 — the local handshake policy that ties D1 (key_class),
/// D2 (additive negotiation), D3 (require_signed grace) and D4 (require-hw-only
/// abort) together into a single fail-closed verdict.
///
/// This is PURE decision logic over already-resolved inputs (the verify result,
/// the negotiated fp, the local contact's key_class). It performs no crypto and
/// no I/O, so it is fully host-runnable under `swift test` (unlike the Keychain /
/// CryptoKit-bound pieces). The call layer feeds it the facts and acts on the
/// verdict: `.abort` ⇒ tear the call down BEFORE any session-key derivation.
public enum KmsHandshakePolicyV1 {

    // MARK: - D2 additive negotiation

    /// D2 — order a set of locally-eligible PSK fingerprints for ADVERTISEMENT,
    /// hw_only FIRST. The frozen "additive = single negotiated salt" semantics
    /// rely on hw_only keys sitting at TOP priority so, when both legs hold one,
    /// the caller-priority intersection picks it (it becomes the HKDF salt). The
    /// returned order is what the OFFER's `pskFingerprints[]` advertises.
    ///
    /// Within a class the input order is preserved (stable) so callers keep any
    /// secondary priority they already imposed.
    ///
    /// - Parameter eligible: (fingerprint, key_class) pairs the device holds for
    ///   this contact / its catalogue.
    public static func advertiseOrder(
        eligible: [(fingerprint: String, keyClass: SovereignKeyVault.KeyClass)]
    ) -> [String] {
        let rank: (SovereignKeyVault.KeyClass) -> Int = { kc in
            switch kc {
            case .hwOnly: return 0   // top priority
            case .shared: return 1
            case .swOnly: return 2
            }
        }
        return eligible
            .enumerated()
            .sorted { a, b in
                let ra = rank(a.element.keyClass), rb = rank(b.element.keyClass)
                if ra != rb { return ra < rb }
                return a.offset < b.offset            // stable within a class
            }
            .map { $0.element.fingerprint }
    }

    /// D2 — RESPONDER selection: pick the first ADVERTISED fingerprint (caller's
    /// priority order) that this device also holds. Mirrors the existing
    /// `onAndroidBundleReceived` selection (`firstOrNull{ it holds }`) and is
    /// what the ACCEPT echoes back as `selectedPskFingerprint`. Returns nil when
    /// the intersection is empty (legitimate SW-only fallback ⇒ null salt).
    public static func selectFingerprint(
        advertised: [String],
        locallyHeld: Set<String>
    ) -> String? {
        return advertised.first(where: { locallyHeld.contains($0) })
    }

    // MARK: - Verdict

    public enum Verdict: Equatable {
        /// Proceed and derive the session key, mixing `selectedFingerprint`
        /// (nil ⇒ no PSK / null salt = legitimate SW-only fallback).
        case proceed(selectedFingerprint: String?)
        /// A signed bundle was present but verification failed → drop the call
        /// before any key derivation.
        case abortVerifyFailed
        /// This contact holds a hw_only key but the negotiation produced no
        /// hw_only fingerprint (stripped / downgraded) → drop the call (D4).
        case abortHwOnlyRequired
        /// Legacy unsigned peer accepted under the grace window (D3 WarnLegacy).
        /// Carries the same selected fingerprint as `.proceed` would.
        case proceedWarnLegacy(selectedFingerprint: String?)
    }

    /// The single fail-closed handshake verdict.
    ///
    /// Inputs (all already resolved by the call layer):
    /// - `signaturePresent`: did the inbound bundle carry a signature?
    /// - `signatureVerified`: when present, did `KmsHsBundleV1.verify` pass?
    ///   (ignored when `signaturePresent == false`).
    /// - `requireSigned`: the global `require_signed` enforcement flag. When ON,
    ///   the grace window is closed and unsigned legacy peers are NOT accepted
    ///   (still subject to the hw_only carve-out below, which is stricter).
    /// - `contactHasHwOnlyKey`: does THIS device hold a hw_only key for this peer
    ///   (D1 key_class == hw_only)? Resolved via `SovereignKeyVault.getKeyClass`.
    /// - `negotiatedFingerprint`: the selected fp (D2), or nil.
    /// - `expectedHwOnlyFingerprint`: the fp of the hw_only key this device holds
    ///   for the peer (the fp the negotiation MUST land on for a hw_only contact).
    ///   nil when `contactHasHwOnlyKey == false`.
    ///
    /// Order of checks (each strictly fail-closed):
    ///   1. signed-but-bad      → abortVerifyFailed
    ///   2. hw_only carve-out   → if the contact has a hw_only key, the
    ///      negotiation MUST yield exactly that hw_only fp (regardless of grace /
    ///      require_signed); else abortHwOnlyRequired. (D4 + the D3 "hw_only
    ///      contacts require the mix regardless of grace" rule.)
    ///   3. unsigned + require   → unsigned legacy peer with require_signed ON and
    ///      NOT a hw_only contact ⇒ abortVerifyFailed (grace closed).
    ///   4. unsigned + grace     → proceedWarnLegacy
    ///   5. signed + verified    → proceed
    public static func evaluate(
        signaturePresent: Bool,
        signatureVerified: Bool,
        requireSigned: Bool,
        contactHasHwOnlyKey: Bool,
        negotiatedFingerprint: String?,
        expectedHwOnlyFingerprint: String?
    ) -> Verdict {
        // 1. A present signature that does not verify is fatal, always.
        if signaturePresent && !signatureVerified {
            return .abortVerifyFailed
        }

        // 2. hw_only carve-out — strictest, evaluated BEFORE the grace path so a
        //    hw_only contact can never fall through to WarnLegacy. The mix is
        //    required regardless of signature/grace: if the negotiation did not
        //    land on this contact's hw_only fp (stripped, downgraded to null, or
        //    swapped to a different key), abort (D4).
        if contactHasHwOnlyKey {
            guard let expected = expectedHwOnlyFingerprint,
                  let got = negotiatedFingerprint,
                  got == expected else {
                return .abortHwOnlyRequired
            }
            // hw_only mix confirmed. If the bundle was also signed+verified, this
            // is the strongest path; if unsigned, we STILL proceed (the mix is
            // the protection here) — but never WarnLegacy-silent: the call layer
            // logs it. Either way: proceed with the hw_only fp.
            return .proceed(selectedFingerprint: got)
        }

        // 3. Unsigned legacy peer with enforcement ON (and not a hw_only contact)
        //    ⇒ grace closed ⇒ abort.
        if !signaturePresent && requireSigned {
            return .abortVerifyFailed
        }

        // 4. Unsigned legacy peer during the grace window ⇒ accept with a warning.
        if !signaturePresent {
            return .proceedWarnLegacy(selectedFingerprint: negotiatedFingerprint)
        }

        // 5. Signed and verified ⇒ proceed.
        return .proceed(selectedFingerprint: negotiatedFingerprint)
    }
}
