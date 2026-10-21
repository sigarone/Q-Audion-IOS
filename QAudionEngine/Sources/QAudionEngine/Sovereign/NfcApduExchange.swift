import Foundation
import CryptoKit
#if canImport(CoreNFC) && os(iOS)
import CoreNFC
#endif

/// iPhone side of NFC pairing v2 (docs/security/NFC_PAIRING_V2.md). The iPhone is only ever the reader; the other
/// phone is an Android phone in card mode (AID `F0 BC F1 07 3A 51 00`).
///
/// ## Two taps
///
/// Tap 1 is one reader session: the exchange runs up to REVEAL, both phones derive the same 6-digit code from the
/// whole transcript, the session closes and the sheet shows the code in its final message. Nothing is stored. The
/// users compare the two screens; ``confirmSas()`` then opens tap 2, a new reader session started by that user action.
/// Tap 2 polls the card until it has stored the key and proved it (`confirm_C`); only then does this phone store its
/// copy (``onPskDerived``, which also finalizes: F1) and send FINALIZE. If the other person has not decided yet, or
/// the field is lost, the screen offers to hold the phones together again until the 120 s of the user run out. A
/// local reject sends nothing: the card times out by itself.
///
/// The state machine itself is ``NfcReaderCeremony`` (no CoreNFC); this class owns the sessions, the screen state and
/// the identity policy. `NFCTagReaderSession` is iOS-only; elsewhere ``start()`` reports the unavailable line.
@MainActor
public final class NfcApduExchange: NSObject {

    // MARK: - Public types

    public enum State: Equatable {
        case idle
        /// Tap 1: the reader session is open, waiting for the other phone.
        case waiting
        /// Tap 1: the other phone is in the field and the exchange is running.
        case exchanging
        /// Both identity proofs verified; nothing is stored. `sas` is the code derived from the whole transcript.
        case sasConfirm(sas: String, peerDeviceName: String)
        /// The user confirmed here; the phones must be held together again to finish.
        case holdAgain(peerDeviceName: String)
        /// Tap 2: the session is open and the exchange with the other phone is running.
        case confirming(peerDeviceName: String)
        /// Tap 2: the other person has not decided yet.
        case waitingForPeer(peerDeviceName: String)
        case success(peerDeviceName: String)
        /// The other person rejected (proven by their tag); nothing was stored.
        case peerRejected(peerDeviceName: String)
        case error(String)
    }

    /// What the store step did, for the log.
    public struct StoreOutcome: Equatable, Sendable {
        public let replaced: Bool
        public let deleted: Int

        public init(replaced: Bool, deleted: Int) {
            self.replaced = replaced
            self.deleted = deleted
        }
    }

    // MARK: - Public interface

    public internal(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    /// Called whenever ``state`` changes.
    public var onStateChanged: ((State) -> Void)?

    /// Called once, when the other phone proved it stored the key and this user had confirmed: store the key bound
    /// to the verified peer identity and finalize it (the earlier keys of that device are deleted: F1,
    /// docs/security/CALL_KEY_PRIORITY.md section 4a). Parameters: `(psk: 32B, peerIdentityPub: 32B Ed25519)`. It
    /// must throw if the key could not be stored.
    public var onPskDerived: ((Data, Data) async throws -> StoreOutcome)?

    /// Warning for the confirmation screen about the verified identity (a pinned key that differs, an account that
    /// does not publish the proven key). Nil when there is none.
    public private(set) var identityWarning: String?

    /// Local Ed25519 identity public key (32 bytes). Must be set before ``start()``; the private key is read from
    /// the identity manager and has to belong to it.
    public var localIdentityPublicKey: Data?

    /// The account id sent in the sealed identity block (`n = 0` when empty: no account id).
    public var localUserId: String = ""

    /// Optional pinned peer identity for a contact-targeted re-pairing: the exchange stops with
    /// `peer_identity_changed` if the other phone proves a different key.
    public var expectedPeerIdentityPub: Data?

    /// Optional lookup of the identity keys an account publishes (the same one proximity pairing uses). A proven key
    /// that is not among them adds a warning to the confirmation screen.
    public var serverIdentityKeys: ((String) async -> Set<Data>)?

    // MARK: - Test seams

    var identityProvider: (() -> NfcPairingV2LocalIdentity?)?
    var environment: NfcReaderEnvironment = .live
    /// Sleeps until the 120 s of the user are over (a test replaces it).
    var timerSleepMs: (UInt64) async -> Void = { ms in try? await Task.sleep(nanoseconds: ms * 1_000_000) }
    /// False in the tests: no CoreNFC session is opened, the tests drive `performFirstTap` / `performConfirmTap`.
    var opensSessions: Bool = true
    var assessor: (NfcPairingV2Identity, NfcPairingV2Policy.ServerCheck) -> NfcPeerAssessment = { peer, check in
        NfcPairingV2Policy.liveAssessment(peer: peer, serverCheck: check)
    }

    private static let serverCheckTimeoutMs: UInt64 = 3_000

    // MARK: - Init

    private let availability: NfcAvailability
    private var ceremony: NfcReaderCeremony?
    private var peerName: String = ""
    private var confirmationTimer: Task<Void, Never>?
    private var localStoreFailed: Bool = false

    public init(availability: NfcAvailability = .device) {
        self.availability = availability
        super.init()
    }

    // MARK: - Lifecycle

    /// Begin tap 1. On macOS (no CoreNFC) transitions immediately to `.error`.
    public func start() {
        guard prepareCeremony() else { return }
        #if canImport(CoreNFC) && os(iOS)
        if opensSessions { openSession(.first) }
        #else
        if opensSessions { state = .error(NfcAvailability.unavailableMessage) }
        #endif
    }

    /// Checks the prerequisites and creates the ceremony of a new pairing. False (with the error on screen) when
    /// the phone has no usable identity or cannot read NFC tags.
    func prepareCeremony() -> Bool {
        guard let idPub = localIdentityPublicKey, idPub.count == 32 else {
            state = .error(String(localized: "nfc.error.identity_key_invalid", defaultValue: "Chiave pubblica d'identità locale mancante o non valida", comment: "NFC pairing error: this phone's own identity key is missing or malformed."))
            return false
        }
        guard availability.isAvailable else {
            state = .error(NfcAvailability.unavailableMessage)
            return false
        }
        guard let local = loadLocalIdentity(expectedPublicKey: idPub) else {
            state = .error(String(localized: "nfc.error.identity_key_missing", defaultValue: "Chiave d'identità locale non configurata", comment: "NFC pairing error: this phone has no identity key yet."))
            return false
        }
        resetCeremony()
        ceremony = NfcReaderCeremony(local: local, pinnedPeerKey: expectedPeerIdentityPub, environment: environment)
        return true
    }

    /// The user compared the codes and they match. Opens tap 2. No-op unless the code is on screen.
    public func confirmSas() {
        guard case .sasConfirm = state, let ceremony, ceremony.hasStagedCeremony else { return }
        guard ceremony.remainingConfirmationMs() > 0 else {
            expireCeremony()
            return
        }
        ceremony.userDidConfirm()
        state = .holdAgain(peerDeviceName: peerName)
        if opensSessions { beginConfirmSession() }
    }

    /// The user could not match the codes, or backed out. Nothing is sent: the card times out on its own.
    public func rejectSas() {
        guard ceremony?.hasStagedCeremony == true else { return }
        switch state {
        case .sasConfirm, .holdAgain, .waitingForPeer, .confirming:
            break
        default:
            return
        }
        resetCeremony(rejected: true)
        state = .error(String(localized: "nfc.error.sas_rejected", defaultValue: "Codice non confermato — scambio annullato", comment: "NFC pairing: the user said the 6-digit codes do not match, the exchange is cancelled."))
    }

    /// Opens tap 2 again (after the other person had not decided yet, or the field was lost).
    public func holdAgain() {
        guard case .holdAgain = state, ceremony?.hasStagedCeremony == true else { return }
        if opensSessions { beginConfirmSession() }
    }

    /// Cancel any running session and discard a ceremony waiting for the user (nothing is sent).
    public func cancel() {
        resetCeremony(rejected: ceremony?.hasStagedCeremony == true)
        switch state {
        case .waiting, .exchanging, .sasConfirm, .holdAgain, .confirming, .waitingForPeer:
            state = .idle
        default:
            break
        }
    }

    private func resetCeremony(rejected: Bool = false) {
        confirmationTimer?.cancel()
        confirmationTimer = nil
        #if canImport(CoreNFC) && os(iOS)
        endSessionIfActive()
        #endif
        if rejected {
            ceremony?.rejectLocally()
        } else {
            ceremony?.discard()
        }
        ceremony = nil
        identityWarning = nil
        localStoreFailed = false
    }

    private func loadLocalIdentity(expectedPublicKey: Data) -> NfcPairingV2LocalIdentity? {
        if let identityProvider {
            return identityProvider()
        }
        guard let stored = SovereignIdentityManager().loadIdentity() else { return nil }
        var seed = Data(stored.signingPrivate)
        defer { CryptoConstants.zeroize(&seed) }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              key.publicKey.rawRepresentation == Data(stored.signingPublic),
              Data(stored.signingPublic) == expectedPublicKey,
              let identity = try? NfcPairingV2Identity(publicKey: expectedPublicKey, userId: localUserId) else {
            return nil
        }
        return NfcPairingV2LocalIdentity(identity: identity, signingPrivateKey: seed)
    }

    // MARK: - Tap logic (no CoreNFC)

    /// What the session layer does with the system sheet after a tap.
    enum TapEnd: Equatable {
        /// Close the sheet; `message` is its final text (the code, or the success line).
        case finished(message: String)
        /// Close the sheet with this error text.
        case failed(message: String)
        /// Close the sheet with this text and offer to hold the phones together again.
        case holdAgain(message: String)
    }

    /// Tap 1 over `transport`: the exchange up to REVEAL, the identity assessment, the code on screen.
    func performFirstTap(over transport: NfcIso7816Transport) async -> TapEnd {
        guard let ceremony else {
            let message = Self.message(for: NfcPairingV2Failure(.order))
            state = .error(message)
            return .failed(message: message)
        }
        state = .exchanging
        do {
            let first = try await ceremony.runFirstTap(over: transport)
            // Cancelled while the tap was running: the screen has moved on, nothing may come back to life.
            guard self.ceremony === ceremony else {
                ceremony.discard()
                return .failed(message: Self.message(for: NfcPairingV2Failure(.userRejected)))
            }
            let serverCheck = await checkServer(for: first.peer)
            guard self.ceremony === ceremony else {
                ceremony.discard()
                return .failed(message: Self.message(for: NfcPairingV2Failure(.userRejected)))
            }
            let assessment = assessor(first.peer, serverCheck)
            peerName = assessment.contactName ?? Self.unknownPeerName
            identityWarning = assessment.warning
            NfcPairingLog.sasShown(role: .reader, peerKnown: assessment.peerKnown, pinned: assessment.pinned,
                                   logTag: first.logTag)
            state = .sasConfirm(sas: first.sas, peerDeviceName: peerName)
            startConfirmationTimer()
            return .finished(message: Self.codeMessage(first.sas))
        } catch let failure as NfcPairingV2Failure {
            let message = Self.message(for: failure)
            if self.ceremony === ceremony { state = .error(message) }
            return .failed(message: message)
        } catch {
            let message = Self.message(for: NfcPairingV2Failure(.cardError))
            if self.ceremony === ceremony { state = .error(message) }
            return .failed(message: message)
        }
    }

    /// Tap 2 over `transport`: poll the card, store on a verified `confirm_C`, FINALIZE.
    func performConfirmTap(over transport: NfcIso7816Transport) async -> TapEnd {
        guard let ceremony, ceremony.hasStagedCeremony else {
            let message = Self.message(for: NfcPairingV2Failure(.noCeremony))
            state = .error(message)
            return .failed(message: message)
        }
        state = .confirming(peerDeviceName: peerName)
        let name = peerName
        let result = await ceremony.runConfirmTap(
            over: transport,
            progress: { [weak self] decision in
                if decision == .pending, let self, case .confirming = self.state {
                    self.state = .waitingForPeer(peerDeviceName: name)
                }
            },
            store: { [weak self] psk, peer in
                // Nothing is stored for a ceremony the user cancelled or rejected in the meantime.
                guard let self, self.ceremony === ceremony, let handler = self.onPskDerived else {
                    throw NfcPairingV2Failure(.storeFailed)
                }
                do {
                    let outcome = try await handler(psk, peer.publicKey)
                    return NfcReaderStoreOutcome(replaced: outcome.replaced, deleted: outcome.deleted)
                } catch {
                    self.localStoreFailed = true
                    throw error
                }
            })
        var storedAlready = false
        if case .stored = result { storedAlready = true }
        guard self.ceremony === ceremony || storedAlready else {
            // Cancelled or rejected while the tap was running: the screen already moved on.
            ceremony.discard()
            return .failed(message: Self.message(for: NfcPairingV2Failure(.userRejected)))
        }
        switch result {
        case .stored:
            confirmationTimer?.cancel()
            confirmationTimer = nil
            self.ceremony = nil
            state = .success(peerDeviceName: name)
            return .finished(message: String(localized: "nfc.session.paired", defaultValue: "Associato con \(name)", comment: "System NFC sheet message after a successful pairing; %@ is the other phone's name."))
        case .peerRejected:
            confirmationTimer?.cancel()
            confirmationTimer = nil
            self.ceremony = nil
            state = .peerRejected(peerDeviceName: name)
            return .failed(message: Self.message(for: NfcPairingV2Failure(.peerRejected)))
        case .stillPending, .fieldLost:
            if ceremony.remainingConfirmationMs() == 0 {
                expireCeremony()
                return .failed(message: Self.message(for: NfcPairingV2Failure(.timeout)))
            }
            state = .holdAgain(peerDeviceName: name)
            return .holdAgain(message: String(localized: "nfc.session.hold_again", defaultValue: "Avvicina di nuovo i telefoni per terminare.", comment: "System NFC sheet message: the pairing is not finished, hold the phones together again."))
        case .failed(let token):
            confirmationTimer?.cancel()
            confirmationTimer = nil
            self.ceremony = nil
            let message = Self.message(for: NfcPairingV2Failure(token), localStoreFailed: localStoreFailed)
            state = .error(message)
            return .failed(message: message)
        }
    }

    private func checkServer(for peer: NfcPairingV2Identity) async -> NfcPairingV2Policy.ServerCheck {
        guard let lookup = serverIdentityKeys, !peer.userId.isEmpty else { return .unavailable }
        let userId = peer.userId
        let presented = peer.publicKey
        let timeoutMs = Self.serverCheckTimeoutMs
        let published: Set<Data>? = await withTaskGroup(of: Set<Data>?.self) { group in
            group.addTask { await lookup(userId) }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let published else { return .unavailable }
        return NfcPairingV2Policy.serverVerdict(published: published, presented: presented)
    }

    // MARK: - The 120 s of the user

    private func startConfirmationTimer() {
        confirmationTimer?.cancel()
        guard let ceremony else { return }
        let remaining = ceremony.remainingConfirmationMs()
        let sleepMs = timerSleepMs
        confirmationTimer = Task { [weak self] in
            await sleepMs(remaining)
            if Task.isCancelled { return }
            self?.confirmationTimerFired()
        }
    }

    func confirmationTimerFired() {
        guard let ceremony, ceremony.hasStagedCeremony else { return }
        switch state {
        case .sasConfirm, .holdAgain, .waitingForPeer, .confirming:
            if ceremony.remainingConfirmationMs() == 0 {
                expireCeremony()
            }
        default:
            break
        }
    }

    private func expireCeremony() {
        confirmationTimer?.cancel()
        confirmationTimer = nil
        #if canImport(CoreNFC) && os(iOS)
        endSessionIfActive()
        #endif
        ceremony?.expire()
        ceremony = nil
        state = .error(Self.message(for: NfcPairingV2Failure(.timeout)))
    }

    // MARK: - Texts

    private static var unknownPeerName: String {
        String(localized: "nfc.peer_unknown", defaultValue: "un telefono sconosciuto", comment: "Name shown for the other phone in NFC pairing when its identity matches no contact. Used mid-sentence after \"con\" / \"with\", so it carries its own article.")
    }

    /// `123 456`.
    static func groupedCode(_ sas: String) -> String {
        guard sas.count == 6 else { return sas }
        return String(sas.prefix(3)) + " " + String(sas.suffix(3))
    }

    static func codeMessage(_ sas: String) -> String {
        let grouped = groupedCode(sas)
        return String(localized: "nfc.session.code", defaultValue: "Codice: \(grouped). Confrontalo con l\u{2019}altro telefono.", comment: "Final text of the system NFC sheet after the first tap; %@ is the 6-digit code grouped as 123 456.")
    }

    /// The text for a failed ceremony. Never contains a key, a code or an identity.
    static func message(for failure: NfcPairingV2Failure, localStoreFailed: Bool = false) -> String {
        switch failure.token {
        case .version:
            return String(localized: "nfc.error.update_other_app", defaultValue: "L\u{2019}altro telefono usa una versione di Q-Audion non compatibile. Aggiorna l\u{2019}app sull\u{2019}altro telefono.", comment: "NFC pairing error: the other phone runs an older version of the app.")
        case .notArmed:
            return String(localized: "nfc.error.not_ready", defaultValue: "Sull\u{2019}altro telefono apri la schermata di associazione NFC e premi Pronto, poi riprova.", comment: "NFC pairing error: the other phone is not showing its pairing screen in the ready state.")
        case .identitySelf:
            return String(localized: "nfc.error.self_pairing", defaultValue: "Non puoi associare il telefono con se stesso.", comment: "NFC pairing error: the other phone presented this phone's own identity.")
        case .identityInvalid:
            return String(localized: "nfc.error.identity_invalid", defaultValue: "L\u{2019}altro telefono ha presentato una chiave di identità non valida.", comment: "NFC pairing error: the identity key of the other phone is not acceptable.")
        case .peerIdentityChanged:
            return String(localized: "nfc.error.peer_identity_changed", defaultValue: "La chiave d'identità dell'altro telefono è cambiata dall'ultima associazione: operazione annullata (possibile attacco)", comment: "NFC pairing error: the other phone presented a different identity key than the one stored.")
        case .rtt:
            return String(localized: "nfc.error.too_slow", defaultValue: "L\u{2019}altro telefono ha risposto troppo lentamente. Tieni i telefoni fermi e riprova.", comment: "NFC pairing error: the answer of the other phone took too long.")
        case .timeout:
            return String(localized: "nfc.error.timeout", defaultValue: "Tempo scaduto. Ricomincia l\u{2019}associazione.", comment: "NFC pairing error: the time for the pairing ran out.")
        case .userRejected, .peerRejected:
            return String(localized: "nfc.error.peer_rejected", defaultValue: "L\u{2019}altra persona ha rifiutato l\u{2019}associazione.", comment: "NFC pairing: the other person did not confirm the code.")
        case .noCeremony:
            return String(localized: "nfc.error.no_ceremony", defaultValue: "L\u{2019}altro telefono non ha più questa associazione. Ricomincia.", comment: "NFC pairing error: the other phone no longer holds this pairing.")
        case .storeFailed:
            if localStoreFailed {
                return String(localized: "nfc.error.store_failed_here", defaultValue: "Impossibile salvare la chiave su questo telefono. Ricomincia.", comment: "NFC pairing error: the key could not be saved on this phone.")
            }
            return String(localized: "nfc.error.store_failed_there", defaultValue: "L\u{2019}altro telefono non è riuscito a salvare la chiave. Ricomincia.", comment: "NFC pairing error: the other phone could not save the key.")
        case .fieldLost:
            return String(localized: "nfc.error.field_lost", defaultValue: "Connessione NFC interrotta. Avvicina di nuovo i telefoni e riprova.", comment: "NFC pairing error: the NFC connection to the other phone was lost.")
        case .order, .length, .userId, .x25519Zero, .kem, .openFailed, .mac, .signature, .commitment, .cardError:
            return String(localized: "nfc.error.security_check", defaultValue: "Verifica di sicurezza non riuscita. Ricomincia l\u{2019}associazione.", comment: "NFC pairing error: a check of the exchange failed, nothing was saved.")
        }
    }

    // MARK: - CoreNFC internals (iOS-only)

    #if canImport(CoreNFC) && os(iOS)
    fileprivate enum SessionKind {
        case first
        case confirm
    }

    private var nfcSession: NFCTagReaderSession?
    private var tagDelegate: TagDelegate?
    /// Bumped whenever a session ends, so a callback of a session that is already over is ignored.
    private var generation: Int = 0

    private func endSessionIfActive() {
        generation &+= 1
        nfcSession?.invalidate()
        nfcSession = nil
        tagDelegate = nil
    }

    private func beginConfirmSession() {
        openSession(.confirm)
    }

    private func openSession(_ kind: SessionKind) {
        endSessionIfActive()
        let delegate = TagDelegate()
        delegate.owner = self
        delegate.generation = generation
        delegate.kind = kind
        tagDelegate = delegate
        guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: delegate, queue: nil) else {
            state = .error(String(localized: "nfc.error.session_failed", defaultValue: "Impossibile avviare la lettura NFC", comment: "NFC pairing error: the NFC reader session could not be created."))
            return
        }
        switch kind {
        case .first:
            session.alertMessage = String(localized: "nfc.session.hold_near", defaultValue: "Avvicina l'iPhone al telefono Android con Q-Audion.", comment: "System NFC sheet message: hold the iPhone near the other phone.")
        case .confirm:
            session.alertMessage = String(localized: "nfc.session.hold_again_start", defaultValue: "Avvicina di nuovo l\u{2019}iPhone all\u{2019}altro telefono per terminare.", comment: "System NFC sheet message of the second tap: hold the iPhone to the other phone again to finish.")
        }
        nfcSession = session
        session.begin()
        if kind == .first { state = .waiting }
    }

    fileprivate func handleDetected(tags: [NFCTag], session: NFCTagReaderSession, kind: SessionKind, generation gen: Int) async {
        guard gen == generation else { return }
        guard let tag = tags.first, case .iso7816(let iso) = tag else {
            session.invalidate(errorMessage: String(localized: "nfc.error.incompatible_tag", defaultValue: "Tag non compatibile: serve un telefono Android con Q-Audion", comment: "System NFC sheet message: the tapped object is not a phone running Q-Audion."))
            return
        }
        do {
            try await session.connect(to: tag)
        } catch {
            fail(session: session, kind: kind, generation: gen, failure: NfcPairingV2Failure(.fieldLost))
            return
        }
        guard gen == generation else { return }
        let transport = CoreNfcTransport(tag: iso)
        let end: TapEnd
        switch kind {
        case .first: end = await performFirstTap(over: transport)
        case .confirm: end = await performConfirmTap(over: transport)
        }
        guard gen == generation else { return }
        generation &+= 1
        nfcSession = nil
        tagDelegate = nil
        switch end {
        case .finished(let message):
            session.alertMessage = message
            session.invalidate()
        case .failed(let message), .holdAgain(let message):
            session.invalidate(errorMessage: message)
        }
    }

    private func fail(session: NFCTagReaderSession, kind: SessionKind, generation gen: Int, failure: NfcPairingV2Failure) {
        guard gen == generation else { return }
        generation &+= 1
        nfcSession = nil
        tagDelegate = nil
        let message = Self.message(for: failure)
        switch kind {
        case .first:
            state = .error(message)
        case .confirm:
            state = ceremony?.hasStagedCeremony == true ? .holdAgain(peerDeviceName: peerName) : .error(message)
        }
        session.invalidate(errorMessage: message)
    }

    fileprivate func handleSessionInvalidated(_ error: Error, kind: SessionKind, generation gen: Int) {
        guard gen == generation else { return }
        generation &+= 1
        nfcSession = nil
        tagDelegate = nil
        let userCancelled = (error as? NFCReaderError)?.code == .readerSessionInvalidationErrorUserCanceled
        switch kind {
        case .first:
            if userCancelled {
                if case .waiting = state { state = .idle }
                if case .exchanging = state { state = .idle }
            } else {
                // "Session invalidated" and "tag connection lost" are a lost field, never a rejection.
                NfcPairingLog.fail(role: .reader, NfcPairingV2Failure(.fieldLost))
                state = .error(Self.message(for: NfcPairingV2Failure(.fieldLost)))
            }
        case .confirm:
            // The staged ceremony stays: the user can hold the phones together again until the 120 s run out.
            if ceremony?.hasStagedCeremony == true, ceremony?.remainingConfirmationMs() ?? 0 > 0 {
                if !userCancelled { NfcPairingLog.fail(role: .reader, NfcPairingV2Failure(.fieldLost), step: .confirm) }
                state = .holdAgain(peerDeviceName: peerName)
            }
        }
    }

    fileprivate final class TagDelegate: NSObject, NFCTagReaderSessionDelegate {
        weak var owner: NfcApduExchange?
        var generation: Int = 0
        var kind: SessionKind = .first

        func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

        func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
            let gen = generation
            let kind = kind
            Task { @MainActor [weak owner] in
                owner?.handleSessionInvalidated(error, kind: kind, generation: gen)
            }
        }

        func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
            let gen = generation
            let kind = kind
            Task { @MainActor [weak owner] in
                await owner?.handleDetected(tags: tags, session: session, kind: kind, generation: gen)
            }
        }
    }
    #else
    private func beginConfirmSession() {}
    #endif
}

#if canImport(CoreNFC) && os(iOS)
/// The CoreNFC tag as a transport: one APDU at a time, a time limit per APDU, every CoreNFC error as a lost field.
private final class CoreNfcTransport: NfcIso7816Transport {
    private static let perApduTimeoutMs: UInt64 = 4_000

    private let tag: NFCISO7816Tag

    init(tag: NFCISO7816Tag) {
        self.tag = tag
    }

    func transceive(_ command: NfcApduCommand) async throws -> NfcApduResponse {
        let apdu = NFCISO7816APDU(instructionClass: command.cla, instructionCode: command.ins,
                                  p1Parameter: command.p1, p2Parameter: command.p2,
                                  data: command.data, expectedResponseLength: command.expectedLength ?? -1)
        let tag = self.tag
        return try await Self.withTimeout(milliseconds: Self.perApduTimeoutMs) {
            do {
                let (data, sw1, sw2) = try await tag.sendCommand(apdu: apdu)
                return NfcApduResponse(data: data, statusWord: (UInt16(sw1) << 8) | UInt16(sw2))
            } catch {
                // "Tag connection lost", "session invalidated" and the like.
                throw NfcTransportError.fieldLost
            }
        }
    }

    /// `sendCommand` cannot be cancelled, so the timeout is a race, not a task group (a group would wait for it).
    private static func withTimeout<T: Sendable>(milliseconds: UInt64,
                                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = OnceResume(continuation)
            Task {
                do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                once.resume(.failure(NfcTransportError.timeout))
            }
        }
    }

    private final class OnceResume<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<T, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }
}
#endif
