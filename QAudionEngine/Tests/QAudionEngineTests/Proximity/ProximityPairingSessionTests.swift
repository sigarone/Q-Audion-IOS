import XCTest
import CryptoKit
@testable import QAudionEngine

// End-to-end tests of ProximityDisplayerSession + ProximityScannerSession over
// the in-memory doubles (ProximityTestDoubles.swift), with real ML-KEM-1024,
// X25519 and Ed25519. Spec §6, §9–§12.

// MARK: - Pure byte helpers (nonisolated: used inside transport filters)

private func proxSessionFlip(_ data: Data, at offset: Int) -> Data {
    var copy: Data = Data(data)
    let index: Int = copy.startIndex + offset
    copy[index] ^= 0x01
    return copy
}

private func proxSessionReplace(_ data: Data, at offset: Int, with bytes: Data) -> Data {
    var copy: Data = Data(data)
    let start: Int = copy.startIndex + offset
    copy.replaceSubrange(start..<(start + bytes.count), with: bytes)
    return copy
}

/// Applies `transform` to messages of `type` only.
private func proxSessionTamper(type: UInt8, _ transform: @escaping (Data) -> Data) -> (Data) -> Data? {
    return { (message: Data) -> Data? in
        guard message.first == type else { return message }
        return transform(message)
    }
}

/// Drops every message of `type`.
private func proxSessionDrop(type: UInt8) -> (Data) -> Data? {
    return { (message: Data) -> Data? in
        if message.first == type { return nil }
        return message
    }
}

private func proxSessionKind(_ error: ProximityPairingError?) -> String {
    guard let error = error else { return "none" }
    switch error {
    case .bluetoothUnavailable: return "bluetoothUnavailable"
    case .identityUnavailable: return "identityUnavailable"
    case .invalidQrCode: return "invalidQrCode"
    case .expiredQrCode: return "expiredQrCode"
    case .timeout: return "timeout"
    case .transportFailed: return "transportFailed"
    case .protocolViolation: return "protocolViolation"
    case .authenticationFailed: return "authenticationFailed"
    case .identityRejected: return "identityRejected"
    case .sessionBusy: return "sessionBusy"
    case .peerAborted: return "peerAborted"
    case .userRejected: return "userRejected"
    case .cancelled: return "cancelled"
    case .cryptoFailure: return "cryptoFailure"
    }
}

/// A local timeout, or the peer's ABORT(timeout) when its timer fired first.
private func proxSessionIsTimeout(_ error: ProximityPairingError?) -> Bool {
    guard let error = error else { return false }
    if case .timeout = error { return true }
    return error == .peerAborted(ProximityPairing.AbortReason.timeout.rawValue)
}

private struct ProxSessionAwaiting {
    let sas: String
    let peer: ProximityPeerIdentity
    let warning: String?
    let localConfirmed: Bool
}

// MARK: - Rig

@MainActor
private final class ProximitySessionRig {

    final class PolicyBox {
        var decision: ProximityIdentityDecision = .accept
        var seen: [ProximityPeerIdentity] = []
    }

    let hub: ProximityTestHub
    let scheduler: ProximityManualScheduler
    let displayerTransport: ProximityFakeDisplayerTransport
    let displayerIdentity: ProximityLocalIdentity
    let scannerIdentity: ProximityLocalIdentity
    let displayerPolicy: PolicyBox
    let scannerPolicy: PolicyBox
    let displayer: ProximityDisplayerSession
    var displayerStates: [ProximityDisplayerSession.State] = []

    init(displayerIdentity: ProximityLocalIdentity, scannerIdentity: ProximityLocalIdentity) {
        let hub = ProximityTestHub()
        let scheduler = ProximityManualScheduler()
        let transport = ProximityFakeDisplayerTransport(hub: hub)
        let box = PolicyBox()
        self.hub = hub
        self.scheduler = scheduler
        self.displayerTransport = transport
        self.displayerIdentity = displayerIdentity
        self.scannerIdentity = scannerIdentity
        self.displayerPolicy = box
        self.scannerPolicy = PolicyBox()
        self.displayer = ProximityDisplayerSession(
            identity: displayerIdentity, transport: transport, scheduler: scheduler,
            identityPolicy: { (peer: ProximityPeerIdentity) -> ProximityIdentityDecision in
                box.seen.append(peer)
                return box.decision
            })
        displayer.onStateChange = { [weak self] (state: ProximityDisplayerSession.State) in
            self?.displayerStates.append(state)
        }
    }

    func makeScanner(payload: ProximityQrPayload,
                     identity: ProximityLocalIdentity? = nil) -> (ProximityScannerSession, ProximityFakeScannerTransport) {
        let transport = ProximityFakeScannerTransport(hub: hub, target: displayerTransport)
        let box: PolicyBox = scannerPolicy
        let local: ProximityLocalIdentity = identity ?? scannerIdentity
        let session = ProximityScannerSession(
            payload: payload, identity: local, transport: transport, scheduler: scheduler,
            identityPolicy: { (peer: ProximityPeerIdentity) -> ProximityIdentityDecision in
                box.seen.append(peer)
                return box.decision
            })
        return (session, transport)
    }
}

// MARK: - Scripted peers
//
// A real peer never sends a sealed box that opens but whose contents are
// wrong (bad MAC, foreign signature, own identity, malformed plaintext), so
// the checks after the AEAD are reached only by a hand-driven peer built from
// the same primitives. Each scripted peer also has a positive control test,
// so a failure in the negative tests cannot come from a broken script.

/// Plays the displayer against a real `ProximityScannerSession`: answers
/// HELLO with a real OFFER, recovers the stage-1 keys from the ACCEPT, then
/// sends whatever FINISH a test builds.
private final class ProxScriptedDisplayer {

    enum FinishFault {
        case valid
        case trailingPlaintextByte
        case macUnderScannerKey
        case sealedUnderTh1
    }

    let transport: ProximityFakeDisplayerTransport
    let payload: ProximityQrPayload
    private let kem: ProximityPairingCrypto.KemKeyPair
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let nonce: Data
    private let offerBody: Data

    private(set) var link: ProximityFakeLink?
    private(set) var received: [Data] = []
    private(set) var handshakeKeys: ProximityPairingCrypto.HandshakeKeys?
    private(set) var th1: Data = Data()
    private(set) var scannerTranscriptHash: Data = Data()
    private(set) var sealedScanner: Data = Data()
    private(set) var scannerIdentity: ProximityPeerIdentity?

    init(hub: ProximityTestHub) throws {
        let sessionId: Data = try ProximityPairingCrypto.randomBytes(ProximityPairing.sessionIdBytes)
        let secret: Data = try ProximityPairingCrypto.randomBytes(ProximityPairing.sessionSecretBytes)
        let kemPair: ProximityPairingCrypto.KemKeyPair = try ProximityPairingCrypto.kemGenerateKeyPair()
        let xKey = Curve25519.KeyAgreement.PrivateKey()
        let nonceD: Data = try ProximityPairingCrypto.randomBytes(ProximityPairing.nonceBytes)
        let offer = ProximityMessage.Offer(mlKemPublicKey: kemPair.publicKey,
                                           displayerEphemeralX25519: xKey.publicKey.rawRepresentation,
                                           displayerNonce: nonceD)
        let body: Data = ProximityMessage.offerBody(offer)
        let commitment: Data = ProximityPairingCrypto.commitment(sessionId: sessionId, offerBody: body)
        let frameKey: Data = ProximityPairingCrypto.frameKey(sessionSecret: secret, sessionId: sessionId,
                                                             frameIndex: 0)
        self.payload = try ProximityQrPayload(sessionId: sessionId, commitment: commitment,
                                              frameIndex: 0, frameKey: frameKey)
        self.kem = kemPair
        self.ephemeral = xKey
        self.nonce = nonceD
        self.offerBody = body
        self.transport = ProximityFakeDisplayerTransport(hub: hub)
        transport.startAdvertising(serviceId: sessionId)
        transport.onIncomingLink = { [weak self] (incoming: ProximityPairingLink) in
            guard let end = incoming as? ProximityFakeLink else { return }
            self?.attach(end)
        }
    }

    private func attach(_ end: ProximityFakeLink) {
        link = end
        end.onMessage = { [weak self] (message: Data) in
            self?.received.append(Data(message))
        }
    }

    func sendOffer() {
        var message = Data([ProximityPairing.MessageType.offer.rawValue])
        message.append(offerBody)
        link?.send(message)
    }

    func send(_ message: Data) {
        link?.send(message)
    }

    /// Decapsulates the scanner's ACCEPT and opens sealed_S, as the real displayer does.
    func absorbAccept() throws {
        guard received.count >= 2 else {
            throw ProximityPairingError.protocolViolation("no ACCEPT yet")
        }
        let decodedHello: ProximityMessage = try ProximityMessage.decode(received[0])
        let decodedAccept: ProximityMessage = try ProximityMessage.decode(received[1])
        guard case .hello(let hello) = decodedHello, case .accept(let accept) = decodedAccept else {
            throw ProximityPairingError.protocolViolation("expected HELLO then ACCEPT")
        }
        let kemSecret: Data = try ProximityPairingCrypto.kemDecapsulate(ciphertext: accept.mlKemCiphertext,
                                                                        secretKey: kem.secretKey)
        let xSecret: Data = try ProximityPairingCrypto.x25519SharedSecret(privateKey: ephemeral,
                                                                          peerPublicKey: hello.scannerEphemeralX25519)
        let transcript: Data = ProximityPairingCrypto.transcriptHash(qrBytes: payload.encodedBytes,
                                                                    helloBody: ProximityMessage.helloBody(hello),
                                                                    offerBody: offerBody,
                                                                    mlKemCiphertext: accept.mlKemCiphertext)
        let keys: ProximityPairingCrypto.HandshakeKeys = try ProximityPairingCrypto.deriveHandshakeKeys(
            transcriptHash: transcript, kemSharedSecret: kemSecret, x25519SharedSecret: xSecret,
            scannerNonce: hello.scannerNonce, displayerNonce: nonce)
        let plaintext: Data = try ProximityPairingCrypto.aeadOpen(accept.sealed, key: keys.encKeyScanner,
                                                                  transcriptHash: transcript)
        let opened: ProximityMessage.SealedIdentity = try ProximityMessage.decodeSealedPlaintext(plaintext)
        th1 = transcript
        handshakeKeys = keys
        scannerTranscriptHash = ProximityPairingCrypto.identityTranscriptHash(role: .scanner,
                                                                             previousHash: transcript,
                                                                             idBlock: opened.idBlock)
        sealedScanner = accept.sealed
        scannerIdentity = opened.identity
    }

    /// A FINISH presenting `identity`, signed with `signingPrivateKey`, with an
    /// optional deliberate fault. Returns the message and the TH_D it signed.
    func finish(identity: ProximityPeerIdentity, signingPrivateKey: Data,
                fault: FinishFault = .valid) throws -> (message: Data, displayerTranscriptHash: Data) {
        guard let keys = handshakeKeys else {
            throw ProximityPairingError.protocolViolation("no stage-1 keys")
        }
        let idBlock: Data = ProximityMessage.idBlock(identity)
        let thD: Data = ProximityPairingCrypto.identityTranscriptHash(role: .displayer,
                                                                     previousHash: scannerTranscriptHash,
                                                                     idBlock: idBlock)
        let sigPayload: Data = ProximityPairingCrypto.signaturePayload(role: .displayer, transcriptHash: thD)
        let signature: Data = try ProximityPairingCrypto.sign(sigPayload, signingPrivateKey: signingPrivateKey)
        let macKey: Data = fault == .macUnderScannerKey ? keys.macKeyScanner : keys.macKeyDisplayer
        let mac: Data = ProximityPairingCrypto.transcriptMac(key: macKey, transcriptHash: thD)
        var plaintext: Data = ProximityMessage.sealedPlaintext(idBlock: idBlock, signature: signature, mac: mac)
        if fault == .trailingPlaintextByte {
            plaintext.append(0x00)
        }
        let aad: Data = fault == .sealedUnderTh1 ? th1 : scannerTranscriptHash
        let sealed: Data = try ProximityPairingCrypto.aeadSeal(plaintext, key: keys.encKeyDisplayer,
                                                              transcriptHash: aad)
        let message: Data = ProximityMessage.finish(ProximityMessage.Finish(sealed: sealed)).encoded()
        return (message: message, displayerTranscriptHash: thD)
    }

    /// The SAS the real displayer would show for a FINISH built over `thD`.
    func sas(displayerTranscriptHash thD: Data) throws -> String {
        guard let keys = handshakeKeys else {
            throw ProximityPairingError.protocolViolation("no stage-1 keys")
        }
        let finalKeys: ProximityPairingCrypto.SessionKeys = try ProximityPairingCrypto.deriveSessionKeys(
            handshakeKeys: keys, displayerTranscriptHash: thD)
        return finalKeys.sas
    }
}

/// Plays the scanner against a real `ProximityDisplayerSession`: connects as
/// a central, sends a valid HELLO for the QR it was given, then whatever
/// ACCEPT a test builds.
private final class ProxScriptedScanner {

    enum AcceptFault {
        case valid
        case trailingPlaintextByte
        case macUnderDisplayerKey
        case sealedUnderDisplayerKey
    }

    let link: ProximityFakeLink
    private let payload: ProximityQrPayload
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonce: Data
    private var helloBody: Data = Data()

    private(set) var received: [Data] = []
    private(set) var handshakeKeys: ProximityPairingCrypto.HandshakeKeys?
    private(set) var scannerTranscriptHash: Data = Data()

    init(transport: ProximityFakeDisplayerTransport, payload: ProximityQrPayload) throws {
        self.payload = payload
        self.nonce = try ProximityPairingCrypto.randomBytes(ProximityPairing.nonceBytes)
        self.link = transport.connectCentral()
        link.onMessage = { [weak self] (message: Data) in
            self?.received.append(Data(message))
        }
    }

    func sendHello() {
        let xpk: Data = ephemeral.publicKey.rawRepresentation
        let tag: Data = ProximityPairingCrypto.helloTag(frameKey: payload.frameKey, sessionId: payload.sessionId,
                                                        frameIndex: payload.frameIndex,
                                                        scannerEphemeralX25519: xpk, scannerNonce: nonce)
        let hello = ProximityMessage.Hello(frameIndex: payload.frameIndex, scannerEphemeralX25519: xpk,
                                           scannerNonce: nonce, tag: tag)
        helloBody = ProximityMessage.helloBody(hello)
        link.send(ProximityMessage.hello(hello).encoded())
    }

    /// Answers the OFFER with an ACCEPT presenting `identity`, signed with
    /// `signingPrivateKey`, with an optional deliberate fault.
    func sendAccept(identity: ProximityPeerIdentity, signingPrivateKey: Data,
                    fault: AcceptFault = .valid) throws {
        guard let offerMessage = received.first else {
            throw ProximityPairingError.protocolViolation("no OFFER yet")
        }
        let decoded: ProximityMessage = try ProximityMessage.decode(offerMessage)
        guard case .offer(let offer) = decoded else {
            throw ProximityPairingError.protocolViolation("expected OFFER")
        }
        let encapsulated: (ciphertext: Data, sharedSecret: Data) =
            try ProximityPairingCrypto.kemEncapsulate(publicKey: offer.mlKemPublicKey)
        let xSecret: Data = try ProximityPairingCrypto.x25519SharedSecret(privateKey: ephemeral,
                                                                          peerPublicKey: offer.displayerEphemeralX25519)
        let transcript: Data = ProximityPairingCrypto.transcriptHash(qrBytes: payload.encodedBytes,
                                                                    helloBody: helloBody,
                                                                    offerBody: ProximityMessage.offerBody(offer),
                                                                    mlKemCiphertext: encapsulated.ciphertext)
        let keys: ProximityPairingCrypto.HandshakeKeys = try ProximityPairingCrypto.deriveHandshakeKeys(
            transcriptHash: transcript, kemSharedSecret: encapsulated.sharedSecret, x25519SharedSecret: xSecret,
            scannerNonce: nonce, displayerNonce: offer.displayerNonce)
        let idBlock: Data = ProximityMessage.idBlock(identity)
        let thS: Data = ProximityPairingCrypto.identityTranscriptHash(role: .scanner, previousHash: transcript,
                                                                     idBlock: idBlock)
        let sigPayload: Data = ProximityPairingCrypto.signaturePayload(role: .scanner, transcriptHash: thS)
        let signature: Data = try ProximityPairingCrypto.sign(sigPayload, signingPrivateKey: signingPrivateKey)
        let macKey: Data = fault == .macUnderDisplayerKey ? keys.macKeyDisplayer : keys.macKeyScanner
        let mac: Data = ProximityPairingCrypto.transcriptMac(key: macKey, transcriptHash: thS)
        var plaintext: Data = ProximityMessage.sealedPlaintext(idBlock: idBlock, signature: signature, mac: mac)
        if fault == .trailingPlaintextByte {
            plaintext.append(0x00)
        }
        let encKey: Data = fault == .sealedUnderDisplayerKey ? keys.encKeyDisplayer : keys.encKeyScanner
        let sealed: Data = try ProximityPairingCrypto.aeadSeal(plaintext, key: encKey, transcriptHash: transcript)
        handshakeKeys = keys
        scannerTranscriptHash = thS
        let accept = ProximityMessage.Accept(mlKemCiphertext: encapsulated.ciphertext, sealed: sealed)
        link.send(ProximityMessage.accept(accept).encoded())
    }

    /// Opens the displayer's FINISH the way the real scanner does.
    func openFinish() throws -> ProximityMessage.SealedIdentity {
        guard let keys = handshakeKeys, received.count >= 2 else {
            throw ProximityPairingError.protocolViolation("no FINISH yet")
        }
        let decoded: ProximityMessage = try ProximityMessage.decode(received[1])
        guard case .finish(let finish) = decoded else {
            throw ProximityPairingError.protocolViolation("expected FINISH")
        }
        let plaintext: Data = try ProximityPairingCrypto.aeadOpen(finish.sealed, key: keys.encKeyDisplayer,
                                                                  transcriptHash: scannerTranscriptHash)
        return try ProximityMessage.decodeSealedPlaintext(plaintext)
    }
}

/// A real scanner session driven against `ProxScriptedDisplayer`, stopped
/// right after its ACCEPT was absorbed.
private struct ProxScriptedRun {
    let hub: ProximityTestHub
    let displayer: ProxScriptedDisplayer
    let scanner: ProximityScannerSession
    let scannerIdentity: ProximityLocalIdentity
    let policy: ProximitySessionRig.PolicyBox
}

// MARK: - Tests

@MainActor
final class ProximityPairingSessionTests: XCTestCase {

    // MARK: Helpers

    private func makeRig(displayer: ProximityLocalIdentity? = nil,
                         scanner: ProximityLocalIdentity? = nil) throws -> ProximitySessionRig {
        let displayerIdentity: ProximityLocalIdentity
        if let given = displayer {
            displayerIdentity = given
        } else {
            displayerIdentity = try ProximityTestIdentities.make(userId: "displayer-user")
        }
        let scannerIdentity: ProximityLocalIdentity
        if let given = scanner {
            scannerIdentity = given
        } else {
            scannerIdentity = try ProximityTestIdentities.make(userId: "scanner-user")
        }
        return ProximitySessionRig(displayerIdentity: displayerIdentity, scannerIdentity: scannerIdentity)
    }

    private func showingPayload(_ rig: ProximitySessionRig,
                                file: StaticString = #filePath, line: UInt = #line) throws -> ProximityQrPayload {
        guard case .showing(let payload) = rig.displayer.state else {
            XCTFail("displayer is not showing a QR", file: file, line: line)
            throw ProximityPairingError.protocolViolation("not showing")
        }
        return payload
    }

    /// start → scan → pump: both sides end in `.awaitingConfirmation` unless tampered.
    private func runHandshake(_ rig: ProximitySessionRig) throws -> (ProximityScannerSession, ProximityFakeScannerTransport) {
        rig.displayer.start()
        let payload: ProximityQrPayload = try showingPayload(rig)
        let pair: (ProximityScannerSession, ProximityFakeScannerTransport) = rig.makeScanner(payload: payload)
        pair.0.start()
        rig.hub.pump()
        return pair
    }

    private func displayerAwaiting(_ state: ProximityDisplayerSession.State) -> ProxSessionAwaiting? {
        if case .awaitingConfirmation(sas: let sas, peer: let peer, warning: let warning,
                                      localConfirmed: let local) = state {
            return ProxSessionAwaiting(sas: sas, peer: peer, warning: warning, localConfirmed: local)
        }
        return nil
    }

    private func scannerAwaiting(_ state: ProximityScannerSession.State) -> ProxSessionAwaiting? {
        if case .awaitingConfirmation(sas: let sas, peer: let peer, warning: let warning,
                                      localConfirmed: let local) = state {
            return ProxSessionAwaiting(sas: sas, peer: peer, warning: warning, localConfirmed: local)
        }
        return nil
    }

    private func displayerResult(_ state: ProximityDisplayerSession.State) -> ProximityPairingResult? {
        if case .completed(let result) = state { return result }
        return nil
    }

    private func scannerResult(_ state: ProximityScannerSession.State) -> ProximityPairingResult? {
        if case .completed(let result) = state { return result }
        return nil
    }

    private func displayerError(_ state: ProximityDisplayerSession.State) -> ProximityPairingError? {
        if case .failed(let error) = state { return error }
        return nil
    }

    private func scannerError(_ state: ProximityScannerSession.State) -> ProximityPairingError? {
        if case .failed(let error) = state { return error }
        return nil
    }

    private func isShowing(_ state: ProximityDisplayerSession.State) -> Bool {
        if case .showing = state { return true }
        return false
    }

    private func assertNeitherCompleted(_ rig: ProximitySessionRig, _ scanner: ProximityScannerSession,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(displayerResult(rig.displayer.state), file: file, line: line)
        XCTAssertNil(scannerResult(scanner.state), file: file, line: line)
    }

    private func hexDigest(_ data: Data) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var hex: String = ""
        for byte in SHA256.hash(data: data) {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        return hex
    }

    /// Runs a pairing with the given filters and optional confirmations.
    private func runTampered(toDisplayer: ((Data) -> Data?)? = nil,
                             toScanner: ((Data) -> Data?)? = nil,
                             confirmDisplayer: Bool = false,
                             confirmScanner: Bool = false) throws -> (ProximitySessionRig, ProximityScannerSession) {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayerTransport.toDisplayerFilter = toDisplayer
        rig.displayerTransport.toScannerFilter = toScanner
        let pair: (ProximityScannerSession, ProximityFakeScannerTransport) = try runHandshake(rig)
        if confirmDisplayer { rig.displayer.confirm() }
        if confirmScanner { pair.0.confirm() }
        rig.hub.pump()
        return (rig, pair.0)
    }

    // MARK: Happy path

    func testHappyPathBothComplete() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, scannerTransport) = try runHandshake(rig)

        let dWait: ProxSessionAwaiting = try XCTUnwrap(displayerAwaiting(rig.displayer.state))
        let sWait: ProxSessionAwaiting = try XCTUnwrap(scannerAwaiting(scanner.state))
        XCTAssertEqual(dWait.sas, sWait.sas)
        XCTAssertEqual(dWait.sas.count, ProximityPairing.sasDigits)
        XCTAssertEqual(dWait.peer, rig.scannerIdentity.publicIdentity)
        XCTAssertEqual(sWait.peer, rig.displayerIdentity.publicIdentity)
        XCTAssertNil(dWait.warning)
        XCTAssertNil(sWait.warning)
        XCTAssertFalse(dWait.localConfirmed)
        XCTAssertFalse(sWait.localConfirmed)
        XCTAssertEqual(rig.displayerTransport.stopAdvertisingCount, 1)
        XCTAssertEqual(scannerTransport.connectCalls.count, 1)
        XCTAssertEqual(scannerTransport.connectTimeouts.first, ProximityPairing.scannerConnectTimeout)

        rig.displayer.confirm()
        scanner.confirm()
        rig.hub.pump()

        let dResult: ProximityPairingResult = try XCTUnwrap(displayerResult(rig.displayer.state))
        let sResult: ProximityPairingResult = try XCTUnwrap(scannerResult(scanner.state))
        XCTAssertEqual(dResult.psk.count, ProximityPairing.pskBytes)
        XCTAssertEqual(dResult.psk, sResult.psk)
        XCTAssertEqual(dResult.sas, sResult.sas)
        XCTAssertEqual(dResult.sas, dWait.sas)
        XCTAssertEqual(dResult.pskFingerprint, sResult.pskFingerprint)
        XCTAssertEqual(dResult.pskFingerprint, PskAdvertising.canonicalFingerprint(forPsk: dResult.psk))
        XCTAssertEqual(dResult.pskFingerprint, hexDigest(dResult.psk))
        XCTAssertEqual(dResult.role, .displayer)
        XCTAssertEqual(sResult.role, .scanner)
        XCTAssertEqual(dResult.peer, rig.scannerIdentity.publicIdentity)
        XCTAssertEqual(sResult.peer, rig.displayerIdentity.publicIdentity)
        XCTAssertNil(dResult.identityWarning)
        XCTAssertNil(sResult.identityWarning)
        XCTAssertEqual(rig.displayerPolicy.seen, [rig.scannerIdentity.publicIdentity])
        XCTAssertEqual(rig.scannerPolicy.seen, [rig.displayerIdentity.publicIdentity])

        // The link stays up for the grace period, then everything is released.
        XCTAssertEqual(rig.displayerTransport.shutdownCount, 0)
        rig.scheduler.advance(by: ProximityPairing.completionLinkGrace)
        rig.hub.pump()
        XCTAssertEqual(rig.displayerTransport.shutdownCount, 1)
        XCTAssertTrue(rig.displayerTransport.displayerEnds[0].isClosed)
        XCTAssertEqual(scannerTransport.link?.isClosed, true)
        XCTAssertGreaterThanOrEqual(scannerTransport.cancelCount, 1)
        XCTAssertNotNil(displayerResult(rig.displayer.state))
        XCTAssertNotNil(scannerResult(scanner.state))
    }

    // MARK: Confirmation ordering

    func testDisplayerConfirmsFirstNothingCompletesUntilScannerConfirms() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, _) = try runHandshake(rig)
        rig.displayer.confirm()
        rig.hub.pump()
        rig.scheduler.advance(by: 60)
        rig.hub.pump()
        assertNeitherCompleted(rig, scanner)
        XCTAssertEqual(displayerAwaiting(rig.displayer.state)?.localConfirmed, true)
        XCTAssertEqual(scannerAwaiting(scanner.state)?.localConfirmed, false)

        // The displayer's CONFIRM already arrived: the scanner completes on its own confirm.
        scanner.confirm()
        XCTAssertNotNil(scannerResult(scanner.state))
        XCTAssertNil(displayerResult(rig.displayer.state))
        rig.hub.pump()
        XCTAssertNotNil(displayerResult(rig.displayer.state))
    }

    func testScannerConfirmsFirstNothingCompletesUntilDisplayerConfirms() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, _) = try runHandshake(rig)
        scanner.confirm()
        rig.hub.pump()
        assertNeitherCompleted(rig, scanner)
        XCTAssertEqual(scannerAwaiting(scanner.state)?.localConfirmed, true)
        XCTAssertEqual(displayerAwaiting(rig.displayer.state)?.localConfirmed, false)

        rig.displayer.confirm()
        XCTAssertNotNil(displayerResult(rig.displayer.state))
        XCTAssertNil(scannerResult(scanner.state))
        rig.hub.pump()
        XCTAssertNotNil(scannerResult(scanner.state))
    }

    func testBothConfirmBeforeEitherConfirmIsDelivered() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, _) = try runHandshake(rig)
        rig.displayer.confirm()
        scanner.confirm()
        assertNeitherCompleted(rig, scanner)
        rig.hub.pump()
        XCTAssertNotNil(displayerResult(rig.displayer.state))
        XCTAssertNotNil(scannerResult(scanner.state))
    }

    func testObserversMayConfirmReentrantly() throws {
        let rig: ProximitySessionRig = try makeRig()
        let displayer: ProximityDisplayerSession = rig.displayer
        displayer.onStateChange = { [weak displayer] (state: ProximityDisplayerSession.State) in
            if case .awaitingConfirmation(sas: _, peer: _, warning: _, localConfirmed: false) = state {
                displayer?.confirm()
            }
        }
        displayer.start()
        let payload: ProximityQrPayload = try showingPayload(rig)
        let (scanner, _) = rig.makeScanner(payload: payload)
        scanner.onStateChange = { [weak scanner] (state: ProximityScannerSession.State) in
            if case .awaitingConfirmation(sas: _, peer: _, warning: _, localConfirmed: false) = state {
                scanner?.confirm()
            }
        }
        scanner.start()
        rig.hub.pump()
        XCTAssertNotNil(displayerResult(displayer.state))
        XCTAssertNotNil(scannerResult(scanner.state))
    }

    // MARK: QR frames and session lifetime

    func testFrameRotationKeepsSessionAndCommitment() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let p0: ProximityQrPayload = try showingPayload(rig)
        XCTAssertEqual(p0.frameIndex, 0)
        XCTAssertEqual(rig.displayerTransport.startAdvertisingCalls, [p0.sessionId])

        rig.scheduler.advance(by: ProximityPairing.frameRotationInterval)
        let p1: ProximityQrPayload = try showingPayload(rig)
        XCTAssertEqual(p1.frameIndex, 1)
        XCTAssertEqual(p1.sessionId, p0.sessionId)
        XCTAssertEqual(p1.commitment, p0.commitment)
        XCTAssertNotEqual(p1.frameKey, p0.frameKey)

        rig.scheduler.advance(by: ProximityPairing.frameRotationInterval)
        let p2: ProximityQrPayload = try showingPayload(rig)
        XCTAssertEqual(p2.frameIndex, 2)
        XCTAssertEqual(p2.sessionId, p0.sessionId)
        XCTAssertEqual(rig.displayerTransport.startAdvertisingCalls.count, 1)
        XCTAssertGreaterThanOrEqual(rig.displayerStates.count, 3)
    }

    func testLifetimeRegeneratesSession() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let p0: ProximityQrPayload = try showingPayload(rig)
        rig.scheduler.advance(by: ProximityPairing.sessionLifetime)
        let fresh: ProximityQrPayload = try showingPayload(rig)
        XCTAssertEqual(fresh.frameIndex, 0)
        XCTAssertNotEqual(fresh.sessionId, p0.sessionId)
        XCTAssertNotEqual(fresh.commitment, p0.commitment)
        XCTAssertEqual(rig.displayerTransport.startAdvertisingCalls.count, 2)
        XCTAssertEqual(rig.displayerTransport.startAdvertisingCalls.last, fresh.sessionId)

        // The old QR no longer finds the peripheral...
        let (old, _) = rig.makeScanner(payload: p0)
        old.start()
        rig.hub.pump()
        XCTAssertEqual(proxSessionKind(scannerError(old.state)), "timeout")

        // ...and even when it reaches it, its HELLO fails the tag check without consuming the session.
        let (forced, forcedTransport) = rig.makeScanner(payload: p0)
        forcedTransport.requireAdvertising = false
        forced.start()
        rig.hub.pump()
        XCTAssertEqual(forced.state, .failed(.peerAborted(ProximityPairing.AbortReason.authenticationFailed.rawValue)))
        XCTAssertTrue(isShowing(rig.displayer.state))

        let (scanner, _) = rig.makeScanner(payload: try showingPayload(rig))
        scanner.start()
        rig.hub.pump()
        XCTAssertNotNil(scannerAwaiting(scanner.state))
        XCTAssertNotNil(displayerAwaiting(rig.displayer.state))
    }

    func testOlderFrameInsideWindowIsAccepted() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let p0: ProximityQrPayload = try showingPayload(rig)
        rig.scheduler.advance(by: 6)
        XCTAssertEqual(try showingPayload(rig).frameIndex, 3)
        let (scanner, _) = rig.makeScanner(payload: p0)
        scanner.start()
        rig.hub.pump()
        XCTAssertNotNil(scannerAwaiting(scanner.state))
        XCTAssertNotNil(displayerAwaiting(rig.displayer.state))
    }

    // MARK: Tamper matrix — HELLO

    func testStaleFrameIsRejectedWithoutConsumingSession() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let p0: ProximityQrPayload = try showingPayload(rig)
        let (scanner, _) = rig.makeScanner(payload: p0)
        scanner.start()
        rig.hub.step()   // connected; HELLO queued
        rig.scheduler.advance(by: ProximityPairing.frameAcceptanceWindow + 1)
        rig.hub.pump()

        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.frameExpired.rawValue)))
        XCTAssertTrue(isShowing(rig.displayer.state))
        XCTAssertEqual(rig.displayerTransport.stopAdvertisingCount, 0)
        XCTAssertTrue(rig.displayerTransport.displayerEnds[0].isClosed)
        assertNeitherCompleted(rig, scanner)

        // Not consumed: a fresh scan still pairs.
        let (second, _) = rig.makeScanner(payload: try showingPayload(rig))
        second.start()
        rig.hub.pump()
        XCTAssertNotNil(scannerAwaiting(second.state))
        XCTAssertNotNil(displayerAwaiting(rig.displayer.state))
    }

    func testUnknownFrameIndexIsRejected() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let p0: ProximityQrPayload = try showingPayload(rig)
        let forged = try ProximityQrPayload(sessionId: p0.sessionId, commitment: p0.commitment,
                                            frameIndex: 99, frameKey: p0.frameKey)
        let (scanner, _) = rig.makeScanner(payload: forged)
        scanner.start()
        rig.hub.pump()
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.frameExpired.rawValue)))
        XCTAssertTrue(isShowing(rig.displayer.state))
        assertNeitherCompleted(rig, scanner)
    }

    func testHelloTagFlipIsRejectedWithoutConsumingSession() throws {
        let filter = proxSessionTamper(type: 0x01) { (m: Data) -> Data in proxSessionFlip(m, at: m.count - 1) }
        let (rig, scanner) = try runTampered(toDisplayer: filter)
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.authenticationFailed.rawValue)))
        XCTAssertTrue(isShowing(rig.displayer.state))
        assertNeitherCompleted(rig, scanner)
    }

    // MARK: Tamper matrix — OFFER

    func testOfferKemKeyFlipFailsCommitment() throws {
        let filter = proxSessionTamper(type: 0x02) { (m: Data) -> Data in proxSessionFlip(m, at: 10) }
        let (rig, scanner) = try runTampered(toScanner: filter)
        XCTAssertEqual(proxSessionKind(scannerError(scanner.state)), "authenticationFailed")
        XCTAssertEqual(rig.displayer.state, .failed(.peerAborted(ProximityPairing.AbortReason.authenticationFailed.rawValue)))
        assertNeitherCompleted(rig, scanner)
    }

    func testOfferCarryingAnIdentityIsRejected() throws {
        // The pre-SIGMA OFFER appended the displayer's idBlock; the strict
        // 1632-byte OFFER turns that into a protocol violation.
        let other: ProximityLocalIdentity = try ProximityTestIdentities.make(userId: "mallory")
        let appended: Data = ProximityMessage.idBlock(other.publicIdentity)
        let filter = proxSessionTamper(type: 0x02) { (m: Data) -> Data in
            var grown: Data = Data(m)
            grown.append(appended)
            return grown
        }
        let (rig, scanner) = try runTampered(toScanner: filter)
        assertScannerViolation(rig, scanner)
        XCTAssertTrue(rig.scannerPolicy.seen.isEmpty)
    }

    func testTruncatedOfferIsRejected() throws {
        let filter = proxSessionTamper(type: 0x02) { (m: Data) -> Data in Data(m.prefix(m.count - 1)) }
        let (rig, scanner) = try runTampered(toScanner: filter)
        assertScannerViolation(rig, scanner)
    }

    // MARK: Tamper matrix — ACCEPT (ct ‖ sealed_S)

    private func assertDisplayerRejectsAccept(file: StaticString = #filePath, line: UInt = #line,
                                              _ transform: @escaping (Data) -> Data) throws {
        let (rig, scanner) = try runTampered(toDisplayer: proxSessionTamper(type: 0x03, transform))
        XCTAssertEqual(proxSessionKind(displayerError(rig.displayer.state)), "authenticationFailed",
                       file: file, line: line)
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.authenticationFailed.rawValue)),
                       file: file, line: line)
        // The displayer never saw an identity it could judge.
        XCTAssertTrue(rig.displayerPolicy.seen.isEmpty, file: file, line: line)
        XCTAssertTrue(rig.scannerPolicy.seen.isEmpty, file: file, line: line)
        assertNeitherCompleted(rig, scanner, file: file, line: line)
    }

    /// ML-KEM implicit rejection: other shared secret, other K_enc_S, sealed_S does not open.
    func testAcceptCiphertextFlipIsRejected() throws {
        try assertDisplayerRejectsAccept { (m: Data) -> Data in proxSessionFlip(m, at: 100) }
    }

    func testAcceptSealedTagFlipIsRejected() throws {
        try assertDisplayerRejectsAccept { (m: Data) -> Data in proxSessionFlip(m, at: m.count - 1) }
    }

    /// Inside the sealed sig_S / mac_S region.
    func testAcceptSealedTrailerFlipIsRejected() throws {
        try assertDisplayerRejectsAccept { (m: Data) -> Data in proxSessionFlip(m, at: m.count - 40) }
    }

    func testAcceptSealedFirstByteFlipIsRejected() throws {
        try assertDisplayerRejectsAccept { (m: Data) -> Data in proxSessionFlip(m, at: 1 + 1568) }
    }

    /// Where idPub_S sits inside the box: substituting it still has to beat the tag.
    func testAcceptSealedSigningKeyRegionReplacedIsRejected() throws {
        let other: ProximityLocalIdentity = try ProximityTestIdentities.make(userId: "mallory")
        let replacement: Data = other.signingPublicKey
        try assertDisplayerRejectsAccept { (m: Data) -> Data in
            proxSessionReplace(m, at: 1 + 1568, with: replacement)
        }
    }

    /// Still a length a box can have, so it reaches (and fails) the AEAD.
    func testAcceptSealedTruncatedByOneByteIsRejected() throws {
        try assertDisplayerRejectsAccept { (m: Data) -> Data in Data(m.prefix(m.count - 1)) }
    }

    // MARK: Tamper matrix — FINISH (sealed_D) and CONFIRM

    private func assertScannerRejectsFinish(file: StaticString = #filePath, line: UInt = #line,
                                            _ transform: @escaping (Data) -> Data) throws {
        let (rig, scanner) = try runTampered(toScanner: proxSessionTamper(type: 0x04, transform))
        XCTAssertEqual(proxSessionKind(scannerError(scanner.state)), "authenticationFailed", file: file, line: line)
        XCTAssertEqual(rig.displayer.state,
                       .failed(.peerAborted(ProximityPairing.AbortReason.authenticationFailed.rawValue)),
                       file: file, line: line)
        // The scanner never learned who the displayer is.
        XCTAssertTrue(rig.scannerPolicy.seen.isEmpty, file: file, line: line)
        assertNeitherCompleted(rig, scanner, file: file, line: line)
    }

    func testFinishSealedTagFlipIsRejected() throws {
        try assertScannerRejectsFinish { (m: Data) -> Data in proxSessionFlip(m, at: m.count - 1) }
    }

    func testFinishSealedCiphertextFlipIsRejected() throws {
        try assertScannerRejectsFinish { (m: Data) -> Data in proxSessionFlip(m, at: 5) }
    }

    func testFinishSealedFirstByteFlipIsRejected() throws {
        try assertScannerRejectsFinish { (m: Data) -> Data in proxSessionFlip(m, at: 1) }
    }

    func testFinishSealedTruncatedByOneByteIsRejected() throws {
        try assertScannerRejectsFinish { (m: Data) -> Data in Data(m.prefix(m.count - 1)) }
    }

    func testWrongConfirmFromScannerIsRejected() throws {
        let filter = proxSessionTamper(type: 0x05) { (m: Data) -> Data in proxSessionFlip(m, at: 3) }
        let (rig, scanner) = try runTampered(toDisplayer: filter, confirmScanner: true)
        XCTAssertEqual(proxSessionKind(displayerError(rig.displayer.state)), "authenticationFailed")
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.authenticationFailed.rawValue)))
        assertNeitherCompleted(rig, scanner)
    }

    func testWrongConfirmFromDisplayerIsRejected() throws {
        let filter = proxSessionTamper(type: 0x05) { (m: Data) -> Data in proxSessionFlip(m, at: 3) }
        let (rig, scanner) = try runTampered(toScanner: filter, confirmDisplayer: true)
        XCTAssertEqual(proxSessionKind(scannerError(scanner.state)), "authenticationFailed")
        XCTAssertEqual(rig.displayer.state, .failed(.peerAborted(ProximityPairing.AbortReason.authenticationFailed.rawValue)))
        assertNeitherCompleted(rig, scanner)
    }

    // MARK: User decisions

    func testDisplayerRejectAbortsBothSides() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, _) = try runHandshake(rig)
        rig.displayer.reject()
        rig.hub.pump()
        XCTAssertEqual(rig.displayer.state, .failed(.userRejected))
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.userRejected.rawValue)))
    }

    func testScannerRejectAbortsBothSides() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, _) = try runHandshake(rig)
        scanner.confirm()
        rig.hub.pump()
        // Rejecting after a local confirm still ends the pairing on both sides.
        scanner.reject()
        rig.hub.pump()
        XCTAssertEqual(scanner.state, .failed(.userRejected))
        XCTAssertEqual(rig.displayer.state, .failed(.peerAborted(ProximityPairing.AbortReason.userRejected.rawValue)))
        rig.displayer.confirm()
        rig.hub.pump()
        assertNeitherCompleted(rig, scanner)
    }

    func testCancelWhileShowingShutsDown() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        rig.displayer.cancel()
        XCTAssertEqual(rig.displayer.state, .failed(.cancelled))
        XCTAssertEqual(rig.displayerTransport.shutdownCount, 1)
        XCTAssertEqual(rig.scheduler.pendingCount, 0)

        // Restart from failed gives a brand-new session.
        let firstSession: Data = rig.displayerTransport.startAdvertisingCalls[0]
        rig.displayer.start()
        let fresh: ProximityQrPayload = try showingPayload(rig)
        XCTAssertNotEqual(fresh.sessionId, firstSession)
        XCTAssertEqual(rig.displayerTransport.startAdvertisingCalls.count, 2)
    }

    func testDisplayerCancelDuringConfirmationAbortsScanner() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, _) = try runHandshake(rig)
        rig.displayer.cancel()
        rig.hub.pump()
        XCTAssertEqual(rig.displayer.state, .failed(.cancelled))
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.cancelled.rawValue)))
    }

    // MARK: Busy, transport, timeouts

    func testSecondCentralGetsBusy() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let payload: ProximityQrPayload = try showingPayload(rig)
        let (first, _) = rig.makeScanner(payload: payload)
        let (second, _) = rig.makeScanner(payload: payload)
        first.start()
        second.start()
        rig.hub.pump()
        XCTAssertEqual(second.state, .failed(.sessionBusy))
        XCTAssertNotNil(scannerAwaiting(first.state))
        XCTAssertNotNil(displayerAwaiting(rig.displayer.state))

        // A central that connects after the lock is turned away too.
        let (late, lateTransport) = rig.makeScanner(payload: payload)
        lateTransport.requireAdvertising = false
        late.start()
        rig.hub.pump()
        XCTAssertEqual(late.state, .failed(.sessionBusy))

        // The locked pairing is unaffected.
        rig.displayer.confirm()
        first.confirm()
        rig.hub.pump()
        XCTAssertNotNil(displayerResult(rig.displayer.state))
        XCTAssertNotNil(scannerResult(first.state))
        XCTAssertNil(scannerResult(second.state))
        XCTAssertNil(scannerResult(late.state))
    }

    func testLinkDropMidHandshakeFailsBothSides() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let (scanner, scannerTransport) = rig.makeScanner(payload: try showingPayload(rig))
        scanner.start()
        rig.hub.step()   // connected, HELLO queued
        rig.hub.step()   // locked, OFFER queued
        XCTAssertEqual(rig.displayer.state, .exchanging)
        let scannerEnd: ProximityFakeLink = try XCTUnwrap(scannerTransport.link)
        scannerEnd.simulateDrop(.transportFailed("radio"))
        rig.hub.pump()
        XCTAssertEqual(proxSessionKind(displayerError(rig.displayer.state)), "transportFailed")
        XCTAssertEqual(proxSessionKind(scannerError(scanner.state)), "transportFailed")
        XCTAssertGreaterThanOrEqual(rig.displayerTransport.shutdownCount, 1)
        assertNeitherCompleted(rig, scanner)
    }

    func testHandshakeTimeout() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayerTransport.toDisplayerFilter = proxSessionDrop(type: 0x03)
        let (scanner, _) = try runHandshake(rig)
        XCTAssertEqual(rig.displayer.state, .exchanging)
        XCTAssertEqual(scanner.state, .exchanging)
        rig.scheduler.advance(by: ProximityPairing.handshakeTimeout - 1)
        rig.hub.pump()
        XCTAssertEqual(rig.displayer.state, .exchanging)
        rig.scheduler.advance(by: 1)
        rig.hub.pump()
        XCTAssertTrue(proxSessionIsTimeout(displayerError(rig.displayer.state)))
        XCTAssertTrue(proxSessionIsTimeout(scannerError(scanner.state)))
        assertNeitherCompleted(rig, scanner)
    }

    func testConfirmationTimeout() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, _) = try runHandshake(rig)
        rig.displayer.confirm()
        rig.hub.pump()
        rig.scheduler.advance(by: ProximityPairing.userConfirmationTimeout - 1)
        rig.hub.pump()
        XCTAssertNotNil(displayerAwaiting(rig.displayer.state))
        rig.scheduler.advance(by: 1)
        rig.hub.pump()
        XCTAssertTrue(proxSessionIsTimeout(displayerError(rig.displayer.state)))
        XCTAssertTrue(proxSessionIsTimeout(scannerError(scanner.state)))
        assertNeitherCompleted(rig, scanner)
    }

    func testTransportUnavailableFailsDisplayer() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        rig.displayerTransport.onUnavailable?(.bluetoothUnavailable("off"))
        XCTAssertEqual(rig.displayer.state, .failed(.bluetoothUnavailable("off")))
        XCTAssertGreaterThanOrEqual(rig.displayerTransport.shutdownCount, 1)
    }

    func testScannerConnectFailure() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let (scanner, scannerTransport) = rig.makeScanner(payload: try showingPayload(rig))
        scannerTransport.forcedResult = .failure(.bluetoothUnavailable("off"))
        scanner.start()
        XCTAssertEqual(scanner.state, .connecting)
        rig.hub.pump()
        XCTAssertEqual(scanner.state, .failed(.bluetoothUnavailable("off")))
        XCTAssertTrue(isShowing(rig.displayer.state))
    }

    // MARK: Identity policy

    func testDisplayerPolicyRejects() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayerPolicy.decision = .reject("blocked")
        let (scanner, _) = try runHandshake(rig)
        XCTAssertEqual(rig.displayer.state, .failed(.identityRejected("blocked")))
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.identityRejected.rawValue)))
        XCTAssertEqual(rig.displayerPolicy.seen, [rig.scannerIdentity.publicIdentity])
        // The displayer refused before sealing its own identity: the scanner never saw it.
        XCTAssertTrue(rig.scannerPolicy.seen.isEmpty)
        let toScanner: [Data] = rig.displayerTransport.displayerEnds[0].sent
        XCTAssertFalse(toScanner.contains { (m: Data) -> Bool in m.first == ProximityPairing.MessageType.finish.rawValue })
    }

    func testScannerPolicyRejects() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.scannerPolicy.decision = .reject("blocked")
        let (scanner, _) = try runHandshake(rig)
        XCTAssertEqual(scanner.state, .failed(.identityRejected("blocked")))
        // The displayer had already sent FINISH and was waiting for its user;
        // the scanner's ABORT(identity rejected) ends it there.
        XCTAssertEqual(rig.displayer.state, .failed(.peerAborted(ProximityPairing.AbortReason.identityRejected.rawValue)))
        XCTAssertEqual(rig.scannerPolicy.seen, [rig.displayerIdentity.publicIdentity])
        // SIGMA-I order: the displayer judged the scanner first, on ACCEPT.
        XCTAssertEqual(rig.displayerPolicy.seen, [rig.scannerIdentity.publicIdentity])
        assertNeitherCompleted(rig, scanner)
    }

    /// Spec §9: the scanner's identity policy runs on FINISH, not on OFFER —
    /// before FINISH it does not know who the displayer is.
    func testScannerPolicyRunsOnlyOnFinish() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayerTransport.toScannerFilter = proxSessionDrop(type: ProximityPairing.MessageType.finish.rawValue)
        let (scanner, _) = try runHandshake(rig)
        XCTAssertNotNil(displayerAwaiting(rig.displayer.state))
        XCTAssertEqual(scanner.state, .exchanging)
        XCTAssertEqual(rig.displayerPolicy.seen, [rig.scannerIdentity.publicIdentity])
        XCTAssertTrue(rig.scannerPolicy.seen.isEmpty)
        // No FINISH ever arrives: the scanner times out and stores nothing.
        rig.scheduler.advance(by: ProximityPairing.handshakeTimeout)
        rig.hub.pump()
        XCTAssertTrue(proxSessionIsTimeout(scannerError(scanner.state)))
        XCTAssertTrue(rig.scannerPolicy.seen.isEmpty)
        assertNeitherCompleted(rig, scanner)
    }

    /// SIGMA-I: no identity (Ed25519 key, X25519 key or userId) of either side
    /// appears in clear in any message on the link.
    func testNoIdentityTravelsInClear() throws {
        let rig: ProximitySessionRig = try makeRig()
        let (scanner, scannerTransport) = try runHandshake(rig)
        rig.displayer.confirm()
        scanner.confirm()
        rig.hub.pump()
        XCTAssertNotNil(scannerResult(scanner.state))

        let toScanner: [Data] = rig.displayerTransport.displayerEnds[0].sent
        let scannerEnd: ProximityFakeLink = try XCTUnwrap(scannerTransport.link)
        let toDisplayer: [Data] = scannerEnd.sent
        let offer: Data = try XCTUnwrap(toScanner.first(where: { (m: Data) -> Bool in
            m.first == ProximityPairing.MessageType.offer.rawValue
        }))
        XCTAssertEqual(offer.count, 1 + ProximityPairing.offerBodyBytes)

        let d: ProximityPeerIdentity = rig.displayerIdentity.publicIdentity
        let s: ProximityPeerIdentity = rig.scannerIdentity.publicIdentity
        let needles: [Data] = [d.signingPublicKey, d.encryptionPublicKey, Data(d.userId.utf8),
                               s.signingPublicKey, s.encryptionPublicKey, Data(s.userId.utf8)]
        XCTAssertGreaterThanOrEqual(toScanner.count + toDisplayer.count, 6)
        for message in toScanner + toDisplayer {
            for needle in needles {
                XCTAssertNil(message.range(of: needle))
            }
        }
    }

    func testEveryPairingAgreesOnSasAndPskAndNoTwoShareAPsk() throws {
        var psks: [Data] = []
        var round: Int = 0
        while round < 3 {
            let rig: ProximitySessionRig = try makeRig()
            let (scanner, _) = try runHandshake(rig)
            rig.displayer.confirm()
            scanner.confirm()
            rig.hub.pump()
            let dResult: ProximityPairingResult = try XCTUnwrap(displayerResult(rig.displayer.state))
            let sResult: ProximityPairingResult = try XCTUnwrap(scannerResult(scanner.state))
            XCTAssertEqual(dResult.sas, sResult.sas)
            XCTAssertEqual(dResult.psk, sResult.psk)
            XCTAssertEqual(dResult.pskFingerprint, sResult.pskFingerprint)
            XCTAssertFalse(psks.contains(dResult.psk))
            psks.append(dResult.psk)
            round += 1
        }
    }

    func testWarningSurfacesInStateAndResult() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayerPolicy.decision = .acceptWithWarning("pin mismatch")
        rig.scannerPolicy.decision = .acceptWithWarning("scanner warning")
        let (scanner, _) = try runHandshake(rig)
        XCTAssertEqual(displayerAwaiting(rig.displayer.state)?.warning, "pin mismatch")
        XCTAssertEqual(scannerAwaiting(scanner.state)?.warning, "scanner warning")
        rig.displayer.confirm()
        scanner.confirm()
        rig.hub.pump()
        XCTAssertEqual(displayerResult(rig.displayer.state)?.identityWarning, "pin mismatch")
        XCTAssertEqual(scannerResult(scanner.state)?.identityWarning, "scanner warning")
    }

    /// Under SIGMA-I the displayer opens the scanner's identity first (ACCEPT),
    /// so it is the one that refuses a self pairing. The scanner's own self
    /// check (on FINISH) is covered by the scripted-displayer tests below.
    func testSelfPairingIsRejected() throws {
        let same: ProximityLocalIdentity = try ProximityTestIdentities.make(userId: "same-user")
        let rig: ProximitySessionRig = try makeRig(displayer: same, scanner: same)
        let (scanner, _) = try runHandshake(rig)
        XCTAssertEqual(proxSessionKind(displayerError(rig.displayer.state)), "identityRejected")
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.identityRejected.rawValue)))
        // The self check runs before the host policy, on both sides.
        XCTAssertTrue(rig.displayerPolicy.seen.isEmpty)
        XCTAssertTrue(rig.scannerPolicy.seen.isEmpty)
        assertNeitherCompleted(rig, scanner)
    }

    func testSameUserIdWithDifferentKeyIsRejected() throws {
        let displayerIdentity: ProximityLocalIdentity = try ProximityTestIdentities.make(userId: "same-user")
        let scannerIdentity: ProximityLocalIdentity = try ProximityTestIdentities.make(userId: "same-user")
        let rig: ProximitySessionRig = try makeRig(displayer: displayerIdentity, scanner: scannerIdentity)
        let (scanner, _) = try runHandshake(rig)
        XCTAssertEqual(proxSessionKind(displayerError(rig.displayer.state)), "identityRejected")
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.identityRejected.rawValue)))
        XCTAssertTrue(rig.displayerPolicy.seen.isEmpty)
        assertNeitherCompleted(rig, scanner)
    }

    // MARK: Ordering

    private func assertDisplayerViolation(_ rig: ProximitySessionRig, _ scanner: ProximityScannerSession,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(proxSessionKind(displayerError(rig.displayer.state)), "protocolViolation", file: file, line: line)
        XCTAssertEqual(scanner.state, .failed(.peerAborted(ProximityPairing.AbortReason.protocolViolation.rawValue)),
                       file: file, line: line)
        assertNeitherCompleted(rig, scanner, file: file, line: line)
    }

    private func assertScannerViolation(_ rig: ProximitySessionRig, _ scanner: ProximityScannerSession,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(proxSessionKind(scannerError(scanner.state)), "protocolViolation", file: file, line: line)
        XCTAssertEqual(rig.displayer.state, .failed(.peerAborted(ProximityPairing.AbortReason.protocolViolation.rawValue)),
                       file: file, line: line)
        assertNeitherCompleted(rig, scanner, file: file, line: line)
    }

    /// A FINISH that decodes (a sealed-box length) but was never sealed by anyone.
    private func finishBytes() -> Data {
        let finish = ProximityMessage.Finish(sealed: Data(repeating: 1, count: ProximityMessage.minSealedBytes + 11))
        return ProximityMessage.finish(finish).encoded()
    }

    func testFinishSentToDisplayerIsViolation() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let (scanner, scannerTransport) = rig.makeScanner(payload: try showingPayload(rig))
        scanner.start()
        rig.hub.step()
        rig.hub.step()
        XCTAssertEqual(rig.displayer.state, .exchanging)
        let scannerEnd: ProximityFakeLink = try XCTUnwrap(scannerTransport.link)
        scannerEnd.send(finishBytes())
        rig.hub.pump()
        assertDisplayerViolation(rig, scanner)
    }

    func testSecondHelloOnLockedLinkIsViolation() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let (scanner, scannerTransport) = rig.makeScanner(payload: try showingPayload(rig))
        scanner.start()
        rig.hub.step()
        rig.hub.step()
        XCTAssertEqual(rig.displayer.state, .exchanging)
        let scannerEnd: ProximityFakeLink = try XCTUnwrap(scannerTransport.link)
        let hello: Data = try XCTUnwrap(scannerEnd.sent.first)
        scannerEnd.send(hello)
        rig.hub.pump()
        assertDisplayerViolation(rig, scanner)
    }

    func testFinishBeforeOfferIsViolation() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let (scanner, _) = rig.makeScanner(payload: try showingPayload(rig))
        scanner.start()
        rig.hub.step()   // connected, HELLO queued
        let displayerEnd: ProximityFakeLink = rig.displayerTransport.displayerEnds[0]
        displayerEnd.send(finishBytes())
        rig.hub.pump()
        assertScannerViolation(rig, scanner)
    }

    func testConfirmDuringHandshakeIsViolation() throws {
        let rig: ProximitySessionRig = try makeRig()
        rig.displayer.start()
        let (scanner, _) = rig.makeScanner(payload: try showingPayload(rig))
        scanner.start()
        rig.hub.step()   // connected, HELLO queued
        let displayerEnd: ProximityFakeLink = rig.displayerTransport.displayerEnds[0]
        let confirm: Data = ProximityMessage.confirm(mac: Data(repeating: 9, count: 32)).encoded()
        displayerEnd.send(confirm)
        rig.hub.pump()
        assertScannerViolation(rig, scanner)
    }
}
