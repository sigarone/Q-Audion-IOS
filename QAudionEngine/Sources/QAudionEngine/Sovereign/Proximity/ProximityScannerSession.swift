import Foundation
import CryptoKit

/// The phone that SCANS the QR code (spec §9, §11): GATT central, ML-KEM
/// encapsulator, sends HELLO / ACCEPT / CONFIRM. Single use: one scanned
/// payload, one `start()`.
///
/// Threading: identical to `ProximityDisplayerSession` — main actor, every
/// entry point funnelled through `serialize`, one message at a time.
@MainActor
public final class ProximityScannerSession {

    public enum State: Equatable {
        case idle
        case connecting
        case exchanging
        case awaitingConfirmation(sas: String, peer: ProximityPeerIdentity, warning: String?, localConfirmed: Bool)
        case completed(ProximityPairingResult)
        case failed(ProximityPairingError)
    }

    public private(set) var state: State = .idle
    public var onStateChange: ((State) -> Void)?

    private enum TimerKind {
        case connectBackstop
        case handshake
        case confirmation
        case completionGrace
    }

    /// Extra time granted to the transport's own connect timeout before the
    /// session gives up on a completion that never arrives.
    private static let connectBackstopMargin: TimeInterval = 5.0

    private let payload: ProximityQrPayload
    private let identity: ProximityLocalIdentity
    private let transport: ProximityScannerTransport
    private let scheduler: ProximityScheduler
    private let identityPolicy: (ProximityPeerIdentity) -> ProximityIdentityDecision

    private var pendingOperations: [() -> Void] = []
    private var isRunningOperation: Bool = false
    private var generation: UInt64 = 0

    private var link: ProximityPairingLink?
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var scannerNonce: Data = Data()
    private var helloBody: Data = Data()
    private var offerReceived: Bool = false
    private var transcriptHash: Data = Data()
    private var displayerSigningKey: Data = Data()
    private var keys: ProximityPairingCrypto.SessionKeys?
    private var peer: ProximityPeerIdentity?
    private var warning: String?
    private var sas: String = ""
    private var localConfirmed: Bool = false
    private var peerConfirmed: Bool = false

    private var connectTimer: ProximityCancellable?
    private var handshakeTimer: ProximityCancellable?
    private var confirmationTimer: ProximityCancellable?
    private var graceTimer: ProximityCancellable?

    public init(payload: ProximityQrPayload,
                identity: ProximityLocalIdentity,
                transport: ProximityScannerTransport,
                scheduler: ProximityScheduler,
                identityPolicy: @escaping (ProximityPeerIdentity) -> ProximityIdentityDecision) {
        self.payload = payload
        self.identity = identity
        self.transport = transport
        self.scheduler = scheduler
        self.identityPolicy = identityPolicy
    }

    // MARK: - Public API

    /// Connects to the displayer named by the QR and sends HELLO. Only from idle.
    public func start() {
        serialize { [weak self] in self?.performStart() }
    }

    public func confirm() {
        serialize { [weak self] in self?.performConfirm() }
    }

    public func reject() {
        serialize { [weak self] in self?.performReject() }
    }

    public func cancel() {
        serialize { [weak self] in self?.performCancel() }
    }

    // MARK: - Serialization

    private func serialize(_ operation: @escaping () -> Void) {
        pendingOperations.append(operation)
        if isRunningOperation { return }
        isRunningOperation = true
        while !pendingOperations.isEmpty {
            let next: () -> Void = pendingOperations.removeFirst()
            next()
        }
        isRunningOperation = false
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Connect and HELLO

    private func performStart() {
        guard case .idle = state else { return }
        do {
            scannerNonce = try ProximityPairingCrypto.randomBytes(ProximityPairing.nonceBytes)
        } catch let error as ProximityPairingError {
            fail(error)
            return
        } catch {
            fail(.cryptoFailure("nonce"))
            return
        }
        ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        generation &+= 1
        let timeout: TimeInterval = ProximityPairing.scannerConnectTimeout
        connectTimer = schedule(.connectBackstop, after: timeout + ProximityScannerSession.connectBackstopMargin)
        setState(.connecting)
        let expected: UInt64 = generation
        transport.connect(serviceId: payload.sessionId, timeout: timeout) {
            [weak self] (result: Result<ProximityPairingLink, ProximityPairingError>) in
            self?.serialize { [weak self] in self?.handleConnect(result, generation: expected) }
        }
    }

    private func handleConnect(_ result: Result<ProximityPairingLink, ProximityPairingError>,
                               generation connected: UInt64) {
        switch result {
        case .failure(let error):
            guard connected == generation, case .connecting = state else { return }
            fail(error, sendAbort: false)
        case .success(let newLink):
            guard connected == generation, case .connecting = state else {
                newLink.close()
                return
            }
            connectTimer?.cancel()
            connectTimer = nil
            link = newLink
            attach(newLink)
            sendHello(on: newLink)
        }
    }

    private func sendHello(on newLink: ProximityPairingLink) {
        guard let ephemeral = ephemeralKey else {
            fail(.cryptoFailure("ephemeral key"))
            return
        }
        let xpk: Data = ephemeral.publicKey.rawRepresentation
        let tag: Data = ProximityPairingCrypto.helloTag(frameKey: payload.frameKey,
                                                        sessionId: payload.sessionId,
                                                        frameIndex: payload.frameIndex,
                                                        scannerEphemeralX25519: xpk,
                                                        scannerNonce: scannerNonce)
        guard tag.count == ProximityPairing.macBytes else {
            fail(.cryptoFailure("HELLO tag"))
            return
        }
        let hello = ProximityMessage.Hello(frameIndex: payload.frameIndex, scannerEphemeralX25519: xpk,
                                           scannerNonce: scannerNonce, tag: tag)
        helloBody = ProximityMessage.helloBody(hello)
        handshakeTimer = schedule(.handshake, after: ProximityPairing.handshakeTimeout)
        newLink.send(ProximityMessage.hello(hello).encoded())
        setState(.exchanging)
    }

    private func attach(_ newLink: ProximityPairingLink) {
        newLink.onMessage = { [weak self, weak newLink] (message: Data) in
            guard let source = newLink else { return }
            self?.serialize { [weak self] in self?.handleMessage(message, from: source) }
        }
        newLink.onClosed = { [weak self, weak newLink] (_: ProximityPairingError?) in
            guard let source = newLink else { return }
            self?.serialize { [weak self] in self?.handleClosed(source) }
        }
    }

    private func handleClosed(_ source: ProximityPairingLink) {
        guard let current = link, current === source else { return }
        link = nil
        detachAndClose(source)
        // No-op once completed: the displayer closing after COMPLETE is expected.
        fail(.transportFailed("link closed"), sendAbort: false)
    }

    // MARK: - Messages

    private func handleMessage(_ raw: Data, from source: ProximityPairingLink) {
        guard let current = link, current === source else { return }
        let message: Data = Data(raw)
        let decoded: ProximityMessage
        do {
            decoded = try ProximityMessage.decode(message)
        } catch let error as ProximityPairingError {
            fail(error)
            return
        } catch {
            fail(.protocolViolation("decode"))
            return
        }
        switch decoded {
        case .abort(reason: let reason):
            fail(.peerAborted(reason), sendAbort: false)
        case .busy:
            fail(.sessionBusy, sendAbort: false)
        case .offer(let offer):
            guard case .exchanging = state, !offerReceived else {
                fail(.protocolViolation("unexpected OFFER"))
                return
            }
            offerReceived = true
            let body: Data = Data(message.subdata(in: (message.startIndex + 1)..<message.endIndex))
            handleOffer(offer, body: body)
        case .finish(let finish):
            guard case .exchanging = state, keys != nil, peer != nil else {
                fail(.protocolViolation("unexpected FINISH"))
                return
            }
            handleFinish(finish)
        case .confirm(mac: let mac):
            guard case .awaitingConfirmation = state, !peerConfirmed else {
                fail(.protocolViolation("unexpected CONFIRM"))
                return
            }
            handlePeerConfirm(mac)
        default:
            fail(.protocolViolation("unexpected message"))
        }
    }

    private func handleOffer(_ offer: ProximityMessage.Offer, body: Data) {
        do {
            let accept: ProximityMessage.Accept = try buildAccept(offer, offerBody: body)
            link?.send(ProximityMessage.accept(accept).encoded())
        } catch let error as ProximityPairingError {
            fail(error)
        } catch {
            fail(.cryptoFailure("OFFER"))
        }
    }

    /// Commitment, identity checks, encapsulation, key schedule, ACCEPT.
    private func buildAccept(_ offer: ProximityMessage.Offer, offerBody: Data) throws -> ProximityMessage.Accept {
        let commitment: Data = ProximityPairingCrypto.commitment(sessionId: payload.sessionId, offerBody: offerBody)
        guard ProximityPairingCrypto.constantTimeEquals(commitment, payload.commitment) else {
            throw ProximityPairingError.authenticationFailed("OFFER commitment")
        }
        let candidate: ProximityPeerIdentity = offer.identity
        if candidate.signingPublicKey == identity.signingPublicKey || candidate.userId == identity.userId {
            throw ProximityPairingError.identityRejected("Non puoi associare il telefono con se stesso.")
        }
        switch identityPolicy(candidate) {
        case .accept:
            warning = nil
        case .acceptWithWarning(let message):
            warning = message
        case .reject(let message):
            throw ProximityPairingError.identityRejected(message)
        }
        guard let ephemeral = ephemeralKey else {
            throw ProximityPairingError.cryptoFailure("ephemeral key")
        }
        ephemeralKey = nil
        // Kept in the tuple (single owner) so the scrub hits the live buffer.
        var encapsulated: (ciphertext: Data, sharedSecret: Data) =
            try ProximityPairingCrypto.kemEncapsulate(publicKey: offer.mlKemPublicKey)
        defer { CryptoConstants.zeroize(&encapsulated.sharedSecret) }
        var x25519Secret: Data = try ProximityPairingCrypto.x25519SharedSecret(
            privateKey: ephemeral, peerPublicKey: offer.displayerEphemeralX25519)
        defer { CryptoConstants.zeroize(&x25519Secret) }

        let localIdentity: ProximityPeerIdentity = identity.publicIdentity
        let acceptUnsigned: Data = ProximityMessage.acceptUnsignedBody(mlKemCiphertext: encapsulated.ciphertext,
                                                                       identity: localIdentity)
        var qrBytes: Data = payload.encodedBytes
        defer { CryptoConstants.zeroize(&qrBytes) }
        let transcript: Data = ProximityPairingCrypto.transcriptHash(qrBytes: qrBytes, helloBody: helloBody,
                                                                     offerBody: offerBody,
                                                                     acceptUnsignedBody: acceptUnsigned)
        keys = try ProximityPairingCrypto.deriveSessionKeys(transcriptHash: transcript,
                                                            kemSharedSecret: encapsulated.sharedSecret,
                                                            x25519SharedSecret: x25519Secret,
                                                            scannerNonce: scannerNonce,
                                                            displayerNonce: offer.displayerNonce)
        let sigPayload: Data = ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: transcript)
        let signature: Data = try ProximityPairingCrypto.sign(sigPayload, signingPrivateKey: identity.signingPrivateKey)
        let macKey: Data = keys?.macKeyScanner ?? Data()
        let mac: Data = ProximityPairingCrypto.transcriptMac(key: macKey, transcriptHash: transcript)
        guard mac.count == ProximityPairing.macBytes else {
            throw ProximityPairingError.cryptoFailure("ACCEPT mac")
        }
        sas = keys?.sas ?? ""
        guard sas.count == ProximityPairing.sasDigits else {
            throw ProximityPairingError.cryptoFailure("SAS")
        }
        transcriptHash = transcript
        displayerSigningKey = candidate.signingPublicKey
        peer = candidate
        return ProximityMessage.Accept(mlKemCiphertext: encapsulated.ciphertext, identity: localIdentity,
                                       signature: signature, mac: mac)
    }

    private func handleFinish(_ finish: ProximityMessage.Finish) {
        let macKey: Data = keys?.macKeyDisplayer ?? Data()
        let expectedMac: Data = ProximityPairingCrypto.transcriptMac(key: macKey, transcriptHash: transcriptHash)
        guard ProximityPairingCrypto.constantTimeEquals(expectedMac, finish.mac) else {
            fail(.authenticationFailed("FINISH mac"))
            return
        }
        let sigPayload: Data = ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: transcriptHash)
        // idPub_D is bound by the QR commitment, which was verified on OFFER.
        guard ProximityPairingCrypto.verify(signature: finish.signature, payload: sigPayload,
                                            signingPublicKey: displayerSigningKey) else {
            fail(.authenticationFailed("FINISH signature"))
            return
        }
        guard let peerIdentity = peer else {
            fail(.protocolViolation("FINISH without OFFER"))
            return
        }
        handshakeTimer?.cancel()
        handshakeTimer = nil
        confirmationTimer = schedule(.confirmation, after: ProximityPairing.userConfirmationTimeout)
        setState(.awaitingConfirmation(sas: sas, peer: peerIdentity, warning: warning, localConfirmed: false))
    }

    // MARK: - Confirmation

    private func performConfirm() {
        guard case .awaitingConfirmation = state, !localConfirmed, let current = link,
              let peerIdentity = peer else { return }
        let confirmKey: Data = keys?.confirmKeyScanner ?? Data()
        let mac: Data = ProximityPairingCrypto.confirmationMac(key: confirmKey)
        guard mac.count == ProximityPairing.macBytes else {
            fail(.cryptoFailure("CONFIRM"))
            return
        }
        current.send(ProximityMessage.confirm(mac: mac).encoded())
        localConfirmed = true
        if peerConfirmed {
            complete()
            return
        }
        setState(.awaitingConfirmation(sas: sas, peer: peerIdentity, warning: warning, localConfirmed: true))
    }

    private func handlePeerConfirm(_ mac: Data) {
        let peerKey: Data = keys?.confirmKeyDisplayer ?? Data()
        let expected: Data = ProximityPairingCrypto.confirmationMac(key: peerKey)
        guard ProximityPairingCrypto.constantTimeEquals(expected, mac) else {
            fail(.authenticationFailed("CONFIRM mac"))
            return
        }
        peerConfirmed = true
        if localConfirmed {
            complete()
        }
    }

    private func complete() {
        guard let peerIdentity = peer, let psk = keys?.psk, psk.count == ProximityPairing.pskBytes else {
            fail(.cryptoFailure("completion"))
            return
        }
        let fingerprint: String = PskAdvertising.canonicalFingerprint(forPsk: psk)
        let result = ProximityPairingResult(role: .scanner, peer: peerIdentity, psk: psk,
                                            pskFingerprint: fingerprint, sas: sas,
                                            identityWarning: warning)
        cancelAllTimers()
        wipeSecrets()
        graceTimer = schedule(.completionGrace, after: ProximityPairing.completionLinkGrace)
        setState(.completed(result))
    }

    private func performReject() {
        switch state {
        case .idle, .completed, .failed:
            return
        default:
            fail(.userRejected)
        }
    }

    private func performCancel() {
        switch state {
        case .completed:
            graceTimer?.cancel()
            graceTimer = nil
            releaseLink()
            transport.cancel()
        case .idle, .failed:
            transport.cancel()
        default:
            fail(.cancelled)
        }
    }

    // MARK: - Timers

    private func schedule(_ kind: TimerKind, after delay: TimeInterval) -> ProximityCancellable {
        let expected: UInt64 = generation
        return scheduler.schedule(after: delay) { [weak self] in
            self?.serialize { [weak self] in self?.timerFired(kind, generation: expected) }
        }
    }

    private func timerFired(_ kind: TimerKind, generation fired: UInt64) {
        guard fired == generation else { return }
        switch kind {
        case .connectBackstop:
            guard case .connecting = state else { return }
            fail(.timeout("connect"), sendAbort: false)
        case .handshake:
            guard case .exchanging = state else { return }
            fail(.timeout("handshake"))
        case .confirmation:
            guard case .awaitingConfirmation = state else { return }
            fail(.timeout("confirmation"))
        case .completionGrace:
            guard case .completed = state else { return }
            graceTimer = nil
            releaseLink()
            transport.cancel()
        }
    }

    private func cancelAllTimers() {
        connectTimer?.cancel()
        handshakeTimer?.cancel()
        confirmationTimer?.cancel()
        graceTimer?.cancel()
        connectTimer = nil
        handshakeTimer = nil
        confirmationTimer = nil
        graceTimer = nil
    }

    // MARK: - Teardown

    /// Idempotent; never overrides `.completed`.
    private func fail(_ error: ProximityPairingError, sendAbort: Bool = true) {
        switch state {
        case .completed, .failed:
            return
        default:
            break
        }
        if sendAbort, let current = link {
            current.send(ProximityMessage.abort(reason: error.abortReason.rawValue).encoded())
        }
        generation &+= 1
        releaseLink()
        transport.cancel()
        cancelAllTimers()
        wipeSecrets()
        peer = nil
        warning = nil
        sas = ""
        setState(.failed(error))
    }

    private func detachAndClose(_ target: ProximityPairingLink) {
        target.onMessage = nil
        target.onClosed = nil
        target.close()
    }

    private func releaseLink() {
        if let current = link {
            link = nil
            detachAndClose(current)
        }
    }

    private func wipeSecrets() {
        keys?.zeroize()
        keys = nil
        ephemeralKey = nil
        CryptoConstants.zeroize(&transcriptHash)
        transcriptHash = Data()
    }
}
