import Foundation
import CryptoKit

/// The phone that SCANS the QR code (spec §9, §11): GATT central, ML-KEM
/// encapsulator, sends HELLO / ACCEPT / CONFIRM. Single use: one scanned
/// payload, one `start()`.
///
/// SIGMA-I (spec §10): the OFFER carries only the displayer's ephemeral keys,
/// so this side learns WHO it is pairing with only when it opens FINISH. The
/// self check and the identity policy therefore run on FINISH, and `peer`
/// stays nil until then.
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
    /// Stage-1 keys: derived on OFFER, consumed and zeroized on FINISH.
    private var handshakeKeys: ProximityPairingCrypto.HandshakeKeys?
    /// TH_S: the aad of sealed_D and the chain value of TH_D. Set once ACCEPT is built.
    private var scannerTranscriptHash: Data = Data()
    /// Stage-2 keys: derived on FINISH.
    private var keys: ProximityPairingCrypto.SessionKeys?
    /// The displayer's identity: unknown until FINISH is opened and verified.
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
        newLink.onClosed = { [weak self, weak newLink] (error: ProximityPairingError?) in
            guard let source = newLink else { return }
            self?.serialize { [weak self] in self?.handleClosed(source, error: error) }
        }
    }

    private func handleClosed(_ source: ProximityPairingLink, error: ProximityPairingError?) {
        guard let current = link, current === source else { return }
        link = nil
        detachAndClose(source)
        // No-op once completed: the displayer closing after COMPLETE is expected.
        // A transport-reported cause (e.g. a framing violation) is kept.
        let reason: ProximityPairingError = error ?? ProximityPairingError.transportFailed("link closed")
        fail(reason, sendAbort: false)
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
            // Only after our ACCEPT was built (stage-1 keys + TH_S exist) and only once.
            guard case .exchanging = state, handshakeKeys != nil, !scannerTranscriptHash.isEmpty,
                  keys == nil else {
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

    /// Commitment, encapsulation, stage-1 key schedule, sealed scanner
    /// identity, ACCEPT. The displayer's identity is not known yet: it
    /// arrives sealed in FINISH, where the self check and the policy run.
    private func buildAccept(_ offer: ProximityMessage.Offer, offerBody: Data) throws -> ProximityMessage.Accept {
        let commitment: Data = ProximityPairingCrypto.commitment(sessionId: payload.sessionId, offerBody: offerBody)
        guard ProximityPairingCrypto.constantTimeEquals(commitment, payload.commitment) else {
            throw ProximityPairingError.authenticationFailed("OFFER commitment")
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

        var qrBytes: Data = payload.encodedBytes
        defer { CryptoConstants.zeroize(&qrBytes) }
        var th1: Data = ProximityPairingCrypto.transcriptHash(qrBytes: qrBytes, helloBody: helloBody,
                                                              offerBody: offerBody,
                                                              mlKemCiphertext: encapsulated.ciphertext)
        defer { CryptoConstants.zeroize(&th1) }
        handshakeKeys = try ProximityPairingCrypto.deriveHandshakeKeys(transcriptHash: th1,
                                                                      kemSharedSecret: encapsulated.sharedSecret,
                                                                      x25519SharedSecret: x25519Secret,
                                                                      scannerNonce: scannerNonce,
                                                                      displayerNonce: offer.displayerNonce)
        let sealed: Data = try sealScannerIdentity(transcriptHash: th1)
        return ProximityMessage.Accept(mlKemCiphertext: encapsulated.ciphertext, sealed: sealed)
    }

    /// `sealed_S = Seal(K_enc_S, aad = TH1, idBlock_S ‖ sig_S ‖ mac_S)` with
    /// `TH_S = SHA-256(L_TH_S ‖ TH1 ‖ lp32(idBlock_S))`. Stores TH_S: it is the
    /// aad of sealed_D and the chain value of TH_D.
    private func sealScannerIdentity(transcriptHash th1: Data) throws -> Data {
        let idBlock: Data = ProximityMessage.idBlock(identity.publicIdentity)
        let thS: Data = ProximityPairingCrypto.identityTranscriptHash(role: .scanner, previousHash: th1,
                                                                      idBlock: idBlock)
        guard thS.count == ProximityPairing.transcriptHashBytes else {
            throw ProximityPairingError.cryptoFailure("TH_S")
        }
        let sigPayload: Data = ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: thS)
        let signature: Data = try ProximityPairingCrypto.sign(sigPayload, signingPrivateKey: identity.signingPrivateKey)
        let mac: Data = ProximityPairingCrypto.transcriptMac(key: handshakeKeys?.macKeyScanner ?? Data(),
                                                             transcriptHash: thS)
        guard mac.count == ProximityPairing.macBytes else {
            throw ProximityPairingError.cryptoFailure("ACCEPT mac")
        }
        let plaintext: Data = ProximityMessage.sealedPlaintext(idBlock: idBlock, signature: signature, mac: mac)
        let sealed: Data = try ProximityPairingCrypto.aeadSeal(plaintext,
                                                              key: handshakeKeys?.encKeyScanner ?? Data(),
                                                              transcriptHash: th1)
        scannerTranscriptHash = thS
        return sealed
    }

    private func handleFinish(_ finish: ProximityMessage.Finish) {
        do {
            try verifyFinish(finish)
        } catch let error as ProximityPairingError {
            fail(error)
            return
        } catch {
            fail(.cryptoFailure("FINISH"))
            return
        }
        guard let peerIdentity = peer else {
            fail(.cryptoFailure("FINISH"))
            return
        }
        handshakeTimer?.cancel()
        handshakeTimer = nil
        confirmationTimer = schedule(.confirmation, after: ProximityPairing.userConfirmationTimeout)
        setState(.awaitingConfirmation(sas: sas, peer: peerIdentity, warning: warning, localConfirmed: false))
    }

    /// Opens sealed_D (K_enc_D, aad TH_S), parses idBlock_D strictly, verifies
    /// mac_D and sig_D over TH_D, then the self check and the identity policy
    /// (the first time this side sees the displayer's identity), then stage 2.
    /// On success stores keys / peer / warning / SAS; every stage-1 value is
    /// zeroized by then.
    private func verifyFinish(_ finish: ProximityMessage.Finish) throws {
        let plaintext: Data = try ProximityPairingCrypto.aeadOpen(finish.sealed,
                                                                  key: handshakeKeys?.encKeyDisplayer ?? Data(),
                                                                  transcriptHash: scannerTranscriptHash)
        let opened: ProximityMessage.SealedIdentity = try ProximityMessage.decodeSealedPlaintext(plaintext)
        var thD: Data = ProximityPairingCrypto.identityTranscriptHash(role: .displayer,
                                                                      previousHash: scannerTranscriptHash,
                                                                      idBlock: opened.idBlock)
        defer { CryptoConstants.zeroize(&thD) }
        guard thD.count == ProximityPairing.transcriptHashBytes else {
            throw ProximityPairingError.cryptoFailure("TH_D")
        }
        let expectedMac: Data = ProximityPairingCrypto.transcriptMac(key: handshakeKeys?.macKeyDisplayer ?? Data(),
                                                                     transcriptHash: thD)
        guard ProximityPairingCrypto.constantTimeEquals(expectedMac, opened.mac) else {
            throw ProximityPairingError.authenticationFailed("FINISH mac")
        }
        let sigPayload: Data = ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: thD)
        guard ProximityPairingCrypto.verify(signature: opened.signature, payload: sigPayload,
                                            signingPublicKey: opened.identity.signingPublicKey) else {
            throw ProximityPairingError.authenticationFailed("FINISH signature")
        }
        let decidedWarning: String? = try evaluatePeer(opened.identity)
        try deriveFinalKeys(displayerTranscriptHash: thD)
        let finalSas: String = keys?.sas ?? ""
        guard finalSas.count == ProximityPairing.sasDigits else {
            throw ProximityPairingError.cryptoFailure("SAS")
        }
        sas = finalSas
        warning = decidedWarning
        peer = opened.identity
    }

    /// Spec §12: never pair with ourselves (same Ed25519 key or same userId),
    /// then the host's identity policy. Returns the warning to show (nil for a
    /// plain accept); throws `.identityRejected` otherwise.
    private func evaluatePeer(_ candidate: ProximityPeerIdentity) throws -> String? {
        if candidate.signingPublicKey == identity.signingPublicKey || candidate.userId == identity.userId {
            throw ProximityPairingError.identityRejected("Non puoi associare il telefono con se stesso.")
        }
        switch identityPolicy(candidate) {
        case .accept:
            return nil
        case .acceptWithWarning(let message):
            return message
        case .reject(let message):
            throw ProximityPairingError.identityRejected(message)
        }
    }

    /// Stage 2 (PRK2 from TH_D and PRK1), then scrub every stage-1 value.
    /// The `if let` copy of the stage-1 keys ends with its scope, so the scrub
    /// below hits the live buffers, not a copy-on-write duplicate.
    private func deriveFinalKeys(displayerTranscriptHash: Data) throws {
        if let stageOne = handshakeKeys {
            keys = try ProximityPairingCrypto.deriveSessionKeys(handshakeKeys: stageOne,
                                                                displayerTranscriptHash: displayerTranscriptHash)
        } else {
            throw ProximityPairingError.cryptoFailure("stage-1 keys")
        }
        handshakeKeys?.zeroize()
        handshakeKeys = nil
        CryptoConstants.zeroize(&scannerTranscriptHash)
        scannerTranscriptHash = Data()
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
        guard let peerIdentity = peer, var psk = keys?.psk, psk.count == ProximityPairing.pskBytes else {
            fail(.cryptoFailure("completion"))
            return
        }
        let fingerprint: String = PskAdvertising.canonicalFingerprint(forPsk: psk)
        let result = ProximityPairingResult(role: .scanner, peer: peerIdentity, psk: psk,
                                            pskFingerprint: fingerprint, sas: sas,
                                            identityWarning: warning)
        cancelAllTimers()
        wipeSecrets()
        // `psk` shared its buffer with `keys.psk`, so the scrub above hit a
        // copy-on-write copy; this one hits the original (the result owns its
        // own copy, made by ProximityPairingResult.init).
        CryptoConstants.zeroize(&psk)
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
        handshakeKeys?.zeroize()
        handshakeKeys = nil
        ephemeralKey = nil
        CryptoConstants.zeroize(&scannerTranscriptHash)
        scannerTranscriptHash = Data()
    }
}
