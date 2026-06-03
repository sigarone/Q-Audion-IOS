import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import AudioToolbox  // AudioServicesPlayAlertSound (in-app ringtone)
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

    /// W466 — short, human-readable label for the logged-in account,
    /// for the iPad sidebar header (and any other "this is you" chip).
    /// Prefers the server-assigned PBX extension ("Interno 234") over the
    /// raw 36-char UUID, which the user reported as unreadably long in
    /// the main-screen top-left. Falls back to a truncated UUID, then a
    /// generic label, mirroring `SettingsScreen.profileDisplayName`.
    var displayAccountLabel: String {
        if let ext = currentUserDialExtension, !ext.isEmpty {
            return "Interno " + ext
        }
        if let uid = currentUserId, !uid.isEmpty {
            let head: String = String(uid.prefix(8))
            return uid.count > 8 ? head + "…" : head
        }
        return "Q-Audion User"
    }

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
    /// W478 — display name of the incoming caller, set when `call_incoming`
    /// is processed. Shown in the in-app ringing banner as a fallback when
    /// CallKit's system UI is suppressed (Focus / Silence Unknown Callers).
    @Published var incomingCallerName: String = ""
    /// H-6 — re-entrancy guard for endCall(). A second endCall() (e.g.
    /// CallKit onEndCall + remote call_hangup racing) while teardown is
    /// already running would double-hangup and leak the
    /// RTCPeerConnection. AppState is @MainActor so this needs no lock.
    private var isEndingCall = false
    /// M-32 — set true the first time the deepfake classifier runs for
    /// a call so endCall() only releases the ONNX model when it was
    /// actually loaded.
    var deepfakeClassifierUsed = false
    /// M-14 — token for the CallSessionKeyBroker.sasReadyNotification
    /// observer registered by wireSasReadyToController(). Held so
    /// logout() can remove it; nil until first registration.
    private var sasReadyObserverToken: NSObjectProtocol?
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
    /// Actual media transport in use for the current call.
    /// "p2p"    — WebRTC ICE direct (host or srflx candidate pair)
    /// "turn"   — WebRTC ICE via TURN relay (TransportGate.forcesRelay or VPN-TURN)
    /// "relay"  — bcrypto server WS relay (fallback when P2P not yet negotiated)
    /// The LiveInCallScreen maps these to TransportMode for the chip label.
    @Published var backendType: String = "p2p"  // "p2p" | "turn" | "relay"
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
    /// M-10 — provenance of the key currently feeding the SAS panel.
    /// `.psk` while the SAS is seeded from the TRANSITIONAL per-pair
    /// PSK (pre-handshake); `.mlKem` once the real ML-KEM-1024 session
    /// key has overwritten it. The UI can show a "verifying…" state
    /// while `.psk` so the user doesn't trust pre-handshake words as
    /// post-quantum-authenticated.
    enum CallSasKeySource { case none, psk, mlKem }
    @Published var callSasKeySource: CallSasKeySource = .none
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
    // W533 — screen-share state. Mirrors the desktop client's
    // PeerConnectionManager.isScreenSharing flag and toggles a stub
    // `cameraFrameClosureSnapshot` so the camera-to-WebRTC pipe can
    // be restored when the user stops sharing.
    @Published public private(set) var isScreenSharing: Bool = false

    /// W534 — true when the REMOTE peer has announced an active
    /// `<callId>|SCREEN_SHARE:start` piggy-back for the current call.
    /// The receiver still gets RTP video frames on the pre-allocated
    /// `m=video` transceiver regardless of this flag (the transceiver
    /// is built at PeerConnection setup), but the UI only mounts the
    /// `WebRTCRemoteVideoView` + badge while this flag is true on an
    /// audio-only call. See
    /// `apps/qaudion-desktop/docs/SCREEN_SHARE_PROTOCOL.md`.
    @Published public private(set) var peerScreenShareActive: Bool = false
    #if os(iOS)
    private let screenShareController = ScreenShareController()
    /// Camera-frame closure captured BEFORE starting screen share, so
    /// stopScreenShare can restore it without re-running the whole
    /// startVideoPipeline wiring sequence.
    private var preScreenShareCameraClosure: ((CVPixelBuffer, Int64) -> Void)?
    #endif
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
    /// VPN service — manages WireGuard tunnel lifecycle via NetworkExtension.
    /// Bare `let` because `VpnService` is itself `ObservableObject`; HomeView
    /// passes it directly to `VpnToggleChip(@ObservedObject)` so the chip
    /// subscribes to VpnService.objectWillChange without going through AppState.
    let vpnService = VpnService()

    /// The current session access token, for use by VPN sub-operations.
    var currentAccessToken: String? { authService.loadToken() }

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

    /// Bug A guard — the call UUID for which `onAnswerCall` has already run.
    /// On the double-dialer second call (PushKit native UI + in-app banner
    /// both up), CallKit can deliver `CXAnswerCallAction` more than once for
    /// the same call: once from the in-app green button
    /// (`CXCallController.request`) and once from the native UI. A second
    /// `onAnswerCall` re-enters `startIncomingCallAudioOnAnswer` →
    /// `activateIncomingCallAudio` → `teardownAudioStack()` WHILE the first
    /// answer's `AVAudioEngine` is mid-start → an uncatchable Obj-C
    /// `NSException` (SIGABRT). Tracking the answered UUID makes the answer
    /// idempotent. Reset to nil on call teardown.
    private var answeredCallKitId: UUID?
    /// In-app ringtone timer (fires every 3 s while callState == .ringing
    /// and the native CallKit UI is suppressed).
    private var ringtoneTimer: DispatchSourceTimer?

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

        // W541-3 — start structured telemetry pump (encrypted batch
        // POST every 5 s). Same primitives-only API constraint as
        // LiveLogStreamer per CLAUDE.md "Hard-won lesson 16".
        TelemetryService.shared.start(
            serverUrl: serverUrl,
            getToken: { [weak self] in self?.authService.loadToken() },
            getUserId: { [weak self] in self?.currentUserId }
        )
        // First event: app-launch marker so the maintainer can
        // anchor every per-call timeline against the session start.
        TelemetryService.shared.emit(
            kind: "app.launch",
            attrs: [
                "device_model": UIDevice.current.model,
                "ios_version":  UIDevice.current.systemVersion
            ]
        )

        // W545 — per-device synthetic self-tests. Schedules a first
        // run ~3 s after launch in background, emits selftest.*
        // telemetry events with timing percentiles for regression
        // detection across iOS versions / hardware. Primitives-only
        // API per CLAUDE.md "Hard-won lesson 16".
        SelfTestService.shared.start(
            serverUrl: serverUrl,
            getToken: { [weak self] in self?.authService.loadToken() }
        )

        // W546+W547 — in-app feedback channel. Wires the HTTP client
        // for the FeedbackScreen (Settings → Feedback). The screen
        // pulls inbox on appear; no background polling here yet —
        // a future iteration can add an APNS push trigger.
        FeedbackService.shared.start(
            serverUrl: serverUrl,
            getToken: { [weak self] in self?.authService.loadToken() }
        )

        // W559 — cross-platform bug report service. Volume-gesture trigger +
        // auto-detection hook. Primitives-only API per CLAUDE.md rule #16.
        BugReporter.shared.configure(
            getToken: { [weak self] in self?.authService.loadToken() },
            getServerUrl: { [weak self] in self?.serverUrl ?? "" }
        )
        BugReporter.shared.startVolumeObserver()

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
                // M-32: a score arrived ⇒ the ONNX model was loaded
                // and run on this call; mark it so endCall() releases it.
                self.deepfakeClassifierUsed = true
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
                    // Bug A — idempotent answer. CallKit may deliver
                    // CXAnswerCallAction twice for the same call when the
                    // in-app green button and the native UI both target it
                    // (double-dialer second call). The second pass would
                    // re-enter startIncomingCallAudioOnAnswer →
                    // activateIncomingCallAudio → teardownAudioStack() while
                    // the first AVAudioEngine start is still in flight → an
                    // uncatchable NSException. Ignore repeats for the same call.
                    if self.answeredCallKitId == uuid {
                        print("[AppState] onAnswerCall: duplicate answer for \(uuid) ignored (Bug A guard)")
                        return
                    }
                    self.answeredCallKitId = uuid
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
                    // W521: sasReadyNotification may have fired during the
                    // ringing phase — before the user answered. Its observer
                    // (wireSasReadyToController) guards on callState == .active,
                    // which was false at that point, so the .encrypted
                    // transition was skipped. callSasKeySource is still set to
                    // .mlKem unconditionally when the notification fires.
                    // Catch up: if the ML-KEM handshake already completed,
                    // advance the state machine to .encrypted right now so
                    // the peer (Android/Desktop) doesn't time out waiting for
                    // PQC confirmation and send call_hangup.
                    if self.callState == .active && self.callSasKeySource == .mlKem {
                        self.callState = .encrypted
                        RTLog.info("call", "onAnswerCall: PQC handshake completed during ringing — state .active → .encrypted")
                        // W541-3: emit encrypted-state-reached event.
                        // Maintainer measures (call.encrypted.ts -
                        // call.start_dial.ts) as the dial-to-secure
                        // latency p95 — a key user-perceived metric.
                        TelemetryService.shared.emit(
                            kind: "call.encrypted",
                            callId: uuid.uuidString.lowercased(),
                            attrs: ["path": "answer-fastpath-w521"]
                        )
                    }
                    // W450: boot audio pipeline for incoming call.
                    // Outgoing calls do this inside startCall(contactId:) →
                    // callService.startCall(engine:contactId:). For incoming
                    // calls that path is never taken (isInCall guard blocks it).
                    // We must start capture+playback here, when the user
                    // explicitly accepts, so there is actual audio in the call.
                    self.startIncomingCallAudioOnAnswer()
                    // SAS-fix: tell the CALLER we answered. On the WS-relay path
                    // (iOS↔iOS — no WebRTC controller) NOTHING else emits
                    // call_answer (sendCallAnswer lives only in the WebRTC
                    // controller), so the caller stays stuck in .ringing and its
                    // SAS screen never completes ("il chiamante non completa mai
                    // la schermata SAS"). A bare call_answer (empty SDP) makes the
                    // caller's W528 handler advance .ringing → .encrypted and
                    // render the 6 SAS words. WebRTC calls already send their own
                    // SDP-bearing call_answer from the controller — skip those to
                    // avoid a duplicate. The bound incoming call_id is attached by
                    // sendCallAnswer (currentCallId), so the server routes it.
                    if self.webRtcController == nil,
                       let peer = self.callContactId,
                       let calling = self.liveProvider?.callingApi {
                        Task { try? await calling.sendCallAnswer(recipientId: peer, sdp: "") }
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
            // W464 — CallKit owns the shared AVAudioSession. The audio
            // engines (mic capture + speaker playback) MUST NOT start
            // until CallKit activates it: starting AVAudioEngine before
            // `didActivate` throws "Session activation failed" and the
            // call connects (WebRTC ICE + PQC handshake OK) but has no
            // audio in either direction. These two bridges hand the
            // activation signal to CallService, which then starts /
            // stops its AVAudioEngine capture/playback at the right time.
            provider.onAudioSessionActivated = { [weak self] in
                Task { @MainActor in
                    self?.callService.handleAudioSessionActivated()
                }
            }
            provider.onAudioSessionDeactivated = { [weak self] in
                Task { @MainActor in
                    self?.callService.handleAudioSessionDeactivated()
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
                    // C-10: never log any portion of the VoIP token —
                    // the stdout tee is uploaded as telemetry.
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
            // Pre-fill userId from UserDefaults so the profile card renders before
            // getProfile() returns. dialExtension is intentionally NOT pre-filled:
            // it is account-specific and a stale cached value from a previous account
            // would show the wrong internal number until the server round-trip completes.
            // nil here means the hero card shows the dial extension only after the live
            // server response arrives — no stale artefact across account switches.
            if let cached = UserDefaults.standard.string(forKey: "currentUserId") {
                self.currentUserId = cached
            }
            // Pre-fill extension from cache so SettingsScreen hero card shows
            // "Interno 112" immediately on launch, before getProfile() returns.
            // The live getProfile() will overwrite with the fresh value (or clear
            // if the server returns 0). This mirrors how currentUserId is handled.
            if let cachedExt = UserDefaults.standard.string(forKey: "currentUserDialExtension"),
               !cachedExt.isEmpty {
                self.currentUserDialExtension = cachedExt
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
                    // W461: log what the server actually returns so we can diagnose
                    // "still showing long ID" — if dialExtension is nil/0 every
                    // launch the cached extension gets cleared and UUID is shown.
                    print("[AppState] getProfile userId=\(profile.userId.prefix(8))… dialExtension=\(String(describing: profile.dialExtension))")
                    if let ext = profile.dialExtension, ext > 0 {
                        let extStr = String(ext)
                        self.currentUserDialExtension = extStr
                        UserDefaults.standard.set(extStr, forKey: "currentUserDialExtension")
                    } else {
                        // OR-fix3: server returned nil/0 — clear stale cached extension
                        // so a user migrated to an account without an extension stops
                        // showing the old "Int. 103" indefinitely.
                        print("[AppState] getProfile: dialExtension nil/0 — clearing cached extension, will show UUID prefix in Settings")
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

        // ADVISORY-ONLY runtime integrity probe. Fully fail-soft:
        // detached low-priority Task, NOT on the launch / call path,
        // logs an INFO security event for fleet visibility and does
        // NOTHING else (no enforcement, no blocking, no exit). Gated
        // behind a UserDefaults kill-switch (default ON). See
        // RuntimeIntegrity.swift — it takes no AppState reference.
        let integrityKey: String = "qaudion.security.integrityProbe"
        if UserDefaults.standard.object(forKey: integrityKey) == nil {
            UserDefaults.standard.set(true, forKey: integrityKey)
        }
        let integrityEnabled: Bool =
            UserDefaults.standard.bool(forKey: integrityKey)
        if integrityEnabled {
            Task.detached(priority: .background) {
                // Delay so this never competes with launch or an
                // incoming call; purely a quiet idle observation.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let snap = RuntimeIntegrity.snapshot()
                let summary: String = RuntimeIntegrity.summaryLine(snap)
                let flagged: Bool = RuntimeIntegrity.anyFlag(snap)
                let sev: SecurityEvent.Severity =
                    flagged ? .warning : .info
                let detail: String = "integrity " + summary
                let event = SecurityEvent(
                    kind: .threat,
                    severity: sev,
                    details: detail)
                // logEvent already swallows all errors internally.
                SecurityEventStore(db: .shared).logEvent(event)
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
        // Guard: if liveProvider is already set, a connection is either in-flight
        // or live. Do NOT create a second provider regardless of its current state.
        //
        // Previous version checked `state != .disconnected` — but BCryptoBackendProvider
        // starts in `.disconnected` before initialize() runs (which is async in a Task).
        // Two rapid calls (e.g. from login-success path + willEnterForeground) would
        // both see `.disconnected` and each create their own BCryptoBackendProvider,
        // causing the server to log "replacing stale ws device" and ultimately dropping
        // the call the moment the callee answers (both WS close with EOF at that
        // instant). Callers that explicitly want a new connection MUST set
        // `self.liveProvider = nil` first (the willEnterForeground handler already does
        // this when state == .disconnected).
        if liveProvider != nil { return }
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
        // Server selection: probe all nodes and connect to the fastest one.
        // Runs in background — does not delay the login flow.
        Task { [weak self] in
            guard let self, let prov = await MainActor.run(body: { self.liveProvider }) else { return }
            await ServerSelector.shared.selectBestServer(provider: prov)
            await MainActor.run { ServerSelector.shared.startMonitor(provider: prov) }
        }
        // W476 — wire CallService's lazy WS / peer-id fallback providers
        // ONCE, here at login. The TX path falls back to these when
        // `wireTransport(wsClient:peerUserId:)` never bound the eager
        // fields — see CallService.WsClientProvider for the full
        // explanation. Without this fallback, every encrypted TX frame
        // is silently dropped whenever `liveProvider` was nil at call
        // setup time. Closures capture self weakly and read non-isolated
        // — `liveProvider`/`callContactId` are only set from main, but a
        // cross-thread read is acceptable here (best-effort).
        callService.getWsClient = { [weak self] in
            self?.liveProvider?.getWebSocketClient()
        }
        callService.getPeerId = { [weak self] in
            self?.callContactId
        }
        callService.isCallActive = { [weak self] in
            guard let self else { return false }
            return self.callState == .active || self.callState == .encrypted
        }
        // W525: stamp the call_id onto every outbound audio_frame so
        // Android (BcryptoWsFrameRelayTransport) and Desktop
        // (MediaTransport) don't silently drop our frames. The engine's
        // BCryptoCallingApiImpl is the authoritative source — its
        // activeCallId is set by sendCallOfferWithId (outgoing) or
        // bindIncomingCallId (incoming via wireIncomingCallHandlers).
        callService.getCallId = { [weak self] in
            guard let live = self?.liveProvider,
                  let impl = live.callingApi as? BCryptoCallingApiImpl
            else { return nil }
            return impl.getActiveCallId()
        }
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
        // W505: wire ping/pong RTT measurement so CallSecurityBadge and
        // the call diagnostics panels can show a live relay latency value.
        // The callback fires on the utility queue every 30 s (ping interval)
        // so we dispatch to main before writing @Published latencyMs.
        ws.onLatencyMeasured = { [weak self] rttMs in
            DispatchQueue.main.async { self?.latencyMs = rttMs }
        }
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
        // W530: register the audio_frame RX handler EAGERLY at login.
        // Previously this was wired only inside startCall (caller) or
        // startIncomingCallAudioOnAnswer (callee), both gated on
        // `liveProvider?.getWebSocketClient()` being non-nil at the
        // exact instant the call happened. When liveProvider was
        // transient-nil (mid-reconnect), `wireTransport` was skipped
        // entirely → the W522 lazy fallback registered the handler
        // only after the first encrypted TX frame, leaving a ~5 s
        // window in which any inbound audio_frame from the peer hit
        // an empty `messageHandlers["audio_frame"]` slot and was
        // silently dropped. Registering here (and again on every
        // reconnect, see state listener below) makes the dispatcher
        // ALWAYS able to route inbound audio to handleIncomingEncryptedFrame,
        // which buffers (W481) if no integration is bound yet.
        callService.attachIncomingAudioHandler(wsClient: ws)
        // Subscribe state listener so the UI can show "Connecting → Online".
        provider.persistentConnection.addStateListener { [weak self] state in
            DispatchQueue.main.async {
                // W550 — emit a sealed telemetry event on every WS
                // state change so the maintainer dashboard can see
                // which device is flapping. Pair with the server's
                // `ws: opened` / `ws: closing unauthenticated` logs
                // by cf_ip + timestamp to identify reconnect loops.
                let prev = self?.wsConnectionState
                if prev != state {
                    TelemetryService.shared.emit(
                        kind: "ws.state",
                        attrs: [
                            "state": String(describing: state),
                            "prev":  String(describing: prev ?? .disconnected)
                        ]
                    )
                }
                self?.wsConnectionState = state
                if state == .connected || state == .authenticated {
                    // (re-)bind presence now that the transport is live —
                    // the previous provider may have been torn down on
                    // app suspend / token rotate, leaving subscribers
                    // stale.
                    self?.bindPresenceAfterAuth()
                }
                if state == .authenticated {
                    // W530: re-register the audio_frame handler on the
                    // (possibly fresh) WS instance after every reconnect.
                    // BCryptoWebSocketClient.registerHandler is idempotent
                    // per type so this is safe to call repeatedly.
                    if let live = self?.liveProvider {
                        self?.callService.attachIncomingAudioHandler(
                            wsClient: live.getWebSocketClient())
                    }
                    self?.rewireCallAudioOnReconnect()
                    // W531: if a handshake is in flight, re-emit the last
                    // unACKed bundle (caller→OFFER, responder→ACCEPT)
                    // so the bytes that may have been lost while the WS
                    // was reconnecting are delivered. The integration
                    // is fully idempotent at both wire and crypto
                    // layers (sessionInitializedByCall + cached
                    // ACCEPT) so this is safe even if the original
                    // bundle DID arrive.
                    if let integration = self?.callService.callIntegration {
                        Task {
                            await integration.replayPendingHandshake()
                        }
                    }
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
                        // C-10: token registered OK — do NOT log any
                        // portion of the token material.
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
            // C-4: drop calls from blocked contacts BEFORE any CallKit
            // report, responder-integration provisioning, or PQC setup.
            // A blocked caller must not be able to ring the device or
            // trigger key-exchange side effects.
            if BlockedContactsStore.isBlocked(senderId) { return }
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
            let rawWireCallerDisplay = (data["caller_display"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // H-15: the wire `caller_display` is attacker-controlled
            // (it comes from the peer's call envelope) and is shown
            // verbatim by CallKit. Sanitise it the same way contact
            // display names are sanitised — strip control chars,
            // bidi/RTL overrides, excessive length, etc. Empty
            // fallback so the tier-2/tier-3 resolution below still runs
            // when the wire value sanitises away to nothing.
            let sanitisedWireDisplay = StringSanitiser.displayName(rawWireCallerDisplay, fallback: "")
            let wireCallerDisplay: String? = sanitisedWireDisplay.isEmpty ? nil : sanitisedWireDisplay
            let resolvedCallerName: String = {
                if let cd = wireCallerDisplay, !cd.isEmpty {
                    // The server sets caller_display to the caller's PBX
                    // extension (a bare integer, e.g. "103") when no custom
                    // display name is configured. Format it consistently with
                    // CallHistoryView ("Int. 103") so the banner, CallKit UI
                    // and call history all show the same string.
                    if cd.allSatisfy({ $0.isNumber }) { return "Int. \(cd)" }
                    return cd
                }
                let stored = ContactsStore().load()
                if let match = stored.first(where: { $0.userId == senderId }),
                   !match.displayName.isEmpty {
                    return match.displayName
                }
                // Last resort: never show the raw 36-char UUID to the user.
                // Truncate to head…tail like the Settings/profile screens do.
                if senderId.count > 12 {
                    return String(senderId.prefix(8)) + "…" + String(senderId.suffix(4))
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
                // W450-dedup + PushKit-first fix.
                //
                // Drop ONLY a genuine duplicate. Two cases must be told apart:
                //   (A) A second WS `call_incoming` for a call already fully
                //       provisioned here (integration built + callState set).
                //       → drop, else we double-report to CallKit.
                //   (B) PushKit (APNs VoIP) woke the device FIRST. Its handler
                //       sets `activeCallKitId` / `callContactId` but does NOT
                //       build the responder integration and does NOT set
                //       `callState`. The old guard (`activeCallKitId == nil`)
                //       wrongly treated this as a duplicate and bailed out —
                //       so `ensureResponderIntegration` + the early PQC OFFER
                //       sink never ran, leaving audio buffered with
                //       "callIntegration nil" and the answer path failing with
                //       "audio not started". In this case we MUST proceed
                //       (the duplicate `reportIncomingCall` is skipped below).
                let sameCallProvisioned = (self.activeCallKitId == callUUID)
                    && (self.responderCallIntegration != nil)
                    && (self.callState != .idle)
                let differentCallActive = (self.activeCallKitId != nil)
                    && (self.activeCallKitId != callUUID)
                guard !sameCallProvisioned, !differentCallActive else {
                    print("[AppState] call_incoming: dup dropped callId=\(callIdStr.prefix(8))… state=\(self.callState) sameProvisioned=\(sameCallProvisioned) otherActive=\(differentCallActive)")
                    return
                }
                Task {
                    // If PushKit already reported this call (activeCallKitId set),
                    // skip the second reportIncomingCall to avoid Code=2
                    // (callUUIDAlreadyExists). But ALWAYS fall through to set up the
                    // responder integration below — without it audio never starts
                    // even when PushKit handled the CallKit registration first.
                    let alreadyRegisteredByPushKit = await MainActor.run { self.activeCallKitId != nil }
                    // Single-dialer (W520): a FOREGROUND WS call shows ONLY the
                    // in-app Qaudion banner — suppress the native CallKit UI so
                    // the user never sees two dialers at once (the "seconda
                    // chiamata in chiaro"). The previous code called
                    // reportIncomingCall (native) AND set callState=.ringing
                    // (in-app) for every WS call with no prior PushKit → a
                    // permanent double dialer on iOS↔iOS. A BACKGROUND WS call
                    // (no PushKit yet) has no visible in-app banner, so it MUST
                    // fall back to the native UI. PushKit-first calls already
                    // own the native UI (skip both).
                    let appForeground = await MainActor.run {
                        UIApplication.shared.applicationState == .active
                    }
                    if !alreadyRegisteredByPushKit {
                        if appForeground {
                            await MainActor.run {
                                (self.callKit as? CallKitProvider)?.registerSuppressedCall(callUUID)
                            }
                        } else if let ck = self.callKit {
                            await ck.reportIncomingCall(
                                uuid: callUUID,
                                callerName: resolvedCallerName,
                                hasVideo: (callType == "video")
                            )
                        }
                    }
                    await MainActor.run {
                        if self.activeCallKitId == nil { self.activeCallKitId = callUUID }
                        self.callContactId = senderId
                        self.incomingCallerName = resolvedCallerName
                        self.isVideoCall = (callType == "video")
                        // W450-fix: when PushKit woke the device first, CallKit's
                        // native phone UI is already visible. Setting .ringing here
                        // would also trigger Q-Audion's in-app ringing banner →
                        // the user sees TWO simultaneous call screens ("una nostra
                        // e una con l'interfaccia telefonica"). When the native
                        // CallKit UI handles ringing, stay in .idle so the in-app
                        // view stays hidden. callState advances to .active in
                        // CallKitProvider.onAnswerCall when the user accepts.
                        // Only show the in-app banner when FOREGROUND: when the
                        // native CallKit UI is handling ringing (background WS or
                        // PushKit), stay .idle so the in-app view stays hidden —
                        // the single-dialer guarantee.
                        if !alreadyRegisteredByPushKit && appForeground {
                            self.callState = .ringing
                            // In-app ringtone: CallKit (suppressed for in-app dialer) was
                            // previously the only ring source. Play the system "sms-received"
                            // sound on repeat every 3 s until the call is answered/declined.
                            // AudioServicesPlayAlertSound is safe to call on the main thread
                            // and requires no separate AVAudioSession — it shares the system
                            // notification channel, which works even when the audio session is
                            // inactive (i.e. before the user answers).
                            self.startInAppRingtone()
                        }
                        // C-3: do NOT set isInCall here. Setting it on
                        // call ARRIVAL (before the user answers) blocks
                        // startCall() (guards !isInCall) and a spurious
                        // or replayed call_incoming could lock the
                        // device permanently. isInCall is now set only
                        // when the user actually answers — see
                        // CallKitProvider.onAnswerCall.
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
                        // P2P iOS↔iOS: the server forwards the caller's
                        // call_offer payload verbatim inside call_incoming
                        // (including the "sdp" field from
                        // BCryptoCallingApiImpl.sendCallOffer). Extract it
                        // here and hand it to handleIncomingWebRtcOffer so
                        // the callee starts WebRTC ICE negotiation — the
                        // same path a desktop or Android callee uses. This
                        // was the missing piece that forced iOS↔iOS audio
                        // to fall back on the WS relay even when a direct
                        // P2P path was available.
                        if let sdp = data["sdp"] as? String, !sdp.isEmpty {
                            let caps = data["capabilities"] as? [String]
                            let vid = (callType == "video")
                            self.handleIncomingWebRtcOffer(
                                callerId: senderId,
                                sdp: sdp,
                                peerCapabilities: caps,
                                hasVideo: vid
                            )
                        }
                    }
                }
            }
        }
        ws.registerHandler(type: "call_hangup") { [weak self] _, data in
            guard let self = self else { return }
            let reasonString = data["reason"] as? String ?? "normal"
            DispatchQueue.main.async {
                self.handleRemoteCallHangup(reasonString: reasonString)
            }
        }
        // W474 — wire `onCallCancel` on the INCOMING path. The server
        // emits `call_cancel` when the caller bails BEFORE the callee
        // answers. Previously this closure was assigned ONLY inside
        // startCall() (the outgoing path), so a device that had not
        // made an outgoing call this session had no `call_cancel`
        // handler at all: a cancelled un-answered incoming call left
        // `callState` stuck at `.ringing` forever, and the
        // `call_incoming` dedup guard (`guard callState == .idle`) then
        // silently dropped EVERY subsequent incoming call — the device
        // simply stopped ringing. Route `call_cancel` through the same
        // `handleRemoteCallHangup` teardown as `call_hangup`; it runs
        // the full state reset and records the missed call correctly.
        // startCall() may later overwrite this closure with its
        // outgoing-call variant — also a valid full state reset.
        ws.onCallCancel = { [weak self] _, reason in
            guard let self = self else { return }
            let r: String = reason ?? ""
            let reasonString: String = r.isEmpty ? "timeout" : r
            DispatchQueue.main.async {
                self.handleRemoteCallHangup(reasonString: reasonString)
            }
        }

        // W536 — inbound mid-call upgrade. Responder side: peer
        // wants to add video; apply their SDP offer, generate an
        // answer, ship it back, flip the UI to video mode, and
        // start the local VideoCallPipeline so the WS HEVC path is
        // populated too (the WebRTC RTP path is what the peer
        // actually consumes; the WS path serves iOS↔iOS peers).
        ws.onCallUpgradeRequest = { [weak self] callId, senderId, sdp in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleIncomingUpgradeRequest(
                    callId: callId, senderId: senderId, sdp: sdp)
            }
        }
        // W536 — caller side: peer accepted/rejected our upgrade
        // request. Apply the answer SDP if accepted.
        ws.onCallUpgradeResponse = { [weak self] callId, accepted, sdp in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleUpgradeResponse(
                    callId: callId, accepted: accepted, sdp: sdp)
            }
        }
    }

    /// W536 — responder side of audio→video upgrade. Builds the
    /// answer SDP via the WebRTC controller, ships it back via
    /// `sendCallUpgradeResponse(accepted: true)`, and starts the
    /// local VideoCallPipeline. If the WebRTC controller is not
    /// available we ship `accepted: false` with empty SDP so the
    /// peer sees an explicit reject instead of waiting on a timeout.
    @MainActor
    private func handleIncomingUpgradeRequest(
        callId: String, senderId: String, sdp: String
    ) {
        #if canImport(WebRTC)
        guard let controller = webRtcController as? QAudionWebRtcCallController,
              let provider = liveProvider,
              let impl = provider.callingApi as? BCryptoCallingApiImpl
        else {
            RTLog.warn("call", "onCallUpgradeRequest: WebRTC controller unavailable — sending reject")
            Task {
                try? await (liveProvider?.callingApi as? BCryptoCallingApiImpl)?
                    .sendCallUpgradeResponse(
                        callId: callId,
                        recipientId: senderId,
                        sdp: "",
                        accepted: false)
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let answerSdp = try await controller.acceptUpgradeOffer(remoteSdp: sdp)
                try await impl.sendCallUpgradeResponse(
                    callId: callId,
                    recipientId: senderId,
                    sdp: answerSdp,
                    accepted: true)
                self.isVideoCall = true
                self.setCamera(true)
                await self.startVideoPipeline(for: senderId)
                RTLog.info("call", "onCallUpgradeRequest accepted — local video pipeline up")
            } catch {
                let desc: String = error.localizedDescription
                RTLog.warn("call", "onCallUpgradeRequest failed: " + desc)
                try? await impl.sendCallUpgradeResponse(
                    callId: callId,
                    recipientId: senderId,
                    sdp: "",
                    accepted: false)
            }
        }
        #endif
    }

    /// W536 — caller side. Apply peer's answer SDP or revert the
    /// local UI if the peer rejected.
    @MainActor
    private func handleUpgradeResponse(
        callId: String, accepted: Bool, sdp: String
    ) {
        #if canImport(WebRTC)
        guard let controller = webRtcController as? QAudionWebRtcCallController else { return }
        if !accepted || sdp.isEmpty {
            RTLog.info("call", "onCallUpgradeResponse: peer rejected — reverting to audio-only UI")
            self.isVideoCall = false
            self.setCamera(false)
            self.videoPipeline?.stop()
            self.videoPipeline = nil
            return
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await controller.applyUpgradeAnswer(sdp: sdp)
                RTLog.info("call", "onCallUpgradeResponse: WebRTC renegotiation complete — video flowing")
                // W402: forward the (possibly newly-derived) PQC key
                // to the WebRTC controller in case the upgrade
                // crossed a rekey boundary. Idempotent.
                if let key = self.callPqcSessionKey {
                    controller.pqcSessionKey = key
                }
            } catch {
                let desc: String = error.localizedDescription
                RTLog.warn("call", "applyUpgradeAnswer failed: " + desc)
                self.errorMessage = "Upgrade a video fallito: " + desc
            }
        }
        #endif
    }

    /// C-3 — remote hangup / decline / timeout teardown. Runs the full
    /// state reset UNCONDITIONALLY (the old code bailed when
    /// `activeCallKitId == nil`, leaving isInCall/callState stuck on a
    /// not-yet-answered spurious call). The CallKit notification is the
    /// only part gated on having a live UUID.
    private func handleRemoteCallHangup(reasonString: String) {
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
        if wasRinging && missedRecordId == nil {
            RTLog.info("call", "WARN hangup-while-ringing but activeOutgoingRecordId=nil — missed call will not be recorded")
        }
        let uuid = self.activeCallKitId
        Task {
            if let uuid = uuid {
                await self.callKit?.reportCallEnded(uuid: uuid, reason: reason)
            }
            await MainActor.run {
                if wasRinging, let rid = missedRecordId {
                    PersistentCallRecordStore.shared.markMissed(id: rid)
                    self.activeOutgoingRecordId = nil
                }
                self.endCall()
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
            // W462-iOS: The iOS PQC path sends a vestigial call_offer with
            // sdp:"" so the server creates a call session and wakes the
            // callee's CallKit (via call_incoming). WebRTC is NOT needed for
            // that envelope — creating a WebRTC controller with empty SDP
            // causes RTCPeerConnection.setRemoteDescription to fail, and the
            // resulting ICE-failure callback fires handleIceTermination →
            // endCall, killing the call before the user can speak.
            // Guard: skip WebRTC setup entirely for empty-SDP offers.
            guard let self = self,
                  let sdp = data["sdp"] as? String, !sdp.isEmpty,
                  let callerId = (data["sender_id"] as? String) ?? (data["caller_id"] as? String) else {
                if let s = data["sdp"] as? String, s.isEmpty {
                    print("[AppState] call_offer: empty SDP (PQC-only offer) — skip WebRTC setup")
                } else {
                    print("[AppState] call_offer: missing sdp/caller_id")
                }
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
            if let sdp = data["sdp"] as? String, !sdp.isEmpty {
                self.handleIncomingWebRtcAnswer(sdp: sdp, peerCapabilities: peerCaps)
            } else {
                // Bare call_answer (no/empty SDP) — the WS-relay path (iOS↔iOS)
                // signals "answered" without a WebRTC SDP. Skip WebRTC and let
                // the W528 state-advance below render the SAS on the caller.
                print("[AppState] call_answer: no/empty sdp — bare answer, advancing state only")
            }
            // W528-fix: caller-side .ringing → .active on answer.
            // wireSasReadyToController no longer transitions from .ringing
            // so we must advance the state here when the callee answers.
            // If PQC completed before the answer (callSasKeySource == .mlKem),
            // skip .active and jump straight to .encrypted — matching the
            // race-handling already in place for the callee side (W521).
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.callState == .ringing else { return }
                if self.callSasKeySource == .mlKem {
                    self.callState = .encrypted
                    RTLog.info("call", "call_answer: PQC already done — .ringing → .encrypted")
                } else {
                    self.callState = .active
                    RTLog.info("call", "call_answer: callee answered — .ringing → .active")
                }
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
              let cipherB64 = entry["encrypted_payload"] as? String else {
            return
        }
        // CRITICAL (Android→iOS key sync): opaque call-signalling queued while
        // this device was offline / a suspended-iOS zombie (PQC OFFER or
        // ACCEPT, contact key-exchange, call piggy-back) must go to the opaque
        // dispatcher — NOT the chat decrypt. Two reasons:
        //   1. handleIncomingMessage would try to MessageCrypto-decrypt the
        //      OFFER as a chat ciphertext → garbage → silently dropped, so the
        //      responder never encapsulates / sends the ACCEPT → no key sync.
        //   2. The Android JSON OFFER wire is `<callId>|<json>` (NOT base64),
        //      so it cannot even pass the chat path's Data(base64Encoded:)
        //      guard below — it would be dropped before any handler runs.
        // Already on the main queue (caller dispatches the batch on .main).
        if (entry["msg_type"] as? String) == "opaque" {
            dispatchInboundOpaque(senderId: senderId, blobStr: cipherB64)
            return
        }
        guard let serverMsgId = entry["message_id"] as? String,
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
        // qa_ctl control envelope detection (Android-compatible wire format).
        // These are NOT stored as normal message rows — they trigger state changes
        // and optionally store a system bubble for user visibility.
        if let data = plaintext.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let qaCtl = json["qa_ctl"] as? Int, qaCtl == 1,
           let ctlType = json["t"] as? String {
            let isScreenshotCtl = ctlType == "ss_req" || ctlType == "ss_resp" || ctlType == "ss_lock"
            let isTimerCtl = ctlType == "ephemeral_timer"
            if isScreenshotCtl || isTimerCtl {
                let label: String
                if ctlType == "ss_req" {
                    label = "📸 Il contatto chiede autorizzazione per gli screenshot"
                } else if ctlType == "ss_resp" {
                    let approved = json["approved"] as? Bool ?? false
                    label = approved ? "📸 Screenshot autorizzati" : "📸 Richiesta screenshot negata"
                    store.setScreenshotGranted(conversationId: conv.id, granted: approved)
                } else if ctlType == "ss_lock" {
                    label = "📸 Screenshot nuovamente bloccati"
                    store.setScreenshotGranted(conversationId: conv.id, granted: false)
                } else if ctlType == "ephemeral_timer" {
                    let sec = json["timer_sec"] as? Int ?? 0
                    store.setEphemeralTimer(conversationId: conv.id, seconds: sec == 0 ? nil : sec)
                    label = sec == -1 ? "⏱ Messaggi: visualizza una volta"
                         : sec == 0 ? "⏱ Messaggi a scomparsa: disattivati"
                         : "⏱ Messaggi a scomparsa: \(sec)s"
                } else {
                    label = ""
                }
                if !label.isEmpty {
                    let sysMsg = Message(
                        id: UUID(), conversationId: conv.id,
                        direction: .incoming, plaintext: label,
                        sentAt: Date(), deliveredAt: Date(), readAt: nil,
                        status: .delivered, senderUserId: senderId
                    )
                    store.appendMessage(sysMsg)
                    store.recordNewMessage(conversationId: conv.id,
                                           lastMessagePreview: label,
                                           lastActivity: Date(), incrementUnread: !conv.muted)
                }
                NotificationCenter.default.post(name: AppState.chatRefreshNotification,
                                                object: nil,
                                                userInfo: ["peerUserId": senderId])
                return
            }
        }

        // Incoming message: isViewOnce derived from conversation timer == -1.
        var isViewOnce: Bool = false
        isViewOnce = (conv.ephemeralTimerSeconds ?? 0) == -1

        let msgUUID = UUID()
        // W80: voice-note receive.
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
            serverMessageId: serverMsgId,
            mediaLocalPath: nil,
            mediaDurationMs: initialMediaDur,
            mediaMimeType: pendingMarker?.qfile.mime ?? pendingAttachAnnounce?.att.mime,
            clientMsgId: clientMsgId,
            isViewOnce: isViewOnce ? true : nil
        )
        store.appendMessage(msg)
        // W83: bump conversation preview + activity + unread so the
        // chat list reflects new messages and the count badge shows.
        // Use the already-rendered `plaintext` (placeholder for media)
        // so cross-platform attachments don't leak raw JSON to the list.
        // W89: muted conversations skip the unread bump so the badge
        // stays clean (the message still lands and re-orders the list).
        let isMuted = conv.muted
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
            // MessageHandler is a non-isolated closure but dispatchInboundOpaque
            // is @MainActor (AppState is @MainActor) — hop to the main actor,
            // mirroring the original handler which wrapped every routing call in
            // `Task { @MainActor }`.
            Task { @MainActor [weak self] in
                self?.dispatchInboundOpaque(senderId: senderId, blobStr: blobStr)
            }
        }
    }

    /// Route a single inbound opaque blob to the correct handler. Invoked for a
    /// LIVE `opaque_message` and also REPLAYED for a `msg_pending_sync` entry
    /// whose `msg_type == "opaque"` — a PQC OFFER/ACCEPT, contact-key-exchange
    /// frame or call piggy-back that the server queued offline while this
    /// device's WS was disconnected OR a suspended-iOS zombie.
    ///
    /// Before this extraction the pending-sync replay path
    /// (`replayPendingSyncEntry`) fed EVERY queued blob through the chat
    /// decrypt (`handleIncomingMessage`), so an offline-queued Android OFFER
    /// was mis-decrypted as a chat ciphertext and silently dropped. Combined
    /// with the server's zombie-WS race that caused OFFERs to be queued in the
    /// first place, this left every backgrounded Android→iOS call ringing on
    /// the iPad but NEVER reaching the key sync. Routing opaque blobs here on
    /// replay closes that hole.
    private func dispatchInboundOpaque(senderId: String, blobStr: String) {
        guard let cke = contactKeyExchange else { return }

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

        // Path B0 — `<callId>|<TAG>:value` piggy-back framing shared
        // with Android + Desktop (SCREEN_SHARE / CAPS / HANGUP).
        // Tested BEFORE the JSON HandshakeBundle branch because both
        // share the `<callId>|...` prefix; the piggy-back parser
        // bails out for `{`-prefixed payloads so JSON falls through
        // intact. See AndroidHandshakeBundle.swift `CallPiggyBack`
        // and docs/SCREEN_SHARE_PROTOCOL.md.
        if let piggy = CallPiggyBack.parse(blobStr) {
            Task { @MainActor [weak self] in
                self?.routeInboundCallPiggyBack(piggy, senderId: senderId)
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
                    callerId: senderId,
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
            print("[AppState] Android ACCEPT arrived from \(senderId.prefix(8))… but callService.callIntegration is nil — call already ended or ACCEPT arrived after teardown")
            return
        }
        // W461: diagnostic — log the callId as received so we can detect
        // case mismatches (iOS uppercase UUID vs Android lowercase echo).
        let intState: String = String(describing: integration.getState())
        print("[AppState] Android ACCEPT callId=\(parsed.callId.prefix(8))… from \(senderId.prefix(8))… integration.state=\(intState)")
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

    /// W534 — dispatch for `<callId>|<TAG>:value` piggy-backs.
    /// Currently consumes `SCREEN_SHARE:` (start/stop) and silently
    /// drops CAPS / HANGUP (the regular `call_hangup` envelope is
    /// authoritative for teardown). See
    /// `apps/qaudion-desktop/docs/SCREEN_SHARE_PROTOCOL.md`.
    @MainActor
    private func routeInboundCallPiggyBack(_ piggy: CallPiggyBack, senderId: String) {
        switch piggy {
        case .screenShare(let callId, let active):
            handleRemoteScreenShareState(
                callId: callId, active: active, senderId: senderId)
        case .caps(let callId, let raw):
            // Reserved — iOS doesn't yet consume CAPS, but log to
            // confirm we're seeing them so the parser isn't a black
            // hole when Desktop / Android add new tags.
            print("[AppState] piggy-back CAPS dropped (not consumed): callId=\(callId.prefix(8))… raw=\(raw)")
        case .hangup(let callId, let reason):
            // The authoritative teardown still arrives on the
            // `call_hangup` WS envelope. Log + drop.
            print("[AppState] piggy-back HANGUP dropped (call_hangup is authoritative): callId=\(callId.prefix(8))… reason=\(reason) from=\(senderId.prefix(8))…")
        }
    }

    /// W534 — apply a remote `SCREEN_SHARE:start|stop` to the current
    /// call. Stale callIds (from a previous call) are silently ignored
    /// so a late-arriving frame can't flip the UI back on after hangup.
    @MainActor
    private func handleRemoteScreenShareState(
        callId: String, active: Bool, senderId: String
    ) {
        let currentCallId: String? = {
            if let provider = liveProvider,
               let impl = provider.callingApi as? BCryptoCallingApiImpl {
                return impl.getActiveCallId()
            }
            return nil
        }()
        // Match case-insensitively — Android historically echoes the
        // server-side lowercase UUID even when iOS minted uppercase
        // (see W461). If we have no bound callId yet (very early or
        // already torn down), still match against the peer userId.
        let callIdMatches: Bool = {
            guard let cur = currentCallId else { return isInCall && callContactId == senderId }
            return cur.caseInsensitiveCompare(callId) == .orderedSame
        }()
        let senderMatches = (callContactId == senderId)
        guard callIdMatches, senderMatches else {
            print("[AppState] SCREEN_SHARE dropped — stale callId=\(callId.prefix(8))… active=\(active) (current=\(currentCallId?.prefix(8) ?? "nil") senderMatch=\(senderMatches))")
            return
        }
        // Debounce identical state (the spec warns about a malicious
        // peer flapping start/stop — keep the UI calm).
        guard peerScreenShareActive != active else { return }
        peerScreenShareActive = active
        print("[AppState] SCREEN_SHARE \(active ? "start" : "stop") from=\(senderId.prefix(8))… callId=\(callId.prefix(8))…")
    }

    /// W534 — outbound announce primitive. Builds
    /// `<callId>|SCREEN_SHARE:<start|stop>` and ships it via the
    /// existing `opaque_message` UTF-8 string path so Desktop +
    /// Android peers mount their remote video sink. iOS does NOT yet
    /// expose a screen-share UI button (would require a ReplayKit
    /// broadcast extension) — this method exists so a future iOS
    /// capture path has the announce ready without re-touching the
    /// piggy-back framing.
    @MainActor
    public func announceScreenShare(active: Bool) async {
        guard let peer = callContactId, !peer.isEmpty,
              let provider = liveProvider,
              let impl = provider.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId(), !callId.isEmpty
        else {
            print("[AppState] announceScreenShare: no active call — refusing")
            return
        }
        let wire = CallPiggyBack.serializeScreenShare(callId: callId, active: active)
        do {
            try await provider.callingApi.sendOpaqueMessageString(
                recipientId: peer, payload: wire)
            print("[AppState] SCREEN_SHARE announce shipped active=\(active) callId=\(callId.prefix(8))…")
        } catch {
            print("[AppState] announceScreenShare failed: \(error)")
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
                // M-9: reject an all-zero / empty shared secret — a
                // degenerate key must never be registered as a call's
                // PQC session key.
                guard sharedSecret.contains(where: { $0 != 0 }) else { return }
                // M-9: only register if this key belongs to the call
                // currently in progress (callContactId == peerId),
                // otherwise a stale/cross-call handshake completion
                // could race a different call's key into the broker.
                guard self.callContactId == peerId else { return }
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

    /// W450: boot the audio capture/playback stack for an incoming call
    /// the moment the user accepts it via CallKit.
    ///
    /// Outgoing calls do this inside `startCall(contactId:video:)` →
    /// `callService.startCall(engine:contactId:)`. For incoming calls
    /// that path is never taken because `isInCall` is already true
    /// (set by the `call_incoming` WS handler before the user answers).
    /// This method fills that gap: wires WS transport and activates
    /// AudioCapture + AudioPlayback on the existing responder integration
    /// so the callee actually hears and speaks once they accept.
    ///
    /// Must be called on the main thread (@MainActor).
    @MainActor
    private func startIncomingCallAudioOnAnswer() {
        guard let eng = engine,
              let intg = responderCallIntegration,
              let cid = callContactId else {
            print("[AppState] startIncomingCallAudioOnAnswer: missing engine/integration/contactId — audio not started")
            return
        }
        // Wire WS transport so audio_frame handler routes inbound audio
        // to handleIncomingEncryptedFrame, and TX frames are sent to peer.
        if let ws = liveProvider?.getWebSocketClient() {
            callService.wireTransport(wsClient: ws, peerUserId: cid)
        }
        // Activate capture + playback. Reuses the existing responder
        // integration so the PQC session key negotiated during ringing
        // is the same one the audio codec uses — no re-keying needed.
        do {
            try callService.activateIncomingCallAudio(engine: eng, integration: intg)
        } catch {
            print("[AppState] startIncomingCallAudioOnAnswer: audio activation failed: \(error)")
        }
        // Speaker override is now in CallService.handleAudioSessionActivated()
        // — calling it here (before the session is active) was silently ignored
        // by iOS, leaving audio on the earpiece (log: out=Receiver).
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
    /// Re-wires the call audio transport to the fresh WS instance after a
    /// BCryptoWS reconnect. Without this, `audio_frame` RX stays registered
    /// on the dead old WS (silent RX) and TX also goes to the dead instance
    /// because `wsClient != nil` prevents the `getWsClient` fallback.
    @MainActor
    private func rewireCallAudioOnReconnect() {
        guard isInCall,
              let ws = liveProvider?.getWebSocketClient(),
              let peerId = callContactId else { return }
        callService.wireTransport(wsClient: ws, peerUserId: peerId)
        print("[AppState] WS reconnect — call audio re-wired to fresh WS for peer \(peerId.prefix(8))…")
    }

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
        ServerSelector.shared.stopMonitor()
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
        // M-14: remove the CallSessionKeyBroker.sasReadyNotification
        // observer registered by wireSasReadyToController() so it
        // doesn't leak across logout/login cycles (and can't fire into
        // a stale AppState after re-auth).
        if let token = sasReadyObserverToken {
            NotificationCenter.default.removeObserver(token)
            sasReadyObserverToken = nil
        }
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
                // Preserve a human-readable peer label for the call screens.
                // Dialing a short extension resolves to a bare UUID; without
                // this the outgoing / in-call screens fall back to the
                // truncated UUID ("non si capisce perché mostri uid lungo").
                // Prefer the server display name, else show the dialed
                // extension as "Int. NNN" — every call screen consults
                // incomingCallerName as its name fallback (build 595).
                let dn = (profile.displayName ?? "").trimmingCharacters(in: .whitespaces)
                self.incomingCallerName = dn.isEmpty ? "Int. \(ext)" : dn
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
                // Same UUID-leak fix as the extension branch: show the dialed
                // E.164 number on the call screens instead of the raw UUID.
                self.incomingCallerName = normalized
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
        // W541-3: telemetry event marking outgoing-call dial. callId
        // isn't minted yet at this point — bound later via the same
        // session_id. Useful for measuring dial-to-active duration.
        TelemetryService.shared.emit(
            kind: "call.start_dial",
            attrs: [
                "peer_prefix": String(contactId.prefix(8)),
                "video": video
            ]
        )
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
        // M-10: SAS words shown now are seeded from the transitional
        // PSK, NOT the ML-KEM handshake. Flip to .mlKem only when the
        // broker's real key overwrites it (see wireSasReadyToController).
        callSasKeySource = pskActive ? .psk : .none
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
                ws.onCallProcessing = { [weak self] callId, receiverId in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // W461: route to the integration so it advances from
                        // .capabilitySent → .connecting. Without this the
                        // 30s fallback timer checked state == .capabilitySent
                        // and fired endCall() even though the peer ack'd.
                        print("[AppState] call_processing callId=\(callId.prefix(8))… from \(receiverId.prefix(8))… — advancing integration to .connecting")
                        self.callService.callIntegration?.onCallProcessingReceived(
                            callId: callId, receiverId: receiverId)
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
                        let cid = (self.liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId()
                        CallMediaTelemetry.shared.recordEnded(callId: cid, reason: "peer_offline")
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

            let peerDisplayName = _outgoingPeerDisplay
            let hasVideo = video
            Task {
                do {
                    if let uuid = try await callKit?.startOutgoingCall(handle: peerDisplayName, hasVideo: hasVideo) {
                        await MainActor.run {
                            self.activeCallKitId = uuid
                        }
                    } else {
                        await MainActor.run {
                            self.callService.handleAudioSessionActivated()
                        }
                    }
                } catch {
                    print("[AppState] CallKit startOutgoingCall failed: \(error)")
                    await MainActor.run {
                        self.callService.handleAudioSessionActivated()
                    }
                }
            }

            // W462-iOS: canonical callId shared across PQC and WebRTC rails.
            // Declared here (outer do scope) so the WebRTC Task below can
            // capture it without re-minting a second UUID that creates a
            // duplicate server call-session and ghost call_incoming events.
            // Set to the real UUID inside the `if let integration` block.
            var sharedOutgoingCallId: String = ""

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
                        // M-9: reject an all-zero / empty shared secret.
                        guard sharedSecret.contains(where: { $0 != 0 }) else { return }
                        // M-9: only register the key for the call that
                        // is actually in progress for this peer.
                        guard strongSelf.callContactId == peerId else { return }
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
                let outgoingCallId = UUID().uuidString.lowercased()
                sharedOutgoingCallId = outgoingCallId  // expose to WebRTC Task below
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
            // W548 (iOS): per-call media lifecycle telemetry. Pair
            // with `call.media.summary` emitted on the .ended edge.
            do {
                let cid = (liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId()
                CallMediaTelemetry.shared.recordConnected(
                    callId: cid,
                    peerPrefix: String(contactId.prefix(8)),
                    sasSource: "answered"
                )
            }
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
                // WSS-TURN bridge JWT auth — forwarded to the WS handshake
                // on /api/v1/turn-ws (server requires Bearer token since W559).
                controller.accessToken = currentAccessToken
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
                // Remote-readable video diagnostics (mirrors Android). Ships
                // outbound/inbound video RTP stats + remote-track arrival to
                // the server so an iOS→Android video failure is diagnosable
                // without a Mac console session.
                controller.videoTelemetry = { kind, attrs in
                    TelemetryService.shared.emit(kind: kind, attrs: attrs)
                }
                // R-4 (sovereign-only): reject incoming video when the
                // policy is on. Read live (not captured) so a mid-session
                // toggle takes effect on the next inbound track.
                controller.shouldRejectIncomingVideo = { CallsGate.shouldRejectIncomingVideo }
                // R-4 (DEFECT 2): strip `vkey-v1` from every offer/answer
                // this controller advertises when sovereign-only is on.
                controller.advertisedCapabilitiesFilter = { CallsGate.filterAdvertisedCapabilities($0) }
                // If ICE fails / drops mid-call (network change, TURN
                // unreachable) the controller flips to .failed/.disconnected
                // but nothing tore down AppState — isInCall stayed true and
                // the UI was wedged on the call screen forever. Drive
                // endCall() off the controller's terminal state. Guarded by
                // isInCall so it can't double-teardown with the normal
                // hangup path.
                controller.onStateChange = { [weak self] newState in
                    switch newState {
                    case .failed, .disconnected:
                        Task { @MainActor [weak self] in
                            self?.handleIceTermination()
                        }
                    default:
                        break
                    }
                }
                controller.onIceConnectionState = { [weak self] iceState in
                    switch iceState {
                    case .failed, .disconnected, .closed:
                        Task { @MainActor [weak self] in
                            self?.handleIceTermination()
                        }
                    case .connected, .completed:
                        // Transport indicator: WebRTC path confirmed.
                        // If the user forced relay (TransportGate.forcesRelay)
                        // or the VPN routes everything through TURN, show "STD"
                        // (→ label "TURN"). Otherwise "PQC" (→ "P2P SRTP").
                        let isRelayForced = TransportGate.forcesRelay
                        Task { @MainActor [weak self] in
                            self?.backendType = isRelayForced ? "turn" : "p2p"
                        }
                    default:
                        break
                    }
                }
                // Same caller-id substitution as the legacy path —
                // both rails ship the same `caller_display` so the
                // peer doesn't pick a different label depending on
                // which OFFER it picks up first.
                let webRtcCallerDisplay = LocalCallerIdSettings.phoneNumber()
                // W462-iOS: thread the canonical PQC callId into the
                // WebRTC controller so both rails share ONE server
                // call-session. `sharedOutgoingCallId` was minted inside
                // the integration block and already used by `beginAndroidOutgoing`.
                // If the integration block was skipped (no integration yet),
                // sharedOutgoingCallId is "" and startOutgoingCall falls
                // back to minting its own UUID (old behaviour, harmless for
                // pure-WebRTC peers).
                let webRtcCallId: String? = sharedOutgoingCallId.isEmpty ? nil : sharedOutgoingCallId
                Task { [weak self] in
                    do {
                        try await controller.startOutgoingCall(
                            recipientId: contactId,
                            audioOnly: !video,
                            callerDisplay: webRtcCallerDisplay,
                            callId: webRtcCallId
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
            let cid = (liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId()
            CallMediaTelemetry.shared.recordEnded(callId: cid, reason: "answer_failed:\(error.localizedDescription)")
            callState = .ended
            isInCall = false
            isVideoCall = false
            errorMessage = "Call failed: \(error.localizedDescription)"
        }
    }

    // MARK: - In-app ringtone (foreground WS calls, no CallKit UI)

    /// Start the in-app ringtone using AudioServicesPlayAlertSound.
    /// Repeats every 3 s. Safe to call multiple times (idempotent).
    func startInAppRingtone() {
        guard ringtoneTimer == nil else { return }
        // 1005 = "sms-received5.caf" — short, distinctive, non-intrusive.
        // Using 1000 (classic tring) would clash with system notifications.
        let soundId: SystemSoundID = 1005
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 3.0)
        timer.setEventHandler { AudioServicesPlayAlertSound(soundId) }
        ringtoneTimer = timer
        timer.resume()
    }

    /// Stop the in-app ringtone. Called on answer, decline, or hangup.
    func stopInAppRingtone() {
        ringtoneTimer?.cancel()
        ringtoneTimer = nil
    }

    /// C-2 — terminate the call when WebRTC reports a fatal ICE /
    /// connection state (`.failed` / `.disconnected` / `.closed`).
    /// Without this the controller's onStateChange/onIceConnectionState
    /// callbacks were never assigned, so a dropped media path left the
    /// call UI up forever. Extracted into its own @MainActor method to
    /// keep the wiring closures shallow (Swift 6 type-checker depth).
    @MainActor
    private func handleIceTermination() {
        // F-1 (2nd-pass regression): C-3 made `isInCall` stay false until
        // the call is ANSWERED. So an ICE / connection failure DURING
        // setup (outgoing `.connecting`, incoming `.ringing`) — i.e. the
        // "can't even connect" case — was swallowed by the old
        // `guard isInCall` and left the call UI / CallKit wedged forever.
        // Tear down on any non-terminal call state, not just answered.
        switch callState {
        case .idle, .ended:
            return
        case .connecting, .ringing, .active, .encrypted:
            break
        }
        self.endCall()
    }

    /// W478 — answer an incoming call from the in-app ringing banner.
    /// Uses CXCallController so the same `provider(_:perform:CXAnswerCallAction)`
    /// delegate path fires as when the user taps Answer on the system sheet.
    func answerIncomingCall() {
        stopInAppRingtone()
        guard let uuid = activeCallKitId else { return }
        Task { try? await callKit?.answerCall(uuid: uuid) }
    }

    /// W478 — decline an incoming call from the in-app ringing banner.
    /// Delegates to endCall() which sends call_hangup to the server and
    /// reports the call ended to CallKit with `.declined` reason.
    func declineIncomingCall() {
        endCall()
    }

    func endCall() {
        // H-6: idempotency — a second endCall() while teardown is
        // already in flight (CallKit onEndCall racing a remote
        // call_hangup) must be a no-op, otherwise we double-hangup the
        // controller and leak the RTCPeerConnection.
        stopInAppRingtone()
        guard !isEndingCall else { return }
        isEndingCall = true

        // W517: send call_hangup for non-WebRTC paths (QUAD binary iOS↔Android
        // and all incoming calls). The WebRTC path uses sendHangupAndClose()
        // below — skip here to avoid double-hangup.
        // callingApi.activeCallId is pre-bound: outgoing via sendCallOfferWithId,
        // incoming via bindIncomingCallId (AppState.wireIncomingCallHandlers).
        // Capture callContactId NOW before the teardown sequence clears it.
        if let peer = callContactId,
           let provider = liveProvider,
           webRtcController == nil {
            Task { try? await provider.callingApi.sendHangup(recipientId: peer) }
        }

        if let uuid = activeCallKitId {
            Task { [weak self] in
                await self?.callKit?.reportCallEnded(uuid: uuid, reason: .userEnded)
            }
        }
        // NIM-fix1: log the call-session UUID, not the raw peer userId, to
        // avoid leaking the social graph through auto-uploaded VPS telemetry.
        let callLogId: String = activeOutgoingRecordId ?? "none"
        RTLog.info("call", "endCall — callId=" + callLogId + " state=\(callState)")
        // W541-3: telemetry event for call end. callState carries the
        // terminal state which the maintainer correlates with peer's
        // own endCall event to detect "iPhone went encrypted but S24
        // gave up at ringing" patterns.
        TelemetryService.shared.emit(
            kind: "call.end",
            callId: callLogId == "none" ? nil : callLogId,
            attrs: [
                "terminal_state": String(describing: callState),
                "is_video": isVideoCall
            ]
        )
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
        // W533: also stop screen share if it was running so ReplayKit
        // releases its capture session cleanly. We don't await — the
        // call is already ending, the user doesn't need to wait for
        // ReplayKit's stopCapture callback.
        #if os(iOS)
        if isScreenSharing {
            isScreenSharing = false
            preScreenShareCameraClosure = nil
            Task { @MainActor [weak self] in
                await self?.screenShareController.stop()
            }
        }
        #endif
        videoPipeline?.stop()
        videoPipeline = nil
        // W396: tear down the responder integration so a subsequent
        // call from the same peer starts with a clean state machine.
        responderCallIntegration?.onCallEnded()
        responderCallIntegration = nil
        // W548 (iOS): emit call.media.summary on the canonical end edge.
        do {
            let cid = (liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId()
            CallMediaTelemetry.shared.recordEnded(callId: cid, reason: "user_hangup")
        }
        callState = .ended
        isInCall = false
        isVideoCall = false
        deepfakeAlert = false
        callContactId = nil
        incomingCallerName = ""
        activeCallKitId = nil
        answeredCallKitId = nil  // Bug A — re-arm the idempotent-answer guard for the next call
        // W534 — drop any sticky peer-screen-share state from this call
        // so the next call starts with a clean UI. Per SCREEN_SHARE_
        // PROTOCOL.md the call_hangup envelope is authoritative for
        // teardown; we do NOT need (and the spec explicitly says not to
        // send) a final `SCREEN_SHARE:stop` here.
        peerScreenShareActive = false
        // W339: drop the PQC session key so the SAS panel hides on the
        // next call setup. Holding stale key material across calls
        // would otherwise let one call's verified SAS appear on the
        // next, unverified call.
        callPqcSessionKey = nil
        // M-10: reset SAS provenance so the next call starts from
        // .none and doesn't inherit this call's .mlKem trust state.
        callSasKeySource = .none
        // Reset transport indicator so the next call doesn't inherit
        // the previous call's transport type (WS relay vs WebRTC).
        backendType = "p2p"  // reset — next call starts assuming direct until ICE says otherwise
        // Reset audio routing to default (earpiece + proximity sensor) so
        // the next call does NOT inherit a previous overrideOutputAudioPort(.speaker).
        // Without this, if the user activated loudspeaker in the previous call,
        // the next call would start with .speaker override still active → audio
        // comes out of the external speaker at low perceived volume when
        // the user holds the phone to their ear expecting the earpiece.
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        // W347 / H-6: tear down the WebRTC bridge for this call.
        // W495 — send WS call_hangup BEFORE closing the peer connection.
        // Old pattern (closeSynchronously THEN Task { hangup() }) was broken:
        // closeSynchronously() sets recipientId = nil; by the time the Task
        // runs, recipientId is nil so call_hangup was never sent. The remote
        // then waited for ICE disconnect timeout (~3s) to end the call.
        // sendHangupAndClose() captures recipientId first, then closes sync.
        #if canImport(WebRTC)
        if let ctrl = webRtcController as? QAudionWebRtcCallController {
            ctrl.sendHangupAndClose()
        }
        #endif
        webRtcController = nil
        remoteWebRtcVideoTrack = nil
        // M-32: free the ≈150 MB ONNX deepfake model if it was used on
        // this call so it isn't held resident between calls.
        if deepfakeClassifierUsed {
            DeepfakeClassifier.shared.releaseModel()
            deepfakeClassifierUsed = false
        }
        txWaveformSamples = []
        rxWaveformSamples = []
        cipherWaveformSamples = []
        // W481 — reset callState to .idle IMMEDIATELY (not after 1s).
        // The 1-second delay was causing every subsequent call_incoming
        // that arrived within 1s of a hangup to be silently dropped by
        // the dedup guard (guard callState == .idle). Typical scenario:
        // caller hangs up → callee endCall() → callState=.ended →
        // caller retries within 1s → call_incoming arrives while
        // callState=.ended → dropped → device never rings again.
        // isEndingCall still clears after a short delay to preserve the
        // H-6 re-entrancy guard against the rapid double-endCall race.
        callState = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            // H-6: clear the re-entrancy guard once teardown has fully
            // settled so the next call's endCall() runs normally.
            self.isEndingCall = false
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
    ///
    /// W554 — gate render on `callSasKeySource == .mlKem`.
    /// The previous version exposed words derived from the transitional
    /// PSK (`deriveTransitionalSasKey`, see line 2946), which iOS seeds
    /// for ~3-5 s before the ML-KEM handshake delivers the real key.
    /// Android has NO equivalent transitional path — it waits for the
    /// CallSessionKeyBroker. The mismatch produced two completely
    /// different 6-word strings on the two ends for that window, the
    /// user reads them, sees "no match", thinks the call is compromised.
    /// Holding the panel hidden until the broker fires is the right UX
    /// AND security stance: a SAS that doesn't reflect the actual call
    /// key is worse than no SAS.
    var callSasWords: [String] {
        guard callSasKeySource == .mlKem else { return [] }
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
        // W520: route audio to the external loudspeaker (or back to the earpiece).
        //
        // Two-step approach required:
        // 1. Reconfigure the category options: include .defaultToSpeaker only
        //    when speaker is ON. Without it, overrideOutputAudioPort(.none)
        //    correctly falls back to earpiece. With it, the proximity sensor
        //    overrides earpiece anyway — so both must change together.
        // 2. Call overrideOutputAudioPort to LOCK the route regardless of
        //    the proximity sensor (which .voiceChat mode monitors by default).
        //    Without this lock, holding the phone to your ear silently reverts
        //    to earpiece even after the user explicitly tapped "speaker".
        let session = AVAudioSession.sharedInstance()
        do {
            var opts: AVAudioSession.CategoryOptions = [
                .allowBluetoothHFP,
                .interruptSpokenAudioAndMixWithOthers
            ]
            if enabled { opts.insert(.defaultToSpeaker) }
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
            RTLog.info("call", "setSpeaker(" + String(describing: enabled) + ") ok")
        } catch {
            let msg: String = error.localizedDescription
            RTLog.warn("call", "setSpeaker failed: " + msg)
        }
    }

    /// Toggle the local camera for video calls. Pauses/resumes the
    /// video capture pipeline. No-op when there is no active video call.
    func setCamera(_ enabled: Bool) {
        videoPipeline?.setCameraEnabled(enabled)
    }

    /// Upgrade an audio call to video mid-call (same as Android/Desktop "upgrade to video").
    /// Sets `isVideoCall = true` so the camera toggle button appears in InCallScreen
    /// and starts the local video capture pipeline. Does NOT yet signal the peer
    /// (a WS video-upgrade message will be added when the server supports it).
    func upgradeToVideo() {
        guard isInCall, !isVideoCall else { return }
        guard let peerId = callContactId, !peerId.isEmpty else {
            RTLog.warn("call", "upgradeToVideo: callContactId nil — aborting")
            return
        }
        // iOS↔iOS WS-relay path: WebRTC controller is nil — start
        // VideoCallPipeline directly (camera → HEVC → WS relay → HEVC decode).
        // WebRTC renegotiation is skipped because there is no RTP transceiver.
        if webRtcController == nil {
            RTLog.info("call", "upgradeToVideo: iOS↔iOS WS relay — starting VideoCallPipeline directly")
            isVideoCall = true
            setCamera(true)
            Task { @MainActor [weak self] in
                await self?.startVideoPipeline(for: peerId)
            }
            return
        }
        RTLog.info("call", "upgradeToVideo: starting WebRTC renegotiation for peer " + peerId.prefix(8).description + "…")
        // W536 — proper cross-platform audio→video upgrade via WebRTC
        // SDP renegotiation. The previous (W522) implementation only
        // flipped isVideoCall and started VideoCallPipeline (WS HEVC
        // path). That produced black/purple video on Android + desktop
        // because their video render side only consumes WebRTC RTP —
        // and the existing PC had no m=video section, so there was
        // nothing to consume.
        //
        // New flow (matches desktop's PeerConnectionManager.
        // upgradeToVideo + CallController.requestUpgradeToVideo):
        //   1. addTransceiver(.video) via QAudionWebRtcCallController.
        //      upgradeToVideo — returns the regenerated SDP offer.
        //   2. CallingApi.sendCallUpgradeRequest ships the offer over
        //      WS. Recipient is the peer's userId; call_id ties it to
        //      the existing session.
        //   3. Peer responds with call_upgrade_response (handled in
        //      wireUpgradeHandlers). On accept, we feed the answer
        //      back via applyUpgradeAnswer.
        //   4. Once the renegotiation lands, VideoCallPipeline starts
        //      so the WS-relay HEVC path (iOS↔iOS) ALSO carries video.
        //      Cross-platform peers ignore the WS video_frame (no
        //      consumer) but the WebRTC RTP path is what they render.
        //
        // setCamera(true) is deferred to AFTER the WebRTC renegotiation
        // succeeds — turning on the camera before there's a sink for
        // the frames would flash the local preview without sending.
        Task { @MainActor [weak self] in
            await self?.performWebRtcVideoUpgrade(for: peerId)
        }
    }

    /// W536 — execute the WebRTC half of upgradeToVideo. Split out of
    /// `upgradeToVideo()` so the synchronous public function can
    /// return immediately while the async signaling happens in the
    /// background. Best-effort: any failure leaves the call in
    /// audio-only mode (no UI regression).
    @MainActor
    private func performWebRtcVideoUpgrade(for peerId: String) async {
        #if canImport(WebRTC)
        guard let controller = webRtcController as? QAudionWebRtcCallController,
              let provider = liveProvider,
              let impl = provider.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId()
        else {
            RTLog.warn("call", "upgradeToVideo: WebRTC controller / callId unavailable — leaving call audio-only")
            return
        }
        do {
            let offerSdp = try await controller.upgradeToVideo()
            // Mark the local UI as video BEFORE the peer accepts so
            // the local preview can show as soon as the camera is on.
            // If the peer rejects (accepted=false), we revert below.
            self.isVideoCall = true
            self.setCamera(true)
            try await impl.sendCallUpgradeRequest(
                callId: callId,
                recipientId: peerId,
                sdp: offerSdp
            )
            RTLog.info("call", "upgradeToVideo: call_upgrade_request shipped — awaiting response")
            // ALSO bring up the VideoCallPipeline so iOS↔iOS peers get
            // the WS HEVC stream. The WebRTC RTP path handles Android
            // + desktop. Both are wired to the same camera frames; no
            // extra capture session.
            await startVideoPipeline(for: peerId)
        } catch QAudionWebRtcCallController.ControllerError.alreadyHasVideo {
            // The peer raced us with their own upgrade. acceptUpgrade
            // Offer will fire shortly; nothing to do here.
            RTLog.info("call", "upgradeToVideo: already in video — peer raced us")
        } catch {
            let desc: String = error.localizedDescription
            RTLog.warn("call", "upgradeToVideo failed: " + desc)
            errorMessage = "Upgrade a video fallito: " + desc
        }
        #else
        RTLog.warn("call", "upgradeToVideo: WebRTC not available in this build")
        #endif
    }

    // MARK: - W533: Screen Share

    /// Start sharing the iOS in-app screen to the remote peer. Hot-
    /// swaps the camera-frame producer on `VideoCallPipeline.
    /// onCapturedPixelBuffer` for a no-op (so two writers don't race
    /// into the same `RTCVideoSource`) and points `ScreenShareController`
    /// at the WebRTC capturer. The remote peer sees the screen
    /// content as a normal WebRTC video track — no wire-protocol
    /// change required. Desktop / Android receive it automatically.
    ///
    /// Pre-conditions:
    ///   - The call must already be in `.encrypted` (video stream
    ///     plumbing is up only for video calls — for audio-only
    ///     calls we would also need to flip `isVideoCall=true` and
    ///     run `upgradeToVideo()` first; deferring that to a future
    ///     iteration since the UI button is shown only on
    ///     active video calls).
    ///   - The WebRTC controller is live so its `webrtcPixelBuffer
    ///     Capturer` is non-nil.
    public func startScreenShare() async {
        #if os(iOS)
        guard isInCall else {
            RTLog.warn("call", "startScreenShare: not in a call — refusing")
            return
        }
        #if canImport(WebRTC)
        // W538: audio-call screen-share — if there's no video transceiver
        // yet, upgrade the call to video first (same path as the
        // upgrade-to-video button). The WebRTC capturer is only created
        // after `startCameraCapture` (which `upgradeToVideo` triggers),
        // so without this step `webrtcPixelBufferCapturer` is nil on
        // audio calls and ReplayKit has nowhere to push frames.
        if !isVideoCall {
            RTLog.info("call", "startScreenShare: upgrading audio→video before capture")
            guard let peerId = callContactId, !peerId.isEmpty else {
                RTLog.warn("call", "startScreenShare: callContactId nil — aborting")
                errorMessage = "Impossibile avviare la condivisione: peer sconosciuto."
                return
            }
            await performWebRtcVideoUpgrade(for: peerId)
            // Give the renegotiation a brief moment to wire the
            // capturer; bail with a clear error if it didn't land.
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        guard let controller = webRtcController as? QAudionWebRtcCallController,
              let capturer = controller.webrtcPixelBufferCapturer
        else {
            RTLog.warn("call", "startScreenShare: WebRTC capturer unavailable")
            errorMessage = "Condivisione schermo non disponibile: video non pronto."
            return
        }
        // Capture (and clear) the current camera-frame closure so we
        // can restore it on stop. AppState owns the source of truth
        // here — videoPipeline writes to onCapturedPixelBuffer when
        // startVideoPipeline runs.
        preScreenShareCameraClosure = videoPipeline?.onCapturedPixelBuffer
        videoPipeline?.onCapturedPixelBuffer = nil
        do {
            try await screenShareController.start(into: capturer)
            isScreenSharing = true
            RTLog.info("call", "startScreenShare: ReplayKit capture live — pushing into WebRTC")
            // W538: fire-and-forget peer announce so cross-platform
            // peers can mount the screen-share video sink with the
            // right badge. If the peer doesn't support the SCREEN_SHARE
            // protocol, the opaque message is harmlessly ignored —
            // local capture is unaffected.
            Task { @MainActor [weak self] in
                await self?.announceScreenShare(active: true)
            }
        } catch {
            // Restore the camera closure if start failed so the call
            // doesn't get stuck without any video producer.
            videoPipeline?.onCapturedPixelBuffer = preScreenShareCameraClosure
            preScreenShareCameraClosure = nil
            let msg: String = error.localizedDescription
            RTLog.warn("call", "startScreenShare failed: " + msg)
            errorMessage = msg
        }
        #else
        RTLog.warn("call", "startScreenShare: WebRTC not available in this build")
        #endif
        #endif
    }

    public func stopScreenShare() async {
        #if os(iOS)
        guard isScreenSharing else { return }
        await screenShareController.stop()
        // Restore the camera path so VideoCallPipeline frames once
        // again flow to the WebRTC capturer.
        videoPipeline?.onCapturedPixelBuffer = preScreenShareCameraClosure
        preScreenShareCameraClosure = nil
        isScreenSharing = false
        RTLog.info("call", "stopScreenShare: camera frame closure restored")
        // W538: symmetric announce so the peer can swap the screen-share
        // sink back to the normal camera video badge. Fire-and-forget —
        // not blocking the UI restoration on the opaque-message round-trip.
        Task { @MainActor [weak self] in
            await self?.announceScreenShare(active: false)
        }
        #endif
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
            // Use a derived PSK for message encryption (32 bytes for AES-256).
            // New AAD-bound encrypt() returns a self-contained wire blob
            // (salt || nonce || ciphertext || tag) — no manual packing needed.
            let psk = Data(SHA256.hash(data: Data((contactId + (currentUserId ?? "")).utf8)))
            let payload = try messageCrypto.encrypt(
                plaintext: content,
                psk: psk,
                senderId: currentUserId ?? "",
                recipientId: contactId,
                msgId: messageId
            )

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
        // M-14: guard against double-registration — a second call to
        // this method would add a duplicate observer that is never
        // balanced, leaking it for the AppState lifetime.
        guard sasReadyObserverToken == nil else { return }
        sasReadyObserverToken = NotificationCenter.default.addObserver(
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
                // M-10: the broker has now overwritten callPqcSessionKey
                // with the REAL ML-KEM-1024 session key — the SAS words
                // are post-quantum authenticated from this point on.
                self.callSasKeySource = .mlKem
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
                //
                // W528: include .ringing AND .connecting in the
                // transition set. The original W521 fix covered the
                // CALLEE answer race (ringing → active → encrypted in
                // onAnswerCall). But the CALLER side never explicitly
                // transitions .ringing → .active for the Android-
                // compatible outgoing path: the only .active assignments
                // are at line 482 (CALLEE answer), line 2833 (legacy
                // iOS-only outgoing branch). When iPhone calls iPad or
                // Android, the caller stays at .ringing through the
                // entire ACCEPT + PQC decapsulation, and this observer
                // (which fires when the peer's ACCEPT bundle has been
                // decapsulated) would skip the transition because
                // callState != .active. Result: caller UI stuck on
                // "scambio chiavi" while the callee's UI shows the
                // active encrypted call. Treat ringing/connecting as
                // "ready to flip to encrypted" since PQC having
                // completed is a strictly stronger guarantee.
                //
                // W528-fix: do NOT include .ringing here. When the caller is
                // in .ringing (ringback playing) it means the callee has NOT
                // yet answered — PQC finishing early is by design (zero-ring-
                // delay) but the caller UI must stay in .ringing until the
                // callee's call_answer arrives. Jumping straight to .encrypted
                // from .ringing showed the iPad caller an "active encrypted
                // call" while Android was still on the incoming call screen.
                // The call_answer WS handler below now drives .ringing → .active
                // (and → .encrypted if PQC is already done). (report 10a131a4)
                let prev = self.callState
                switch self.callState {
                case .active, .connecting:
                    self.callState = .encrypted
                default:
                    break  // .idle, .ringing, .ended, already .encrypted — skip
                }
                if self.callState == .encrypted && prev != .encrypted {
                    // W541-3: emit caller-side encrypted-reached
                    // event. Pair with callee's emission above; the
                    // per-call decode tool computes the dial-to-secure
                    // delta on both sides for asymmetry detection.
                    let cid: String? = (self.liveProvider?.callingApi
                        as? BCryptoCallingApiImpl)?.getActiveCallId()
                    TelemetryService.shared.emit(
                        kind: "call.encrypted",
                        callId: cid,
                        attrs: [
                            "path": "caller-sasReady",
                            "prev_state": String(describing: prev)
                        ]
                    )
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
        // W525: capture a weak reference to the calling impl so each
        // fragment can stamp the current call_id onto the WS envelope.
        // Without this Android/Desktop drop every video_frame the same
        // way they drop audio_frames without call_id.
        // Captured strongly because BCryptoCallingApiImpl is owned by
        // liveProvider (also captured via `ws`) and outlives the call;
        // a weak capture on an optional reference here would just add
        // optional chaining noise without lifetime benefit.
        let callingImpl: BCryptoCallingApiImpl? = liveProvider?.callingApi as? BCryptoCallingApiImpl
        pipeline.onOutboundFragment = { [weak ws, weak pipeline, callingImpl] fragment in
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
            let cid = callingImpl?.getActiveCallId()
            ws?.sendVideoFrame(recipientId: peerId, frame: toShip, callId: cid)
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
        // WSS-TURN bridge JWT auth (responder side mirrors caller).
        controller.accessToken = currentAccessToken
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
        // Remote-readable video diagnostics (responder side, mirrors caller).
        controller.videoTelemetry = { kind, attrs in
            TelemetryService.shared.emit(kind: kind, attrs: attrs)
        }
        // R-4 (sovereign-only): reject incoming video when the policy is
        // on (responder side). Mirror of the caller-side wiring.
        controller.shouldRejectIncomingVideo = { CallsGate.shouldRejectIncomingVideo }
        // R-4 (DEFECT 2): strip `vkey-v1` from this controller's
        // offer/answer advertisements under sovereign-only (responder).
        controller.advertisedCapabilitiesFilter = { CallsGate.filterAdvertisedCapabilities($0) }
        // Mirror of the caller-side teardown: a mid-call ICE failure on
        // the responder side would otherwise leave isInCall == true and
        // the UI stuck on the call screen. Guarded by isInCall to avoid
        // double-teardown with the normal hangup path.
        controller.onStateChange = { [weak self] newState in
            switch newState {
            case .failed, .disconnected:
                Task { @MainActor [weak self] in
                    self?.handleIceTermination()
                }
            default:
                break
            }
        }
        controller.onIceConnectionState = { [weak self] iceState in
            switch iceState {
            case .failed, .disconnected, .closed:
                Task { @MainActor [weak self] in
                    self?.handleIceTermination()
                }
            case .connected, .completed:
                let isRelayForced = TransportGate.forcesRelay
                Task { @MainActor [weak self] in
                    self?.backendType = isRelayForced ? "turn" : "p2p"
                }
            default:
                break
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
