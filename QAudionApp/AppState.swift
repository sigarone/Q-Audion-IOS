import Foundation
import SwiftUI
import CryptoKit
import QAudionEngine

enum CallState: String {
    case idle
    case connecting
    case ringing
    case active
    case encrypted
    case ended
}

// MARK: - Messaging Models

struct Conversation: Identifiable {
    let id: String
    let contactName: String
    var lastMessage: String
    var lastMessageTime: Date
    var unreadCount: Int
    var isEncrypted: Bool
}

struct ChatMessage: Identifiable {
    let id: String
    let text: String
    let timestamp: Date
    let isSent: Bool
    let isEncrypted: Bool
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Auth state
    @Published var isAuthenticated: Bool = false
    @Published var currentUserId: String?
    @Published var errorMessage: String?

    // MARK: - Call state
    @Published var isInCall: Bool = false
    @Published var isVideoCall: Bool = false
    @Published var callState: CallState = .idle
    @Published var callContactId: String?
    @Published var deepfakeAlert: Bool = false
    @Published var recentCalls: [String] = []

    // MARK: - Waveform state (updated during call for visualization)
    @Published var txWaveformSamples: [Float] = []
    @Published var rxWaveformSamples: [Float] = []
    @Published var cipherWaveformSamples: [Float] = []
    @Published var txWaveform: [Float] = Array(repeating: 0, count: 128)
    @Published var rxWaveform: [Float] = Array(repeating: 0, count: 128)
    @Published var cipherWaveform: [Float] = Array(repeating: 0, count: 128)
    @Published var framesTx: Int = 0
    @Published var framesRx: Int = 0
    @Published var waveformEnabled: Bool = false

    // MARK: - Messaging state
    @Published var conversations: [Conversation] = []
    @Published var currentMessages: [ChatMessage] = []

    // MARK: - Security badge state (updated during call)
    @Published var confidenceLevel: String = "green"  // "green", "yellow", "red"
    @Published var confidenceScore: Float = 0.97
    @Published var backendType: String = "PQC"  // "PQC", "BCR", "STD"
    @Published var pskActive: Bool = false
    @Published var pskName: String = ""
    @Published var pskFingerprint: String = ""
    @Published var rekeyCount: Int = 0
    @Published var encryptionAlgo: String = "ML-KEM-1024 + AES-256-GCM"
    @Published var transportType: String = "P2P Direct"
    @Published var latencyMs: Int = 0

    // MARK: - Server connection state
    @Published var serverUrl: String = "https://api.qaudion.com"
    @Published var connectionStatus: String = "not_configured"  // "connected", "connecting", "error", "not_configured"
    @Published var backendMode: String = "dual"  // "signal_only", "dual", "bcrypto_only"

    var engine: QAudionEngine?
    let authService = AuthService()
    let callService = CallService()
    let messageCrypto = MessageCrypto()

    private var defaultServerUrl: String { serverUrl }

    func initialize() {
        let config = EngineConfig.production()
        let engine = QAudionEngine(config: config)
        do {
            try engine.initialize()
            self.engine = engine
        } catch {
            errorMessage = "Engine initialization failed: \(error.localizedDescription)"
            return
        }

        callService.onDeepfakeAlert = { [weak self] isAlert in
            Task { @MainActor in
                self?.deepfakeAlert = isAlert
            }
        }

        callService.onDeepfakeScore = { [weak self] level, score in
            Task { @MainActor in
                guard let self else { return }
                self.confidenceScore = score
                switch level {
                case .critical, .high:
                    self.confidenceLevel = "red"
                case .medium:
                    self.confidenceLevel = "yellow"
                case .low, .none:
                    self.confidenceLevel = "green"
                @unknown default:
                    self.confidenceLevel = "green"
                }
            }
        }

        callService.onTxWaveformUpdate = { [weak self] samples in
            Task { @MainActor in
                guard let self else { return }
                self.txWaveformSamples = samples
                self.framesTx += 1
                // Downsample to 128 points for visualization
                self.txWaveform = Self.downsampleForDisplay(samples, count: 128)
            }
        }

        callService.onRxWaveformUpdate = { [weak self] samples in
            Task { @MainActor in
                guard let self else { return }
                self.rxWaveformSamples = samples
                self.framesRx += 1
                self.rxWaveform = Self.downsampleForDisplay(samples, count: 128)
            }
        }

        callService.onCipherWaveformUpdate = { [weak self] samples in
            Task { @MainActor in
                guard let self else { return }
                self.cipherWaveformSamples = samples
                self.cipherWaveform = Self.downsampleForDisplay(samples, count: 128)
            }
        }

        if let token = authService.loadToken() {
            let backendConfig = BackendConfig(serverUrl: defaultServerUrl, accessToken: token)
            let rest = BCryptoRestClient(config: backendConfig)
            let accountApi = BCryptoAccountApiImpl(rest: rest)
            Task {
                do {
                    let profile = try await accountApi.getProfile()
                    self.currentUserId = profile.userId
                    self.isAuthenticated = true
                } catch {
                    authService.clearToken()
                    self.isAuthenticated = false
                }
            }
        }
    }

    func login(userId: String, credential: String) async {
        do {
            let token = try await authService.login(
                userId: userId, credential: credential, serverUrl: defaultServerUrl
            )
            authService.saveToken(token)
            currentUserId = userId
            isAuthenticated = true
            errorMessage = nil
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    func logout() {
        authService.clearToken()
        engine?.destroySession()
        engine?.release()
        engine = nil
        currentUserId = nil
        isAuthenticated = false
        callState = .idle
        isInCall = false
        deepfakeAlert = false
    }

    func startCall(contactId: String, video: Bool = false) async {
        guard let engine = engine else {
            errorMessage = "Engine not available"
            return
        }
        callContactId = contactId
        callState = .connecting
        isInCall = true
        isVideoCall = video
        confidenceLevel = "green"
        confidenceScore = 0.97
        rekeyCount = 0
        txWaveformSamples = []
        rxWaveformSamples = []
        cipherWaveformSamples = []
        do {
            try callService.startCall(engine: engine, contactId: contactId)
            callState = .active
            // Track in recent calls
            if !recentCalls.contains(contactId) {
                recentCalls.insert(contactId, at: 0)
                if recentCalls.count > 20 { recentCalls = Array(recentCalls.prefix(20)) }
            }
        } catch {
            callState = .ended
            isInCall = false
            isVideoCall = false
            errorMessage = "Call failed: \(error.localizedDescription)"
        }
    }

    func endCall() {
        callService.endCall()
        callState = .ended
        isInCall = false
        isVideoCall = false
        deepfakeAlert = false
        callContactId = nil
        txWaveformSamples = []
        rxWaveformSamples = []
        cipherWaveformSamples = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.callState = .idle
        }
    }

    func setMuted(_ muted: Bool) {
        engine?.audioProcessor?.setMuted(muted)
    }

    func setSpeaker(_ enabled: Bool) {
        engine?.audioProcessor?.setSpeaker(enabled)
    }

    func testConnection() async {
        connectionStatus = "connecting"
        let config = BackendConfig(serverUrl: serverUrl)
        let rest = BCryptoRestClient(config: config)
        do {
            _ = try await rest.get("/api/v1/health")
            connectionStatus = "connected"
        } catch {
            connectionStatus = "error"
        }
    }

    // MARK: - Messaging

    func sendMessage(to contactId: String, text: String) async {
        let messageId = UUID().uuidString
        let now = Date()

        // Add to local messages immediately for responsiveness
        let outgoing = ChatMessage(
            id: messageId,
            text: text,
            timestamp: now,
            isSent: true,
            isEncrypted: true
        )
        currentMessages.append(outgoing)

        // Update conversation preview
        if let idx = conversations.firstIndex(where: { $0.id == contactId }) {
            conversations[idx].lastMessage = text
            conversations[idx].lastMessageTime = now
        }

        // Encrypt and send via backend
        do {
            guard let content = text.data(using: .utf8) else { return }
            // Use a derived key for message encryption (32 bytes for AES-256)
            let keyMaterial = Data(SHA256.hash(data: Data((contactId + (currentUserId ?? "")).utf8)))
            let encrypted = try messageCrypto.encrypt(message: content, key: keyMaterial)
            // Package encrypted payload: nonce + ciphertext + tag
            var payload = Data()
            payload.append(encrypted.nonce)
            payload.append(encrypted.ciphertext)
            payload.append(encrypted.tag)

            let config = BackendConfig(serverUrl: serverUrl, accessToken: authService.loadToken())
            let ws = BCryptoWebSocketClient(config: config)
            let api = BCryptoMessageApiImpl(ws: ws)
            _ = try await api.sendMessage(recipientId: contactId, content: payload)
        } catch {
            errorMessage = "Send failed: \(error.localizedDescription)"
        }
    }

    func loadMessages(for contactId: String) async {
        // In production this would fetch from backend storage.
        // For now keep local state. Populate demo data if empty.
        if currentMessages.isEmpty {
            let now = Date()
            currentMessages = [
                ChatMessage(id: UUID().uuidString, text: "Hey, are you available for a secure call?",
                            timestamp: now.addingTimeInterval(-300), isSent: false, isEncrypted: true),
                ChatMessage(id: UUID().uuidString, text: "Yes, line is encrypted. Go ahead.",
                            timestamp: now.addingTimeInterval(-240), isSent: true, isEncrypted: true),
                ChatMessage(id: UUID().uuidString, text: "Sending the documents now.",
                            timestamp: now.addingTimeInterval(-120), isSent: false, isEncrypted: true),
            ]
        }
    }

    func createConversation(contactId: String) {
        guard !conversations.contains(where: { $0.id == contactId }) else { return }
        let conversation = Conversation(
            id: contactId,
            contactName: contactId,
            lastMessage: "Tap to start chatting",
            lastMessageTime: Date(),
            unreadCount: 0,
            isEncrypted: true
        )
        conversations.insert(conversation, at: 0)
    }

    // MARK: - Waveform Helpers

    /// Downsample an array of Float samples to a fixed number of display points
    /// by taking the maximum absolute value within each bucket (peak-hold).
    static func downsampleForDisplay(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty, count > 0 else {
            return Array(repeating: 0, count: count)
        }
        let bucketSize = max(1, samples.count / count)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let start = i * bucketSize
            let end = min(start + bucketSize, samples.count)
            guard start < end else { continue }
            var peak: Float = 0
            for j in start..<end {
                let abs = samples[j] < 0 ? -samples[j] : samples[j]
                if abs > peak { peak = abs }
            }
            result[i] = peak
        }
        return result
    }
}
