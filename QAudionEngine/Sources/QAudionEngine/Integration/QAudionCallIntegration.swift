import Foundation

public final class QAudionCallIntegration: @unchecked Sendable {
    public enum CallState: String { case idle; case capabilitySent; case negotiating; case active; case fallback; case error }

    private let lock = NSLock()
    private var state: CallState = .idle
    private let engine = QAudionEngine()
    private let pqc = PqcKeyExchange()
    private var localKeyPair: PqcKeyExchange.KeyPair?
    private var transportSelector: TransportSelector?
    private var capabilityExchange: QAudionCapabilityExchange?
    private let guardianMode = GuardianMode()
    private let voiceAnalysis = VoiceAnalysisEngine()
    private var sendOpaque: ((Data) async throws -> Void)?
    private var resolvedBcryptoUserId: String?
    private var bcryptoUserIdCache: [String: String] = [:]  // Signal recipientId -> BCrypto userId

    public var onStateChanged: ((CallState) -> Void)?
    public var onDeepfakeAlert: ((ConfidenceIndex.Level, Float) -> Void)?
    /// Set a BCryptoRestClient to enable userId pre-resolution before OFFER.
    /// Without this, OFFERs use Signal recipientId which may cause server routing failures.
    public var restClient: BCryptoRestClient?

    public init() {
        guardianMode.onAlert = { [weak self] level, score in self?.onDeepfakeAlert?(level, score) }
    }

    /// Resolve BCrypto userId for a contact. Call before onCallSetupStarted.
    public func resolveUserId(signalRecipientId: String, phoneHash: String) async {
        if let cached = bcryptoUserIdCache[signalRecipientId] {
            resolvedBcryptoUserId = cached
            return
        }
        guard let rest = restClient else { return }
        do {
            let data = try await rest.post("/api/v1/contacts/discover",
                body: try JSONSerialization.data(withJSONObject: ["hashes": [phoneHash]]))
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = json.first, let userId = first["userId"] as? String {
                resolvedBcryptoUserId = userId
                bcryptoUserIdCache[signalRecipientId] = userId
            }
        } catch { /* fallback: use signalRecipientId */ }
    }

    public func onCallSetupStarted(sendOpaqueMessage: @escaping (Data) async throws -> Void) throws {
        lock.lock()
        guard state == .idle else { lock.unlock(); throw IntegrationError.invalidState(state) }
        sendOpaque = sendOpaqueMessage
        lock.unlock()

        try engine.initialize()
        let keyPair = pqc.generateKeyPair()
        lock.lock()
        localKeyPair = keyPair
        state = .capabilitySent
        lock.unlock()
        onStateChanged?(.capabilitySent)

        // Use raw public key (no ASN.1) for cross-platform compat with Android
        let rawPublicKey = PqcKeyExchange.extractRawPublicKey(keyPair.publicKey)
        let offer = QAudionCapabilityExchange.createOffer(publicKey: rawPublicKey, pskFingerprints: [])
        Task { try? await sendOpaqueMessage(offer) }

        // Timeout after 15s
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.state == .capabilitySent { self.state = .fallback; self.lock.unlock(); self.onStateChanged?(.fallback) }
            else { self.lock.unlock() }
        }
    }

    public func onCapabilityMessageReceived(data: Data, sendOpaqueMessage: @escaping (Data) async throws -> Void) throws {
        guard let message = QAudionCapabilityExchange.parse(data) else { return }

        switch message {
        case .offer(let remotePublicKey, _, let pskFingerprints):
            let keyPair = pqc.generateKeyPair()
            let result = try pqc.encapsulate(remotePublicKey: remotePublicKey)
            try engine.initialize()
            try engine.initSession(sharedSecret: result.sharedSecret)
            let accept = QAudionCapabilityExchange.createAccept(ciphertext: result.ciphertext, pskFingerprint: nil)
            Task { try? await sendOpaqueMessage(accept) }
            lock.lock(); state = .active; lock.unlock()
            onStateChanged?(.active)

        case .accept(let ciphertext, let pskFingerprint):
            guard let kp = localKeyPair else { return }
            let sharedSecret = try pqc.decapsulate(ciphertext: ciphertext, privateKey: kp.privateKey)
            try engine.initSession(sharedSecret: sharedSecret)
            lock.lock(); state = .active; lock.unlock()
            onStateChanged?(.active)

        case .audioData, .voiceAnalysis, .dcSdpOffer, .dcSdpAnswer, .dcIce,
             .callHangup, .keyExchangeOffer, .keyExchangeAccept:
            // TODO(desktop-interop): route callHangup / keyExchange* to appropriate handlers
            break
        }
    }

    public func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        guardianMode.processFrame(pcmFrame)
        voiceAnalysis.processFrame(pcmFrame)
        return try engine.processOutgoingAudio(pcmFrame: pcmFrame)
    }

    public func processIncomingAudio(serializedFrame: Data) throws -> Data {
        let pcm = try engine.processIncomingAudio(serializedFrame: serializedFrame)
        guardianMode.processFrame(pcm)
        return pcm
    }

    public func onCallEnded() {
        engine.destroySession()
        engine.release()
        lock.lock(); state = .idle; localKeyPair = nil; lock.unlock()
        onStateChanged?(.idle)
    }

    public func getState() -> CallState { lock.lock(); defer { lock.unlock() }; return state }
    public func getGuardianMode() -> GuardianMode { guardianMode }
    public func getVoiceAnalysis() -> VoiceAnalysisEngine { voiceAnalysis }
}

public enum IntegrationError: Error { case invalidState(QAudionCallIntegration.CallState) }
