import Foundation
import CryptoKit
import Security
#if canImport(CoreNFC) && os(iOS)
import CoreNFC
#endif

/// iOS-initiator side of the Android Phase 14c NFC identity-bound key exchange.
///
/// ## Protocol overview
///
/// Android acts as an HCE (Host Card Emulation) card with AID `F0 BC F1 07 3A 51 00`.
/// iOS acts as the NFC reader (initiator) using `NFCTagReaderSession` with `.iso7816`.
///
/// The exchange sequence is:
/// ```
/// iOS (reader)                          Android (HCE card)
///   ─── SELECT AID ────────────────────>
///   <── 9000 ────────────────────────────
///   ─── GET_IDENTITY_KEY (0xC4) ────────>
///   <── [32B Ed25519 pub] 9000 ──────────
///   ─── PUSH_PEER_IDENTITY (0xC5) ──────>  ← iOS sends its Ed25519 identity pub
///   <── 9000 ────────────────────────────
///   ─── KEY_EXCHANGE (0x01) ────────────>  ← [32B X25519_eph_pub | 32B entropy]
///   <── [32B X25519_eph_pub] 9000 ───────  ← Android's ephemeral X25519 pub
/// ```
///
/// Both sides then independently derive the PSK via (see
/// ``deriveCollaborativePsk(myEphPriv:peerEphPub:entropyA:entropyB:)`` for the
/// exact, current construction — this summary intentionally does not repeat
/// its full derivation, which salts over the two EPHEMERAL pubkeys plus both
/// sides' entropy, not the long-term identity keys):
/// ```
/// shared = X25519(my_eph_priv, peer_eph_pub)
/// PSK    = HKDF-SHA256(ikm=shared‖entropy_a‖entropy_b,
///                       salt=SHA256(sort(my_eph_pub, peer_eph_pub)),
///                       info="Q-Audion NFC Collaborative PSK v1")
/// ```
/// The two IDENTITY keys exchanged in steps 2/3 above (`GET_IDENTITY_KEY`/
/// `PUSH_PEER_IDENTITY`) are NOT mixed into this KDF — they exist so `S2`
/// (`AssuranceState.nfcAuthenticated`) can later prove which peer the tapped
/// PSK is bound to (see `AssuranceState.resolveNfcMixInputs`), and so
/// `NfcSasConfirmGate`'s SAS step (below) has a real per-call proximity
/// ceremony independent of the KDF's own inputs.
///
/// **W-NFCSAS:** after the PSK is derived, a 6-digit SAS
/// (``NfcSasComputation``, over the two Ed25519 identity keys — byte-exact
/// with Android's `nfc/SasComputation.kt`) is shown and the user must
/// confirm it matches the other device
/// (``State/sasConfirm(sas:peerDeviceName:)``) before anything is
/// persisted — see ``confirmSas()``/``rejectSas()``.
///
/// **Superseded fallback (removed):** an anonymous, non-identity-bound
/// single-round X25519 exchange used to exist as a fallback for this class
/// (`NfcCollaborativeExchange`) — deleted (confirmed dead: zero production
/// call sites once this identity-required path replaced it; the only peer
/// that exists, Android's HCE service, never spoke that exchange's protocol
/// either). `NfcApduExchange` is the ONLY NFC pairing path on iOS today.
///
/// **Platform note:** `NFCTagReaderSession` is iOS-only; this class is a no-op
/// on macOS. The ``State`` type and ``start()``/``cancel()`` entry points are
/// always available so the caller needn't `#if os(iOS)` everywhere.
public final class NfcApduExchange: NSObject {

    // MARK: - Public types

    public enum State: Equatable {
        case idle
        case waiting
        case exchanging
        /// W-NFCSAS — the raw PSK is derived and the ephemeral keys/entropy
        /// exchanged, but nothing is persisted yet. `sas` is the 6-digit
        /// Short-Authentication-String (`NfcSasComputation`, a byte-exact
        /// port of Android's `nfc/SasComputation.kt`) derived from the two
        /// peers' Ed25519 IDENTITY keys — NOT `ComputeSasUseCase` (that one
        /// is for the in-call ceremony, derived from the session key into 6
        /// PGP words; a different construction entirely). The user must
        /// read this code against the other device before the ceremony can
        /// proceed — both platforms now derive the identical 6 digits for
        /// the same tap.
        case sasConfirm(sas: String, peerDeviceName: String)
        case success(peerDeviceName: String)
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.waiting, .waiting), (.exchanging, .exchanging):
                return true
            case (.sasConfirm(let sasA, let peerA), .sasConfirm(let sasB, let peerB)):
                return sasA == sasB && peerA == peerB
            case (.success(let a), .success(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    // MARK: - Public interface

    public internal(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    /// Called whenever ``state`` changes.
    public var onStateChanged: ((State) -> Void)?

    /// Called when the PSK exchange completes successfully — i.e. AFTER the
    /// user has confirmed the SAS (`.sasConfirm` state, see `confirmSas()`).
    /// Parameters: `(psk: 32B, peerIdentityPub: 32B Ed25519)`.
    public var onPskDerived: ((Data, Data) async throws -> Void)?

    /// W-NFCSAS — the post-derivation confirm gate. `nil` whenever no
    /// ceremony is currently paused at `.sasConfirm` (before the first tap,
    /// after a completed/failed/cancelled one).
    private var sasGate: NfcSasConfirmGate?

    /// User confirmed the SAS words match what the other device shows.
    /// No-op if not currently at `.sasConfirm` (nothing to confirm).
    public func confirmSas() {
        sasGate?.confirm()
        sasGate = nil
    }

    /// User rejected the SAS (words did not match, or they backed out).
    /// The ceremony throws before `onPskDerived` is ever called — no
    /// key material is persisted for a rejected tap. No-op if not
    /// currently at `.sasConfirm`.
    public func rejectSas() {
        sasGate?.reject()
        sasGate = nil
    }

    /// Local Ed25519 identity public key (32 bytes). Must be set before ``start()``.
    /// Typically sourced from ``SovereignIdentityManager``.
    public var localIdentityPublicKey: Data?

    /// SECURITY M-6 — optional pinned peer identity for re-pairing.
    ///
    /// On the FIRST pairing this is nil (TOFU). The integration layer
    /// SHOULD persist the peer's Ed25519 identity pub into
    /// SovereignKeyVault keyed by the peer, and on any SUBSEQUENT
    /// pairing with the same peer set this property to the stored
    /// value. When set, `runPhase14cExchange` rejects the exchange
    /// (constant-time compare) if the tag presents a DIFFERENT
    /// identity key — defending against a key-substitution / MITM
    /// swap on re-pair. When nil, behaviour is unchanged (TOFU).
    ///
    /// TODO (SECURITY M-6, integration layer): wire this from the
    /// caller — look up `SovereignKeyVault.identityKey(forPeer:)`,
    /// pass it here before `start()`, and on mismatch surface a
    /// prominent "this device's key changed — possible attack" alert
    /// instead of silently re-trusting.
    public var expectedPeerIdentityPub: Data?

    // MARK: - Init

    public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Begin the NFC reader session. On macOS (no CoreNFC) transitions immediately to `.error`.
    public func start() {
        guard let idPub = localIdentityPublicKey, idPub.count == 32 else {
            state = .error("Local identity public key not set or invalid (must be 32B Ed25519)")
            return
        }
        #if canImport(CoreNFC) && os(iOS)
        guard NFCTagReaderSession.readingAvailable else {
            state = .error("NFC reading is not available on this device")
            return
        }
        endSessionIfActive()
        let d = TagDelegate()
        d.owner = self
        tagDelegate = d
        guard let session = NFCTagReaderSession(
            pollingOption: [.iso14443],
            delegate: d,
            queue: nil
        ) else {
            state = .error("Failed to create NFC reader session")
            return
        }
        session.alertMessage = "Hold your iPhone near the Android device running Q-Audion."
        nfcSession = session
        session.begin()
        state = .waiting
        #else
        state = .error("NFC is not available on this platform")
        #endif
    }

    /// Cancel any running session — including one paused at `.sasConfirm`
    /// awaiting the user's decision (rejects it, same as `rejectSas()`, so
    /// the suspended `runPhase14cExchange` Task unwinds instead of leaking).
    public func cancel() {
        #if canImport(CoreNFC) && os(iOS)
        endSessionIfActive()
        #endif
        sasGate?.reject()
        sasGate = nil
        if case .waiting = state { state = .idle }
        if case .exchanging = state { state = .idle }
        if case .sasConfirm = state { state = .idle }
    }

    // MARK: - CoreNFC internals (iOS-only)

    #if canImport(CoreNFC) && os(iOS)
    private var nfcSession: NFCTagReaderSession?
    private var tagDelegate: TagDelegate?

    private func endSessionIfActive() {
        nfcSession?.invalidate()
        nfcSession = nil
        tagDelegate = nil
    }

    /// Drive the APDU sequence over an ISO-7816 tag (the Android HCE card).
    /// Returns the peer device name string (from select response or placeholder).
    fileprivate func runPhase14cExchange(
        over iso: NFCISO7816Tag,
        session: NFCTagReaderSession
    ) async throws -> String {
        state = .exchanging

        guard let myIdPub = localIdentityPublicKey, myIdPub.count == 32 else {
            throw ExchangeError.identityKeyMissing
        }

        // Step 1: SELECT AID F0BCF1073A5100
        let aid = Data([0xF0, 0xBC, 0xF1, 0x07, 0x3A, 0x51, 0x00])
        let selectApdu = NFCISO7816APDU(
            instructionClass: 0x00, instructionCode: 0xA4,
            p1Parameter: 0x04, p2Parameter: 0x00,
            data: aid, expectedResponseLength: -1
        )
        let (_, sw1s, sw2s) = try await iso.sendCommand(apdu: selectApdu)
        guard sw1s == 0x90, sw2s == 0x00 else {
            throw ExchangeError.apduFailed("SELECT", sw1s, sw2s)
        }

        // Step 2: GET_IDENTITY_KEY (0xC4) — receive peer's Ed25519 identity pub
        //
        // W-NFCIOS — CLA is 0x80, the proprietary class. Android checks it on
        // every one of the three commands (NfcApduService.kt:399,411,423 against
        // NfcConstants.CLA_PROPRIETARY) and answers SW_INS_NOT_SUPPORTED (0x6D00)
        // to anything else, so the 0x00 we sent before died here — the very first
        // command after SELECT. Only SELECT itself is class 0x00, because that is
        // the ISO-standard header Android matches byte-for-byte
        // (NfcConstants.SELECT_AID_HEADER = 00 A4 04 00).
        let getIdApdu = NFCISO7816APDU(
            instructionClass: 0x80, instructionCode: 0xC4,
            p1Parameter: 0x00, p2Parameter: 0x00,
            data: Data(), expectedResponseLength: 32
        )
        let (idKeyResp, sw1g, sw2g) = try await iso.sendCommand(apdu: getIdApdu)
        guard sw1g == 0x90, sw2g == 0x00, idKeyResp.count == 32 else {
            throw ExchangeError.apduFailed("GET_IDENTITY_KEY", sw1g, sw2g)
        }
        let peerIdentityPub = idKeyResp

        // SECURITY M-6 — pinned-key check on re-pairing. If the
        // caller supplied a previously-stored identity for this peer
        // and the tag now presents a different one, abort: this is a
        // key-substitution attempt or a genuine key rotation the
        // user must explicitly re-confirm out of band.
        if let pinned = expectedPeerIdentityPub {
            let match = NfcApduExchange.constantTimeEquals(pinned, peerIdentityPub)
            guard match else {
                throw ExchangeError.peerIdentityMismatch
            }
        }

        // Step 3: PUSH_PEER_IDENTITY (0xC5) — send our Ed25519 identity pub
        let pushIdApdu = NFCISO7816APDU(
            instructionClass: 0x80, instructionCode: 0xC5,
            p1Parameter: 0x00, p2Parameter: 0x00,
            data: Data(myIdPub), expectedResponseLength: -1
        )
        let (_, sw1p, sw2p) = try await iso.sendCommand(apdu: pushIdApdu)
        guard sw1p == 0x90, sw2p == 0x00 else {
            throw ExchangeError.apduFailed("PUSH_PEER_IDENTITY", sw1p, sw2p)
        }

        // Step 4: KEY_EXCHANGE (0x01) — send [ephemeral X25519 pub | 32B entropy],
        //         receive the peer's [ephemeral X25519 pub | 32B entropy].
        //
        // W-NFCIOS — the response is 64 bytes, not 32. Android answers with the
        // same payload shape it received (NfcApduService.kt:369 returns
        // `ourPayload`, built by NfcProtocol.prepareCollaborativeExchange() =
        // pubkey(32) ‖ entropy(32), NfcConstants.PAYLOAD_SIZE = 64). Guarding on
        // 32 threw on a perfectly good reply.
        let myEphPriv = Curve25519.KeyAgreement.PrivateKey()
        let myEphPub = myEphPriv.publicKey.rawRepresentation
        // SECURITY H-8 is closed by this change: the entropy each side
        // contributes is now folded into the KDF instead of being transmitted
        // and ignored. Both halves matter — a peer that could bias only its own
        // ephemeral key still cannot steer the result while the other side's
        // 32 fresh CSPRNG bytes are in the IKM.
        let entropy = NfcApduExchange.secureRandomBytes(32)
        let kePayload = myEphPub + entropy   // 64 bytes
        let keyExchangeApdu = NFCISO7816APDU(
            instructionClass: 0x80, instructionCode: 0x01,
            p1Parameter: 0x00, p2Parameter: 0x00,
            data: kePayload, expectedResponseLength: 64
        )
        let (peerPayload, sw1k, sw2k) = try await iso.sendCommand(apdu: keyExchangeApdu)
        guard sw1k == 0x90, sw2k == 0x00, peerPayload.count == 64 else {
            throw ExchangeError.apduFailed("KEY_EXCHANGE", sw1k, sw2k)
        }
        let peerEphPubBytes = peerPayload.prefix(32)
        let peerEntropy = peerPayload.suffix(32)

        let peerEphPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(peerEphPubBytes))
        // This device is the APDU initiator (iOS can only ever be the reader),
        // so our entropy is `entropy_a` and the card's is `entropy_b`.
        let psk = try NfcApduExchange.deriveCollaborativePsk(
            myEphPriv: myEphPriv,
            peerEphPub: peerEphPub,
            entropyA: entropy,
            entropyB: Data(peerEntropy)
        )

        // W-NFCSAS — pause here and make the user compare/confirm BEFORE the
        // key is ever handed to the integration layer. `onPskDerived` (the
        // ONLY call in this type that persists anything — `NfcExchangeView
        // .persistPsk` writes to `SovereignKeyVault` from inside it) is
        // reached ONLY on the `true` branch below; a reject (or a cancel())
        // throws first, so nothing is ever written for a rejected tap.
        //
        // Uses `NfcSasComputation` — a byte-exact port of Android's
        // `nfc/SasComputation.kt` — over the two Ed25519 IDENTITY keys
        // (`myIdPub`/`peerIdentityPub`, already exchanged above), NOT
        // `ComputeSasUseCase` (that one derives from the session/call key
        // into 6 PGP words, for the in-call ceremony — a different
        // construction). Both platforms now derive the identical 6-digit
        // code for the same tap (pinned by the shared KAT vectors:
        // all-zero vs all-0xFF -> "759936"; 0..31 vs 32..63 -> "360896").
        let sas = try NfcSasComputation.computeSas(
            selfIkEdPub: Data(myIdPub),
            peerIkEdPub: Data(peerIdentityPub)
        )
        let gate = NfcSasConfirmGate()
        sasGate = gate
        state = .sasConfirm(sas: sas, peerDeviceName: "Android peer")
        let confirmed = await gate.awaitConfirmation()
        sasGate = nil
        guard confirmed else {
            throw ExchangeError.sasRejected
        }

        // Notify the integration layer.
        try await onPskDerived?(psk, peerIdentityPub)

        return "Android peer"
    }

    fileprivate func handleSessionError(_ error: Error) {
        let nfcError = error as? NFCReaderError
        if nfcError?.code == .readerSessionInvalidationErrorUserCanceled {
            if case .waiting = state { state = .idle }
            if case .exchanging = state { state = .idle }
            return
        }
        state = .error(error.localizedDescription)
        endSessionIfActive()
    }
    #endif

    // MARK: - PSK derivation (platform-independent)

    /// W-NFCIOS — the collaborative PSK, byte-identical to the Android HCE peer.
    ///
    /// ```
    /// ikm  = ecdh(32) ‖ entropy_a(32) ‖ entropy_b(32)            [96]
    /// salt = SHA-256(sorted(myEphPub, peerEphPub))               [32]
    /// info = "Q-Audion NFC Collaborative PSK v1"
    /// psk  = HKDF-SHA256(ikm, salt, info, 32)
    /// ```
    /// `entropy_a` is the APDU initiator's, `entropy_b` the responder's. iOS can
    /// only be the reader, so the caller always passes its own as `entropyA`.
    /// Mirrors `NfcProtocol.deriveCollaborativePsk` (NfcProtocol.kt:291-321),
    /// with no ML-KEM leg because the Android HCE service never runs one: its
    /// APDU dispatch handles SELECT / 0xC4 / 0xC5 / 0x01 and nothing else
    /// (NfcApduService.kt:141-153), so `pqcActive` is false on that side and the
    /// info label stays `HKDF_INFO_COLLAB`.
    ///
    /// This REPLACES the previous identity-bound derivation, which salted over
    /// the two long-term identity keys and dropped both entropies. That shape
    /// could never agree with the only peer that exists, so nothing is being
    /// migrated — there are no working iOS-derived NFC keys in the field to
    /// invalidate. The identity binding it was reaching for is still worth
    /// having, but it belongs in the stored metadata rather than in the KDF,
    /// where changing it would mean moving both platforms in lockstep. Today the
    /// peer's Ed25519 key is fetched over 0xC4 and survives only as the first 16
    /// hex characters of the vault account name (`NfcExchangeView.persistPsk`);
    /// recording it in full, so a call can prove it is talking to the peer that
    /// was tapped, is a follow-up and is NOT done here.
    ///
    /// Note for whoever re-pins the cross-platform vector: `nfc_psk_v1` in
    /// Tests/Resources/cross_platform_vectors.json still describes the old
    /// ecdh-only shape and says "Android must confirm byte-identical output".
    /// Android never did — there is no NFC KAT in that repo at all. Aligning iOS
    /// to Android rather than the reverse is deliberate: real NFC keys exist on
    /// Android phones today and none exist here.
    public static func deriveCollaborativePsk(
        myEphPriv: Curve25519.KeyAgreement.PrivateKey,
        peerEphPub: Curve25519.KeyAgreement.PublicKey,
        entropyA: Data,
        entropyB: Data
    ) throws -> Data {
        let shared = try myEphPriv.sharedSecretFromKeyAgreement(with: peerEphPub)
        let salt = sortedConcatSHA256(myEphPriv.publicKey.rawRepresentation,
                                      peerEphPub.rawRepresentation)
        // CryptoKit's SharedSecret.hkdfDerivedSymmetricKey can only use the raw
        // ECDH output as IKM, and Android concatenates the two entropies onto
        // it, so the extract step is done explicitly here.
        var ikm = Data()
        shared.withUnsafeBytes { ikm.append(contentsOf: $0) }
        ikm.append(entropyA)
        ikm.append(entropyB)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm),
                                       salt: salt)
        let key = HKDF<SHA256>.expand(pseudoRandomKey: prk,
                                      info: HkdfLabels.nfcCollaborativePsk,
                                      outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func sortedConcatSHA256(_ a: Data, _ b: Data) -> Data {
        let pair = a.lexicographicallyPrecedes(b) ? a + b : b + a
        return Data(SHA256.hash(data: pair))
    }

    /// SECURITY H-8 — CSPRNG-backed random bytes. Uses
    /// `SecRandomCopyBytes`; falls back to CryptoKit's `SymmetricKey`
    /// generator (also CSPRNG) only if the Security call fails, so
    /// the result is never the non-crypto `UInt8.random` path.
    static func secureRandomBytes(_ count: Int) -> Data {
        var buf = Data(count: count)
        let status: Int32 = buf.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        if status == errSecSuccess { return buf }
        let k = SymmetricKey(size: SymmetricKeySize(bitCount: count * 8))
        return k.withUnsafeBytes { Data($0) }
    }

    // MARK: - Errors

    public enum ExchangeError: Error, LocalizedError {
        case identityKeyMissing
        case apduFailed(String, UInt8, UInt8)
        case invalidResponse(String)
        /// SECURITY M-6 — re-pair presented a different peer identity
        /// key than the pinned one.
        case peerIdentityMismatch
        /// W-NFCSAS — the user rejected the SAS confirm step (or cancelled
        /// while it was showing). Thrown BEFORE `onPskDerived` is ever
        /// called, so no key material is persisted.
        case sasRejected

        public var errorDescription: String? {
            switch self {
            case .identityKeyMissing:
                return "Local identity key not configured"
            case .apduFailed(let cmd, let sw1, let sw2):
                return "\(cmd) failed: SW=\(String(format: "%02X%02X", sw1, sw2))"
            case .invalidResponse(let msg):
                return "Invalid APDU response: \(msg)"
            case .peerIdentityMismatch:
                return "Peer identity key changed since last pairing — aborting (possible attack)"
            case .sasRejected:
                return "SAS non confermato — scambio annullato"
            }
        }
    }

    /// W-NFCSAS — the post-derivation confirm gate `runPhase14cExchange`
    /// awaits, extracted as a plain, CoreNFC-free async barrier so it is
    /// unit-testable without real NFC hardware (CoreNFC tag sessions cannot
    /// run in CI/simulator — see `NfcCollaborativePskKatTests`'s own note on
    /// this same constraint). `awaitConfirmation()` suspends until EITHER
    /// `confirm()` (resumes `true`) or `reject()` (resumes `false`) is
    /// called — there is no third path and no timeout, matching every other
    /// NFC state transition in this file (user-driven, not time-boxed).
    final class NfcSasConfirmGate {
        private var continuation: CheckedContinuation<Bool, Never>?

        func awaitConfirmation() async -> Bool {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                self.continuation = cont
            }
        }

        func confirm() {
            continuation?.resume(returning: true)
            continuation = nil
        }

        func reject() {
            continuation?.resume(returning: false)
            continuation = nil
        }
    }

    /// SECURITY M-6 — length-checked constant-time byte compare so
    /// the pin check does not leak via timing.
    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        let av = Array(a)
        let bv = Array(b)
        var diff: UInt8 = 0
        var i: Int = 0
        while i < av.count {
            diff |= av[i] ^ bv[i]
            i += 1
        }
        return diff == 0
    }
}

private extension Data {
    func lexicographicallyPrecedes(_ other: Data) -> Bool {
        for (l, r) in zip(self, other) {
            if l < r { return true }
            if l > r { return false }
        }
        return count < other.count
    }
}

// MARK: - NFCTagReaderSessionDelegate (iOS-only)

#if canImport(CoreNFC) && os(iOS)
private final class TagDelegate: NSObject, NFCTagReaderSessionDelegate {

    weak var owner: NfcApduExchange?

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        owner?.handleSessionError(error)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first, case .iso7816(let iso) = tag else {
            session.invalidate(errorMessage: "Incompatible tag — Q-Audion requires ISO-7816 (Android HCE)")
            return
        }
        Task { [weak owner] in
            let ownerRef = owner
            do {
                try await session.connect(to: tag)
                let peerName = try await ownerRef?.runPhase14cExchange(
                    over: iso, session: session) ?? "(unknown)"
                await MainActor.run { [ownerRef] in
                    ownerRef?.state = .success(peerDeviceName: peerName)
                }
                session.alertMessage = "Paired with \(peerName)"
                session.invalidate()
            } catch {
                let errMsg = error.localizedDescription
                session.invalidate(errorMessage: errMsg)
                await MainActor.run { [ownerRef] in
                    ownerRef?.state = .error(errMsg)
                }
            }
        }
    }
}
#endif
