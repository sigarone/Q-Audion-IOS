import Foundation
import QAudionEngine

/// Persistent safety-number evaluation for `ContactDetailScreen` — iOS
/// counterpart to Android `EnsurePeerTrustPinnedUseCase` +
/// `PeerTrustRepository` (core-trust module). Ports the SAME state machine
/// (WIRE_SPEC.md §5.1.2) using pieces that already exist engine-side:
///
///   - `SafetyNumber.compute` — the HKDF+CBOR derivation (this session).
///   - `SovereignIdentityManager` — local Ed25519 identity (`signingPublic`).
///   - `BCryptoKmsClient.fetchUserIdentityKey` — peer's published Ed25519 leg
///     (`GET /api/v1/users/{id}/identity-key`, already used by the
///     handshake-signing verifier).
///   - `PeerIdentityPinStore` — Keychain TOFU pin (already wired to the
///     handshake verifier in `QAudionCallIntegration`).
///   - `ContactsStore.verifiedFingerprintHex` — manual "I compared this
///     out-of-band" self-attest, mirroring Android `PeerTrustEntity`.
///   - `SasVerificationStore` — the REAL in-call anti-replay SAS ceremony
///     (`LiveInCallScreen`). Android's own `PeerTrustRepository.toTrustLevel()`
///     kdoc notes the in-call SAS persists to a SEPARATE table from the
///     identity-pin repository and is not unified into one state — this
///     mirrors that same (shipped, accepted) architecture rather than
///     inventing a cleaner-but-divergent design.
public enum PeerTrustEvaluator {

    public struct Evaluation {
        public let state: TrustSafetyNumberState
        public let safetyNumber: TrustSafetyNumber
        public let verifiedAt: Date?
        public let verificationMethod: TrustVerificationMethod?
        /// The peer's raw Ed25519 identity key resolved for this
        /// evaluation, when the server fetch succeeded. Callers need this
        /// for `acceptNewFingerprint` (re-pin the NEW key) without a
        /// second redundant network fetch.
        public let peerIkEdPub: Data?
    }

    /// Resolve + evaluate trust for `peerUserId`. Never throws: every
    /// failure path (no self identity, peer never published, network
    /// error, bad UUID) degrades to `.unverified` with an empty safety
    /// number, matching Android's graceful-degrade contract.
    @MainActor
    public static func evaluate(peerUserId: String, provider: BCryptoBackendProvider?) async -> Evaluation {
        let unverified = Evaluation(
            state: .unverified,
            safetyNumber: TrustSafetyNumber(groups: [], fingerprintHex: ""),
            verifiedAt: nil,
            verificationMethod: nil,
            peerIkEdPub: nil
        )

        guard let selfUserId = AppState.currentUserIdSnapshot, !selfUserId.isEmpty,
              selfUserId != peerUserId,
              let selfUuidRaw = SafetyNumber.rawUuidBytes(fromUuidString: selfUserId),
              let peerUuidRaw = SafetyNumber.rawUuidBytes(fromUuidString: peerUserId),
              let selfIkEdPub = SovereignIdentityManager().loadIdentity()?.signingPublic
        else {
            return unverified
        }

        guard let provider,
              let peerIkEdPub = await provider.kmsClient.fetchUserIdentityKey(userId: peerUserId),
              peerIkEdPub.count == 32
        else {
            return unverified
        }

        guard let computed = try? SafetyNumber.compute(
            localUuidRaw: selfUuidRaw, localIkEdPub: selfIkEdPub,
            peerUuidRaw: peerUuidRaw, peerIkEdPub: peerIkEdPub
        ) else {
            return unverified
        }

        let safetyNumber = TrustSafetyNumber(groups: computed.groups, fingerprintHex: computed.fingerprintHex)

        let pinResult = PeerIdentityPinStore().pinOrMatch(contactId: peerUserId, ed25519Pub: peerIkEdPub)
        if pinResult == .mismatch {
            return Evaluation(state: .identityChanged, safetyNumber: safetyNumber, verifiedAt: nil, verificationMethod: nil, peerIkEdPub: peerIkEdPub)
        }

        let stored = ContactsStore().load().first(where: { $0.userId == peerUserId })
        if let storedFp = stored?.verifiedFingerprintHex, storedFp == computed.fingerprintHex {
            let method = stored?.verificationMethod.flatMap(TrustVerificationMethod.init(rawValue:))
            let verifiedAt = stored?.verifiedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            return Evaluation(state: .userVerified, safetyNumber: safetyNumber, verifiedAt: verifiedAt, verificationMethod: method, peerIkEdPub: peerIkEdPub)
        }

        // Fall back to the real in-call anti-replay SAS ceremony (LiveInCallScreen).
        // No live session key here (this screen is never shown mid-call), so we
        // can only check "was ANY SAS ever confirmed for this peer" rather than
        // compare against the current call's fingerprint.
        if SasVerificationStore.shared.storedFingerprint(peerUserId: peerUserId) != nil {
            return Evaluation(state: .userVerified, safetyNumber: safetyNumber, verifiedAt: nil, verificationMethod: .antiReplay, peerIkEdPub: peerIkEdPub)
        }

        return Evaluation(state: .identityPinnedTofu, safetyNumber: safetyNumber, verifiedAt: nil, verificationMethod: nil, peerIkEdPub: peerIkEdPub)
    }

    /// Persist a manual "I compared the safety number via `method`"
    /// self-attest (mirrors Android `PeerTrustRepository.markVerified`).
    /// The CALLER must pass the `fingerprintHex` from the Evaluation just
    /// rendered on screen (never a stale one) so a later rotation is
    /// detected correctly on the next `evaluate` call.
    public static func markVerified(peerUserId: String, method: TrustVerificationMethod, fingerprintHex: String) {
        let store = ContactsStore()
        guard let existing = store.load().first(where: { $0.userId == peerUserId }) else { return }
        store.upsert(ContactsStore.StoredContact(
            userId: existing.userId,
            displayName: existing.displayName,
            phoneHash: existing.phoneHash,
            avatarUrl: existing.avatarUrl,
            lastSeen: existing.lastSeen,
            isVerified: true,
            pubkey: existing.pubkey,
            verifiedFingerprintHex: fingerprintHex,
            verifiedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            verificationMethod: method.rawValue,
            // W-ASSURANCE/W-FLOOR — a manual SAS/QR/anti-replay verify is NOT
            // an identity change (the OPPOSITE: it's confirming the SAME
            // identity this call already trusts) and must never wipe a
            // physically-established NFC presence record — that is a
            // SEPARATE, ranked-but-never-merged trust axis (design brief:
            // "two things that must never share a widget"). Unlike
            // `acceptNewFingerprint` below (which deliberately OMITS these two
            // fields so they clear via the same default-nil mechanism the
            // verify-tier fields above already rely on), this call site must
            // explicitly THREAD them through unchanged. See
            // `PeerTrustEvaluatorTests.test_markVerified_preservesPresenceAuthAndFloor`
            // (QAudionAppTests).
            presenceAuth: existing.presenceAuth,
            presenceFloor: existing.presenceFloor
        ))
    }

    /// User explicitly accepted a rotated identity (`.identityChanged` →
    /// re-pin). Wipes the old Keychain pin and re-pins the NEW key so the
    /// next `evaluate` call sees `.match` instead of `.mismatch`. Clears any
    /// prior manual-verify record — the peer must re-verify the new safety
    /// number, mirroring Android `acceptNewFingerprint` resetting
    /// `verifiedAtMs` to null.
    ///
    /// Uses `wipeLegacyOnly` (NOT the full-peer `wipe`): `evaluate()` only
    /// ever checks the legacy bare-contactId account (this screen has no
    /// device-id context), so accepting a rotation here must only reset
    /// THAT account — a full-peer wipe would also silently discard any
    /// real per-device pins established by call-handshake verification
    /// (adversarial-review finding, confirmed).
    ///
    /// W-ASSURANCE/W-FLOOR (design brief: "cleared unconditionally on any
    /// peer identity change... rely on it, don't duplicate the logic"): the
    /// `StoredContact(...)` reconstruction below deliberately does NOT pass
    /// `presenceAuth`/`presenceFloor` — both default to `nil` in
    /// `StoredContact.init`, so they clear as an EMERGENT side effect of this
    /// same identity-rotation reconstruction, exactly like
    /// `verifiedFingerprintHex`/`verifiedAtMs`/`verificationMethod` already do
    /// on the lines below. Do NOT add explicit `presenceAuth: nil` here — the
    /// point of this note is that nothing new needs to change; see
    /// `ContactsStoreTests.test_reconstructingStoredContactWithoutPresenceFields_clearsThemToNil`
    /// (QAudionEngineTests — mechanism pin) and
    /// `PeerTrustEvaluatorTests.test_acceptNewFingerprint_clearsPresenceAuthAndFloor`
    /// (QAudionAppTests — real call-path pin).
    public static func acceptNewFingerprint(peerUserId: String, newPeerIkEdPub: Data) {
        let pinStore = PeerIdentityPinStore()
        pinStore.wipeLegacyOnly(contactId: peerUserId)
        pinStore.pinOrMatch(contactId: peerUserId, ed25519Pub: newPeerIkEdPub)

        let store = ContactsStore()
        guard let existing = store.load().first(where: { $0.userId == peerUserId }) else { return }
        store.upsert(ContactsStore.StoredContact(
            userId: existing.userId,
            displayName: existing.displayName,
            phoneHash: existing.phoneHash,
            avatarUrl: existing.avatarUrl,
            lastSeen: existing.lastSeen,
            isVerified: false,
            pubkey: existing.pubkey,
            verifiedFingerprintHex: nil,
            verifiedAtMs: nil,
            verificationMethod: nil
        ))
    }
}
