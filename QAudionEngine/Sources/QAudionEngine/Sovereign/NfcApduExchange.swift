import Foundation
import CryptoKit
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
/// Both sides then independently derive the PSK via:
/// ```
/// shared  = X25519(my_eph_priv, peer_eph_pub)
/// id_salt = SHA256(sort(ios_id_pub ∥ android_id_pub))
/// PSK     = HKDF-SHA256(ikm=shared, salt=id_salt, info="Q-Audion NFC Collaborative PSK v1")
/// ```
///
/// This is the identity-bound variant of ``NfcCollaborativeExchange``.
/// ``NfcCollaborativeExchange`` uses a single-round anonymous X25519 exchange
/// (compatible with NDEF tags). This class targets live Android HCE pairing.
///
/// **Compatibility note:** Android Phase 14c introduced this protocol; older
/// Android builds that only write NDEF tags should still be served by
/// ``NfcCollaborativeExchange``. Use this class when tapping two live phones.
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
        case success(peerDeviceName: String)
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.waiting, .waiting), (.exchanging, .exchanging):
                return true
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

    /// Called when the PSK exchange completes successfully.
    /// Parameters: `(psk: 32B, peerIdentityPub: 32B Ed25519)`.
    public var onPskDerived: ((Data, Data) async throws -> Void)?

    /// Local Ed25519 identity public key (32 bytes). Must be set before ``start()``.
    /// Typically sourced from ``SovereignIdentityManager``.
    public var localIdentityPublicKey: Data?

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

    /// Cancel any running session.
    public func cancel() {
        #if canImport(CoreNFC) && os(iOS)
        endSessionIfActive()
        #endif
        if case .waiting = state { state = .idle }
        if case .exchanging = state { state = .idle }
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
        let getIdApdu = NFCISO7816APDU(
            instructionClass: 0x00, instructionCode: 0xC4,
            p1Parameter: 0x00, p2Parameter: 0x00,
            data: Data(), expectedResponseLength: 32
        )
        let (idKeyResp, sw1g, sw2g) = try await iso.sendCommand(apdu: getIdApdu)
        guard sw1g == 0x90, sw2g == 0x00, idKeyResp.count == 32 else {
            throw ExchangeError.apduFailed("GET_IDENTITY_KEY", sw1g, sw2g)
        }
        let peerIdentityPub = idKeyResp

        // Step 3: PUSH_PEER_IDENTITY (0xC5) — send our Ed25519 identity pub
        let pushIdApdu = NFCISO7816APDU(
            instructionClass: 0x00, instructionCode: 0xC5,
            p1Parameter: 0x00, p2Parameter: 0x00,
            data: Data(myIdPub), expectedResponseLength: -1
        )
        let (_, sw1p, sw2p) = try await iso.sendCommand(apdu: pushIdApdu)
        guard sw1p == 0x90, sw2p == 0x00 else {
            throw ExchangeError.apduFailed("PUSH_PEER_IDENTITY", sw1p, sw2p)
        }

        // Step 4: KEY_EXCHANGE (0x01) — send ephemeral X25519 pub + 32B entropy
        //         receive peer's ephemeral X25519 pub (32 bytes)
        let myEphPriv = Curve25519.KeyAgreement.PrivateKey()
        let myEphPub = myEphPriv.publicKey.rawRepresentation
        let entropy = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let kePayload = myEphPub + entropy   // 64 bytes
        let keyExchangeApdu = NFCISO7816APDU(
            instructionClass: 0x00, instructionCode: 0x01,
            p1Parameter: 0x00, p2Parameter: 0x00,
            data: kePayload, expectedResponseLength: 32
        )
        let (peerEphPubBytes, sw1k, sw2k) = try await iso.sendCommand(apdu: keyExchangeApdu)
        guard sw1k == 0x90, sw2k == 0x00, peerEphPubBytes.count == 32 else {
            throw ExchangeError.apduFailed("KEY_EXCHANGE", sw1k, sw2k)
        }

        // Derive identity-bound PSK.
        let peerEphPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphPubBytes)
        let psk = try NfcApduExchange.deriveIdentityBoundPsk(
            myEphPriv: myEphPriv,
            peerEphPub: peerEphPub,
            myIdPub: Data(myIdPub),
            peerIdPub: peerIdentityPub
        )

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

    /// HKDF-SHA256 PSK with identity key binding.
    ///
    /// Identical KDF to ``NfcPskDerivation/derivePsk`` but uses
    /// `SHA256(sort(my_id_pub ∥ peer_id_pub))` as salt instead of the
    /// ephemeral pubkeys alone, so the derived key is bound to both
    /// long-term identities.
    public static func deriveIdentityBoundPsk(
        myEphPriv: Curve25519.KeyAgreement.PrivateKey,
        peerEphPub: Curve25519.KeyAgreement.PublicKey,
        myIdPub: Data,
        peerIdPub: Data
    ) throws -> Data {
        let shared = try myEphPriv.sharedSecretFromKeyAgreement(with: peerEphPub)
        let idSalt = sortedConcatSHA256(myIdPub, peerIdPub)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: idSalt,
            sharedInfo: HkdfLabels.nfcCollaborativePsk,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private static func sortedConcatSHA256(_ a: Data, _ b: Data) -> Data {
        let pair = a.lexicographicallyPrecedes(b) ? a + b : b + a
        return Data(SHA256.hash(data: pair))
    }

    // MARK: - Errors

    public enum ExchangeError: Error, LocalizedError {
        case identityKeyMissing
        case apduFailed(String, UInt8, UInt8)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .identityKeyMissing:
                return "Local identity key not configured"
            case .apduFailed(let cmd, let sw1, let sw2):
                return "\(cmd) failed: SW=\(String(format: "%02X%02X", sw1, sw2))"
            case .invalidResponse(let msg):
                return "Invalid APDU response: \(msg)"
            }
        }
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
