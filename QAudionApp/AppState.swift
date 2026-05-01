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
    /// Persistent backend provider. Internal-visible (was `private`)
    /// so ChatContainer can access `messageApi` for read-receipt
    /// emission (W84). Set by `attachPersistentBackend`; cleared on
    /// logout / token refresh.
    internal var liveProvider: BCryptoBackendProvider?
    /// W90: peer userId of the currently-open chat. ChatContainer.markRead
    /// sets this on .onAppear; ChatContainer deinits clear it. Used by
    /// `handleIncomingMessage` to suppress local-notification banners
    /// for the conversation the user is actively viewing — avoids the
    /// "banner pops up while I'm reading the message" UX gaffe.
    internal var activePeerUserId: String?

    /// W77: pairwise PSK first-contact handshake. Built in
    /// `connectPersistentSocket()` once the WS is up so `sendOpaque`
    /// rides the live transport. The closure stored in
    /// `ContactKeyExchange` calls `wsClient.sendOpaqueMessage(...)`
    /// directly — no per-call provider rebuild.
    private var contactKeyExchange: ContactKeyExchange?
    /// One-shot identity used for ECDH. Persisted across launches so
    /// peers see a stable `encryption_public` over QR / NFC. Only
    /// rebuilt by an explicit "Rotate key" action.
    private lazy var sovereignIdentity = SovereignIdentityManager()

    /// W75: cached PushKit VoIP token. PushKit emits this on first
    /// launch BEFORE the user is authenticated — we stash it here and
    /// retry the server POST after every auth-success transition. Once
    /// the registration succeeds, subsequent re-emits (rotation /
    /// reinstall) hit `registerVoipPushToken` directly.
    private var pendingVoipPushTokenHex: String?

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
        ) { _ in
            // The notification closure is `@Sendable` per the iOS 18+
            // signature; mutating main-actor-isolated state must hop
            // back through `Task { @MainActor in ... }`. We only capture
            // `self` once inside the Task to avoid the
            // "'self' defined but never used" warning that Xcode 26 emits
            // when the outer closure binds `[weak self]` and forwards.
            Task { @MainActor [weak self] in
                guard let self = self, self.isAuthenticated else { return }
                // If the existing provider's socket is dead, drop it so
                // `connectPersistentSocket()` rebuilds the WS.
                if let live = self.liveProvider,
                   live.persistentConnection.state == .disconnected {
                    self.liveProvider = nil
                }
                self.connectPersistentSocket()
            }
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
            onTokenUpdate: { [weak self] token in
                // W75: register the VoIP token with the server so the
                // dispatcher can wake the device for incoming calls when
                // the WS isn't live (app suspended / killed). Wire shape
                // matches `bcrypto-server/cmd/bcrypto-lite/account_apns_voip_token.go`:
                //   POST /api/v1/account/apns-voip-token
                //   { "voip_token": "<64 hex>", "bundle_id": "com.qaudion.app" }
                let hex = token.map { String(format: "%02hhx", $0) }.joined()
                await MainActor.run {
                    print("[Q-Audion] PushKit VoIP token: \(hex.prefix(16))...")
                    self?.registerVoipPushToken(hex: hex)
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
                    // W75: ship any cached PushKit token now that we
                    // have a JWT — calls survive app-killed state.
                    self.retryPendingVoipPushTokenRegistration()
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
            // W75: ship any cached PushKit token.
            retryPendingVoipPushTokenRegistration()
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
            // W75: ship any cached PushKit token.
            retryPendingVoipPushTokenRegistration()
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
        // W76: chat envelope dispatch — `msg_receive` / `msg_delivered` /
        // `msg_read` / `msg_typing`. Without these handlers the iOS app
        // sends WS frames in one direction only — incoming peer messages
        // are silently dropped at the dispatcher.
        wireIncomingChatHandlers(on: provider.getWebSocketClient())
        // W77: build the ContactKeyExchange now that we have a live WS.
        // Its `sendOpaque` closure rides the SAME transport so the QUAD
        // KEY_EXCHANGE_OFFER / ACCEPT frames land via `opaque_message`.
        // The handler for inbound `opaque_message` envelopes is wired
        // separately (`wireOpaqueMessageHandler`) and routes the parsed
        // QUAD frame back to ContactKeyExchange when it carries a key
        // exchange payload.
        let ws = provider.getWebSocketClient()
        let cke = ContactKeyExchange(
            identity: sovereignIdentity,
            vault: SovereignKeyVault(),
            sendOpaque: { recipientId, wire in
                ws.sendOpaqueMessage(recipientId: recipientId, payload: wire)
            }
        )
        cke.onKeyExchanged = { (contactId: String, _: String, fingerprint: String) in
            print("[AppState] Pairwise PSK derived for \(contactId.prefix(8))… fp=\(fingerprint.prefix(8))…")
        }
        cke.onError = { (contactId: String, error: Error) in
            print("[AppState] PSK exchange error for \(contactId.prefix(8))…: \(error)")
        }
        self.contactKeyExchange = cke
        wireOpaqueMessageHandler(on: ws, cke: cke)
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

    /// W75: re-attempt the PushKit registration after auth-success.
    /// Called from the 3 auth-success entry points so the cached token
    /// (deferred while unauthenticated) lands the moment we have a JWT.
    private func retryPendingVoipPushTokenRegistration() {
        guard let hex = pendingVoipPushTokenHex else { return }
        registerVoipPushToken(hex: hex)
    }

    /// W75: ship the PushKit VoIP token to the bcrypto-server so the
    /// dispatcher can wake the device for incoming calls when the WS
    /// isn't live (app suspended or killed). The server endpoint is
    /// `POST /api/v1/account/apns-voip-token` with body
    /// `{voip_token: "<64 hex>", bundle_id: "com.qaudion.app"}` —
    /// matches `cmd/bcrypto-lite/account_apns_voip_token.go` line 47.
    ///
    /// Best-effort: any non-2xx is logged but not surfaced to the UI.
    /// PushKit re-emits the token on every app launch and on rotation,
    /// so a transient registration failure recovers automatically the
    /// next time the user opens the app.
    private func registerVoipPushToken(hex: String) {
        // Validate length AND hex-only chars. Without this an arbitrary
        // 64-char string (e.g. all 'z') would be accepted and the
        // server would 400 — silent for the user. Flagged by external
        // review (OpenRouter glm-5.1).
        guard hex.count == 64,
              hex.allSatisfy({ $0.isHexDigit }) else {
            print("[AppState] PushKit token invalid (len=\(hex.count) hex=\(hex.allSatisfy { $0.isHexDigit }))")
            return
        }
        // Always cache so the next auth-success can retry. Cleared on
        // successful HTTP 2xx response IF the cached value still
        // matches THIS request — guards against a race where a second
        // PushKit emit overwrites the cache while the first request
        // is in-flight.
        pendingVoipPushTokenHex = hex
        guard let token = authService.loadToken(), !token.isEmpty else {
            print("[AppState] PushKit register deferred — not authenticated yet (cached for retry)")
            return
        }
        // Build URL via URLComponents so the path isn't percent-encoded
        // by `appendingPathComponent` (which can produce /api%2Fv1%2F…
        // on some iOS versions, leading to 404).
        guard var components = URLComponents(string: serverUrl) else { return }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/api/v1/account/apns-voip-token"
        guard let url = components.url else { return }

        let bundleId = Bundle.main.bundleIdentifier ?? "com.qaudion.app"
        let body: [String: Any] = [
            "voip_token": hex,
            "bundle_id": bundleId,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        Task { [weak self, hex] in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    if (200..<300).contains(http.statusCode) {
                        print("[AppState] PushKit VoIP token registered (\(hex.prefix(16))…)")
                        await MainActor.run {
                            // Only clear if cache still holds THIS token.
                            // If a second PushKit emit raced ahead the
                            // cache holds the new hex — must NOT wipe it.
                            if self?.pendingVoipPushTokenHex == hex {
                                self?.pendingVoipPushTokenHex = nil
                            }
                        }
                    } else {
                        print("[AppState] PushKit register HTTP \(http.statusCode)")
                        // Cache stays — `retryPendingVoipPushTokenRegistration()`
                        // will fire next foreground/auth event.
                        await Self.scheduleRetry(self: self)
                    }
                }
            } catch {
                print("[AppState] PushKit register error: \(error.localizedDescription)")
                await Self.scheduleRetry(self: self)
            }
        }
    }

    /// Schedule a single retry tick 30s out so transient network
    /// failures (Wi-Fi flap, brief server hiccup) don't strand the
    /// VoIP token in `pendingVoipPushTokenHex` until the next auth
    /// transition.
    private static func scheduleRetry(self ref: AppState?) async {
        try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
        await MainActor.run {
            ref?.retryPendingVoipPushTokenRegistration()
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
            // W77: bind the inbound call_id on the calling impl so the
            // subsequent `sendCallAnswer` / `sendCallHangup` envelopes
            // use the SAME id the server registered for this call.
            // Without this, answer/hangup would mint a brand-new UUID
            // and the server's call state machine would drop them.
            if !callIdStr.isEmpty,
               let provider = self.liveProvider,
               let calling = provider.callingApi as? BCryptoCallingApiImpl {
                calling.bindIncomingCallId(callIdStr)
            }
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
                case "error":     reason = .failed("error")
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

    /// W76: register the chat envelope dispatch handlers. Wire shapes
    /// match `bcrypto-server/internal/signaling/messages.go`:
    ///
    ///   - `msg_receive`     {message_id, sender_id, encrypted_payload, msg_type, server_ts, client_msg_id}
    ///   - `msg_delivered`   {message_ids: []}
    ///   - `msg_read`        {sender_id, message_ids: []}
    ///   - `msg_typing`      {recipient_id, is_typing}      // server overwrites recipient with sender on relay
    ///
    /// Today the handlers persist incoming text messages into the
    /// `ConversationStore` so the chat UI shows them on next refresh,
    /// and broadcast NotificationCenter events for delivery / read /
    /// typing so the active `ChatContainer` can update without a full
    /// re-fetch. Decryption is delegated to `ChatMessageSendService`'s
    /// inverse path (via `MessageCrypto.decrypt`) so the AAD stays
    /// bound to the (sender, recipient, msgId) triplet — protects
    /// against ciphertext replay across pairs.
    private func wireIncomingChatHandlers(on ws: BCryptoWebSocketClient) {
        ws.registerHandler(type: "msg_receive") { [weak self] _, data in
            guard let self = self else { return }
            // Server-injected fields. `sender_id` is authoritative
            // (server overwrites it on the way out from the producer).
            guard let senderId = data["sender_id"] as? String,
                  !senderId.isEmpty,
                  let cipherB64 = data["encrypted_payload"] as? String,
                  let serverMsgId = data["message_id"] as? String,
                  let cipher = Data(base64Encoded: cipherB64) else {
                print("[AppState] msg_receive missing required fields: \(data.keys)")
                return
            }
            DispatchQueue.main.async {
                self.handleIncomingMessage(
                    senderId: senderId,
                    serverMsgId: serverMsgId,
                    cipher: cipher,
                    clientMsgId: data["client_msg_id"] as? String
                )
            }
        }
        ws.registerHandler(type: "msg_delivered") { [weak self] _, data in
            guard let ids = data["message_ids"] as? [String], !ids.isEmpty else { return }
            DispatchQueue.main.async {
                self?.handleDeliveryReceipts(ids: ids)
            }
        }
        ws.registerHandler(type: "msg_read") { [weak self] _, data in
            guard let ids = data["message_ids"] as? [String], !ids.isEmpty else { return }
            let senderId = data["sender_id"] as? String ?? ""
            DispatchQueue.main.async {
                self?.handleReadReceipts(senderId: senderId, ids: ids)
            }
        }
        ws.registerHandler(type: "msg_typing") { [weak self] _, data in
            guard let senderId = data["sender_id"] as? String,
                  let isTyping = data["is_typing"] as? Bool else { return }
            DispatchQueue.main.async {
                self?.handleTypingIndicator(senderId: senderId, isTyping: isTyping)
            }
        }
    }

    /// Persist an incoming peer message to the local store + post a
    /// NotificationCenter event so any active `ChatContainer` for the
    /// peer refreshes. Decryption uses the same MessageCrypto wire
    /// format as the send path; if decryption fails we still persist
    /// a placeholder ("[messaggio cifrato non leggibile]") so the
    /// conversation history at least shows that something arrived —
    /// helps debugging when peers are on different protocol versions.
    private func handleIncomingMessage(
        senderId: String,
        serverMsgId: String,
        cipher: Data,
        clientMsgId: String?
    ) {
        let crypto = MessageCrypto()
        let vault = SovereignKeyVault()
        let plaintext: String
        // W77: prefer the pairwise PSK stored under the
        // `auto:<prefix>:<peerId>` name by ContactKeyExchange. Falls
        // back to the bare peerId (legacy) and finally to the
        // deterministic shared-secret fallback.
        let psk: Data
        let prefix = senderId.count > 8 ? String(senderId.prefix(8)) : senderId
        let autoName = "auto:\(prefix):\(senderId)"
        if let stored = (try? vault.loadPsk(name: autoName)) ?? nil, !stored.isEmpty {
            psk = stored
        } else if let stored = (try? vault.loadPsk(name: senderId)) ?? nil, !stored.isEmpty {
            psk = stored
        } else {
            // Mirror the same fallback shape used by ChatMessageSendService.
            // Symmetric in (peer, self) so both sides derive the same key
            // when no pairwise PSK has been negotiated yet.
            let pair = [senderId, currentUserId ?? ""].sorted().joined(separator: ":")
            let digest = SHA256.hash(data: Data("qaudion-fallback-psk:\(pair)".utf8))
            psk = Data(digest)
        }
        // W80: capture the RAW decrypted plaintext separately from the
        // friendly UI rendering so we can detect qfile markers and
        // kick off the receive pipeline. Without this split, the
        // marker JSON would already have been replaced by the
        // "(download in arrivo)" placeholder before we get to parse.
        var decryptedRaw: String = ""
        do {
            let pt = try crypto.decrypt(
                wireBlob: cipher,
                psk: psk,
                senderId: senderId,
                recipientId: currentUserId ?? "",
                msgId: clientMsgId ?? serverMsgId
            )
            decryptedRaw = String(data: pt, encoding: .utf8) ?? "[messaggio cifrato non leggibile]"
            // W78: cross-platform attachment placeholder. Desktop and
            // Android send voice notes / files via the qa_ctl:1
            // `attach_announce` envelope (XChaCha20-Poly1305 + TUS).
            // iOS does not yet implement that download/decrypt path
            // (deferred until the engine ships the Double Ratchet
            // chain-key snapshot needed for parity), so when one of
            // those envelopes arrives we surface a friendly placeholder
            // instead of pasting raw JSON into the chat history. Same
            // shape for `qfile` markers (legacy iOS-internal file
            // transfer) so a stray Desktop-FileTransfer marker doesn't
            // leak as text either.
            // W86: route qa_ctl:1 control envelopes (delete / edit)
            // BEFORE persisting as a new inbound row. These mutate
            // an EXISTING row keyed by clientMsgId rather than
            // appending. A successful route returns early — the chat
            // refresh notification fires from inside the route helper.
            if let env = try? ChatControlEnvelope.parse(decryptedRaw) {
                handleControlEnvelope(env, senderId: senderId)
                return
            }
            plaintext = Self.renderInboundPlaintext(decryptedRaw)
        } catch {
            print("[AppState] msg_receive decrypt failed from \(senderId): \(error)")
            plaintext = "[messaggio cifrato non leggibile]"
            // W77b: auto-rekey on decrypt failure. Same pattern as
            // qaudion-desktop's `MessageService.on('needRekey')` → fires
            // a fresh KEY_EXCHANGE_OFFER with `force=true` so the next
            // message from this peer rides a freshly-derived PSK. Saves
            // the user from having to manually re-pair when keychains
            // get desynced (e.g. after one side reinstalls).
            triggerKeyExchange(with: senderId, force: true)
        }

        // Persist into the conversation store. The conversation is
        // keyed by peerUserId — find the matching conv (1:1) or create
        // one on the fly so first-contact messages still land.
        let store = ConversationStore()
        let existing = store.loadConversations().first(where: { $0.peerUserId == senderId })
        let conv: Conversation
        if let e = existing {
            conv = e
        } else {
            conv = Conversation(
                id: UUID(),
                peerUserId: senderId,
                peerDisplayName: senderId, // resolved later via contacts lookup
                lastMessagePreview: plaintext,
                lastActivity: Date(),
                unreadCount: 1,
                pinned: false,
                kind: .oneToOne
            )
            store.upsertConversation(conv)
        }
        let msgUUID = UUID()
        // W80: voice-note receive — if the decrypted plaintext is a
        // `qfile` v3 marker (carrying a download_claim), persist the
        // duration up front so the row already shows "🎤 Nota vocale
        // (4.2s) (download in arrivo)", and kick off the async
        // download+decrypt that flips the row to a playable bubble
        // once the M4A lands in the cache.
        var initialMediaDur: Int64? = nil
        var pendingMarker: FileTransfer.FileMarker? = nil
        if !decryptedRaw.isEmpty,
           let marker = FileTransfer.tryParseMarker(text: decryptedRaw),
           marker.qfile.downloadClaim != nil {
            initialMediaDur = marker.qfile.durationMs
            pendingMarker = marker
        }
        let msg = Message(
            id: msgUUID,
            conversationId: conv.id,
            direction: .incoming,
            plaintext: plaintext,
            sentAt: Date(),
            deliveredAt: Date(),
            readAt: nil,
            status: .delivered,
            senderUserId: senderId,
            // W78: persist the server id on inbound messages too so any
            // future cross-device sync (read receipts emitted by a
            // companion device, e.g. desktop session) can match the row.
            serverMessageId: serverMsgId,
            mediaLocalPath: nil,
            mediaDurationMs: initialMediaDur,
            // W82: route bubble UI by mime (audio/* → voice player,
            // image/* → image preview). Stamped up-front from the
            // marker so the row already shows the right placeholder.
            mediaMimeType: pendingMarker?.qfile.mime,
            // W86: persist the sender-generated clientMsgId so future
            // qa_ctl:1 envelopes (edit/delete/reaction) targeting this
            // message can find the row. Without this, peers can't edit
            // or delete what they previously sent us.
            clientMsgId: clientMsgId
        )
        store.appendMessage(msg)
        // W83: bump conversation preview + activity + unread so the
        // chat list reflects new messages and the count badge shows.
        // Use the already-rendered `plaintext` (placeholder for media)
        // so cross-platform attachments don't leak raw JSON to the list.
        // W89: muted conversations skip the unread bump so the badge
        // stays clean (the message still lands and re-orders the list).
        let isMuted = conv.muted ?? false
        store.recordNewMessage(
            conversationId: conv.id,
            lastMessagePreview: plaintext,
            lastActivity: Date(),
            incrementUnread: !isMuted
        )
        // W90: local-notification banner for inbound messages.
        // Suppression rules:
        //   - skip if conversation is muted (W89).
        //   - skip if the user is currently viewing this peer's chat
        //     (activePeerUserId matches the sender) — they already
        //     see the message in the open chat, banner is redundant.
        //   - else fire the banner so a backgrounded chat list still
        //     surfaces the new message.
        if !isMuted && activePeerUserId != senderId {
            let title = conv.peerDisplayName.isEmpty ? senderId : conv.peerDisplayName
            // Cap body at ~120 chars so multi-line essays don't blow
            // up the banner. plaintext is already the friendly render.
            let bodyText: String
            if plaintext.count > 120 {
                bodyText = String(plaintext.prefix(120)) + "…"
            } else {
                bodyText = plaintext
            }
            Task { @MainActor in
                await NotificationCenterService.shared.scheduleLocal(
                    category: .messageDelivered,
                    title: title,
                    body: bodyText,
                    userInfo: [
                        "conversationId": conv.id.uuidString,
                        "peerUserId":     senderId,
                    ],
                    delay: 0.1
                )
            }
        }
        // W80: async download + decrypt + cache. We kick this off here
        // so the cache is populated by the time the user opens the
        // chat. The send path attaches a recipient capability claim,
        // which the receiver redeems via the X-Download-* headers.
        if let marker = pendingMarker {
            Task { [weak self, msgUUID, convId = conv.id, senderId] in
                guard let self = self else { return }
                let receiver = ChatVoiceNoteReceiver(appState: self)
                do {
                    let cacheURL = try await receiver.fetch(
                        marker: marker, senderId: senderId
                    )
                    let friendly = ChatVoiceNoteReceiver.renderReceivedText(marker: marker)
                    await MainActor.run {
                        ConversationStore().setMediaInfo(
                            localId: msgUUID,
                            conversationId: convId,
                            plaintext: friendly,
                            mediaLocalPath: cacheURL.path,
                            mediaDurationMs: marker.qfile.durationMs,
                            mediaMimeType: marker.qfile.mime
                        )
                        NotificationCenter.default.post(
                            name: AppState.chatRefreshNotification,
                            object: nil,
                            userInfo: ["peerUserId": senderId, "conversationId": convId]
                        )
                    }
                } catch {
                    print("[AppState] attachment receive failed from \(senderId): \(error)")
                    // Leave the placeholder text in place; user can
                    // tap a retry CTA in a future patch (snackbar
                    // not surfaced today to avoid noise on transient
                    // network blips).
                }
            }
        }
        // Auto-ack delivery so the sender flips its UI to "delivered".
        // Best-effort fire-and-forget. ChatContainer's user-mark-as-read
        // sends `msg_read` separately when the screen is open.
        if let provider = liveProvider {
            Task {
                try? await provider.messageApi.sendDeliveryReceipt(messageId: serverMsgId)
            }
        }
        // Notify any open ChatContainer to refresh from the store.
        NotificationCenter.default.post(
            name: AppState.chatRefreshNotification,
            object: nil,
            userInfo: ["peerUserId": senderId, "conversationId": conv.id]
        )
    }

    /// W86: route a `qa_ctl:1` control envelope (delete / edit) to the
    /// matching local row, applying the spoof check. Spoof rule: only
    /// the original sender of `target` may edit or delete. For inbound
    /// rows this means `original.senderUserId == envelopeSenderId`.
    /// For outbound rows (peer trying to modify OUR message) the
    /// envelope is rejected outright.
    private func handleControlEnvelope(_ env: ChatControlEnvelope,
                                       senderId envelopeSenderId: String) {
        let store = ConversationStore()
        let target: String
        switch env {
        case .delete(let t, _): target = t
        case .edit(let t, _, _): target = t
        case .reaction(let t, _, _): target = t
        }
        guard let (convId, original) = store.findByClientMsgId(target) else {
            print("[AppState] qa_ctl envelope: target \(target.prefix(8))… not found")
            return
        }
        // W87: reactions DON'T require a spoof check — any peer can
        // react to any message (Desktop/Android parity). Only the
        // delete/edit variants enforce origin matching.
        if case .reaction(_, let emoji, _) = env {
            // Toggle for the envelope's sender — if they previously
            // reacted with this emoji, the toggle removes it; otherwise
            // adds it.
            _ = store.applyReactionToggleByClientMsgId(
                target, userId: envelopeSenderId, emoji: emoji
            )
            NotificationCenter.default.post(
                name: AppState.chatRefreshNotification,
                object: nil,
                userInfo: ["peerUserId": envelopeSenderId, "conversationId": convId]
            )
            return
        }
        // delete / edit spoof check.
        if original.direction == .outgoing {
            print("[AppState] qa_ctl envelope: peer attempted to modify our outbound message — rejected")
            return
        }
        if original.senderUserId != envelopeSenderId {
            print("[AppState] qa_ctl envelope: sender mismatch (envelope=\(envelopeSenderId), original=\(original.senderUserId ?? "?")) — rejected")
            return
        }
        // Apply.
        let applied: Bool
        switch env {
        case .delete:
            applied = store.applyDeleteByClientMsgId(target)
        case .edit(_, let newBody, _):
            applied = store.applyEditByClientMsgId(target, newPlaintext: newBody)
        case .reaction:
            applied = false  // handled above
        }
        guard applied else { return }
        NotificationCenter.default.post(
            name: AppState.chatRefreshNotification,
            object: nil,
            userInfo: ["peerUserId": envelopeSenderId, "conversationId": convId]
        )
    }

    /// Mark the locally-stored copies of delivered messages as
    /// `.delivered` so the sender's UI flips the receipt icon.
    /// W78: server↔client id reconciliation now wired. ChatContainer
    /// stamps the server id on each outbound message after the WS ack
    /// (`ChatMessageSendService.Outcome.delivered(serverMessageId:)`),
    /// so we can look up the row directly by server id here.
    private func handleDeliveryReceipts(ids: [String]) {
        let store = ConversationStore()
        let now = Date()
        var matchedAny = false
        for sid in ids {
            if store.updateStatusByServerId(serverMessageId: sid,
                                            newStatus: .delivered,
                                            deliveredAt: now) {
                matchedAny = true
            }
        }
        if matchedAny {
            NotificationCenter.default.post(
                name: AppState.chatRefreshNotification,
                object: nil,
                userInfo: ["deliveredServerIds": ids]
            )
        }
    }

    /// Mark the locally-stored messages as `.read` for the given sender.
    /// W78: same server-id reconciliation as the delivery receipts path.
    private func handleReadReceipts(senderId: String, ids: [String]) {
        let store = ConversationStore()
        let now = Date()
        var matchedAny = false
        for sid in ids {
            if store.updateStatusByServerId(serverMessageId: sid,
                                            newStatus: .read,
                                            readAt: now) {
                matchedAny = true
            }
        }
        if matchedAny {
            NotificationCenter.default.post(
                name: AppState.chatRefreshNotification,
                object: nil,
                userInfo: ["readSenderId": senderId, "readServerIds": ids]
            )
        }
    }

    /// W78: render incoming chat plaintext, replacing cross-platform
    /// attachment envelopes with a friendly placeholder until iOS
    /// ships the matching download/decrypt path (Wave 2D-5c port).
    /// Today we recognize:
    ///   - `qa_ctl:1` `attach_announce` (Desktop / Android voice notes
    ///     and file shares) — XChaCha20-Poly1305 + TUS, requires the
    ///     Double Ratchet chain-key snapshot iOS doesn't expose yet.
    ///   - `qfile` v2 marker (legacy iOS-internal FileTransfer) — same
    ///     placeholder, since the receive UI hasn't been wired yet.
    /// Anything else is returned as-is.
    ///
    /// **DoS guard**: parsers walk JSON, so cap the input to 64 KiB.
    /// A regular chat message is well under 1 KiB; voice-note envelopes
    /// (with base64 sha256 + uuid + a few hundred bytes of metadata)
    /// stay under 2 KiB. 64 KiB is comfortably above the worst-case
    /// legitimate envelope and defangs a malicious peer crafting a
    /// pathological JSON to chew CPU on the receiver.
    static func renderInboundPlaintext(_ raw: String) -> String {
        guard raw.utf8.count <= 64 * 1024 else { return raw }
        // attach_announce path — qa_ctl:1 marker.
        // `try? parse` collapses the Optional<Optional<…>> down to a
        // single Optional, so a single `if let` is enough; the previous
        // `let env = env` shadowing pattern errored because the inner
        // bind sees a non-optional value.
        if let env = try? AttachAnnounceEnvelope.parse(raw) {
            let mime = env.att.mime
            if mime.hasPrefix("audio/") {
                if let dur = env.att.durationMs, dur > 0 {
                    let secs = Double(dur) / 1000.0
                    return String(format: "🎤 Nota vocale (%.1fs) — supporto cross-platform in arrivo", secs)
                }
                return "🎤 Nota vocale — supporto cross-platform in arrivo"
            }
            if mime.hasPrefix("image/") {
                return "🖼️ Immagine — supporto cross-platform in arrivo"
            }
            if mime.hasPrefix("video/") {
                return "🎬 Video — supporto cross-platform in arrivo"
            }
            return "📎 Allegato — supporto cross-platform in arrivo"
        }
        // qfile legacy marker — iOS-internal FileTransfer.
        if let marker = FileTransfer.tryParseMarker(text: raw) {
            let mime = marker.qfile.mime
            if mime.hasPrefix("audio/") {
                return "🎤 Nota vocale (download in arrivo)"
            }
            return "📎 \(marker.qfile.name) (download in arrivo)"
        }
        return raw
    }

    /// Surface peer typing state. `ChatContainer` picks this up via
    /// the same NotificationCenter channel and flips its `isPeerTyping`
    /// flag. Auto-clears after 5s if no `is_typing=false` arrives.
    private func handleTypingIndicator(senderId: String, isTyping: Bool) {
        NotificationCenter.default.post(
            name: AppState.chatTypingNotification,
            object: nil,
            userInfo: ["senderId": senderId, "isTyping": isTyping]
        )
    }

    /// Channel for chat envelope events relayed from the WS dispatcher
    /// to any `ChatContainer` currently displayed. The container
    /// subscribes in `attach(appState:)` and unsubscribes on dealloc.
    static let chatRefreshNotification = Notification.Name("qaudion.chat.refresh")
    static let chatTypingNotification = Notification.Name("qaudion.chat.typing")

    /// W77: dispatch inbound `opaque_message` envelopes. The QUAD frame
    /// inside the payload carries either:
    ///   - KEY_EXCHANGE_OFFER  → derive PSK + reply with ACCEPT
    ///   - KEY_EXCHANGE_ACCEPT → derive PSK only (no reply)
    ///   - other capability frames (already handled elsewhere)
    /// Routes to `ContactKeyExchange.handleOffer/handleAccept` so the
    /// pairwise PSK handshake completes without explicit UI action.
    private func wireOpaqueMessageHandler(on ws: BCryptoWebSocketClient, cke: ContactKeyExchange) {
        ws.registerHandler(type: "opaque_message") { _, data in
            guard let senderId = data["sender_id"] as? String,
                  !senderId.isEmpty,
                  let blobB64 = data["data"] as? String,
                  let blob = Data(base64Encoded: blobB64) else {
                return
            }
            // Parse the QUAD frame using the engine's capability decoder.
            guard let decoded = QAudionCapabilityExchange.parse(blob) else {
                print("[AppState] opaque_message from \(senderId.prefix(8))… not a valid QUAD frame")
                return
            }
            switch decoded {
            case .keyExchangeOffer(let pub):
                Task { await cke.handleOffer(senderId: senderId, peerPubKey: pub) }
            case .keyExchangeAccept(let pub):
                Task { await cke.handleAccept(senderId: senderId, peerPubKey: pub) }
            default:
                // Other capability frames (offer/accept/audio/etc.) are
                // routed by the call/audio path elsewhere — ignore here
                // unless the engine adds first-class support.
                break
            }
        }
    }

    /// W77: public hook to trigger the first-contact PSK handshake with a
    /// peer. Called from contact-add flows after a QR/NFC payload has
    /// been successfully decoded — the resulting OFFER carries this
    /// device's X25519 public key; the peer's response (ACCEPT) is
    /// handled automatically by `wireOpaqueMessageHandler`.
    /// Fire-and-forget — failure is logged, never surfaced to the UI.
    func triggerKeyExchange(with contactId: String, force: Bool = false) {
        guard let cke = contactKeyExchange else {
            print("[AppState] triggerKeyExchange called before WS up — pending")
            return
        }
        Task {
            do {
                _ = try await cke.initiate(contactId: contactId, force: force)
                print("[AppState] KEY_EXCHANGE_OFFER sent to \(contactId.prefix(8))…")
            } catch {
                print("[AppState] triggerKeyExchange failed: \(error)")
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
