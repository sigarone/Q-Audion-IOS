import Foundation
import CryptoKit
import Security
#if canImport(CoreNFC) && os(iOS)
import CoreNFC
#endif

/// Drives an iOS-reader NFC collaborative pairing session.
///
/// Owns an `NfcExchangeViewModel` and (on iOS) an underlying `NFCTagReaderSession`.
/// When a tag is detected, performs SELECT-AID → 64-byte payload exchange → PSK
/// derivation per spec §5.5, then transitions to `.success` or `.error`.
///
/// On non-iOS builds (e.g. macOS unit tests), the CoreNFC layer is absent
/// and the service exposes `simulate*ForTesting()` methods to drive the
/// state machine deterministically.
public final class NfcCollaborativeExchange {

    public private(set) var viewModel: NfcExchangeViewModel

    /// Caller (e.g. KeyManagementContainer) sets this to persist the PSK +
    /// peer pubkey into SovereignKeyVault. NfcCollaborativeExchange itself
    /// does not own a vault — that's the integration layer's job.
    /// Closure receives `(psk: 32B, peerPubkey: 32B)`.
    public var onPskDerivedDelegate: ((Data, Data) async throws -> Void)?

    /// Called whenever the internal ``viewModel`` state changes.
    /// Fired on whatever thread/Task drives the state machine — callers
    /// must dispatch to main if they need UI updates.
    public var onStateChanged: ((NfcExchangeViewModel.State) -> Void)?

    public init() {
        self.viewModel = .mock  // starts in .idle
    }

    public func start() {
        viewModel.transition(to: .waiting)
        #if canImport(CoreNFC) && os(iOS)
        beginNfcReaderSession()
        #endif
    }

    public func cancel() {
        viewModel.transition(to: .idle)
        #if canImport(CoreNFC) && os(iOS)
        endNfcReaderSessionIfActive()
        #endif
    }

    // MARK: - Test seams (cross-platform)

    public func simulateTagDetectedForTesting() {
        viewModel.transition(to: .exchanging)
    }

    public func simulateExchangeCompletedForTesting(peerDeviceName: String) {
        viewModel.transition(to: .success(peerDeviceName: peerDeviceName))
    }

    public func simulateExchangeFailedForTesting(message: String) {
        viewModel.transition(to: .error(message: message))
    }

    /// Internal seam used by the iOS CoreNFC delegate to drive state from
    /// outside the class (the `private(set)` viewModel can't be mutated by
    /// the inner `TagReaderDelegate` directly).
    internal func transition(to state: NfcExchangeViewModel.State) {
        viewModel.transition(to: state)
        onStateChanged?(viewModel.state)
    }

    /// SECURITY H-8 — CSPRNG-backed random bytes via
    /// `SecRandomCopyBytes`; CryptoKit `SymmetricKey` (also CSPRNG)
    /// only as a fallback. Never the non-crypto `UInt8.random` path.
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

    // MARK: - CoreNFC integration (iOS-only)

    #if canImport(CoreNFC) && os(iOS)
    private var session: NFCTagReaderSession?
    private var delegate: TagReaderDelegate?

    private func beginNfcReaderSession() {
        let d = TagReaderDelegate()
        d.owner = self
        self.delegate = d
        guard let session = NFCTagReaderSession(
            pollingOption: [.iso14443],
            delegate: d,
            queue: nil
        ) else {
            viewModel.transition(to: .error(message: "Unable to create NFC reader session"))
            return
        }
        session.alertMessage = "Hold your iPhone near the Android device running Q-Audion."
        self.session = session
        session.begin()
    }

    private func endNfcReaderSessionIfActive() {
        session?.invalidate()
        session = nil
        delegate = nil
    }

    fileprivate func handleSessionInvalid(error: Error) {
        // User cancelled or hardware error — surface in state machine.
        viewModel.transition(to: .error(message: error.localizedDescription))
        endNfcReaderSessionIfActive()
    }

    fileprivate func runApduExchange(
        over iso: NFCISO7816Tag,
        session: NFCTagReaderSession
    ) async throws -> String {
        viewModel.transition(to: .exchanging)

        // SELECT command → AID F0BCF1073A5100 (§5.5)
        let aid = Data([0xF0, 0xBC, 0xF1, 0x07, 0x3A, 0x51, 0x00])
        let select = NFCISO7816APDU(
            instructionClass: 0x00, instructionCode: 0xA4,
            p1Parameter: 0x04, p2Parameter: 0x00,
            data: aid, expectedResponseLength: -1
        )
        let (selectResp, sw1, sw2) = try await iso.sendCommand(apdu: select)
        guard sw1 == 0x90, sw2 == 0x00 else {
            throw NSError(
                domain: "NfcCollaborativeExchange",
                code: Int(sw1) << 8 | Int(sw2),
                userInfo: [NSLocalizedDescriptionKey: "SELECT failed (SW=\(String(format: "%02X%02X", sw1, sw2)))"]
            )
        }
        _ = selectResp  // metadata, not consumed

        // Generate our 64-byte payload: 32B X25519 ephemeral pubkey + 32B random entropy.
        let myPriv = Curve25519.KeyAgreement.PrivateKey()
        let myPub = myPriv.publicKey.rawRepresentation
        // SECURITY H-8 — this 32B `entropy` is transmitted but is
        // NOT folded into the PSK KDF (`NfcPskDerivation.derivePsk`
        // uses only the X25519 shared secret). It is security
        // theater today. We do NOT alter the transmitted bytes
        // (Android exchanges the same field; changing/removing it is
        // a wire-breaking change needing a coordinated v2). Minimal
        // hardening: source it from the system CSPRNG instead of the
        // non-crypto `UInt8.random`.
        //
        // TODO (SECURITY H-8 v2, coordinated with Android): include
        // both peers' entropy in the HKDF IKM so the field actually
        // strengthens the PSK.
        let entropy = NfcCollaborativeExchange.secureRandomBytes(32)
        let myPayload = myPub + entropy
        precondition(myPayload.count == 64, "Payload must be exactly 64B (32B pubkey + 32B entropy)")

        // GET DATA — send our payload, expect peer's 64-byte payload back.
        let exchange = NFCISO7816APDU(
            instructionClass: 0x00, instructionCode: 0xCA,
            p1Parameter: 0x00, p2Parameter: 0x00,
            data: myPayload, expectedResponseLength: 64
        )
        let (peerPayload, sw1b, sw2b) = try await iso.sendCommand(apdu: exchange)
        guard sw1b == 0x90, sw2b == 0x00, peerPayload.count == 64 else {
            throw NSError(
                domain: "NfcCollaborativeExchange",
                code: Int(sw1b) << 8 | Int(sw2b),
                userInfo: [NSLocalizedDescriptionKey: "Payload exchange failed (SW=\(String(format: "%02X%02X", sw1b, sw2b)), len=\(peerPayload.count))"]
            )
        }

        // First 32B of peer payload is their ephemeral X25519 pubkey.
        let peerPubBytes = peerPayload.prefix(32)
        let peerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPubBytes)

        // Derive PSK using §5.5 spec (HKDF-SHA256 with NFC info string).
        let psk = try NfcPskDerivation.derivePsk(myPriv: myPriv, peerPub: peerPub)

        // Persist via caller-supplied delegate (typically writes to SovereignKeyVault).
        try await onPskDerivedDelegate?(psk, Data(peerPubBytes))

        // Peer device name is not in the wire payload (Android sends it via a
        // separate INS — Track B follow-up). Return placeholder for now.
        return "Android peer"
    }
    #endif
}

// MARK: - Tag reader delegate (iOS-only)

#if canImport(CoreNFC) && os(iOS)
private final class TagReaderDelegate: NSObject, NFCTagReaderSessionDelegate {

    weak var owner: NfcCollaborativeExchange?

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        // No-op — viewModel already in .waiting from start().
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        owner?.handleSessionInvalid(error: error)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first, case .iso7816(let iso) = tag else {
            session.invalidate(errorMessage: "Unsupported tag — Q-Audion requires ISO-7816")
            return
        }
        Task { [weak owner] in
            // Swift 6: re-bind weak capture to an immutable let so the
            // closure passed to MainActor.run captures an immutable, not
            // the mutable `var` introduced by `[weak owner]`.
            let ownerRef = owner
            do {
                try await session.connect(to: tag)
                let peerName = try await ownerRef?.runApduExchange(over: iso, session: session) ?? "(unknown)"
                await MainActor.run { [ownerRef] in
                    ownerRef?.transition(to: .success(peerDeviceName: peerName))
                }
                session.alertMessage = "Paired with \(peerName)"
                session.invalidate()
            } catch {
                session.invalidate(errorMessage: error.localizedDescription)
            }
        }
    }
}
#endif
