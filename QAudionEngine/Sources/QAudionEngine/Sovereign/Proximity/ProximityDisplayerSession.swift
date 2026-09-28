import Foundation
import CryptoKit

/// The phone that SHOWS the QR code (spec §6, §9, §11): GATT peripheral,
/// ML-KEM-1024 key owner, receives HELLO / ACCEPT / CONFIRM.
///
/// SIGMA-I (spec §10): the QR and the OFFER carry only ephemeral keys. This
/// side learns the scanner's identity by opening sealed_S in ACCEPT, and
/// reveals its own only inside sealed_D (FINISH), after the scanner has
/// proven it holds the keys derived from this session's shared secret.
///
/// Threading: every entry point (public methods, link / transport callbacks,
/// timers) runs on the main actor and is funnelled through `serialize`, so
/// protocol messages are processed strictly one at a time and a state-change
/// observer that calls back into the session (e.g. `confirm()` from
/// `onStateChange`) runs only after the current step has finished.
@MainActor
public final class ProximityDisplayerSession {

    public enum State: Equatable {
        case idle
        case showing(ProximityQrPayload)
        case exchanging
        case awaitingConfirmation(sas: String, peer: ProximityPeerIdentity, warning: String?, localConfirmed: Bool)
        case completed(ProximityPairingResult)
        case failed(ProximityPairingError)
    }

    public private(set) var state: State = .idle
    public var onStateChange: ((State) -> Void)?

    private enum TimerKind {
        case rotation
        case lifetime
        case handshake
        case confirmation
        case completionGrace
    }

    private let identity: ProximityLocalIdentity
    private let transport: ProximityDisplayerTransport
    private let scheduler: ProximityScheduler
    private let identityPolicy: (ProximityPeerIdentity) -> ProximityIdentityDecision

    // Serialization.
    private var pendingOperations: [() -> Void] = []
    private var isRunningOperation: Bool = false
    /// Bumped on every new session and every teardown so stale timers are inert.
    private var generation: UInt64 = 0

    // Per-session material (spec §6). Secrets are zeroized by `wipeSecrets()`.
    private var sessionId: Data = Data()
    private var sessionSecret: Data = Data()
    private var kemSecretKey: Data = Data()
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var displayerNonce: Data = Data()
    private var offerBody: Data = Data()
    private var commitment: Data = Data()
    private var currentFrameIndex: UInt32 = 0
    private var frameShownAt: [UInt32: TimeInterval] = [:]

    // Links.
    private var candidates: [ProximityPairingLink] = []
    private var lockedLink: ProximityPairingLink?

    // Handshake.
    private var qrBytes: Data = Data()
    private var helloBody: Data = Data()
    private var scannerEphemeral: Data = Data()
    private var scannerNonce: Data = Data()
    /// Stage-1 keys: derived and consumed while processing ACCEPT.
    private var handshakeKeys: ProximityPairingCrypto.HandshakeKeys?
    /// Stage-2 keys: derived once FINISH is built.
    private var keys: ProximityPairingCrypto.SessionKeys?
    private var peer: ProximityPeerIdentity?
    private var warning: String?
    private var sas: String = ""
    private var localConfirmed: Bool = false
    private var peerConfirmed: Bool = false

    // Timers.
    private var rotationTimer: ProximityCancellable?
    private var lifetimeTimer: ProximityCancellable?
    private var handshakeTimer: ProximityCancellable?
    private var confirmationTimer: ProximityCancellable?
    private var graceTimer: ProximityCancellable?

    public init(identity: ProximityLocalIdentity,
                transport: ProximityDisplayerTransport,
                scheduler: ProximityScheduler,
                identityPolicy: @escaping (ProximityPeerIdentity) -> ProximityIdentityDecision) {
        self.identity = identity
        self.transport = transport
        self.scheduler = scheduler
        self.identityPolicy = identityPolicy
        installTransportCallbacks()
    }

    // MARK: - Public API

    /// Generates a fresh session and shows frame 0. Allowed from idle, failed and completed.
    public func start() {
        serialize { [weak self] in self?.performStart() }
    }

    /// The local user confirmed the SAS. Sends CONFIRM once.
    public func confirm() {
        serialize { [weak self] in self?.performConfirm() }
    }

    /// The local user rejected the SAS (or the pairing in general).
    public func reject() {
        serialize { [weak self] in self?.performReject() }
    }

    /// The user left the pairing screen.
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

    private func installTransportCallbacks() {
        transport.onIncomingLink = { [weak self] (link: ProximityPairingLink) in
            self?.serialize { [weak self] in self?.handleIncomingLink(link) }
        }
        transport.onUnavailable = { [weak self] (error: ProximityPairingError) in
            self?.serialize { [weak self] in self?.fail(error) }
        }
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Session setup and frame rotation (spec §6)

    private func performStart() {
        switch state {
        case .idle, .failed, .completed:
            break
        default:
            return
        }
        // A restart during the completion grace period drops the old link now.
        releaseLinks()
        cancelAllTimers()
        wipeSecrets()
        resetHandshake()
        installTransportCallbacks()
        do {
            try generateSession()
        } catch let error as ProximityPairingError {
            fail(error)
        } catch {
            fail(.cryptoFailure("session setup"))
        }
    }

    /// Fresh sessionId, sessionSecret, ML-KEM and X25519 keys, nonce, OFFER body, commitment.
    private func generateSession() throws {
        generation &+= 1
        sessionId = try ProximityPairingCrypto.randomBytes(ProximityPairing.sessionIdBytes)
        sessionSecret = try ProximityPairingCrypto.randomBytes(ProximityPairing.sessionSecretBytes)
        let keyPair: ProximityPairingCrypto.KemKeyPair = try ProximityPairingCrypto.kemGenerateKeyPair()
        kemSecretKey = keyPair.secretKey
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        ephemeralKey = ephemeral
        displayerNonce = try ProximityPairingCrypto.randomBytes(ProximityPairing.nonceBytes)
        // Ephemeral keys only: the QR commits to them, and our identity goes
        // out later, sealed, in FINISH (spec §6, §8).
        let offer = ProximityMessage.Offer(mlKemPublicKey: keyPair.publicKey,
                                           displayerEphemeralX25519: ephemeral.publicKey.rawRepresentation,
                                           displayerNonce: displayerNonce)
        offerBody = ProximityMessage.offerBody(offer)
        commitment = ProximityPairingCrypto.commitment(sessionId: sessionId, offerBody: offerBody)
        guard commitment.count == ProximityPairing.commitmentBytes else {
            throw ProximityPairingError.cryptoFailure("commitment")
        }
        frameShownAt = [:]
        transport.startAdvertising(serviceId: sessionId)
        lifetimeTimer = schedule(.lifetime, after: ProximityPairing.sessionLifetime)
        try showFrame(0)
    }

    private func showFrame(_ index: UInt32) throws {
        var frameKey: Data = ProximityPairingCrypto.frameKey(sessionSecret: sessionSecret,
                                                             sessionId: sessionId,
                                                             frameIndex: index)
        defer { CryptoConstants.zeroize(&frameKey) }
        let payload = try ProximityQrPayload(sessionId: sessionId, commitment: commitment,
                                             frameIndex: index, frameKey: frameKey)
        let now: TimeInterval = scheduler.now()
        frameShownAt[index] = now
        pruneFrames(now: now)
        currentFrameIndex = index
        rotationTimer?.cancel()
        rotationTimer = schedule(.rotation, after: ProximityPairing.frameRotationInterval)
        setState(.showing(payload))
    }

    private func pruneFrames(now: TimeInterval) {
        let window: TimeInterval = ProximityPairing.frameAcceptanceWindow
        var stale: [UInt32] = []
        for (index, shownAt) in frameShownAt where now - shownAt > window {
            stale.append(index)
        }
        for index in stale {
            frameShownAt.removeValue(forKey: index)
        }
    }

    /// The frame after `index`, or nil when `index` is the last one a u32 can
    /// carry — the session is then replaced instead of wrapping to 0 (a
    /// wrapped index would re-issue frame keys the displayer already showed).
    nonisolated static func nextFrameIndex(after index: UInt32) -> UInt32? {
        guard index < UInt32.max else { return nil }
        return index + 1
    }

    private func rotateFrame() {
        guard case .showing = state, lockedLink == nil else { return }
        guard let next = ProximityDisplayerSession.nextFrameIndex(after: currentFrameIndex) else {
            regenerateSession()
            return
        }
        do {
            try showFrame(next)
        } catch let error as ProximityPairingError {
            fail(error)
        } catch {
            fail(.cryptoFailure("frame"))
        }
    }

    /// Lifetime expired while still showing: new keys, new sessionId, advertise again.
    private func regenerateSession() {
        guard case .showing = state, lockedLink == nil else { return }
        let expired: [ProximityPairingLink] = candidates
        candidates = []
        let abort: Data = ProximityMessage.abort(reason: ProximityPairing.AbortReason.frameExpired.rawValue).encoded()
        for link in expired {
            link.send(abort)
            detachAndClose(link)
        }
        cancelAllTimers()
        wipeSecrets()
        do {
            try generateSession()
        } catch let error as ProximityPairingError {
            fail(error)
        } catch {
            fail(.cryptoFailure("session setup"))
        }
    }

    // MARK: - Links

    private func handleIncomingLink(_ link: ProximityPairingLink) {
        switch state {
        case .showing:
            if lockedLink == nil {
                candidates.append(link)
                attach(link)
                return
            }
            rejectBusy(link)
        case .exchanging, .awaitingConfirmation, .completed:
            rejectBusy(link)
        case .idle, .failed:
            link.close()
        }
    }

    private func attach(_ link: ProximityPairingLink) {
        link.onMessage = { [weak self, weak link] (message: Data) in
            guard let source = link else { return }
            self?.serialize { [weak self] in self?.handleMessage(message, from: source) }
        }
        link.onClosed = { [weak self, weak link] (error: ProximityPairingError?) in
            guard let source = link else { return }
            self?.serialize { [weak self] in self?.handleClosed(source, error: error) }
        }
    }

    private func rejectBusy(_ link: ProximityPairingLink) {
        link.send(ProximityMessage.busy.encoded())
        link.close()
    }

    private func detachAndClose(_ link: ProximityPairingLink) {
        link.onMessage = nil
        link.onClosed = nil
        link.close()
    }

    private func isCandidate(_ link: ProximityPairingLink) -> Bool {
        return candidates.contains { (candidate: ProximityPairingLink) -> Bool in
            return candidate === link
        }
    }

    private func removeCandidate(_ link: ProximityPairingLink) {
        candidates.removeAll { (candidate: ProximityPairingLink) -> Bool in
            return candidate === link
        }
    }

    private func handleClosed(_ link: ProximityPairingLink, error: ProximityPairingError?) {
        if let locked = lockedLink, locked === link {
            lockedLink = nil
            detachAndClose(link)
            // No-op once completed: the peer closing after COMPLETE is expected.
            // A transport-reported cause (e.g. a framing violation) is kept.
            let reason: ProximityPairingError = error ?? ProximityPairingError.transportFailed("link closed")
            fail(reason, sendAbort: false)
            return
        }
        if isCandidate(link) {
            removeCandidate(link)
        }
    }

    // MARK: - Messages

    private func handleMessage(_ raw: Data, from link: ProximityPairingLink) {
        if let locked = lockedLink, locked === link {
            handleLockedMessage(Data(raw))
            return
        }
        guard lockedLink == nil, isCandidate(link), case .showing = state else {
            return
        }
        handleCandidateMessage(Data(raw), from: link)
    }

    /// Before locking: only a valid HELLO wins; anything else costs the sender its link,
    /// never the session (spec §9).
    private func handleCandidateMessage(_ message: Data, from link: ProximityPairingLink) {
        let decoded: ProximityMessage
        do {
            decoded = try ProximityMessage.decode(message)
        } catch {
            dismissCandidate(link, reason: .protocolViolation)
            return
        }
        switch decoded {
        case .hello(let hello):
            guard let shownAt = frameShownAt[hello.frameIndex],
                  scheduler.now() - shownAt <= ProximityPairing.frameAcceptanceWindow else {
                dismissCandidate(link, reason: .frameExpired)
                return
            }
            var frameKey: Data = ProximityPairingCrypto.frameKey(sessionSecret: sessionSecret,
                                                                 sessionId: sessionId,
                                                                 frameIndex: hello.frameIndex)
            defer { CryptoConstants.zeroize(&frameKey) }
            let expectedTag: Data = ProximityPairingCrypto.helloTag(frameKey: frameKey,
                                                                    sessionId: sessionId,
                                                                    frameIndex: hello.frameIndex,
                                                                    scannerEphemeralX25519: hello.scannerEphemeralX25519,
                                                                    scannerNonce: hello.scannerNonce)
            guard ProximityPairingCrypto.constantTimeEquals(expectedTag, hello.tag) else {
                dismissCandidate(link, reason: .authenticationFailed)
                return
            }
            let helloBytes: Data = Data(message.subdata(in: (message.startIndex + 1)..<message.endIndex))
            lock(to: link, hello: hello, helloBytes: helloBytes, frameKey: frameKey)
        case .abort:
            removeCandidate(link)
            detachAndClose(link)
        default:
            dismissCandidate(link, reason: .protocolViolation)
        }
    }

    private func dismissCandidate(_ link: ProximityPairingLink, reason: ProximityPairing.AbortReason) {
        removeCandidate(link)
        link.send(ProximityMessage.abort(reason: reason.rawValue).encoded())
        detachAndClose(link)
    }

    private func lock(to link: ProximityPairingLink, hello: ProximityMessage.Hello,
                      helloBytes: Data, frameKey: Data) {
        let payload: ProximityQrPayload
        do {
            payload = try ProximityQrPayload(sessionId: sessionId, commitment: commitment,
                                             frameIndex: hello.frameIndex, frameKey: frameKey)
        } catch {
            dismissCandidate(link, reason: .internalError)
            return
        }
        lockedLink = link
        removeCandidate(link)
        let others: [ProximityPairingLink] = candidates
        candidates = []
        for other in others {
            other.onMessage = nil
            other.onClosed = nil
            rejectBusy(other)
        }
        rotationTimer?.cancel()
        rotationTimer = nil
        lifetimeTimer?.cancel()
        lifetimeTimer = nil
        transport.stopAdvertising()

        qrBytes = payload.encodedBytes
        helloBody = helloBytes
        scannerEphemeral = hello.scannerEphemeralX25519
        scannerNonce = hello.scannerNonce
        // Frame keys are no longer needed once the session is locked.
        CryptoConstants.zeroize(&sessionSecret)
        sessionSecret = Data()
        frameShownAt = [:]

        handshakeTimer = schedule(.handshake, after: ProximityPairing.handshakeTimeout)
        var offerMessage = Data()
        offerMessage.append(ProximityPairing.MessageType.offer.rawValue)
        offerMessage.append(offerBody)
        link.send(offerMessage)
        setState(.exchanging)
    }

    private func handleLockedMessage(_ message: Data) {
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
        case .accept(let accept):
            guard case .exchanging = state, handshakeKeys == nil, keys == nil else {
                fail(.protocolViolation("unexpected ACCEPT"))
                return
            }
            handleAccept(accept)
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

    private func handleAccept(_ accept: ProximityMessage.Accept) {
        do {
            let finish: ProximityMessage.Finish = try processAccept(accept)
            guard let peerIdentity = peer else {
                throw ProximityPairingError.cryptoFailure("FINISH")
            }
            lockedLink?.send(ProximityMessage.finish(finish).encoded())
            handshakeTimer?.cancel()
            handshakeTimer = nil
            confirmationTimer = schedule(.confirmation, after: ProximityPairing.userConfirmationTimeout)
            setState(.awaitingConfirmation(sas: sas, peer: peerIdentity, warning: warning, localConfirmed: false))
        } catch let error as ProximityPairingError {
            fail(error)
        } catch {
            fail(.cryptoFailure("ACCEPT"))
        }
    }

    /// Spec §9, displayer on ACCEPT: decapsulate, X25519, TH1, stage-1 keys;
    /// open sealed_S and verify the scanner's identity; self check and
    /// identity policy; seal our own identity into FINISH; stage 2 and SAS.
    /// On success stores keys / peer / warning / SAS and returns FINISH; every
    /// stage-1 value is zeroized by then.
    private func processAccept(_ accept: ProximityMessage.Accept) throws -> ProximityMessage.Finish {
        var th1: Data = try deriveHandshake(accept)
        defer { CryptoConstants.zeroize(&th1) }
        let opened: ProximityMessage.SealedIdentity = try openScannerIdentity(accept.sealed, transcriptHash: th1)
        var thS: Data = ProximityPairingCrypto.identityTranscriptHash(role: .scanner, previousHash: th1,
                                                                      idBlock: opened.idBlock)
        defer { CryptoConstants.zeroize(&thS) }
        try verifyScannerProof(opened, scannerTranscriptHash: thS)
        let decidedWarning: String? = try evaluatePeer(opened.identity)

        let idBlock: Data = ProximityMessage.idBlock(identity.publicIdentity)
        var thD: Data = ProximityPairingCrypto.identityTranscriptHash(role: .displayer, previousHash: thS,
                                                                      idBlock: idBlock)
        defer { CryptoConstants.zeroize(&thD) }
        let sealed: Data = try sealDisplayerIdentity(idBlock: idBlock, scannerTranscriptHash: thS,
                                                     displayerTranscriptHash: thD)
        try deriveFinalKeys(displayerTranscriptHash: thD)
        let finalSas: String = keys?.sas ?? ""
        guard finalSas.count == ProximityPairing.sasDigits else {
            throw ProximityPairingError.cryptoFailure("SAS")
        }
        sas = finalSas
        warning = decidedWarning
        peer = opened.identity
        return ProximityMessage.Finish(sealed: sealed)
    }

    /// Decapsulates, runs X25519, computes TH1 and the stage-1 keys. The ML-KEM
    /// secret key and the X25519 private key are single-use and dropped here.
    /// Returns TH1.
    private func deriveHandshake(_ accept: ProximityMessage.Accept) throws -> Data {
        guard let ephemeral = ephemeralKey else {
            throw ProximityPairingError.cryptoFailure("ephemeral key")
        }
        var kemSecret: Data = try ProximityPairingCrypto.kemDecapsulate(ciphertext: accept.mlKemCiphertext,
                                                                        secretKey: kemSecretKey)
        defer { CryptoConstants.zeroize(&kemSecret) }
        CryptoConstants.zeroize(&kemSecretKey)
        kemSecretKey = Data()
        ephemeralKey = nil
        var x25519Secret: Data = try ProximityPairingCrypto.x25519SharedSecret(privateKey: ephemeral,
                                                                               peerPublicKey: scannerEphemeral)
        defer { CryptoConstants.zeroize(&x25519Secret) }

        let th1: Data = ProximityPairingCrypto.transcriptHash(qrBytes: qrBytes, helloBody: helloBody,
                                                              offerBody: offerBody,
                                                              mlKemCiphertext: accept.mlKemCiphertext)
        CryptoConstants.zeroize(&qrBytes)
        qrBytes = Data()
        handshakeKeys = try ProximityPairingCrypto.deriveHandshakeKeys(transcriptHash: th1,
                                                                      kemSharedSecret: kemSecret,
                                                                      x25519SharedSecret: x25519Secret,
                                                                      scannerNonce: scannerNonce,
                                                                      displayerNonce: displayerNonce)
        return th1
    }

    /// Opens sealed_S (K_enc_S, aad TH1) — a tag failure is an authentication
    /// failure — and parses its plaintext strictly (exactly 66 + n + 96 bytes).
    private func openScannerIdentity(_ sealed: Data, transcriptHash th1: Data) throws -> ProximityMessage.SealedIdentity {
        let plaintext: Data = try ProximityPairingCrypto.aeadOpen(sealed,
                                                                  key: handshakeKeys?.encKeyScanner ?? Data(),
                                                                  transcriptHash: th1)
        return try ProximityMessage.decodeSealedPlaintext(plaintext)
    }

    /// mac_S = HMAC(K_mac_S, TH_S) (constant time), then sig_S over
    /// `L_SIG_S ‖ TH_S` under the idPub_S the box carried.
    private func verifyScannerProof(_ opened: ProximityMessage.SealedIdentity, scannerTranscriptHash thS: Data) throws {
        guard thS.count == ProximityPairing.transcriptHashBytes else {
            throw ProximityPairingError.cryptoFailure("TH_S")
        }
        let expectedMac: Data = ProximityPairingCrypto.transcriptMac(key: handshakeKeys?.macKeyScanner ?? Data(),
                                                                     transcriptHash: thS)
        guard ProximityPairingCrypto.constantTimeEquals(expectedMac, opened.mac) else {
            throw ProximityPairingError.authenticationFailed("ACCEPT mac")
        }
        let sigPayload: Data = ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: thS)
        guard ProximityPairingCrypto.verify(signature: opened.signature, payload: sigPayload,
                                            signingPublicKey: opened.identity.signingPublicKey) else {
            throw ProximityPairingError.authenticationFailed("ACCEPT signature")
        }
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

    /// `sealed_D = Seal(K_enc_D, aad = TH_S, idBlock_D ‖ sig_D ‖ mac_D)` with
    /// sig_D over `L_SIG_D ‖ TH_D` and mac_D = HMAC(K_mac_D, TH_D).
    private func sealDisplayerIdentity(idBlock: Data, scannerTranscriptHash thS: Data,
                                       displayerTranscriptHash thD: Data) throws -> Data {
        guard thD.count == ProximityPairing.transcriptHashBytes else {
            throw ProximityPairingError.cryptoFailure("TH_D")
        }
        let sigPayload: Data = ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: thD)
        let signature: Data = try ProximityPairingCrypto.sign(sigPayload, signingPrivateKey: identity.signingPrivateKey)
        let mac: Data = ProximityPairingCrypto.transcriptMac(key: handshakeKeys?.macKeyDisplayer ?? Data(),
                                                             transcriptHash: thD)
        guard mac.count == ProximityPairing.macBytes else {
            throw ProximityPairingError.cryptoFailure("FINISH mac")
        }
        let plaintext: Data = ProximityMessage.sealedPlaintext(idBlock: idBlock, signature: signature, mac: mac)
        return try ProximityPairingCrypto.aeadSeal(plaintext, key: handshakeKeys?.encKeyDisplayer ?? Data(),
                                                   transcriptHash: thS)
    }

    /// Stage 2 (PRK2 from TH_D and PRK1), then scrub every stage-1 key.
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
    }

    // MARK: - Confirmation (spec §9)

    private func performConfirm() {
        guard case .awaitingConfirmation = state, !localConfirmed, let link = lockedLink,
              let peerIdentity = peer else { return }
        let confirmKey: Data = keys?.confirmKeyDisplayer ?? Data()
        let mac: Data = ProximityPairingCrypto.confirmationMac(key: confirmKey)
        guard mac.count == ProximityPairing.macBytes else {
            fail(.cryptoFailure("CONFIRM"))
            return
        }
        link.send(ProximityMessage.confirm(mac: mac).encoded())
        localConfirmed = true
        if peerConfirmed {
            complete()
            return
        }
        setState(.awaitingConfirmation(sas: sas, peer: peerIdentity, warning: warning, localConfirmed: true))
    }

    private func handlePeerConfirm(_ mac: Data) {
        let peerKey: Data = keys?.confirmKeyScanner ?? Data()
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
        let result = ProximityPairingResult(role: .displayer, peer: peerIdentity, psk: psk,
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
            releaseLinks()
            transport.shutdown()
        case .idle, .failed:
            transport.shutdown()
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
        case .rotation:
            rotateFrame()
        case .lifetime:
            regenerateSession()
        case .handshake:
            guard case .exchanging = state else { return }
            fail(.timeout("handshake"))
        case .confirmation:
            guard case .awaitingConfirmation = state else { return }
            fail(.timeout("confirmation"))
        case .completionGrace:
            guard case .completed = state else { return }
            graceTimer = nil
            releaseLinks()
            transport.shutdown()
        }
    }

    private func cancelAllTimers() {
        rotationTimer?.cancel()
        lifetimeTimer?.cancel()
        handshakeTimer?.cancel()
        confirmationTimer?.cancel()
        graceTimer?.cancel()
        rotationTimer = nil
        lifetimeTimer = nil
        handshakeTimer = nil
        confirmationTimer = nil
        graceTimer = nil
    }

    // MARK: - Teardown

    /// Idempotent; never overrides `.completed`. Sends ABORT on the locked link
    /// for local failures, closes every link, shuts the transport down, cancels
    /// every timer and zeroizes every secret.
    private func fail(_ error: ProximityPairingError, sendAbort: Bool = true) {
        switch state {
        case .completed, .failed:
            return
        default:
            break
        }
        if sendAbort, let link = lockedLink {
            link.send(ProximityMessage.abort(reason: error.abortReason.rawValue).encoded())
        }
        generation &+= 1
        releaseLinks()
        transport.shutdown()
        cancelAllTimers()
        wipeSecrets()
        resetHandshake()
        setState(.failed(error))
    }

    private func releaseLinks() {
        let all: [ProximityPairingLink] = candidates
        candidates = []
        for link in all {
            detachAndClose(link)
        }
        if let link = lockedLink {
            lockedLink = nil
            detachAndClose(link)
        }
    }

    private func wipeSecrets() {
        CryptoConstants.zeroize(&sessionSecret)
        CryptoConstants.zeroize(&kemSecretKey)
        CryptoConstants.zeroize(&qrBytes)
        keys?.zeroize()
        keys = nil
        handshakeKeys?.zeroize()
        handshakeKeys = nil
        ephemeralKey = nil
        sessionSecret = Data()
        kemSecretKey = Data()
        qrBytes = Data()
        frameShownAt = [:]
    }

    private func resetHandshake() {
        helloBody = Data()
        scannerEphemeral = Data()
        scannerNonce = Data()
        peer = nil
        warning = nil
        sas = ""
        localConfirmed = false
        peerConfirmed = false
    }
}
