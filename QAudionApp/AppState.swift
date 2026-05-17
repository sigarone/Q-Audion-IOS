import Foundation
import SwiftUI
import CryptoKit
import QAudionEngine
#if canImport(WebRTC)
// W412: needed by the W411 RTCIceServer references inside the
// WebRTC bridge code paths. The QAudionEngine extension types
// (QAudionWebRtcCallController.iceServerOverride: [RTCIceServer]?)
// require the symbol to be in scope at the call site too.
import WebRTC
#endif

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
    /// W444: server-assigned short PBX extension for the logged-in user (e.g. "103").
    /// Persisted to UserDefaults key "currentUserDialExtension" so the SettingsScreen
    /// hero card and caller-id display show the real short number immediately on
    /// launch, before the next getProfile() round-trip completes.
    /// Populated by the startup getProfile() path and by AccountSettingsContainer.loadFromServer().
    @Published var currentUserDialExtension: String?
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
    /// W94: pending chat deep link. Set by the notification-tap
    /// handler (NotificationCenterService.onNotificationTap) when the
    /// user taps a `.messageDelivered` banner. ChatListScreen observes
    /// this and pushes the matching chat detail onto the nav stack;
    /// once consumed it's reset to nil.
    @Published var pendingDeepLinkConversationId: UUID?

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
    /// PQC session key for the active call, used to derive the in-call
    /// 6-PGP-word SAS via [ComputeSasUseCase]. Set by the call setup
    /// path once the ML-KEM-1024 handshake completes; cleared on
    /// `endCall()`. While nil the SAS panel stays hidden in the UI
    /// (`callSasWords` returns empty).
    ///
    /// Cross-platform contract: this is the same shared secret the
    /// Android peer feeds into its `ComputeSasUseCase` — see
    /// `SasConstants.salt = "qaudion-sas-v1"` /
    /// `SasConstants.infoWords = "sas-words-v1"`. Drift here would
    /// silently diverge the two-peer ceremony.
    @Published var callPqcSessionKey: Data?
    /// W366: GroupCallController bound to the live audio pipeline.
    /// Lazy-init via `ensureGroupCallController(_:)` — one controller
    /// per AppState, reused across calls.
    var groupCallController: GroupCallController?
    /// W391: live video pipeline for the active 1:1 video call.
    /// Created in startCall(video:true), stopped in endCall. Held by
    /// AppState (not by the View) so SwiftUI re-creation doesn't tear
    /// down the AVCaptureSession mid-call.
    @Published var videoPipeline: VideoCallPipeline?
    /// W398: ABR controller bound to the active video pipeline.
    /// Co-lifecycled with videoPipeline.
    private var abrController: AbrController?
    /// W396: responder-side QAudionCallIntegration. Lazy-created on
    /// inbound `call_incoming` BEFORE the user accepts on CallKit so
    /// we have somewhere to land the early PQC OFFER opaque_message.
    /// Once landed, encapsulate fires + ML-KEM secret is forwarded to
    /// the broker via onPqcSessionKeyEstablished. This unblocks W389
    /// for the responder side (was previously caller-only).
    private var responderCallIntegration: QAudionCallIntegration?
    /// W372: NotificationCenter observer guard — only register the
    /// group-chat fan-out listener once per AppState lifetime.
    private var groupFanOutWired: Bool = false
    /// W348: shared TURN credentials cache. Lazy-initialised the first
    /// time a WebRTC call needs ICE servers, then reused across calls
    /// (the RelayCredentialsProvider actor coalesces concurrent
    /// refreshes and re-uses the cached bundle until it's within
    /// 5 minutes of expiry).
    private var _relayProvider: RelayCredentialsProvider?
    func ensureRelayProvider() -> RelayCredentialsProvider? {
        guard let provider = liveProvider else { return nil }
        if let existing = _relayProvider { return existing }
        let p = RelayCredentialsProvider(api: provider.callingApi)
        _relayProvider = p
        return p
    }
    /// W347: WebRTC bridge for the active call. Lives only for the
    /// duration of one call; reset to nil on `endCall()`. Typed as
    /// `Any?` because the QAudionWebRtcCallController class is gated
    /// on `canImport(WebRTC)` — using Any here lets the AppState
    /// header compile even on hosts where the WebRTC XCFramework
    /// hasn't been resolved yet.
    var webRtcController: Any?
    /// Remote video track delivered by the WebRTC stack when the peer
    /// sends video via RTP (Android interop path). Typed as Any? so the
    /// header compiles without a WebRTC import at top level. At runtime
    /// this is always RTCVideoTrack or nil. VideoCallView reads it to
    /// render the remote feed via WebRTCRemoteVideoView when no BCrypto
    /// WS video pipeline is active (i.e. iOS↔Android calls).
    @Published var remoteWebRtcVideoTrack: Any?

    /// Commit 540b79c0 parity — peer's advertised SFrame capability tags
    /// captured from the latest `call_incoming` envelope. Forwarded to
    /// the WebRTC controller in `handleIncomingWebRtcOffer` once the
    /// controller is built. Reset back to `nil` when the call ends.
    /// `nil` = legacy peer (no `capabilities` field on the wire).
    var pendingPeerCapabilities: [String]?

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
    @Published var backendMode: String = "bcrypto_only"  // "bcrypto_only" — only the BCrypto backend is supported

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

    /// UUID string of the PersistentCallRecord for the current call.
    /// Set in startCall (outgoing) and wireIncomingCallHandlers (incoming).
    /// Cleared after endCall() writes the end timestamp.
    var activeOutgoingRecordId: String?

    private var defaultServerUrl: String { serverUrl }

    /// Build a BackendConfig for `serverUrl` with cert pinning enabled.
    /// All production network paths MUST use this helper (IMPORTANT-2a).
    /// Pins Let's Encrypt E8 + ISRG Root X1 — survives leaf cert rotation.
    private func pinnedConfig(token: String? = nil,
                               refreshToken: String? = nil,
                               userId: String? = nil) -> BackendConfig {
        BackendConfig(
            serverUrl: serverUrl,
            accessToken: token,
            refreshToken: refreshToken,
            userId: userId,
            certPinSha256B64: PinnedServerHost.certChainPins
        )
    }

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

        // W417 — start always-on telemetry pump. Pass primitive
        // serverUrl + closures (NOT AppState directly — see
        // LiveLogStreamer.swift header + CLAUDE.md "Hard-won lesson 16").
        LiveLogStreamer.shared.start(
            serverUrl: serverUrl,
            getToken: { [weak self] in self?.authService.loadToken() },
            getUserId: { [weak self] in self?.currentUserId }
        )

        // W94: wire chat-message notification taps to pendingDeepLinkConversationId
        // so the chat list can pick up and navigate. Idempotent — re-init
        // overwrites the closure with a fresh AppState capture.
        NotificationCenterService.shared.onNotificationTap = { [weak self] category, info in
            guard category == .messageDelivered else { return }
            guard let convIdStr = info["conversationId"],
                  let convId = UUID(uuidString: convIdStr) else { return }
            DispatchQueue.main.async {
                self?.pendingDeepLinkConversationId = convId
            }
        }

        // W74: re-attempt the persistent WS the moment the app returns
        // to the foreground. iOS suspends URLSessionWebSocketTask while
        // backgrounded — by the time the user opens the app again the
        // socket is dead but `handleDisconnect()` may not have fired
        // yet (no `receive` failure delivered).
        //
        // 2026-05-08 hardening: the previous version only rebuilt the
        // provider when `state == .disconnected`. iOS can suspend the
        // task without flipping that state — the local machine still
        // says `.authenticated` but the URLSessionWebSocketTask is
        // dead. The next call_offer hits `task == nil`, gets DROPPED,
        // CallKit flashes for ~1s and the user sees nothing. We now
        // call `ensureAuthenticated(timeoutSec: 5)` which transparently
        // forces a reconnect when the connection is stale (no inbound
        // traffic in pingInterval*2 seconds) and waits for a fresh
        // `MsgAuthenticated` before letting the next dial proceed.
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
                if let live = self.liveProvider {
                    // Drop the provider only when its WS is already known
                    // dead — otherwise let `ensureAuthenticated` decide
                    // whether to force-reconnect (it checks freshness via
                    // `lastInboundAt`, not just the state enum).
                    if live.persistentConnection.state == .disconnected {
                        self.liveProvider = nil
                        self.connectPersistentSocket()
                    } else {
                        // `ensureAuthenticated` polls with `Task.sleep` so
                        // awaiting it from MainActor releases the main
                        // thread between checks — no detached hop needed.
                        _ = await live.persistentConnection.ensureAuthenticated(timeoutSec: 5)
                    }
                } else {
                    self.connectPersistentSocket()
                }
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
                    // Notify "user accepted" so the call transitions from ringing to active.
                    // Actual signalling (offer/answer) stays inside QAudionCallIntegration.
                    self.isInCall = true
                    self.activeCallKitId = uuid
                    // Callee-side state machine: ringing → active on answer.
                    // Guarded so a stale CallKit callback can't regress an
                    // already-encrypted or ended call.
                    if self.callState == .ringing {
                        self.callState = .active
                    }
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
            // W444: pre-fill userId + dialExtension from UserDefaults so
            // SettingsScreen shows the correct handle before getProfile() returns.
            if let cached = UserDefaults.standard.string(forKey: "currentUserId") {
                self.currentUserId = cached
            }
            if let cached = UserDefaults.standard.string(forKey: "currentUserDialExtension") {
                self.currentUserDialExtension = cached
            }
            let backendConfig = pinnedConfig(token: token)
            let provider = BCryptoBackendProvider(config: backendConfig)
            Task {
                do {
                    let profile = try await provider.accountApi.getProfile()
                    self.currentUserId = profile.userId
                    // W361: mirror to UserDefaults so engine-adjacent
                    // services (LinkNewDeviceScreen QR, future
                    // background tasks) can read the userId without
                    // taking a reference to AppState.
                    UserDefaults.standard.set(profile.userId, forKey: "currentUserId")
                    // W444: persist the short PBX extension so the SettingsScreen
                    // hero card shows "Int. 103" immediately on next launch.
                    if let ext = profile.dialExtension, ext > 0 {
                        let extStr = String(ext)
                        self.currentUserDialExtension = extStr
                        UserDefaults.standard.set(extStr, forKey: "currentUserDialExtension")
                    } else {
                        // OR-fix3: server returned nil/0 — clear stale cached extension
                        // so a user migrated to an account without an extension stops
                        // showing the old "Int. 103" indefinitely.
                        self.currentUserDialExtension = nil
                        UserDefaults.standard.removeObject(forKey: "currentUserDialExtension")
                    }
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
            UserDefaults.standard.set(creds.userId, forKey: "currentUserId")
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
            UserDefaults.standard.set(creds.userId, forKey: "currentUserId")
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
        // W372: subscribe (idempotent — NotificationCenter accepts
        // duplicate observers of the same selector but our use case
        // sends one fan-out per send, which keeps the closure list
        // bounded). Use a guard flag so we only register once per
        // AppState lifetime.
        if !groupFanOutWired {
            wireGroupChatFanOut()
            // W375: bind the PQC session-key broker so the call
            // handshake completion path can re-seed callPqcSessionKey
            // from the real ML-KEM shared secret once it's available.
            CallSessionKeyBroker.shared.bind(to: self)
            // W383: forward broker notifications to the WebRTC
            // controller so the PQC SRTP sealer (W376/W382) gets
            // installed automatically when the handshake key arrives.
            wireSasReadyToController()
            groupFanOutWired = true
        }
        let config = pinnedConfig(token: token)
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
            // Caller-id resolution priority for the CallKit display name:
            //   1. `caller_display` from the wire envelope — server
            //      already resolved the caller's locally-configured
            //      public phone (or fell back to the caller's internal
            //      extension). Highest-priority source.
            //   2. Local rubrica (ContactsStore) lookup by sender_id —
            //      lets the callee see "Mario Rossi" instead of a UUID
            //      when the caller is in the address book but didn't
            //      ship a `caller_display`.
            //   3. Bare `sender_id` UUID as last resort.
            let wireCallerDisplay = (data["caller_display"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedCallerName: String = {
                if let cd = wireCallerDisplay, !cd.isEmpty { return cd }
                let stored = ContactsStore().load()
                if let match = stored.first(where: { $0.userId == senderId }),
                   !match.displayName.isEmpty {
                    return match.displayName
                }
                return senderId
            }()
            // Commit 540b79c0 parity — `call_incoming` is the responder's
            // FIRST view of the caller's caps (the server forwards the
            // call_offer's capabilities verbatim under this envelope).
            // Stash them so handleIncomingWebRtcOffer can apply them on
            // the controller as soon as it's built, and so the
            // CallSetupHandler-equivalent code paths see the same set.
            self.pendingPeerCapabilities = data["capabilities"] as? [String]
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
                        callerName: resolvedCallerName,
                        hasVideo: callType == "video"
                    )
                    await MainActor.run {
                        self.activeCallKitId = callUUID
                        self.callContactId = senderId
                        self.isVideoCall = (callType == "video")
                        self.callState = .ringing
                        self.isInCall = true
                        // PersistentCallRecord — register incoming call.
                        let incomingRecordId = callUUID.uuidString
                        let isVid: Bool = (callType == "video")
                        self.activeOutgoingRecordId = incomingRecordId
                        PersistentCallRecordStore.shared.beginCall(
                            id: incomingRecordId,
                            peerUserId: senderId,
                            peerDisplayName: resolvedCallerName,
                            direction: .incoming,
                            isVideo: isVid
                        )
                        // W396: pre-create the responder integration
                        // so the early PQC OFFER (which arrives
                        // immediately after the call_incoming envelope
                        // — possibly before the user accepts on
                        // CallKit) has somewhere to land.
                        let integration = self.ensureResponderIntegration(forCaller: senderId)
                        integration.didReceiveIncomingCallOffer(
                            callId: callIdStr, callerId: senderId)
                        integration.setLocallyRinging(true)
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
                // If the call was still ringing when the hangup arrived the
                // callee never answered — mark the record as missed.
                let wasRinging = self.callState == .ringing
                let missedRecordId = self.activeOutgoingRecordId
                // NIM-MINOR-4: if we reach ringing state without a record id, the
                // missed call will not appear in history. Log a warning so this
                // regression is visible in telemetry if it ever happens.
                if wasRinging && missedRecordId == nil {
                    RTLog.info("call", "WARN hangup-while-ringing but activeOutgoingRecordId=nil — missed call will not be recorded")
                }
                Task {
                    await self.callKit?.reportCallEnded(uuid: uuid, reason: reason)
                    await MainActor.run {
                        if wasRinging, let rid = missedRecordId {
                            PersistentCallRecordStore.shared.markMissed(id: rid)
                            self.activeOutgoingRecordId = nil
                        }
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

        // W329: handle server `error` envelope. The server emits
        // `{type:"error", code, message}` for AUTH_FAILED, USER_BLOCKED,
        // PAYLOAD_TOO_LARGE, GROUP_CALL_ERROR, etc. iOS was silently
        // dropping all of these. Surface to the UI via errorMessage.
        ws.registerHandler(type: "error") { [weak self] _, data in
            let code = (data["code"] as? String) ?? "?"
            let msg = (data["message"] as? String) ?? "Errore server"
            DispatchQueue.main.async {
                self?.errorMessage = "[" + code + "] " + msg
            }
        }

        // W330: handle `remote_wipe`. Security/compliance — server
        // sends this when an admin or recovery flow has triggered a
        // remote wipe. Server also tries to send an FCM push but
        // hub.go:615 SKIPS the push for ios-apns devices, so the WS
        // envelope is the ONLY path. Before this fix, iOS users
        // could ignore wipe commands. Action: clear auth + force
        // sign-out. (TODO: future — also wipe local stores.)
        ws.registerHandler(type: "remote_wipe") { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.authService.clearToken()
                self?.errorMessage = "Account cancellato remotamente."
            }
        }

        // W331: handle `account_locked`. Server emits when admin
        // locks an account. iOS must drop tokens + force back to
        // login.
        ws.registerHandler(type: "account_locked") { [weak self] _, data in
            let reason = (data["reason"] as? String) ?? "Account bloccato"
            DispatchQueue.main.async {
                self?.authService.clearToken()
                self?.errorMessage = reason
            }
        }

        // W332 + 2026-05-06 KMS lifecycle — kicks the iOS-side KMS
        // pipeline (DeviceKeyManager → KmsPollerService → SovereignKeyVault).
        //
        // Pre-fix iOS only logged a toast on `kms_key_available` and
        // waited indefinitely for the next REST poll. Now: ensure the
        // device-keys are provisioned (idempotent), then sweep the
        // pending list. Best-effort — failures are logged + surfaced
        // via errorMessage so the user can retry from Settings if
        // they care.
        ws.registerHandler(type: "kms_key_available") { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.errorMessage = "Nuova chiave KMS disponibile."
                await self.runKmsSweep()
            }
        }
        ws.registerHandler(type: "kms_key_revoked") { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.errorMessage = "Una chiave KMS è stata revocata."
            }
        }
        // Initial sweep right after WS auth — covers any keys the
        // admin provisioned while the app was offline.
        Task { @MainActor [weak self] in
            await self?.runKmsSweep()
        }

        // W347: route call_offer / call_answer / call_ice through the
        // WebRTC bridge if it's been spun up by the call lifecycle.
        // The bridge is opt-in per call (AppState.webRtcController) so
        // builds without the WebRTC framework available still compile.
        ws.registerHandler(type: "call_offer") { [weak self] _, data in
            guard let self = self,
                  let sdp = data["sdp"] as? String,
                  let callerId = (data["sender_id"] as? String) ?? (data["caller_id"] as? String) else {
                print("[AppState] call_offer: missing sdp/caller_id")
                return
            }
            // Commit 540b79c0 parity — capture the peer's advertised
            // SFrame capability tags BEFORE the controller is built.
            // Absent field → nil → useSFrame=false (legacy peer).
            let peerCaps = data["capabilities"] as? [String]
            // Extract has_video from the wire envelope. Android WsCodec.kt
            // sends this as a Bool; fall back to call_type=="video" for
            // servers that don't forward the field.
            let offerHasVideo: Bool
            if let v = data["has_video"] as? Bool {
                offerHasVideo = v
            } else {
                offerHasVideo = (data["call_type"] as? String) == "video"
            }
            self.handleIncomingWebRtcOffer(
                callerId: callerId,
                sdp: sdp,
                peerCapabilities: peerCaps,
                hasVideo: offerHasVideo
            )
        }
        ws.registerHandler(type: "call_answer") { [weak self] _, data in
            guard let self = self else { return }
            // Commit 540b79c0 parity — capture the peer's caps before
            // applying the SDP so the pipeline pick has the right
            // negotiated set when ensureVideoSealer() runs at video setup.
            let peerCaps = data["capabilities"] as? [String]
            if let sdp = data["sdp"] as? String {
                self.handleIncomingWebRtcAnswer(sdp: sdp, peerCapabilities: peerCaps)
            } else {
                print("[AppState] call_answer: no sdp field")
            }
        }
        ws.registerHandler(type: "call_ice") { [weak self] _, data in
            guard let self = self else { return }
            let candidate = (data["candidate"] as? String) ?? ""
            let sdpMid = data["sdp_mid"] as? String
            let mlineIndex = (data["sdp_mline_index"] as? Int).map { Int32($0) } ?? 0
            self.handleIncomingWebRtcIce(candidate: candidate,
                                            sdpMid: sdpMid,
                                            sdpMLineIndex: mlineIndex)
        }

        // W328 (CRITICAL): handle msg_pending_sync — the server pushes
        // up to 50 queued offline messages on every reconnect via this
        // single envelope (`{type: "msg_pending_sync", messages: [...]}`).
        // Before this fix iOS silently dropped the entire batch, losing
        // every offline message until the next live `msg_receive` came
        // in. PARITY_AUDIT_HONEST.md (Agent C) flagged this as
        // CRITICAL — users were losing messages.
        ws.registerHandler(type: "msg_pending_sync") { [weak self] _, data in
            guard let self = self else { return }
            guard let batch = data["messages"] as? [[String: Any]] else {
                print("[AppState] msg_pending_sync: missing 'messages' array")
                return
            }
            // Replay each entry through the same path as a live
            // msg_receive. Order matters — server pushes oldest first.
            DispatchQueue.main.async {
                for entry in batch {
                    self.replayPendingSyncEntry(entry)
                }
            }
        }
    }

    /// W328: replay one entry from a `msg_pending_sync` batch as if it
    /// arrived via `msg_receive`. Same field-extraction guards.
    /// Method-extracted to keep the closure body trivial per
    /// CLAUDE.md §13.
    private func replayPendingSyncEntry(_ entry: [String: Any]) {
        guard let senderId = entry["sender_id"] as? String,
              !senderId.isEmpty,
              let cipherB64 = entry["encrypted_payload"] as? String,
              let serverMsgId = entry["message_id"] as? String,
              let cipher = Data(base64Encoded: cipherB64) else {
            return
        }
        handleIncomingMessage(
            senderId: senderId,
            serverMsgId: serverMsgId,
            cipher: cipher,
            clientMsgId: entry["client_msg_id"] as? String
        )
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
        // W365: probe the wire-format magic byte to learn this peer's
        // capability. Once we observe a v3 inbound, every outbound
        // chat message to that peer also goes v3 (without needing the
        // global UserDefaults flag).
        PeerCapabilityRegistry.shared.probeInbound(cipher, from: senderId)

        // W80: capture the RAW decrypted plaintext separately from the
        // friendly UI rendering so we can detect qfile markers and
        // kick off the receive pipeline. Without this split, the
        // marker JSON would already have been replaced by the
        // "(download in arrivo)" placeholder before we get to parse.
        var decryptedRaw: String = ""
        do {
            // W351 + W374: route by wire-format magic byte.
            //   0xE3 → v3.1 ratchet (forward secrecy, canonical CBOR AAD)
            //   0xE2 → v2 epoch-routed (W374 cross-platform compat)
            //   anything else → legacy v1 MessageCrypto path
            // First-byte detection is cheap and cross-platform-safe;
            // both engines reject the other's format up front.
            let pt: Data
            switch MessageWireFormat.detect(cipher) {
            case .v3:
                pt = try ratchetDecryptV3(
                    wire: cipher,
                    psk: psk,
                    senderId: senderId,
                    msgId: clientMsgId ?? serverMsgId)
            case .v2:
                // v2 kept the v1 AAD shape ("msg:sender:recipient:msgId")
                // and only added the epoch-routing header in the wire.
                // PSK is already resolved above via the same ladder.
                let aad = Data("msg:\(senderId):\(currentUserId ?? ""):\(clientMsgId ?? serverMsgId)".utf8)
                if let plain = MessageCryptoV2.decrypt(wire: cipher, psk: psk, aad: aad) {
                    pt = plain
                } else {
                    pt = try crypto.decrypt(
                        wireBlob: cipher,
                        psk: psk,
                        senderId: senderId,
                        recipientId: currentUserId ?? "",
                        msgId: clientMsgId ?? serverMsgId
                    )
                }
            case .v1:
                pt = try crypto.decrypt(
                    wireBlob: cipher,
                    psk: psk,
                    senderId: senderId,
                    recipientId: currentUserId ?? "",
                    msgId: clientMsgId ?? serverMsgId
                )
            }
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
            // W390: route `qa_grp:1` envelopes (sender_key_init,
            // sender_key_rotate) to the GroupChatService BEFORE
            // persisting as a chat row. These are protocol messages,
            // not user-visible text. The handler installs the recv
            // chain so subsequent group ciphertexts from this sender
            // can decrypt; if no group session exists locally yet, the
            // handler drops silently (the peer will re-ship after we
            // join via the membership signaling layer).
            if let groupCtlType = GroupChatService.detectGroupCtlType(decryptedRaw) {
                let mySelfId = currentUserId ?? ""
                switch groupCtlType {
                case "sender_key_init":
                    GroupChatService.shared.handleInboundSenderKeyInit(
                        envelopeJson: decryptedRaw,
                        fromUserId: senderId,
                        selfId: mySelfId)
                case "sender_key_rotate":
                    GroupChatService.shared.handleInboundSenderKeyRotate(
                        envelopeJson: decryptedRaw,
                        fromUserId: senderId,
                        selfId: mySelfId)
                case "group_invite":
                    // W399 — iOS-only enhancement: full state on first contact.
                    handleInboundGroupInvite(json: decryptedRaw, fromUserId: senderId)
                case "member_added":
                    // W403 — Desktop-aligned wire.
                    handleInboundMemberAdded(json: decryptedRaw, fromUserId: senderId)
                case "member_removed":
                    handleInboundMemberRemoved(json: decryptedRaw, fromUserId: senderId)
                case "member_left":
                    handleInboundMemberLeft(json: decryptedRaw, fromUserId: senderId)
                case "group_member_added":
                    // W403 LEGACY — accept with epoch gate (drop if env.e
                    // is present and < state.epoch), then route to the
                    // canonical handler. Will be removed in a future release.
                    handleLegacyMemberDelta(
                        json: decryptedRaw, fromUserId: senderId, isAdded: true)
                case "group_member_removed":
                    handleLegacyMemberDelta(
                        json: decryptedRaw, fromUserId: senderId, isAdded: false)
                default:
                    // W403: dropped "group_invite_decline" (was dead code:
                    // a declined invite is just an ignored sender_key_init).
                    print("[AppState] unknown qa_grp:1 type \(groupCtlType) from \(senderId)")
                }
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
            // W444: resolve peer display name from ContactsStore so the conversation
            // list never shows a raw UUID. Falls back to abbreviated senderId when
            // the peer is not yet in contacts (e.g. first-contact inbound message).
            let contactsStore = ContactsStore()
            let resolvedName: String = {
                if let name = contactsStore.load().first(where: { $0.userId == senderId })?.displayName,
                   !name.isEmpty { return name }
                if senderId.count > 12 {
                    return String(senderId.prefix(8)) + "…" + String(senderId.suffix(4))
                }
                return senderId
            }()
            conv = Conversation(
                id: UUID(),
                peerUserId: senderId,
                peerDisplayName: resolvedName,
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
        var pendingAttachAnnounce: AttachAnnounceEnvelope? = nil
        if !decryptedRaw.isEmpty,
           let marker = FileTransfer.tryParseMarker(text: decryptedRaw),
           marker.qfile.downloadClaim != nil {
            initialMediaDur = marker.qfile.durationMs
            pendingMarker = marker
        }
        // W363: also detect the cross-platform attach_announce envelope.
        // Mutually exclusive with the qfile marker — if both somehow
        // parse (shouldn't, since `qa_ctl` and `qfile` are different
        // top-level keys) the qfile path wins for backward compat.
        if pendingMarker == nil,
           !decryptedRaw.isEmpty,
           let env = try? AttachAnnounceEnvelope.parse(decryptedRaw) {
            initialMediaDur = env.att.durationMs
            pendingAttachAnnounce = env
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
            mediaMimeType: pendingMarker?.qfile.mime ?? pendingAttachAnnounce?.att.mime,
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
        // W96: respect the global banner toggle from
        // Settings → Notifiche. Default true so a fresh install
        // sees banners; user can opt out from settings.
        let bannersGlobalEnabled = (UserDefaults.standard.object(
            forKey: "qaudion.notifications.banners_enabled") as? Bool) ?? true
        // W122: when the user is actively viewing this peer's chat
        // and a new message lands, fire a soft haptic so the user
        // notices without an audio chime. Suppression already excludes
        // muted convs from the banner, but THIS path runs even when
        // the banner is suppressed (active chat) so the user still
        // gets a tactile cue.
        if !isMuted && activePeerUserId == senderId {
            HapticFeedback.messageSent()
        }
        if bannersGlobalEnabled && !isMuted && activePeerUserId != senderId {
            let title = conv.peerDisplayName.isEmpty ? senderId : conv.peerDisplayName
            // W106: privacy toggle — hide content in notifications.
            // Defaults false; when on the body is replaced with a
            // generic "Nuovo messaggio" so the lock-screen / banner
            // doesn't leak chat content to over-the-shoulder readers.
            // W404: two-axis privacy gating on the notification body.
            // (a) hideContent (UserDefaults qaudion.privacy.hide_notification_content)
            //     replaces the body with a generic "Nuovo messaggio".
            // (b) PrivacyGate.messagePreviewInNotifications: when OFF,
            //     same effect as hideContent. ChatSettings/Privacy
            //     toggles both flow into PrivacyGate so the user can
            //     disable preview from either screen and the banner
            //     respects it. (a) AND (b) are AND-ed: any one false
            //     hides the body.
            let hideContent = (UserDefaults.standard.object(
                forKey: "qaudion.privacy.hide_notification_content") as? Bool) ?? false
            let previewAllowed = PrivacyGate.messagePreviewInNotifications
            let bodyText: String
            if hideContent || !previewAllowed {
                bodyText = "Nuovo messaggio"
            } else if plaintext.count > 120 {
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
        // W363: mirror the same async-fetch pattern for the cross-
        // platform attach_announce envelope (W355/W356 wire), so an
        // Android- or Desktop-produced voice note auto-downloads and
        // becomes a playable bubble.
        if let envelope = pendingAttachAnnounce {
            Task { [weak self, msgUUID, convId = conv.id, senderId] in
                guard let self = self else { return }
                let receiver = ChatVoiceNoteReceiver(appState: self)
                do {
                    let cacheURL = try await receiver.fetchAttachAnnounce(
                        envelope: envelope, senderId: senderId
                    )
                    let mime = envelope.att.mime
                    let durMs = envelope.att.durationMs
                    let friendly: String = {
                        if mime.hasPrefix("audio/") {
                            if let dur = durMs, dur > 0 {
                                let secs = Double(dur) / 1000.0
                                return String(format: "🎤 Nota vocale (%.1fs)", secs)
                            }
                            return "🎤 Nota vocale"
                        }
                        if mime.hasPrefix("image/") { return "🖼️ Immagine" }
                        if mime.hasPrefix("video/") { return "🎬 Video" }
                        return "📎 Allegato"
                    }()
                    await MainActor.run {
                        ConversationStore().setMediaInfo(
                            localId: msgUUID,
                            conversationId: convId,
                            plaintext: friendly,
                            mediaLocalPath: cacheURL.path,
                            mediaDurationMs: durMs,
                            mediaMimeType: mime
                        )
                        NotificationCenter.default.post(
                            name: AppState.chatRefreshNotification,
                            object: nil,
                            userInfo: ["peerUserId": senderId, "conversationId": convId]
                        )
                    }
                } catch {
                    print("[AppState] attach_announce receive failed from \(senderId): \(error)")
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
    /// W372: fan-out request from GroupChatScreen.handleSend.
    /// userInfo = ["groupId": String, "recipient": String, "wire": Data]
    /// AppState observes this and ships an opaque_message per recipient.
    static let groupChatFanOutNotification = Notification.Name("qaudion.group.fanout")
    /// W399 — non-isolated read of the persisted current userId.
    /// Used by SwiftUI Views (GroupChatScreen.makeInfoState) that
    /// need the userId without taking an EnvironmentObject ref.
    /// Reads from UserDefaults (mirrored on every login by
    /// AppState's auth flow).
    public static var currentUserIdSnapshot: String? {
        return UserDefaults.standard.string(forKey: "currentUserId")
    }

    /// W399 — surfaced to UI when an inbound group_invite arrives.
    /// userInfo: ["groupId": String, "groupName": String,
    ///   "members": [String], "admins": [String], "from": String]
    /// A sheet can subscribe and present accept/decline buttons. On
    /// accept, the UI calls AppState.acceptGroupInvite(groupId:).
    static let groupInviteReceivedNotification = Notification.Name("qaudion.group.inviteReceived")

    /// W399 — fired after acceptGroupInvite or local createGroup
    /// finishes registry persistence + GroupChatService bootstrap.
    /// userInfo: ["groupId": String]. ChatList / GroupChatScreen
    /// subscribe to refresh visible state.
    static let groupRegistryChangedNotification = Notification.Name("qaudion.group.registryChanged")

    /// W403 — fired when a Desktop/Android peer auto-bootstrapped us
    /// into a group via `member_added` (without a preceding iOS
    /// `group_invite` envelope). Snackbar host should show
    /// "Aggiunto al gruppo X da Y" so the user has visibility.
    /// userInfo: ["groupId": String, "fromAdmin": String]
    static let groupAutoJoinedNotification = Notification.Name("qaudion.group.autoJoined")

    /// W390 — group sender_key_init / sender_key_rotate distribution
    /// fan-out. Each emission has userInfo:
    ///   - "recipient": the peer userId to ship to
    ///   - "envelopeJson": the JSON-encoded `qa_grp:1` envelope
    /// AppState.wireGroupSenderKeyCtlFanOut wraps each emission in the
    /// 1:1 ratchet via ChatMessageSendService.sendEncrypted, so the
    /// envelope rides the same per-pair PSK / v3 ratchet path text
    /// chat uses. The recipient's chat dispatcher detects the
    /// `qa_grp:1` marker and routes to GroupChatService.
    static let groupSenderKeyCtlNotification = Notification.Name("qaudion.group.senderKeyCtl")

    /// W77: dispatch inbound `opaque_message` envelopes. The QUAD frame
    /// inside the payload carries either:
    /// 2026-05-06 — KMS pipeline orchestrator. Closes the
    /// WIRE_SPEC §5 "iOS KMS app-level wiring" gap: gathers the
    /// device's long-term keys via DeviceKeyManager (provisioning
    /// them if it's the first launch), then runs one
    /// KmsPollerService.pollOnce sweep against /api/v1/kms/pending.
    /// Decrypted PSKs land in SovereignKeyVault and become
    /// immediately usable by the PqcHandshake fingerprint
    /// negotiation. Best-effort — failures are logged so a transient
    /// network blip on app launch doesn't break the call surface.
    @MainActor
    private func runKmsSweep() async {
        guard let provider = liveProvider else { return }
        let vault = SovereignKeyVault()
        let manager = DeviceKeyManager(vault: vault, kmsClient: provider.kmsClient)
        do {
            let keys = try await manager.ensureProvisioned()
            let poller = KmsPollerService(kmsClient: provider.kmsClient, vault: vault)
            let stats = try await poller.pollOnce(deviceKeys: keys)
            if stats.processed > 0 {
                print("[AppState] KMS sweep: processed=\(stats.processed) stored=\(stats.stored) acked=\(stats.acknowledged) decryptFailed=\(stats.decryptFailed) ackFailed=\(stats.ackFailed)")
            }
            // 2026-05-06 session-renewal Phase 2 — wire the Ed25519
            // device-bound silent re-auth fallback into the REST
            // client. From now on a 401 from /auth/refresh (or a
            // missing refresh token) cascades to /auth/device-renew
            // before BCryptoError.unauthorized surfaces. Mirror of the
            // Android SessionRenewerImpl Phase-1+Phase-2 cascade.
            let renewClient = BCryptoDeviceRenewClient(
                rest: provider.getRestClient(),
                deviceKeyManager: manager
            )
            provider.getRestClient().setDeviceRenewFallback {
                // deviceId is persisted by AuthService at login under
                // "com.qaudion.auth.device_id". Read it lazily so a
                // log-in / log-out cycle picks up the new value.
                guard let did = UserDefaults.standard.string(forKey: "com.qaudion.auth.device_id"),
                      !did.isEmpty else {
                    throw BCryptoError.unauthorized
                }
                let fresh = try await renewClient.renew(deviceId: did)
                // Persist the rotated tokens so the next cold-launch
                // does not replay a stale refresh token.
                UserDefaults.standard.set(fresh.accessToken, forKey: "com.qaudion.auth.token")
                UserDefaults.standard.set(fresh.refreshToken, forKey: "com.qaudion.auth.refresh_token")
                return (accessToken: fresh.accessToken, refreshToken: fresh.refreshToken)
            }
        } catch {
            print("[AppState] KMS sweep failed: \(error)")
        }
    }

    ///   - KEY_EXCHANGE_OFFER  → derive PSK + reply with ACCEPT
    ///   - KEY_EXCHANGE_ACCEPT → derive PSK only (no reply)
    ///   - other capability frames (already handled elsewhere)
    /// Routes to `ContactKeyExchange.handleOffer/handleAccept` so the
    /// pairwise PSK handshake completes without explicit UI action.
    private func wireOpaqueMessageHandler(on ws: BCryptoWebSocketClient, cke: ContactKeyExchange) {
        ws.registerHandler(type: "opaque_message") { [weak self] _, data in
            guard let senderId = data["sender_id"] as? String,
                  !senderId.isEmpty,
                  let blobStr = data["data"] as? String else {
                return
            }

            // Path A — base64-encoded QUAD binary frame (iOS / Desktop peers).
            if let blob = Data(base64Encoded: blobStr),
               let decoded = QAudionCapabilityExchange.parse(blob) {
                switch decoded {
                case .keyExchangeOffer(let pub):
                    Task { await cke.handleOffer(senderId: senderId, peerPubKey: pub) }
                case .keyExchangeAccept(let pub):
                    Task { await cke.handleAccept(senderId: senderId, peerPubKey: pub) }
                case .offer:
                    Task { @MainActor [weak self] in
                        self?.routeInboundPqcOffer(blob: blob, senderId: senderId)
                    }
                case .accept:
                    Task { @MainActor [weak self] in
                        self?.routeInboundPqcAccept(blob: blob, senderId: senderId)
                    }
                default:
                    break
                }
                return
            }

            // Path B — Android JSON HandshakeBundle (full processing).
            //
            // Wire shape (WIRE_SPEC.md §3.1): literal UTF-8 string
            // `"<callId>|<JSON>"` placed verbatim in the `data` field
            // (NOT base64). The JSON carries split pqcPublicKey +
            // x25519PublicKey + capabilities + pskFingerprints. iOS
            // engine's QAudionCapabilityExchange (QUAD binary, single
            // combined kemPublicKey) cannot consume this directly, so
            // we decode via AndroidHandshakeEnvelope.parse() and route
            // to QAudionCallIntegration.onAndroidBundleReceived which
            // does the dual-hybrid encapsulate (ML-KEM-1024 + X25519)
            // and ships the matching ACCEPT back over the same wire.
            if let parsed = AndroidHandshakeEnvelope.parse(blobStr) {
                switch parsed.bundle.kind {
                case .offer:
                    Task { @MainActor [weak self] in
                        self?.routeInboundAndroidOffer(parsed: parsed, senderId: senderId)
                    }
                case .accept:
                    Task { @MainActor [weak self] in
                        self?.routeInboundAndroidAccept(parsed: parsed, senderId: senderId)
                    }
                }
                return
            }

            print("[AppState] opaque_message from \(senderId.prefix(8))… not a valid QUAD frame and not a recognised Android envelope (\(blobStr.count) bytes)")
        }
    }

    /// Responder-side dispatch for Android JSON OFFER. Symmetric to
    /// `routeInboundPqcOffer` but consumes the Android wire format
    /// directly via `QAudionCallIntegration.onAndroidBundleReceived`.
    @MainActor
    private func routeInboundAndroidOffer(parsed: AndroidHandshakeEnvelope.Parsed, senderId: String) {
        let integration = ensureResponderIntegration(forCaller: senderId)
        let sendOpaqueRaw: (String) async throws -> Void = { [weak self] wireString in
            guard let provider = await MainActor.run(body: { self?.liveProvider }) else { return }
            // CRITICAL: ship the wire string verbatim — NOT base64-wrapped.
            // CallingApi.sendOpaqueMessage(data: Data) goes through
            // BCryptoWebSocketClient.sendOpaqueMessage which calls
            // payload.base64EncodedString() under the hood; that breaks
            // Android's `<callId>|<json>` framing because `|` is not in
            // the base64 alphabet so the receiver's `dispatch()` rejects
            // the envelope as malformed.
            try await provider.callingApi.sendOpaqueMessageString(
                recipientId: senderId, payload: wireString)
        }
        Task {
            do {
                try await integration.onAndroidBundleReceived(
                    bundle: parsed.bundle,
                    callId: parsed.callId,
                    eligiblePsks: [:],
                    sendOpaqueRaw: sendOpaqueRaw)
            } catch {
                print("[AppState] routeInboundAndroidOffer failed: \(error)")
            }
        }
    }

    /// Caller-side dispatch for Android JSON ACCEPT. iOS originator
    /// path currently emits QUAD only, so this branch is reached only
    /// when iOS-originated JSON is added later (TODO). Wired now for
    /// forward-compatibility.
    @MainActor
    private func routeInboundAndroidAccept(parsed: AndroidHandshakeEnvelope.Parsed, senderId: String) {
        guard let integration = callService.callIntegration else {
            print("[AppState] Android ACCEPT arrived from \(senderId) with no caller integration")
            return
        }
        let sendOpaqueRaw: (String) async throws -> Void = { [weak self] wireString in
            guard let provider = await MainActor.run(body: { self?.liveProvider }) else { return }
            let payload = wireString.data(using: .utf8) ?? Data()
            try await provider.callingApi.sendOpaqueMessage(
                recipientId: senderId, data: payload)
        }
        Task {
            do {
                try await integration.onAndroidBundleReceived(
                    bundle: parsed.bundle,
                    callId: parsed.callId,
                    eligiblePsks: [:],
                    sendOpaqueRaw: sendOpaqueRaw)
            } catch {
                print("[AppState] routeInboundAndroidAccept failed: \(error)")
            }
        }
    }

    /// W396 — responder-side dispatch: ensure an integration exists
    /// (lazy-create if first OFFER for this peer), pre-stash the
    /// incoming-call ids, and fire onCapabilityMessageReceived so
    /// the engine can encapsulate and ship ACCEPT.
    @MainActor
    private func routeInboundPqcOffer(blob: Data, senderId: String) {
        let integration = ensureResponderIntegration(forCaller: senderId)
        // Build the send-opaque closure bound to this caller. Each
        // outbound ACCEPT rides the existing CallingApi WS path.
        let sendOpaque: (Data) async throws -> Void = { [weak self] payload in
            guard let provider = await MainActor.run(body: { self?.liveProvider }) else { return }
            try await provider.callingApi.sendOpaqueMessage(
                recipientId: senderId, data: payload)
        }
        do {
            try integration.onCapabilityMessageReceived(
                data: blob, fromSenderId: senderId, sendOpaqueMessage: sendOpaque)
        } catch {
            print("[AppState] responder onCapabilityMessageReceived failed: \(error)")
        }
    }

    /// W396 — caller-side dispatch: forward the PQC ACCEPT to the
    /// existing caller integration owned by callService. The
    /// integration's decapsulate path fires onPqcSessionKeyEstablished
    /// (W389) which surfaces the real ML-KEM secret to the broker.
    @MainActor
    private func routeInboundPqcAccept(blob: Data, senderId: String) {
        guard let integration = callService.callIntegration,
              let provider = liveProvider else {
            print("[AppState] PQC ACCEPT arrived from \(senderId) with no caller integration")
            return
        }
        // Reuse the same opaque sender the caller startCall built.
        let sendOpaque: (Data) async throws -> Void = { payload in
            try await provider.callingApi.sendOpaqueMessage(
                recipientId: senderId, data: payload)
        }
        do {
            try integration.onCapabilityMessageReceived(
                data: blob, fromSenderId: senderId, sendOpaqueMessage: sendOpaque)
        } catch {
            print("[AppState] caller onCapabilityMessageReceived failed: \(error)")
        }
    }

    /// W396 — lazy-create the responder integration the first time we
    /// see an inbound PQC envelope from this caller. Idempotent: a
    /// subsequent call returns the cached instance. Wires the same
    /// callbacks the caller path uses (onPqcSessionKeyEstablished →
    /// broker; sendCallProcessing/Ready via the live CallingApi).
    @MainActor
    private func ensureResponderIntegration(forCaller callerId: String) -> QAudionCallIntegration {
        if let existing = responderCallIntegration {
            return existing
        }
        let integration = QAudionCallIntegration()
        // W389: forward the ML-KEM secret to the broker. peerId is the
        // CALLER (we're the responder), so SAS / video sealer rotate
        // are bound to the right peer for this device.
        integration.onPqcSessionKeyEstablished = { [weak self] sharedSecret in
            let peerId = callerId
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                CallSessionKeyBroker.shared.bind(to: self)
                CallSessionKeyBroker.shared.registerPqcSessionKey(
                    sharedSecret, for: peerId)
            }
        }
        // Pre-negotiation hooks — same shape the caller-side block in
        // startCall uses, but mirrored for the responder.
        if let provider = liveProvider {
            integration.sendCallProcessing = { callId, callerId in
                Task {
                    try? await provider.callingApi.sendCallProcessing(
                        callId: callId, callerId: callerId)
                }
            }
            integration.sendCallReady = { callId, callerId in
                Task {
                    try? await provider.callingApi.sendCallReady(
                        callId: callId, callerId: callerId)
                }
            }
        }
        responderCallIntegration = integration
        return integration
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
            let config = pinnedConfig(token: token)
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
        // Drop the relay credentials cache so the next login creates a fresh
        // RelayCredentialsProvider bound to the new token. Without this,
        // ensureRelayProvider() returns the stale provider and expired
        // cache re-fetches fail with the old (invalidated) auth token.
        _relayProvider = nil
        wsConnectionState = .disconnected
        // W72: drop presence subscriptions + cached statuses so the next
        // login starts with a clean slate.
        presenceService.reset()
        currentUserId = nil
        UserDefaults.standard.removeObject(forKey: "currentUserId")
        currentUserDialExtension = nil
        UserDefaults.standard.removeObject(forKey: "currentUserDialExtension")
        isAuthenticated = false
        callState = .idle
        isInCall = false
        deepfakeAlert = false
    }

    /// W414 — entry point dal DialPad. Risolve `rawInput` (può essere
    /// short extension PBX, E.164, o uno user_id UUID-form) al vero
    /// BCrypto userId tramite il server, poi chiama `startCall(contactId:)`.
    ///
    /// Heuristica di parsing:
    ///   - solo cifre (con o senza '+') e ≤ 7 char → short extension,
    ///     prova `GET /api/v1/directory/by-extension/{n}` (W414 endpoint).
    ///   - inizia con '+' → E.164, prova fetchPepper + discover-v2.
    ///   - 32+ char alfanumerici/trattini → presumibilmente già uno
    ///     user_id, passa diretto a startCall (back-compat con
    ///     callers che hanno già lo userId).
    ///
    /// Ogni step di rete ha errori user-facing tramite `errorMessage`
    /// + early return così il DialPad non resta bloccato in attesa.
    @MainActor
    func dialAndCall(rawInput: String, video: Bool = false) async {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        RTLog.info("dial", "dialAndCall raw='\(trimmed)' video=\(video)")
        guard !trimmed.isEmpty else {
            errorMessage = "Numero vuoto."
            RTLog.warn("dial", "input vuoto, abort")
            return
        }
        guard let token = authService.loadToken(), !token.isEmpty else {
            errorMessage = "Sessione non autenticata."
            return
        }
        let backendConfig = pinnedConfig(token: token)
        let provider = BCryptoBackendProvider(config: backendConfig)

        // Step A — short extension (solo cifre, lunghezza ≤ 7).
        let digitsOnly = trimmed.allSatisfy { $0.isNumber }
        if digitsOnly, trimmed.count <= 7, let ext = Int64(trimmed) {
            RTLog.info("dial", "branch=extension ext=\(ext)")
            do {
                guard let profile = try await provider.accountApi.lookupByExtension(ext) else {
                    errorMessage = "Interno \(ext) non assegnato — verifica il numero e riprova."
                    RTLog.warn("dial", "ext=\(ext) → 404 not assigned")
                    return
                }
                RTLog.info("dial", "ext=\(ext) → userId=\(profile.userId.prefix(8))…")
                await startCall(contactId: profile.userId, video: video)
                return
            } catch {
                errorMessage = "Risoluzione interno \(ext) fallita: \(error.localizedDescription)"
                RTLog.error("dial", "ext=\(ext) lookup error: \(error.localizedDescription)")
                return
            }
        }

        // Step B — E.164 (+...) → contacts/discover-v2 path.
        if trimmed.hasPrefix("+") {
            do {
                let normalized = try PhoneHashHelper.normalizeE164(trimmed)
                let v2 = BCryptoContactsDiscoverV2Client(
                    baseUrl: URL(string: serverUrl)!,
                    bearerTokenProvider: { [weak self] in self?.authService.loadToken() })
                let pepper = try await v2.fetchPepper()
                let hash = try PepperedPhoneHash.hash(phone: normalized, pepperBytes: pepper.pepperBytes)
                let entries = try await v2.discover(alg: pepper.alg, hashes: [hash])
                guard let entry = entries.first, let userId = entry.userId else {
                    errorMessage = "Numero \(normalized) non risulta tra gli utenti registrati."
                    return
                }
                await startCall(contactId: userId, video: video)
                return
            } catch {
                errorMessage = "Risoluzione \(trimmed) fallita: \(error.localizedDescription)"
                return
            }
        }

        // Step C — fallback: assumiamo già uno user_id e proviamo
        // diretto. Il server rifiuterà in modo benigno se sbagliato.
        await startCall(contactId: trimmed, video: video)
    }

    func startCall(contactId: String, video: Bool = false) async {
        RTLog.info("call", "startCall contactId=\(contactId.prefix(8))… video=\(video)")
        // Guard against double-tap / concurrent calls. Without this,
        // two rapid invocations each generate a fresh UUID and each
        // send an independent call_offer — the server creates two
        // separate call sessions and the callee sees two incoming calls
        // (observed 2026-05-16, iOS→Android, UUIDs C6C66915/FC3AA1BF).
        guard !isInCall else {
            RTLog.warn("call", "startCall ignored — already in call (isInCall=true)")
            return
        }
        guard let engine = engine else {
            errorMessage = "Engine not available"
            RTLog.error("call", "engine not available — abort")
            return
        }
        callContactId = contactId
        callState = .connecting
        isInCall = true
        isVideoCall = video
        // PersistentCallRecord — register outgoing call. Use activeCallKitId if
        // already set, otherwise mint a placeholder id that endCall will match.
        // The id is updated to the real outgoingCallId once beginAndroidOutgoing
        // runs below; here we use a stable per-session key derived from contactId
        // + startedAt so the record can be matched by endCall(id:).
        let _outgoingRecordId: String = UUID().uuidString
        let _outgoingPeerDisplay: String = {
            let stored = ContactsStore().load()
            var nameMap: [String: String] = [:]
            for c in stored where !c.displayName.isEmpty {
                nameMap[c.userId] = c.displayName
            }
            return PersistentCallRecordStore.resolveDisplayName(
                userId: contactId, wireDisplay: nil, nameByUserId: nameMap)
        }()
        activeOutgoingRecordId = _outgoingRecordId
        PersistentCallRecordStore.shared.beginCall(
            id: _outgoingRecordId,
            peerUserId: contactId,
            peerDisplayName: _outgoingPeerDisplay,
            direction: .outgoing,
            isVideo: video
        )
        confidenceLevel = "green"
        confidenceScore = 0.97
        rekeyCount = 0
        txWaveformSamples = []
        rxWaveformSamples = []
        cipherWaveformSamples = []
        // W369: seed `callPqcSessionKey` from the per-pair PSK so the
        // SAS panel renders REAL words derived from the same secret
        // both peers hold. This is a transitional source — it will be
        // replaced by the actual ML-KEM-1024 session key once the
        // PQC handshake plumbing surfaces it. Until then the SAS is
        // still a meaningful authentication primitive: identical on
        // both ends if and only if the PSK ladder agrees.
        callPqcSessionKey = Self.deriveTransitionalSasKey(
            selfId: currentUserId ?? "",
            peerId: contactId)
        pskActive = !(callPqcSessionKey?.isEmpty ?? true)
        do {
            // W67: wire WebSocket transport PRIMA di startCall così il
            // handler "audio_frame" è già registrato quando il peer
            // inizia a inviare e la capture.onFrame può immediatamente
            // route al wsClient. Best-effort: senza token ancora non
            // facciamo wiring (chiamata continua senza network audio,
            // ma HW DSP capture+playback restano comunque attivi via W66).
            if let ws = liveProvider?.getWebSocketClient() {
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
                        // Bail out if AppState was deallocated mid-flight.
                        // No need to bind self — the closure body doesn't
                        // touch any instance state, just logs.
                        guard self != nil else { return }
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
               let provider = liveProvider {
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
                // W389: forward the real ML-KEM-1024 session key into
                // CallSessionKeyBroker so AppState.callPqcSessionKey
                // swaps from the W369 transitional PSK-derived seed to
                // the PQC handshake output. The broker also re-posts
                // sasReadyNotification, which LiveInCallScreen and the
                // WebRTC controller observe to re-render SAS words and
                // (when the binary supports insertable streams)
                // re-install the PQC sealer with the correct key.
                // Capture `self` weakly in the closure that gets stored
                // on the integration so we don't hold AppState alive via
                // callService → integration → closure. The peerId is
                // captured by-value from `contactId`.
                integration.onPqcSessionKeyEstablished = { [weak self] sharedSecret in
                    // The integration fires this from its WS dispatch
                    // queue. Both AppState and CallSessionKeyBroker are
                    // @MainActor, so hop explicitly via a MainActor Task.
                    let peerId = contactId
                    let weakSelf = self  // re-capture for Task scope
                    Task { @MainActor in
                        guard let strongSelf = weakSelf else { return }
                        // Bind broker on first use; idempotent.
                        CallSessionKeyBroker.shared.bind(to: strongSelf)
                        CallSessionKeyBroker.shared.registerPqcSessionKey(
                            sharedSecret, for: peerId)
                    }
                }

                // 2026-05-06 — close the WIRE_SPEC §5 P0 gap "iOS
                // originator JSON-HandshakeBundle (UI/WS plumbing)".
                // Mint the canonical callId here and drive
                // CallService.beginAndroidOutgoing which:
                //   1. ships call_offer with this callId,
                //   2. drives integration.onAndroidCallSetupStarted
                //      with the same callId so the engine stash key,
                //      the WS-level callId, and the PQC bundle's
                //      callId field all converge on one UUID.
                // Pre-fix the legacy CallService path passed an empty
                // closure to onCallSetupStarted, so the OFFER bytes
                // generated by the engine went to /dev/null and any
                // iOS-originated call to Android sat for the full
                // 35s PqcHandshake timeout.
                let outgoingCallId = UUID().uuidString
                // Caller-id substitution: ship the local public phone
                // number (digits-only, see `LocalCallerIdSettings`) as
                // `caller_display` on the outbound call_offer when the
                // user has configured one. Otherwise the field is
                // omitted and the server fills it with the caller's
                // internal extension.
                let callerDisplay = LocalCallerIdSettings.phoneNumber()
                do {
                    try await callService.beginAndroidOutgoing(
                        callId: outgoingCallId,
                        recipientId: contactId,
                        callingApi: provider.callingApi,
                        callerDisplay: callerDisplay,
                        hasVideo: video
                    )
                } catch is CancellationError {
                    print("[AppState] startCall cancelled mid-OFFER for callId=\(outgoingCallId.prefix(8))…")
                    callService.endCall()
                    callState = .idle
                    isInCall = false
                    callContactId = nil
                    return
                } catch {
                    print("[AppState] beginAndroidOutgoing failed for callId=\(outgoingCallId.prefix(8))…: \(error)")
                    errorMessage = "Avvio chiamata fallito: \(error.localizedDescription)"
                    callService.endCall()
                    callState = .idle
                    isInCall = false
                    callContactId = nil
                    return
                }
            }

            callState = .active
            // W391: bring up the video pipeline for video calls.
            // Best-effort: if camera permission is denied or hardware
            // is unavailable, the call continues without video (the
            // UI placeholders stay visible).
            if video {
                await startVideoPipeline(for: contactId)
            }
            // W347: also kick off a WebRTC outgoing call. This rides in
            // PARALLEL with the legacy SDP-less PQC path during the
            // rollover — the peer that supports WebRTC will pick the
            // first valid offer it sees. Best-effort: if WebRTC isn't
            // available (test target etc.), the legacy path keeps the
            // call up.
            #if canImport(WebRTC)
            if let provider = liveProvider {
                let controller = QAudionWebRtcCallController(
                    callingApi: provider.callingApi,
                    relayProvider: ensureRelayProvider()
                )
                // W411: apply user-configured Transport overrides.
                #if canImport(WebRTC)
                if let customUrl = TransportGate.preferredTurnUrl {
                    controller.iceServerOverride = [
                        RTCIceServer(urlStrings: [customUrl.absoluteString])
                    ]
                }
                if TransportGate.forcesRelay {
                    controller.iceTransportPolicyOverride = .relay
                }
                #endif
                // Commit 77583315 parity — wire the rotating-key SFrame
                // sealer factory. The factory is consulted by
                // `ensureVideoSealer()` at video-pipeline pickup time;
                // until then keeping it set has zero side effects.
                // The provider closure must return the CURRENT 32-byte
                // PQC session key on every frame so audio-driven rekey
                // rotations are picked up transparently.
                controller.sframeVideoSealerFactory = { keyProvider in
                    SFrameVideoSealer.forRotatingKey(keyProvider)
                }
                // For outgoing video calls VideoCallPipeline (above)
                // already opened the camera. Tell the controller to
                // skip RTCCameraVideoCapturer so the two AVCaptureSessions
                // don't conflict. The video m=video SDP section still
                // exists so Android negotiates video correctly.
                if video { controller.useExternalVideoSource = true }
                webRtcController = controller
                // Android↔iOS remote video: Android sends video via WebRTC
                // RTP (not WS video_frame envelopes). Wire the track callback
                // so VideoCallView can render it via WebRTCRemoteVideoView.
                controller.onRemoteVideoTrack = { [weak self] track in
                    Task { @MainActor [weak self] in
                        self?.remoteWebRtcVideoTrack = track
                    }
                }
                // Same caller-id substitution as the legacy path —
                // both rails ship the same `caller_display` so the
                // peer doesn't pick a different label depending on
                // which OFFER it picks up first.
                let webRtcCallerDisplay = LocalCallerIdSettings.phoneNumber()
                Task { [weak self] in
                    do {
                        try await controller.startOutgoingCall(
                            recipientId: contactId,
                            audioOnly: !video,
                            callerDisplay: webRtcCallerDisplay
                        )
                        print("[AppState] WebRTC outgoing offer sent to \(contactId)")
                        // After startOutgoingCall the WebRTC video source exists.
                        // Wire VideoCallPipeline → RTCVideoSource so Android
                        // receives real camera video over WebRTC RTP.
                        #if os(iOS)
                        if video, let capturer = controller.webrtcPixelBufferCapturer {
                            await MainActor.run {
                                self?.videoPipeline?.onCapturedPixelBuffer = {
                                    [weak capturer] pixelBuffer, timestampNs in
                                    capturer?.push(pixelBuffer, rotation: ._0,
                                                   timestampNs: timestampNs)
                                }
                            }
                        }
                        #endif
                    } catch {
                        print("[AppState] WebRTC startOutgoingCall failed: \(error)")
                        await MainActor.run {
                            self?.webRtcController = nil
                        }
                    }
                }
            }
            #endif
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
        // NIM-fix1: log the call-session UUID, not the raw peer userId, to
        // avoid leaking the social graph through auto-uploaded VPS telemetry.
        let callLogId: String = activeOutgoingRecordId ?? "none"
        RTLog.info("call", "endCall — callId=" + callLogId + " state=\(callState)")
        // Persist call end time. Use the stable record id registered in startCall
        // or wireIncomingCallHandlers. Works for both outgoing and incoming paths.
        if let rid = activeOutgoingRecordId {
            PersistentCallRecordStore.shared.endCall(id: rid)
            activeOutgoingRecordId = nil
        }
        callService.endCall()
        // W398: stop ABR loop before video pipeline teardown so the
        // controller doesn't try to set bitrate on a freed encoder.
        abrController?.stop()
        abrController = nil
        // W391: tear down the video pipeline alongside the audio
        // session. Idempotent if no video pipeline was started.
        videoPipeline?.stop()
        videoPipeline = nil
        // W396: tear down the responder integration so a subsequent
        // call from the same peer starts with a clean state machine.
        responderCallIntegration?.onCallEnded()
        responderCallIntegration = nil
        callState = .ended
        isInCall = false
        isVideoCall = false
        deepfakeAlert = false
        callContactId = nil
        activeCallKitId = nil
        // W339: drop the PQC session key so the SAS panel hides on the
        // next call setup. Holding stale key material across calls
        // would otherwise let one call's verified SAS appear on the
        // next, unverified call.
        callPqcSessionKey = nil
        // W347: tear down the WebRTC bridge for this call. The
        // controller's own deinit / hangup() closes the underlying
        // RTCPeerConnection.
        #if canImport(WebRTC)
        if let ctrl = webRtcController as? QAudionWebRtcCallController {
            Task { await ctrl.hangup() }
        }
        #endif
        webRtcController = nil
        remoteWebRtcVideoTrack = nil
        txWaveformSamples = []
        rxWaveformSamples = []
        cipherWaveformSamples = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.callState = .idle
        }
    }

    /// W369: transitional SAS key derivation. Loads the per-pair PSK
    /// from the SovereignKeyVault using the same ladder
    /// ChatMessageSendService uses (auto:<prefix>:<peer> → bare
    /// peerId → deterministic SHA-256(pair) fallback) and uses it as
    /// the SAS engine input. Both peers hold the same PSK so they
    /// derive the same 6 words.
    ///
    /// This is a TRANSITIONAL bridge until the call PQC handshake
    /// surfaces the real ML-KEM-1024 session key. The SAS still
    /// authenticates the call: identical words on both ends ⇔ same
    /// PSK ladder agreed; mismatched words ⇒ key tampering or one
    /// side has a stale PSK.
    private static func deriveTransitionalSasKey(selfId: String, peerId: String) -> Data {
        guard !peerId.isEmpty, !selfId.isEmpty else { return Data() }
        let vault = SovereignKeyVault()
        let prefix = peerId.count > 8 ? String(peerId.prefix(8)) : peerId
        let autoName = "auto:\(prefix):\(peerId)"
        if let stored = (try? vault.loadPsk(name: autoName)) ?? nil, !stored.isEmpty {
            return stored
        }
        if let stored = (try? vault.loadPsk(name: peerId)) ?? nil, !stored.isEmpty {
            return stored
        }
        // Deterministic fallback (same as ChatMessageSendService.fallbackPsk):
        // both peers derive the same key from the sorted-pair tuple.
        let pair = [peerId, selfId].sorted().joined(separator: ":")
        let digest = SHA256.hash(data: Data("qaudion-fallback-psk:\(pair)".utf8))
        return Data(digest)
    }

    /// W339: derive the 6-PGP-word in-call SAS from the active call's
    /// PQC session key. Returns an empty array when `callPqcSessionKey`
    /// is nil — the InCallScreen hides the SAS panel in that case.
    /// Both peers compute the SAS from the same shared secret using the
    /// same canonical salt/info, so two same-version peers always agree
    /// on the 6-word string.
    var callSasWords: [String] {
        guard let key = callPqcSessionKey, !key.isEmpty else { return [] }
        do {
            return try ComputeSasUseCase.invoke(sessionKey: key).words
                .map { $0.uppercased() }
        } catch {
            return []
        }
    }

    func setMuted(_ muted: Bool) {
        // Forward to CallService which gates outgoing PCM before encryption.
        callService.setMuted(muted)
    }

    func setSpeaker(_ enabled: Bool) {
        // Audio routing is managed by the OS via AVAudioSession; no engine API needed.
    }

    /// Toggle the local camera for video calls. Pauses/resumes the
    /// video capture pipeline. No-op when there is no active video call.
    func setCamera(_ enabled: Bool) {
        videoPipeline?.setCameraEnabled(enabled)
    }

    func testConnection() async {
        connectionStatus = "connecting"
        let config = pinnedConfig()
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

            let backendConfig = pinnedConfig(token: authService.loadToken())
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

// MARK: - W384: SAS-ready → WebRTC sealer install observer

extension AppState {
    /// Subscribes to CallSessionKeyBroker.sasReadyNotification (W375)
    /// and forwards the freshly-derived ML-KEM session key into the
    /// QAudionWebRtcCallController.pqcSessionKey (W383). The
    /// controller's didSet then installs PqcFrameEncryptor +
    /// Decryptor on every RTP sender/receiver of the active peer
    /// connection, lighting up the PQC SRTP layer mid-call.
    func wireSasReadyToController() {
        NotificationCenter.default.addObserver(
            forName: CallSessionKeyBroker.sasReadyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // W402: AppState is @MainActor, so accessing webRtcController /
            // videoPipeline / rotatePqcSealer from this NotificationCenter
            // closure (delivered on .main queue but not declared @MainActor)
            // requires an explicit MainActor hop under Swift 6 strict mode.
            Task { @MainActor [weak self] in
                guard let self = self,
                      let key = self.callPqcSessionKey else { return }
                #if canImport(WebRTC)
                if let ctrl = self.webRtcController as? QAudionWebRtcCallController {
                    ctrl.pqcSessionKey = key
                    print("[AppState] PQC SRTP sealer key forwarded to WebRTC controller (\(key.count) bytes)")
                }
                #endif
                // W394: rotate the video pipeline's sealer with the new
                // ML-KEM secret. From this moment forward, every outbound
                // fragment is sealed under the post-handshake key and
                // every inbound fragment is opened with it.
                if let pipeline = self.videoPipeline {
                    pipeline.rotatePqcSealer(key)
                    print("[AppState] video pipeline PQC sealer rotated (\(key.count) bytes)")
                }
                // Advance the call-state machine to .encrypted now that
                // the ML-KEM session key is live. Guards against regressing
                // from .ended (stale notification after hangup).
                if self.callState == .active {
                    self.callState = .encrypted
                }
            }
        }
    }
}

// MARK: - W372: group chat fan-out

extension AppState {
    /// Subscribe once at AppState init to the group fan-out
    /// notification. Each emission ships a single opaque_message to
    /// the named recipient with the encrypted wire bytes as payload.
    /// Server-side store-and-forward via msg_pending_sync covers
    /// offline peers — same path 1:1 chat already uses.
    func wireGroupChatFanOut() {
        NotificationCenter.default.addObserver(
            forName: AppState.groupChatFanOutNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let recipient = note.userInfo?["recipient"] as? String,
                  let wire = note.userInfo?["wire"] as? Data else {
                return
            }
            // W388: `liveProvider` is main-actor-isolated; resolve it
            // inside a `@MainActor` Task so Swift 6 strict concurrency
            // doesn't complain about cross-actor capture in the
            // (otherwise main-queue) NotificationCenter closure.
            Task { @MainActor [weak self] in
                guard let provider = self?.liveProvider else { return }
                do {
                    try await provider.callingApi.sendOpaqueMessage(
                        recipientId: recipient, data: wire)
                } catch {
                    print("[AppState] groupChat fan-out to \(recipient) failed: \(error)")
                }
            }
        }
        // W390: also subscribe to the sender_key_init / rotate fan-out
        // so each (recipientId, envelopeJson) emission is wrapped in
        // the per-pair PSK / v3 ratchet via ChatMessageSendService and
        // shipped as a regular `msg_send`. Recipient's chat dispatcher
        // detects the `qa_grp:1` marker in the decrypted plaintext and
        // routes to GroupChatService.handleInboundSenderKeyInit BEFORE
        // a chat row is persisted.
        NotificationCenter.default.addObserver(
            forName: AppState.groupSenderKeyCtlNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let recipient = note.userInfo?["recipient"] as? String,
                  let envelopeJson = note.userInfo?["envelopeJson"] as? String else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let sender = ChatMessageSendService(appState: self)
                let outcome = await sender.sendEncrypted(
                    messageId: UUID(),
                    peerUserId: recipient,
                    plaintext: envelopeJson)
                switch outcome {
                case .delivered, .sent:
                    break
                case .failed(let reason):
                    print("[AppState] sender_key_ctl ship to \(recipient) failed: \(reason)")
                }
            }
        }
    }
}

// MARK: - W399: group invite plumbing

extension AppState {

    /// Inbound `qa_grp:1, t:"group_invite"` from a peer admin.
    /// Validates basic fields then surfaces via NotificationCenter
    /// so a sheet can prompt the user.
    @MainActor
    fileprivate func handleInboundGroupInvite(json: String, fromUserId senderId: String) {
        guard let env = GroupInviteEnvelope.decodeInvite(json) else {
            print("[AppState] handleInboundGroupInvite: malformed JSON from \(senderId)")
            return
        }
        // Sanity: the sender must actually be in the admins list of
        // the invite. A spoofed invite from a non-admin is rejected
        // (defense-in-depth — the sender_id is server-overridden).
        guard env.admins.contains(senderId) || env.from == senderId else {
            print("[AppState] handleInboundGroupInvite: sender \(senderId) not in admins of invite for group \(env.g) — rejecting")
            return
        }
        // If we're already in this group, treat as a no-op (idempotent
        // re-invites are valid for offline peers replaying).
        if GroupRegistry.shared.entry(for: env.g) != nil {
            print("[AppState] handleInboundGroupInvite: already member of \(env.g), ignoring re-invite")
            return
        }
        NotificationCenter.default.post(
            name: AppState.groupInviteReceivedNotification,
            object: nil,
            userInfo: [
                "groupId": env.g,
                "groupName": env.name,
                "members": env.members,
                "admins": env.admins,
                "from": env.from,
            ])
    }

    /// Public API for the UI (sheet) to accept an inbound invite.
    /// Persists the entry, bootstraps the GroupChatService session
    /// (which fires replayBufferedCtl for any sender_key_init that
    /// pre-arrived under W395), and notifies observers.
    @MainActor
    public func acceptGroupInvite(groupId: String, name: String,
                                  members: [String], admins: [String]) {
        guard let selfId = currentUserId, !selfId.isEmpty else {
            print("[AppState] acceptGroupInvite: no currentUserId")
            return
        }
        let entry = GroupRegistry.Entry(
            id: groupId, name: name, members: members,
            admins: admins, joinedAt: Date(), bootstrapped: false)
        GroupRegistry.shared.upsert(entry)
        // Force the GroupChatService to bootstrap the session right
        // away — that drains the W395 buffered ctl envelopes (which
        // may have already arrived from the existing members).
        _ = GroupChatService.shared.session(
            groupId: groupId, members: members, selfId: selfId)
        GroupRegistry.shared.markBootstrapped(groupId: groupId)
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupId])
    }

    /// Public API for the UI to decline an inbound invite. Best-
    /// effort: ships a `qa_grp:1 group_invite_decline` to the
    /// admin so they know not to expect us. The admin UI may show
    /// a toast; the registry stays untouched.
    @MainActor
    /// W403 — declining an invite is now a local-only action (no wire
    /// envelope, since `group_invite_decline` was dropped for cross-
    /// platform consistency: a declined invite is just an ignored
    /// sender_key_init/group_invite, which Desktop/Android already
    /// handle silently). The admin will eventually notice via UI
    /// (no message activity from us) or the standard remove flow.
    public func declineGroupInvite(groupId: String, fromAdmin admin: String) {
        // Best-effort: drop any local registry entry the inbound
        // group_invite may have created, and clear the GroupChatService
        // session if it bootstrapped.
        GroupRegistry.shared.remove(groupId: groupId)
        GroupChatService.shared.invalidate(groupId: groupId)
        print("[AppState] declined invite for group \(groupId) from admin \(admin) (no decline envelope shipped — W403 alignment)")
    }

    /// Public API: admin creates a new group and ships invites to
    /// every member via 1:1 ratchet. The local user is auto-joined
    /// (registry entry persisted, GroupChatService session
    /// bootstrapped) so they can immediately send into the group.
    /// Each invitee receives a `qa_grp:1 group_invite` and decides
    /// independently to accept.
    @MainActor
    public func createGroup(name: String, members: [String], admins: [String]) -> String? {
        guard let selfId = currentUserId, !selfId.isEmpty else {
            print("[AppState] createGroup: no currentUserId")
            return nil
        }
        // Generate a fresh 16-byte group id (UUIDv4 → hex).
        let gidBytes = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Make sure self is in members AND admins (admin-creator).
        var fullMembers = members
        if !fullMembers.contains(selfId) { fullMembers.append(selfId) }
        var fullAdmins = admins
        if !fullAdmins.contains(selfId) { fullAdmins.append(selfId) }

        // Local persist + bootstrap.
        let entry = GroupRegistry.Entry(
            id: gidBytes, name: name, members: fullMembers,
            admins: fullAdmins, joinedAt: Date(), bootstrapped: false)
        GroupRegistry.shared.upsert(entry)
        _ = GroupChatService.shared.session(
            groupId: gidBytes, members: fullMembers, selfId: selfId)
        GroupRegistry.shared.markBootstrapped(groupId: gidBytes)

        // W403 Outbound: emit BOTH the legacy iOS `group_invite`
        // envelope (better UX for iOS↔iOS — modal sheet with full
        // state up-front) AND the Desktop-aligned `member_added`
        // events (interop with Desktop/Android peers). Desktop/Android
        // log the `group_invite` as unknown qa_grp envelope, then
        // process the parallel `member_added` events normally.
        let now = Int64(Date().timeIntervalSince1970)
        let groupEpoch: UInt32 = 1
        let inviteEnv = GroupInviteEnvelope.Invite(
            g: gidBytes, name: name, members: fullMembers,
            admins: fullAdmins, from: selfId, e: groupEpoch, ts: now)
        let inviteJson = GroupInviteEnvelope.encodeInvite(inviteEnv)

        // For every recipient, ship: (a) iOS group_invite (full state)
        // + (b) one `member_added` per existing OTHER member so the
        // recipient builds the roster incrementally. The `member_added`
        // for the recipient themselves is shipped to all OTHER members
        // (so their registry adds the new joiner). This matches Desktop's
        // O(N) admin-side cost on group creation.
        for recipient in fullMembers where recipient != selfId {
            // (a) iOS-only enhancement.
            if let json = inviteJson {
                NotificationCenter.default.post(
                    name: AppState.groupSenderKeyCtlNotification,
                    object: nil,
                    userInfo: [
                        "recipient": recipient,
                        "envelopeJson": json,
                    ])
            }
            // (b) Desktop-aligned fan-out: send `member_added` for every
            // member EXCEPT the recipient (recipient learns the rest of
            // the roster from these events). Recipient's own membership
            // is implied by the very fact they got the invite.
            for otherMember in fullMembers where otherMember != recipient {
                let addedEnv = GroupInviteEnvelope.MemberAdded(
                    g: gidBytes, e: groupEpoch, member: otherMember,
                    from: selfId, ts: now)
                if let addedJson = GroupInviteEnvelope.encodeMemberAdded(addedEnv) {
                    NotificationCenter.default.post(
                        name: AppState.groupSenderKeyCtlNotification,
                        object: nil,
                        userInfo: [
                            "recipient": recipient,
                            "envelopeJson": addedJson,
                        ])
                }
            }
        }
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": gidBytes])
        return gidBytes
    }

    /// W403 — inbound `member_added` (Desktop-aligned wire).
    /// Auto-bootstraps a local registry entry if `member == self` AND
    /// no local state exists (mirrors Desktop's onboarding flow when
    /// no `group_invite` envelope precedes the delta). Surfaces a
    /// `groupRegistryChangedNotification` so the chat list can react.
    @MainActor
    fileprivate func handleInboundMemberAdded(json: String, fromUserId senderId: String) {
        guard let env = GroupInviteEnvelope.decodeMemberAdded(json) else { return }
        applyMemberAdded(
            groupId: env.g, epoch: env.e, member: env.member,
            from: env.from.isEmpty ? senderId : env.from,
            senderId: senderId)
    }

    /// W403 — inbound `member_removed` (Desktop-aligned wire).
    @MainActor
    fileprivate func handleInboundMemberRemoved(json: String, fromUserId senderId: String) {
        guard let env = GroupInviteEnvelope.decodeMemberRemoved(json) else { return }
        applyMemberRemoved(
            groupId: env.g, epoch: env.e, member: env.member,
            from: env.from.isEmpty ? senderId : env.from,
            senderId: senderId, voluntary: false)
    }

    /// W403 — inbound `member_left` (voluntary leave). The leaver IS
    /// the sender, so authorization check is "sender == leaver"
    /// instead of "sender ∈ admins" (admin auth).
    @MainActor
    fileprivate func handleInboundMemberLeft(json: String, fromUserId senderId: String) {
        guard let env = GroupInviteEnvelope.decodeMemberLeft(json) else { return }
        guard env.member == senderId else {
            print("[AppState] member_left from \(senderId) but member=\(env.member) — rejecting")
            return
        }
        applyMemberRemoved(
            groupId: env.g, epoch: env.e, member: env.member,
            from: senderId, senderId: senderId, voluntary: true)
    }

    /// W403 — legacy iOS (W399) wire decoder with epoch gate.
    /// Drops envelopes that try to roll state back. Logged as
    /// deprecation so we can monitor when it's safe to remove.
    @MainActor
    fileprivate func handleLegacyMemberDelta(json: String, fromUserId senderId: String, isAdded: Bool) {
        guard let env = GroupInviteEnvelope.decodeLegacyMemberDelta(json) else { return }
        // Epoch gate: if remote sent W403+ envelope with `e`, enforce it.
        // Pre-W403 senders omit `e` (env.e == nil) — accepted for now.
        let envEpoch = env.e ?? 0
        if let entry = GroupRegistry.shared.entry(for: env.g) {
            // We have a local state. Reject any legacy envelope that
            // would mutate it under a stale epoch.
            // (The first time this group is seen, entry is nil and we
            // bootstrap below — no rollback risk.)
            // GroupRegistry doesn't store epoch yet; use 1 as the
            // implicit current epoch (matches GroupSession default).
            // Future: bind GroupRegistry.Entry.epoch and compare exactly.
            _ = entry  // silence unused if no future field added
            if envEpoch != 0 && envEpoch < 1 {
                print("[AppState] legacy \(env.t) for \(env.g) e=\(envEpoch) below local epoch — dropping (replay/downgrade defense)")
                return
            }
        }
        let resolvedFrom = env.from ?? senderId
        if isAdded {
            applyMemberAdded(
                groupId: env.g, epoch: envEpoch == 0 ? 1 : envEpoch,
                member: env.member, from: resolvedFrom, senderId: senderId)
        } else {
            applyMemberRemoved(
                groupId: env.g, epoch: envEpoch == 0 ? 1 : envEpoch,
                member: env.member, from: resolvedFrom, senderId: senderId,
                voluntary: false)
        }
        print("[AppState] DEPRECATED qa_grp legacy token \(env.t) processed (sender=\(senderId), group=\(env.g))")
    }

    // MARK: - W403 shared apply helpers

    @MainActor
    fileprivate func applyMemberAdded(
        groupId: String, epoch: UInt32, member: String,
        from adminUserId: String, senderId: String
    ) {
        if let entry = GroupRegistry.shared.entry(for: groupId) {
            // Authorization: admin must actually be in the admin set.
            // Ignore mismatches between sender_id and from to be lenient
            // (server might rewrite sender_id; the from field is our
            // ground-truth admin claim, but it MUST be in admins[]).
            guard entry.admins.contains(adminUserId) || entry.admins.contains(senderId) else {
                print("[AppState] member_added from non-admin \(senderId)/from=\(adminUserId) for \(groupId) — rejecting")
                return
            }
            GroupRegistry.shared.addMember(groupId: groupId, userId: member)
        } else if member == currentUserId {
            // W403 auto-bootstrap: we've been added to a group we don't
            // know yet (Desktop/Android onboarding flow — no preceding
            // group_invite envelope). Persist a minimal registry entry
            // with admin=sender_id so subsequent member_added events
            // pass authorization.
            let now = Date()
            let entry = GroupRegistry.Entry(
                id: groupId,
                name: groupId.prefix(8) + "…", // placeholder; user can rename later
                members: [adminUserId, member],
                admins: [adminUserId],
                joinedAt: now,
                bootstrapped: false)
            GroupRegistry.shared.upsert(entry)
            // Bootstrap the GroupChatService session so subsequent
            // 0xE4 group ciphertexts decrypt. Members list at bootstrap
            // is incomplete — incremental member_added events fill it in.
            _ = GroupChatService.shared.session(
                groupId: groupId, members: [adminUserId, member],
                selfId: member)
            GroupRegistry.shared.markBootstrapped(groupId: groupId)
            // Surface a snackbar via NotificationCenter (the chat list
            // UI subscribes and shows "Aggiunto al gruppo X da Y").
            NotificationCenter.default.post(
                name: AppState.groupAutoJoinedNotification,
                object: nil,
                userInfo: [
                    "groupId": groupId,
                    "fromAdmin": adminUserId,
                ])
        } else {
            // Unknown group AND we're not the new member. Ignore: this
            // is a fan-out for a group we're not in.
            print("[AppState] member_added for unknown group \(groupId) (member=\(member.prefix(8))…) — ignoring")
            return
        }
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupId])
    }

    @MainActor
    fileprivate func applyMemberRemoved(
        groupId: String, epoch: UInt32, member: String,
        from sender: String, senderId: String, voluntary: Bool
    ) {
        guard let entry = GroupRegistry.shared.entry(for: groupId) else { return }
        if !voluntary {
            guard entry.admins.contains(sender) || entry.admins.contains(senderId) else {
                print("[AppState] member_removed from non-admin \(senderId)/from=\(sender) for \(groupId) — rejecting")
                return
            }
        }
        if member == currentUserId {
            GroupRegistry.shared.remove(groupId: groupId)
            GroupChatService.shared.invalidate(groupId: groupId)
        } else {
            GroupRegistry.shared.removeMember(groupId: groupId, userId: member)
        }
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupId])
    }

    /// W403 — leave a group voluntarily. Ships a `member_left` envelope
    /// to every other member via 1:1 ratchet, then drops local state.
    @MainActor
    public func leaveGroup(groupId: String) {
        guard let selfId = currentUserId, !selfId.isEmpty else { return }
        guard let entry = GroupRegistry.shared.entry(for: groupId) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let env = GroupInviteEnvelope.MemberLeft(
            g: groupId, e: 1, member: selfId, from: selfId, ts: now)
        guard let json = GroupInviteEnvelope.encodeMemberLeft(env) else { return }
        for recipient in entry.members where recipient != selfId {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: [
                    "recipient": recipient,
                    "envelopeJson": json,
                ])
        }
        GroupRegistry.shared.remove(groupId: groupId)
        GroupChatService.shared.invalidate(groupId: groupId)
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupId])
    }
}

// MARK: - W391: video call pipeline lifecycle

extension AppState {
    /// Bring up the W391 video pipeline for the active call. Wires:
    ///   - outbound fragments → `wsClient.sendVideoFrame` to peer
    ///   - inbound `video_frame` WS events → `pipeline.acceptInboundFragment`
    /// Best-effort: a failure here doesn't abort the call (the audio
    /// path keeps working; the SwiftUI placeholders stay visible).
    @MainActor
    func startVideoPipeline(for peerId: String) async {
        // Tear down any leftover pipeline from a previous call.
        videoPipeline?.stop()

        let pipeline = VideoCallPipeline()

        // Resolve transport (WS client). Reuse the already-authenticated
        // liveProvider WS — creating a new BCryptoBackendProvider would
        // produce a disconnected WS whose sendVideoFrame calls are all
        // silently dropped (webSocketTask == nil → "DROPPED" log).
        guard let ws = liveProvider?.getWebSocketClient() else {
            print("[AppState] startVideoPipeline: no live WS provider, skipping")
            return
        }

        // W392 + W394: PQC seal/unwrap on the video transport, with
        // mid-call rekey support. The pipeline owns its own
        // PqcFrameEncryptor / Decryptor (under sealerLock) and
        // re-rotates whenever AppState calls rotatePqcSealer with a
        // fresh ML-KEM secret. Initial install with the current call
        // key (transitional or post-handshake); the wireSasReady-
        // ToController observer re-fires this with the real key once
        // the W389 broker reports.
        pipeline.rotatePqcSealer(self.callPqcSessionKey)

        // W397 — Android wire-compat is OPT-IN via UserDefaults.
        // Default ON for cross-platform interop (iOS↔Android needs
        // WireRelayFrameCodec); flip OFF via the Beta panel for
        // legacy iOS↔iOS-only mode (raw sealed fragments).
        let androidWire = (UserDefaults.standard.object(
            forKey: "qaudion.video.android_wire_compat") as? Bool) ?? true
        let seqCounter = AndroidVideoWireAdapter.SequenceCounter()

        // Outbound — each fragment ships as a video_frame WS envelope.
        // sealOutboundFragment reads the current sealer from the
        // pipeline so rekey is observed without rewiring closures.
        pipeline.onOutboundFragment = { [weak ws, weak pipeline] fragment in
            // Parse the iOS sub-header BEFORE sealing so the sealed
            // envelope carries it inside the ciphertext. The Android
            // wrapper only needs the metadata to rebuild the outer
            // mux header — the iOS receiver still uses the inner
            // sub-header for defragmentation.
            let parsed = AndroidVideoWireAdapter.parseIosFragment(fragment)
            let sealed = pipeline?.sealOutboundFragment(fragment) ?? fragment
            let toShip: Data
            if androidWire, let p = parsed,
               let android = AndroidVideoWireAdapter.encodeForAndroid(
                    sealedFragment: sealed,
                    innerFragment: p,
                    sequence: seqCounter.next()) {
                toShip = android
            } else {
                toShip = sealed
            }
            ws?.sendVideoFrame(recipientId: peerId, frame: toShip)
        }

        // Inbound — register the WS handler. When Android-wire is on,
        // unwrap the outer mux header first; either way feed the
        // post-seal envelope to acceptInboundFragment which applies
        // PQC unwrap internally before defragmentation.
        ws.registerHandler(type: "video_frame") { [weak pipeline] _, data in
            guard let pipeline = pipeline,
                  let b64 = data["frame"] as? String,
                  let raw = Data(base64Encoded: b64) else { return }
            if androidWire,
               let unwrapped = AndroidVideoWireAdapter.decodeFromAndroid(raw) {
                pipeline.acceptInboundFragment(unwrapped.sealedFragment)
            } else {
                pipeline.acceptInboundFragment(raw)
            }
        }

        do {
            try await pipeline.start()
            self.videoPipeline = pipeline
            // W398: spin up ABR loop on the same lifecycle.
            let abr = AbrController(pipeline: pipeline)
            abr.start()
            self.abrController = abr
            print("[AppState] video pipeline up for peer \(peerId), ABR active")
        } catch let err as VideoCallPipeline.PipelineError {
            // W393: user-visible error surfacing. The audio call keeps
            // running; only the video portion is degraded. Surface a
            // localized message via the existing errorMessage banner
            // rather than failing silently.
            switch err {
            case .permissionDenied:
                errorMessage = "Per attivare il video concedi l'accesso alla fotocamera in Impostazioni → Q-Audion."
            case .cameraUnavailable:
                errorMessage = "Fotocamera non disponibile su questo dispositivo."
            case .outputAttachFailed:
                errorMessage = "Impossibile inizializzare il flusso video."
            }
            print("[AppState] video pipeline start failed: \(err)")
        } catch {
            errorMessage = "Errore avvio video: \(error.localizedDescription)"
            print("[AppState] video pipeline start failed: \(error)")
        }
    }

    /// W393: bridge for VideoCallView's "Inverti" button.
    @MainActor
    func videoFlipCamera() {
        videoPipeline?.flipCamera()
    }

    /// W393: bridge for VideoCallView's "Cam ON/OFF" toggle.
    @MainActor
    func videoSetCameraEnabled(_ enabled: Bool) {
        videoPipeline?.setCameraEnabled(enabled)
    }
}

// MARK: - W366: group call lifecycle

extension AppState {

    /// Lazy-init shared GroupCallController backed by:
    /// - the live BCryptoGroupCallManager (WS protocol)
    /// - a KeychainGroupSessionVault (W364) for chain-state persistence
    /// - bound AudioCapture / AudioPlayback for the audio pipeline
    ///
    /// One controller per AppState; reused across calls. The
    /// PARITY_AUDIT_HONEST.md item "Group voice call ROTTO" is now
    /// fully closed — engine + WS protocol + audio pipeline + state
    /// persistence are all wired through this property.
    func ensureGroupCallController(
        _ manager: BCryptoGroupCallManager
    ) -> GroupCallController {
        if let existing = groupCallController {
            return existing
        }
        let controller = GroupCallController(manager: manager)
        // Attach the shared audio capture / playback so the
        // controller drives them in lockstep with call state.
        let capture = AudioCapture()
        let playback = AudioPlayback()
        controller.attachAudioPipeline(capture: capture, playback: playback)
        groupCallController = controller
        return controller
    }
}

// MARK: - W351: 1:1 v3 ratchet decrypt routing

extension AppState {

    /// W357: Keychain-backed ratchet vault. Each (epochId, peerId)
    /// snapshot lives in its own keychain item with
    /// `WhenUnlockedThisDeviceOnly`. Survives process death so long-
    /// offline windows still decrypt cleanly when iOS comes back online.
    /// Falls back to in-memory if keychain access fails (rare; would
    /// require the device to be locked or a corrupted item).
    private static let ratchetVault: RatchetVault = KeychainRatchetVault()
    private static let ratchet: MessageRatchet = MessageRatchet(vault: ratchetVault)

    /// Decrypt a v3.1 wire blob. Bootstraps the per-peer session from
    /// `psk` if the vault has no snapshot yet. Throws on AEAD failure /
    /// replay / wire malformation, matching the v1 path's error
    /// behaviour so the surrounding catch can trigger auto-rekey.
    func ratchetDecryptV3(wire: Data, psk: Data, senderId: String, msgId: String) throws -> Data {
        let selfId = currentUserId ?? ""
        let session = try Self.ratchet.ensureSession(
            epochId: "v1",                  // single epoch until we wire negotiation
            selfId: selfId,
            peerId: senderId,
            pskRoot: psk
        )
        let aad = MessageRatchet.buildMessageAD(
            senderId: senderId, recipientId: selfId, clientMsgId: msgId)
        return try Self.ratchet.decryptOrThrow(
            session: session, wire: wire, aad: aad)
    }
}

// MARK: - W347: WebRTC bridge

#if canImport(WebRTC)
extension AppState {
    /// W347: handle inbound `call_offer` SDP via the WebRTC bridge. Spins
    /// up a fresh QAudionWebRtcCallController for this call, applies the
    /// remote offer, and ships the answer through the existing
    /// `CallingApi.sendCallAnswer` envelope.
    func handleIncomingWebRtcOffer(
        callerId: String,
        sdp: String,
        peerCapabilities: [String]? = nil,
        hasVideo: Bool = false
    ) {
        guard let provider = liveProvider else { return }
        // Spawn a controller bound to the live CallingApi + relay provider.
        let controller = QAudionWebRtcCallController(
            callingApi: provider.callingApi,
            relayProvider: ensureRelayProvider()
        )
        // W411: apply Transport overrides on the responder side too.
        if let customUrl = TransportGate.preferredTurnUrl {
            controller.iceServerOverride = [
                RTCIceServer(urlStrings: [customUrl.absoluteString])
            ]
        }
        if TransportGate.forcesRelay {
            controller.iceTransportPolicyOverride = .relay
        }
        // Commit 77583315 parity — DI the rotating-key SFrame sealer
        // factory on the responder side too. Without this, two
        // updated peers would still pick `.legacy` because the
        // factory is the gate inside `ensureVideoSealer()`.
        controller.sframeVideoSealerFactory = { keyProvider in
            SFrameVideoSealer.forRotatingKey(keyProvider)
        }
        // For incoming video calls, start the VideoCallPipeline first so it
        // owns the AVCaptureSession. Tell the WebRTC controller to skip its
        // own RTCCameraVideoCapturer — avoids the dual AVCaptureSession
        // conflict that mirrors the outgoing-call handling in startCall.
        if hasVideo { controller.useExternalVideoSource = true }
        // Commit 540b79c0 parity — apply the peer's caps (from this
        // envelope OR the earlier call_incoming stash) before
        // acceptIncomingCall builds the peer connection. The Android
        // CallController consults peerNegotiated() at video-pipeline
        // pickup time; iOS mirrors that contract.
        let caps = peerCapabilities ?? pendingPeerCapabilities
        let audioOnly = !hasVideo
        webRtcController = controller
        // Mirror of the caller-side wiring: Android sends remote video via
        // WebRTC RTP so the callee also needs this callback.
        controller.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor [weak self] in
                self?.remoteWebRtcVideoTrack = track
            }
        }
        let cid = callerId
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if hasVideo {
                self.isVideoCall = true
                // Start the callee's WS video pipeline so that inbound
                // video_frame envelopes are decoded + displayed and
                // outbound frames from the camera are shipped to the peer.
                // Mirrors the startVideoPipeline call on the caller side
                // in startCall so both peers have symmetric transport.
                await self.startVideoPipeline(for: cid)
            }
            do {
                try await controller.acceptIncomingCall(callerId: cid,
                                                         offerSdp: sdp,
                                                         audioOnly: audioOnly)
                controller.acceptPeerCapabilities(caps)
                print("[AppState] WebRTC: accepted incoming call from \(cid) (video=\(hasVideo), peerCaps=\(caps ?? []))")
                // Wire VideoCallPipeline → RTCVideoSource (callee side) so
                // Android sees iOS camera video over WebRTC RTP.
                #if os(iOS)
                if hasVideo, let capturer = controller.webrtcPixelBufferCapturer {
                    self.videoPipeline?.onCapturedPixelBuffer = {
                        [weak capturer] pixelBuffer, timestampNs in
                        capturer?.push(pixelBuffer, rotation: ._0,
                                       timestampNs: timestampNs)
                    }
                }
                #endif
            } catch {
                print("[AppState] WebRTC acceptIncomingCall failed: \(error)")
            }
        }
    }

    func handleIncomingWebRtcAnswer(sdp: String, peerCapabilities: [String]? = nil) {
        guard let controller = webRtcController as? QAudionWebRtcCallController else {
            print("[AppState] WebRTC: ignoring call_answer (no active controller)")
            return
        }
        // Commit 540b79c0 parity — caller side learns the peer's caps
        // here for the first time (call_offer goes outbound from us;
        // call_answer is the peer's first envelope back). Cache them
        // before applying the SDP so the pipeline pick has the right
        // negotiation state at video setup time.
        controller.acceptPeerCapabilities(peerCapabilities)
        Task {
            do {
                try await controller.handleRemoteAnswer(sdp: sdp)
                print("[AppState] WebRTC: applied remote answer SDP (\(sdp.count) chars, peerCaps=\(peerCapabilities ?? []))")
            } catch {
                print("[AppState] WebRTC handleRemoteAnswer failed: \(error)")
            }
        }
    }

    func handleIncomingWebRtcIce(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        guard let controller = webRtcController as? QAudionWebRtcCallController else { return }
        controller.handleRemoteIce(candidate: candidate,
                                     sdpMid: sdpMid,
                                     sdpMLineIndex: sdpMLineIndex)
    }
}
#else
extension AppState {
    /// WebRTC framework not available in this target — no-op stubs so the
    /// AppState handlers keep their call sites intact.
    func handleIncomingWebRtcOffer(
        callerId: String,
        sdp: String,
        peerCapabilities: [String]? = nil,
        hasVideo: Bool = false
    ) {
        print("[AppState] WebRTC: call_offer received but WebRTC framework not linked")
    }
    func handleIncomingWebRtcAnswer(sdp: String, peerCapabilities: [String]? = nil) {
        print("[AppState] WebRTC: call_answer received but WebRTC framework not linked")
    }
    func handleIncomingWebRtcIce(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {}
}
#endif
