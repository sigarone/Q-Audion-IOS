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

/// Legacy conversation row used by AppState's in-memory `conversations` array
/// before the W11.A ConversationStore. Renamed from `Conversation` so that
/// callers in views (ChatContainer, ConversationListContainer) resolve the
/// unqualified symbol `Conversation` to `QAudionEngine.Conversation` (UUID-keyed).
/// Do NOT rename this back without also retiring the legacy preview list path.
struct LegacyConversation: Identifiable {
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

    /// W72: presence service — bound to the engine `BCryptoPresenceManager`
    /// after auth-success so the contacts list / conversations / chat
    /// header can render online/offline dots reactively. Always non-nil
    /// so SwiftUI can `@EnvironmentObject` it without a guard.
    @Published var presenceService: PresenceService = PresenceService()

    /// W74: long-lived backend provider whose WebSocket stays open as
    /// long as the user is authenticated. Server marks the user as
    /// `online` for as long as this WS is connected (see
    /// `bcrypto-server/internal/signaling/hub.go addClient`). Without
    /// this the iOS app only opens ad-hoc WSs during calls / message
    /// sends and the server reports `online_users: 0` for the rest of
    /// the time, which broke the presence dot end-to-end. Recreated on
    /// logout so the next session starts fresh.
    @Published private(set) var wsConnectionState: ConnectionState = .disconnected
    private var liveProvider: BCryptoBackendProvider?

    // MARK: - Call state
    @Published var isInCall: Bool = false
    @Published var isVideoCall: Bool = false
    @Published var callState: CallState = .idle
    @Published var callContactId: String?
    @Published var deepfakeAlert: Bool = false
    @Published var recentCalls: [String] = []

    // MARK: - Video codec
    /// HEVC (H.265) is primary, H.264 is fallback for older devices
    @Published var videoCodec: String = "HEVC"  // "HEVC" or "H.264"
    var videoCodecLabel: String {
        videoCodec == "HEVC" ? "HEVC (H.265)" : "H.264 (fallback)"
    }

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
    /// Legacy preview rows. The W11.A path uses `ConversationStore` + the engine
    /// `Conversation` (UUID-keyed); this array survives only for the deprecated
    /// `sendMessage(to:text:)` and `createConversation(contactId:)` helpers below.
    @Published var conversations: [LegacyConversation] = []
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
    /// Pinned to `PinnedServerHost.url` (`https://voip.bcrypto.com`).
    /// We keep it as `@Published var` (not `let`) only because the
    /// fast-setup login path explicitly re-asserts the value via
    /// `appState.serverUrl = PinnedServerHost.url` — a no-op today, but
    /// it survives any future code path that tries to override the host
    /// (e.g. a debug-flavor Settings field). The previous default
    /// `https://api.qaudion.com` was a placeholder that broke real
    /// logins; it's been wiped.
    @Published var serverUrl: String = PinnedServerHost.url
    @Published var connectionStatus: String = "not_configured"  // "connected", "connecting", "error", "not_configured"
    @Published var backendMode: String = "dual"  // "signal_only", "dual", "bcrypto_only"

    var engine: QAudionEngine?
    let authService = AuthService()
    let callService = CallService()
    let messageCrypto = MessageCrypto()

    // MARK: - CallKit / PushKit

    #if canImport(CallKit) && os(iOS)
    /// CallKit adapter. Nil only when CallKit is unavailable (macOS Catalyst, Simulator quirks).
    private(set) var callKit: CallKitManaging? = CallKitProvider()
    #else
    private(set) var callKit: CallKitManaging? = nil
    #endif

    #if canImport(PushKit) && os(iOS)
    /// PushKit VoIP push adapter. Initialized in initialize().
    private(set) var pushKit: PushKitProvider?
    #endif

    /// Currently-active CallKit call UUID (one at a time).
    private(set) var activeCallKitId: UUID?

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

        // W74: re-attempt the persistent WS the moment the app returns
        // to the foreground. iOS suspends URLSessionWebSocketTask while
        // backgrounded — by the time the user opens the app again the
        // socket is dead but `handleDisconnect()` may not have fired
        // yet (no `receive` failure delivered). Forcing a connect here
        // is idempotent: `connectPersistentSocket()` short-circuits if
        // the WS is already in `.connecting/.connected/.authenticated`.
        #if canImport(UIKit) && os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isAuthenticated else { return }
            // If the existing provider's socket is dead, drop it so
            // `connectPersistentSocket()` rebuilds the WS.
            if let live = self.liveProvider, live.persistentConnection.state == .disconnected {
                self.liveProvider = nil
            }
            self.connectPersistentSocket()
        }
        #endif

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
                case .red:
                    self.confidenceLevel = "red"
                case .yellow:
                    self.confidenceLevel = "yellow"
                case .green:
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

        // MARK: Bridge CallKit system actions back to CallService / AppState

        #if canImport(CallKit) && os(iOS)
        if let provider = callKit as? CallKitProvider {
            provider.onAnswerCall = { [weak self] uuid in
                guard let self = self else { return }
                await MainActor.run {
                    // User accepted incoming call from lock screen.
                    // Signal "user accepted" so the call transitions from ringing to active.
                    // Actual signalling (offer/answer) stays inside QAudionCallIntegration (USER WT).
                    self.isInCall = true
                    self.activeCallKitId = uuid
                }
            }
            provider.onEndCall = { [weak self] uuid in
                guard let self = self else { return }
                await MainActor.run {
                    self.endCall()
                }
            }
            provider.onMutedChanged = { [weak self] uuid, muted in
                guard let self = self else { return }
                await MainActor.run {
                    // Route through AppState.setMuted which forwards to CallService.
                    self.setMuted(muted)
                }
            }
        }

        // MARK: PushKit VoIP push registration
        // Registers for tokens so the day server picks option α/β/γ/δ, iOS is ready.
        self.pushKit = PushKitProvider(
            // W60: rimosso `[weak self]` non usato — il body del closure
            // logga solo il token, no riferimenti a self. Eliminava il
            // warning compile "variable 'self' was written to, but never
            // read" che spam-ava ogni Codemagic build.
            onTokenUpdate: { token in
                let hex = token.map { String(format: "%02hhx", $0) }.joined()
                // Stub: log token prefix. Actual server registration deferred until
                // spec §10.1 APNs option (α/β/γ/δ) is finalised.
                await MainActor.run {
                    print("[Q-Audion] PushKit VoIP token: \(hex.prefix(16))...")
                }
            },
            onIncomingCall: { [weak self] payload in
                guard let self = self else { return }
                await self.callKit?.reportIncomingCall(
                    uuid: payload.callId,
                    callerName: payload.callerName,
                    hasVideo: payload.hasVideo
                )
                await MainActor.run {
                    self.activeCallKitId = payload.callId
                    self.callContactId = payload.callerId
                    self.isVideoCall = payload.hasVideo
                }
            }
        )
        #endif

        if let token = authService.loadToken() {
            let backendConfig = BackendConfig(serverUrl: defaultServerUrl, accessToken: token)
            let provider = BCryptoBackendProvider(config: backendConfig)
            Task {
                do {
                    let profile = try await provider.accountApi.getProfile()
                    self.currentUserId = profile.userId
                    self.isAuthenticated = true
                    self.replayPendingTrackB()
                    // W74: open the long-lived WS so the server flips
                    // the user to `online`. Presence binding piggybacks
                    // on the same provider once the socket is up.
                    self.connectPersistentSocket()
                    self.bindPresenceAfterAuth()
                } catch {
                    authService.clearToken()
                    self.isAuthenticated = false
                }
            }
        }
    }

    func login(userId: String, credential: String) async {
        do {
            let creds = try await authService.login(
                phoneNumber: userId, password: credential, serverUrl: defaultServerUrl
            )
            currentUserId = creds.userId
            isAuthenticated = true
            errorMessage = nil
            replayPendingTrackB()
            // W74: open the long-lived WS so the server marks us online.
            connectPersistentSocket()
            bindPresenceAfterAuth()
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    /// Login with a PRE-COMPUTED `phone_hash` (lowercase hex SHA-256).
    /// Used exclusively by the fast-setup flow (`FastSetupAuth.run`),
    /// where the hash is derived from the opaque `phone_id` embedded in
    /// the QR — NOT from an E.164 phone number — and therefore must
    /// bypass `PhoneHash.hash` normalization.
    ///
    /// 1:1 parity with Android `LoginUseCase.invoke(phoneHash, ...)`,
    /// which the Android `FastSetupUseCase` calls directly.
    func loginWithPhoneHash(phoneHash: String, credential: String) async {
        do {
            let creds = try await authService.loginWithPhoneHash(
                phoneHash: phoneHash, password: credential, serverUrl: defaultServerUrl
            )
            currentUserId = creds.userId
            isAuthenticated = true
            errorMessage = nil
            replayPendingTrackB()
            // W74: open the long-lived WS so the server marks us online.
            connectPersistentSocket()
            bindPresenceAfterAuth()
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    /// W70: drain `PendingGroupInviteStore` chiamando `POST /groups/:id/join`
    /// per ogni pending. Best-effort, mai blocca l'UI. Chiamato al
    /// completamento di ogni transizione auth → success.
    private func replayPendingTrackB() {
        guard let sync = TrackBSyncService.from(self) else { return }
        Task { _ = await sync.replayPendingGroupInvites() }
    }

    /// W74: open and KEEP a persistent WebSocket connection so the
    /// server keeps the user marked as `online`. Idempotent — repeated
    /// calls with a live connection are a no-op. After the WS settles
    /// (`.connected` or `.authenticated`), `bindPresenceAfterAuth` is
    /// re-run so the presence subscriptions land on the live transport.
    ///
    /// Server side: `Hub.addClient` flips the user to "online" the
    /// moment the WS handshake completes; `Hub.removeClient` flips
    /// back to "offline" on disconnect. So the lifetime of `wsClient`
    /// IS the lifetime of the user's online status.
    private func connectPersistentSocket() {
        guard let token = authService.loadToken(), !token.isEmpty else { return }
        // Reuse the live provider when its WS is already connecting /
        // connected. Recreate when previously torn down or token rotated.
        if let existing = liveProvider {
            let s = existing.persistentConnection.state
            if s == .connecting || s == .connected || s == .authenticated {
                return
            }
        }
        let config = BackendConfig(serverUrl: serverUrl, accessToken: token)
        let provider = BCryptoBackendProvider(config: config)
        self.liveProvider = provider
        // W74: register inbound call handlers BEFORE the WS lands. The
        // server relays Android→iOS calls as `call_incoming`, NOT
        // `call_offer` (see bcrypto-server signaling/messages.go
        // MsgCallIncoming). Without this handler, every incoming call
        // is silently dropped at the WS dispatcher.
        wireIncomingCallHandlers(on: provider.getWebSocketClient())
        // Subscribe state listener so the UI can show "Connecting → Online".
        provider.persistentConnection.addStateListener { [weak self] state in
            DispatchQueue.main.async {
                self?.wsConnectionState = state
                if state == .connected || state == .authenticated {
                    // (re-)bind presence now that the transport is live —
                    // the previous provider may have been torn down on
                    // app suspend / token rotate, leaving subscribers
                    // stale.
                    self?.bindPresenceAfterAuth()
                }
            }
        }
        Task {
            do {
                try await provider.initialize()
                print("[AppState] persistent WS opened (online presence active)")
            } catch {
                print("[AppState] persistent WS open failed: \(error.localizedDescription)")
            }
        }
    }

    /// W74: register the WS dispatch handlers that turn server-relayed
    /// call signaling into CallKit + ring on the responder side. Three
    /// inbound types matter:
    ///   - `call_incoming` — peer started a call. Build a CXCallUpdate
    ///     and ask CallKit to ring + display the system call screen.
    ///   - `call_hangup` — the active call ended (peer hung up before
    ///     we picked up, or the server timed it out). Tell CallKit to
    ///     close the incoming-call UI so the system stops ringing.
    ///   - `call_cancel` — same shape as `call_hangup` but emitted when
    ///     the caller bailed before the peer answered (legacy alias).
    private func wireIncomingCallHandlers(on ws: BCryptoWebSocketClient) {
        ws.registerHandler(type: "call_incoming") { [weak self] _, data in
            guard let self = self else { return }
            let callIdStr = data["call_id"] as? String ?? ""
            let senderId = data["sender_id"] as? String ?? "Sconosciuto"
            let callType = data["call_type"] as? String ?? "audio"
            let callUUID = UUID(uuidString: callIdStr) ?? UUID()
            // CallKit must run from MainActor — its CXProvider state
            // machine refuses cross-thread mutations.
            DispatchQueue.main.async {
                Task {
                    await self.callKit?.reportIncomingCall(
                        uuid: callUUID,
                        callerName: senderId,
                        hasVideo: callType == "video"
                    )
                    await MainActor.run {
                        self.activeCallKitId = callUUID
                        self.callContactId = senderId
                        self.isVideoCall = (callType == "video")
                        self.callState = .ringing
                        self.isInCall = true
                    }
                }
            }
        }
        ws.registerHandler(type: "call_hangup") { [weak self] _, data in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let uuid = self.activeCallKitId else { return }
                let reasonString = data["reason"] as? String ?? "normal"
                let reason: CallEndReason
                switch reasonString {
                case "busy":      reason = .declined
                case "timeout":   reason = .unanswered
                case "error":     reason = .failed
                default:          reason = .remoteEnded
                }
                Task {
                    await self.callKit?.reportCallEnded(uuid: uuid, reason: reason)
                    await MainActor.run {
                        self.endCall()
                    }
                }
            }
        }
    }

    /// W72: bind the presence service to the live WS transport and
    /// subscribe the union of contacts + conversation peers so the UI
    /// can render online/offline dots reactively. Idempotent — calling
    /// twice with the same auth state is a no-op (the service rebinds
    /// to the same provider). Best-effort: failures are logged but don't
    /// block the auth flow.
    private func bindPresenceAfterAuth() {
        // W74: prefer the long-lived provider when present so the
        // presence subscriptions ride the SAME WS that keeps the user
        // marked online. Falls back to a fresh provider only when the
        // persistent socket failed to open.
        let provider: BCryptoBackendProvider
        if let live = liveProvider {
            provider = live
        } else {
            guard let token = authService.loadToken(), !token.isEmpty else { return }
            let config = BackendConfig(serverUrl: serverUrl, accessToken: token)
            provider = BCryptoBackendProvider(config: config)
        }
        presenceService.attach(provider: provider)
        // Initial subscription set: known contact userIds + recent calls.
        // Views that load additional userIds (chat list with full
        // history) call `presenceService.subscribe(userIds:)` themselves
        // to broaden the tracked set.
        let contacts = ContactsStore().load().map { $0.userId }
        let recents = recentCalls
        let union = Array(Set(contacts + recents)).filter { !$0.isEmpty }
        if !union.isEmpty {
            presenceService.subscribe(userIds: union)
        }
    }

    func logout() {
        authService.clearToken()
        engine?.destroySession()
        engine?.release()
        engine = nil
        // W74: tear down the persistent WS so the server flips us back
        // to `offline` immediately. Otherwise the connection lingers
        // until the next service restart and "online" flickers wrong.
        liveProvider?.persistentConnection.disconnect()
        liveProvider = nil
        wsConnectionState = .disconnected
        // W72: drop presence subscriptions + cached statuses so the next
        // login starts with a clean slate.
        presenceService.reset()
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
            // W67: wire WebSocket transport PRIMA di startCall così il
            // handler "audio_frame" è già registrato quando il peer
            // inizia a inviare e la capture.onFrame può immediatamente
            // route al wsClient. Best-effort: senza token ancora non
            // facciamo wiring (chiamata continua senza network audio,
            // ma HW DSP capture+playback restano comunque attivi via W66).
            if let token = authService.loadToken(), !token.isEmpty {
                let backendConfig = BackendConfig(
                    serverUrl: serverUrl,
                    accessToken: token
                )
                let provider = BCryptoBackendProvider(config: backendConfig)
                let ws = provider.getWebSocketClient()
                callService.wireTransport(
                    wsClient: ws,
                    peerUserId: contactId
                )
                // W72: pre-negotiation phase observers (caller side).
                // Mirror desktop CallController.CallProgressPhase. Lets
                // the UI distinguish "remote acked our offer" from
                // "remote is now ringing locally". See engine docs in
                // BCryptoWebSocketClient.swift (onCallProcessing /
                // onCallReady / onCallRing / onCallPeerOffline /
                // onCallCancel).
                ws.onCallProcessing = { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // Already `.connecting` by default — no transition
                        // needed but log so devs see the WS arrived.
                        print("[AppState] call_processing received — peer ack'd offer")
                    }
                }
                ws.onCallReady = { [weak self] _, _, _ in
                    DispatchQueue.main.async {
                        // Peer finished PQC setup; flip UI to "Ringing".
                        self?.callState = .ringing
                    }
                }
                ws.onCallRing = { _, _ in
                    // Server-side ack that caller has been notified —
                    // informational only, no state transition.
                    print("[AppState] call_ring server ack")
                }
                ws.onCallPeerOffline = { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.errorMessage = "Il destinatario non è raggiungibile."
                        self.callService.endCall()
                        self.callState = .ended
                        self.isInCall = false
                        self.callContactId = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.callState = .idle
                        }
                    }
                }
                ws.onCallCancel = { [weak self] _, reason in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if let r = reason, !r.isEmpty {
                            print("[AppState] call_cancel from caller: \(r)")
                        }
                        self.callService.endCall()
                        self.callState = .idle
                        self.isInCall = false
                        self.callContactId = nil
                    }
                }
            }

            try callService.startCall(engine: engine, contactId: contactId)

            // W72: integration responder-side wiring. When THIS device is
            // the responder receiving a call, the engine emits these
            // closures for us to relay over WS so the caller sees the
            // pre-negotiation phases. Set immediately after callService
            // builds the integration.
            if let integration = callService.callIntegration,
               let token = authService.loadToken(), !token.isEmpty {
                let backendConfig = BackendConfig(
                    serverUrl: serverUrl,
                    accessToken: token
                )
                let provider = BCryptoBackendProvider(config: backendConfig)
                integration.sendCallProcessing = { callId, callerId in
                    // Forward via the calling API (which routes through WS).
                    Task {
                        try? await provider.callingApi.sendCallProcessing(
                            callId: callId, callerId: callerId
                        )
                    }
                }
                integration.sendCallReady = { callId, callerId in
                    Task {
                        try? await provider.callingApi.sendCallReady(
                            callId: callId, callerId: callerId
                        )
                    }
                }
                integration.requestRingLocally = { [weak self] _, _ in
                    DispatchQueue.main.async {
                        // Fallback ring trigger when the responder UI
                        // didn't already start ringing locally.
                        self?.callState = .ringing
                    }
                }
                integration.onIncomingCallCancelled = { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.callService.endCall()
                        self.callState = .idle
                        self.isInCall = false
                        self.callContactId = nil
                    }
                }
            }

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
        activeCallKitId = nil
        txWaveformSamples = []
        rxWaveformSamples = []
        cipherWaveformSamples = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.callState = .idle
        }
    }

    func setMuted(_ muted: Bool) {
        // Forward to CallService which gates outgoing PCM before encryption.
        callService.setMuted(muted)
    }

    func setSpeaker(_ enabled: Bool) {
        // Audio routing is managed by the OS via AVAudioSession; no engine API needed.
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

            let backendConfig = BackendConfig(serverUrl: serverUrl, accessToken: authService.loadToken())
            let provider = BCryptoBackendProvider(config: backendConfig)
            try await provider.initialize()
            _ = try await provider.messageApi.sendMessage(recipientId: contactId, content: payload)
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
        let conversation = LegacyConversation(
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
