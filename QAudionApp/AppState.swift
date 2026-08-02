import Foundation
import SwiftUI
import Combine
import CryptoKit
import AVFoundation
import AudioToolbox  // AudioServicesPlayAlertSound (in-app ringtone)
import BackgroundTasks
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
    /// Prefers the server-assigned PBX extension over the raw 36-char UUID,
    /// which the user reported as unreadably long in the main-screen
    /// top-left. Falls back to a truncated UUID, then a generic label,
    /// mirroring `SettingsScreen.profileDisplayName`. Pavel, 2026-07-29:
    /// bare digits, no "Interno" prefix.
    var displayAccountLabel: String {
        if let ext = currentUserDialExtension, !ext.isEmpty {
            return DisplayName.formatExtension(ext)
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

    /// I4: `presenceService` is a reference type, mutated in place (its own
    /// `statuses`/`extendedStatuses` are what changes on every
    /// `presence_update`) and never reassigned — so `@Published` on the
    /// property above only fires if the REFERENCE itself changes, which it
    /// never does. Views that read `appState.presenceService.…` instead of
    /// holding `PresenceService` as their own `@ObservedObject` therefore had
    /// no subscription to its changes at all, and only appeared to update
    /// when some unrelated `AppState` publish happened to re-render them.
    /// Forwarding its `objectWillChange` here closes that gap for every such
    /// view without touching each one individually. `lazy` gives exactly-once
    /// wiring regardless of how many call sites touch it below.
    private lazy var presenceServiceForwarding: AnyCancellable =
        presenceService.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }

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
    /// Epoch-ms of the last node failover — damps ping-pong if both nodes flap.
    private var lastFailoverMs: Double = 0

    // MARK: - Reality censorship-bypass transport (additive; clearnet-FIRST)
    //
    // Reality (VLESS+REALITY over xray-core, via RealityManager) is a SECOND
    // signaling backend, activated ONLY as a fallback after clearnet is
    // exhausted — never the default route (design doc §6, bcrypto-server
    // CENSORSHIP_RESISTANT_TRANSPORT_DESIGN.md). Tor's own paths
    // (EmbeddedTorManager / TorObfsTransport) are untouched — this is
    // additive, not a replacement.

    /// UserDefaults key for the MANUAL force toggle (TransportSettingsScreen).
    /// When set, the persistent socket brings Reality up BEFORE trying
    /// clearnet, so a tester can verify the tunnel on an OPEN network where the
    /// automatic hard-failure trigger would never fire.
    static let forceRealityDefaultsKey = "qaudion.transport.force_reality"
    /// Read/write the persisted force-Reality preference. Static + UserDefaults
    /// so a SwiftUI `@AppStorage` binding and the connect path share one source
    /// of truth.
    static var forceRealityEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: forceRealityDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: forceRealityDefaultsKey) }
    }
    /// True while signaling is tunneled through the Reality SOCKS5 (either the
    /// auto fallback or the manual force). Drives a quiet UI indicator and
    /// guards against re-activating an already-active tunnel. Never persisted.
    @Published private(set) var transportIsReality: Bool = false
    /// REALITY_PIN fix: true when `activateRealityFallback` observed the
    /// server-issued Reality front public key CHANGE from a previously-pinned
    /// value (`RealityPinStore.Verdict.changed`) — a compromised/coerced CDN
    /// edge swapping the key would show up here. Non-blocking (signal-not-kill):
    /// the tunnel still comes up under the new key; this only drives a quiet
    /// advisory in TransportSettingsScreen. Never auto-clears — same "sticky
    /// until surfaced" shape as `callIdentityUnauthenticatedChange`.
    @Published var realityKeyChanged: Bool = false
    /// Re-entrancy guard so overlapping stall signals / toggle taps can't fire
    /// two concurrent RealityManager.start() attempts.
    private var realityActivationInFlight: Bool = false
    /// W90: peer userId of the currently-open chat. ChatContainer.markRead
    /// sets this on .onAppear; ChatContainer deinits clear it. Used by
    /// `handleIncomingMessage` to suppress local-notification banners
    /// for the conversation the user is actively viewing — avoids the
    /// "banner pops up while I'm reading the message" UX gaffe.
    internal var activePeerUserId: String?
    /// Fase 1B — groupHex of the currently-open group chat. GroupChatScreen
    /// sets this on `.onAppear` and clears it on `.onDisappear`; used by
    /// `handleIncomingGroupMessage` to suppress the inbound-group banner for
    /// the group the user is actively viewing (mirrors `activePeerUserId`).
    internal var activeGroupHex: String?
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

    /// Phase-10b handshake signing — Keychain-backed TOFU pin store for peer
    /// long-term Ed25519 identity keys (HANDSHAKE-SIGNING-SPEC.md §2/§5c). Shared
    /// across both call-integration construction sites so the caller-side and
    /// responder-side handshakes pin/resolve against ONE store.
    private lazy var peerPinStore = PeerIdentityPinStore()

    /// Phase-10b `v4_capable_pinned` set (spec §4) — the set of peer contactIds
    /// for which a SIGNED v4 bundle has ever verified. Persisted in UserDefaults
    /// (never cleared by the policy), so once a peer is v4-pinned a later
    /// unsigned handshake from it is rejected. Read/written directly via
    /// UserDefaults inside the integration closures (`wireHandshakeSigning`),
    /// which run off-main, so it is NOT wrapped in a MainActor-isolated helper.
    private static let peerV4PinnedDefaultsKey = "qaudion.hs.v4pinned.peers"

    /// SRTP downgrade fix: TOFU-pin analogue of `peerV4PinnedDefaultsKey` for
    /// the directional-SRTP-key (`srtpDirKeyV1`) capability — the set of peer
    /// contactIds for which a SIGNED bundle has ever advertised it. Same
    /// persistence shape (never cleared, read/written off-main inside
    /// `wireHandshakeSigning`'s closures).
    private static let peerSrtpDirKeyV1PinnedDefaultsKey = "qaudion.hs.srtpdirkeyv1pinned.peers"

    /// W75: cached PushKit VoIP token. PushKit emits this on first
    /// launch BEFORE the user is authenticated — we stash it here and
    /// retry the server POST after every auth-success transition. Once
    /// the registration succeeds, subsequent re-emits (rotation /
    /// reinstall) hit `registerVoipPushToken` directly.
    private var pendingVoipPushTokenHex: String?
    /// W-PUSHHEAL: persisted last-known VoIP token. Survives the success-clear of
    /// `pendingVoipPushTokenHex` AND process restarts. The server clears a device's
    /// token on a dead push (410/BadDeviceToken — ClearAPNsVoipToken) and Apple does
    /// NOT re-emit `didUpdate pushCredentials` on a stable install, so without a
    /// persistent token + an unconditional re-assert the device would never
    /// re-register and stay silently unreachable. Re-posted on login + foreground.
    private static let lastKnownVoipTokenKey = "qaudion.push.lastVoipTokenHex"
    /// W-NOCALLKIT — standard APNs (alert) device token, in flight to the server.
    /// Only used in `CallsGate.callKitFreeMode`: the server sends an INCOMING_CALL
    /// *alert* push (not VoIP) to this token when the app is killed. Mirrors
    /// `pendingVoipPushTokenHex`/`lastKnownVoipTokenKey` semantics.
    private var pendingApnsTokenHex: String?
    private static let lastKnownApnsTokenKey = "qaudion.push.lastApnsTokenHex"
    /// W-PUSHDEDUP: coalesce duplicate VoIP-token registrations. Several
    /// triggers fire on the SAME auth/foreground transition — launch
    /// auth-success (`reassertVoipPushTokenRegistration`), the foreground
    /// notification, the PushKit `didUpdate` re-emit — so the device used to
    /// POST `/account/apns-voip-token` 2-3× within a couple of seconds (the
    /// "pairs" in the server journal). These fields let `registerVoipPushToken`
    /// skip a POST when the SAME token is already in flight OR was confirmed
    /// registered within `voipRegisterCoalesceWindowSec`. The window is short
    /// so the long-timescale W-PUSHHEAL re-assert (login / foreground, minutes
    /// to hours apart) STILL re-posts to heal a server-side 410 clear.
    private var voipRegisterInFlightHex: String?
    private var lastVoipRegisteredHex: String?
    private var lastVoipRegisteredAt: Date?
    private static let voipRegisterCoalesceWindowSec: TimeInterval = 90
    /// SECURITY C-6: cert-pinned URLSession for VoIP push token registration.
    /// Lazy — created once on first use against the server URL configured at
    /// login time. Avoids per-call URLSession + thread-pool allocation.
    ///
    /// NOTE: captures `serverUrl` at first access (i.e. first push-token
    /// registration after login). `serverUrl` is always `PinnedServerHost.url`
    /// today (see line ~275 comment). If serverUrl ever becomes genuinely
    /// reconfigurable, this property must be reset to nil between logins so
    /// the next registration pins against the new host.
    private lazy var voipPushSession: URLSession = PinnedURLSession.make(for: serverUrl)

    // MARK: - Contacts cache (W-CC)
    /// In-memory snapshot of ContactsStore, refreshed at app start and on
    /// every ContactsStore write (via .contactsDidChange notification).
    /// Use this instead of ContactsStore().load() in hot paths (incoming call,
    /// message receive, outgoing call dial) to avoid a UserDefaults decode
    /// on each event.
    /// Internal read access (module-visible) so Views can use the cached
    /// snapshot directly without re-loading ContactsStore. Mutation is
    /// private — only refreshContactsCache() may write this.
    private(set) var cachedContacts: [ContactsStore.StoredContact] = []
    private var contactsCacheObserver: NSObjectProtocol?
    /// I1-RESUME — see `.presenceVisibilityDidChange`'s declaration.
    private var presenceVisibilityObserver: NSObjectProtocol?
    /// W-EARTOUCH (2026-07-27) — re-evaluates proximity monitoring on every
    /// route change (Bluetooth/wired connect or disconnect), not just the
    /// manual speaker toggle. See `updateProximityMonitoring()`.
    private var audioRouteChangeObserver: NSObjectProtocol?

    /// W-ORPHANPEER — peers the server has answered a definitive 404 for:
    /// accounts that no longer exist. Hidden from the address book and from
    /// every "who can I reach" picker. See `PeerOrphanPolicy.swift` in the
    /// engine for the rules, and for why "gone" and "unreachable" must not be
    /// conflated.
    ///
    /// `@Published` on purpose, unlike `cachedContacts` above: this one has to
    /// re-render the lists mid-session as the lookups land, and a plain
    /// `private(set) var` on an ObservableObject does not fire
    /// `objectWillChange` — the hidden contact would stay on screen until some
    /// unrelated redraw happened to come along.
    ///
    /// In-memory only. Nothing is written to `ContactsStore`, so the set is
    /// re-derived from live lookups on every launch and a restored backup or a
    /// corrected environment brings the contact back with no user action.
    @Published private(set) var orphanPeerIds: Set<String> = []

    /// Record what a profile lookup said about a peer. Only `.absent` marks
    /// and only `.exists` clears; `.unknown` deliberately does neither —
    /// marking would hide a real contact over a dropped connection, clearing
    /// would make the list flap on every failed retry.
    func recordPeerLookupOutcome(_ userId: String, _ outcome: ProfileLookupOutcome) {
        guard !userId.isEmpty else { return }
        switch outcome {
        case .absent:
            guard !orphanPeerIds.contains(userId) else { return }
            orphanPeerIds.insert(userId)
        case .exists:
            guard orphanPeerIds.contains(userId) else { return }
            orphanPeerIds.remove(userId)
        case .unknown:
            return
        }
        // CarPlay builds its rows outside SwiftUI, so it cannot observe this
        // object — push the set across instead. Same exclusion, same source.
        CarPlayBridge.shared.orphanPeerIds = orphanPeerIds
    }

    /// The contacts the user can actually reach — everything in
    /// `cachedContacts` minus the orphans. Use this wherever the question is
    /// "who can I call or write to"; keep using `cachedContacts` where the
    /// question is "what name goes on this row", because an existing
    /// conversation with an orphan still needs its label.
    var reachableContacts: [ContactsStore.StoredContact] {
        cachedContacts.filter { !shouldHideContact(orphanPeerIds.contains($0.userId)) }
    }

    // MARK: - Call state
    /// WIRE_SPEC §8.9 — arm/disarm the video-state beacon with the call, from
    /// the ONE flag every call path already flips. There are a dozen
    /// `isInCall = ...` sites; hooking them individually would leave the next
    /// one added silently un-beaconed, which is the same drift that produced
    /// the bug the beacon exists to fix.
    @Published var isInCall: Bool = false {
        didSet {
            guard oldValue != isInCall else { return }
            if isInCall { startVideoBeacon() } else { stopVideoBeacon() }
        }
    }
    @Published var isVideoCall: Bool = false { didSet { noteVideoLaneChanged() } }
    /// W-EARTOUCH (2026-07-27) — every callState transition re-evaluates
    /// proximity monitoring (see `updateProximityMonitoring()`), the same
    /// "one flag every call path already flips" choke point `isInCall`'s own
    /// didSet above uses for the video beacon.
    @Published var callState: CallState = .idle {
        didSet {
            guard oldValue != callState else { return }
            updateProximityMonitoring()
        }
    }
    @Published var callContactId: String?
    /// W-CALLSPKR (2026-07-20) — the user's live loudspeaker preference for
    /// the CURRENT 1:1 call, set by `setSpeaker(_:)` and consulted by the
    /// `onAudioSessionActivated` fork below. Mirrors the state group calls
    /// already track implicitly via `routeGroupCallAudioToSpeaker()` (which
    /// re-derives "should be on speaker" from the live route instead of a
    /// flag — not reusable here because a 1:1 call's default IS the
    /// earpiece, so "current route is receiver" can't distinguish "user
    /// never asked for speaker" from "CallKit just downgraded us out of
    /// it"). Reset to `false` on every call teardown (endCall) so a stale
    /// preference never leaks into the next call.
    /// W-AUDIOUILIE (2026-07-24) — published read-only so a call surface that is
    /// REMOUNTED mid-call (every video upgrade/downgrade swaps `VideoCallView` /
    /// `LiveInCallScreen`) can seed its controls from the live truth instead of a
    /// hardcoded default. Both views used to open with fabricated values
    /// (`VideoCallView`: muted=false + speaker=ON; `LiveInCallScreen`: both false),
    /// so after a single video toggle the buttons could claim the opposite of the
    /// real routing — and the user's next tap then applied the inverse of what they
    /// intended. Setter stays internal: every write is inside AppState
    /// (`endCall` reset and the speaker toggle), so `private(set)` is exact.
    @Published private(set) var callSpeakerOn: Bool = false

    /// W-MUTEBTNSRC (2026-07-24) — the observable mirror of `CallService.isMuted`,
    /// the same shape `callSpeakerOn` already has for the route.
    ///
    /// `CallService` is not an `ObservableObject` and `isMuted` is not
    /// `@Published`, so a view reading it directly never re-renders when it
    /// changes. The two call surfaces worked around that differently:
    /// `LiveInCallScreen` re-reads it on every TimelineView tick, while
    /// `VideoCallView` kept a local `@State` seeded once in `onAppear`. The
    /// second is wrong for a reason that is not cosmetic: CallKit's
    /// `CXSetMutedCallAction` (the system call UI, the lock screen, a headset
    /// button) reaches `setMuted` without going through the button, so the mic
    /// could be genuinely muted while the button still read "live" — and the
    /// next tap would then unmute-then-mute rather than unmute.
    @Published private(set) var callMuted: Bool = false
    /// W-ICEGRACE (2026-07-21) — pending "ICE went `.disconnected`, give it a
    /// chance to recover before tearing the call down" countdown. Mirrors
    /// Android's `DISCONNECT_GRACE_MS` (CallTransportFactory.kt:821). Non-nil
    /// only while a grace window is running; cancelled on ICE recovery, on a
    /// terminal ICE state, and on teardown.
    private var iceDisconnectGraceTask: Task<Void, Never>?
    /// W-ICEGRACE — grace window length. Byte-for-byte the same 3000 ms
    /// Android has used since its own fix; keep the two in lockstep.
    private static let iceDisconnectGraceMs: Int = 3_000
    /// W-UPGRADEICEWATCHDOG (2026-07-28) — the on-demand PeerConnection built
    /// by `makeUpgradeResponderController()` for a video upgrade on a
    /// WS-relay-only (audio-only) call has NO proactive timeout: `onIceConnectionState`
    /// only rolls the video back on an explicit `.failed`/`.disconnected`/`.closed`
    /// callback. Live-reproduced: on a restrictive NAT this fresh ICE can sit in
    /// `.checking` forever without ever reaching a terminal state, so the callback
    /// never fires — the peer (Android) sees SDP negotiated fine, zero video ever
    /// arrives, and the call is stuck black until the user manually hangs up
    /// (observed live: 90+ s). Arms alongside the ICE grace/disconnect handling
    /// above but is its own independent watchdog since this PC is a distinct
    /// object from the call's primary controller.
    private var upgradeResponderIceConnectTask: Task<Void, Never>?
    /// W-UPGRADEICEWATCHDOG — how long the on-demand upgrade responder PC gets
    /// to reach `.connected`/`.completed` before we treat it as failed and roll
    /// the video back ourselves. Generous relative to a normal P2P/TURN connect
    /// (which completes in low single-digit seconds) without leaving the user
    /// staring at a black video anywhere near as long as the un-timed-out case.
    private static let upgradeResponderIceConnectTimeoutMs: Int = 10_000
    /// W-OFFERBUFFER (2026-07-12) — OFFER messages (PQC or Android-JSON)
    /// that arrived while `callContactId` was still nil. Desktop/Android
    /// ship the opaque OFFER BEFORE the `call_offer` envelope that sets
    /// `callContactId` via `call_incoming`, so on every first-ever
    /// incoming call the OFFER legitimately arrives ahead of it. The
    /// strict `callContactId == senderId` guard (567e953) must stay
    /// strict — reverting d3b304f, which relaxed it, restored a real
    /// key-injection/call-hijack hole and caused a session-key mismatch
    /// between two live devices. Buffering here gets the same outcome
    /// (the legitimate first OFFER is not dropped) without weakening the
    /// check: a buffered entry only ever replays if callContactId is
    /// LATER set to that exact senderId by the real call_incoming/
    /// prepareIncomingPushCall path; an attacker's OFFER sent while
    /// callContactId is nil just expires unprocessed, identical to a
    /// drop. TTL-based (not tied to callContactId reset call sites) so
    /// it self-cleans even if a future call-end path misses clearing it.
    private struct PendingOfferReplay {
        let senderId: String
        let enqueuedAt: Date
        let replay: () -> Void
    }
    private var pendingOfferReplays: [PendingOfferReplay] = []
    private static let pendingOfferReplayCap = 4
    private static let pendingOfferReplayTTL: TimeInterval = 5.0

    /// Buffer an OFFER dispatch for replay once `callContactId` becomes
    /// exactly `senderId`. Bounded + TTL-pruned on every call (append and
    /// drain) so a burst of unsolicited OFFERs from different senders
    /// can't grow this unbounded, and a stale entry can't outlive the
    /// handshake window it exists for.
    @MainActor
    private func bufferOfferReplay(senderId: String, replay: @escaping () -> Void) {
        let now = Date()
        pendingOfferReplays.removeAll { now.timeIntervalSince($0.enqueuedAt) > Self.pendingOfferReplayTTL }
        if pendingOfferReplays.count >= Self.pendingOfferReplayCap {
            pendingOfferReplays.removeFirst()
        }
        pendingOfferReplays.append(PendingOfferReplay(senderId: senderId, enqueuedAt: now, replay: replay))
    }

    /// Call right after every `callContactId = <non-nil>` assignment
    /// (mirrors `drainRxPreBuffer()`'s placement right after
    /// `callIntegration` binds in CallService.swift). Replays only the
    /// entries whose senderId matches what callContactId was just set
    /// to; everything else — expired or from a different sender — is
    /// discarded, never processed.
    @MainActor
    private func drainPendingOfferReplays(for senderId: String) {
        guard !pendingOfferReplays.isEmpty else { return }
        let now = Date()
        let matches = pendingOfferReplays.filter {
            $0.senderId == senderId && now.timeIntervalSince($0.enqueuedAt) <= Self.pendingOfferReplayTTL
        }
        pendingOfferReplays.removeAll { $0.senderId == senderId }
        for m in matches { m.replay() }
    }
    /// WIRE_SPEC §8.1 — true when the remote peer has signalled
    /// `call_video_state(paused: true)` (they turned their camera off).
    /// Purely informational UI state: it never touches the PeerConnection
    /// or the negotiated `m=video` line. Reset to false at the start of
    /// every new call (same lifecycle as the other call-scoped published
    /// fields above). Drives the "peer paused their video" badge and,
    /// combined with the local camera-off state, the auto-fallback to
    /// the audio-only call screen (ContentView.inCallStack).
    @Published var remoteVideoPaused: Bool = false { didSet { noteVideoLaneChanged() } }
    /// WIRE_SPEC §8.1 — mirrors VideoCallView's local `isCameraOn` toggle
    /// (true = camera off) so `ContentView.inCallStack` can decide the
    /// audio-only-screen fallback without VideoCallView's private @State.
    /// Set by `videoSetCameraEnabled`; same reset lifecycle as
    /// `remoteVideoPaused` above.
    @Published var localVideoPaused: Bool = false { didSet { noteVideoLaneChanged() } }

    // MARK: - W-VIDTRANS (2026-07-24) — video-lane transition telemetry
    //
    // The "va in video, torna a voce, va in video, si blocca" report was
    // undiagnosable from the server: we shipped periodic `video.stats` and
    // on-detection `video.stall`, but nothing recording WHEN the call changed
    // lane or in which direction — so a peer left stuck in the wrong lane was
    // only visible with a cable attached. Android writes its lane through one
    // choke point (`CallController.setVideoState`); iOS's lane is DERIVED from
    // three independently-written published flags with ~20 write sites between
    // them, so instead of refactoring every writer this observes the derived
    // value. Every present and FUTURE writer is covered by construction.
    //
    // `videoTransitionCause` is a best-effort hint the intentional writers set
    // just before flipping a flag; it defaults back to "derived" after each
    // emission so a stale label can never be attributed to an unrelated flip.

    /// The four lane names Android's `VideoLaneTransitions` and Desktop's
    /// `videoLaneName()` use — identical vocabulary so ONE server-side query
    /// answers "which side got stuck" across all three platforms.
    /// W-CAMBTNSRC (2026-07-24) — THE authoritative "is MY camera sending"
    /// signal, and the only one any UI may render a camera control from.
    ///
    /// Three in-call surfaces each had their own formula for this one fact:
    /// `InCallView` and `LiveInCallScreen` seeded from `isVideoCall` ("does
    /// this call have video AT ALL"), so while only the PEER was sending the
    /// local camera button displayed as ON in what was, for that user, a
    /// voice call; `VideoCallView` used `!localVideoPaused`, whose default
    /// `false` is ambiguous between "not paused" and "never started" — the
    /// same ambiguity WIRE_SPEC §8.9 calls out for the `paused` wire field.
    /// Confirmed live on call fec3decc.
    ///
    /// `isVideoCall` is "this call has video on at least one lane"; it is NOT
    /// a statement about our own camera. Both conditions are required.
    var localCameraSending: Bool { isVideoCall && !localVideoPaused }

    /// Mirror for the peer's lane, so a "peer is sending" badge never has to
    /// re-derive it either.
    var peerCameraSending: Bool { isVideoCall && !remoteVideoPaused }

    private var videoLaneName: String {
        guard isVideoCall else { return "Off" }
        if localCameraSending && peerCameraSending { return "Both" }
        if localCameraSending { return "LocalOnly" }
        if peerCameraSending { return "RemoteOnly" }
        return "Off"
    }

    /// Hint for the NEXT lane flip, consumed and reset on emission.
    var videoTransitionCause: String = "derived"

    // MARK: - WIRE_SPEC §8.9 video-state beacon
    //
    // Edge-triggered signalling made the peer's view of our camera depend on
    // receiving every single toggle: one announcement lost to a stale WS, a
    // mid-call reconnect, or a reordered pair, and the two sides disagreed for
    // the rest of the call with no path back. Unlike the lane-table defect
    // fixed alongside it, no amount of correct local logic recovers from an
    // edge that never arrived — hence a state-triggered beacon that re-states
    // the CURRENT value on change and on a timer.

    /// Our outbound announcement counter for the ACTIVE call (reset per call).
    private var videoBeaconSeq: Int = 0
    /// What we last told the peer, so the on-change trigger stays cheap.
    private var videoBeaconLastSent: Bool?
    /// Highest seq accepted from the peer — the last-writer-wins window.
    fileprivate var videoBeaconPeerSeq: Int?
    private var videoBeaconTimer: Timer?

    /// Announce OUR current video-send state. `force` is used by the heartbeat
    /// to REPEAT an unchanged value — that repetition is the whole point.
    /// Best-effort throughout (signal-not-kill): a failed send is retried by
    /// the next heartbeat, never surfaced into the call.
    func announceVideoState(force: Bool) {
        let sending = localCameraSending
        guard VideoStateBeacon.shouldAnnounce(
            lastAnnouncedSending: videoBeaconLastSent, sending: sending, force: force) else { return }
        guard let peerId = callContactId,
              let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId() else { return }
        videoBeaconSeq = VideoStateBeacon.advance(videoBeaconSeq)
        videoBeaconLastSent = sending
        let seq = videoBeaconSeq
        let screen = isScreenSharing
        Task { [weak self] in
            do {
                try await impl.sendVideoState(
                    callId: callId, recipientId: peerId,
                    paused: !sending, seq: seq, screen: screen)
            } catch {
                // Let the next heartbeat re-send: clearing the memo makes the
                // on-change trigger fire again even if the state has not moved.
                await MainActor.run { self?.videoBeaconLastSent = nil }
            }
        }
    }

    /// Start the §8.9 heartbeat for the active call. Idempotent.
    func startVideoBeacon() {
        stopVideoBeacon()
        let t = Timer.scheduledTimer(
            withTimeInterval: Double(VideoStateBeacon.heartbeatMs) / 1000.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.announceVideoState(force: true) }
        }
        // The call UI drives the run loop in .common during scrolling/animation;
        // .default alone would silently stall the heartbeat there.
        RunLoop.main.add(t, forMode: .common)
        videoBeaconTimer = t
        announceVideoState(force: true)
    }

    /// Stop beaconing and reset the window, so the next call cannot inherit a
    /// seq high enough to reject its own first announcements.
    func stopVideoBeacon() {
        videoBeaconTimer?.invalidate()
        videoBeaconTimer = nil
        videoBeaconSeq = 0
        videoBeaconLastSent = nil
        videoBeaconPeerSeq = nil
    }
    private var lastVideoLaneName: String = "Off"
    private var lastVideoTransitionAtMs: Int64 = 0

    private func noteVideoLaneChanged() {
        let next = videoLaneName
        let prev = lastVideoLaneName
        guard prev != next else { return }
        lastVideoLaneName = next
        // A lane collapse while the call is already gone is ALWAYS teardown,
        // whatever hint happened to be left over. Without this the last row of
        // call fec3decc read `Both -> Off (peer-camera-start)` — a stale hint
        // from the previous flip attributed to the hangup, which is exactly the
        // kind of confident-but-wrong record that sends a future reader chasing
        // a bug that never happened.
        let cause = isInCall ? videoTransitionCause : "call-teardown"
        videoTransitionCause = "derived"
        // W-CONSENTSESSION (2026-07-25) — consent is for THIS video session, not
        // for the rest of the call. It was cleared only at call end, so after one
        // accepted upgrade the auto-accept branch (`videoConsentGranted ||
        // isVideoCall`) fired on every later request: go to video, both sides
        // downgrade to audio, upgrade again, and both cameras opened with no
        // prompt. Reaching `Off` means neither side is sending, so the session is
        // over. NOT cleared on Both -> LocalOnly/RemoteOnly, where video is still
        // live on one lane and a re-offer is the benign renegotiation the latch
        // legitimately exists for.
        if next == "Off" && videoConsentGranted {
            RTLog.info("call", "video consent cleared — call is back to audio (was \(prev))")
            videoConsentGranted = false
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sincePrev = lastVideoTransitionAtMs == 0 ? -1 : nowMs - lastVideoTransitionAtMs
        lastVideoTransitionAtMs = nowMs
        let callId = (liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId()
        let c = callService.liveAudioCounters
        TelemetryService.shared.emit(
            kind: "call.video.transition",
            callId: callId,
            attrs: [
                "from": prev,
                "to": next,
                "cause": cause,
                "local_sending": localCameraSending,
                "peer_sending": peerCameraSending,
                "since_prev_ms": sincePrev,
                // Audio liveness AT the flip — a transition after which
                // tx_enc/rx_dec stop climbing is the audio-death signature.
                "tx_enc": c.txEnc,
                "rx_recv": c.rxRecv,
                "rx_dec": c.rxDec,
            ]
        )
    }
    /// D11 / W-NOBRICK — true when the active call's peer presented an
    /// UNAUTHENTICATED identity-key change (the handshake signer key is ∉ the
    /// server-published per-device set). Drives a NON-BLOCKING advisory banner in
    /// `InCallScreen` ("verify SAS"); it NEVER gates audio/video. Set off-main by
    /// the integration's `onUnauthenticatedIdentityChange` (marshalled to
    /// MainActor); reset at the start of every new call.
    @Published var callIdentityUnauthenticatedChange: Bool = false
    /// W-ASSURANCE (ship step 6) — THIS call's LIVE `AssuranceState` verdict.
    /// `nil` until `emitKeyConfirmationTelemetry` resolves one (peer doesn't
    /// support mix ⇒ almost immediately; otherwise after the kc_mac exchange
    /// settles, ≤5000ms in) — `LiveInCallScreen` renders no section at all
    /// while nil, never a fabricated placeholder. Reset at the start of
    /// every new call, same lifecycle as `callIdentityUnauthenticatedChange`
    /// above.
    ///
    /// Deliberately the RAW enum, not a pre-built `AssuranceStateUI
    /// .Presentation` — `AssuranceStateUI.present(...)` needs a `secretLabel`
    /// (the contact's display name, NEVER a raw UUID per this project's
    /// standing rule), and `LiveInCallScreen` already has the UI-safe
    /// resolved name (`cachedPeerDisplayName`) that AppState itself does not
    /// duplicate name-resolution logic to re-derive. The View maps this to
    /// a `Presentation` at render time.
    @Published var callAssuranceState: AssuranceState? = nil
    /// The `expectedNfc` this call's verdict was computed with — needed
    /// alongside `callAssuranceState` because `AssuranceStateUI.present`'s S0
    /// copy is a compound of BOTH.
    @Published var callAssuranceExpectedNfc: Bool = false
    /// W-NFCCOMMON (2026-07-24, Pavel correction) — "this device and the peer
    /// BOTH hold a matching NFC-tap secret", independent of whether THIS
    /// call's session key actually mixes it (`callAssuranceState` above can
    /// legitimately be S8/S9/S10 with this still `true` — vault priority
    /// picked a different secret, e.g. KMS). Drives the trust bar's OWN
    /// always-on "NFC ✓" chip, additive to (never gated by) whichever
    /// `AssuranceStateUI.Presentation` `callAssuranceState` renders as.
    @Published var callMutualNfcInCommon: Bool = false
    /// W-NFCCOMMON follow-up (2026-07-24, Pavel DECISION) — "a pre-shared key of ANY
    /// origin (KMS/NFC/QR/manual) is mixed into this call's session key", i.e. `n>=1`.
    /// Deliberately independent of `callAssuranceState`: Pavel's explicit choice is
    /// that the trust bar's "PSK ✓" chip shows in EVERY state a PSK was mixed —
    /// including the warning states (S1 active-attack-signature, S7 NFC-downgrade-
    /// regression). The chip answers only "does a shared secret exist for this
    /// call", never "is everything about it fine" — that second question is what
    /// the warning banner is for. `false` only for genuine PQC-only (S10, n==0).
    @Published var callPskMixedThisCall: Bool = false
    /// "Voce come chiave" cross-device attestation (item 2, 2026-07-31
    /// InCallScreen Android→iOS port) — `true` once the PEER has announced,
    /// over the `<callId>|VOICE_KEY:1` opaque_message piggy-back
    /// (`CallPiggyBack.voiceKey`, see `routeInboundCallPiggyBack`), that
    /// Voice-as-Key is enrolled on THEIR OWN device. Self-declared, NOT a
    /// crypto proof — it says nothing about whether THIS call has actually
    /// recognized their voice (that's the separate live Guardian
    /// confidence signal). Mirrors Android's
    /// `CallController.peerVoiceKeyEnrolled`. Reset at the start of every
    /// new call, same lifecycle as `callMutualNfcInCommon` above.
    @Published var callPeerVoiceKeyEnrolled: Bool = false
    /// D11 — `sender_device_id` (server-stamped) captured from the most recent
    /// `call_incoming` envelope, keyed by `sender_id`. The OFFER/ACCEPT bundles
    /// arrive over `opaque_message`, which the server relays WITHOUT a device id
    /// (only `sender_id`), so we stash the device id here from `call_incoming`
    /// and thread it into the per-device verdict when the bundle lands. Absent ⇒
    /// nil ⇒ legacy single-key + set-membership (never a fatal mismatch).
    private var senderDeviceIdByPeer: [String: String] = [:]
    /// W478 — display name of the incoming caller, set when `call_incoming`
    /// is processed. Shown in the in-app ringing banner as a fallback when
    /// CallKit's system UI is suppressed (Focus / Silence Unknown Callers).
    @Published var incomingCallerName: String = ""
    /// W-1TO1RING (2026-07-27) — mirrors `incomingGroupCallInvite`: set
    /// unconditionally whenever a 1:1 call arrives (push or WS), regardless
    /// of whether CallKit's native UI also owns the ring. Drives the same
    /// rich `IncomingCallScreen` already used for group calls, replacing
    /// the old thin `HomeView.incomingCallBanner`. While the device is
    /// genuinely locked, CallKit's native UI is still the only thing
    /// visible (Apple platform constraint — no SwiftUI view can render
    /// over the lock screen) — this flag only matters once the app can
    /// actually draw (foreground at arrival, or becomes active after a
    /// CallKit-mediated wake), exactly like the group-call ring.
    @Published var incomingCallRingVisible: Bool = false
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
    /// DISPLAY-ONLY method label of the sovereign/KMS PSK mixed into the
    /// active call's session key ("KMS" for KMS-delivered keys, "NFC" /
    /// "QR" etc. for imported ones). Empty when no PSK was mixed. Mirrors
    /// Android `keyInfo.pskMethodLabel`. Written by the broker's display
    /// closures; never participates in any derivation.
    @Published var pskMethod: String = ""
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
    /// Task 10 — the video PQC sealer's `(callId, selfIsRoleA)` identity,
    /// pinned ONCE at `startVideoPipeline` and reused verbatim by the later
    /// `wireSasReadyToController` rotate. Two independently-computed
    /// `selfIsRoleA` values (one from the `peerId` function param, one from
    /// `callContactId`) could in principle diverge if the two ever disagree
    /// for the active call — pinning removes that divergence risk by
    /// construction instead of relying on the two sources always agreeing.
    /// Cleared alongside `callPqcSessionKey` at hangup so a stale pin can
    /// never leak into the next call's pipeline.
    private var activeVideoCallIdentity: (callId: String, selfIsRoleA: Bool)?
    /// vkey-v1 — raw sovereign/KMS PSK bytes mixed into THIS call's session
    /// key, resolved by the negotiated PSK fingerprint. Pushed to the WebRTC
    /// controller as `videoContactPsk` so K_video's HKDF *salt* = psk —
    /// byte-identical to Android `deriveVideoKey(psk = psk)`
    /// (PqcHandshake.kt:674). nil when no PSK was selected (both platforms then
    /// fall back to the default "Q-AUDION-PHONE-VIDEO-SALT-V1" salt). Without
    /// this, iOS derived K_video with the default salt while Android used the
    /// psk → divergent K_video → AES-GCM video frames undecryptable cross-
    /// platform (black/garbage) while audio kept working.
    var callVideoPsk: Data?
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
    /// W-GRPUI: the manager backing `groupCallController`, built once in
    /// `connectPersistentSocket()`. Stored so the root view can hand both
    /// to `GroupCallViewModel` without the engine layer exposing its
    /// private `manager` reference.
    var groupCallManager: BCryptoGroupCallManager?
    /// W-GRPUI: the single `GroupCallViewModel` instance wrapping
    /// `groupCallManager`/`groupCallController`. Built once alongside them
    /// so its `onStateChanged`/`onParticipantsChanged` bindings survive
    /// across `GroupCallView` presentations (a fresh ViewModel per
    /// presentation would silently re-subscribe every time SwiftUI
    /// re-evaluates the cover's content closure).
    var groupCallViewModel: GroupCallViewModel?
    /// W-GRPUI: mirrors `GroupCallController.onStateChange` so the root
    /// view can drive `GroupCallView`'s presentation off a directly-
    /// observed `@Published` (a nested ObservableObject's own `@Published`
    /// changes don't propagate through `appState.groupCallViewModel?.x`
    /// unless the view separately observes that nested object).
    @Published var groupCallControllerState: GroupCallController.State = .idle

    /// W561 — the callId of whatever call is active right now (group takes
    /// priority since `callState`/`BCryptoCallingApiImpl` don't expose a 1:1
    /// call id when idle). Feeds `BugReporter`'s `call_id` form field — see
    /// that class's `ActiveCallIdProvider` kdoc for why this field existing
    /// server-side but never being populated by ANY client was the actual
    /// gap.
    func activeCallIdForReport() -> String? {
        switch groupCallControllerState {
        case .connecting(let callId), .active(let callId, _):
            return callId
        case .idle, .failed:
            break
        }
        return (liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId()
    }

    /// W561 — compact JSON snapshot of call/network state at trigger time,
    /// folded into the bug report's encrypted body (see `BugReporter`'s
    /// `DiagSnapshotProvider` kdoc). Primitives-only across the AppState/
    /// BugReporter boundary per CLAUDE.md rule #16 — this method does all
    /// the type-aware work and returns a plain String.
    ///
    /// Deliberately NOT redacting participant UUIDs here (unlike
    /// user-facing UI, which never shows a raw UUID): this JSON is only ever
    /// decrypted by the admin/maintainer, and full UUIDs are what make a
    /// report directly correlatable against `qa-logs.ps1`/`tune-report.py`
    /// without the reporter having to separately state which peers were
    /// involved.
    func buildDiagSnapshotJSON() -> String {
        var call: [String: Any] = ["one_to_one_state": callState.rawValue]
        switch groupCallControllerState {
        case .idle:
            call["group_state"] = "idle"
        case .connecting(let callId):
            call["group_state"] = "connecting"
            call["group_call_id"] = callId
        case .active(let callId, let participants):
            call["group_state"] = "active"
            call["group_call_id"] = callId
            call["group_participant_count"] = participants.count
            call["group_participants"] = participants
        case .failed(let reason):
            call["group_state"] = "failed"
            call["group_failed_reason"] = reason
        }
        if let oneToOneCallId = (liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId() {
            call["one_to_one_call_id"] = oneToOneCallId
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshot: [String: Any] = [
            "schema": 1,
            "captured_at": iso.string(from: Date()),
            "ws_state": wsConnectionState.rawValue,
            "call": call,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// W-GRPRING — one pending INCOMING group call (ring state).
    struct IncomingGroupCallInvite: Equatable {
        let callId: String
        let creatorId: String
        let creatorName: String
        /// "audio" | "video" — server contract (`group_call_invite` /
        /// `incoming_group_call` push both carry it).
        let callType: String
        /// Empty for an ad-hoc group call started from the contact picker.
        let groupId: String
        let groupName: String

        var hasVideo: Bool { callType == "video" }
        /// What the ring screen shows: the group when the call was started
        /// from a real group, otherwise whoever started it.
        ///
        /// W-GRPTITLE-UUIDGAP (2026-07-20): `groupName`/`creatorName` here
        /// are wire/push-supplied values (`group_call_invite`'s raw
        /// `group_name` is NEVER resolved — see
        /// `BCryptoGroupCallManager.registerHandlers`'s kdoc: "additive... a
        /// create sent by an older client leaves them empty strings", not
        /// necessarily a real name) and were trusted VERBATIM here with no
        /// `looksLikeUUID` guard — unlike every other identity render in
        /// this codebase, which goes through `DisplayName.forUser`/
        /// `forGroup` specifically BECAUSE a raw id can surface un-sanitised
        /// this way. This is the one `displayTitle` feeds: CallKit's
        /// `callerName` (the native lock-screen/in-call incoming-call UI)
        /// and the W-NOCALLKIT local notification banner — i.e. exactly the
        /// surface most likely to be "the group call screen" a user sees a
        /// raw UUID on, since it renders before the app UI (which uses the
        /// correctly-guarded per-participant `nameResolver`) is even open.
        var displayTitle: String {
            let g = groupName.trimmingCharacters(in: .whitespaces)
            if !g.isEmpty, !DisplayName.looksLikeUUID(g) { return g }
            let c = creatorName.trimmingCharacters(in: .whitespaces)
            if !c.isEmpty, !DisplayName.looksLikeUUID(c) { return c }
            // groupName/creatorName were empty OR themselves UUID-shaped —
            // never fall through to them. A real group gets the humane
            // per-kind fallback ("Gruppo a1b2c3d4…"); otherwise resolve the
            // creator through the central chain (rubrica -> "Utente
            // a1b2c3d4…") — matches DisplayName.forUser/forGroup exactly,
            // never a bare UUID slice.
            if !groupId.isEmpty { return DisplayName.shortGroupFallback(groupId) }
            return DisplayName.forUser(creatorId)
        }
    }

    /// W-GRPRING: the pending incoming group call — set by BOTH the live WS
    /// `group_call_invite` AND the `incoming_group_call` push (deduped by
    /// `call_id`), and cleared on accept / reject / call-ended. Non-nil ==
    /// the ring surface is up and we have NOT joined. Accept →
    /// `groupCallController.join(callId:)` (the existing join path); reject
    /// → we simply never join (there is no `group_call_decline` wire type —
    /// the server keeps the room open for the other invitees).
    ///
    /// This REPLACES the previous silent auto-join (the invite used to call
    /// `join()` immediately: no ring, no accept/reject — audit gap).
    @Published var incomingGroupCallInvite: IncomingGroupCallInvite?

    /// W-GRPRING — the CallKit UUID we reported for the pending/active group
    /// call, so `onAnswerCall` / `onEndCall` can tell a GROUP call apart from
    /// a 1:1 one and route to the group accept/leave path instead of the 1:1
    /// `performAcceptIncoming` / `endCall`. nil == no CallKit call is up for a
    /// group call.
    var groupCallKitId: UUID?

    /// W-GRPRING — call_ids already accepted or rejected. Guards against a
    /// re-ring when the push and the WS invite race (deliberately NO
    /// server-side `armCallPushAck` delay for groups: one call_id has N
    /// invitees), and against a re-ring on WS reconnect. Bounded.
    var handledGroupCallIds: [String] = []

    /// W-GRPRING — accept latched during a cold start: the user answered the
    /// push-woken group call before `connectPersistentSocket()` built the
    /// GroupCallController, so `join(callId:)` had nowhere to go. Consumed the
    /// moment the controller exists (mirrors `pendingNotificationAnswer`).
    var pendingGroupCallJoinId: String?
    /// W-GRPVIDEO: the latched invite's `hasVideo`, set alongside
    /// `pendingGroupCallJoinId` — without this the cold-start join would
    /// always fall back to `join(callId:)`'s `video: false` default even
    /// when the invite was a video call.
    var pendingGroupCallJoinVideo: Bool = false
    /// In-call chat panel — the latched invite's `groupId` (dashed UUID,
    /// "" for an ad-hoc call), set alongside `pendingGroupCallJoinId` so
    /// the cold-start path can still bind `GroupCallViewModel.activeGroupId`
    /// once the controller exists (see the consumption site in
    /// `wireGroupCallManager`/`connectPersistentSocket`, mirroring how
    /// `pendingGroupCallJoinVideo` is threaded through the same latch).
    var pendingGroupCallJoinGroupId: String = ""
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

    // ─── media-consent v1 ─────────────────────────────────────────────
    /// The peer asked to turn their camera on mid-call. Non-nil while the
    /// consent dialog is on screen; cleared by accept / decline / timeout /
    /// call teardown. Receiving this NEVER touches the local camera.
    struct PendingIncomingUpgrade: Equatable {
        let callId: String
        let senderId: String
        let sdp: String
        /// True when this prompt came from a `call_upgrade_intent` (peer
        /// wants video but asked US to send the real offer) rather than a
        /// normal `call_upgrade_request` with SDP attached. `sdp` is empty
        /// in that case — accept/decline branches on this flag instead of
        /// touching `sdp`. Mirrors Android `IncomingUpgrade.isIntentOnly`.
        var isIntentOnly: Bool = false
    }
    @Published var pendingIncomingUpgrade: PendingIncomingUpgrade?

    /// True once camera video has been consented to in THIS call (either
    /// direction). Later camera renegotiations auto-accept instead of
    /// re-prompting. Reset on call teardown.
    private var videoConsentGranted: Bool = false

    /// W-VIDUP: true while an incoming video upgrade is being built (the
    /// on-demand PeerConnection + SDP answer take hundreds of ms). Blocks an
    /// Android offer-RETRANSMIT during that window from re-showing the consent
    /// dialog or racing a second build → which could later fire a contradictory
    /// accepted:false after we already shipped accepted:true.
    private var upgradeBuildInProgress: Bool = false

    /// W-VIDUP: pin outbound voice to the WS relay when the active controller
    /// was built ON-DEMAND solely for a video upgrade (the call's audio was
    /// never on WebRTC). Prevents silently moving the proven WS-relay audio leg
    /// onto the fresh DataChannel mid-call (which could flap on the restrictive
    /// NATs that put audio on the relay in the first place). Reset on teardown.
    private var audioPinnedToWsRelay: Bool = false

    /// Auto-decline timer for [pendingIncomingUpgrade]. WIRE_SPEC §8.2:
    /// responder auto-decline and requester watchdog are ALIGNED at 30s.
    /// (Was 25s; now matches the initiator's `upgradeResponseTimeoutTask`
    /// window — an explicit decline still races ahead of the initiator's
    /// own timeout because we ship `accepted=false` the instant this fires.)
    private var pendingUpgradeAutoDeclineTask: Task<Void, Never>?

    /// Initiator-side watchdog for OUR camera upgrade request: if no
    /// call_upgrade_response lands within 30s, roll the camera back.
    private var upgradeResponseTimeoutTask: Task<Void, Never>?

    /// What OUR outstanding `call_upgrade_request` was for ("camera" |
    /// "screen"), so the response handler knows whether to unpause the
    /// camera pipeline / roll it back. nil when nothing is in flight.
    private var pendingOutgoingUpgradeMedia: String?

    /// WIRE_SPEC §8.3 — the ORIGINAL role of THIS endpoint in the active
    /// call. Glare politeness is keyed to it: `.callee` = polite (rolls back
    /// its own colliding upgrade and accepts the peer's), `.caller` =
    /// impolite (ignores the peer's colliding request). Set at call setup
    /// (`.caller` in startCall; `.callee` on both incoming paths), reset on
    /// teardown. nil when not in a call.
    private var originalCallRole: UpgradeFlowDecisions.CallRole?

    /// WIRE_SPEC §8.7 — dedup for outbound `call_media_ready`: one send
    /// per "call_id:mid" combo (survives controller rebuilds on the
    /// upgrade paths). Cleared on call teardown in endCall().
    private var mediaReadySentKeys: Set<String> = []

    // WIRE_SPEC §8.7 — receiver-side RENDER gate (Android parity: the
    // inbound video track stays disabled until the receiver FrameCryptor
    // is attached, PeerConnectionHolder's "PURPLE-FRAME-ON-TOGGLE" gate).
    // iOS equivalent: hold the PUBLICATION of `remoteWebRtcVideoTrack`
    // (the only thing VideoCallView renders from) until our receiver
    // cryptor is attached+keyed (`onInboundVideoReady` → the same instant
    // we ship `call_media_ready`). A 2s failsafe lifts the gate anyway —
    // signal-not-kill, mirroring Android's watchdog FAILSAFE_LIFT: a
    // brief garbage frame is strictly better than never rendering.

    /// Remote WebRTC video track parked while the render gate is closed.
    /// Published to `remoteWebRtcVideoTrack` on gate open. Typed Any? for
    /// the same canImport(WebRTC) reason as `remoteWebRtcVideoTrack`.
    private var pendingRemoteVideoTrack: Any?
    /// True once the receiver cryptor readiness fired for this call —
    /// remote tracks publish immediately from then on (the readiness is a
    /// one-shot per call; a re-upgrade on the same call is still keyed).
    private var inboundVideoReadyThisCall = false
    /// 2s failsafe that lifts the render gate if readiness never fires
    /// (e.g. peer without E2EE video caps → no cryptor to attach).
    private var remoteVideoGateFailsafeTask: Task<Void, Never>?

    /// WIRE_SPEC §8.7 — honor-side rate limit: at most one forced local
    /// encoder IDR per second, however many call_media_ready /
    /// video_keyframe_request envelopes the peer ships.
    private var lastKeyframeForcedAt: Date = .distantPast

    // VIDEODIAG (WIRE_SPEC §8.7) — self-heal watchdog. SIGNAL-NOT-KILL:
    // it NEVER drops/tears down a call and never blocks anything — it
    // only heals (keyframe request, sink re-attach, call_media_ready
    // re-announce) and logs. NEVER-BLOCK: ONE 1s-tick task per call,
    // cancelled on endCall/rollback; counters bumped on existing hot
    // paths (VideoPathDiag), no per-frame tasks.

    /// Per-call video-path counters (arrived/decoded/rendered/IDR).
    /// Internal (not private) on purpose: VideoCallView hands it to
    /// WebRTCRemoteVideoView, whose Coordinator wraps the REAL UI renderer
    /// (RTCMTLVideoView) in a counting forwarder — the rendered-hop counter
    /// attaches/detaches IN LOCKSTEP with the on-screen renderer, so a
    /// detached renderer stops the counter and the watchdog can see the
    /// detached-renderer black-video class (rung 2 heals it).
    let videoDiag = VideoPathDiag()
    /// The ONE per-call 1s-tick watchdog task. nil = not running.
    private var videoDiagWatchdogTask: Task<Void, Never>?
    /// Escalation ladder state (pure engine, KAT-gated) the tick delegates to.
    private let videoStallLadder = VideoStallEscalationEngine()
    /// Tick memos: last observed counter values + the monotonic ms of
    /// their last increase (stall rule inputs).
    private var videoDiagPrevArrived: Int64 = 0
    private var videoDiagPrevRendered: Int64 = 0
    private var videoDiagLastArrivedIncreaseMs: Int64 = 0
    private var videoDiagLastRenderedIncreaseMs: Int64 = 0
    /// Last inbound video mid announced via call_media_ready — the mid
    /// the rung-3 re-announce re-sends for. Reset with the watchdog.
    private var lastInboundVideoMid: String?
    /// Timestamps (monotonic ms) of the most recent inbound
    /// video_keyframe_request envelopes — TX storm rule input
    /// (>=3 in 5s → force IDR immediately, one-shot limiter bypass).
    private var peerKeyframeRequestTimesMs: [Int64] = []

    /// True when [videoPipeline] was started decode-only (external source,
    /// paused) just to RENDER a WS-relay peer's screen share on an
    /// audio-only call — torn down again on SCREEN_SHARE:stop.
    private var decodeOnlyPipelineForPeerScreen: Bool = false

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

    /// W-KCMAC (multi-PSK-mixing SYNTHESIS.md ship step 5) — per-call state for
    /// the `KCMAC:` piggy-back exchange, keyed by lowercased callId. Populated
    /// by `handleKcMacReady` (fired from `QAudionCallIntegration.onKcMacReady`
    /// on both the caller and responder legs) and consumed by
    /// `handleInboundKcMac` (the peer's `KCMAC:` piggy-back) and the 5000ms
    /// deadline task. A class (not a struct) so both consumers mutate the SAME
    /// instance in place rather than needing a dictionary re-write on every
    /// field update. PURE OBSERVATION (W-NOBRICK): nothing here ever gates the
    /// call — `kcStatus` only ever feeds `AssuranceState`/telemetry.
    private final class KeyConfirmationCallState {
        let peerId: String
        let isInitiator: Bool
        /// `nil` ⇒ kc_mac was never attempted this call (peer didn't advertise
        /// pskMixV1, or a transcript-v2 binding/identity key was missing) —
        /// `kcStatus` stays `.absent` and no wire message is ever sent/awaited.
        let kcKey: Data?
        let transcript: Data?
        let n: Int
        let peerSupportsMix: Bool
        let sigOk: Bool
        let peerAdvertisedRoles: [Int]
        /// W-NFCBADGE — the hex fingerprint of the ONE PSK selected for this
        /// call (`KcMacReadyEvent.selectedFp`), `nil` when `n == 0`. Used by
        /// `emitKeyConfirmationTelemetry` to look up the vault entry's
        /// `PskOrigin` and (for an NFC-origin entry) the peer identity it was
        /// bound to at tap time.
        let selectedFp: String?
        var kcStatus: KeyConfirmation.Status = .absent
        /// Set once the FINAL verdict (verified / wrong / timed-out-absent) is
        /// recorded, so a late-arriving duplicate KCMAC or a race between the
        /// deadline task and an inbound MAC can't double-emit telemetry.
        var resultRecorded = false
        var deadlineTask: Task<Void, Never>?
        /// W-FLOOR (ship step 8) — moment this state was created, i.e. right
        /// after session-key derivation. Used as a PROXY for "connected media
        /// start" when computing `mediaDwellMs` for
        /// `ContactsStore.applyAssuranceOutcome`'s dwell gate — not an exact
        /// measurement of real audio frames flowing (that timer doesn't exist
        /// anywhere in this codebase yet), but session-key derivation and
        /// audio-stack start are, in practice, near-simultaneous on this call
        /// path. Documented here as a deliberate, disclosed approximation
        /// rather than silently presented as exact.
        let readyAt = Date()

        init(event: QAudionCallIntegration.KcMacReadyEvent) {
            peerId = event.peerId
            isInitiator = event.isInitiator
            kcKey = event.kcKey
            transcript = event.transcript
            n = event.n
            peerSupportsMix = event.peerSupportsMix
            sigOk = event.sigOk
            peerAdvertisedRoles = event.peerAdvertisedRoles
            selectedFp = event.selectedFp
        }
    }
    private var kcCallStates: [String: KeyConfirmationCallState] = [:]
    /// Read by `CallService.getKeyConfirmationTelemetry` at call teardown so
    /// the `psk_mix_n`/`kc_mac_result`/`assurance_state`/`expected_but_missing`
    /// fields can ride the EXISTING `call.audio.diag` emission (no new
    /// telemetry channel — see that closure's wiring for why). Populated by
    /// `emitKeyConfirmationTelemetry` the moment a call's kc_mac verdict (or
    /// lack thereof) is final; read once, left in place until `endCall()`
    /// clears the entry (a call can teardown-race the closure read, so the
    /// entry is intentionally NOT removed until the explicit cleanup call).
    private var keyConfirmationTelemetryByCall:
        [String: (pskMixN: Int, kcMacResult: String, assuranceState: String, expectedButMissing: Bool)] = [:]
    /// W-FLOOR (ship step 8) — the raw `AssuranceState` enum value (not just
    /// its telemetry string) plus the peer's userId for this call's FINAL
    /// verdict, so `clearKeyConfirmationState` can apply it to
    /// `ContactsStore.applyAssuranceOutcome` once the call is actually
    /// tearing down (when `mediaDwellMs` is knowable) — populated by the SAME
    /// `emitKeyConfirmationTelemetry` call that fills
    /// `keyConfirmationTelemetryByCall` above, a few seconds into the call;
    /// consumed later, at teardown.
    /// W-NFCBADGE — `witnessOk`/`selectedFp` ride alongside so
    /// `applyPresenceAuthOutcomeIfAny` persists the SAME witness verdict
    /// `emitKeyConfirmationTelemetry` fed `decide()` (rather than a second,
    /// independently-hardcoded value) and the real NFC fingerprint instead
    /// of an empty placeholder.
    private var finalAssuranceByCall: [String: (state: AssuranceState, peerId: String, selectedFp: String?, witnessOk: Bool)] = [:]

    /// W372: NotificationCenter observer guard — only register the
    /// group-chat fan-out listener once per AppState lifetime.
    private var groupFanOutWired: Bool = false
    /// W-GRPMSG: bounded retry buffer for inbound group TEXT messages
    /// whose recv chain isn't installed yet (the sender's
    /// `sender_key_init` is still in flight, or arrived out of order).
    /// Each entry is the raw `group_msg_receive`-shaped dict plus the
    /// live flag; retried after the next sender_key_init/rotate install.
    /// Mirrors GroupChatService's W395 ctl-envelope buffering idea.
    /// Capped so a flood of undecryptable frames can't grow unbounded.
    private var bufferedGroupWires: [(data: [String: Any], live: Bool)] = []
    private static let maxBufferedGroupWires = 128
    /// 2026-07-17 — same buffering idea as `bufferedGroupWires`, but for a
    /// `group_metadata_changed`/GET-fetched metadata blob whose decrypt
    /// failed because the ACTOR's (the renaming admin's) recv chain isn't
    /// installed yet. Before this fix, a decrypt failure here was final —
    /// no retry existed for metadata specifically (only for TEXT frames),
    /// so a group discovered via `reconcileAllGroupsFromServer` (which
    /// never lived through the rename's live WS event) kept showing the
    /// placeholder/stale name forever, even once the admin's
    /// `sender_key_init` eventually arrived via normal 1:1 delivery.
    /// Keyed by groupHex — only the LATEST blob per group is worth
    /// retrying (an older version would just get re-superseded).
    private var bufferedGroupMetadata: [String: (blobB64: String, version: UInt32, selfId: String)] = [:]
    /// 2026-07-19 — closes the residual gap left by the 2026-07-17
    /// self-heal in `applyRemovalRekey`: that one only re-seals metadata
    /// the FIRST time THIS device's own crypto epoch transitions past the
    /// target (`removeMemberLocally`'s idempotent no-op guard once already
    /// caught up never fires again). If every admin's device had already
    /// caught its crypto epoch up BEFORE ever running the 2026-07-17 fix,
    /// nothing re-triggers a republish and the metadata blob stays sealed
    /// at its old epoch forever. `maybeReSealStaleGroupMetadata` detects
    /// this independently (any decrypt failure whose wire epoch is
    /// strictly behind our live epoch) and de-dupes per (group, epoch)
    /// here so the GET-recovery / WS-push / reconcile call sites — which
    /// can all observe the identical stale blob within moments of each
    /// other — don't each fire a redundant republish.
    private var attemptedEpochReseal: [String: UInt32] = [:]
    /// Fase 1B: rowIds (clientMsgId/serverMsgId) of inbound group-attachment
    /// blobs whose download+decrypt is in flight. Shared by the initial
    /// land path and the on-open retry so re-opening a group while a
    /// download is still running never starts a duplicate concurrent GET
    /// on the same blob. An entry is added before the Task starts and
    /// removed in its `defer`.
    private var groupAttachmentDownloadsInFlight: Set<String> = []
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
    /// WIRE_SPEC §8.7 — do NOT write this directly from track callbacks:
    /// publication goes through `publishRemoteVideoTrackGated` (RX render
    /// gate — parked until the receiver cryptor is ready, 2s failsafe).
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
    /// Unified call UI — Guardian ribbon voice biometrics (pitch, stress,
    /// voice health, speech rate, confidence). Fed by
    /// `CallService.onVoiceAnalysis`, itself wired from
    /// `QAudionCallIntegration.getVoiceAnalysis().onResult` on BOTH the
    /// outgoing (`CallService.startCall`) and incoming
    /// (`CallService.activateIncomingCallAudio`) integration binding sites —
    /// the old outgoing-only asymmetry (gauges dead on every incoming call)
    /// was fixed 2026-07-04. nil until the first analysis result arrives.
    /// Reset in endCall().
    @Published var voiceAnalysis: VoiceAnalysisResult?

    /// Unified call UI — REAL remote-voice spectrum: 40 log-spaced bands
    /// (0..1), the actual FFT magnitude of the decoded RX PCM computed by
    /// `SpectrumExtractor` inside `QAudionCallIntegration
    /// .processIncomingAudio` (66 ms source throttle ⇒ ≤15 Hz `@Published`
    /// writes — never a per-audio-frame publish). Drives the Guardian ribbon
    /// MiniSpectrum: no synthetic shimmer, no formant fake. nil before the
    /// first decoded frame / between calls (bars rest). Wired for BOTH
    /// outgoing and incoming calls, same as `voiceAnalysis` above.
    /// Reset in endCall().
    @Published var voiceSpectrum: [Float]?

    /// Feature B ("voce verificata") — state of the per-contact call-time
    /// voice-learning session (`VoiceLearningSession`, fed from the SAME
    /// decoded RX audio as `voiceAnalysis`/`voiceSpectrum` above via
    /// `QAudionCallIntegration.processIncomingAudio`). nil when no session
    /// has ever run this call. W-AUTOLEARN parity (item 5, 2026-07-31
    /// InCallScreen Android→iOS port): no more manual "Avvia apprendimento
    /// voce" tap — `maybeAutoStartVoiceLearning` starts this itself, silently,
    /// the first time `handleCallSessionEstablished` ever fires for a
    /// contact with no existing `VoiceprintStore` template. `InCallScreen`
    /// now only ever SHOWS state (a brief progress indicator while
    /// `.inProgress`, the live `voiceConfidenceHistory` wave otherwise) —
    /// see `InCallScreen.voiceLearningControl`. Reset in endCall(). On
    /// `.completed(contactId:)` this also writes the real "voice verified"
    /// signal via `ContactsStore.setVoiceVerified` — see the observer set up
    /// alongside `callService.onVoiceLearningStateChanged`.
    @Published var voiceLearningState: VoiceLearningSession.State?

    /// This device's OWN TX-side owner-continuity self-check state,
    /// published from `callService.onOwnerContinuityStateChanged`.
    /// `.inactive` whenever the user has no Voice-as-Key enrollment. NOT
    /// shown as its own trust-bar shield (Android doesn't either — see
    /// `InCallScreen.peerOwnerContinuityLevel`'s doc); its only consumer is
    /// `sendOwnerContinuityAnnounceIfChanged`, which announces real
    /// transitions to the peer so THEIR device can show `.mismatch` on
    /// their trust bar. Reset in endCall() alongside `voiceLearningState`.
    @Published var ownerContinuityState: OwnerContinuityMonitor.State = .inactive

    /// Last level actually sent to the peer via `OWNER_CONT` — dedup guard
    /// mirroring Android's `lastSentOwnerContinuityLevel`, so a re-fired
    /// `.onOwnerContinuityStateChanged` callback with the SAME level (e.g.
    /// another `.scored` tick that didn't cross a threshold) never re-sends.
    private var lastSentOwnerContinuityLevel: ContactVoiceContinuityGate.Level?

    /// The PEER's self-reported live continuity level, received over the
    /// `OWNER_CONT` opaque-message piggy-back — see
    /// `routeInboundCallPiggyBack`'s `.ownerContinuity` case. `.unknown`
    /// for the whole call unless the peer's device actually signals a
    /// transition (most calls never do). Drives `InCallScreen`'s merged
    /// "voce come chiave" shield alongside `callPeerVoiceKeyEnrolled`.
    /// Reset in endCall().
    @Published var peerOwnerContinuityLevel: ContactVoiceContinuityGate.Level = .unknown

    /// Tier 2 ("voce remota") — RX-side per-contact continuity level,
    /// published from `callService.onContactVoiceLevelChanged`. `.unknown`
    /// until the first real score tick for the active contact. Reset in
    /// endCall().
    @Published var contactVoiceLevel: ContactVoiceContinuityGate.Level = .unknown

    /// Item 5 (2026-07-31 InCallScreen Android→iOS port) — rolling window
    /// of RAW (un-smoothed) per-analyzed-frame Guardian confidence scores
    /// for the live wave that replaces the old manual voice-learning CTA
    /// slot (see `InCallScreen.voiceConfidenceWave`). Deliberately NOT
    /// `confidenceScore` (the alarm-only, heavily-smoothed EMA number the
    /// CONFIDENCE stat/avatar halo use — see `GuardianMode.onAlert`'s
    /// 5s-sustained-red gate — which barely moves and would read as a dead
    /// flat line): this mirrors `ConfidenceIndex.scoreHistory` directly, the
    /// same raw per-frame values Guardian already computes every ~5th audio
    /// frame internally but never surfaced to any UI before this pass.
    /// Sampled by `voiceWaveTimer` (armed/torn down alongside
    /// `cryptoMeterTimer`, same lifecycle) rather than pushed per-frame —
    /// polling a `NSLock`-protected snapshot is cheap and avoids adding a
    /// new per-frame callback across the engine boundary. Empty between
    /// calls / before the first analyzed frame — the wave then renders its
    /// neutral flat-line state, never fabricated motion.
    @Published var voiceConfidenceHistory: [Float] = []
    /// Sampler for `voiceConfidenceHistory` — same pattern as
    /// `cryptoMeterTimer` immediately below, just a faster tick (5 Hz) so
    /// the wave reads as genuinely live rather than stepping once a second.
    private var voiceWaveTimer: Timer?

    /// "Voce come chiave" (item 2, 2026-07-31 InCallScreen Android→iOS
    /// port) — in-flight fast-burst + persistent re-announce loop for our
    /// own VOICE_KEY enrollment state, armed once per call by
    /// `handleCallSessionEstablished`. See `startVoiceKeyAnnounceLoop`'s doc
    /// for the retry/persist cadence. Cancelled in `endCall()`.
    private var voiceKeyAnnounceTask: Task<Void, Never>?

    /// Unified call UI — crypto-engine meter. Live count of real AES-256-GCM
    /// frame operations per second, sampled once/sec from the ground-truth
    /// `CallService` frame counters (`framesEncryptedTx` = seal(TX),
    /// `framesDecryptedRx` = open(RX)) — one op per sealed/opened frame each
    /// direction, mirroring Android's `CryptoEngineMeter.recordOp` definition.
    /// The Guardian ribbon renders a pulsing comet whose sweep period and
    /// intensity track this rate. 0 between calls / before any frame flows,
    /// which hides the meter. Reset in `endCall()`.
    ///
    /// No byte counter exists on iOS (`CallService` tracks frame counts only),
    /// so — unlike Android — no kB/s is derived: fabricating a byte rate from
    /// an assumed frame size would be dishonest, so the meter shows ops/s only.
    @Published var cryptoOpsPerSec: Int = 0
    /// 1 Hz sampler for `cryptoOpsPerSec`. Gated to the call lifecycle: armed
    /// at each `isInCall = true` site, invalidated in `endCall()` so it never
    /// ticks between calls. Reads the `CallService` counters only — never
    /// touches the frame-counting hot path.
    private var cryptoMeterTimer: Timer?
    /// Last sampled `framesEncryptedTx + framesDecryptedRx` total, used to
    /// derive the per-second delta.
    private var cryptoMeterLastTotal: Int64 = 0

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

    /// earbud-relay-v1 — SW counterparty handshake coordinator for calls
    /// where the PEER's bonded earbud (HW firmware, CRUX SPE) owns the
    /// audio key. iOS never advertises the capability; it reacts to the
    /// peer's advertisement (call_incoming / call_answer caps) by running
    /// `EarbudHandshakeResponder` over the `EARBUDPDU:` opaque channel
    /// and installing K_counter via
    /// `QAudionCallIntegration.completeEarbudCounterparty` — from there
    /// the standard key-established wiring (SAS words, broker, sealers)
    /// takes over unchanged. Lazy so the closures can capture self.
    lazy var earbudCounterparty: EarbudCounterpartyService = {
        let svc = EarbudCounterpartyService()
        svc.sendOpaque = { [weak self] peerId, payload in
            guard let api = self?.liveProvider?.callingApi else {
                print("[AppState] earbud PDU send skipped — no live provider")
                return
            }
            try await api.sendOpaqueMessageString(recipientId: peerId, payload: payload)
        }
        svc.onSessionKey = { [weak self] callId, key in
            guard let self else { return }
            // Callee timing: the earbud handshake typically completes
            // DURING RING, before activateIncomingCallAudio binds
            // callService.callIntegration — the key must land on the
            // responder integration built at call_incoming time. Caller
            // side: callService.callIntegration is bound by startCall.
            guard let integration = self.callService.callIntegration
                    ?? self.responderCallIntegration else {
                print("[AppState] earbud K_counter ready but no call integration — dropped (call torn down?)")
                return
            }
            do {
                try integration.completeEarbudCounterparty(callId: callId, sessionKey: key)
                // Telemetry/UI parity with the Android earbud side.
                self.encryptionAlgo = "ML-KEM-1024 + X25519 (earbud SPE — CRUX)"
            } catch {
                print("[AppState] completeEarbudCounterparty failed: \(error.localizedDescription)")
            }
        }
        svc.onFailed = { callId, reason in
            // Diagnostic only — mirrors a PQC handshake timeout: the call
            // survives, audio simply has no session key (and the W461
            // fallback keeps it alive).
            print("[AppState] earbud counterparty FAILED callId=\(callId.prefix(8))…: \(reason)")
            TelemetryService.shared.emit(
                kind: "call.earbud.counterparty_failed",
                callId: callId,
                attrs: ["reason": reason]
            )
        }
        return svc
    }()
    /// CL-5.4 — earbud BLE GATT proxy for KMS hw_only/earbud_pair key relay.
    /// Shared across KMS sweeps so a single CBCentralManager instance handles all
    /// earbud connection state (avoids duplicate BLE stacks). Nil until first KMS
    /// sweep that needs it (lazy instantiation via runKmsSweep).
    lazy var earbudGattProxy: IOSEarbudGattProxy = IOSEarbudGattProxy()

    /// Persist the Bluetooth peripheral UUID of the most-recently connected
    /// earbud so the app can offer auto-reconnect on subsequent launches.
    static func rememberEarbudIdentifier(_ identifier: UUID) {
        UserDefaults.standard.set(identifier.uuidString,
                                  forKey: "qaudion_paired_earbud_uuid")
    }

    /// Phase-0 §6 — keeps a periodic KMS sweep running in the background.
    /// Started once after WS auth; stopped implicitly when AppState is freed.
    private var kmsPeriodicPoller: KmsPeriodicPoller?

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

    /// call_accepted two-flag latch (WIRE_SPEC §3.5) — set once THIS
    /// device's local handshake-completion logic (the call_answer
    /// state-advance) has run for a given callId. Whichever of {this,
    /// `callAcceptedCallId`} lands first is latched; `finalizeCallActive()`
    /// runs exactly once, on the second.
    private var localHandshakeReadyCallId: String?
    /// call_accepted two-flag latch (WIRE_SPEC §3.5) — set when
    /// `onCallAccepted` fires for a given callId (the callee's real user
    /// tapped Answer). See `localHandshakeReadyCallId`.
    private var callAcceptedCallId: String?

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
    /// Cold-start answer race — set true once the deferred incoming-call audio
    /// has actually started, so `consumeDeferredAnswerIfReady` runs exactly
    /// once. Reset in the call-reset block alongside `answeredCallKitId`.
    private var incomingAudioStarted = false
    /// W-NOCALLKIT cold-start answer race — the user tapped "Rispondi" on the
    /// local/APNs INCOMING_CALL notification BEFORE the WS `call_incoming`
    /// (which generates the call UUID) has been processed. We can't accept yet
    /// (no `activeCallKitId`); latch the intent here and `performAcceptIncoming`
    /// fires the moment `call_incoming` lands. Cleared on consume + call reset.
    private var pendingNotificationAnswer = false
    /// W-NOCALLKIT cold-start DECLINE latch — symmetric to
    /// `pendingNotificationAnswer`. User tapped "Rifiuta" on the APNs/local
    /// notification before the WS `call_incoming` arrived; the call is rejected
    /// (hangup sent, no provisioning, no ring) the moment it lands. Decline wins
    /// over a concurrently-latched answer. Cleared on consume + call reset.
    private var pendingNotificationDecline = false
    /// True once the user has explicitly answered the current incoming call via
    /// CallKit (`onAnswerCall` sets `answeredCallKitId`). The app-lock scene gate
    /// uses this to drop the biometric lock the MOMENT the call is answered —
    /// even before the PQC handshake reaches `.encrypted` — so a PushKit-woken,
    /// just-answered call surfaces the Q-Audion in-call screen (securing → SAS)
    /// instead of the lock screen. A mere ring never sets it, so the lock still
    /// holds for an unanswered incoming call (SECURITY M-25/L-7 preserved).
    var callWasAnswered: Bool { answeredCallKitId != nil }
    /// W-WAKEONLY — true once we've dismissed the native CallKit UI after answer
    /// (CallKit-for-wake-only) and the app self-manages the audio session. When
    /// set, `onAudioSessionDeactivated` re-asserts the session instead of pausing
    /// (the call is still live in-app). Reset per call. Gated by the remote flag
    /// `ios_callkit_wake_only`.
    private var selfManagedAudioSession = false
    /// In-app ringtone timer (fires every 3 s while callState == .ringing
    /// and the native CallKit UI is suppressed).
    private var ringtoneTimer: DispatchSourceTimer?

    /// FORCED-QR FIX (2026-06-24) — proactive access-token refresh.
    /// Fires at ~60% of the token TTL so the next cold-launch (and any
    /// in-flight request) never races an already-expired access token.
    /// A failed proactive refresh NEVER clears the session — it only
    /// reschedules with backoff. UserDefaults key for the persisted
    /// access-token expiry epoch (seconds) so the schedule survives a
    /// background→foreground hop or a relaunch.
    private var proactiveRefreshTimer: DispatchSourceTimer?
    /// Single-flight guard for `performProactiveRefresh` (FORCED-QR FIX
    /// 2026-06-24, MED). Both the proactive timer and `willEnterForeground`
    /// can fire near expiry; without this guard two concurrent invocations
    /// each read the SAME single-use refresh token from storage and issue
    /// independent POST /auth/refresh calls. That direct `accountApi`
    /// refresh path does NOT go through the REST client's `refreshInFlight`
    /// coalescing, so the second call is a replay of a consumed refresh
    /// token — a server enforcing refresh-reuse detection could revoke the
    /// token family and re-introduce a forced QR. Callers MUST funnel
    /// through `runProactiveRefresh()` so the second caller awaits the
    /// in-flight task instead of issuing a duplicate refresh.
    private var proactiveRefreshTask: Task<Void, Never>?
    // Swift 6 — nonisolated so the `@Sendable` device-renew fallback closure
    // (and persistAccessTokenTtl / the token-persist paths) can reference this
    // constant key without crossing main-actor isolation. It is an immutable
    // String literal, so nonisolated is safe.
    nonisolated private static let accessTokenExpiryEpochKey = "com.qaudion.auth.access_expiry_epoch"

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

    /// FORCED-QR FIX (2026-06-24) — wire the Ed25519 device-bound silent
    /// re-auth fallback onto a provider's REST client. Previously this was
    /// only done LATE inside `runKmsSweep` (after the persistent socket was
    /// up), so the cold-start launch `getProfile()` could hit a 401 with
    /// `deviceRenewFallback == nil` and surface `BCryptoError.unauthorized`
    /// even though the device credential was perfectly valid — which the
    /// launch catch then "resolved" by clearing tokens and forcing a QR
    /// re-pair. Wiring it at provider-build time means the very first
    /// network request's 401 cascade (primary /auth/refresh → Ed25519
    /// /auth/device-renew) runs in full before `.unauthorized` can surface.
    ///
    /// The primary `tokenRefresher` (POST /auth/refresh) is already wired by
    /// `BCryptoBackendProvider.init`; it only fires when the config carries a
    /// refresh token, so callers must build `pinnedConfig` with the stored
    /// refresh token for the primary leg to be attempted.
    ///
    /// Idempotent: `setDeviceRenewFallback` just overwrites the stored
    /// closure, so calling this again from `runKmsSweep` (on the live
    /// provider) is harmless.
    private func wireDeviceRenewFallback(on provider: BCryptoBackendProvider) {
        let vault = SovereignKeyVault()
        let manager = DeviceKeyManager(vault: vault, kmsClient: provider.kmsClient)
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
            // Persist the rotated tokens so the next cold-launch does not
            // replay a stale refresh token. MUST go to the Keychain
            // (TokenVault), NOT UserDefaults: `AuthService.loadToken()`
            // reads the Keychain, and `migrateTokensToKeychainIfNeeded()`
            // only sweeps UserDefaults→Keychain when the Keychain slot is
            // EMPTY — after a normal login it is populated, so a UD write
            // here would land a fresh token in plaintext UserDefaults (dead
            // + iCloud-backupable at rest) while the Keychain kept the
            // STALE token, guaranteeing a 401 cascade on the next launch.
            // TokenVault is static-only and primitive-typed, safe to call
            // from this @Sendable closure (CLAUDE.md §16). Also record the
            // access-token TTL so the proactive-refresh scheduler can renew
            // ahead of expiry.
            TokenVault.saveAccessToken(fresh.accessToken)
            TokenVault.saveRefreshToken(fresh.refreshToken)
            AppState.persistAccessTokenTtl(expiresInSec: fresh.expiresInSec)
            return (accessToken: fresh.accessToken, refreshToken: fresh.refreshToken)
        }
    }

    /// Build a backend provider for one-shot REST attachment uploads
    /// (file / image / voice-note) with BOTH token-refresh legs armed:
    /// the primary POST /auth/refresh (which fires only when the config
    /// carries the stored refresh token) AND the Ed25519 device-renew
    /// fallback (wired explicitly via `wireDeviceRenewFallback`).
    ///
    /// UPLOAD-401 FIX (2026-07-03) — `ChatVoiceNoteSender` used to build a
    /// bare `BCryptoBackendProvider(config: .pinned(serverUrl:accessToken:))`
    /// per upload: the config carried NO refresh token (so the primary
    /// leg could never fire, see `wireDeviceRenewFallback`'s doc) and
    /// `wireDeviceRenewFallback` was never called on it (so the device-
    /// renew leg was nil). With both refresh legs dead, once the access
    /// token expired mid-session EVERY attachment upload — and every
    /// retry — 401'd permanently with no self-heal: `tryRefreshToken`
    /// returned false immediately and never even reached `/auth/refresh`
    /// (confirmed in the server journal — three endpoints 401'd together
    /// at token expiry, zero refresh call). Prefers the already-wired
    /// `liveProvider` when present; otherwise builds a transient provider
    /// wired the same way `performProactiveRefresh` does, so a 401 runs
    /// the full refresh cascade + retry and the upload self-heals.
    func makeUploadProvider() -> BCryptoBackendProvider {
        if let live = liveProvider { return live }
        let cfg = pinnedConfig(
            token: authService.loadToken(),
            refreshToken: authService.loadRefreshToken(),
            userId: currentUserId
        )
        let p = BCryptoBackendProvider(config: cfg)
        wireDeviceRenewFallback(on: p)
        return p
    }

    // MARK: - Proactive token refresh (FORCED-QR FIX 2026-06-24)

    /// Format + emit a session-auth diagnostic line. Lives at top level
    /// (nonisolated static) so the formatting `+`/interpolation happens OUTSIDE
    /// any deeply-nested closure — Swift 6's type-checker times out on String
    /// concatenation built inline inside `closure → Task → do/catch` bodies
    /// (CLAUDE.md sec 16). Callers pass a pre-tag + the raw error.
    nonisolated static func logAuthDiag(_ tag: String, _ error: Error) {
        let desc: String = String(describing: error)
        let line: String = tag + desc
        print(line)
    }

    /// Persist the absolute expiry epoch (seconds since 1970) for the current
    /// access token, computed from a server-provided `expires_in`. Nonisolated
    /// + static so it can be called from the device-renew fallback closure
    /// (which is `@Sendable` and must not touch main-actor state).
    nonisolated static func persistAccessTokenTtl(expiresInSec: Int) {
        guard expiresInSec > 0 else { return }
        let expiry: Double = Date().timeIntervalSince1970 + Double(expiresInSec)
        UserDefaults.standard.set(expiry, forKey: accessTokenExpiryEpochKey)
    }

    /// Best-effort extraction of the JWT `exp` (seconds-since-epoch) from the
    /// middle (payload) segment of a compact JWS. Returns nil when the token
    /// is opaque / malformed. Used as a fallback when no `expires_in` was
    /// persisted (e.g. the access token came from a plain login, not a renew).
    private static func jwtExpiryEpoch(_ token: String) -> Double? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4 for Data(base64Encoded:).
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let exp = obj["exp"] as? Double { return exp }
        if let expInt = obj["exp"] as? Int { return Double(expInt) }
        return nil
    }

    /// Resolve the access-token expiry epoch: prefer the persisted
    /// `expires_in`-derived value, else parse the JWT `exp`.
    private func currentAccessTokenExpiryEpoch() -> Double? {
        let persisted = UserDefaults.standard.double(forKey: AppState.accessTokenExpiryEpochKey)
        if persisted > 0 { return persisted }
        if let token = authService.loadToken() {
            return AppState.jwtExpiryEpoch(token)
        }
        return nil
    }

    /// True when the access token is within the last ~20% of its TTL (or its
    /// expiry is unknown). Used on `willEnterForeground` to decide between an
    /// immediate refresh vs. just (re)arming the timer.
    private func tokenIsNearExpiry() -> Bool {
        guard authService.loadToken() != nil else { return false }
        guard let expiry = currentAccessTokenExpiryEpoch() else { return true }
        let now: Double = Date().timeIntervalSince1970
        // Within 5 minutes of expiry (or already past) ⇒ refresh now.
        return (expiry - now) <= 300
    }

    /// (Re)arm the proactive-refresh timer to fire at ~60% of the remaining
    /// TTL. If the token is already past 60% (or expiry is unknown) the
    /// refresh runs almost immediately. Safe to call repeatedly — it cancels
    /// any prior timer first.
    func scheduleProactiveTokenRefresh() {
        proactiveRefreshTimer?.cancel()
        proactiveRefreshTimer = nil
        guard authService.loadToken() != nil else { return }

        let now: Double = Date().timeIntervalSince1970
        // Default when expiry is INDETERMINATE (opaque token, no expires_in,
        // no JWT exp): use a conservative long interval, NOT a short one
        // (FORCED-QR FIX 2026-06-24, LOW). A short default caused a battery/
        // traffic-draining poll loop — every successful refresh that yielded
        // no usable expiry re-armed in 30s and refreshed again. 30 minutes is
        // safe: the on-demand 401 cascade still recovers an actually-expired
        // token immediately, so we don't need to poll aggressively here.
        var fireInSec: Double = 1800
        if let expiry = currentAccessTokenExpiryEpoch(), expiry > now {
            let ttl: Double = expiry - now
            // Fire at 60% of TTL; clamp so we neither thrash nor wait too long.
            let target: Double = ttl * 0.6
            fireInSec = min(max(target, 15), max(ttl - 30, 15))
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + fireInSec)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.runProactiveRefresh()
            }
        }
        proactiveRefreshTimer = timer
        timer.resume()
    }

    /// Single-flight entry point for the proactive refresh cascade
    /// (FORCED-QR FIX 2026-06-24, MED). If a refresh is already in flight,
    /// the caller awaits that task instead of starting a second one — this
    /// prevents the timer path and the `willEnterForeground` path from each
    /// replaying the same single-use refresh token. `@MainActor` isolation
    /// makes the check-and-set atomic (no `await` between reading and
    /// assigning `proactiveRefreshTask`), so there is no lost-update race.
    /// Awaiting the in-flight task does not deadlock: the task body runs as
    /// an independent unit of work, so a re-entrant MainActor caller simply
    /// suspends until it completes.
    func runProactiveRefresh() async {
        if let inFlight = proactiveRefreshTask {
            await inFlight.value
            return
        }
        // Strong `self` capture is intentional and safe: the task is owned by
        // `proactiveRefreshTask` (owned by self) and clears itself below, so
        // there is no retain cycle beyond the refresh's lifetime. The body is
        // a statement (not an expression) so the task is inferred as
        // `Task<Void, Never>`, matching the property type.
        let task: Task<Void, Never> = Task { @MainActor in
            await self.performProactiveRefresh()
        }
        proactiveRefreshTask = task
        await task.value
        proactiveRefreshTask = nil
    }

    /// Run the refresh cascade ahead of expiry. NEVER clears the session on
    /// failure — a failed proactive refresh just reschedules with backoff so
    /// the eventual on-demand 401 cascade (or the next launch) can recover.
    /// Do NOT call directly from concurrent contexts — go through
    /// `runProactiveRefresh()` for single-flight coalescing.
    private func performProactiveRefresh() async {
        guard authService.loadToken() != nil else { return }
        let provider: BCryptoBackendProvider
        if let live = liveProvider {
            provider = live
        } else {
            let cfg = pinnedConfig(
                token: authService.loadToken(),
                refreshToken: authService.loadRefreshToken()
            )
            let p = BCryptoBackendProvider(config: cfg)
            wireDeviceRenewFallback(on: p)
            self.liveProvider = p
            provider = p
        }

        // Leg 1: primary refresh (POST /auth/refresh) when a refresh token
        // is present.
        if let refresh = authService.loadRefreshToken(), !refresh.isEmpty {
            do {
                let pair = try await (provider.accountApi as? BCryptoAccountApiImpl)?.refreshToken(refresh)
                if let pair {
                    provider.applyTokenPair(access: pair.accessToken, refresh: pair.refreshToken)
                    authService.saveToken(pair.accessToken)
                    if let r = pair.refreshToken, !r.isEmpty { authService.saveRefreshToken(r) }
                    if let exp = pair.expiresIn {
                        AppState.persistAccessTokenTtl(expiresInSec: exp)
                    } else if let parsed = AppState.jwtExpiryEpoch(pair.accessToken) {
                        UserDefaults.standard.set(parsed, forKey: AppState.accessTokenExpiryEpochKey)
                    } else {
                        // Indeterminate expiry (opaque token, no expires_in,
                        // no JWT exp). Clear any STALE/past epoch left from a
                        // prior token so `scheduleProactiveTokenRefresh()`
                        // does not see a past value and fall into a tight
                        // refresh loop. With the key cleared the scheduler
                        // uses its conservative indeterminate-expiry interval.
                        UserDefaults.standard.removeObject(forKey: AppState.accessTokenExpiryEpochKey)
                    }
                    scheduleProactiveTokenRefresh()
                    return
                }
            } catch {
                AppState.logAuthDiag("[AppState] proactive refresh (primary) failed, trying device-renew: ", error)
            }
        }

        // Leg 2: Ed25519 device-renew.
        guard let did = UserDefaults.standard.string(forKey: "com.qaudion.auth.device_id"),
              !did.isEmpty else {
            // No device credential to renew with: do NOT clear — just back off.
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 120)
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleProactiveTokenRefresh() }
            }
            proactiveRefreshTimer = timer
            timer.resume()
            return
        }
        let vault = SovereignKeyVault()
        let manager = DeviceKeyManager(vault: vault, kmsClient: provider.kmsClient)
        let renewClient = BCryptoDeviceRenewClient(
            rest: provider.getRestClient(),
            deviceKeyManager: manager
        )
        do {
            let fresh = try await renewClient.renew(deviceId: did)
            provider.applyTokenPair(access: fresh.accessToken, refresh: fresh.refreshToken)
            authService.saveToken(fresh.accessToken)
            authService.saveRefreshToken(fresh.refreshToken)
            AppState.persistAccessTokenTtl(expiresInSec: fresh.expiresInSec)
            scheduleProactiveTokenRefresh()
        } catch {
            // Proactive renew failed — could be transient (offline). NEVER
            // clear here; the device credential may still be valid. Back off
            // and retry; an eventual hard rejection will surface via an
            // on-demand 401 cascade in getProfile().
            AppState.logAuthDiag("[AppState] proactive device-renew failed (non-fatal, keeping session): ", error)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 120)
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleProactiveTokenRefresh() }
            }
            proactiveRefreshTimer = timer
            timer.resume()
        }
    }

    func initialize() {
        // I4: materialize the presence objectWillChange forwarding before
        // anything can publish a presence update. `lazy` means touching it
        // here is a no-op on every call after the first.
        _ = presenceServiceForwarding
        // W-EARTOUCH — re-evaluate proximity monitoring on every audio route
        // change (Bluetooth/wired headset connect or disconnect mid-call),
        // not just the manual speaker toggle already covered in setSpeaker().
        // A separate, independent observer — AudioCapture's own
        // routeChangeNotification handler (engine rebuild) is unrelated and
        // untouched; multiple observers on the same notification are fine.
        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProximityMonitoring()
            }
        }
        // W-CC: warm the contacts cache immediately so incoming-call and
        // message-receive paths have fresh data without a synchronous disk
        // decode. The notification observer keeps it current across the session.
        refreshContactsCache()
        contactsCacheObserver = NotificationCenter.default.addObserver(
            forName: .contactsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter callbacks are @Sendable in iOS 18+ — hop to
            // MainActor to satisfy the @MainActor isolation of cachedContacts.
            Task { @MainActor [weak self] in
                self?.refreshContactsCache()
                // I5: a contact added mid-session (QR scan, NFC pair, phonebook
                // import) was never subscribed — this handler used to stop at
                // refreshContactsCache, so BCryptoPresenceManager's own
                // subscribed-set guard silently dropped every presence_update
                // for that userId forever (until the next app-relaunch /
                // bindPresenceAfterAuth). Re-run the same tracked-set push
                // auth uses so a fresh contact starts receiving updates too.
                self?.resubscribePresenceForTrackedContacts()
            }
        }

        // I1-RESUME — PrivacyGate.presenceVisibleToContacts turning back ON
        // does not by itself put anything on the wire: subscribe(userIds:)
        // re-checks the gate on every call, but nothing calls it again just
        // because the gate changed. Without this, a user who re-enables the
        // setting sees every contact stay grey until the next WS reconnect,
        // which on a long-lived connection could be hours. Only posted when
        // the gate turns true (see the setter), so there is nothing to do
        // here on the OFF direction — subscribe() itself already goes silent.
        presenceVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .presenceVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.forceResubscribePresence()
            }
        }

        // W-EXTRESOLVE: wire DisplayName's async fetch backstop to the live
        // provider. Primitives-only @MainActor closure (same pattern as
        // LiveLogStreamer/CarPlayBridge below) — the service never holds
        // AppState; it re-reads liveProvider on each resolve so it follows
        // socket rebuilds automatically.
        NameResolutionService.shared.configure(apiSource: { [weak self] in
            self?.liveProvider?.accountApi
        })
        // W-ORPHANPEER — same primitives-only closure pattern: the resolver
        // reports what the server said about a peer, AppState owns the set the
        // views observe.
        NameResolutionService.shared.configure(orphanSink: { [weak self] userId, outcome in
            self?.recordPeerLookupOutcome(userId, outcome)
        })

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

        // CarPlay — wire the call bridge so the in-car CarPlay scene (a separate
        // UIScene that must NOT import AppState, CLAUDE.md §16) can place
        // outgoing PQC calls. Pure closure injection, same primitives-only
        // pattern as LiveLogStreamer above. Harmless when the QAUDION_CARPLAY
        // flag is off: no CarPlay scene is ever created without the entitlement,
        // so `placeCall` simply stays unused.
        CarPlayBridge.shared.placeCall = { [weak self] peerUserId, displayName in
            guard let self = self else { return }
            Task { @MainActor in
                // Mirror dialAndCall's label handling: seed the call UI name
                // before routing keys off peerUserId.
                if !displayName.isEmpty { self.incomingCallerName = displayName }
                await self.startCall(contactId: peerUserId)
            }
        }

        // MASQUE CONNECT-UDP — register the quiche-backed transport (linked
        // only in the app target via Vendor/quiche.xcframework) and enable the
        // gated MASQUE TURN fallback. If Cquiche isn't linked, the factory
        // stays nil and the call path ignores MASQUE entirely (falls back to
        // WSS-TURN / Tor). See Transport/Masque/ in QAudionEngine.
        #if canImport(Cquiche)
        MasqueTransportFactory.register { AppMasqueQuicheTransport() }
        MasqueFeature.isEnabled = true
        #endif

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

        // W559/W561 — cross-platform bug report service. Volume-gesture
        // trigger + auto-detection hook. Primitives-only API per CLAUDE.md
        // rule #16 — `getActiveCallId`/`getDiagSnapshot` do all the
        // AppState-type-aware work here and hand BugReporter plain Strings.
        BugReporter.shared.configure(
            getToken: { [weak self] in self?.authService.loadToken() },
            getServerUrl: { [weak self] in self?.serverUrl ?? "" },
            getActiveCallId: { [weak self] in self?.activeCallIdForReport() },
            getDiagSnapshot: { [weak self] in self?.buildDiagSnapshotJSON() ?? "{}" }
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

        // W-NOCALLKIT — Answer/Decline from the INCOMING_CALL notification
        // (local, posted by call_incoming when backgrounded; or APNs alert when
        // the app was killed). Both the "Rispondi" action AND a plain tap mean
        // answer. If the WS call_incoming already arrived (activeCallKitId set),
        // accept now; otherwise latch the intent — the call_incoming handler
        // consumes pendingNotificationAnswer the moment the call lands.
        NotificationCenterService.shared.onIncomingCallAction = { [weak self] action, info in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let callId = info["call_id"]
                // W-GRPRING — the INCOMING_CALL category is SHARED with group
                // calls in CallKit-free mode (W-NOCALLKIT): the local
                // notification we post on a WS invite, and the server's APNs
                // ALERT push (`type == "incoming_group_call"`,
                // internal/push/apns.go SendAlertGroupCallInvite) for an
                // app-KILLED invitee. Route both to the group path.
                //
                // The `type` check is load-bearing on a COLD start: the app was
                // killed, so no WS `group_call_invite` was ever seen and
                // `incomingGroupCallInvite` is nil — matching on it alone would
                // fall through to the 1:1 branch below, which (activeCallKitId
                // == nil) would arm `pendingNotificationAnswer` and then
                // auto-answer the NEXT unrelated 1:1 call, while the group call
                // was never joined at all.
                if let cid = callId, self.isGroupCallNotification(callId: cid, info: info) {
                    self.handleGroupCallNotificationAction(action, callId: cid, info: info)
                    return
                }
                switch action {
                case .decline:
                    self.pendingNotificationAnswer = false
                    if let cid = callId { NotificationCenterService.shared.clearIncomingCall(callId: cid) }
                    if self.activeCallKitId != nil {
                        self.declineIncomingCall()
                    } else {
                        // Cold start: call_incoming not processed yet — latch the
                        // decline so the call is rejected the moment it lands.
                        self.pendingNotificationDecline = true
                        print("[AppState] W-NOCALLKIT decline latched (call_incoming not yet arrived)")
                    }
                case .answer:
                    if let cid = callId { NotificationCenterService.shared.clearIncomingCall(callId: cid) }
                    if self.activeCallKitId != nil {
                        self.answerIncomingCall()
                    } else {
                        // Cold start: call_incoming not processed yet — latch.
                        self.pendingNotificationAnswer = true
                        print("[AppState] W-NOCALLKIT answer latched (call_incoming not yet arrived)")
                    }
                case .open:
                    // Plain tap — bring up the in-app ring UI but do NOT answer.
                    // Warm-background case: call_incoming already arrived
                    // (activeCallKitId set) but callState stayed .idle (we were
                    // backgrounded at arrival). Surface the ring now. Cold start:
                    // activeCallKitId is nil → the incoming call_incoming will set
                    // .ringing itself (foreground at that point), nothing to do.
                    if self.activeCallKitId != nil,
                       !self.isInCall,
                       self.callState == .idle {
                        self.callState = .ringing
                        self.startInAppRingtone()
                    }
                }
            }
        }
        // W-NOCALLKIT cold-start: drain any notification action that fired before
        // this handler was wired (app-killed launch via Answer/Decline tap).
        NotificationCenterService.shared.flushPendingIncomingAction()

        // W-NOCALLKIT — receive the standard APNs device token from AppDelegate
        // and register it server-side (only when callKitFreeMode; handleApnsDeviceToken
        // gates internally). Posted by
        // application(_:didRegisterForRemoteNotificationsWithDeviceToken:).
        NotificationCenter.default.addObserver(
            forName: AppState.apnsTokenReceived,
            object: nil,
            queue: .main
        ) { note in
            guard let hex = note.object as? String else { return }
            Task { @MainActor [weak self] in
                self?.handleApnsDeviceToken(hex: hex)
            }
        }

        // W-NOCALLKIT — in CallKit-free mode the incoming-call ring depends on
        // USER notification authorization (the local INCOMING_CALL banner when
        // backgrounded + the APNs alert when killed) AND a standard APNs token.
        // VoIP push needs neither, which is why the app never requested notif
        // permission before. Request both now. Flag OFF → VoIP path unchanged
        // (we skip this so flag-OFF behavior is byte-identical to today).
        if CallsGate.callKitFreeMode {
            Task { @MainActor in
                _ = await NotificationCenterService.shared.requestAuthorization()
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
                // FORCED-QR FIX (2026-06-24): refresh the access token ahead of
                // any work on resume so a token that expired while backgrounded
                // is renewed silently (via /auth/refresh → Ed25519 device-renew)
                // instead of letting the next request 401-cascade. Never clears
                // the session on failure.
                if self.tokenIsNearExpiry() {
                    await self.runProactiveRefresh()
                } else {
                    self.scheduleProactiveTokenRefresh()
                }
                // W-PUSHHEAL: re-assert the VoIP token on every foreground so a token
                // the server cleared on a dead push (410) is re-registered the moment
                // the user opens the app — the natural recovery action, no re-login
                // needed. Best-effort; the register path already retries on failure.
                self.reassertVoipPushTokenRegistration()
                self.reassertStandardApnsTokenRegistration()  // W-NOCALLKIT (no-op when flag OFF)
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

        // W-BGK: BGAppRefreshTask handler routing.
        // QAudionApp.init() registers the BGTask with a closure that posts
        // AppState.bgWsKeepalive; we observe here so handleWsKeepaliveTask can
        // access the live auth state without a static reference to AppState.
        NotificationCenter.default.addObserver(
            forName: AppState.bgWsKeepalive,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let task = notification.object as? BGAppRefreshTask else { return }
            Task { @MainActor [weak self] in self?.handleWsKeepaliveTask(task) }
        }
        scheduleWsKeepalive()

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

        // Unified call UI — Guardian ribbon voice biometrics. Mirrors the
        // onDeepfakeScore subscription immediately above: hop to MainActor,
        // publish the result. This does NOT touch/invert deepfakeAlert —
        // it is a separate @Published field driven by a separate closure.
        callService.onVoiceAnalysis = { [weak self] result in
            Task { @MainActor in
                self?.voiceAnalysis = result
            }
        }

        // Unified call UI — REAL remote-voice spectrum (≤15 Hz, throttled at
        // the source inside QAudionCallIntegration, so this MainActor hop
        // never runs per audio frame). Same pattern as onVoiceAnalysis above.
        callService.onVoiceSpectrum = { [weak self] bands in
            Task { @MainActor in
                self?.voiceSpectrum = bands
            }
        }

        // Feature B ("voce verificata") — publish the learning-session state
        // for LiveInCallScreen's button/progress UI, and on `.completed`
        // write the real independent trust signal `ContactDetailScreen`'s
        // "Voce verificata" row reads (replacing its former mislabeled
        // duplicate of the SAS-verified boolean).
        callService.onVoiceLearningStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.voiceLearningState = state
                if case .completed(let contactId) = state {
                    ContactsStore().setVoiceVerified(userId: contactId)
                }
            }
        }

        // Tier 1/Tier 2 — fire on their own private queues (see each
        // callback's own doc), so hop to MainActor before publishing, same
        // pattern as every other cross-thread call-engine signal above.
        callService.onOwnerContinuityStateChanged = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.ownerContinuityState = state
                self.maybeAnnounceOwnerContinuity(state)
            }
        }
        callService.onContactVoiceLevelChanged = { [weak self] level in
            Task { @MainActor in
                self?.contactVoiceLevel = level
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
                    // W-GRPRING — a GROUP call reported to CallKit (push-woken /
                    // background invite) must NOT enter the 1:1 accept path:
                    // that would build a responder integration for a peer that
                    // doesn't exist. Route to the group join instead.
                    if self.groupCallKitId == uuid {
                        RTLog.info("call", "W-CALLFG-DIAG onAnswerCall uuid=\(uuid) — routing to performAcceptIncomingGroupCall (group)")
                        self.performAcceptIncomingGroupCall()
                        return
                    }
                    RTLog.info("call", "W-CALLFG-DIAG onAnswerCall uuid=\(uuid) — routing to performAcceptIncoming (1:1)")
                    // CallKit answered → run the shared accept path + dismiss the
                    // native CallKit UI. The same accept body is reused by the
                    // CallKit-FREE path (answerIncomingCall when callKitFreeMode).
                    self.performAcceptIncoming(uuid: uuid, dismissNativeUI: true)
                }
            }
            provider.onEndCall = { [weak self] uuid in
                guard let self = self else { return }
                await MainActor.run {
                    // W-GRPRING — same fork as onAnswerCall: "End" on a group
                    // call is a reject (still ringing) or a leave (joined).
                    if self.groupCallKitId == uuid {
                        self.endGroupCallFromSystemUI()
                        return
                    }
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
                    guard let self = self else { return }
                    // W-GRPVPIO-CRASH (2026-07-17) — CXProvider's didActivate:
                    // fires for the app's ONE shared AVAudioSession regardless of
                    // WHICH call (1:1 or group) CallKit is reporting — unlike
                    // onAnswerCall/onEndCall above, this callback carries no uuid
                    // to fork on. A group call owns its own audio entirely through
                    // LiveKit's SFU room (LiveKitGroupCallRoom.connect()), which
                    // configures the SAME physical VoiceProcessingIO hardware unit
                    // independently. Unconditionally starting CallService's
                    // legacy 1:1 AudioCapture/AudioProcessingPipeline here as well
                    // raced LiveKit's own engine setup and crashed both test
                    // devices (EXC_CRASH/SIGABRT in AVAudioEngineGraph::_Connect
                    // inside -[AVAudioIONode setVoiceProcessingEnabled:error:],
                    // call 3d8324ec, 2026-07-17 10:08-10:09 UTC — Apple crash
                    // portal, same crashPointId on both). `groupCallKitId` stays
                    // non-nil for the whole ring→active→end lifetime of a group
                    // call (set in reportGroupCall.../cleared only in
                    // clearGroupCallKitCall), so it's the right guard here even
                    // without a uuid to compare.
                    guard self.groupCallKitId == nil else {
                        // W-GRPSPKR (2026-07-20, call 694147de) —
                        // CallKitProvider.didActivate just forced plain
                        // `.voiceChat` (no `.defaultToSpeaker`) onto the
                        // shared session, which on iPhone routes group-call
                        // playback to the EARPIECE (iPad has no receiver —
                        // hence "iPad hears, iPhone silent" on one build).
                        // LiveKit owns the group call's audio ENGINE, but the
                        // output ROUTE is ours to keep on the loudspeaker
                        // (no-op unless currently on the receiver).
                        self.routeGroupCallAudioToSpeaker()
                        return
                    }
                    self.callService.handleAudioSessionActivated()
                    // W-CALLSPKR (2026-07-20) — same class of gap as
                    // W-GRPSPKR above, different code path: didActivate just
                    // forced plain `.voiceChat` (no `.defaultToSpeaker`) onto
                    // the shared session, same as the group-call fork. On a
                    // 1:1 call that ONLY matters if the user had already
                    // tapped the in-call speaker button — CallKit can refire
                    // didActivate mid-call (interruption-end, hold/resume,
                    // Bluetooth reactivation) without any speaker toggle from
                    // the user, silently dropping the option that keeps the
                    // route "sticky" against the proximity sensor. Re-assert
                    // via the same two-step setSpeaker(true) path (category +
                    // override) whenever the user's latched preference says
                    // speaker should be on; no-ops (harmless) if it's already
                    // correctly routed. Left OFF the fast path when
                    // `callSpeakerOn` is false so the default earpiece call
                    // start is untouched.
                    if self.callSpeakerOn {
                        self.setSpeaker(true)
                    }
                }
            }
            provider.onAudioSessionDeactivated = { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    // W-GRPVPIO-CRASH — same fork as onAudioSessionActivated:
                    // a group call's audio is LiveKit's to manage, never
                    // CallService's.
                    guard self.groupCallKitId == nil else { return }
                    if self.selfManagedAudioSession {
                        // W-WAKEONLY — CallKit released its audio-session hold
                        // after we dismissed the system UI, but the call is still
                        // live in-app. Re-assert the session so mic + speaker keep
                        // working (do NOT pause as the normal teardown would).
                        await (self.callKit as? CallKitProvider)?
                            .reactivateAudioSessionForSelfManagedCall()
                        return
                    }
                    self.callService.handleAudioSessionDeactivated()
                }
            }
            // W571 — wire up system-reset cleanup. CallKit may reset all calls
            // when another CallKit app takes over (e.g. a real phone call), on
            // app re-launch after a crash, or during suspension recovery.
            // Without this, audio engine, video capture, and WS call handlers
            // leaked across resets, causing a corrupted state on the next call.
            provider.onProviderReset = { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    RTLog.warn("call", "providerDidReset — tearing down call resources")
                    self.videoPipeline?.stop()
                    self.videoPipeline = nil
                    self.abrController?.stop()
                    self.abrController = nil
                    self.callService.handleAudioSessionDeactivated()
                    self.isInCall = false
                    self.isVideoCall = false
                    self.callState = .idle
                }
            }
        }

        // MARK: PushKit VoIP push registration
        // Registers for tokens so the day server picks option α/β/γ/δ, iOS is ready.
        // W-NOCALLKIT — when callKitFreeMode is ON, do NOT register PushKit/VoIP
        // (PushKit MANDATES a CallKit reportNewIncomingCall, which we no longer
        // want). The standard APNs *alert* path replaces it: the token is captured
        // by AppDelegate → handleApnsDeviceToken → server. Flag OFF → unchanged.
        if CallsGate.callKitFreeMode {
            print("[AppState] W-NOCALLKIT callKitFreeMode ON — PushKit/VoIP NOT registered; using APNs alert path")
        } else {
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
                // Set activeCallKitId BEFORE reporting to CallKit so a racing WS
                // `call_incoming` for the SAME call sees it already registered and
                // dedups (skips its own report) — closes the window that produced
                // the intermittent "seconda chiamata" double dialer in chiaro.
                // Resolve the caller name from the LOCAL address book (rubrica)
                // here — the push payload's caller_name is server-supplied — so
                // the native UI shows the same rubrica name the WS path resolves.
                // Body extracted to a method (CLAUDE.md §13/§14: keep the nested
                // MainActor.run closure to a single call to avoid type-checker
                // timeouts).
                let display: String = await MainActor.run {
                    self.prepareIncomingPushCall(
                        callId: payload.callId,
                        callerId: payload.callerId,
                        hasVideo: payload.hasVideo,
                        fallbackName: payload.callerName
                    )
                }
                let pkDiag: String = "[AppState] W-CALLDIAG PushKit→report uuid=\(payload.callId) hasVideo=\(payload.hasVideo) reportedHasVideo=true(forced)"
                print(pkDiag)
                // W-CALLKITVIDEOFORCE (2026-07-27, Pavel) — always report
                // hasVideo=true to CallKit regardless of the real call type.
                // iOS only auto-foregrounds the app on answer when the
                // CXCallUpdate says the call carries video (CallKit's native
                // chrome can't render video, so it must hand off); a pure
                // voice call left the user stuck on the native screen with
                // no way back except a hard swipe + manual relaunch. The
                // REAL call type (payload.hasVideo, above) still drives
                // everything that matters — isVideoCall, the offer/answer
                // negotiation, the UI the user actually sees — only what
                // CallKit itself is told is forced. Deliberate deviation
                // from Apple's documented hasVideo semantics ("indicates
                // whether the call includes video"); accepted knowingly.
                await self.callKit?.reportIncomingCall(
                    uuid: payload.callId,
                    callerName: display,
                    hasVideo: true
                )
                // CRITICAL: bring the signalling WS up NOW so the buffered
                // call_offer redelivery + PQC handshake can flow (see
                // reviveSignalingSocket). Kicked in a detached Task so PushKit's
                // completion() — already satisfied by the reportIncomingCall above —
                // fires promptly; the revive runs while the native UI rings.
                Task { @MainActor [weak self] in
                    await self?.reviveSignalingSocket()
                }
            },
            onIncomingGroupCall: { [weak self] payload in
                guard let self = self else { return }
                // W-GRPRING — incoming GROUP call while the app is closed /
                // suspended (server commit 9619df4 now fans a VoIP push out to
                // every invitee not on a fresh socket). Byte-for-byte the same
                // shape as the 1:1 branch above: report to CallKit FIRST (the
                // PushKit mandate — a VoIP push that does not report an incoming
                // call gets the app killed and future VoIP pushes throttled),
                // then revive the WS so the `group_call_join` on accept has a
                // live socket. Deduped against the WS `group_call_invite` by
                // call_id inside `presentIncomingGroupCall`.
                let prepared: (uuid: UUID, display: String, presented: Bool) = await MainActor.run {
                    self.prepareIncomingPushGroupCall(payload)
                }
                // Pre-bound single-segment locals — SWIFT6_PATTERNS rule 1 (no
                // multi-segment interpolation inside a closure).
                let grpUuid: String = String(describing: prepared.uuid)
                let grpPresented: String = String(describing: prepared.presented)
                let grpDiag: String = "[AppState] W-GRPRING PushKit→report group uuid=" + grpUuid + " presented=" + grpPresented
                print(grpDiag)
                // W-CALLKITVIDEOFORCE — same rationale as the 1:1 branch
                // above: force hasVideo=true so answering a group call at
                // screen-off auto-dismisses CallKit's native UI into the
                // app. Real call type (payload.hasVideo) still drives
                // everything else.
                await self.callKit?.reportIncomingCall(
                    uuid: prepared.uuid,
                    callerName: prepared.display,
                    hasVideo: true
                )
                guard prepared.presented else {
                    // The PushKit contract is satisfied (we reported), but there
                    // is nothing to ring for — already accepted/rejected, or we
                    // are busy in another call. End it right away rather than
                    // leaving a dead call in the system UI. Same shape as
                    // `onMalformedPush`.
                    await self.callKit?.reportCallEnded(
                        uuid: prepared.uuid, reason: .failed("group-call-not-presentable"))
                    return
                }
                // W-GRPDOUBLEDIALER (2026-07-27, live-confirmed via screenshot) —
                // `prepareIncomingPushGroupCall` above already called
                // `presentIncomingGroupCall`, which sets `incomingGroupCallInvite`
                // UNCONDITIONALLY regardless of source — so our own full-screen
                // `IncomingCallScreen` is already primed BEFORE the CallKit report
                // above even runs. If the app is already foreground (VoIP pushes
                // still deliver to a foregrounded app), iOS shows CallKit's native
                // UI as a compact TOP BANNER (not full-screen, since the app is
                // already frontmost) — visibly on top of our own screen at the same
                // time (confirmed: the banner's "<name> · 🔒 Cifrata" text is
                // exactly `CallKitProvider.reportIncomingCall`'s
                // `localizedCallerName`). The 1:1 path avoids this via
                // `registerSuppressedCall` (skips the report entirely for a
                // foreground WS call) — not available here since this is a push,
                // and the mandate to report was already satisfied above. Instead,
                // release the native UI immediately: unlike
                // `dismissNativeCallUIAfterAnswer` (which failed because the
                // device was genuinely LOCKED and iOS has no API to foreground an
                // app from there), the app is ALREADY frontmost here — nothing
                // needs foregrounding, only hiding, which `releaseFromSystemUI`
                // does safely (ends only CallKit's own administrative call
                // record; does not touch `incomingGroupCallInvite`, the ring
                // timers, or trigger `onEndCall`/`endCall()` — it's a one-way
                // notification, not a `CXEndCallAction`).
                let releasedNativeUI: Bool = await MainActor.run {
                    guard UIApplication.shared.applicationState == .active else { return false }
                    return (self.callKit as? CallKitProvider)?.releaseFromSystemUI(prepared.uuid) ?? false
                }
                if releasedNativeUI {
                    RTLog.info("call", "W-GRPDOUBLEDIALER foreground push-sourced group call — released native CallKit UI, our own IncomingCallScreen is the ring")
                }
                // CRITICAL (same as the 1:1 branch): bring the signalling WS up
                // NOW so the `group_call_join` fired on accept — and the
                // sender-key control envelopes — have a live socket.
                Task { @MainActor [weak self] in
                    await self?.reviveSignalingSocket()
                }
            },
            onMalformedPush: { [weak self] in
                guard let self = self else { return }
                // A VoIP push arrived that we cannot turn into a call (malformed /
                // non-call payload). We MUST still report a call to CallKit to
                // satisfy the PushKit contract, then end it immediately — otherwise
                // iOS terminates the app and throttles future VoIP pushes, which
                // silently makes the device unreachable for incoming calls.
                let placeholder = UUID()
                await self.callKit?.reportIncomingCall(uuid: placeholder, callerName: "Q-Audion", hasVideo: false)
                await self.callKit?.reportCallEnded(uuid: placeholder, reason: .failed("malformed-voip-push"))
            }
        )
        }  // W-NOCALLKIT — end `if !callKitFreeMode` PushKit registration guard
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
            // FORCED-QR FIX (2026-06-24): build the config WITH the stored
            // refresh token so the auto-wired primary refresher (POST
            // /auth/refresh) can actually fire on the launch getProfile()'s
            // 401, and wire the Ed25519 device-renew fallback BEFORE the call
            // so the full cascade is available. Without both, a transient
            // 401 here had no recovery path and the catch below force-cleared
            // the session → QR re-pair.
            let backendConfig = pinnedConfig(
                token: token,
                refreshToken: authService.loadRefreshToken()
            )
            let provider = BCryptoBackendProvider(config: backendConfig)
            wireDeviceRenewFallback(on: provider)
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
                    // FORCED-QR FIX (2026-06-24): the cascade inside getProfile()
                    // may have silently refreshed the access token. Persist the
                    // freshest pair so the next cold-launch starts authenticated,
                    // and schedule a proactive refresh ahead of expiry so a later
                    // launch never races an already-expired token.
                    let freshAccess: String? = provider.config.accessToken
                    let freshRefresh: String? = provider.config.refreshToken
                    if let acc = freshAccess, acc != token {
                        authService.saveToken(acc)
                        if let r = freshRefresh, !r.isEmpty { authService.saveRefreshToken(r) }
                        if let parsed = AppState.jwtExpiryEpoch(acc) {
                            UserDefaults.standard.set(parsed, forKey: AppState.accessTokenExpiryEpochKey)
                        } else {
                            // Opaque refreshed token: clear any stale epoch so
                            // the scheduler uses its conservative indeterminate
                            // interval, not a past value (FORCED-QR FIX LOW).
                            UserDefaults.standard.removeObject(forKey: AppState.accessTokenExpiryEpochKey)
                        }
                    }
                    self.scheduleProactiveTokenRefresh()
                    self.replayPendingTrackB()
                    // W74: open the long-lived WS so the server flips
                    // the user to `online`. Presence binding piggybacks
                    // on the same provider once the socket is up.
                    self.connectPersistentSocket()
                    self.bindPresenceAfterAuth()
                    // W-PUSHHEAL: re-assert UNCONDITIONALLY so a token the server
                    // cleared on a dead push (410) is re-posted on every authenticated
                    // launch — not just the first. Calls survive app-killed state.
                    self.reassertVoipPushTokenRegistration()
                    self.reassertStandardApnsTokenRegistration()  // W-NOCALLKIT (no-op when flag OFF)
                } catch {
                    // FORCED-QR FIX (2026-06-24): clear the session ONLY on a
                    // GENUINE hard auth rejection — i.e. `BCryptoError.unauthorized`,
                    // which the REST client throws ONLY after the full
                    // refresh → Ed25519 device-renew cascade itself was rejected
                    // by the server (device credential revoked/invalid). Every
                    // other error (network/offline/timeout, 5xx, decode) is
                    // TRANSIENT: keep the tokens and the device credential, keep
                    // the user authenticated against the still-valid local token,
                    // and schedule a reconnect. Bouncing to onboarding (QR
                    // re-pair) on a transient blip was the forced-QR bug.
                    if case BCryptoError.unauthorized = error {
                        let line: String = "[AppState] getProfile: device credential rejected after full refresh+device-renew cascade — clearing session, QR re-pair required"
                        print(line)
                        authService.clearToken()
                        self.isAuthenticated = false
                    } else {
                        AppState.logAuthDiag("[AppState] getProfile transient failure — keeping session, will retry: ", error)
                        // Stay authenticated if a local token is still present;
                        // the WS layer + proactive refresh will recover.
                        self.isAuthenticated = (authService.loadToken() != nil)
                        if self.isAuthenticated {
                            self.scheduleProactiveTokenRefresh()
                            self.connectPersistentSocket()
                        }
                    }
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
            // W-PUSHHEAL: re-assert UNCONDITIONALLY (see launch path).
            reassertVoipPushTokenRegistration()
            reassertStandardApnsTokenRegistration()  // W-NOCALLKIT (no-op when flag OFF)
            // 2026-07-17 — this interactive login path only ever set
            // currentUserId from the raw auth response, never fetching the
            // short PBX extension the cold-launch path (below) already
            // gets from getProfile(). Left the hero card showing the long
            // UUID after every re-login until the user happened to open
            // Settings (whose own onAppear separately fetches it).
            refreshOwnDialExtension()
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    /// 2026-07-17 — shared by both interactive login paths below: fetch our
    /// OWN profile and cache the short PBX extension the same way the
    /// cold-launch path (see `connectPersistentSocket`'s caller) already
    /// does, so the hero card shows "Int. NNN" immediately after a fresh
    /// login instead of the long UUID until Settings is opened. Best-effort
    /// — `liveProvider` is set synchronously by `connectPersistentSocket()`
    /// just above every call site, but a network failure here just leaves
    /// the UUID fallback showing, same as it did before this fix.
    @MainActor
    private func refreshOwnDialExtension() {
        guard let provider = liveProvider else { return }
        Task {
            guard let profile = try? await provider.accountApi.getProfile() else { return }
            if let ext = profile.dialExtension, ext > 0 {
                let extStr = String(ext)
                self.currentUserDialExtension = extStr
                UserDefaults.standard.set(extStr, forKey: "currentUserDialExtension")
            }
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
            // W-PUSHHEAL: re-assert UNCONDITIONALLY (see launch path).
            reassertVoipPushTokenRegistration()
            reassertStandardApnsTokenRegistration()  // W-NOCALLKIT (no-op when flag OFF)
            // 2026-07-17 — see the identical comment in `login(userId:credential:)`.
            refreshOwnDialExtension()
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    /// 2026-07-29 — SMS-OTP / extension-only registration onboarding.
    /// Persists the credentials returned by `otp/verify` or
    /// `register/extension` (Keychain + UserDefaults, exactly like
    /// `saveCredentials` in the password-based paths) and caches the
    /// assigned extension — but, UNLIKE `login`/`loginWithPhoneHash`,
    /// deliberately does NOT flip `isAuthenticated` and does NOT open the
    /// persistent socket / bind presence / reassert push tokens yet.
    ///
    /// Why: `ContentView.mainStack` switches away from `OnboardingRoot` to
    /// `HomeView` the INSTANT `isAuthenticated` flips true. The new
    /// onboarding flow has a mandatory recovery-phrase reveal step that
    /// must run AFTER a successful register but BEFORE the user lands in
    /// HomeView — flipping `isAuthenticated` immediately here would skip
    /// that step entirely (OnboardingRoot would be unmounted out from
    /// under it). Call `activatePendingSession()` once the onboarding
    /// chain (profile setup + recovery reveal) actually completes.
    ///
    /// Safe to call again for the same session (e.g. re-running this after
    /// `registerExtensionOnly`) — it's a plain overwrite, not additive.
    func completeOtpAuth(_ result: OtpAuthResult) {
        let creds = result.asAuthCredentials
        authService.saveCredentials(creds)
        currentUserId = creds.userId
        UserDefaults.standard.set(creds.userId, forKey: "currentUserId")
        if let ext = result.assignedExtension, ext > 0 {
            let extStr = String(ext)
            currentUserDialExtension = extStr
            UserDefaults.standard.set(extStr, forKey: "currentUserDialExtension")
        }
        errorMessage = nil
    }

    /// Finishes activating a session started by `completeOtpAuth(_:)` —
    /// flips `isAuthenticated` (which is what makes `ContentView` switch
    /// from `OnboardingRoot` to `HomeView`) and runs the same post-login
    /// wiring every other auth path already runs on success.
    func activatePendingSession() {
        isAuthenticated = true
        replayPendingTrackB()
        connectPersistentSocket()
        bindPresenceAfterAuth()
        reassertVoipPushTokenRegistration()
        reassertStandardApnsTokenRegistration()  // W-NOCALLKIT (no-op when flag OFF)
        refreshOwnDialExtension()
    }

    /// W70: drain `PendingGroupInviteStore` chiamando `POST /groups/:id/join`
    /// per ogni pending. Best-effort, mai blocca l'UI. Chiamato al
    /// completamento di ogni transizione auth → success.
    private func replayPendingTrackB() {
        guard let sync = TrackBSyncService.from(serverUrl: serverUrl, token: authService.loadToken()) else { return }
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
            CallSessionKeyBroker.shared.bind(
                getCallContactId: { [weak self] in self?.callContactId },
                setSessionKey: { [weak self] in self?.callPqcSessionKey = $0 },
                setPskActive: { [weak self] in self?.pskActive = $0 },
                setPskName: { [weak self] in self?.pskName = $0 },
                setPskMethod: { [weak self] in self?.pskMethod = $0 },
                setPskFingerprint: { [weak self] in self?.pskFingerprint = $0 },
                onSessionEstablished: { [weak self] peerId in self?.handleCallSessionEstablished(peerId: peerId) }
            )
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
        // W-GRPVPIO-CRASH-3 — a group call owns the VP-IO hardware unit via
        // LiveKit; every 1:1 audio-engine start must refuse to run so a
        // stray/redelivered 1:1 signaling message can't crash the process
        // (see CallService.isGroupCallActive kdoc). `groupCallKitId` is
        // non-nil for the whole ring→active→end lifetime of a group call.
        callService.isGroupCallActive = { [weak self] in
            guard let self else { return false }
            // Cover BOTH signals: `groupCallKitId` (set for the CallKit ring
            // lifetime) AND the controller being non-idle (covers
            // callKitFreeMode + the connecting window before/without a
            // CallKit id). Either being live means LiveKit owns VP-IO.
            if self.groupCallKitId != nil { return true }
            if case .idle = self.groupCallControllerState { return false }
            return true
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
        // W-KCMAC (ship step 5) — same live-getter pattern as `getCallId` above,
        // read at teardown (`CallService.teardownAudioStack`) so `psk_mix_n`/
        // `kc_mac_result`/`assurance_state`/`expected_but_missing` ride the
        // EXISTING `call.audio.diag` emission instead of a new channel. `nil`
        // when this call never fired `onKcMacReady` at all (no active call, or
        // the handshake never completed).
        callService.getKeyConfirmationTelemetry = { [weak self] in
            guard let self, let live = self.liveProvider,
                  let impl = live.callingApi as? BCryptoCallingApiImpl,
                  let cid = impl.getActiveCallId()
            else { return nil }
            return self.keyConfirmationTelemetryByCall[cid.lowercased()]
        }
        // W-DCAUDIO — route outbound voice over the WebRTC sealed-audio
        // DataChannel when it is open (P2P, lower latency, media off the
        // server). Returns false when no DC is open, so CallService falls back to
        // the WS relay. Resolves the live controller dynamically so it tracks
        // lazy per-call controller creation (the property is the gated `Any?`).
        #if canImport(WebRTC)
        callService.sendAudioOverDataChannel = { [weak self] data in
            guard let self = self, !self.audioPinnedToWsRelay,
                  let controller = self.webRtcController as? QAudionWebRtcCallController else { return false }
            return controller.sendAudioFrameData(data)
        }
        #endif
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
        // FAILOVER: the WS client signals a stalled (dead) node after enough
        // consecutive reconnects. Re-select a different trusted node and switch.
        ws.onNodeStalled = { [weak self] deadWss in
            Task { @MainActor in await self?.handleNodeStalled(deadWss) }
        }
        let cke = ContactKeyExchange(
            identity: sovereignIdentity,
            vault: SovereignKeyVault(),
            // Fix (2026-07-31, found during full-audit): this used to call
            // `ws.sendOpaqueMessage` directly with no auth-gate at all —
            // unlike the ordinary chat path (`BCryptoMessageApiImpl
            // .sendMessage`), which waits up to 5s for a live/authenticated
            // socket via `ensureAuthenticated` before sending. If the WS was
            // down (the confirmed churn window this session root-caused, or
            // any future regression of the same class), `send()` drops the
            // frame with only a `print` and no throw — so this closure's
            // `async throws` signature never actually threw, `ContactKey
            // Exchange.initiate`'s caller never saw a failure, and the
            // KEY_EXCHANGE_OFFER that starts the entire PSK/avatar chain
            // for a peer could silently vanish with zero trace and zero
            // retry. Now waits for a real connection first and throws if
            // one never arrives, so the existing retry paths this exchange
            // already has (next call, next contact scan) actually get a
            // chance to fire instead of assuming the OFFER made it out.
            sendOpaque: { [weak ws] recipientId, wire in
                guard let ws else { throw ContactKeyExchangeError.wsNotAuthenticated }
                guard await ws.ensureAuthenticated() else {
                    throw ContactKeyExchangeError.wsNotAuthenticated
                }
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
        // W-GRPSENDERKEY / W-GRPREKEY — build the group-call manager against
        // THIS session's live ws. NOTE (W-GRPSTALEMGR): this function does
        // NOT run exactly once per AppState lifetime — every socket rebuild
        // (willEnterForeground / reviveSignalingSocket sets
        // `liveProvider = nil` first) re-enters here with a fresh ws, so a
        // fresh manager is built each time and `ensureGroupCallController`
        // REBINDS the long-lived controller onto it (see that method's
        // kdoc for the zero-participant late-join bug the old
        // return-without-rebind caused). Wires the control-
        // envelope send hook (seal via the shared 1:1 ratchet, wrap in
        // `qa_grpcall_ctrl`, ship as an opaque_message) so
        // GroupCallController never needs to import BCryptoWebSocketClient.
        if let selfId = currentUserId {
            // Central name-resolution rule (see DisplayName.swift): the
            // manager's participant roster feeds the group-call tiles, so
            // inject the app-side resolver (rubrica alias → server display
            // → "Utente a1b2c3d4…") instead of the engine's minimal
            // default. Fires on the WS background thread — DisplayName.
            // forUser is nonisolated by design.
            let groupManager = BCryptoGroupCallManager(
                ws: ws,
                selfUserId: selfId,
                nameResolver: { DisplayName.forUser($0) }
            )
            let groupController = ensureGroupCallController(groupManager)
            // W-GRPSENDERKEY / regression-risk fix (2026-07-13): seal via
            // AppState's OWN shared `Self.ratchet`/`Self.sharedV4Ratchet`
            // instances — the SAME ones chat uses — rather than a separate
            // MessageRatchet instance. A prior version had GroupCallController
            // own a second instance pointed at the same Keychain-backed
            // session storage; two independent instances driven from
            // different threads could silently clobber each other's chain
            // advance for the same peer. See GroupCallController.swift's
            // "Control-envelope transport" comment.
            //
            // This closure is invoked from GroupCallController's manager
            // callbacks, which fire on the WS client's own background
            // delegate queue (BCryptoWebSocketClient uses `delegateQueue:
            // nil`, i.e. its own serial queue), NOT MainActor — while
            // `dispatchInboundOpaque`'s Path C (the receive side of this
            // same shared ratchet) runs on MainActor, same as chat's own
            // send/receive. Merely pointing both sides at the SAME
            // MessageRatchet instance removes the multi-instance clobber
            // hazard, but a genuinely different, un-actor-isolated caller
            // thread touching that instance concurrently with MainActor
            // would still be a real cross-thread race (the class's own doc
            // says the v3.1 path has no internal lock and "relies on
            // callers serializing"). `DispatchQueue.main.sync` forces this
            // send onto the SAME serial executor as every other caller of
            // `Self.ratchet`/`Self.sharedV4Ratchet`, closing that gap
            // without changing the closure's synchronous Bool-returning
            // signature (which `sendSenderKeyEnvelope` needs to gate
            // `initSentTo`). Safe: this closure is never invoked from
            // MainActor itself (confirmed via the WS delegate-queue
            // wiring), so `.sync` here cannot deadlock.
            groupController.onSendControlEnvelope = { peer, senderId, envelopeJson in
                // W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): every
                // `return false` below used to be completely silent —
                // this is the app-layer transport for sender_key_init/
                // rotate, and a failure here means the recipient NEVER
                // even sees the envelope (as opposed to seeing it and
                // rejecting it, which `onGroupCallControlEnvelope`'s own
                // new logging now covers). Root-causing whether S26<->iOS
                // failed here specifically (no pairwise 1:1 session yet)
                // was explicitly left as an unresolved residual by the
                // 2026-07-15 recon precisely because this call site had
                // no observability — this closes that gap.
                //
                // gap A2 / ADR-014a (W-GRPKMSPB) — this closure is now
                // `async` (`GroupCallController.onSendControlEnvelope`'s
                // type changed accordingly) so the KMS-prebootstrap
                // fallback below can `await` real network fetches. The
                // fast v4/v2 seal path is CPU-only + Keychain reads
                // (no network), so it stays wrapped in `await
                // MainActor.run` to preserve the original `.sync`
                // invariant: serialize with every OTHER MainActor caller
                // of `Self.ratchet`/`Self.sharedV4Ratchet` (this closure
                // itself is never invoked ON MainActor — confirmed via
                // the WS delegate-queue wiring — so hopping IN here
                // cannot deadlock the way `.sync` onto your own queue
                // would).
                enum FastPathOutcome {
                    case sealed(wire: Data, transport: String)
                    case failed
                    case noPsk
                }
                let envType = (try? JSONSerialization.jsonObject(with: Data(envelopeJson.utf8)) as? [String: Any])?["t"] as? String ?? "?"
                let msgId = UUID().uuidString
                let plaintext = Data(envelopeJson.utf8)

                let outcome: FastPathOutcome = await MainActor.run {
                    if AppState.sharedV4Ratchet.hasV4Session(peer) {
                        guard let frame = AppState.sharedV4Ratchet.encryptV4Routed(peerId: peer, plaintext: plaintext),
                              let first = frame.first, first == MessageRatchet.magicV4 else {
                            print("[GroupCallController][telemetry] ctrl envelope SEND FAILED type=\(envType) peer=\(peer.prefix(8)) reason=v4_encrypt_failed (hasV4Session=true)")
                            return .failed
                        }
                        return .sealed(wire: frame, transport: "v4")
                    } else if let pskMeta = AppState.resolveGroupCtrlPskNamed(peer: peer) {
                        // W-GRPCTRL-PARITY (2026-07-20, call FB75E465): the
                        // old fallback sealed a v3 wire under the HARDCODED
                        // session epoch 'v1' — a recipe no flag-day peer can
                        // open: Desktop's `handleGroupCtrlOpaque` and
                        // Android's `MessageCrypto.decryptV3` both parse the
                        // epoch tag FROM THE WIRE and look the PSK up BY NAME
                        // (Android's v3 open has NO contact-newest fallback
                        // at all, so an epoch of 'v1' matches nothing and the
                        // envelope dies silently). Mirror Desktop's
                        // chat-proven `encryptDispatch` recipe instead:
                        // contact-bound-newest PSK, epoch tag = the PSK NAME
                        // (minus any `call-` prefix), version-routed. iOS's
                        // `SovereignKeyVault` has no ratchet-version field
                        // and never stores call-derived `call-*` (rv>=3)
                        // names — every contact-bound PSK here is
                        // X25519/RK_0-derived, i.e. the rv=2 class Desktop
                        // seals via v2 AEAD — so this seals a v2 (0xE2) wire
                        // under the channel AAD
                        // `grpcall-ctrl:<sender>:<recipient>` (the AAD
                        // Android's `onOpaqueMessage` and Desktop's v2 open
                        // branch verify). The rv>=3 v3-ratchet branch Desktop
                        // has is structurally unreachable on iOS: a v3-class
                        // pairing here is exactly a v4-session pairing,
                        // already handled above.
                        let epochTag = pskMeta.name.hasPrefix("call-")
                            ? String(pskMeta.name.dropFirst("call-".count))
                            : pskMeta.name
                        let aad = Data("grpcall-ctrl:\(senderId):\(peer)".utf8)
                        do {
                            let wire = try MessageCryptoV2.seal(
                                plaintext: plaintext, psk: pskMeta.psk, epochTag: epochTag, aad: aad)
                            return .sealed(wire: wire, transport: "v2:\(epochTag.prefix(16))")
                        } catch {
                            print("[GroupCallController][telemetry] ctrl envelope SEND FAILED type=\(envType) peer=\(peer.prefix(8)) reason=v2_encrypt_failed epoch=\(epochTag.prefix(16)): \(error)")
                            return .failed
                        }
                    } else {
                        return .noPsk
                    }
                }

                switch outcome {
                case .failed:
                    return false
                case .sealed(let wire, let transport):
                    let wrapper: [String: Any] = [
                        "qa_grpcall_ctrl": 1,
                        "cmid": msgId,
                        "blob": wire.base64EncodedString()
                    ]
                    guard let data = try? JSONSerialization.data(withJSONObject: wrapper),
                          let wrapperJson = String(data: data, encoding: .utf8) else {
                        print("[GroupCallController][telemetry] ctrl envelope SEND FAILED type=\(envType) peer=\(peer.prefix(8)) reason=wrapper_json_encode_failed")
                        return false
                    }
                    // W-GRPCTRL-TRANSPORT (2026-07-19, call 60aca70c) — MUST
                    // ship the wrapper as the RAW UTF-8 JSON string in `data`.
                    // `sendOpaqueMessage(payload: Data)` base64-wraps, which
                    // NO receiver of this channel parses: Android's
                    // `onOpaqueMessage` and our own `dispatchInboundOpaque`
                    // Path C both JSON-parse `data` verbatim (Desktop now
                    // does too). The old base64 wrap made every iOS ctrl
                    // envelope silently undecodable on all three platforms.
                    ws.sendOpaqueMessageString(recipientId: peer, payload: wrapperJson)
                    print("[GroupCallController][telemetry] ctrl envelope SENT type=\(envType) peer=\(peer.prefix(8)) cmid=\(msgId.prefix(8)) transport=\(transport)")
                    return true
                case .noPsk:
                    // GAP A2 — no pairwise v4/v1 session yet: attempt the
                    // KMS-prebootstrap fallback (REAL now, not a documented
                    // no-op — mirrors Android's ADR-014a bootstrap-off-
                    // published-bundle path). Real network round-trip
                    // (bundle + prekey fetch), which is exactly why this
                    // whole closure had to become `async`.
                    if let wrapped = await AppState.attemptGroupCtrlKmsPreBootstrap(
                        peer: peer, selfId: senderId, envelopeJson: envelopeJson, kmsClient: provider.kmsClient
                    ) {
                        // W-GRPCTRL-TRANSPORT — raw JSON string, NOT base64:
                        // Android's qa_kms branch / Desktop's Path-D mirror
                        // parse `data` verbatim. See the qa_grpcall_ctrl send
                        // above for the full rationale.
                        ws.sendOpaqueMessageString(recipientId: peer, payload: wrapped)
                        print("[GroupCallController][telemetry] ctrl envelope SENT type=\(envType) peer=\(peer.prefix(8)) transport=kms_prebootstrap")
                        return true
                    }
                    print("[GroupCallController][telemetry] ctrl envelope SEND FAILED type=\(envType) peer=\(peer.prefix(8)) reason=no_v4_session_and_no_psk_and_prebootstrap_failed (pairwise 1:1 relationship never established)")
                    return false
                }
            }
            groupManager.onIncomingInvite = { [weak self] invite in
                DispatchQueue.main.async {
                    // W-GRPRING — RING, do not join. The previous code called
                    // `groupCallController.join(callId:)` right here: the callee
                    // was silently dropped into the call with no ringtone and no
                    // accept/reject. Accept now goes through
                    // `answerIncomingGroupCall()` → the SAME `join(callId:)`
                    // (still the single source of truth for the WS join + the
                    // GroupSession crypto bootstrap).
                    self?.presentIncomingGroupCall(
                        AppState.IncomingGroupCallInvite(
                            callId: invite.callId,
                            creatorId: invite.creatorId,
                            creatorName: invite.creatorName,
                            callType: invite.callType,
                            groupId: invite.groupId,
                            groupName: invite.groupName),
                        source: .webSocket)
                }
            }
            groupController.onStateChange = { [weak self] s in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.groupCallControllerState = s
                    // W-GRPSPKR — the group-call surface is hands-free: route
                    // playback to the loudspeaker if the session default left
                    // it on the iPhone earpiece (no-op on iPad/BT/wired — see
                    // routeGroupCallAudioToSpeaker's kdoc).
                    if case .active = s { self.routeGroupCallAudioToSpeaker() }
                    // W-GRPRING — the group call is over (left / ended / never
                    // started): clear the CallKit call we reported for it, else
                    // the system call UI would stay up forever.
                    if s == .idle {
                        self.clearGroupCallKitCall(reason: .remoteEnded)
                        // W-GRPSPKR — drop the loudspeaker lock so the NEXT
                        // (1:1) call starts on the earpiece as always —
                        // mirrors endCall()'s identical reset.
                        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
                    }
                }
            }
            // W-GRPSPKR — re-assert the speaker route as each remote audio
            // track subscribes: LiveKit's engine start (and a late CallKit
            // didActivate) reconfigures the shared AVAudioSession AFTER the
            // `.active` hook above ran, silently dropping the override back
            // to the earpiece. This closure slot was previously unbound
            // (LiveKit plays remote audio itself; nothing else consumes it)
            // and the routine no-ops unless the current output route is the
            // built-in receiver, so re-firing per track is safe.
            groupController.onRemoteAudioTrack = { [weak self] _, _ in
                DispatchQueue.main.async { self?.routeGroupCallAudioToSpeaker() }
            }
            self.groupCallManager = groupManager
            self.groupCallViewModel = GroupCallViewModel(manager: groupManager, controller: groupController)
            // W-GRPRING cold start: the user accepted a push-woken group call
            // before this socket (and therefore the controller) existed. The
            // accept was latched — consume it now that `join(callId:)` can
            // actually reach a live WS. Mirrors `pendingNotificationAnswer`.
            if let pendingJoin = self.pendingGroupCallJoinId {
                self.pendingGroupCallJoinId = nil
                let pendingVideo = self.pendingGroupCallJoinVideo
                self.pendingGroupCallJoinVideo = false
                let pendingGroupId = self.pendingGroupCallJoinGroupId
                self.pendingGroupCallJoinGroupId = ""
                print("[AppState] W-GRPRING consuming latched group-call join \(pendingJoin.prefix(8))…")
                // In-call chat panel — bind before join so the panel's
                // group binding is ready the moment the call surfaces
                // (mirrors the non-cold-start bind order below).
                self.groupCallViewModel?.bindGroupId(pendingGroupId)
                groupController.join(callId: pendingJoin, video: pendingVideo)
                self.armGroupCallJoinTimeout(callId: pendingJoin)
            }
        }
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
                    var attrs: [String: Any] = [
                        "state": String(describing: state),
                        "prev":  String(describing: prev ?? .disconnected)
                    ]
                    // W-WSREASON: the previous "why did it drop" signal was
                    // discarded at the lowest level (bare `case .failure:`
                    // in BCryptoWebSocketClient.receiveLoop) — ws.state
                    // telemetry could show THAT it flapped but never WHY.
                    if state == .disconnected,
                       let reason = provider.persistentConnection.lastDisconnectReason {
                        attrs["reason"] = reason
                    }
                    TelemetryService.shared.emit(kind: "ws.state", attrs: attrs)
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
                    // W-GRPREJOIN (2026-07-20, call FB75E465): a socket that
                    // just (re-)authenticated mid-group-call means the OLD
                    // WS died — the server reaps ghost participants from the
                    // roster after the grace window (commit 5a3b2e1), so
                    // without an explicit re-join this device stays stranded
                    // alone in the call UI (exactly what happened to the
                    // iPhone creator in FB75E465). The server allows rejoin
                    // for invited/former participants. Gated on the
                    // transition INTO .authenticated (once per reconnect)
                    // and, inside `rejoinAfterReconnect`, on the controller
                    // actually being in a call — a no-op on every ordinary
                    // login/first-connect. Sends must not fire before
                    // .authenticated: `BCryptoWebSocketClient.send` DROPS
                    // frames while the task is nil, which is why this lives
                    // here and not next to the `ensureGroupCallController`
                    // rebind (which runs before the socket even dials).
                    if prev != .authenticated {
                        self?.groupCallController?.rejoinAfterReconnect()
                    }
                }
            }
        }
        Task { [weak self] in
            // Clearnet-FIRST (design doc §6): the normal direct WSS dial is the
            // default for the 99% of users on an open network. ONLY the explicit
            // manual force flag (tester / known-censored network) brings Reality
            // up before trying clearnet; the automatic path instead waits for a
            // hard clearnet failure (handleNodeStalled → no reachable node).
            if AppState.forceRealityEnabled {
                print("[AppState] force-Reality enabled — bringing up tunnel before clearnet dial")
                await self?.activateRealityFallback(reason: "manual-force-at-connect")
                return
            }
            do {
                try await provider.initialize()
                print("[AppState] persistent WS opened (online presence active)")
            } catch {
                print("[AppState] persistent WS open failed: \(error.localizedDescription)")
            }
        }
    }

    /// W-ONESOCKET: return the persistent `liveProvider`, establishing it if
    /// absent, so EVERY WebSocket operation rides the SINGLE long-lived socket
    /// instead of a throwaway one. Replaces the old "spin up a fresh provider
    /// + `initialize()`" fallbacks that opened a second `/ws` per message /
    /// presence op — the server logged "replacing stale ws device", churned
    /// the per-(user,deviceID) slot, and the dropped zombie re-POSTed the
    /// apns-voip-token. Returns nil only when unauthenticated; otherwise
    /// best-effort awaits authentication up to `timeoutSec` (the caller still
    /// proceeds best-effort — `send()` self-heals a stale socket).
    func ensurePersistentProviderConnected(timeoutSec: Double = 5) async -> BCryptoBackendProvider? {
        if liveProvider == nil {
            guard authService.loadToken()?.isEmpty == false else { return nil }
            connectPersistentSocket()   // idempotent; sets self.liveProvider synchronously
        }
        guard let live = liveProvider else { return nil }
        _ = await live.persistentConnection.ensureAuthenticated(timeoutSec: timeoutSec)
        return live
    }

    /// W75: re-attempt the PushKit registration after auth-success.
    /// Called from the 3 auth-success entry points so the cached token
    /// (deferred while unauthenticated) lands the moment we have a JWT.
    private func retryPendingVoipPushTokenRegistration() {
        guard let hex = pendingVoipPushTokenHex else { return }
        registerVoipPushToken(hex: hex)
    }

    /// W-PUSHHEAL: UNCONDITIONALLY re-post the last-known VoIP token. Unlike
    /// `retryPendingVoipPushTokenRegistration()` this is NOT gated on
    /// `pendingVoipPushTokenHex` (wiped on first success, lost on restart): it reads
    /// the persisted token so a server-side clear (dead-push 410) is healed at the
    /// next login or foreground. No-op until PushKit has delivered a token once.
    private func reassertVoipPushTokenRegistration() {
        let stored = UserDefaults.standard.string(forKey: AppState.lastKnownVoipTokenKey)
        guard let hex = pendingVoipPushTokenHex ?? stored else { return }
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
        // W-PUSHHEAL: persist the freshest valid token so it can be re-asserted on
        // the next login/foreground even after success clears the cache or the
        // process restarts. C-10: never log the token; UserDefaults is local.
        UserDefaults.standard.set(hex, forKey: AppState.lastKnownVoipTokenKey)
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
        // W-PUSHDEDUP: collapse the burst of identical registrations that the
        // launch/foreground/PushKit triggers fire within a second or two.
        if voipRegisterInFlightHex == hex {
            print("[AppState] PushKit register skipped — same token already in flight")
            return
        }
        if lastVoipRegisteredHex == hex, let at = lastVoipRegisteredAt,
           Date().timeIntervalSince(at) < AppState.voipRegisterCoalesceWindowSec {
            print("[AppState] PushKit register skipped — same token registered \(Int(Date().timeIntervalSince(at)))s ago (<\(Int(AppState.voipRegisterCoalesceWindowSec))s)")
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
        // W-PUSHDEDUP: mark in flight only now that the POST is actually
        // about to fire (all synchronous guards passed). Cleared on every
        // terminal outcome below so a later genuine re-assert isn't blocked.
        voipRegisterInFlightHex = hex
        // SECURITY C-6 — cert-pinned session for push token registration.
        // Capture the lazy session once; avoids per-call URLSession allocation.
        let session = voipPushSession
        Task { [weak self, hex, session] in
            do {
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse {
                    if (200..<300).contains(http.statusCode) {
                        // C-10: token registered OK — do NOT log any
                        // portion of the token material.
                        await MainActor.run {
                            // W-PUSHDEDUP: stamp the confirmed registration so
                            // the coalesce window suppresses the sibling burst,
                            // and release the in-flight latch.
                            self?.lastVoipRegisteredHex = hex
                            self?.lastVoipRegisteredAt = Date()
                            if self?.voipRegisterInFlightHex == hex {
                                self?.voipRegisterInFlightHex = nil
                            }
                            // Only clear if cache still holds THIS token.
                            // If a second PushKit emit raced ahead the
                            // cache holds the new hex — must NOT wipe it.
                            if self?.pendingVoipPushTokenHex == hex {
                                self?.pendingVoipPushTokenHex = nil
                            }
                        }
                    } else {
                        print("[AppState] PushKit register HTTP \(http.statusCode)")
                        // Failure: release the in-flight latch so the retry
                        // can re-POST. Cache stays —
                        // `retryPendingVoipPushTokenRegistration()` fires next
                        // foreground/auth event.
                        await MainActor.run {
                            if self?.voipRegisterInFlightHex == hex { self?.voipRegisterInFlightHex = nil }
                        }
                        await Self.scheduleRetry(self: self)
                    }
                } else {
                    // Non-HTTP response (shouldn't happen) — release the latch.
                    await MainActor.run {
                        if self?.voipRegisterInFlightHex == hex { self?.voipRegisterInFlightHex = nil }
                    }
                }
            } catch {
                print("[AppState] PushKit register error: \(error.localizedDescription)")
                await MainActor.run {
                    if self?.voipRegisterInFlightHex == hex { self?.voipRegisterInFlightHex = nil }
                }
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

    // MARK: - W-NOCALLKIT: standard APNs (alert) token for CallKit-free calls

    /// Public entry — invoked when AppDelegate receives the standard APNs device
    /// token. ADDITIVE: only ships the token to the server when
    /// `CallsGate.callKitFreeMode` is ON, so flag-OFF behavior is byte-identical
    /// to today (VoIP/CallKit path untouched; the token is simply ignored).
    func handleApnsDeviceToken(hex: String) {
        guard CallsGate.callKitFreeMode else {
            // Flag OFF — VoIP/PushKit owns incoming-call wakeups. Ignore.
            return
        }
        registerStandardApnsToken(hex: hex)
    }

    /// W-NOCALLKIT: re-assert the last-known standard APNs token (login /
    /// foreground), so a server-side clear (dead push 410) heals. No-op when the
    /// flag is OFF or no token has ever been delivered.
    private func reassertStandardApnsTokenRegistration() {
        guard CallsGate.callKitFreeMode else { return }
        let stored = UserDefaults.standard.string(forKey: AppState.lastKnownApnsTokenKey)
        guard let hex = pendingApnsTokenHex ?? stored else { return }
        registerStandardApnsToken(hex: hex)
    }

    /// W-NOCALLKIT: ship the standard APNs (alert) device token to the server so
    /// the dispatcher can send an INCOMING_CALL *alert* push (push-type=alert,
    /// interruption-level=time-sensitive, category INCOMING_CALL) when the app is
    /// killed and `callKitFreeMode` is ON. Mirrors `registerVoipPushToken`.
    /// Server endpoint (Phase 3): `POST /api/v1/account/apns-token` with body
    /// `{apns_token: "<64 hex>", bundle_id: "com.qaudion.app"}`.
    private func registerStandardApnsToken(hex: String) {
        guard hex.count == 64,
              hex.allSatisfy({ $0.isHexDigit }) else {
            print("[AppState] APNs token invalid (len=\(hex.count))")
            return
        }
        UserDefaults.standard.set(hex, forKey: AppState.lastKnownApnsTokenKey)
        pendingApnsTokenHex = hex
        guard let token = authService.loadToken(), !token.isEmpty else {
            print("[AppState] APNs register deferred — not authenticated yet (cached for retry)")
            return
        }
        guard var components = URLComponents(string: serverUrl) else { return }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/api/v1/account/apns-token"
        guard let url = components.url else { return }

        let bundleId = Bundle.main.bundleIdentifier ?? "com.qaudion.app"
        let body: [String: Any] = [
            "apns_token": hex,
            "bundle_id": bundleId,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        let session = voipPushSession
        Task { [weak self, hex, session] in
            do {
                let (_, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    await MainActor.run {
                        if self?.pendingApnsTokenHex == hex { self?.pendingApnsTokenHex = nil }
                    }
                } else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    print("[AppState] APNs register HTTP \(code)")
                }
            } catch {
                print("[AppState] APNs register error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - W-BGK: Background WS keepalive

    /// Schedule the next BGAppRefreshTask. Called on launch and at the end of
    /// each BGTask run so the chain is self-sustaining. iOS picks the actual
    /// fire time; the `earliestBeginDate` sets a lower bound only — the system
    /// may defer up to ~15 min based on power / usage patterns.
    func scheduleWsKeepalive() {
        guard PrivacyGate.autoStartEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: "com.bcrypto.qaudion.ws-keepalive")
        // Ask iOS to fire within the next 5 minutes; system may delay further.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// BGAppRefreshTask handler. Ensures the WS is authenticated (reconnects if
    /// stale), completes the task, and schedules the next run. The iOS budget
    /// for a BGAppRefreshTask is ~30 s of CPU — ensureAuthenticated is capped
    /// at 10 s to stay safely within it.
    private func handleWsKeepaliveTask(_ task: BGAppRefreshTask) {
        // Schedule the next run first — if this handler crashes or expires,
        // the chain is already queued for next time.
        scheduleWsKeepalive()

        task.expirationHandler = { task.setTaskCompleted(success: false) }

        Task { @MainActor [weak self] in
            guard let self, self.isAuthenticated, let live = self.liveProvider else {
                task.setTaskCompleted(success: false)
                return
            }
            let ok = await live.persistentConnection.ensureAuthenticated(timeoutSec: 10)
            task.setTaskCompleted(success: ok)
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
            // ROOT-CAUSE FIX (2026-07-12, MetricKit-confirmed heap corruption):
            // this handler is invoked on the URLSession delegate BACKGROUND thread
            // (BCryptoWebSocketClient builds its session with delegateQueue:nil and
            // calls handler?() with no dispatch). AppState is a @MainActor
            // ObservableObject, and the body below writes @Published properties
            // (callIdentityUnauthenticatedChange / remoteVideoPaused /
            // localVideoPaused / pendingPeerCapabilities) and the
            // senderDeviceIdByPeer dictionary. Doing that off-main synchronously
            // fired the synthesized ObservableObjectPublisher.objectWillChange into
            // a live main-thread SwiftUI subscription → unsynchronised mutation of
            // Combine's internal subscriber list from two threads → over-release /
            // use-after-free of subscription objects. The corrupted publisher then
            // detonated at whatever ran next (EXC_CRASH/SIGTRAP at innocent sites —
            // e.g. a SwiftUI/CoreAnimation render, or the drainPendingOfferReplays
            // CoW-dictionary read). Hop the ENTIRE handler onto the main queue so
            // every AppState access is correctly main-isolated. FIFO
            // (DispatchQueue.main.async) preserves the incoming-call ordering the
            // dedup guards below rely on; the inner main hop further down is now a
            // harmless redundant hop.
            DispatchQueue.main.async {
            guard let self = self else { return }
            let callIdStr = data["call_id"] as? String ?? ""
            let senderId = data["sender_id"] as? String ?? "Sconosciuto"
            // C-4: drop calls from blocked contacts BEFORE any CallKit
            // report, responder-integration provisioning, or PQC setup.
            // A blocked caller must not be able to ring the device or
            // trigger key-exchange side effects.
            if BlockedContactsStore.isBlocked(senderId) { return }
            // D11: stash the server-stamped `sender_device_id` keyed by sender so
            // the later OFFER/ACCEPT (which arrive over `opaque_message` WITHOUT a
            // device id — the server relays only `sender_id` there) can verify
            // per-(peer, device). Absent ⇒ nil ⇒ legacy single-key + set
            // membership (never a fatal mismatch). Server-authoritative, sourced
            // from the caller's JWT `did` (server client.go), NOT client payload.
            if let sdid = (data["sender_device_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !sdid.isEmpty {
                self.senderDeviceIdByPeer[senderId] = sdid
            }
            // D11: a fresh incoming call clears any stale unauthenticated-change
            // banner from a previous call.
            self.callIdentityUnauthenticatedChange = false
            // W-ASSURANCE: same reset — a fresh incoming call must not show a
            // stale live-assurance verdict from a previous call.
            self.callAssuranceState = nil
            self.callAssuranceExpectedNfc = false
            self.callMutualNfcInCommon = false
            self.callPskMixedThisCall = false
            self.callPeerVoiceKeyEnrolled = false
            // WIRE_SPEC §8.1: a fresh incoming call clears any stale
            // "peer paused their camera" state from a previous call.
            self.remoteVideoPaused = false
            self.localVideoPaused = false
            // #2 (server-fetch trust source): warm the caller's server identity
            // key now, BEFORE handleIncomingWebRtcOffer runs the §5c verify, so
            // resolveServerPeerKey can cross-check the OFFER's signer key. Race
            // loser (verify before fetch lands) → cache miss → bundle-TOFU.
            self.prefetchServerPeerKey(senderId)
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
            // W-CALLBOOK (2026-07-29) — mark this peer as call-linked so the
            // rubrica auto-save/device-contact-enrichment path (
            // NameResolutionService.enrichFromCallProfile) is allowed to run
            // for them; also hands along the already-sanitised wire value as
            // a second phone-number signal. Synchronous, in-memory only —
            // same safety class as the cachedContacts read right below.
            NameResolutionService.markCallLinkedPeer(senderId, callerDisplay: wireCallerDisplay)
            // W-EXTPREFIX consolidation (2026-07-29): this used to be an
            // independent copy of the resolution chain (its own
            // `allSatisfy(isNumber)` check, its own "Int. " prefix, no
            // placeholder-awareness for `wireCallerDisplay` itself) — now a
            // single call into the canonical `DisplayName.forUser`, so the
            // banner, CallKit UI, and call history all resolve through the
            // SAME chain instead of three independently-formatted copies.
            // Priority note: this now puts the rubrica ahead of the wire
            // value (forUser's documented order), where before the wire
            // value won outright — deliberate, matching every other
            // consolidated call site; see canonicalFunctionLocation notes.
            let resolvedCallerName: String = DisplayName.forUser(
                senderId,
                serverDisplay: wireCallerDisplay,
                contacts: self.cachedContacts
            )
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
            // earbud-relay-v1 — the caller's audio key lives in its
            // earbud FIRMWARE: no SW PQC OFFER will ever arrive. Start
            // the counterparty handshake (HSINIT) IMMEDIATELY: the
            // earbud-side phone buffers early PDUs (replay=8) while it
            // brings up the BLE leg, and Android peers expect HSINIT
            // "well before" their j1 subscriber is alive.
            if CallCapabilities.peerAdvertisedEarbudRelay(self.pendingPeerCapabilities),
               !callIdStr.isEmpty {
                let earbudCallId = callIdStr
                let earbudPeer = senderId
                Task { @MainActor [weak self] in
                    self?.earbudCounterparty.start(callId: earbudCallId, peerId: earbudPeer)
                }
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
                // W-NOCALLKIT cold-start DECLINE: the user already tapped "Rifiuta"
                // on the notification before this call_incoming landed. Reject the
                // call NOW — send hangup, skip ALL provisioning (no integration, no
                // ring, no state change). The incoming call_id is already bound
                // (bindIncomingCallId above) so the hangup targets the right call.
                if CallsGate.callKitFreeMode && self.pendingNotificationDecline {
                    self.pendingNotificationDecline = false
                    self.pendingNotificationAnswer = false
                    if let provider = self.liveProvider {
                        let peer = senderId
                        Task { try? await provider.callingApi.sendHangup(recipientId: peer) }
                    }
                    NotificationCenterService.shared.clearIncomingCall(callId: callIdStr)
                    print("[AppState] W-NOCALLKIT cold-start decline consumed — call rejected before provisioning")
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
                    let wsDiagVideo: Bool = (callType == "video")
                    let wsDiag: String = "[AppState] W-CALLDIAG WS path uuid=\(callUUID) hasVideo=\(wsDiagVideo) pushKitFirst=\(alreadyRegisteredByPushKit) foreground=\(appForeground)"
                    print(wsDiag)
                    let useCustomUI = CallsGate.callKitFreeMode
                    if !alreadyRegisteredByPushKit {
                        if useCustomUI {
                            // W-NOCALLKIT — never touch CallKit. Foreground → the
                            // in-app banner (callState=.ringing set below) is the
                            // ring UI. Not foreground (app alive in background) →
                            // post a local INCOMING_CALL notification with
                            // Answer/Decline; tapping Answer opens the app → banner.
                            if !appForeground {
                                await NotificationCenterService.shared.postIncomingCall(
                                    callId: callIdStr,
                                    peerId: senderId,
                                    callerName: resolvedCallerName,
                                    hasVideo: wsDiagVideo
                                )
                            }
                        } else if appForeground {
                            await MainActor.run {
                                (self.callKit as? CallKitProvider)?.registerSuppressedCall(callUUID)
                            }
                        } else if let ck = self.callKit {
                            // W-CALLKITVIDEOFORCE — see the PushKit branch's
                            // kdoc above for the full rationale. Real call
                            // type (wsDiagVideo) still drives isVideoCall /
                            // the actual offer below; only CallKit's own
                            // hasVideo is forced so answering always
                            // auto-dismisses the native UI into the app.
                            await ck.reportIncomingCall(
                                uuid: callUUID,
                                callerName: resolvedCallerName,
                                hasVideo: true
                            )
                        }
                    }
                    await MainActor.run {
                        if self.activeCallKitId == nil { self.activeCallKitId = callUUID }
                        self.callContactId = senderId
                        self.drainPendingOfferReplays(for: senderId)  // W-OFFERBUFFER
                        // WIRE_SPEC §8.3 — we answered → polite on any later glare.
                        self.originalCallRole = .callee
                        self.incomingCallerName = resolvedCallerName
                        self.isVideoCall = (callType == "video")
                        // W-1TO1RING — set unconditionally, same as the group-call
                        // invite: this is what makes IncomingCallScreen appear the
                        // instant the app can draw, independent of whether CallKit
                        // also owns the ring (see ContentView's fullScreenCover).
                        self.incomingCallRingVisible = true
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
                        // W-NOCALLKIT cold-start: the user already tapped
                        // "Rispondi" on the notification before this call_incoming
                        // landed. activeCallKitId is now set → consume the latched
                        // intent and accept. Guarded by callKitFreeMode so the
                        // CallKit path is untouched.
                        if useCustomUI && self.pendingNotificationAnswer {
                            self.pendingNotificationAnswer = false
                            self.stopInAppRingtone()
                            self.performAcceptIncoming(uuid: callUUID, dismissNativeUI: false)
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
                        // W-VIDDIAG: log the inbound SDP presence — the decisive
                        // signal for whether iOS builds a WebRTC controller for
                        // this peer (empty ⇒ iOS↔iOS PQC/relay; non-empty ⇒
                        // WebRTC peer = Android/Desktop). Used to diagnose the
                        // iOS↔Android one-way video (controller-nil → WS relay).
                        let inSdpLen: Int = (data["sdp"] as? String)?.count ?? -1
                        let inCaps: [String] = (data["capabilities"] as? [String]) ?? []
                        let from8: String = String(senderId.prefix(8))
                        // W-NOCALLKIT review B1: drop the `+` operator (overload
                        // resolution risk inside this deep closure, CLAUDE.md §16)
                        // — single-segment interpolation only. The W-NOCALLKIT
                        // additions enlarged this closure, so de-risk it.
                        let viddiagLine: String = "[AppState] W-VIDDIAG call_incoming: sdpLen=\(inSdpLen) caps=\(inCaps) from=\(from8)"
                        print(viddiagLine)
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
                        // Cold-start answer race — the responder integration +
                        // callContactId are now set (engine was ready since init).
                        // If the user already answered the PushKit-woken call
                        // during the WS-reconnect gap, start its audio now rather
                        // than letting the latched answer expire.
                        self.consumeDeferredAnswerIfReady("ws-call-incoming")
                    }
                }
            }
            } // end DispatchQueue.main.async — root-cause main hop (see top of handler)
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

        // call_missed (recipient side) — the server sends this to a device that
        // was ALREADY in an answered call when a NEW caller dialled it. Because
        // this device is busy, no `call_incoming` is delivered for that new call
        // at all, so nothing rings and no history record is created. Surface a
        // "missed call" reminder WITHOUT touching the currently-active call:
        // record a `.missed` entry in the call history and post a passive
        // local `missedCall` notification. Wire payload (server-authoritative):
        // {call_id, caller_id, caller_display, call_type, ts_ms}. The
        // display-name resolution mirrors the `call_incoming` handler above
        // (sanitise the attacker-controlled wire display, then the SAME
        // canonical `DisplayName.forUser` chain — never a raw UUID, never a
        // stale placeholder shown verbatim).
        ws.registerHandler(type: "call_missed") { [weak self] _, data in
            guard let self = self else { return }
            let callIdStr = (data["call_id"] as? String) ?? UUID().uuidString
            let callerId = (data["caller_id"] as? String) ?? ""
            let isVid: Bool = ((data["call_type"] as? String) ?? "audio") == "video"
            // H-15 parity: caller_display is peer-controlled — sanitise it the
            // same way the call_incoming path does before it reaches any UI.
            let rawWireDisplay = (data["caller_display"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitisedWireDisplay = StringSanitiser.displayName(rawWireDisplay, fallback: "")
            // Hop to main: PersistentCallRecordStore is @MainActor, and
            // cachedContacts is main-isolated AppState state (this handler is
            // invoked on the WS delegate background thread — see call_incoming).
            DispatchQueue.main.async {
                let resolvedName: String = callerId.isEmpty
                    ? "Sconosciuto"
                    : DisplayName.forUser(
                        callerId,
                        serverDisplay: sanitisedWireDisplay.isEmpty ? nil : sanitisedWireDisplay,
                        contacts: self.cachedContacts
                    )
                // Record the missed call directly (dedup by call_id). A `.missed`
                // insert — NOT markMissed — because this device never registered
                // an in-progress record for this call (it was busy, no ring).
                PersistentCallRecordStore.shared.beginCall(
                    id: callIdStr,
                    peerUserId: callerId,
                    peerDisplayName: resolvedName,
                    direction: .missed,
                    isVideo: isVid
                )
                // Passive reminder only. The `.missedCall` category posts a plain
                // banner (no ringtone, no audio-session seizure — unlike the
                // INCOMING_CALL category), so it cannot disturb the call the user
                // is currently in.
                Task { @MainActor in
                    await NotificationCenterService.shared.scheduleLocal(
                        category: .missedCall,
                        title: "Chiamata persa",
                        body: "Chiamata persa da \(resolvedName)",
                        userInfo: [
                            "call_id": callIdStr,
                            "peer_id": callerId,
                        ],
                        delay: 0.1
                    )
                }
            }
        }

        // call_accepted — callee's real user tapped Answer. Gates the
        // caller's SAS/active-call display via the two-flag latch in
        // finalizeCallActive()/handleCallAccepted (WIRE_SPEC §3.5).
        ws.onCallAccepted = { [weak self] callId, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.handleCallAccepted(callId: callId)
            }
        }

        // W536 — inbound mid-call upgrade. Responder side: peer
        // wants to add video; apply their SDP offer, generate an
        // answer, ship it back, flip the UI to video mode, and
        // start the local VideoCallPipeline so the WS HEVC path is
        // populated too (the WebRTC RTP path is what the peer
        // actually consumes; the WS path serves iOS↔iOS peers).
        ws.onCallUpgradeRequest = { [weak self] callId, senderId, sdp, media in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleIncomingUpgradeRequest(
                    callId: callId, senderId: senderId, sdp: sdp, media: media)
            }
        }
        // W536 — caller side: peer accepted/rejected our upgrade
        // request. Apply the answer SDP if accepted.
        ws.onCallUpgradeResponse = { [weak self] callId, senderId, accepted, sdp in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleUpgradeResponse(
                    callId: callId, senderId: senderId, accepted: accepted, sdp: sdp)
            }
        }

        // Peer (Desktop/Android) wants video but is asking US to send the
        // real offer — see handleIncomingUpgradeIntent doc / Android
        // WsEvent.CallUpgradeIntent kdoc for the rationale.
        ws.onCallUpgradeIntent = { [weak self] callId, senderId, media in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleIncomingUpgradeIntent(
                    callId: callId, senderId: senderId, media: media)
            }
        }

        // WIRE_SPEC §8.7 (v1.1) — media readiness + keyframe recovery.
        // Both events funnel into the same honor path: force a local
        // encoder IDR for the active call (rate-limited to 1/s inside).
        ws.onCallMediaReady = { [weak self] callId, senderId, _, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleInboundKeyframeSignal(
                    callId: callId, senderId: senderId, kind: "call_media_ready")
            }
        }
        ws.onVideoKeyframeRequest = { [weak self] callId, senderId in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handleInboundKeyframeSignal(
                    callId: callId, senderId: senderId, kind: "video_keyframe_request")
            }
        }

        // WIRE_SPEC §8.1 — peer toggled their camera off/on. Informational
        // only: filter to the active call (same getActiveCallId() live-getter
        // pattern as registerInboundVideoHandler above) and publish the flag
        // so VideoCallView / ContentView react — no PeerConnection/SDP touch.
        ws.onCallVideoState = { [weak self] callId, paused, seq in
            DispatchQueue.main.async {
                guard let self = self,
                      let impl = self.liveProvider?.callingApi as? BCryptoCallingApiImpl,
                      let activeCallId = impl.getActiveCallId(),
                      callId.caseInsensitiveCompare(activeCallId) == .orderedSame
                else { return }
                // WIRE_SPEC §8.9 — last-writer-wins. The peer now REPEATS its
                // state every heartbeat, so without an ordering rule a delayed
                // repeat could overwrite a newer toggle and pin the lane to a
                // stale value: the heartbeat would become a new way to produce
                // the very hang it exists to heal. A peer that predates the
                // beacon sends no `seq` and is always accepted, i.e. exactly
                // the pre-beacon behaviour.
                guard VideoStateBeacon.shouldAccept(lastSeq: self.videoBeaconPeerSeq, incomingSeq: seq) else { return }
                self.videoBeaconPeerSeq = VideoStateBeacon.nextStoredSeq(
                    lastSeq: self.videoBeaconPeerSeq, acceptedSeq: seq)
                self.videoTransitionCause = paused ? "peer-camera-stop" : "peer-camera-start"
                self.remoteVideoPaused = paused
            }
        }
    }

    /// media-consent v1 — responder side of a mid-call renegotiation.
    /// Routes on the request's `media` tag:
    ///   - "screen": peer is sharing their screen. Viewing exposes nothing
    ///     of ours → answer immediately, NEVER open the local camera.
    ///   - "camera", consent already granted this call: benign renegotiation
    ///     (camera off→on / re-offer) → accept with the bidirectional flow
    ///     the user already approved.
    ///   - "camera", first time: PRIVACY GATE — publish
    ///     [pendingIncomingUpgrade] so the UI shows the consent dialog.
    ///     Nothing is answered and no camera opens until the user decides;
    ///     a 30s timer auto-declines (WIRE_SPEC §8.2 aligned timeout).
    /// Works on both transports: WebRTC (sdp carries the peer's offer) and
    /// the iOS↔iOS WS-HEVC relay (sdp is empty; the response carries an
    /// empty answer and pipelines start on each side independently).
    @MainActor
    private func handleIncomingUpgradeRequest(
        callId: String, senderId: String, sdp: String, media: String
    ) {
        guard isInCall, callContactId == senderId else {
            RTLog.warn("call", "onCallUpgradeRequest: not in a call with \(senderId.prefix(8))… — sending reject")
            Task {
                try? await (liveProvider?.callingApi as? BCryptoCallingApiImpl)?
                    .sendCallUpgradeResponse(
                        callId: callId, recipientId: senderId, sdp: "", accepted: false)
            }
            return
        }
        if media == "screen" {
            acceptIncomingScreenShareRenegotiation(
                callId: callId, senderId: senderId, sdp: sdp)
            return
        }
        // WIRE_SPEC §8.3 — GLARE: the peer's `call_upgrade_request` collided
        // with our OWN in-flight camera upgrade request (we already shipped one
        // and are awaiting its response). Resolve by the ORIGINAL call role.
        if pendingOutgoingUpgradeMedia != nil {
            handleGlareCollision(callId: callId, senderId: senderId, sdp: sdp)
            return
        }
        // W-VIDUP: a video upgrade for this call is already being built (the
        // on-demand PC + SDP answer take hundreds of ms). Ignore offer
        // retransmits in that window so we neither re-prompt the user nor race a
        // second build (which could later send a contradictory accepted:false).
        if upgradeBuildInProgress {
            RTLog.info("call", "onCallUpgradeRequest: upgrade build already in progress — ignoring retransmit")
            return
        }
        // A call that is ALREADY in video (born as a video call, or upgraded
        // earlier) counts as granted consent — re-offers don't re-prompt.
        if videoConsentGranted || isVideoCall {
            RTLog.info("call", "onCallUpgradeRequest: camera consent already granted this call — auto-accepting")
            acceptPendingIncomingUpgrade(
                PendingIncomingUpgrade(callId: callId, senderId: senderId, sdp: sdp))
            return
        }
        // First camera request this call → consent dialog. Duplicate
        // requests (re-offer retransmits) just refresh the pending state.
        RTLog.info("call", "onCallUpgradeRequest: camera upgrade from \(senderId.prefix(8))… — awaiting user consent")
        pendingIncomingUpgrade = PendingIncomingUpgrade(
            callId: callId, senderId: senderId, sdp: sdp)
        pendingUpgradeAutoDeclineTask?.cancel()
        pendingUpgradeAutoDeclineTask = Task { @MainActor [weak self] in
            // WIRE_SPEC §8.2 — 30s, aligned with the requester watchdog.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self = self,
                  self.pendingIncomingUpgrade?.callId == callId else { return }
            RTLog.info("call", "incoming upgrade consent timed out — auto-declining")
            self.declineIncomingUpgrade()
        }
    }

    /// `call_upgrade_intent` — responder side of the "peer asks us to send
    /// the real offer" flow (see `BCryptoWebSocketClient.onCallUpgradeIntent`
    /// doc / Android `WsEvent.CallUpgradeIntent` kdoc for the cross-platform
    /// rationale). Same consent gate as `handleIncomingUpgradeRequest` — the
    /// difference is purely which side ends up building the SDP offer: on
    /// accept we call `upgradeToVideo()` (self-initiate) instead of
    /// answering a peer-supplied SDP. Mirrors Android
    /// `CallController.kt`'s `upgradeIntentListenerJob`, which does not
    /// special-case glare or `media == "screen"` for this path either
    /// (Desktop only sends camera intents today; its screen-share protocol
    /// always ships its own offer) — kept minimal on purpose rather than
    /// inventing untested collision handling for a path the reference
    /// implementation doesn't cover.
    @MainActor
    private func handleIncomingUpgradeIntent(
        callId: String, senderId: String, media: String
    ) {
        guard isInCall, callContactId == senderId else {
            RTLog.warn("call", "onCallUpgradeIntent: not in a call with \(senderId.prefix(8))… — sending reject")
            Task {
                try? await (liveProvider?.callingApi as? BCryptoCallingApiImpl)?
                    .sendCallUpgradeResponse(
                        callId: callId, recipientId: senderId, sdp: "", accepted: false)
            }
            return
        }
        if upgradeBuildInProgress {
            RTLog.info("call", "onCallUpgradeIntent: upgrade build already in progress — ignoring retransmit")
            return
        }
        if videoConsentGranted || isVideoCall {
            RTLog.info("call", "onCallUpgradeIntent: camera consent already granted this call — self-initiating offer")
            upgradeToVideo()
            return
        }
        // First camera request this call → consent dialog. sdp is empty:
        // accept calls upgradeToVideo() (self-initiate) instead of answering.
        RTLog.info("call", "onCallUpgradeIntent: camera upgrade intent from \(senderId.prefix(8))… — awaiting user consent")
        pendingIncomingUpgrade = PendingIncomingUpgrade(
            callId: callId, senderId: senderId, sdp: "", isIntentOnly: true)
        pendingUpgradeAutoDeclineTask?.cancel()
        pendingUpgradeAutoDeclineTask = Task { @MainActor [weak self] in
            // WIRE_SPEC §8.2 — 30s, aligned with the requester watchdog.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self = self,
                  self.pendingIncomingUpgrade?.callId == callId else { return }
            RTLog.info("call", "incoming upgrade-intent consent timed out — auto-declining")
            self.declineIncomingUpgrade()
        }
    }

    /// WIRE_SPEC §8.3 — glare: a peer `call_upgrade_request` arrived while OUR
    /// own camera upgrade request is still in flight (`pendingOutgoingUpgradeMedia
    /// != nil`). Politeness is keyed to the ORIGINAL call role:
    ///   - polite (original CALLEE): JSEP-rollback our pending local offer,
    ///     accept the peer's offer, and treat our own request as satisfied.
    ///   - impolite (original CALLER): ignore the peer's request (send NO
    ///     decline) and keep waiting for the response to our own.
    /// Both branches keep the call retry-able (never poison state, §8.4): the
    /// impolite side leaves its own watchdog running; the polite side scrubs its
    /// abandoned outgoing metadata BEFORE accepting so a late
    /// `call_upgrade_response` for the abandoned request is a no-op.
    @MainActor
    private func handleGlareCollision(callId: String, senderId: String, sdp: String) {
        // Default role is CALLEE (polite) when unknown — the fail-safe here is
        // to accept the peer rather than deadlock both sides on a timeout.
        let role = originalCallRole ?? .callee
        switch UpgradeFlowDecisions.glareResolution(callRole: role) {
        case .impoliteIgnorePeer:
            // Original CALLER: ignore the colliding request. Our own watchdog
            // (upgradeResponseTimeoutTask) stays armed; the peer, being polite,
            // rolls back and accepts OUR offer, so we expect a normal
            // `call_upgrade_response` shortly. Send NO decline.
            RTLog.info("call", "glare (impolite/caller): ignoring peer upgrade request — awaiting our own response")
        case .politeAcceptPeer:
            // Original CALLEE: yield to the peer. Scrub our abandoned outgoing
            // upgrade FIRST so a stray `call_upgrade_response` for it can't
            // double-apply an answer (handleUpgradeResponse keys on
            // pendingOutgoingUpgradeMedia), then roll our controller back to
            // `stable` and accept the peer's offer via the normal accept path.
            RTLog.info("call", "glare (polite/callee): rolling back our request, accepting peer upgrade")
            pendingOutgoingUpgradeMedia = nil
            upgradeResponseTimeoutTask?.cancel()
            upgradeResponseTimeoutTask = nil
            // Our own request's camera/preview: keep it — accepting the peer's
            // upgrade means bidirectional video anyway (acceptPendingIncomingUpgrade
            // sets camera on). The controller rollback only tears down the
            // JSEP offer + upgrade latch, not the camera we already started.
            let pending = PendingIncomingUpgrade(callId: callId, senderId: senderId, sdp: sdp)
            #if canImport(WebRTC)
            if let controller = webRtcController as? QAudionWebRtcCallController {
                // Roll back the pending local offer to `stable`, THEN accept the
                // peer offer. Ordered + awaited so setRemoteOffer never lands on
                // a PC still parked in have-local-offer (§8.3 correctness).
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // W-GLARERECVONLY (2026-07-28) — NOT cancelVideoUpgrade():
                    // that stops the camera and removeTrack()s the sender,
                    // which the very next accept below can't undo (see
                    // rollbackLocalVideoOfferForGlare kdoc). Roll back only
                    // the JSEP offer so camera/track survive into the accept.
                    await controller.rollbackLocalVideoOfferForGlare()
                    self.acceptPendingIncomingUpgrade(pending)
                }
                return
            }
            #endif
            // No live controller (WS-relay-only call): nothing to JSEP-roll-back;
            // accept directly (the accept path builds an on-demand controller if
            // the peer's offer carries SDP).
            acceptPendingIncomingUpgrade(pending)
        }
    }

    /// media-consent v1 — user tapped ACCEPT on the consent dialog (or the
    /// consent was already granted this call). Answers the renegotiation,
    /// then opens OUR camera too: per spec, accepting means bidirectional
    /// video. Camera permission is pre-checked; on denial the upgrade is
    /// declined so the peer is not left waiting.
    @MainActor
    func acceptIncomingUpgrade() {
        guard let pending = pendingIncomingUpgrade else { return }
        pendingUpgradeAutoDeclineTask?.cancel()
        pendingUpgradeAutoDeclineTask = nil
        pendingIncomingUpgrade = nil
        if pending.isIntentOnly {
            // `call_upgrade_intent` accept: the peer asked US to send the
            // real offer (see handleIncomingUpgradeIntent doc / Android
            // WsEvent.CallUpgradeIntent kdoc) — same consent gate as a
            // normal incoming request, but WE initiate instead of
            // answering. upgradeToVideo() runs its own camera-permission
            // check (mirrors the explicit check below for the SDP path).
            upgradeToVideo()
            return
        }
        let camStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if camStatus == .denied || camStatus == .restricted {
            errorMessage = "Per attivare il video concedi l'accesso alla fotocamera in Impostazioni → Q-Audion."
            declinePending(pending)
            return
        }
        acceptPendingIncomingUpgrade(pending)
    }

    /// media-consent v1 — user tapped DECLINE (or the timer fired, or the
    /// camera permission was missing). Ships `accepted=false`; the call
    /// continues voice-only and nothing local changes.
    @MainActor
    func declineIncomingUpgrade() {
        guard let pending = pendingIncomingUpgrade else { return }
        pendingUpgradeAutoDeclineTask?.cancel()
        pendingUpgradeAutoDeclineTask = nil
        pendingIncomingUpgrade = nil
        declinePending(pending)
    }

    @MainActor
    private func declinePending(_ pending: PendingIncomingUpgrade) {
        Task {
            try? await (liveProvider?.callingApi as? BCryptoCallingApiImpl)?
                .sendCallUpgradeResponse(
                    callId: pending.callId,
                    recipientId: pending.senderId,
                    sdp: "",
                    accepted: false)
        }
    }

    /// Shared accept body: WebRTC answer (when a controller is live) or the
    /// WS-relay empty-SDP accept, then local camera pipeline up.
#if canImport(WebRTC)
    /// W-VIDUP — roll back ONLY the video leg when the on-demand upgrade
    /// PeerConnection fails to establish (ICE/DTLS). The WS-relay AUDIO call is
    /// independent and MUST keep flowing — so this never calls
    /// handleIceTermination()/endCall(). Idempotent.
    @MainActor
    private func rollbackUpgradeVideo() {
        // W-UPGRADEICEWATCHDOG — cancel so a rollback triggered another way
        // (explicit ICE failure, hangup, teardown) can't leave the watchdog
        // pending to fire later against a since-rebuilt controller.
        upgradeResponderIceConnectTask?.cancel()
        upgradeResponderIceConnectTask = nil
        if let c = self.webRtcController as? QAudionWebRtcCallController {
            c.closeSynchronously()
        }
        self.webRtcController = nil
        self.remoteWebRtcVideoTrack = nil
        // WIRE_SPEC §8.7 — the video leg is gone: drop any parked track +
        // failsafe so a rebuilt upgrade PC starts with a fresh RX gate.
        self.resetRemoteVideoRenderGate()
        // VIDEODIAG — the watched video leg is gone: cancel the watchdog
        // (a rebuilt upgrade re-starts it on the fresh track).
        self.stopVideoDiagWatchdog(reason: "video-leg rollback")
        self.videoPipeline?.stop()
        self.videoPipeline = nil
        self.setCamera(false)
        self.isVideoCall = self.peerScreenShareActive
        RTLog.warn("call", "video rollback ev=rb media_mode=ws-relay state=active")
    }

    /// W-VIDUP — build + wire a responder WebRTC controller on-demand when a
    /// video upgrade arrives on a WS-relay call that never built one (the audio
    /// runs over the sealed WS relay, not WebRTC). Mirrors the wiring in
    /// `handleIncomingWebRtcOffer` (kept separate so that proven path is
    /// untouched) and seeds the PQC session key + sovereign/KMS PSK so the
    /// native video FrameCryptor derives the same K_video as Android (v1.0.700).
    @MainActor
    private func makeUpgradeResponderController() -> QAudionWebRtcCallController? {
        guard let provider = liveProvider else { return nil }
        let controller = QAudionWebRtcCallController(
            callingApi: provider.callingApi,
            relayProvider: ensureRelayProvider())
        controller.accessToken = currentAccessToken
        if let customUrl = TransportGate.preferredTurnUrl {
            controller.iceServerOverride = [RTCIceServer(urlStrings: [customUrl.absoluteString])]
        }
        if TransportGate.forcesRelay { controller.iceTransportPolicyOverride = .relay }
        controller.sframeVideoSealerFactory = { keyProvider in
            SFrameVideoSealer.forRotatingKey(keyProvider)
        }
        controller.useExternalVideoSource = true
        // WIRE_SPEC §8.7 — publication rides the RX render gate (parked
        // until the receiver cryptor is ready, 2s failsafe).
        controller.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor [weak self] in self?.publishRemoteVideoTrackGated(track) }
        }
        // WIRE_SPEC §8.7 — receiver readiness → call_media_ready (dedup
        // per call+mid inside sendCallMediaReadyOnce).
        controller.onInboundVideoReady = { [weak self] mid in
            Task { @MainActor [weak self] in self?.sendCallMediaReadyOnce(mid: mid) }
        }
        // WIRE_SPEC §8.7 (INT-4a) — receiver decode stall → nudge the sender.
        controller.onVideoStallDetected = { [weak self] in
            Task { @MainActor [weak self] in self?.requestKeyframeFromSender() }
        }
        controller.videoTelemetry = { [weak self] kind, attrs in
            TelemetryService.shared.emit(kind: kind, attrs: attrs)
            // VIDEODIAG — feed the arrived/decoded counters off the
            // EXISTING 3s stats poll (thread-safe class; any thread).
            self?.videoDiag.noteVideoStats(kind: kind, attrs: attrs)
        }
        controller.onAudioDataChannelFrame = { [weak self] data in
            self?.callService.handleIncomingDataChannelAudio(data)
        }
        controller.shouldRejectIncomingVideo = { CallsGate.shouldRejectIncomingVideo }
        controller.advertisedCapabilitiesFilter = { CallsGate.filterAdvertisedCapabilities($0) }
        // NEVER-BRICK: this controller is built ONLY for the video upgrade; the
        // AUDIO call rides the sealed WS relay independently. A fresh-PC ICE/DTLS
        // failure (common on the restrictive NATs that forced audio onto the WS
        // relay) must roll back ONLY the video — it must NOT call
        // handleIceTermination()/endCall(), which would kill the working audio.
        controller.onStateChange = { [weak self] newState in
            switch newState {
            case .failed, .disconnected:
                Task { @MainActor [weak self] in self?.rollbackUpgradeVideo() }
            default:
                break
            }
        }
        controller.onIceConnectionState = { [weak self] iceState in
            switch iceState {
            case .failed, .disconnected, .closed:
                Task { @MainActor [weak self] in self?.rollbackUpgradeVideo() }
            case .connected, .completed:
                let isRelayForced = TransportGate.forcesRelay
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // W-UPGRADEICEWATCHDOG — ICE reached a working state on its
                    // own; the proactive timeout armed below is no longer needed.
                    self.upgradeResponderIceConnectTask?.cancel()
                    self.upgradeResponderIceConnectTask = nil
                    self.backendType = isRelayForced ? "turn" : "p2p"
                }
            default:
                break
            }
        }
        // K_video parity (v1.0.700): the native video FrameCryptor needs the
        // call's session key + the sovereign/KMS PSK salt BEFORE the answer.
        controller.pqcCallId = self.activeCallKitId?.uuidString.lowercased() ?? ""
        controller.videoContactPsk = self.callVideoPsk
        if let key = self.callPqcSessionKey { controller.pqcSessionKey = key }
        self.webRtcController = controller
        // Keep the proven WS-relay audio leg untouched — this controller exists
        // ONLY for video. Outbound voice stays on the relay (see
        // sendAudioOverDataChannel pin); video rides this WebRTC PC.
        self.audioPinnedToWsRelay = true
        // W-UPGRADEICEWATCHDOG — proactive fallback for the case where this
        // fresh ICE never reaches ANY terminal state (stuck in `.checking`
        // forever) rather than cleanly failing — `onIceConnectionState`'s
        // `.failed`/`.disconnected`/`.closed` branch above would never fire.
        // `weak controller` so a rollback/rebuild that replaces
        // `webRtcController` before the deadline can't roll back the WRONG
        // (newer) controller — the identity check below is the real guard,
        // this is belt-and-suspenders against a retained closure outliving it.
        upgradeResponderIceConnectTask?.cancel()
        upgradeResponderIceConnectTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(nanoseconds: UInt64(Self.upgradeResponderIceConnectTimeoutMs) * 1_000_000)
            guard !Task.isCancelled, let self = self, let controller = controller,
                  (self.webRtcController as? QAudionWebRtcCallController) === controller else { return }
            RTLog.warn("call", "video upgrade ICE-connect watchdog fired after \(Self.upgradeResponderIceConnectTimeoutMs)ms — never reached connected/completed, rolling back")
            self.rollbackUpgradeVideo()
        }
        return controller
    }
#endif

    @MainActor
    private func acceptPendingIncomingUpgrade(_ pending: PendingIncomingUpgrade) {
        guard let provider = liveProvider,
              let impl = provider.callingApi as? BCryptoCallingApiImpl else { return }
        // Latch SYNCHRONOUSLY before the async build so an Android upgrade-offer
        // retransmit during the build window is treated as a duplicate (ignored
        // by handleIncomingUpgradeRequest) instead of re-prompting / racing a
        // second build. Cancel the consent auto-decline now — we're accepting.
        upgradeBuildInProgress = true
        pendingUpgradeAutoDeclineTask?.cancel()
        pendingUpgradeAutoDeclineTask = nil
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer { self.upgradeBuildInProgress = false }
            var builtOnDemand = false
            do {
                var answerSdp = ""
                #if canImport(WebRTC)
                if let controller = self.webRtcController as? QAudionWebRtcCallController,
                   !pending.sdp.isEmpty {
                    // Existing controller (call started as video / already has a PC):
                    // a true renegotiation on the live PeerConnection.
                    controller.useExternalVideoSource = true
                    answerSdp = try await controller.acceptUpgradeOffer(remoteSdp: pending.sdp)
                } else if !pending.sdp.isEmpty,
                          let controller = self.makeUpgradeResponderController() {
                    builtOnDemand = true
                    // WS-relay call had NO WebRTC controller (audio is sealed-WS,
                    // not WebRTC). Build one on-demand and answer the peer's video
                    // upgrade offer with a fresh PeerConnection — a clean first
                    // offer/answer (the peer's PC never completed ICE/DTLS for this
                    // call). Without this iOS sent an EMPTY SDP and the peer rolled
                    // the camera back (iOS↔Android video upgrade stayed black).
                    // Caps are applied INSIDE the build method AFTER the PC exists
                    // (they live on the PC) so peerNegotiated() is non-nil and the
                    // native video FrameCryptor gets keyed with K_video.
                    answerSdp = try await controller.acceptUpgradeOfferBuildingPeerConnection(
                        callerId: pending.senderId, remoteSdp: pending.sdp,
                        peerCapabilities: self.pendingPeerCapabilities)
                }
                #endif
                try await impl.sendCallUpgradeResponse(
                    callId: pending.callId,
                    recipientId: pending.senderId,
                    sdp: answerSdp,
                    accepted: true)
                self.videoConsentGranted = true
                self.isVideoCall = true
                // W-CAMREVIVE (2026-07-24) — do NOT force the camera back on if the
                // user had paused it. This path is reached WITHOUT a consent prompt
                // whenever `videoConsentGranted || isVideoCall` (see
                // onCallUpgradeRequest's auto-accept), so a peer that simply re-sends
                // `call_upgrade_request` used to silently re-enable a camera the user
                // had deliberately turned off — one consent tap early in the call
                // bought the peer the ability to revive our camera for the rest of it.
                // Consent is for "may video exist on this call", never for "you may
                // turn my camera back on".
                let userHadPausedCamera = self.localVideoPaused
                if !userHadPausedCamera { self.setCamera(true) }
                // Idempotent: if a live pipeline already exists for a call that is
                // already in video, a re-offer must not tear it down and rebuild it
                // (the rebuild is what resurrected the camera, and it also restarts
                // capture/encode for no reason mid-call). When a rebuild genuinely is
                // needed, it inherits the user's pause state instead of overriding it.
                if self.isVideoCall, self.videoPipeline != nil {
                    RTLog.info("call", "acceptPendingIncomingUpgrade: pipeline already live — not rebuilding (paused=\(userHadPausedCamera))")
                } else {
                    await self.startVideoPipeline(for: pending.senderId,
                                                  startPaused: userHadPausedCamera)
                }
                // W-VIDTX: feed the camera into the WebRTC RTCVideoSource on the
                // RESPONDER upgrade too. The caller side already wires this in
                // startCall; without it here, iOS camera frames go ONLY to the
                // WS-relay VideoCallPipeline, never WebRTC RTP, so an Android /
                // Desktop peer (which renders ONLY WebRTC RTP) sees a BLACK screen.
                // Mirrors the proven caller-side wiring.
                #if canImport(WebRTC)
                if let controller = self.webRtcController as? QAudionWebRtcCallController,
                   let capturer = controller.webrtcPixelBufferCapturer {
                    self.videoPipeline?.onCapturedPixelBuffer = { [weak capturer] pixelBuffer, timestampNs in
                        capturer?.push(pixelBuffer, rotation: ._0, timestampNs: timestampNs)
                    }
                }
                #endif
                if self.videoPipeline == nil {
                    // Camera permission denied at request time or hardware
                    // unavailable — the peer's video still shows (consent
                    // was given); our side simply sends nothing.
                    self.isVideoCall = self.peerScreenShareActive
                    self.setCamera(false)
                }
                RTLog.info("call", "upgrade accepted ev=upok media_mode=p2p state=active")
            } catch {
                let desc: String = error.localizedDescription
                RTLog.warn("call", "upgrade failed ev=upfail state=active detail=" + desc)
                #if canImport(WebRTC)
                if builtOnDemand {
                    // The on-demand upgrade controller was published to
                    // webRtcController before this (failed) async build — tear it down
                    // so a stale/half-built PC can't block a later upgrade retry or be
                    // probed per audio frame.
                    self.rollbackUpgradeVideo()
                } else if let controller = self.webRtcController as? QAudionWebRtcCallController {
                    // 2026-07-04 fix — a failed `acceptUpgradeOffer` on the
                    // PRE-EXISTING (audio-carrying) controller used to leave that
                    // shared PeerConnection wedged: `setRemoteOffer` had thrown
                    // "Called in wrong state" (libwebrtc's signalingState guard),
                    // and nothing ever rolled the PC back to `stable`. Every
                    // subsequent upgrade retry — a fresh camera + fresh SDP each
                    // time — hit the SAME wedged PC and failed identically, so
                    // the responder's 30s consent dialog never got a stable
                    // window: the requester's `onUpgradeResponse` unblocks its
                    // button on this instant `accepted:false` and a re-click
                    // resets/replaces the still-showing dialog before the user
                    // can tap it (observed: 8 back-to-back failures, same error,
                    // one real call). `recoverPeerConnectionAfterFailedIncomingUpgrade()`
                    // rolls the shared PC back to `stable` (self-guarding, safe
                    // even if there was nothing to roll back) WITHOUT closing
                    // the PeerConnection, so the live AUDIO leg keeps flowing
                    // (signal-not-kill).
                    await controller.recoverPeerConnectionAfterFailedIncomingUpgrade()
                }
                #endif
                try? await impl.sendCallUpgradeResponse(
                    callId: pending.callId,
                    recipientId: pending.senderId,
                    sdp: "",
                    accepted: false)
            }
        }
    }

    /// media-consent v1 — auto-accept a `media="screen"` renegotiation.
    /// The WebRTC answer wires our RECEIVE side; with external video source
    /// the controller never opens a camera. On the WS-relay path (no
    /// controller) the accept is an empty-SDP ack — the decode-only
    /// pipeline mounts when the SCREEN_SHARE:start announce arrives.
    ///
    /// W-SPKAEC fix (2026-07-22): an audio-only call carried on the
    /// WS-relay path has NO `webRtcController` — the audio never built a
    /// WebRTC PeerConnection. When Android starts screen share on such a
    /// call it sends a REAL SDP re-offer expecting a REAL answer; this used
    /// to fall straight through the guard above with `answerSdp` left at
    /// `""` and reply `accepted:true, sdp:""` — silently. Android then threw
    /// on `setRemoteDescription` (SessionDescription is NULL) and the
    /// renegotiation aborted on both ends (black/purple video). Mirrors the
    /// on-demand controller build `acceptPendingIncomingUpgrade` (camera
    /// path) already does for the identical "no existing controller"
    /// precondition — see the comment there. iOS is only the RECEIVE side
    /// for a peer's screen share (no local capture to wire): building the
    /// controller is enough to key the receiver FrameCryptor via the
    /// onRemoteVideoTrack/onInboundVideoReady wiring already set up inside
    /// `makeUpgradeResponderController`.
    @MainActor
    private func acceptIncomingScreenShareRenegotiation(
        callId: String, senderId: String, sdp: String
    ) {
        guard let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            var builtOnDemand = false
            do {
                var answerSdp = ""
                #if canImport(WebRTC)
                let hasExisting = self.webRtcController is QAudionWebRtcCallController
                switch UpgradeFlowDecisions.resolveRenegotiationControllerStrategy(
                    hasExistingController: hasExisting, sdp: sdp
                ) {
                case .noRenegotiation:
                    break
                case .useExisting:
                    if let controller = self.webRtcController as? QAudionWebRtcCallController {
                        controller.useExternalVideoSource = true
                        answerSdp = try await controller.acceptUpgradeOffer(remoteSdp: sdp)
                    }
                case .buildOnDemand:
                    if let controller = self.makeUpgradeResponderController() {
                        builtOnDemand = true
                        answerSdp = try await controller.acceptUpgradeOfferBuildingPeerConnection(
                            callerId: senderId, remoteSdp: sdp,
                            peerCapabilities: self.pendingPeerCapabilities)
                    }
                }
                #endif
                try await impl.sendCallUpgradeResponse(
                    callId: callId, recipientId: senderId,
                    sdp: answerSdp, accepted: true)
                RTLog.info("call", "screenshare accepted ev=ssok media_mode=p2p state=active")
            } catch {
                RTLog.warn("call", "screenshare failed ev=ssfail detail=" + error.localizedDescription)
                #if canImport(WebRTC)
                if builtOnDemand {
                    // Same reasoning as acceptPendingIncomingUpgrade's catch:
                    // the on-demand controller was published to
                    // webRtcController before this (failed) async build —
                    // tear it down so a stale/half-built PC can't block a
                    // later upgrade retry. The WS-relay audio leg is
                    // untouched (signal-not-kill).
                    self.rollbackUpgradeVideo()
                }
                #endif
                try? await impl.sendCallUpgradeResponse(
                    callId: callId, recipientId: senderId, sdp: "", accepted: false)
            }
        }
    }

    /// media-consent v1 — caller side. On accept: unpause the (preview-only)
    /// pipeline so frames finally leave the device, and apply the answer SDP
    /// when the WebRTC leg is in play (the iOS↔iOS WS-relay accept carries
    /// an EMPTY sdp — that is still an accept, not a reject). On decline or
    /// timeout: roll the camera/preview back; the call stays voice-only.
    @MainActor
    private func handleUpgradeResponse(
        callId: String, senderId: String, accepted: Bool, sdp: String
    ) {
        // GAP-10 fix (2026-07-07, cross-platform matrix audit): this handler
        // previously validated neither call_id nor sender — combined with
        // the accepted-defaults-true wire bug (fixed in
        // BCryptoWebSocketClient), any authenticated user who learned this
        // call's UUID could inject a spoofed decline/accept. Mirrors the
        // same call_id + sender guard `handleInboundKeyframeSignal` already
        // applies to the sibling §8.7 signals. The internal 30s-timeout
        // synthetic call below passes `callContactId` as `senderId`, so it
        // naturally satisfies this guard with no special-case bypass.
        guard isInCall,
              let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl,
              let activeCallId = impl.getActiveCallId(),
              callId.caseInsensitiveCompare(activeCallId) == .orderedSame,
              callContactId == senderId else {
            RTLog.warn("call", "call_upgrade_response: not for active call / wrong sender — ignored")
            return
        }
        upgradeResponseTimeoutTask?.cancel()
        upgradeResponseTimeoutTask = nil
        let isCameraUpgrade = pendingOutgoingUpgradeMedia == "camera"
        pendingOutgoingUpgradeMedia = nil
        if !accepted {
            RTLog.info("call", "upgrade declined ev=updecl state=active")
            if isCameraUpgrade {
                self.isVideoCall = false
                self.setCamera(false)
                self.videoPipeline?.stop()
                self.videoPipeline = nil
                self.errorMessage = "Il peer non ha attivato il video — la chiamata continua in voce."
            }
            // Decline-poisoning fix: the UI rollback above is not enough — the
            // WebRTC controller still has videoUpgradeInProgress latched, the
            // upgrade's video track attached, and the PC parked in
            // have-local-offer. That state killed every later upgrade in BOTH
            // directions (our retry threw .alreadyHasVideo and sent nothing,
            // the peer's next offer failed setRemoteOffer wrong-state and was
            // auto-declined). Roll the controller back too. Covers the
            // explicit decline AND the 30s response timeout (which funnels
            // through this same handler).
            #if canImport(WebRTC)
            if let controller = webRtcController as? QAudionWebRtcCallController {
                Task { await controller.cancelVideoUpgrade() }
            }
            #endif
            return
        }
        if isCameraUpgrade {
            videoConsentGranted = true
            // Frames were held back (paused preview) until this consent.
            videoPipeline?.setVideoPaused(false)
        }
        // VIDEODIAG — upgrade accepted: video is expected from here on.
        startVideoDiagWatchdogIfNeeded()
        #if canImport(WebRTC)
        guard let controller = webRtcController as? QAudionWebRtcCallController,
              !sdp.isEmpty else {
            RTLog.info("call", "upgrade accepted ev=upok media_mode=ws-relay state=active")
            return
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await controller.applyUpgradeAnswer(sdp: sdp)
                RTLog.info("call", "upgrade accepted ev=upok media_mode=p2p state=active")
                // W402: forward the (possibly newly-derived) PQC key
                // to the WebRTC controller in case the upgrade
                // crossed a rekey boundary. Idempotent.
                if let key = self.callPqcSessionKey {
                    controller.videoContactPsk = self.callVideoPsk
                    controller.pqcSessionKey = key
                }
            } catch {
                let desc: String = error.localizedDescription
                RTLog.warn("call", "upgrade answer failed ev=ansfail state=active detail=" + desc)
                self.errorMessage = "Upgrade a video fallito: " + desc
            }
        }
        #endif
    }

    /// WIRE_SPEC §8.7 — receiver-side RENDER-gate publication. All three
    /// `onRemoteVideoTrack` wiring sites funnel here instead of writing
    /// `remoteWebRtcVideoTrack` directly: while our receiver cryptor is
    /// not yet attached+keyed the track is PARKED (the native decoder
    /// would only emit black/garbage — E2EE frames it cannot open), and a
    /// 2s failsafe publishes anyway so an exotic peer (no video cryptor
    /// negotiated → readiness never fires) still renders — signal-not-kill,
    /// same timeout the §8.7 sender TX-hold uses. The failsafe also nudges
    /// the sender for a keyframe (Android watchdog RETRY parity): if we
    /// lifted blind, the decoder most likely joined mid-stream.
    @MainActor
    private func publishRemoteVideoTrackGated(_ track: Any?) {
        // VIDEODIAG — remote video is now expected on this call: start the
        // per-call self-heal watchdog (idempotent). The rendered hop is
        // counted by the forwarding renderer WebRTCRemoteVideoView wraps
        // around the real RTCMTLVideoView once SwiftUI attaches it.
        startVideoDiagWatchdogIfNeeded()
        if inboundVideoReadyThisCall {
            remoteWebRtcVideoTrack = track
            return
        }
        pendingRemoteVideoTrack = track
        RTLog.info("call", "§8.7 RX render gate: remote video track parked until receiver cryptor is ready (max 2s)")
        remoteVideoGateFailsafeTask?.cancel()
        remoteVideoGateFailsafeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self = self else { return }
            RTLog.warn("call", "§8.7 RX render gate: 2s failsafe — publishing without readiness")
            self.openRemoteVideoRenderGate(reason: "2s failsafe")
            // Blind lift ⇒ the decoder needs a fresh IDR to sync; the
            // sender rate-limits honors to 1/s so this is always safe.
            self.requestKeyframeFromSender()
        }
    }

    /// WIRE_SPEC §8.7 — open the receiver render gate (readiness fired or
    /// failsafe elapsed): publish any parked remote track and let future
    /// tracks through immediately. Idempotent.
    @MainActor
    private func openRemoteVideoRenderGate(reason: String) {
        remoteVideoGateFailsafeTask?.cancel()
        remoteVideoGateFailsafeTask = nil
        inboundVideoReadyThisCall = true
        if let parked = pendingRemoteVideoTrack {
            pendingRemoteVideoTrack = nil
            remoteWebRtcVideoTrack = parked
            RTLog.info("call", "§8.7 RX render gate OPEN (\(reason)) — remote video track published")
        }
    }

    /// WIRE_SPEC §8.7 — drop all render-gate state WITHOUT publishing
    /// (call teardown / video-leg rollback).
    @MainActor
    private func resetRemoteVideoRenderGate() {
        remoteVideoGateFailsafeTask?.cancel()
        remoteVideoGateFailsafeTask = nil
        pendingRemoteVideoTrack = nil
        inboundVideoReadyThisCall = false
    }

    /// WIRE_SPEC §8.7 — receiver-side readiness handoff. Fired (engine
    /// one-shot latch) by QAudionWebRtcCallController.onInboundVideoReady
    /// when the receiver video cryptor is BOTH attached and keyed. Ships
    /// `call_media_ready` (dir "recv", key_epoch 0) to the sender so it
    /// forces an IDR the moment we can actually decrypt — once per
    /// (call, mid) even across controller rebuilds (upgrade paths).
    /// Also the readiness edge that opens the local RX render gate —
    /// BEFORE the guards/dedup below, so gate opening never depends on
    /// the WS API being resolvable or on the once-per-mid send dedup.
    @MainActor
    private func sendCallMediaReadyOnce(mid: String?) {
        openRemoteVideoRenderGate(reason: "receiver cryptor ready")
        // VIDEODIAG — remember the announced mid so the watchdog's rung-3
        // re-announce ships the same (callId, mid) wire bytes.
        lastInboundVideoMid = mid
        guard let peerId = callContactId,
              let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId() else { return }
        let midValue: String = mid ?? ""
        let dedupKey: String = callId.lowercased() + ":" + midValue
        guard !mediaReadySentKeys.contains(dedupKey) else { return }
        mediaReadySentKeys.insert(dedupKey)
        let midLabel: String = midValue.isEmpty ? "-" : midValue
        RTLog.info("call", "call_media_ready → sender (mid=\(midLabel), dir=recv, epoch=0)")
        Task {
            try? await impl.sendCallMediaReady(
                callId: callId,
                recipientId: peerId,
                mid: midValue,
                keyEpoch: 0,
                dir: "recv")
        }
    }

    /// WIRE_SPEC §8.7 (INT-4a) — receiver-side keyframe nudge. Fired by the
    /// controller's `onVideoStallDetected` (inbound `framesDecoded` flat for
    /// ~5s while bytes still arrive → decoder is missing its keyframe) and by
    /// the RX render gate's 2s failsafe (blind lift ⇒ decoder joined
    /// mid-stream). Ships `video_keyframe_request` to the in-call sender,
    /// which forces a local encoder IDR (WS-HEVC rail) or is a harmless no-op
    /// (pure-WebRTC sender). The API layer rate-limits to 1/s per §8.7, so
    /// callers may fire this freely on a persistent stall.
    @MainActor
    private func requestKeyframeFromSender() {
        guard isInCall,
              let peerId = callContactId,
              let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId() else { return }
        videoDiag.noteKeyframeRequested()   // VIDEODIAG — lastKeyframeRequestAtMs
        RTLog.info("call", "keyframe request ev=kfreq reason=stall")
        Task {
            try? await impl.sendVideoKeyframeRequest(
                callId: callId, recipientId: peerId)
        }
    }

    /// WIRE_SPEC §8.7 — sender-side honor of `call_media_ready` /
    /// `video_keyframe_request`: force a local encoder IDR so the peer's
    /// decoder can (re)bootstrap. Rate-limited to 1/s. Forcing handles,
    /// one per rail (both forced when both are live — e.g. iOS↔Android
    /// upgrades run the WS-HEVC pipeline for capture while the peer
    /// consumes WebRTC RTP):
    ///   - WS-HEVC relay rail: `videoPipeline.forceKeyFrame()` (same
    ///     HevcEncoder mechanism as the W567 first-frame IDR);
    ///   - WebRTC RTP rail: `controller.forceWebRtcKeyframe()` — the
    ///     `KeyframeForcingVideoEncoder` wrapper rewrites the next
    ///     encode()'s frameTypes to `.videoFrameKey` (INT-4a, mirrors
    ///     Android's KeyframeForcingVideoEncoder).
    /// A `call_media_ready` additionally releases the §8.7 TX-hold
    /// (upgrade paths hold the local video track until the peer's
    /// receiver is provably ready, max 2s) — BEFORE the rate limit, so
    /// a burst can't swallow the one-shot release.
    @MainActor
    private func handleInboundKeyframeSignal(callId: String, senderId: String, kind: String) {
        guard isInCall,
              let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl,
              let activeCallId = impl.getActiveCallId(),
              callId.caseInsensitiveCompare(activeCallId) == .orderedSame else {
            RTLog.info("call", "\(kind): not for the active call — ignored")
            return
        }
        // Server-stamped sender_id must be the in-call peer (same check
        // handleIncomingUpgradeRequest applies to upgrade offers).
        guard callContactId == senderId else {
            RTLog.warn("call", "\(kind): sender \(senderId.prefix(8))… is not the in-call peer — ignored")
            return
        }
        // §8.7 TX-hold release — idempotent one-shot, NOT subject to the
        // IDR rate limit below (the release forces its own keyframe).
        // notePeerMediaReadySeen() additionally memoizes the readiness so a
        // LATER re-upgrade this call skips arming a doomed 2s hold
        // (media_ready is once per (callId, mid) — Android armVideoTxHold
        // parity).
        #if canImport(WebRTC)
        if kind == "call_media_ready",
           let controller = webRtcController as? QAudionWebRtcCallController {
            controller.notePeerMediaReadySeen()
            controller.releaseVideoTxHold(reason: "peer call_media_ready")
        }
        #endif
        // VIDEODIAG — the peer signalling §8.7 readiness/recovery means
        // video is expected on this call: make sure the watchdog runs
        // (idempotent) and stamp the diag timestamps.
        startVideoDiagWatchdogIfNeeded()
        // VIDEODIAG TX inverse rule — the peer requesting >=3 keyframes in
        // 5s means its decoder is starving: force an IDR IMMEDIATELY,
        // bypassing the 1/s honor limiter once (one-shot; the timestamp
        // ring resets on bypass so a sustained storm can't turn the bypass
        // into an unlimited IDR firehose).
        var bypassRateLimit = false
        if kind == "video_keyframe_request" {
            let nowMs = VideoPathDiag.nowMs()
            peerKeyframeRequestTimesMs.append(nowMs)
            let cap = VideoStallSelfHeal.peerKeyframeStormCount
            if peerKeyframeRequestTimesMs.count > cap {
                peerKeyframeRequestTimesMs.removeFirst(peerKeyframeRequestTimesMs.count - cap)
            }
            if VideoStallSelfHeal.isPeerKeyframeStorm(
                requestTimesMs: peerKeyframeRequestTimesMs, nowMs: nowMs) {
                bypassRateLimit = true
                peerKeyframeRequestTimesMs.removeAll()
                RTLog.warn("VIDEODIAG", "keyframe storm ev=kfstorm retry_count=" + String(describing: peerKeyframeRequestTimesMs.count))
            }
        } else {
            videoDiag.notePeerMediaReady()   // lastPeerMediaReadyAtMs
        }
        // §8.7 honor rate limit: at most one forced IDR per second.
        let now = Date()
        guard bypassRateLimit || now.timeIntervalSince(lastKeyframeForcedAt) >= 1.0 else { return }
        lastKeyframeForcedAt = now
        var forced = false
        if let pipeline = videoPipeline {
            pipeline.forceKeyFrame()
            forced = true
            RTLog.info("call", "idr forced ev=idrfrc rail=relay")
        }
        #if canImport(WebRTC)
        if let controller = webRtcController as? QAudionWebRtcCallController {
            controller.forceWebRtcKeyframe()
            forced = true
            RTLog.info("call", "idr forced ev=idrfrc rail=webrtc")
        }
        #endif
        if forced {
            videoDiag.noteTxKeyframeForced()   // VIDEODIAG — txKeyframesForced
        } else {
            RTLog.warn("call", "idr skipped ev=idrskip reason=no_rail")
        }
    }

    // MARK: - VIDEODIAG §8.7 — per-call self-heal watchdog

    /// Start the ONE per-call 1s-tick watchdog (idempotent). Called from
    /// every site that establishes "video is expected on this call":
    /// remote track arrival (publishRemoteVideoTrackGated), an accepted
    /// upgrade (handleUpgradeResponse), and inbound §8.7 signals
    /// (handleInboundKeyframeSignal). SIGNAL-NOT-KILL: the tick only
    /// heals + logs, never tears anything down. NEVER-BLOCK: a single
    /// MainActor task sleeping 1s between ticks — no per-frame work.
    @MainActor
    private func startVideoDiagWatchdogIfNeeded() {
        guard videoDiagWatchdogTask == nil else { return }
        let now = VideoPathDiag.nowMs()
        videoDiagPrevArrived = 0
        videoDiagPrevRendered = 0
        videoDiagLastArrivedIncreaseMs = 0    // 0 = no arrival observed yet
        videoDiagLastRenderedIncreaseMs = now // grace: no stall before start+3s
        videoStallLadder.reset()
        RTLog.info("VIDEODIAG", "watchdog ev=wdstart state=active")
        videoDiagWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self = self else { break }
                self.videoDiagTick()
            }
        }
    }

    /// Cancel the watchdog + drop all per-call VIDEODIAG state. Called on
    /// endCall and on the video-leg rollback. Safe no-op when not running.
    @MainActor
    private func stopVideoDiagWatchdog(reason: String) {
        if videoDiagWatchdogTask != nil {
            videoDiagWatchdogTask?.cancel()
            videoDiagWatchdogTask = nil
            RTLog.info("VIDEODIAG", "watchdog ev=wdstop reason=" + reason.replacingOccurrences(of: " ", with: "_"))
        }
        videoStallLadder.reset()
        videoDiag.reset()
        peerKeyframeRequestTimesMs.removeAll()
        lastInboundVideoMid = nil
    }

    /// One 1s tick: sample the lock-free counters, evaluate the §8.7
    /// BLACK-VIDEO STALL rule, and run any due escalation rung. Silent
    /// while healthy (logs only on state transitions); one line per tick
    /// during a stall with every counter + pipeline state so a single log
    /// line pinpoints the broken hop (MEDIADIAG philosophy).
    @MainActor
    private func videoDiagTick() {
        guard isInCall else { return }
        let now = VideoPathDiag.nowMs()
        let snap = videoDiag.snapshot()
        // Update the last-increase memos off the monotonic counters.
        if snap.rxVideoFramesArrived > videoDiagPrevArrived {
            videoDiagPrevArrived = snap.rxVideoFramesArrived
            videoDiagLastArrivedIncreaseMs = now
        }
        if snap.rxFramesRendered > videoDiagPrevRendered {
            videoDiagPrevRendered = snap.rxFramesRendered
            videoDiagLastRenderedIncreaseMs = now
        }
        // Remote video expected = a remote track arrived (published or
        // parked behind the RX render gate). Without one there is nothing
        // to watch on the RX side — stay silent.
        let remoteExpected = remoteWebRtcVideoTrack != nil || pendingRemoteVideoTrack != nil
        guard remoteExpected else { return }
        guard videoDiagLastArrivedIncreaseMs > 0 else { return }  // no RTP yet
        let renderedFresh =
            now - videoDiagLastRenderedIncreaseMs < VideoStallSelfHeal.stallWindowMs
        // Arrivals idle for stallArrivedIdleMs (20s, ported from Android's
        // STALL_ARRIVED_IDLE_MS 2026-07-10 fix — see VideoStallSelfHeal.swift
        // kdoc): the peer stopped sending — "no media" is NOT a black-video
        // stall. Previously used 2× the window (6s), which — per the SAME
        // failure mode Android hit and fixed — cannot distinguish "peer
        // stopped sending" from "peer sending but our receiver never bound",
        // causing false-recovery flapping that starved rungs 2/3 of the
        // escalation ladder.
        let arrivedIdle =
            now - videoDiagLastArrivedIncreaseMs >= VideoStallSelfHeal.stallArrivedIdleMs
        if videoStallLadder.isStalled {
            // Recovery is RENDERED-based (frames actually reaching the
            // renderer again) or true idleness. A mere arrivals hiccup must
            // NOT reset the ladder — the arrival counter has 3s stats-poll
            // granularity, so its freshness can flap for one tick between
            // polls; treating that as recovery would restart the backoff
            // mid-stall and starve rungs 2/3.
            if renderedFresh || arrivedIdle {
                let recoverMs = now - videoStallLadder.stallStartMs
                let how: String = renderedFresh ? "frames rendering again" : "inbound video went idle"
                let line = "recovered (" + how + ") — time-to-recover=" +
                    String(describing: recoverMs) + "ms (backoff + ladder reset)"
                RTLog.info("VIDEODIAG", line)
                videoStallLadder.noteRecovered()
                emitVideoStallTelemetry(event: "recovered", snap: snap, now: now,
                                        recoverMs: recoverMs, how: how)
            }
        } else if VideoStallSelfHeal.isBlackVideoStall(
            msSinceLastArrivedIncrease: now - videoDiagLastArrivedIncreaseMs,
            msSinceLastRenderedIncrease: now - videoDiagLastRenderedIncreaseMs) {
            videoStallLadder.noteStalled(nowMs: now)
            RTLog.warn("VIDEODIAG", "stall ev=stall state=active")
            emitVideoStallTelemetry(event: "detected", snap: snap, now: now,
                                    recoverMs: nil, how: nil)
        }
        guard videoStallLadder.isStalled else { return }
        // Fire every due rung IN ORDER (pure engine decides; SIGNAL-NOT-
        // KILL: every rung only heals — nothing here ever ends the call).
        for action in videoStallLadder.dueActions(nowMs: now) {
            performVideoStallAction(action)
        }
        logVideoDiagStallLine(now: now, snap: snap)
    }

    /// Execute one escalation rung (§8.7 ladder — keyframe request →
    /// sink re-attach → media_ready re-announce). ZERO new wire messages.
    @MainActor
    private func performVideoStallAction(_ action: VideoStallSelfHeal.EscalationAction) {
        switch action {
        case .keyframeRequest:
            RTLog.warn("VIDEODIAG", "selfheal ev=heal1")
            requestKeyframeFromSender()
        case .sinkReattach:
            RTLog.warn("VIDEODIAG", "selfheal ev=heal2")
            reattachRemoteVideoSinkForSelfHeal()
        case .mediaReadyReannounce:
            RTLog.warn("VIDEODIAG", "selfheal ev=heal3")
            reannounceCallMediaReadyForSelfHeal()
        }
    }

    /// One VIDEODIAG line per stall tick with all counters + state so the
    /// broken hop is identifiable from a single line.
    @MainActor
    private func logVideoDiagStallLine(now: Int64, snap: VideoPathDiag.Snapshot) {
        var cryptorReady = false
        var trackAttached = false
        #if canImport(WebRTC)
        if let controller = webRtcController as? QAudionWebRtcCallController {
            cryptorReady = controller.inboundVideoCryptorReady
        }
        trackAttached = (remoteWebRtcVideoTrack as? RTCVideoTrack) != nil
        #endif
        let idrAgeMs = Int64(Date().timeIntervalSince(lastKeyframeForcedAt) * 1000.0)
        let kfrAge: Int64 = snap.lastKeyframeRequestAtMs > 0 ? (now - snap.lastKeyframeRequestAtMs) : -1
        let readyAge: Int64 = snap.lastPeerMediaReadyAtMs > 0 ? (now - snap.lastPeerMediaReadyAtMs) : -1
        var parts: [String] = []
        parts.append("stall t+" + String(describing: now - videoStallLadder.stallStartMs) + "ms")
        parts.append("stage=" + String(describing: videoStallLadder.stage))
        parts.append("arrived=" + String(describing: snap.rxVideoFramesArrived))
        parts.append("decoded=" + String(describing: snap.rxFramesDecoded))
        parts.append("rendered=" + String(describing: snap.rxFramesRendered))
        parts.append("txIdrForced=" + String(describing: snap.txKeyframesForced))
        parts.append("trackAttached=" + String(describing: trackAttached))
        parts.append("gateOpen=" + String(describing: inboundVideoReadyThisCall))
        parts.append("cryptorReady=" + String(describing: cryptorReady))
        parts.append("lastIdrAgeMs=" + String(describing: idrAgeMs))
        parts.append("lastKfrAgeMs=" + String(describing: kfrAge))
        parts.append("peerReadyAgeMs=" + String(describing: readyAge))
        RTLog.warn("VIDEODIAG", parts.joined(separator: " "))
    }

    /// VIDEO-STALL TELEMETRY (2026-07-12) — the §8.7 watchdog already DETECTS
    /// purple/black video (frames arriving but not reaching the renderer) and
    /// logs it to the VIDEODIAG tag, but that only lands in Loki, not the
    /// structured telemetry the tuning card reads. Emit a queryable `video.stall`
    /// event at detection + recovery so "when did purple/black happen (and was it
    /// during the video upgrade)" is a per-call fact, joinable across both legs.
    /// Derives `stall_kind` from the hop counters + cryptor-keyed state:
    ///   purple_unkeyed         — cryptor not keyed ⇒ decoder emits garbage (purple/green)
    ///   black_no_decode        — frames arrive but the decoder produces nothing
    ///   black_detached       — frames decode but never reach the UI renderer
///                          (kept under 20 chars ON PURPOSE: the fail-closed
///                          egress redactor in RuntimeLogSink scrubs any run of
///                          20+ chars from [A-Za-z0-9+/=_-], so the previous
///                          `black_detached_renderer` shipped as ***REDACTED***
///                          and this — the most diagnostic kind — was unreadable
///                          server-side. Weakening the redactor was rejected:
///                          an allowlist there is a bypass in a security control.
    /// Additive; rides the existing TelemetryService (call_id auto-added).
    @MainActor
    private func emitVideoStallTelemetry(event: String, snap: VideoPathDiag.Snapshot,
                                         now: Int64, recoverMs: Int64?, how: String?) {
        var cryptorReady = false
        var trackAttached = false
        #if canImport(WebRTC)
        if let controller = webRtcController as? QAudionWebRtcCallController {
            cryptorReady = controller.inboundVideoCryptorReady
        }
        trackAttached = (remoteWebRtcVideoTrack as? RTCVideoTrack) != nil
        #endif
        let stallKind: String
        if !cryptorReady {
            stallKind = "purple_unkeyed"
        } else if snap.rxVideoFramesArrived > 0 && snap.rxFramesDecoded == 0 {
            stallKind = "black_no_decode"
        } else if snap.rxFramesDecoded > snap.rxFramesRendered {
            stallKind = "black_detached"
        } else {
            stallKind = "black_unknown"
        }
        // "during the video upgrade" — a call_media_ready landed recently (the
        // upgrade handshake completes ~then), so a stall within ~8 s of it is
        // the upgrade-to-video window the user asked about.
        let readyAge: Int64 = snap.lastPeerMediaReadyAtMs > 0 ? (now - snap.lastPeerMediaReadyAtMs) : -1
        let inUpgradeWindow = readyAge >= 0 && readyAge < 8000
        var attrs: [String: Any] = [
            "event":            event,               // "detected" | "recovered"
            "stall_kind":       stallKind,
            "in_upgrade":       inUpgradeWindow,
            "arrived":          snap.rxVideoFramesArrived,
            "decoded":          snap.rxFramesDecoded,
            "rendered":         snap.rxFramesRendered,
            "tx_idr_forced":    snap.txKeyframesForced,
            "cryptor_ready":    cryptorReady,
            "track_attached":   trackAttached,
            "gate_open":        inboundVideoReadyThisCall,
            "peer_ready_age_ms": readyAge,
        ]
        if let recoverMs { attrs["recover_ms"] = recoverMs }
        if let how { attrs["recover_how"] = how }
        TelemetryService.shared.emit(kind: "video.stall", attrs: attrs)
    }

    /// Rung 2 — re-attach the renderer to the remote track: un-publish,
    /// then re-publish on the next main-queue turn so SwiftUI rebuilds
    /// WebRTCRemoteVideoView. Its Coordinator re-runs track.add(wrapper)
    /// with a FRESH counting forwarder around the fresh RTCMTLVideoView —
    /// so a successful re-attach is exactly what restarts the rendered
    /// counter and lets the ladder observe the recovery. The one-frame
    /// fallback flash is acceptable — the video is already black.
    @MainActor
    private func reattachRemoteVideoSinkForSelfHeal() {
        #if canImport(WebRTC)
        guard let track = remoteWebRtcVideoTrack as? RTCVideoTrack else { return }
        remoteWebRtcVideoTrack = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isInCall else { return }
            self.remoteWebRtcVideoTrack = track
        }
        #endif
    }

    /// Rung 3 — re-announce `call_media_ready` for the last announced mid
    /// (same wire bytes as the normal §8.7 readiness path; DELIBERATE
    /// bypass of the once-per-(callId, mid) dedup — receivers are
    /// idempotent) + force a LOCAL encoder IDR through the shared 1/s
    /// honor limiter (helps the symmetric case where OUR outbound lane
    /// is the stalled one).
    @MainActor
    private func reannounceCallMediaReadyForSelfHeal() {
        guard let peerId = callContactId,
              let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId() else { return }
        let midValue: String = lastInboundVideoMid ?? ""
        Task {
            try? await impl.sendCallMediaReady(
                callId: callId,
                recipientId: peerId,
                mid: midValue,
                keyEpoch: 0,
                dir: "recv")
        }
        // Local IDR through the SAME shared 1/s honor limiter as
        // handleInboundKeyframeSignal (flag-based force — collapses with
        // any concurrent request on the next encode()).
        let now = Date()
        if now.timeIntervalSince(lastKeyframeForcedAt) >= 1.0 {
            lastKeyframeForcedAt = now
            var forced = false
            if let pipeline = videoPipeline {
                pipeline.forceKeyFrame()
                forced = true
            }
            #if canImport(WebRTC)
            if let controller = webRtcController as? QAudionWebRtcCallController {
                controller.forceWebRtcKeyframe()
                forced = true
            }
            #endif
            if forced { videoDiag.noteTxKeyframeForced() }
        }
    }

    // NOTE (§8.7 rendered hop): there is deliberately NO side-attached
    // counting sink here anymore. libwebrtc feeds every attached sink, so
    // a sink added BESIDE the UI view kept rxFramesRendered advancing even
    // with the real RTCMTLVideoView detached — hiding the detached-renderer
    // black-video class from the watchdog. The counter now lives in the
    // DiagForwardingVideoRenderer that WebRTCRemoteVideoView wraps around
    // the real renderer (attach/detach in lockstep with the view).

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
            // W-NOCALLKIT review H1: in callKitFreeMode the call was NEVER
            // reported to CallKit (no reportIncomingCall), so reporting its end
            // would hit CXProvider with a UUID it never saw. Skip it; the
            // markMissed + endCall below run unconditionally. Flag OFF unchanged.
            if let uuid = uuid, !CallsGate.callKitFreeMode {
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
            let clientMsgId = data["client_msg_id"] as? String
            DispatchQueue.main.async {
                // W78-fix: the server echoes `msg_receive` back to the
                // SENDER too (`internal/signaling/client.go` handleMsgSend
                // calls both `relayToUser` to the recipient AND `c.send`
                // back to the sender itself), carrying the real DB-assigned
                // `message_id` — the only place that id ever reaches the
                // client. Previously this echo fell straight into
                // `handleIncomingMessage`, which has no self-echo handling
                // and would (at best) no-op into a bogus self-conversation,
                // and the outbound row's `serverMessageId` was left bound
                // to the locally-echoed `clientMsgId` instead (see
                // `ChatMessageSendService`/`BCryptoMessageApiImpl`), which
                // `msg_delivered`/`msg_read` receipts can never match since
                // those are keyed on the real id. Detect the self-echo here
                // and reconcile the outbound row directly by `clientMsgId`
                // instead of falling through to the inbound pipeline.
                if senderId == self.currentUserId, let cmid = clientMsgId, !cmid.isEmpty {
                    let matched = ConversationStore().bindServerMessageId(
                        clientMsgId: cmid,
                        serverMessageId: serverMsgId
                    )
                    if matched {
                        NotificationCenter.default.post(
                            name: AppState.chatRefreshNotification,
                            object: nil,
                            userInfo: ["clientMsgId": cmid]
                        )
                    }
                    return
                }
                self.handleIncomingMessage(
                    senderId: senderId,
                    serverMsgId: serverMsgId,
                    cipher: cipher,
                    clientMsgId: clientMsgId
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
        // Phase-0 KMS Rotation v2 §3.6 — on revoke: delete the vault PSK so
        // any subsequent handshake cannot use a key the server has invalidated.
        // Best-effort: a missing key (sovereign / not-yet-delivered) is a no-op;
        // a Keychain error is logged but never surfaced to the caller.
        ws.registerHandler(type: "kms_key_revoked") { [weak self] _, data in
            let keyId = (data["key_id"] as? String) ?? ""
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.errorMessage = "Una chiave KMS è stata revocata."
                guard !keyId.isEmpty else {
                    print("[AppState] kms_key_revoked: missing key_id in payload — nothing to delete")
                    return
                }
                guard let provider = self.liveProvider else {
                    print("[AppState] kms_key_revoked: no liveProvider (logout race) — key_id=\(keyId.prefix(8))… skip")
                    return
                }
                let vault = SovereignKeyVault()
                let poller = KmsPollerService(kmsClient: provider.kmsClient, vault: vault)
                await poller.notifyRevoked(keyId: keyId)
            }
        }
        // Initial sweep right after WS auth — covers any keys the
        // admin provisioned while the app was offline.
        // Phase-0 §6: also start background periodic poller (default 300s).
        Task { @MainActor [weak self] in
            await self?.runKmsSweep()
            guard let self else { return }
            if self.kmsPeriodicPoller == nil {
                let p = KmsPeriodicPoller()
                self.kmsPeriodicPoller = p
                await p.start { [weak self] in
                    if let self = self { await self.runKmsSweep() }
                }
            }
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
            // ROOT-CAUSE FIX (2026-07-12): this handler runs on the WS delegate
            // BACKGROUND thread. handleIncomingWebRtcOffer touches @MainActor
            // AppState state and reads the senderDeviceIdByPeer dictionary that
            // the (now main-isolated) call_incoming handler writes — an off-main
            // read racing a main write is a Swift Dictionary CoW use-after-free.
            // The other caller (drainPendingOfferReplays) already invokes this on
            // the main actor, so hopping here makes the method consistently
            // main-isolated.
            DispatchQueue.main.async {
                self.handleIncomingWebRtcOffer(
                    callerId: callerId,
                    sdp: sdp,
                    peerCapabilities: peerCaps,
                    hasVideo: offerHasVideo
                )
            }
        }
        ws.registerHandler(type: "call_answer") { [weak self] _, data in
            guard let self = self else { return }
            // Commit 540b79c0 parity — capture the peer's caps before
            // applying the SDP so the pipeline pick has the right
            // negotiated set when ensureVideoSealer() runs at video setup.
            let peerCaps = data["capabilities"] as? [String]
            // W-VIDUP: persist the peer's caps on the CALLER side too. They were
            // only stored on the inbound call_incoming path (callee), so an
            // iOS-as-caller WS-relay audio call had pendingPeerCapabilities == nil
            // at video-upgrade time → agreedTags empty → videoSealer latched
            // .legacy → no K_video cryptor → one-way black video. Storing them
            // here makes the on-demand upgrade responder negotiate sframe/vkey/
            // aes256 correctly in BOTH call directions.
            // ROOT-CAUSE FIX (2026-07-12): this handler runs on the WS delegate
            // BACKGROUND thread; pendingPeerCapabilities is @MainActor @Published
            // AppState. Writing it off-main fired objectWillChange into a live
            // main-thread SwiftUI subscription → Combine subscriber-list corruption
            // (same class as the call_incoming crash). Hop the write to main. It is
            // persisted state read later at video-upgrade time, so deferring it one
            // main tick is correct (nothing in this handler reads it synchronously).
            if let pc = peerCaps, !pc.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.pendingPeerCapabilities = pc }
            }
            // earbud-relay-v1 (caller side) — the callee answered from a
            // phone whose bonded earbud owns the audio key. The SW PQC
            // OFFER we already shipped will never be ACCEPTed; run the
            // counterparty handshake instead. The callId comes from the
            // envelope (or the bound active call as fallback).
            if CallCapabilities.peerAdvertisedEarbudRelay(peerCaps) {
                let envelopeCallId = (data["call_id"] as? String) ?? ""
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let cid = !envelopeCallId.isEmpty
                        ? envelopeCallId
                        : ((self.liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId() ?? "")
                    guard !cid.isEmpty, let peer = self.callContactId else {
                        print("[AppState] earbud caps on call_answer but no callId/peer — counterparty NOT started")
                        return
                    }
                    self.earbudCounterparty.start(callId: cid, peerId: peer)
                }
            }
            if let sdp = data["sdp"] as? String, !sdp.isEmpty {
                // ROOT-CAUSE FIX (2026-07-12): off the WS delegate BACKGROUND
                // thread, this reads webRtcController (@MainActor stored state)
                // and mutates the controller. Hop to main for consistent
                // main-isolation (mirrors the call_offer fix above).
                DispatchQueue.main.async {
                    self.handleIncomingWebRtcAnswer(sdp: sdp, peerCapabilities: peerCaps)
                }
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
                // W-GRPVPIO-CRASH-2 (2026-07-17) — a stray/replayed 1:1
                // `call_answer` arriving while a GROUP call is active must
                // never reach CallService: handleCallAnswered() →
                // startAudioIOIfReady() (and its 1s W574b fallback) call
                // straight into the legacy AudioProcessingPipeline's
                // `setVoiceProcessingEnabled(true)`, racing LiveKit's own
                // VP-IO unit on the SAME hardware — exactly the
                // AVAudioEngineGraph::_Connect EXC_CRASH/SIGABRT root-caused
                // live via App Store Connect crash logs (crashPointId
                // B4lMk7amGdH7pnGoa5qsYT, 4 occurrences 2026-07-17, always
                // during an active/joining group call). Unlike
                // `onAudioSessionActivated` (gated at AppState.swift:1773),
                // this WS-driven path had no such guard — a queued
                // `call_answer` redelivered on WS reconnect (which churns on
                // every group-call participant join/leave, confirmed via
                // server logs correlating each crash to a join event ~300ms
                // prior) reaches here regardless of `callState`. Group calls
                // never use `callService`/CallKit's 1:1 audio path at all
                // (see the comment on `onAudioSessionActivated`), so
                // dropping this entirely while `groupCallKitId != nil` is
                // safe — mirrors that exact guard.
                guard self.groupCallKitId == nil else {
                    print("[AppState] call_answer ignored — group call active")
                    return
                }
                // W574b: unblock the mic UNCONDITIONALLY — before the
                // .ringing guard. The guard below only protects the state
                // transition; gating the mic unblock on it left the mic
                // permanently off whenever callState wasn't .ringing at
                // answer time (e.g. still .active from the outgoing flow).
                self.callService.handleCallAnswered()
                // call_accepted two-flag latch (WIRE_SPEC §3.5): this is
                // the "local handshake done" flag. If the callee's real-user
                // accept already landed, finalize now; otherwise stash and
                // arm the 4s rollout-safety timeout.
                guard self.callState == .ringing,
                      let callId = self.activeCallKitId?.uuidString.lowercased() else { return }
                if self.callAcceptedCallId == callId {
                    self.finalizeCallActive()
                } else {
                    self.localHandshakeReadyCallId = callId
                    self.armAcceptGateTimeout(callId: callId)
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

        // W-GRPMSG: group TEXT message transport (server-side fan-out).
        // Persistent handlers — a recipient may receive group messages
        // without ever opening the group UI this session, so these are
        // registered alongside the always-on 1:1 chat handlers (not
        // lazily when GroupChatScreen appears).
        ws.registerHandler(type: "group_msg_receive") { [weak self] _, data in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.handleIncomingGroupMessage(data, live: true)
            }
        }
        ws.registerHandler(type: "group_msg_pending_sync") { [weak self] _, data in
            guard let self = self else { return }
            guard let batch = data["messages"] as? [[String: Any]] else {
                print("[AppState] group_msg_pending_sync: missing 'messages' array")
                return
            }
            // Oldest-first, same as 1:1 msg_pending_sync.
            DispatchQueue.main.async {
                for entry in batch {
                    self.handleIncomingGroupMessage(entry, live: false)
                }
            }
        }

        // W-GRPMEMBER: server-authoritative membership fan-out
        // (`cmd/bcrypto-lite/groups_membership.go` fanOutMembershipChanged —
        // add / remove / leave, federated cross-node, plus a `replay`-flagged
        // catch-up burst at server start). iOS NEVER consumed this event:
        // added/removed members and epoch bumps silently never landed, so the
        // roster went stale and inbound frames from a member we didn't know
        // about failed to decrypt. Android (QAudionApplication.kt) and Desktop
        // (GroupMembershipService) both consume it — this closes the gap.
        //
        // PERSISTENT handler, registered alongside the group TEXT handlers: a
        // membership change can land while the group UI was never opened.
        ws.registerHandler(type: "group_membership_changed") { [weak self] _, data in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.handleGroupMembershipChanged(data)
            }
        }

        // Fase 1C — server-authoritative group rename/avatar fan-out
        // (`groups_metadata.go` — PUT …/metadata replies to the actor
        // synchronously; every OTHER current member learns it here).
        // PERSISTENT handler, same reasoning as group_membership_changed
        // above: a rename can land while the group UI was never opened.
        ws.registerHandler(type: "group_metadata_changed") { [weak self] _, data in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.handleGroupMetadataChanged(data)
            }
        }

        // Fase 2 — group typing indicator (ephemeral opaque relay, mirrors
        // 1:1 msg_typing — see groups_receipts.go handleGroupTyping).
        // PERSISTENT handler, same reasoning as the group text/membership
        // handlers above: a typing event can arrive for a group whose
        // GroupChatScreen isn't the one currently on screen (harmless —
        // the receiving screen filters by groupHex before updating UI).
        ws.registerHandler(type: "group_typing") { [weak self] _, data in
            guard self != nil else { return }
            guard let rawGroupId = data["group_id"] as? String, !rawGroupId.isEmpty,
                  let senderId = data["sender_id"] as? String, !senderId.isEmpty,
                  let isTyping = data["is_typing"] as? Bool else { return }
            let groupHex = rawGroupId.replacingOccurrences(of: "-", with: "").lowercased()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: AppState.groupTypingNotification,
                    object: nil,
                    userInfo: ["groupHex": groupHex, "senderId": senderId, "isTyping": isTyping]
                )
            }
        }

        // Fase 2 — targeted delivery/read receipt for one of OUR OWN group
        // messages (server resolves the original sender and relays this to
        // THEM ONLY — see groups_receipts.go handleGroupMsgReceipt). Land
        // it straight into GroupMessageStore, which posts its own
        // didChangeNotification so an open GroupChatScreen refreshes its
        // per-message tick exactly like a new inbound message would.
        ws.registerHandler(type: "group_msg_receipt") { [weak self] _, data in
            guard self != nil else { return }
            guard let rawGroupId = data["group_id"] as? String, !rawGroupId.isEmpty,
                  let serverMsgId = data["server_message_id"] as? String, !serverMsgId.isEmpty,
                  let memberUserId = data["member_user_id"] as? String, !memberUserId.isEmpty,
                  let status = data["status"] as? String else { return }
            let groupHex = rawGroupId.replacingOccurrences(of: "-", with: "").lowercased()
            DispatchQueue.main.async {
                GroupMessageStore.shared.recordReceipt(
                    groupHex: groupHex, serverMessageId: serverMsgId,
                    memberUserId: memberUserId, status: status)
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

    // MARK: - W-GRPMSG: group TEXT message receive

    /// Decrypt one `group_msg_receive`-shaped dict and land the
    /// plaintext in `GroupMessageStore` so the group chat UI shows it
    /// live (if open) and on next open (persisted). Mirrors Android's
    /// `ReceiveGroupMessageUseCase.decryptAndPersist`.
    ///
    /// - `live`: true for a live `group_msg_receive`, false for a
    ///   `group_msg_pending_sync` backlog entry. ACKs only fire on the
    ///   live path (the server clears the pending queue on its own after
    ///   the sync flush write — same rule as Android).
    private func handleIncomingGroupMessage(_ data: [String: Any], live: Bool) {
        guard let groupIdUuid = data["group_id"] as? String, !groupIdUuid.isEmpty,
              let senderId = data["sender_id"] as? String, !senderId.isEmpty,
              let serverMsgId = data["server_message_id"] as? String, !serverMsgId.isEmpty,
              let payloadB64 = data["encrypted_payload"] as? String else {
            print("[AppState] group_msg_receive missing required fields: \(data.keys)")
            return
        }
        let clientMsgId = data["client_msg_id"] as? String
        let serverTs = data["server_ts"] as? String
        // Fase 1B — transport msg_type: 0 = raw-UTF-8 text (unchanged),
        // 1 = a 0xE4-sealed attachment descriptor (GroupAttachmentEnvelope).
        let msgType = data["msg_type"] as? Int ?? 0
        // dashed UUID (server wire) → hex (GroupChatService / registry key).
        let groupHex = groupIdUuid.replacingOccurrences(of: "-", with: "").lowercased()
        let selfId = currentUserId ?? AppState.currentUserIdSnapshot ?? ""

        // Sender self-echo: the server echoes our own send back to us so
        // we learn the server id. The optimistic row already exists — bind
        // the server id + ACK, don't re-append. Dedup by senderId (NOT
        // clientMsgId), exactly like Android.
        if senderId == selfId {
            if let cmid = clientMsgId, !cmid.isEmpty {
                GroupMessageStore.shared.bindServerId(
                    groupHex: groupHex, clientMsgId: cmid, serverMessageId: serverMsgId)
            }
            if live { sendGroupDelivered(serverMsgId) }
            return
        }

        // Already persisted (server re-delivered an already-consumed
        // message) — ACK (live) and skip; never buffer a duplicate.
        if GroupMessageStore.shared.contains(groupHex: groupHex, serverMessageId: serverMsgId) {
            if live { sendGroupDelivered(serverMsgId) }
            return
        }

        // Resolve membership (needed to bootstrap our own GroupState on
        // first contact). No registry entry → we haven't joined yet; the
        // sender_key_init that joins us is still in flight. Buffer + no
        // ACK (server keeps it pending until we catch up).
        // W-GRPDEL — a frame for a group this device deleted. The sender does
        // not know we left, and store-and-forward can replay frames queued
        // before the delete, so this is expected traffic rather than an
        // error. Drop it instead of buffering: the 128-slot retry buffer is
        // shared with every other group's genuinely-recoverable frames, and
        // nothing here will ever become decryptable (the crypto state was
        // purged). ACK when live so the server stops re-delivering — without
        // that, a failed server-side leave means this repeats forever.
        if GroupTombstoneStore.shared.isTombstoned(groupHex) {
            let dropShort: String = String(groupHex.prefix(8))
            let dropLive: String = live ? "1" : "0"
            let dropLine: String = "inbound frame dropped g=" + dropShort + " live=" + dropLive
            RTLog.info("groupdel", dropLine)
            if live { sendGroupDelivered(serverMsgId) }
            return
        }
        guard let entry = GroupRegistry.shared.entry(for: groupHex), !selfId.isEmpty else {
            bufferGroupWire(data, live: live)
            return
        }
        guard let wire = Data(base64Encoded: payloadB64) else {
            print("[AppState] group_msg_receive bad base64 msg=\(serverMsgId.prefix(8))")
            return
        }
        // Decrypt via the shared GroupSenderKey engine. nil == recv chain
        // not installed yet (init in flight / out of order) OR replay /
        // AEAD failure — indistinguishable, so buffer (bounded) and DON'T
        // ACK; the retry after the next sender_key_init install, plus the
        // server's pending re-delivery, both recover the in-flight case.
        guard let plaintext = GroupChatService.shared.decrypt(
            wire: wire, senderId: senderId, groupId: groupHex,
            members: entry.members, selfId: selfId) else {
            // W-GRPSILENT (2026-08-02): this buffer-and-return had NO log of
            // any kind. A group text frame that never becomes decryptable
            // (recv chain never installed, epoch moved past it) is not shown
            // as a placeholder like the 1:1 path — it simply never appears,
            // and `bufferedGroupWires` silently evicts it once the bound is
            // hit. "The message never arrived" and "the message arrived and
            // could not be opened" looked identical from outside, on the
            // exact path Pavel reports messages going missing.
            let bufDepth: Int = bufferedGroupWires.count
            RTLog.warn("group", "text undec=1 g=\(groupHex.prefix(8)) buffered=\(bufDepth)")
            bufferGroupWire(data, live: live)
            return
        }

        let ts = Self.parseGroupServerTs(serverTs)

        // Fase 1B — attachment frame: the decrypted 0xE4 plaintext is a
        // GroupAttachmentEnvelope JSON, NOT text. Branch on the transport
        // msg_type (never on speculative JSON-sniffing of a text body).
        if msgType == GroupAttachmentEnvelope.msgTypeAttachment {
            landIncomingGroupAttachment(
                plaintext: plaintext, groupIdUuid: groupIdUuid, groupHex: groupHex,
                senderId: senderId, selfId: selfId, serverMsgId: serverMsgId,
                clientMsgId: clientMsgId, ts: ts, live: live)
            return
        }

        // Store posts didChangeNotification → an open GroupChatScreen
        // reloads live; persisted so it also shows on next open.
        let inserted = GroupMessageStore.shared.append(
            groupHex: groupHex,
            GroupMessageStore.Stored(
                id: clientMsgId ?? serverMsgId,
                serverMessageId: serverMsgId,
                senderId: senderId,
                mine: false,
                text: plaintext,
                ts: ts))
        // Fase 1B — fire the same local banner the 1:1 inbound path fires,
        // but only for a genuinely NEW inbound row (never on a re-delivery
        // that merged into an existing message).
        if inserted {
            presentGroupMessageBanner(groupHex: groupHex, senderId: senderId, plaintext: plaintext)
            // Fase 2 — notify the ORIGINAL SENDER this device received
            // their message (targeted group_msg_receipt, best-effort, not
            // persisted). Distinct from `sendGroupDelivered` below, which
            // reuses the unrelated 1:1 pending-queue ack. Fires on BOTH
            // the live and pending-sync path (a pending-sync catch-up is
            // still a genuine delivery to this device), but never for a
            // re-delivery of an already-persisted row (`inserted == true`
            // guards that).
            sendGroupMsgDelivered(groupId: groupIdUuid, serverMsgId: serverMsgId)
        }
        if live { sendGroupDelivered(serverMsgId) }
    }

    /// Fase 1B — persist an inbound GROUP attachment row and kick off the
    /// async download+decrypt (capability token from `dl[selfId]`), then
    /// stamp the local blob path so the group bubble swaps its spinner for
    /// the image/file. A malformed descriptor is dropped + ACK'd (rendering
    /// it as text would be wrong); a download failure leaves the row in its
    /// "downloading" state to be retried on the next open.
    private func landIncomingGroupAttachment(
        plaintext: String, groupIdUuid: String, groupHex: String, senderId: String, selfId: String,
        serverMsgId: String, clientMsgId: String?, ts: Date, live: Bool
    ) {
        let envelope: GroupAttachmentEnvelope
        do {
            envelope = try GroupAttachmentEnvelope.parse(plaintext)
        } catch {
            print("[AppState] group attachment descriptor malformed msg=\(serverMsgId.prefix(8)): \(error)")
            // Fase 2 — the frame DID reach this device (it decrypted fine;
            // only the descriptor JSON is malformed), so from the sender's
            // perspective it was delivered — same "device receipt, not
            // content validity" semantics as the 1:1/text path above.
            sendGroupMsgDelivered(groupId: groupIdUuid, serverMsgId: serverMsgId)
            if live { sendGroupDelivered(serverMsgId) }
            return
        }
        let att = envelope.attachment
        let rowId = clientMsgId ?? serverMsgId

        // Group-TTL + export-permission. Reuses the SAME
        // AttachmentTimerResolver the 1:1 path uses (no group-specific
        // reimplementation) — `conversationDefault: nil` because group
        // has no per-conversation default timer (design decision: group
        // had NO TTL/view-once concept before this field), so the
        // effective value is purely the per-attachment `att.ex` override.
        let effectiveTimerSecs = AttachmentTimerResolver.resolve(
            overrideSeconds: att.ex, conversationDefault: nil)
        let isViewOnce = (effectiveTimerSecs ?? 0) == -1
        let ephExpiry: Date? = effectiveTimerSecs.flatMap { s in
            s > 0 ? ts.addingTimeInterval(Double(s)) : nil
        }
        let exportBlocked: Bool? = ((att.xp ?? 1) == 0) ? true : nil

        let inserted = GroupMessageStore.shared.append(
            groupHex: groupHex,
            GroupMessageStore.Stored(
                id: rowId,
                serverMessageId: serverMsgId,
                senderId: senderId,
                mine: false,
                text: envelope.caption ?? "",
                ts: ts,
                attachmentKind: envelope.kind,
                mediaMime: att.mime,
                fileName: att.filename,
                byteLength: att.byteLength,
                mediaLocalPath: nil,
                descriptorJson: plaintext,
                expiresAt: ephExpiry,
                isViewOnce: isViewOnce ? true : nil,
                exportBlocked: exportBlocked))
        if inserted {
            let previewName = att.filename
            presentGroupMessageBanner(
                groupHex: groupHex, senderId: senderId,
                plaintext: (envelope.caption?.isEmpty == false) ? envelope.caption! : previewName)
            // Fase 2 — see the text-message path above for the reasoning.
            sendGroupMsgDelivered(groupId: groupIdUuid, serverMsgId: serverMsgId)
            // Download + decrypt off the critical path; stamp the row when done.
            // Register the row as in-flight so an on-open retry can't kick a
            // duplicate concurrent download for the same blob.
            groupAttachmentDownloadsInFlight.insert(rowId)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                defer { self.groupAttachmentDownloadsInFlight.remove(rowId) }
                let receiver = GroupAttachmentReceiver(appState: self)
                do {
                    let url = try await receiver.downloadAndDecrypt(
                        envelope: envelope, senderId: senderId, selfId: selfId)
                    GroupMessageStore.shared.setMediaPath(
                        groupHex: groupHex, id: rowId, path: url.path)
                } catch {
                    print("[AppState] group attachment download failed msg=\(serverMsgId.prefix(8)): \(error)")
                }
            }
        }
        if live { sendGroupDelivered(serverMsgId) }
    }

    /// Fase 1B — on group-chat open, re-kick the download+decrypt for any
    /// inbound attachment row whose descriptor was retained but whose blob
    /// never landed (a prior download failed, or the app was killed before
    /// it finished). `landIncomingGroupAttachment` persists `descriptorJson`
    /// for exactly this retry, but nothing else re-triggers it — so without
    /// this an attachment received while the download failed stays a
    /// permanent spinner. Mirrors the 1:1 path's re-attempt of an
    /// un-downloaded attachment on chat open.
    ///
    /// Idempotent: rows already downloaded (`mediaLocalPath != nil`) and our
    /// own outbound rows are skipped, a malformed/unparseable descriptor is
    /// skipped, and the shared `groupAttachmentDownloadsInFlight` guard
    /// prevents a duplicate concurrent fetch for the same row across the
    /// initial land and repeated opens.
    func retryPendingGroupAttachmentDownloads(groupHex: String) {
        let selfId = currentUserId ?? AppState.currentUserIdSnapshot ?? ""
        guard !selfId.isEmpty else { return }
        for row in GroupMessageStore.shared.messages(forGroupHex: groupHex)
        where row.mediaLocalPath == nil && !row.mine {
            guard let json = row.descriptorJson,
                  let envelope = try? GroupAttachmentEnvelope.parse(json) else { continue }
            let rowId = row.id
            let senderId = row.senderId
            if groupAttachmentDownloadsInFlight.contains(rowId) { continue }
            groupAttachmentDownloadsInFlight.insert(rowId)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                defer { self.groupAttachmentDownloadsInFlight.remove(rowId) }
                let receiver = GroupAttachmentReceiver(appState: self)
                do {
                    let url = try await receiver.downloadAndDecrypt(
                        envelope: envelope, senderId: senderId, selfId: selfId)
                    GroupMessageStore.shared.setMediaPath(
                        groupHex: groupHex, id: rowId, path: url.path)
                } catch {
                    print("[AppState] group attachment retry failed row=\(rowId.prefix(8)): \(error)")
                }
            }
        }
    }

    /// Fase 1B — post a local notification for an inbound GROUP message,
    /// mirroring the 1:1 banner in `persistIncomingPeerMessage`:
    ///   - honours the global banner toggle (`qaudion.notifications.banners_enabled`);
    ///   - suppressed while the user is viewing THIS group (`activeGroupHex`);
    ///   - two-axis privacy gate (`hide_notification_content` AND
    ///     `PrivacyGate.messagePreviewInNotifications`) — either off ⇒ generic body;
    ///   - quiet-hours / in-app-sound are handled inside `scheduleLocal`.
    /// Title = group name; body = "sender: preview" or a generic fallback.
    /// No per-group mute exists in the current group model, so none is applied.
    private func presentGroupMessageBanner(groupHex: String, senderId: String, plaintext: String) {
        let bannersGlobalEnabled = (UserDefaults.standard.object(
            forKey: "qaudion.notifications.banners_enabled") as? Bool) ?? true
        guard bannersGlobalEnabled, activeGroupHex != groupHex else { return }

        let title = GroupRegistry.shared.entry(for: groupHex)?.name ?? "Gruppo"
        // Sender label — same fallback chain the group bubbles use.
        // W-EXTPREFIX consolidation (2026-07-29): this had NO placeholder
        // guard at all (a stale "Phone #100" would have shown verbatim in
        // the notification banner) — now the canonical `DisplayName.forUser`.
        let senderName: String = DisplayName.forUser(senderId, contacts: self.cachedContacts)

        let hideContent = (UserDefaults.standard.object(
            forKey: "qaudion.privacy.hide_notification_content") as? Bool) ?? false
        let previewAllowed = PrivacyGate.messagePreviewInNotifications
        let body: String
        if hideContent || !previewAllowed {
            body = "Nuovo messaggio di gruppo"
        } else {
            let snippet = plaintext.count > 120 ? String(plaintext.prefix(120)) + "…" : plaintext
            body = "\(senderName): \(snippet)"
        }
        Task { @MainActor in
            await NotificationCenterService.shared.scheduleLocal(
                category: .messageDelivered,
                title: title,
                body: body,
                userInfo: [
                    "groupId":    groupHex,
                    "peerUserId": senderId,
                ],
                delay: 0.1)
        }
    }

    /// ACK a delivered group message so the server can drop it from the
    /// pending queue. Uses the ordinary 1:1 `msg_delivered` receipt frame
    /// (`{message_ids:[id]}`) to mirror Android's `WsCommand.MsgDelivered`.
    private func sendGroupDelivered(_ serverMsgId: String) {
        liveProvider?.getWebSocketClient().send(
            type: "msg_delivered", data: ["message_ids": [serverMsgId]])
    }

    // MARK: - Fase 2: group typing indicator + delivery/read receipts

    /// Notify the ORIGINAL SENDER of a group message that THIS device
    /// received it. Server-side: `groups_receipts.go` handleGroupMsgReceipt
    /// resolves the sender from the stored `GroupMessage` and relays a
    /// targeted `group_msg_receipt` to them only — best-effort, never
    /// persisted, self-receipts and cross-group ids are rejected
    /// server-side. Deliberately separate from `sendGroupDelivered` above,
    /// which rides the unrelated 1:1 `msg_delivered` pending-queue-drop
    /// path (that one keeps its existing, unrelated behavior untouched).
    /// `groupId` MUST be the dashed-UUID wire form (never the hex
    /// registry key) — matches what `group_msg_send`/`group_typing` send.
    private func sendGroupMsgDelivered(groupId: String, serverMsgId: String) {
        liveProvider?.getWebSocketClient().send(
            type: "group_msg_delivered",
            data: ["group_id": groupId, "server_message_id": serverMsgId])
    }

    /// Fase 2 — emit `group_msg_read` for every inbound message in this
    /// group that has a server id, mirroring `ChatContainer.emitReadReceipts`
    /// (called once per chat-open, not on every refresh, to keep WS chatter
    /// bounded; no de-dup against already-acked rows — same as the 1:1
    /// method it mirrors). Gated on the SAME global "Conferme di lettura"
    /// privacy flag 1:1 chat uses (`PrivacyGate.readReceiptsEnabled` is not
    /// scoped per-conversation-kind). One WS frame per message — the group
    /// wire (unlike 1:1's batched `message_ids`) carries a single
    /// `server_message_id` per receipt (see groups_receipts.go).
    ///
    /// - Parameter groupId: dashed-UUID wire form (`GroupChatScreen` passes
    ///   `groupId.uuidString.lowercased()`).
    func emitGroupReadReceipts(groupId: String) {
        guard PrivacyGate.readReceiptsEnabled else { return }
        guard let ws = liveProvider?.getWebSocketClient() else { return }
        let groupHex = groupId.replacingOccurrences(of: "-", with: "").lowercased()
        let inboundServerIds = GroupMessageStore.shared.messages(forGroupHex: groupHex)
            .filter { !$0.mine }
            .compactMap { $0.serverMessageId }
        guard !inboundServerIds.isEmpty else { return }
        for serverMsgId in inboundServerIds {
            ws.send(type: "group_msg_read",
                    data: ["group_id": groupId, "server_message_id": serverMsgId])
        }
    }

    /// Fase 2 — group typing-indicator send-side debounce state, keyed by
    /// groupId (dashed UUID). Mirrors `ChatContainer.typingActive`/
    /// `typingStopWorkItem`, but lives on `AppState` (a single long-lived
    /// `@MainActor` owner) rather than on a per-conversation container
    /// object — `GroupChatScreen` is a plain SwiftUI `View` struct with no
    /// container/ViewModel class like `ChatContainer` to hang this on.
    private var groupTypingActive: [String: Bool] = [:]
    private var groupTypingStopWorkItems: [String: DispatchWorkItem] = [:]

    /// Call on every non-empty composer keystroke in a group chat. Fires
    /// `is_typing=true` once per "session of typing" and rolls a 3s
    /// auto-stop timer — identical cadence to `ChatContainer.notifyComposerInput`.
    func notifyGroupComposerInput(groupId: String) {
        guard PrivacyGate.typingIndicatorEnabled else { return }
        guard let ws = liveProvider?.getWebSocketClient() else { return }
        if groupTypingActive[groupId] != true {
            groupTypingActive[groupId] = true
            ws.send(type: "group_typing", data: ["group_id": groupId, "is_typing": true])
        }
        groupTypingStopWorkItems[groupId]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.groupTypingActive[groupId] = false
            guard PrivacyGate.typingIndicatorEnabled,
                  let ws2 = self.liveProvider?.getWebSocketClient() else { return }
            ws2.send(type: "group_typing", data: ["group_id": groupId, "is_typing": false])
        }
        groupTypingStopWorkItems[groupId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// Call when the composer transitions non-empty → empty (user deleted
    /// their draft). Mirrors `ChatContainer.notifyComposerCleared` — note
    /// the SAME asymmetry as 1:1: tapping Send does not call this (the
    /// 3s auto-stop timer clears the peer's "sta scrivendo…" instead),
    /// matching the existing 1:1 idiom exactly rather than "fixing" it.
    func notifyGroupComposerCleared(groupId: String) {
        groupTypingStopWorkItems[groupId]?.cancel()
        guard groupTypingActive[groupId] == true else { return }
        groupTypingActive[groupId] = false
        guard PrivacyGate.typingIndicatorEnabled,
              let ws = liveProvider?.getWebSocketClient() else { return }
        ws.send(type: "group_typing", data: ["group_id": groupId, "is_typing": false])
    }

    /// Append an undecryptable inbound group frame to the bounded retry
    /// buffer (drop oldest on overflow).
    private func bufferGroupWire(_ data: [String: Any], live: Bool) {
        bufferedGroupWires.append((data: data, live: live))
        if bufferedGroupWires.count > Self.maxBufferedGroupWires {
            bufferedGroupWires.removeFirst(bufferedGroupWires.count - Self.maxBufferedGroupWires)
        }
    }

    /// Re-run every buffered group frame through the receive path (e.g.
    /// after a sender_key_init install unblocked a recv chain). Frames
    /// still undecryptable re-buffer via `handleIncomingGroupMessage`;
    /// the bound keeps that from growing without limit.
    private func retryBufferedGroupMessages() {
        guard !bufferedGroupWires.isEmpty else { return }
        let pending = bufferedGroupWires
        bufferedGroupWires = []
        for e in pending {
            handleIncomingGroupMessage(e.data, live: e.live)
        }
    }

    /// Re-run every buffered group METADATA blob through
    /// `decryptAndApplyGroupMetadataBlob` (e.g. after a sender_key_init
    /// install unblocked the renaming admin's recv chain). Still-undecryptable
    /// blobs re-buffer themselves via that same function, mirroring
    /// `retryBufferedGroupMessages` above for TEXT frames.
    private func retryBufferedGroupMetadata() {
        guard !bufferedGroupMetadata.isEmpty else { return }
        let pending = bufferedGroupMetadata
        bufferedGroupMetadata = [:]
        for (groupHex, entry) in pending {
            decryptAndApplyGroupMetadataBlob(
                groupHex: groupHex, blobB64: entry.blobB64,
                version: entry.version, selfId: entry.selfId)
        }
    }

    /// Parse the server RFC3339 `server_ts`; fall back to now (mirrors
    /// Android's `Instant.parse` with a `toLongOrNull` fallback).
    private static func parseGroupServerTs(_ ts: String?) -> Date {
        guard let ts = ts, !ts.isEmpty else { return Date() }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: ts) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: ts) { return d }
        if let ms = Double(ts) { return Date(timeIntervalSince1970: ms / 1000.0) }
        return Date()
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
            case .v4:
                // ── Phase 18 — v4 native PQ ratchet (opaque 0xE5 frame) ──
                // The frame is OPAQUE (owned by the Rust core); we route by PEER
                // id (senderId) only and NEVER parse it. The session was
                // bootstrapped + persisted at handshake time; here we resume-by-
                // peer and decrypt through the engine-routed method. FAIL CLOSED:
                // a 0xE5 frame with no local v4 session (or the v4 path disabled)
                // yields nil → throw → surfaced as a decrypt failure, NEVER a
                // silent downgrade to v2/v1.
                let v4HasSession = AppState.sharedV4Ratchet.hasV4Session(senderId)
                let v4Plain = ratchetDecryptV4(wire: cipher, senderId: senderId)
                print("[PQC_DIAG_V4] decryptV4 sender=\(senderId.prefix(8)) hasSession=\(v4HasSession) result=\(v4Plain != nil ? "ok" : "nil")")
                guard let plain = v4Plain else {
                    throw RatchetV4DispatchError.unroutableOrFailedClosed
                }
                pt = plain
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
            // E2EE avatar transport (2026-07-30) — a successful decrypt
            // from `senderId` proves a real pairwise PSK exists with
            // them right now. Opportunistically deliver our current
            // avatar if we haven't already sent them this version —
            // covers first-contact (this is often the very first real
            // exchange after a key exchange completes) without needing
            // to hook ContactKeyExchange's internal handshake-complete
            // callback directly. Fire-and-forget; never blocks/affects
            // this message's own processing.
            maybeAnnounceAvatarTo(senderId, trigger: .chatDecrypt)
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
            // W86: route qa_ctl:1 control envelopes (delete / edit / reaction)
            // BEFORE persisting as a new inbound row. These mutate
            // an EXISTING row keyed by clientMsgId rather than
            // appending. A successful route returns early — the chat
            // refresh notification fires from inside the route helper.
            //
            // Screenshot-lock family (ss_req / ss_resp / ss_lock) now ALSO
            // parses into a typed case, but it is CONVERSATION-level (no target
            // row to mutate) and is applied — together with its system bubble +
            // `setScreenshotGranted` state — by the conversation-level ad-hoc
            // JSON handler further down this function. So we deliberately let it
            // FALL THROUGH here (do not route to `handleControlEnvelope`, which
            // treats it as a no-op) to keep that ad-hoc handler as the single
            // source of truth and avoid a parse-then-drop regression.
            if let env = try? ChatControlEnvelope.parse(decryptedRaw) {
                switch env {
                case .screenshotRequest, .screenshotResponse, .screenshotLock:
                    break  // fall through to the ad-hoc conversation-level handler
                case .delete, .edit, .reaction:
                    handleControlEnvelope(env, senderId: senderId)
                    return
                }
            }
            // E2EE avatar transport (2026-07-30, see
            // docs/E2EE_AVATAR_TRANSPORT_DESIGN.md) — like delete/edit/
            // reaction above, this must be routed BEFORE message
            // persistence: it is never a visible chat row, only a
            // silent local-cache update.
            //
            // 2026-08-02: the version-dedup pre-check that used to sit here
            // moved INTO the coordinator, where it runs inside the per-sender
            // serialisation. Checking it out here was racy against a second
            // announce from the same peer (both could read the same cached
            // version and both proceed), and — worse for diagnosis — a skip
            // produced no log at all, which is precisely the "did it run or
            // not?" ambiguity that made this feature so hard to debug.
            // Fix (2026-07-31, found during full-audit): `try?` here used to
            // collapse two very different outcomes into the same silent
            // `nil` — "this JSON just isn't an avatar_announce" (expected,
            // falls through to other handlers) and "this IS an
            // avatar_announce but a required field is missing/malformed" (a
            // real wire-format bug, e.g. the att/avatar key mismatch fixed
            // earlier today). The malformed case produced ZERO log anywhere
            // and fell through to being persisted+rendered as raw garbage
            // JSON in the chat UI. Distinguish them explicitly.
            do {
                if let avatarEnv = try AvatarAnnounceEnvelope.parse(decryptedRaw) {
                    handleInboundAvatarAnnounce(avatarEnv, senderId: senderId)
                    return
                }
            } catch {
                RTLog.error("avatar", "malformed avatar_announce from=\(senderId.prefix(8)): \(error)")
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
                // W-GRPMSG: a freshly-installed recv chain may unblock
                // group TEXT frames we buffered because they arrived
                // before this sender's sender_key_init. Retry them now.
                if groupCtlType == "sender_key_init" || groupCtlType == "sender_key_rotate" {
                    retryBufferedGroupMessages()
                    retryBufferedGroupMetadata()
                }
                return
            }
            plaintext = Self.renderInboundPlaintext(decryptedRaw)
        } catch {
            // Fix (2026-07-31, found during full-audit): was bare print() —
            // reaches the Xcode/device console only, no interception
            // anywhere in the app routes it to telemetry/Loki. A whole test
            // session's worth of decrypt failures were completely invisible
            // to remote log pulls because of this single line; RTLog
            // actually reaches RuntimeLogSink → the real log pipeline.
            // W-TAGDROP (2026-08-02): "chat" was NOT in the shipper's
            // TAG_SCOPE_PREFIXES, so even after the 2026-07-31 print()→RTLog
            // fix this line still never reached Loki — the one record of a
            // message the user actually sees as "[messaggio cifrato non
            // leggibile]" was dropped at the tag gate. Tag now allowed, and
            // the counters carry a numeric tail because the redactor blobs
            // every non-numeric token (see PairwiseChainKeyResolver's own
            // note): `undec=1` is what survives the trip.
            RTLog.error("chat", "msg_receive undec=1 from=\(senderId.prefix(8)): \(error)")
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
            // W-CC: use cached snapshot — avoids a UserDefaults decode
            // on every incoming message path.
            // W-EXTPREFIX consolidation (2026-07-29): checked only
            // `looksLikeUUID`, not the full placeholder set — now the
            // canonical `DisplayName.forUser`.
            let resolvedName: String = DisplayName.forUser(senderId, contacts: self.cachedContacts)
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

        // W447: per-attachment ephemeral-timer override. When the
        // inbound message carries a qfile/attach_announce envelope with
        // a non-zero `ex`, it wins over the conversation default —
        // mirrors Desktop's `resolveAttachmentTimerSec` and Android's
        // `InboundFileAttachmentDispatcher`. Plain text messages (no
        // envelope parsed) have no override, so this is a no-op for them
        // and behavior is unchanged.
        let attachmentExOverride: Int? = pendingMarker?.qfile.ex ?? pendingAttachAnnounce?.att.ex
        let effectiveTimerSecs = AttachmentTimerResolver.resolve(
            overrideSeconds: attachmentExOverride,
            conversationDefault: conv.ephemeralTimerSeconds
        )

        // Incoming message: isViewOnce derived from the effective timer == -1.
        let isViewOnce = (effectiveTimerSecs ?? 0) == -1

        // W441 (inbound parity): when the effective timer is an ACTIVE
        // positive disappearing-timer, stamp `expiresAt` on the received
        // row so the EphemeralMessageJanitor sweeps it, exactly like the
        // outbound send path (ChatContainer.sendMessage). Mirrors
        // Android's computeEphemeralExpiry:
        //   - nil / 0  → no expiry (message persists)
        //   - -1       → view-once (expiresAt stays nil here; set at open time
        //                by markViewOnceOpened, parity with the outbound path)
        //   - positive → now + seconds
        let receivedNow = Date()
        let ephExpiry: Date? = effectiveTimerSecs.flatMap { s in
            s > 0 ? receivedNow.addingTimeInterval(Double(s)) : nil
        }

        // Export-permission override. Modern-envelope-only — the legacy
        // qfile marker is NOT being extended with `xp` (see
        // `AttachAnnounceMeta.xp` doc), so only `pendingAttachAnnounce`
        // can ever carry it; a qfile-marker attachment always decodes as
        // export-allowed (nil), same as today. absent/1 on the wire =
        // allowed (nil here, the default); 0 = blocked.
        let wireXp: Int? = pendingAttachAnnounce?.att.xp
        let exportBlocked: Bool? = ((wireXp ?? 1) == 0) ? true : nil

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
            expiresAt: ephExpiry,
            isViewOnce: isViewOnce ? true : nil,
            exportBlocked: exportBlocked
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
            let title = conv.peerDisplayName.isEmpty
                ? DisplayName.forUser(senderId, contacts: self.cachedContacts)
                : conv.peerDisplayName
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
        // Screenshot-lock family (ss_req / ss_resp / ss_lock) is
        // CONVERSATION-level, not message-targeted, and is applied by the
        // ad-hoc JSON handler earlier in `handleIncomingMessage` (which also
        // renders the system bubble + updates `setScreenshotGranted`). We must
        // NOT re-apply it here — that path is the single source of truth. These
        // cases are typed-model completeness only; treat them as a safe no-op so
        // the message-targeted dispatch below never runs on them. (In practice
        // the caller doesn't route these variants here — see the parse-guard in
        // `handleIncomingMessage`.)
        switch env {
        case .screenshotRequest, .screenshotResponse, .screenshotLock:
            return
        case .delete, .edit, .reaction:
            break
        }
        let target: String
        switch env {
        case .delete(let t, _): target = t
        case .edit(let t, _, _): target = t
        case .reaction(let t, _, _): target = t
        case .screenshotRequest, .screenshotResponse, .screenshotLock:
            return  // unreachable: handled by the guard above
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
        case .screenshotRequest, .screenshotResponse, .screenshotLock:
            applied = false  // unreachable: handled by the top-of-function guard
        }
        guard applied else { return }
        NotificationCenter.default.post(
            name: AppState.chatRefreshNotification,
            object: nil,
            userInfo: ["peerUserId": envelopeSenderId, "conversationId": convId]
        )
    }

    // MARK: - E2EE avatar transport (2026-07-30)
    //
    // See docs/E2EE_AVATAR_TRANSPORT_DESIGN.md (bcrypto-server) for the
    // full design. Summary: each peer's avatar is delivered as their
    // OWN ciphertext, encrypted under a pairwise chain key derived from
    // the real ContactKeyExchange PSK (never a shared URL any
    // authenticated account could fetch) — same AttachmentEncryption
    // primitive already used for voice notes/attachments, same
    // fail-closed PSK ladder (PairwiseChainKeyResolver).

    /// The ONE place that decides whether to announce, and the ONE place
    /// that applies an inbound announce — a direct port of Android's
    /// `AvatarAnnounceCoordinator` (per-trigger cooldown, per-peer
    /// serialisation, mark-on-success-only). Everything in this MARK
    /// section now delegates to it; see that file's doc for why each of
    /// those three properties is load-bearing.
    lazy var avatarAnnounceCoordinator = AvatarAnnounceCoordinator(appState: self)

    private static let selfAvatarVersionKey = "qaudion.selfAvatarVersion"
    // W-AVATARSTUCK (2026-07-31) — renamed (v2 suffix) to orphan every
    // pre-tus-fix "sent" entry in one step: this device (and Android's
    // A36/S26 pair, confirmed live) had peers permanently marked as having
    // received the current avatar version from attempts that predated the
    // tus + wire-key transport fixes (silently 404ing on the recipient
    // side) — the version never changed since, so the "already sent" guard
    // below no-op'd forever with zero indication anything was wrong. A key
    // rename needs no migration code; the old entries are simply never read
    // again. Mirrors the identical fix on Android (`AvatarFileStore.kt`
    // `KEY_SENT_PREFIX`) and Desktop (`AvatarFileStore.ts` `sentVersionsV2`).
    // W-AVATARCOOLDOWN (2026-08-02): the sent-version bookkeeping and the
    // self-heal resend ceiling that used to live here moved verbatim into
    // `AvatarAnnounceCoordinator` (same UserDefaults keys, so existing
    // device state carries over unchanged). The ceiling itself was the bug:
    // one flat 3-DAY interval for every trigger, which Android measured to
    // be a guaranteed no-op for both peers of any call inside a normal
    // usage session. It is now per-trigger — 1 h for a background
    // chat-decrypt, 2 min for a real call or a completed key exchange.

    /// Current self-avatar version. 0 = no avatar ever set (never
    /// bumped) — `maybeAnnounceAvatarTo` treats that as "nothing to
    /// send yet" so a brand-new account with no photo doesn't try to
    /// broadcast an empty avatar to every peer it talks to.
    var selfAvatarVersion: Int {
        UserDefaults.standard.integer(forKey: Self.selfAvatarVersionKey)
    }

    /// Bumps and persists the self-avatar version. `AvatarUploader`
    /// calls this once, right after writing the new plaintext bytes to
    /// the local self-avatar cache file, before broadcasting.
    func bumpSelfAvatarVersion() -> Int {
        let next = selfAvatarVersion + 1
        UserDefaults.standard.set(next, forKey: Self.selfAvatarVersionKey)
        return next
    }

    /// Encrypts the current self-avatar under EVERY currently-known
    /// peer's own pairwise chain key and sends each their own
    /// `avatar_announce` — called by `AvatarUploader` right after the
    /// user changes their avatar. Best-effort per peer: one with no
    /// real PSK yet (no completed ContactKeyExchange) is skipped here
    /// and picked up later by `maybeAnnounceAvatarTo` on the next real
    /// message exchange with them, rather than blocking this whole
    /// broadcast on a key exchange that may take a while.
    ///
    /// 2026-08-02: the per-peer encrypt/upload/send/mark body moved into
    /// `AvatarAnnounceCoordinator` so this broadcast shares the SAME
    /// per-peer serialisation and mark-on-success bookkeeping as the
    /// opportunistic triggers. Without that, a broadcast racing a
    /// call-connect announce for the same peer could double-upload and the
    /// two would write the sent-version bookkeeping out of order. The
    /// bytes/version parameters are gone with it: the coordinator reads the
    /// self-avatar cache file and `selfAvatarVersion`, both of which
    /// `AvatarUploader` has already written by the time this is called.
    func broadcastAvatarToKnownPeers() {
        let peers = ContactsStore().load().map { $0.userId }.filter { !$0.isEmpty }
        guard !peers.isEmpty else { return }
        Task { [weak self] in
            for (index, peerId) in peers.enumerated() {
                await self?.avatarAnnounceCoordinator.announce(to: peerId, trigger: .avatarChanged)
                // Security-review fix (2026-07-30): this loop is the only
                // place in the app that fires one HTTP upload per known
                // contact in a tight sequence — every other send path
                // (chat messages, attachments) targets exactly one peer
                // per user action. Unpaced, a user with a large contact
                // list changing their avatar could exhaust the server's
                // shared per-IP general rate-limit bucket and start
                // getting OTHER unrelated requests (a WS reconnect, a
                // normal chat send) throttled with it. This broadcast has
                // no urgency the user can observe (their own avatar
                // already updated locally; a peer who misses this round
                // still gets it opportunistically on the next real
                // message exchange via maybeAnnounceAvatarTo), so pace it
                // well under the server's sustained refill rate rather
                // than bursting.
                if index < peers.count - 1 {
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                }
            }
        }
    }

    /// Opportunistic avatar delivery: called after ANY event that proves a
    /// real pairwise PSK exists with `peerId` right now — a successful chat
    /// decrypt, a call reaching the connected state, or a completed
    /// `ContactKeyExchange`. Delegates to `AvatarAnnounceCoordinator`,
    /// which owns the version guard, the per-trigger cooldown, the per-peer
    /// serialisation and the sent-version bookkeeping (a direct port of
    /// Android's class of the same name — see its doc for why each of those
    /// is load-bearing and which of them iOS was missing).
    ///
    /// `trigger` is what decides the re-announce cooldown, so it must
    /// reflect the REAL cause: a call is rare and explicit and gets a
    /// 2-minute floor, while the chat-decrypt path can fire many times a
    /// minute and keeps 1 hour.
    private func maybeAnnounceAvatarTo(
        _ peerId: String,
        trigger: AvatarAnnounceCoordinator.Trigger = .chatDecrypt
    ) {
        avatarAnnounceCoordinator.maybeAnnounce(to: peerId, trigger: trigger)
    }

    /// Downloads + decrypts an inbound `avatar_announce` and caches the
    /// plaintext locally. Delegates to `AvatarAnnounceCoordinator`, which
    /// serialises per sender and re-checks the version INSIDE that
    /// serialisation — the caller's own pre-check is only an optimisation
    /// to avoid queueing work for an announce that is already stale.
    private func handleInboundAvatarAnnounce(_ envelope: AvatarAnnounceEnvelope, senderId: String) {
        avatarAnnounceCoordinator.handleInbound(envelope, senderId: senderId)
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
    /// W-GRPMSG: single-frame group TEXT send request from
    /// GroupChatScreen.sendGroupOverWire. userInfo:
    ///   - "groupId": String (dashed lowercase UUID — the server wire id)
    ///   - "wire": Data (raw 0xE4 group envelope)
    ///   - "clientMsgId": String
    ///   - "groupEpoch": Int
    /// AppState observes this and ships ONE `group_msg_send` frame
    /// (the server fans out to every member + echoes back to us).
    /// Replaces the retired per-member opaque_message fan-out (W372).
    static let groupMsgSendNotification = Notification.Name("qaudion.group.msgSend")
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

    /// Fase 2 — group typing indicator, relayed from the WS `group_typing`
    /// handler in `wireIncomingChatHandlers`. userInfo:
    ///   - "groupHex": String (hex, no dashes — GroupMessageStore/Registry key)
    ///   - "senderId": String
    ///   - "isTyping": Bool
    /// `GroupChatScreen` subscribes filtered by its own `groupHex`, mirroring
    /// `chatTypingNotification`'s 1:1 contract.
    static let groupTypingNotification = Notification.Name("qaudion.group.typing")

    /// W-BGK: BGAppRefreshTask notification. QAudionApp.init() posts this when
    /// iOS fires the ws-keepalive background task; AppState.handleWsKeepaliveTask
    /// is the observer.
    static let bgWsKeepalive = Notification.Name("com.bcrypto.qaudion.bgWsKeepalive")

    /// W-NOCALLKIT: standard APNs device token delivered. AppDelegate
    /// (`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`) posts
    /// this with the hex token as `object`; AppState registers it server-side
    /// only when `CallsGate.callKitFreeMode` (alert-push for incoming calls).
    static let apnsTokenReceived = Notification.Name("com.bcrypto.qaudion.apnsTokenReceived")

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
            // Publish user-level identity key so callee devices can verify the
            // caller via GET /api/v1/users/{id}/identity-key. Without this the
            // callee (Android) receives 404 and hangs up ~1 s after answering.
            // Best-effort: a transient failure here must not block calls.
            //
            // ROOT-CAUSE FIX (2026-06-23, cross-platform call reject): publish
            // the SOVEREIGN Ed25519 signing key — the EXACT same key used to
            // sign the call handshake (see configureHandshakeSigning:
            // `integration.localSignerIdentityKey = identityManager
            // .loadIdentity()?.signingPublic`). Previously this published the
            // DeviceKeyManager DEVICE key (`manager.currentEd25519Pub()`), a
            // different keypair. A peer (Android/Desktop) GETting our
            // identity-key then received the device key while our signed bundle
            // carried the sovereign key → `bundleKey != trustedKey` →
            // `identity_key_mismatch` abort at HandshakeSigningPolicy:129 BEFORE
            // the signature was even checked → call rejected ~immediately.
            // Sourcing both publish and sign from `sovereignIdentity
            // .loadIdentity()?.signingPublic` makes them a single source of
            // truth so a peer's verify reaches the real Ed25519 signature check.
            if let signingPub = sovereignIdentity.loadIdentity()?.signingPublic,
               signingPub.count == 32,
               let deviceId = UserDefaults.standard.string(forKey: "com.qaudion.auth.device_id"),
               !deviceId.isEmpty {
                do {
                    try await provider.kmsClient.publishUserIdentityKey(ed25519PubKey: signingPub, deviceId: deviceId)
                } catch {
                    print("[AppState] identity key publish failed (non-fatal): \(error)")
                }
            }
            // CL-5.4 — wire the earbud relay so hw_only/earbud_pair keys are
            // forwarded to the SE via GATT rather than attempting SW decryption.
            let relay = EarbudAckPopRelay(gatt: earbudGattProxy)
            let poller = KmsPollerService(kmsClient: provider.kmsClient, vault: vault, earbudRelay: relay)
            // ROOT-CAUSE FIX (W-KMSV2CTX): this was the ONLY production call
            // to pollOnce and never passed v2Context, so
            // KmsPollerService.route(for:) sent EVERY non-legacy, non-earbud
            // KMS delivery (protoVersion >= 2, keyType != "sovereign" — i.e.
            // any modern phone-held key, which is the server's default today)
            // down the .v2PhoneHeld branch, which immediately throws
            // `missingV2Context` (KmsPollerService.swift:89) before ever
            // decrypting/storing/acknowledging. Server-side this looks like
            // "delivered" forever (GET marks delivered unconditionally) with
            // no acknowledge — exactly the symptom reported: KMS key shows
            // delivered, never acknowledged, never usable in a call. Building
            // a real V2Context from the logged-in user + this device's own
            // auth device_id (already used above for identity-key publish)
            // unblocks the v2PhoneHeld path; entry.userId/entry.deviceId
            // (server-authoritative) still win whenever the pending entry
            // carries them, so this is only the fallback the guard needs to
            // even attempt the branch.
            var v2Context: KmsPollerService.V2Context? = nil
            if let userIdStr = currentUserId, let userUuid = UUID(uuidString: userIdStr),
               let deviceIdStr = UserDefaults.standard.string(forKey: "com.qaudion.auth.device_id"),
               let deviceUuid = UUID(uuidString: deviceIdStr) {
                v2Context = KmsPollerService.V2Context(
                    userId: userUuid, deviceId: deviceUuid, serverId: CryptoConstants.kmsServerId())
            } else {
                print("[AppState] KMS sweep: missing userId/deviceId — v2PhoneHeld entries will fail closed this sweep")
            }
            let stats = try await poller.pollOnce(deviceKeys: keys, v2Context: v2Context)
            if stats.processed > 0 {
                print("[AppState] KMS sweep: processed=\(stats.processed) stored=\(stats.stored) acked=\(stats.acknowledged) decryptFailed=\(stats.decryptFailed) ackFailed=\(stats.ackFailed)")
            }
            // 2026-05-06 session-renewal Phase 2 — wire the Ed25519
            // device-bound silent re-auth fallback into the REST client.
            // From now on a 401 from /auth/refresh (or a missing refresh
            // token) cascades to /auth/device-renew before
            // BCryptoError.unauthorized surfaces. Mirror of the Android
            // SessionRenewerImpl Phase-1+Phase-2 cascade.
            //
            // FORCED-QR FIX (2026-06-24): this now delegates to the shared
            // `wireDeviceRenewFallback(on:)` helper (which the cold-start
            // launch path also calls at provider-build time). Idempotent —
            // `setDeviceRenewFallback` just overwrites the closure. Also
            // (re)arms the proactive-refresh timer now that the live
            // provider + device credential are confirmed available.
            wireDeviceRenewFallback(on: provider)
            scheduleProactiveTokenRefresh()
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
                Task { [weak self] in
                    await cke.handleOffer(senderId: senderId, peerPubKey: pub)
                    // Trigger `.keyExchange` — as rare and as explicit as a
                    // call, so it gets the SHORT re-announce cooldown, not
                    // the background chat-decrypt one.
                    // E2EE avatar transport (2026-07-30) — the moment a
                    // pairwise PSK becomes available for this peer (for
                    // ANY reason: a call just triggered this exchange, a
                    // manual re-sync, whatever) is exactly the moment
                    // Pavel wants an avatar exchange to fire, not only on
                    // the NEXT chat message. Safe no-op if the derive
                    // above actually failed (maybeAnnounceAvatarTo fails
                    // closed on a missing PSK).
                    await self?.maybeAnnounceAvatarTo(senderId, trigger: .keyExchange)
                }
            case .keyExchangeAccept(let pub):
                Task { [weak self] in
                    await cke.handleAccept(senderId: senderId, peerPubKey: pub)
                    await self?.maybeAnnounceAvatarTo(senderId, trigger: .keyExchange)
                }
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
            // Self-echo guard (see OpaqueSelfEchoFilter doc) — bcrypto-lite
            // bounces every opaque_message back to its own sender with
            // sender_id rewritten to the recipient, so identity comparison
            // can't catch this here; content-fingerprint the raw wire
            // string instead. Dropped silently, same as any other
            // malformed/unexpected piggy-back on this channel.
            if OpaqueSelfEchoFilter.shared.shouldDropInbound(blobStr) {
                print("[AppState] piggy-back dropped as self-echo: \(blobStr.prefix(48))…")
                return
            }
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

        // Path D — W-GRPKMSPB / gap A2: `qa_kms_prebootstrap:1` envelope
        // wrapper. Wire shape `{"qa_kms":1,"env_b64":"<base64 CBOR
        // envelope>"}` — checked BEFORE Path C's `qa_grpcall_ctrl` because
        // this envelope travels UNWRAPPED: no further 1:1-ratchet
        // encryption, the envelope is already self-authenticating via its
        // own Ed25519 transcript signature. Mirrors Android's
        // `GroupCallController.onOpaqueMessage`'s `qa_kms` branch, which is
        // also checked before `qa_grpcall_ctrl` there. On success this
        // feeds the SAME `onGroupCallControlEnvelope(json:fromUserId:)`
        // terminal call Path C makes below.
        if let obj = try? JSONSerialization.jsonObject(with: Data(blobStr.utf8)) as? [String: Any],
           (obj["qa_kms"] as? NSNumber)?.intValue == 1,
           let envB64 = obj["env_b64"] as? String,
           let envelopeBytes = Data(base64Encoded: envB64) {
            let selfId = currentUserId ?? ""
            guard let kmsClient = liveProvider?.kmsClient, !selfId.isEmpty else {
                print("[GroupCallController][telemetry] ctrl envelope RECEIVE FAILED sender=\(senderId.prefix(8)) reason=kms_prebootstrap_no_provider")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let decoded = await AppState.decodeKmsPreBootstrapEnvelope(
                    envelopeBytes: envelopeBytes, senderId: senderId, selfId: selfId, kmsClient: kmsClient
                ) else {
                    print("[GroupCallController][telemetry] ctrl envelope RECEIVE FAILED sender=\(senderId.prefix(8)) reason=kms_prebootstrap_consume_failed")
                    return
                }
                print("[GroupCallController][telemetry] ctrl envelope RECEIVED+decrypted(prebootstrap) sender=\(senderId.prefix(8)), forwarding to GroupCallController")
                self.groupCallController?.onGroupCallControlEnvelope(json: decoded, fromUserId: senderId)
            }
            return
        }

        // Path C — W-GRPSENDERKEY group-call control envelope. Wire shape
        // `{"qa_grpcall_ctrl":1,"cmid":"...","blob":"<base64 1:1-ratchet
        // wire>"}` — a distinct top-level key from every other opaque_message
        // consumer above AND from chat's own `qa_grp:1` (which rides the
        // regular msg_send channel via `handleIncomingMessage`, not
        // opaque_message). Decrypted inline via the SAME shared
        // `Self.sharedV4Ratchet`/`Self.ratchet` instances chat uses (not a
        // separate MessageRatchet — see GroupCallController.swift's
        // "Control-envelope transport" comment for why that was a bug).
        if let obj = try? JSONSerialization.jsonObject(with: Data(blobStr.utf8)) as? [String: Any],
           (obj["qa_grpcall_ctrl"] as? NSNumber)?.intValue == 1,
           let cmid = obj["cmid"] as? String,
           let blobB64 = obj["blob"] as? String,
           let wire = Data(base64Encoded: blobB64) {
            let selfId = currentUserId ?? ""
            let json: String?
            // W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): this is the
            // receive-side mirror of `onSendControlEnvelope`'s new logging
            // above — a decrypt failure HERE means the sender's envelope
            // (which the sender-side log confirms was actually shipped)
            // never reaches `GroupCallController.onGroupCallControlEnvelope`
            // at all, silently, with no prior trace anywhere. Distinguishing
            // "sent OK but couldn't be opened here" from "never sent" is
            // exactly the missing piece the 2026-07-15 recon flagged as an
            // unresolved residual for the S26<->iOS leg of this incident.
            // W-GRPCTRL-PARITY (2026-07-20, call FB75E465): version-triage
            // exactly like Desktop's `handleGroupCtrlOpaque` — v4 by magic;
            // v3/v2 parse the epoch tag FROM THE WIRE and look the PSK up BY
            // NAME (with the contact-bound ladder as fallback for
            // sender-local names like `auto:*` and for legacy 'v1'-epoch
            // wires from not-yet-updated iOS peers). The old code force-
            // opened every non-v4 wire with the hardcoded session epoch 'v1'
            // + the PSK ladder: an epoch-named wire (what Desktop/Android
            // actually send — e.g. Desktop's "v2 AEAD epoch=auto:…" seal to
            // this exact iPhone in call FB75E465) failed in silence
            // (epochMismatch / wrong AAD, logged only as v1_decrypt_failed).
            switch MessageWireFormat.detect(wire) {
            case .v4:
                json = Self.sharedV4Ratchet.decryptV4Routed(peerId: senderId, frame: wire)
                    .flatMap { String(data: $0, encoding: .utf8) }
                if json == nil {
                    print("[GroupCallController][telemetry] ctrl envelope RECEIVE FAILED sender=\(senderId.prefix(8)) cmid=\(cmid.prefix(8)) reason=v4_decrypt_failed")
                }
            case .v3:
                // Wire layout (MessageRatchet spec §2): magic(1) |
                // epoch_len(1) | epoch(L) | … — parse only the epoch here,
                // the ratchet re-validates the full frame.
                let base = wire.startIndex
                let epochLen = wire.count >= 2 ? Int(wire[base + 1]) : 0
                if epochLen >= 1, wire.count >= 2 + epochLen,
                   let epochTag = String(data: wire.subdata(in: (base + 2)..<(base + 2 + epochLen)), encoding: .utf8) {
                    // W-GRPCTRLPSKSWEEP — TRY each candidate; a single best
                    // guess never matched Desktop. See groupCtrlPskCandidates.
                    // W-GRPCTRLPSKSWEEP2 (2026-07-28) — the earlier sweep here
                    // was INERT and this is why. It called `ensureSession`,
                    // which is snapshot-first: once a snapshot exists for
                    // (epochTag, sender) it returns THAT and ignores pskRoot,
                    // so all N candidates collapsed onto one cached session and
                    // re-ran the identical decrypt N times (measured live:
                    // `tried=68/68`, 0 successes). Worse, `ensureSession`
                    // PERSISTS on a miss, so iOS's very first Desktop envelope
                    // — which fell through to the wrong `auto:` root — wrote a
                    // poisoned session into the Keychain permanently: 43
                    // failures, 0 successes, ever.
                    //
                    // Correct order: try the ESTABLISHED session first (the
                    // normal path, and the only one that carries chain state
                    // forward), then genuinely distinct roots derived WITHOUT
                    // touching the vault. `decrypt` persists whichever session
                    // actually opens the frame, so a winning candidate becomes
                    // the established session from then on and the poisoned
                    // snapshot is replaced rather than worked around.
                    let aadV3 = MessageRatchet.buildMessageAD(
                        senderId: senderId, recipientId: selfId, clientMsgId: cmid)
                    var opened: String?
                    var attempted = 0
                    if let stored = Self.ratchet.existingSession(
                        epochId: epochTag, peerId: senderId) {
                        attempted += 1
                        opened = Self.ratchet.decrypt(session: stored, wire: wire, aad: aadV3)
                            .flatMap { String(data: $0, encoding: .utf8) }
                    }
                    let candidates = opened == nil
                        ? Self.groupCtrlPskCandidates(epochTag: epochTag, sender: senderId)
                        : []
                    if opened == nil {
                        for psk in candidates {
                            guard let session = try? Self.ratchet.deriveSessionUnpersisted(
                                epochId: epochTag, selfId: selfId, peerId: senderId,
                                pskRoot: psk) else { continue }
                            attempted += 1
                            if let plain = Self.ratchet.decrypt(session: session, wire: wire, aad: aadV3)
                                .flatMap({ String(data: $0, encoding: .utf8) }) {
                                opened = plain
                                break
                            }
                        }
                    }
                    json = opened
                    if json == nil {
                        let reason = candidates.isEmpty ? "v3_no_psk_for_epoch"
                            : (attempted == 0 ? "v3_ensure_session_failed" : "v3_decrypt_failed")
                        print("[GroupCallController][telemetry] ctrl envelope RECEIVE FAILED sender=\(senderId.prefix(8)) cmid=\(cmid.prefix(8)) reason=\(reason) epoch=\(epochTag.prefix(16)) tried=\(attempted)/\(candidates.count)")
                    }
                } else {
                    json = nil
                    print("[GroupCallController][telemetry] ctrl envelope RECEIVE FAILED sender=\(senderId.prefix(8)) cmid=\(cmid.prefix(8)) reason=v3_wire_malformed len=\(wire.count)")
                }
            case .v2:
                // v2 (0xE2 epoch-routed) — sealed with the CHANNEL AAD
                // `grpcall-ctrl:<sender>:<recipient>`, NOT chat's `msg:`
                // AAD (Android `sendControlEnvelope` / Desktop's v2 open
                // branch — and our own send side above).
                let aad = Data("grpcall-ctrl:\(senderId):\(selfId)".utf8)
                if let parsed = try? MessageCryptoV2.parse(wire) {
                    // W-GRPCTRLPSKSWEEP — TRY each candidate (see the v3 branch
                    // above and groupCtrlPskCandidates for why one guess never
                    // matched Desktop). This is the branch Desktop actually
                    // uses: its transport tag on the wire is `v2:auto:...`.
                    let candidates = Self.groupCtrlPskCandidates(epochTag: parsed.epoch, sender: senderId)
                    var opened: String?
                    for psk in candidates {
                        if let plain = MessageCryptoV2.openWithPsk(parsed: parsed, psk: psk, aad: aad)
                            .flatMap({ String(data: $0, encoding: .utf8) }) {
                            opened = plain
                            break
                        }
                    }
                    json = opened
                    if json == nil {
                        let reason = candidates.isEmpty ? "v2_no_psk_for_epoch" : "v2_decrypt_failed"
                        print("[GroupCallController][telemetry] ctrl envelope RECEIVE FAILED sender=\(senderId.prefix(8)) cmid=\(cmid.prefix(8)) reason=\(reason) epoch=\(parsed.epoch.prefix(16)) tried=\(candidates.count)")
                    }
                } else {
                    json = nil
                    print("[GroupCallController][telemetry] ctrl envelope RECEIVE FAILED sender=\(senderId.prefix(8)) cmid=\(cmid.prefix(8)) reason=v2_wire_malformed len=\(wire.count)")
                }
            case .v1:
                // No group-ctrl sender emits the magic-less legacy v1 wire
                // on this channel (Android seals v2+, Desktop v2+, iOS
                // v2/v4) — log rather than guess at a PSK/AAD pair.
                json = nil
                print("[GroupCallController][telemetry] ctrl envelope RECEIVE FAILED sender=\(senderId.prefix(8)) cmid=\(cmid.prefix(8)) reason=unsupported_legacy_v1_wire len=\(wire.count)")
            }
            if let json = json {
                print("[GroupCallController][telemetry] ctrl envelope RECEIVED+decrypted sender=\(senderId.prefix(8)) cmid=\(cmid.prefix(8)), forwarding to GroupCallController")
                groupCallController?.onGroupCallControlEnvelope(json: json, fromUserId: senderId)
            }
            return
        }

        print("[AppState] opaque_message from \(senderId.prefix(8))… not a valid QUAD frame and not a recognised Android envelope (\(blobStr.count) bytes)")
    }

    /// DISPLAY-ONLY: resolve the human name + method label for a negotiated
    /// PSK fingerprint by looking it up in the device's own
    /// `SovereignKeyVault`. Pure UI helper — never throws, never affects
    /// derivation.
    ///
    /// KMS-delivered keys: `KmsPollerService` stores the PSK under a UUID
    /// account name (the server keyId) AND a sidecar `__kmsname.<fp>` entry
    /// carrying the human key name. So we FIRST try that sidecar (method
    /// "KMS" + the real server name). Otherwise we match the fingerprint to
    /// a stored PSK account: a UUID account name => "KMS" (no sidecar name
    /// => short fingerprint), else a human-imported key (name + KeyClass).
    static func resolvePskDisplayMeta(fingerprint: String?) -> (name: String?, method: String?) {
        guard let fp = fingerprint, !fp.isEmpty else { return (nil, nil) }
        let vault = SovereignKeyVault()
        // 1. KMS sidecar: human key name persisted at delivery, keyed by fp.
        if let d = (try? vault.loadPsk(name: "__kmsname.\(fp)")) ?? nil,
           let nm = String(data: d, encoding: .utf8), !nm.isEmpty {
            return (nm, "KMS")
        }
        // 2. Match the fingerprint to a stored PSK account (skip sidecars).
        let matchedName: String? = vault.listPskNames().first { n in
            if n.hasPrefix("__") { return false }
            // W-PSKMIX step 6 — same `.callDerived` exclusion the receive-side
            // matching gates apply (step 5, 34d111d): a peer-echoed
            // fingerprint must never resolve to the "auto:<prefix>:<peerId>"
            // group-control-channel ratchet seed (or Android's "call-"/
            // "msg-psk" rows) here either. This function is DISPLAY-only —
            // exclusion here only ever changes what the in-call key panel
            // shows for an unpatched/malicious peer's replayed fingerprint,
            // never a real call (a fixed client never advertises one).
            guard PskAdvertising.isEligibleMatchCandidate(origin: vault.origin(name: n)) else { return false }
            // W-STALEFP — recompute fresh from the raw material, never trust
            // `vault.getFingerprint(name:)` (the cached Keychain label) for a
            // wire match: an entry written before `PskAdvertising.canonicalFingerprint`
            // became the label at write time (any pre-1f336b3 NFC import, and
            // every non-NFC path that never persisted an origin/label
            // deliberately) can carry a label that is NOT SHA-256(material) —
            // e.g. an NFC entry's label used to be `hex(peerIdPub)`. Matching
            // against that stale label silently fails to find an entry whose
            // real bytes DO match the peer's fingerprint.
            guard let raw = (try? vault.loadPsk(name: n)) ?? nil, !raw.isEmpty else { return false }
            return PskAdvertising.canonicalFingerprint(forPsk: raw) == fp
        }
        guard let name = matchedName else {
            // W-PSKMIX — bare log only (this stays a pure, never-throwing UI
            // helper — no behavior change). Previously silent: a non-empty
            // fingerprint with no matching vault entry fell straight through
            // to the short-fingerprint-prefix/nil-method fallback below with
            // no trace anywhere. Worth a log because this is the same shape
            // as an unpatched/malicious peer's replayed fingerprint (see the
            // `.callDerived` exclusion note above) or a genuine local-vault
            // miss — either way, "PSK negotiated but nothing to show/reuse
            // for it" deserves to be visible in device logs.
            print("[AppState] resolvePskDisplayMeta: no local vault entry matches fp=\(fp.prefix(16))… — no name/method to show")
            // W-UNIFORMKEYINFO — canonical spec: never synthesize a display name
            // from fingerprint bytes. `name: nil` makes the UI show the shared
            // "(unnamed key)" placeholder (matches Android's/Desktop's honest
            // last-resort), instead of a hex fragment that looks like a name.
            return (nil, nil)
        }
        let isUuidName: Bool = (UUID(uuidString: name) != nil)
        let method: String
        if isUuidName {
            method = "KMS"
        } else {
            // W-NFCBIND — provenance first, storage class second. Before this,
            // an NFC-derived key fell through `getKeyClass` to the generic
            // "PSK" bucket, so the in-call security sheet could never tell the
            // user that this call's secret came from a physical tap. The class
            // is still what shows for everything else: it is the right label
            // for a KMS/earbud key, and "HW" carries information "PSK" does not.
            switch vault.origin(name: name) {
            case .nfc:
                method = "NFC"
            case .qr, .manual, .kms, .callDerived, .deviceInternal, .identityKey:
                switch vault.getKeyClass(name: name) {
                case .hwOnly: method = "HW"
                case .swOnly: method = "SW"
                case .shared: method = "PSK"
                }
            }
        }
        // W-UNIFORMKEYINFO — canonical spec: a UUID-named (KMS) entry that
        // reaches here means the `__kmsname.<fp>` sidecar lookup above (the
        // server's real human key_name) already missed — never fall back to
        // a fingerprint slice disguised as a name. `nil` -> UI shows the
        // shared "(unnamed key)" placeholder, same as Android/Desktop's
        // honest last-resort when the server sent no name.
        let displayName: String? = isUuidName ? nil : name
        return (displayName, method)
    }

    /// vkey-v1 — resolve the raw PSK key bytes for a negotiated fingerprint
    /// from the sovereign/KMS vault, so iOS can feed the same `psk` salt into
    /// `deriveVideoKey` that Android used (PqcHandshake.kt:674). Returns nil
    /// when no stored key matches the fingerprint — the caller then leaves
    /// `videoContactPsk` nil and both peers fall back to the default video
    /// salt (matches Android's `psk == null` branch). Mirrors the lookup in
    /// ``resolvePskDisplayMeta(fingerprint:)`` but returns the key material.
    static func resolvePskBytes(fingerprint: String?) -> Data? {
        guard let fp = fingerprint, !fp.isEmpty else { return nil }
        let vault = SovereignKeyVault()
        let matchedName: String? = vault.listPskNames().first { n in
            if n.hasPrefix("__") { return false }
            // W-PSKMIX step 6 — this is the SEVERE twin of step 5's receive-
            // side exclusion: unlike the audio-PSK matching gates (which only
            // decide WHICH stored PSK a call uses), this function's return
            // value is fed directly into `deriveVideoKey`'s HKDF *salt*
            // (`videoContactPsk` → `QAudionCallIntegration.deriveVideoKey`,
            // salt = psk when non-nil/non-empty). Letting a `.callDerived`
            // entry's raw bytes (the group-control-channel ratchet seed
            // material) ever match here would mix that forward-secret
            // ratchet's key material directly into a video-call key
            // derivation — coupling two crypto domains that must stay
            // independent. A fixed peer never advertises a `.callDerived`
            // fingerprint (771f4c1), so this is defense-in-depth against an
            // unpatched/malicious peer or a future advertise-side
            // regression, exactly like step 5's audio-PSK gates — nil is
            // already the documented safe fallback (both peers then use the
            // default video salt, matching Android's `psk == null` branch),
            // so excluding this candidate never breaks an ordinary call.
            guard PskAdvertising.isEligibleMatchCandidate(origin: vault.origin(name: n)) else { return false }
            // W-STALEFP — see resolvePskDisplayMeta's identical comment above.
            guard let raw = (try? vault.loadPsk(name: n)) ?? nil, !raw.isEmpty else { return false }
            return PskAdvertising.canonicalFingerprint(forPsk: raw) == fp
        }
        guard let name = matchedName else { return nil }
        return (try? vault.loadPsk(name: name)) ?? nil
    }

    /// W-NFCIDBIND (2026-07-29) — the peer's Ed25519 identity pubkey captured
    /// at NFC-tap time for the vault entry matching `fingerprint`, or `nil`
    /// when there is no match or the matched entry never recorded one (every
    /// non-NFC entry, and any NFC entry written before this field existed).
    ///
    /// Feeds `AssuranceState.resolveNfcMixInputs`'s `capturedPeerIdentityKey`.
    /// Previously that function was handed `fingerprint` itself under the
    /// (false) assumption that an NFC entry's fingerprint label WAS the
    /// captured identity — it is `lc_hex(SHA-256(psk))` on every real code
    /// path, an entirely different 32 bytes, so that comparison could never
    /// succeed and every NFC-selected call landed on a false S3 identity-
    /// mismatch instead of S2. Mirrors `resolvePskDisplayMeta`'s matching
    /// shape rather than sharing it, same convention as `resolvePskBytes`
    /// just above.
    static func resolveNfcPeerIdentityKey(fingerprint: String?) -> Data? {
        guard let fp = fingerprint, !fp.isEmpty else { return nil }
        let vault = SovereignKeyVault()
        let matchedName: String? = vault.listPskNames().first { n in
            if n.hasPrefix("__") { return false }
            guard PskAdvertising.isEligibleMatchCandidate(origin: vault.origin(name: n)) else { return false }
            // W-STALEFP — see resolvePskDisplayMeta's identical comment above.
            guard let raw = (try? vault.loadPsk(name: n)) ?? nil, !raw.isEmpty else { return false }
            return PskAdvertising.canonicalFingerprint(forPsk: raw) == fp
        }
        guard let name = matchedName else { return nil }
        return vault.nfcPeerIdentityKey(name: name)
    }

    /// Responder-side dispatch for Android JSON OFFER. Symmetric to
    /// `routeInboundPqcOffer` but consumes the Android wire format
    /// directly via `QAudionCallIntegration.onAndroidBundleReceived`.
    @MainActor
    private func routeInboundAndroidOffer(parsed: AndroidHandshakeEnvelope.Parsed, senderId: String) {
        // Sender-identity check (2026-07-11 — same reasoning/fix as
        // routeInboundPqcOffer above; sibling dispatch for the
        // Android-JSON-envelope OFFER format, same missing guard.
        if let expected = callContactId {
            guard expected == senderId else {
                print("[AppState] Android OFFER REJECTED — senderId=\(senderId.prefix(8))… does not match established callContactId=\(expected.prefix(8))…")
                return
            }
        } else {
            // W-OFFERBUFFER — callContactId not set yet (this OFFER arrived
            // before call_incoming). Buffer; replayed only if callContactId
            // is later set to this exact senderId, never otherwise.
            print("[AppState] Android OFFER buffered — callContactId not yet set, waiting for call_incoming from \(senderId.prefix(8))…")
            bufferOfferReplay(senderId: senderId) { [weak self] in
                self?.routeInboundAndroidOffer(parsed: parsed, senderId: senderId)
            }
            return
        }
        let integration = ensureResponderIntegration(forCaller: senderId)
        // D11: the OFFER opaque carries no device id; use the one stamped on the
        // matching `call_incoming` envelope (stashed by sender_id). nil ⇒ legacy.
        let senderDeviceId = senderDeviceIdByPeer[senderId]
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
                let vault = SovereignKeyVault()
                let eligiblePsks: [String: Data] = Dictionary(
                    vault.listPskNames().compactMap { name -> (String, Data)? in
                        // W574m — skip the device's own long-term identity keys
                        // (__device.x25519/.mlkem/.ed25519, all tagged with the
                        // CONSTANT "device-key" fingerprint). They are NOT per-peer
                        // call PSKs — no peer ever advertises "device-key", so they
                        // can never be selected at line ~851 — but keying all six by
                        // that one shared fingerprint trapped Dictionary init
                        // ("Fatal error: Duplicate values for key: 'device-key'")
                        // → SIGTRAP that crashed the callee mid-handshake, so the
                        // two phones never connected.
                        guard !name.hasPrefix("__device.") else { return nil }
                        // W-PSKMIX step 5 — same `.callDerived` exclusion
                        // `PskAdvertising.fingerprintsForAdvertisement` applies on
                        // the advertise side (771f4c1): Android's "call-"/"msg-psk"
                        // rows and iOS's own "auto:<prefix>:<peerId>" group-control-
                        // channel ratchet seed must never become a candidate 1:1-
                        // call audio PSK here either. This is the RESPONDER's
                        // eligibility catalogue, matched against the peer's OFFER-
                        // advertised fingerprint list inside onAndroidBundleReceived
                        // — a fixed client no longer advertises a `.callDerived`
                        // fingerprint, but an unpatched peer, a future regression in
                        // the advertise-side filter, or a build predating that fix
                        // could still put one on the wire, so this side must
                        // independently refuse to treat it as eligible rather than
                        // trust the sender to withhold it.
                        guard PskAdvertising.isEligibleMatchCandidate(origin: vault.origin(name: name)) else { return nil }
                        // W-STALEFP — the fingerprint that keys this catalogue MUST be
                        // recomputed fresh from the raw material, never read from
                        // `vault.getFingerprint(name:)` (the cached Keychain label): an
                        // entry whose label predates `PskAdvertising.canonicalFingerprint`
                        // becoming the write-time label (any pre-1f336b3 NFC import) can
                        // carry a label that is NOT SHA-256(material) — e.g. an NFC
                        // entry's label used to be `hex(peerIdPub)`. Keying this
                        // dictionary by that stale label means the peer's true
                        // fingerprint never hits, so a genuinely shared NFC PSK is
                        // silently dropped and the call converges to no-PSK instead of
                        // actually mixing the secret both devices hold.
                        guard let raw = (try? vault.loadPsk(name: name)) ?? nil,
                              !raw.isEmpty else { return nil }
                        let fp = PskAdvertising.canonicalFingerprint(forPsk: raw)
                        return (fp, raw)
                    },
                    // Belt-and-suspenders: tolerate any future duplicate fingerprint
                    // instead of trapping (keep the first match).
                    uniquingKeysWith: { first, _ in first }
                )
                try await integration.onAndroidBundleReceived(
                    bundle: parsed.bundle,
                    callId: parsed.callId,
                    callerId: senderId,
                    // D11: per-device verdict. nil ⇒ legacy single-key + set
                    // membership (never a fatal mismatch).
                    callerDeviceId: senderDeviceId,
                    eligiblePsks: eligiblePsks,
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
        // Sender-identity check (2026-07-11 — same reasoning/fix as
        // routeInboundPqcAccept above; sibling dispatch for the
        // Android-JSON ACCEPT format, same missing guard.
        guard let expected = callContactId, expected == senderId else {
            print("[AppState] Android ACCEPT REJECTED — senderId=\(senderId.prefix(8))… does not match callContactId=\(callContactId?.prefix(8) ?? "nil")")
            return
        }
        guard let integration = callService.callIntegration else {
            print("[AppState] Android ACCEPT arrived from \(senderId.prefix(8))… but callService.callIntegration is nil — call already ended or ACCEPT arrived after teardown")
            return
        }
        // W461: diagnostic — log the callId as received so we can detect
        // case mismatches (iOS uppercase UUID vs Android lowercase echo).
        let intState: String = String(describing: integration.getState())
        print("[AppState] Android ACCEPT callId=\(parsed.callId.prefix(8))… from \(senderId.prefix(8))… integration.state=\(intState)")
        // D11: the ACCEPT (answer leg) carries no server-stamped device id — the
        // caller never receives a `call_incoming` for the callee's device — so
        // this is typically nil ⇒ legacy single-key + set-membership floor (the
        // callee's key ∈ its published set), NEVER a fatal mismatch. We still pass
        // any stash we happen to hold for symmetry.
        let senderDeviceId = senderDeviceIdByPeer[senderId]
        let sendOpaqueRaw: (String) async throws -> Void = { [weak self] wireString in
            guard let provider = await MainActor.run(body: { self?.liveProvider }) else { return }
            let payload = wireString.data(using: .utf8) ?? Data()
            try await provider.callingApi.sendOpaqueMessage(
                recipientId: senderId, data: payload)
        }
        Task {
            do {
                let vault = SovereignKeyVault()
                let eligiblePsks: [String: Data] = Dictionary(
                    vault.listPskNames().compactMap { name -> (String, Data)? in
                        // W574m — skip the device's own long-term identity keys
                        // (__device.x25519/.mlkem/.ed25519, all tagged with the
                        // CONSTANT "device-key" fingerprint). They are NOT per-peer
                        // call PSKs — no peer ever advertises "device-key", so they
                        // can never be selected at line ~851 — but keying all six by
                        // that one shared fingerprint trapped Dictionary init
                        // ("Fatal error: Duplicate values for key: 'device-key'")
                        // → SIGTRAP that crashed the callee mid-handshake, so the
                        // two phones never connected.
                        guard !name.hasPrefix("__device.") else { return nil }
                        // W-PSKMIX step 5 — same `.callDerived` exclusion
                        // `PskAdvertising.fingerprintsForAdvertisement` applies on
                        // the advertise side (771f4c1): Android's "call-"/"msg-psk"
                        // rows and iOS's own "auto:<prefix>:<peerId>" group-control-
                        // channel ratchet seed must never become a candidate 1:1-
                        // call audio PSK here either. This is the caller's
                        // eligibility catalogue, matched against the callee's ACCEPT-
                        // advertised fingerprint list inside onAndroidBundleReceived
                        // — a fixed client no longer advertises a `.callDerived`
                        // fingerprint, but an unpatched peer, a future regression in
                        // the advertise-side filter, or a build predating that fix
                        // could still put one on the wire, so this side must
                        // independently refuse to treat it as eligible rather than
                        // trust the sender to withhold it.
                        guard PskAdvertising.isEligibleMatchCandidate(origin: vault.origin(name: name)) else { return nil }
                        // W-STALEFP — same fresh-recompute fix as routeInboundAndroidOffer's
                        // identical catalogue above; see that comment for the full
                        // rationale (a cached Keychain label can predate
                        // PskAdvertising.canonicalFingerprint becoming the write-time
                        // label and so not equal SHA-256(material)).
                        guard let raw = (try? vault.loadPsk(name: name)) ?? nil,
                              !raw.isEmpty else { return nil }
                        let fp = PskAdvertising.canonicalFingerprint(forPsk: raw)
                        return (fp, raw)
                    },
                    // Belt-and-suspenders: tolerate any future duplicate fingerprint
                    // instead of trapping (keep the first match).
                    uniquingKeysWith: { first, _ in first }
                )
                try await integration.onAndroidBundleReceived(
                    bundle: parsed.bundle,
                    callId: parsed.callId,
                    // Phase-10b (d): thread the peer id into the ACCEPT path so
                    // the signature verify resolves the right peer identity. Was
                    // previously omitted (defaulted to ""), which left the .accept
                    // branch with no peer to verify against.
                    callerId: senderId,
                    callerDeviceId: senderDeviceId,
                    eligiblePsks: eligiblePsks,
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
        case .earbudPdu(let callId, let pdu):
            // earbud-relay-v1 — HSRESP fragments relayed by the
            // earbud-side phone. Sender must be the active call peer
            // (the coordinator additionally matches the callId).
            guard callContactId == senderId else {
                print("[AppState] EARBUDPDU dropped — sender \(senderId.prefix(8))… is not the call peer")
                return
            }
            earbudCounterparty.handleInbound(callId: callId, pdu: pdu)
        case .fpSet(let callId, let fpAdv):
            // Phase B — remote fp_adv for neg_digest computation.
            // Forward to whichever integration is active (caller or responder).
            // Sender guard mirrors EARBUDPDU: must be the current call peer.
            guard callContactId == senderId else {
                print("[AppState] FPSET dropped — sender \(senderId.prefix(8))… is not the call peer")
                return
            }
            let integration = callService.callIntegration ?? responderCallIntegration
            integration?.handleInboundFpSet(callId: callId, fpAdv: fpAdv)
            print("[AppState] FPSET received callId=\(callId.prefix(8))… from=\(senderId.prefix(8))…")
        case .earbudMkd(let callId, let pkg):
            // Phase 6: sealed PQ media key package from earbud-side phone.
            // Full KMS integration pending; guard sender and log.
            guard callContactId == senderId else {
                print("[AppState] EARBUDMKD dropped — sender not call peer")
                return
            }
            print("[AppState] EARBUDMKD callId=\(callId.prefix(8))… \(pkg.count)B")
        case .kcmac(let callId, let raw):
            // W-KCMAC (ship step 5) — upgraded from log-and-drop (step 2) to an
            // actual verify. Still PURE OBSERVATION: `handleInboundKcMac` only
            // ever records a telemetry verdict, never gates/drops the call.
            handleInboundKcMac(callId: callId, raw: raw, senderId: senderId)
        case .voiceKey(let callId, let enrolled):
            // "Voce come chiave" cross-device attestation — the peer's own
            // self-declared local enrollment state. Sender guard mirrors
            // EARBUDPDU/FPSET: only the current call's peer can update this.
            // Self-declared, never a crypto proof on its own — see
            // `callPeerVoiceKeyEnrolled`'s doc and the trust-bar shield's
            // tap-to-explain copy for the exact caveat shown to the user.
            guard callContactId == senderId else {
                print("[AppState] VOICE_KEY dropped — sender \(senderId.prefix(8))… is not the call peer")
                return
            }
            callPeerVoiceKeyEnrolled = enrolled
            print("[AppState] VOICE_KEY received callId=\(callId.prefix(8))… enrolled=\(enrolled) from=\(senderId.prefix(8))…")
        case .ownerContinuity(let callId, let level):
            // "Voce storica" — the peer's own live tri-state. Sender guard
            // mirrors VOICE_KEY/EARBUDPDU/FPSET: only the current call's
            // peer can update this.
            guard callContactId == senderId else {
                print("[AppState] OWNER_CONT dropped — sender \(senderId.prefix(8))… is not the call peer")
                return
            }
            let mapped: ContactVoiceContinuityGate.Level
            switch level {
            case "verified":  mapped = .verified
            case "uncertain": mapped = .uncertain
            case "mismatch":  mapped = .mismatch
            default:          mapped = .unknown
            }
            peerOwnerContinuityLevel = mapped
            print("[AppState] OWNER_CONT received callId=\(callId.prefix(8))… level=\(level) from=\(senderId.prefix(8))…")
        }
    }

    /// W-KCMAC (ship step 5) — fired from `QAudionCallIntegration.onKcMacReady`
    /// on BOTH the caller and responder legs, immediately after session-key
    /// derivation. Sends our own `kc_mac` (gated on the peer having advertised
    /// `pskMixV1`) and arms the 5000ms absent-deadline. W-NOBRICK: never
    /// throws/gates — every path below at worst leaves `kcStatus == .absent`.
    @MainActor
    private func handleKcMacReady(_ event: QAudionCallIntegration.KcMacReadyEvent) {
        let key = event.callId.lowercased()
        let state = KeyConfirmationCallState(event: event)
        kcCallStates[key] = state

        // Gate (per the design/task): only actually run the wire exchange when
        // the peer advertised pskMixV1 AND both sides could reconstruct a
        // transcript-v2 binding (step 4, both legs). Today (pskMixV1 default
        // false fleet-wide, step 7 not flipped) this branch is expected to be
        // the common case — record `.absent` immediately, no wire round-trip.
        guard event.peerSupportsMix, let kcKey = event.kcKey, let transcript = event.transcript else {
            state.kcStatus = .absent
            state.resultRecorded = true
            emitKeyConfirmationTelemetry(callId: event.callId, state: state)
            return
        }

        // Send our own MAC immediately — fire-and-forget over the existing
        // opaque_message channel, same pattern as `sendFpSet`.
        let ownMac = event.isInitiator
            ? KeyConfirmation.macInit(kcKey: kcKey, transcript: transcript)
            : KeyConfirmation.macResp(kcKey: kcKey, transcript: transcript)
        let roleByte: UInt8 = event.isInitiator ? 0x01 : 0x02
        let wire = CallPiggyBack.serializeKcMac(callId: event.callId, role: roleByte, mac: ownMac)
        let peerId = event.peerId
        // Item 4 — self-echo guard (see OpaqueSelfEchoFilter doc). KCMAC is
        // one-shot per handshake, not periodic/symmetric, but marking it is
        // free and keeps every piggy-back send on this channel consistent.
        OpaqueSelfEchoFilter.shared.markSent(wire)
        if let provider = liveProvider {
            Task {
                try? await provider.callingApi.sendOpaqueMessageString(recipientId: peerId, payload: wire)
            }
        }

        // 5000ms deadline (per the design): if the peer's kc_mac never
        // arrives, the verdict is `.absent` — never `.wrong` (that's reserved
        // for a MAC that arrived and failed to verify).
        state.deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, let cur = self.kcCallStates[key], !cur.resultRecorded else { return }
                cur.resultRecorded = true
                self.emitKeyConfirmationTelemetry(callId: event.callId, state: cur)
            }
        }
    }

    /// W-KCMAC (ship step 5) — verify an inbound `KCMAC:` piggy-back against
    /// this call's stashed `(kcKey, transcript)`. Malformed/unexpected payloads
    /// are dropped with a log line, exactly like every other piggy-back branch
    /// above — NEVER thrown, NEVER gates the call (W-NOBRICK).
    @MainActor
    private func handleInboundKcMac(callId: String, raw: String, senderId: String) {
        let key = callId.lowercased()
        guard let state = kcCallStates[key] else {
            print("[AppState] KCMAC dropped — no pending key-confirmation state for callId=\(callId.prefix(8))…")
            return
        }
        guard state.peerId == senderId else {
            print("[AppState] KCMAC dropped — sender=\(senderId.prefix(8))… does not match call peer=\(state.peerId.prefix(8))…")
            return
        }
        // Already decided (verified/wrong, or the 5000ms deadline already fired
        // `.absent`) — a late/duplicate KCMAC must not re-open the verdict.
        guard !state.resultRecorded else { return }
        guard let kcKey = state.kcKey, let transcript = state.transcript else {
            // Gate never opened this call (peer didn't advertise pskMixV1, or we
            // couldn't build a transcript) — nothing to verify against. Absent
            // was already recorded synchronously in `handleKcMacReady`.
            return
        }
        guard let bytes = Data(base64Encoded: raw), bytes.count == 33 else {
            print("[AppState] KCMAC malformed payload callId=\(callId.prefix(8))… rawLen=\(raw.count)")
            return
        }
        let roleByte = bytes[bytes.startIndex]
        let mac = bytes.suffix(from: bytes.index(after: bytes.startIndex))
        // The peer's role byte must be the COMPLEMENT of our own (initiator
        // sends kc_mac_init=0x01, responder sends kc_mac_resp=0x02) — a
        // reflected/self role byte is exactly the `kc_reflect` attack the KAT
        // vectors cover, and `KeyConfirmation.verify` alone can't catch it
        // (macInit/macResp differ only in the HMAC's role-byte input, so a
        // reflected mac with the WRONG `asInitiator` flag simply verifies as
        // the wrong-direction MAC unless the role byte itself is also checked).
        let expectedPeerRole: UInt8 = state.isInitiator ? 0x02 : 0x01
        guard roleByte == expectedPeerRole else {
            print("[AppState] KCMAC role mismatch callId=\(callId.prefix(8))… expected=\(expectedPeerRole) got=\(roleByte)")
            state.kcStatus = .wrong
            state.resultRecorded = true
            state.deadlineTask?.cancel()
            emitKeyConfirmationTelemetry(callId: callId, state: state)
            return
        }
        let ok = KeyConfirmation.verify(
            received: Data(mac), kcKey: kcKey, asInitiator: !state.isInitiator, transcript: transcript)
        state.kcStatus = ok ? .verified : .wrong
        state.resultRecorded = true
        state.deadlineTask?.cancel()
        emitKeyConfirmationTelemetry(callId: callId, state: state)
    }

    /// W-KCMAC/W-ASSURANCE/W-FLOOR/W-NFCBADGE — compute `AssuranceState.decide()`'s
    /// real inputs (including, as of W-NFCBADGE, the ONE selected PSK's genuine NFC
    /// origin when applicable — see `AssuranceState.resolveNfcMixInputs`) and record
    /// the four counters for `CallService.getKeyConfirmationTelemetry` to pick up at
    /// teardown. Idempotent to call more than once for the same callId (overwrites
    /// with the latest verdict).
    @MainActor
    private func emitKeyConfirmationTelemetry(callId: String, state: KeyConfirmationCallState) {
        let kcResultStr: String
        switch state.kcStatus {
        case .verified: kcResultStr = "verified"
        case .absent: kcResultStr = "absent"
        case .wrong: kcResultStr = "wrong"
        }
        // `mediaDwellMs: 0` here is correct for THIS specific call (decide()
        // is invoked seconds into the call, long before any dwell floor could
        // matter for S8/S9/S10's own logic, which never reads it) — the
        // SEPARATE dwell-gated presenceAuth write happens later, at teardown
        // (`clearKeyConfirmationState`), with a real elapsed duration.
        //
        // W-FLOOR (ship step 8): `expectedNfc` is fed from this contact's
        // persisted `presenceFloor`. `false` when the peer has no stored
        // contact row at all.
        let existingContact = ContactsStore().load().first(where: { $0.userId == state.peerId })
        let expectedNfc = existingContact?.presenceFloor ?? false

        // W-NFCBADGE — the ONE selected PSK's real origin now reaches
        // `decide()`: previously `mixRoles` was always `[.psk]`/`[]` and
        // `nfcBound`/`witnessOk` were hardcoded `false` because no NFC
        // ceremony existed anywhere in this codebase. `resolvePskDisplayMeta`
        // is the SAME vault lookup the in-call key panel already uses to
        // label a fingerprint "NFC" — reused, not re-derived.
        // `PeerIdentityPinStore.pinnedKey` is the SAME verified-peer-identity
        // notion `sigOk`'s own verdict is anchored to elsewhere in
        // `QAudionCallIntegration`. See `AssuranceState.resolveNfcMixInputs`
        // for the pure decision logic (unit-tested).
        let selectedIsNfc = AppState.resolvePskDisplayMeta(fingerprint: state.selectedFp).method == "NFC"
        // W-NFCIDBIND (2026-07-29) — the identity captured AT THE TAP, read
        // from the vault's dedicated sidecar field, NOT derived from the
        // fingerprint (which is SHA-256(psk), never an identity key — see
        // `resolveNfcMixInputs`'s parameter doc for the failure this replaces).
        let capturedPeerIdentityKey = AppState.resolveNfcPeerIdentityKey(fingerprint: state.selectedFp)
        let verifiedPeerIdentityKey = PeerIdentityPinStore().pinnedKey(contactId: state.peerId)
        let priorPresenceAuth = existingContact?.presenceAuth
            .map { (peerIdentityKey: $0.peerIdentityKey, witnessTier: $0.witnessTier) }
        let (mixRoles, nfcBound, nfcWitnessOk) = AssuranceState.resolveNfcMixInputs(
            n: state.n,
            selectedIsNfcOrigin: selectedIsNfc,
            capturedPeerIdentityKey: capturedPeerIdentityKey,
            verifiedPeerIdentityKey: verifiedPeerIdentityKey,
            priorPresenceAuth: priorPresenceAuth
        )
        let assurance = AssuranceState.decide(
            peerSupportsMix: state.peerSupportsMix,
            n: state.n,
            mixRoles: mixRoles,
            peerAdvertisedRoles: state.peerAdvertisedRoles,
            expectedNfc: expectedNfc,
            kcStatus: state.kcStatus,
            sigOk: state.sigOk,
            nfcBound: nfcBound,
            witnessOk: nfcWitnessOk,
            floorRecorded: expectedNfc,
            mediaDwellMs: 0
        )
        // `expected_but_missing` — the half of S7's predicate this step CAN
        // honestly evaluate: the peer advertised a role-1 (NFC-tier) fingerprint
        // this side also holds, but no NFC secret was mixed this call. Always
        // false in practice today (nobody sets a non-zero role yet — see
        // `AndroidHandshakeBundle.pskRoles`'s doc) until step 7 ships role
        // advertisement for real.
        let expectedButMissing = state.peerAdvertisedRoles.contains(1) && !mixRoles.contains(.nfc)
        // W-NFCCOMMON — the independent "NFC in comune" fact: true whenever the peer's
        // OFFER/ACCEPT advert shows a mutual NFC-tier fingerprint, regardless of whether
        // THIS call's mixRoles/decide() verdict actually used it. Same underlying set as
        // expectedButMissing above, without the `!mixRoles.contains(.nfc)` restriction —
        // when NFC WAS mixed (S2), this is trivially also true, which is correct: the
        // trust bar's "NFC ✓" chip should light in that case too, same as before.
        let mutualNfcInCommon = state.peerAdvertisedRoles.contains(1)
        // W-NFCCOMMON follow-up (2026-07-24, Pavel DECISION) — "a pre-shared key of ANY
        // origin was mixed into this call", independent of `assurance`'s single-select
        // verdict: shows in EVERY state a PSK was mixed, including warning states.
        let pskMixedThisCall = state.n >= 1
        keyConfirmationTelemetryByCall[callId.lowercased()] = (
            pskMixN: state.n,
            kcMacResult: kcResultStr,
            assuranceState: AppState.wireString(for: assurance),
            expectedButMissing: expectedButMissing
        )
        // W-FLOOR — stash the raw verdict + peerId for `clearKeyConfirmationState`
        // to hand to `ContactsStore.applyAssuranceOutcome` once the call is
        // actually tearing down (see that function's doc for why teardown,
        // not here, is the right moment to know `mediaDwellMs`). W-NFCBADGE:
        // `selectedFp`/`nfcWitnessOk` ride along so the teardown write uses
        // the SAME NFC fingerprint/witness verdict computed above, not a
        // second hardcoded placeholder.
        finalAssuranceByCall[callId.lowercased()] = (
            state: assurance, peerId: state.peerId, selectedFp: state.selectedFp, witnessOk: nfcWitnessOk
        )

        // W-ASSURANCE UI — publish the LIVE verdict for LiveInCallScreen. Same
        // "only surface for the active call's peer" guard as
        // `callIdentityUnauthenticatedChange` above, so a late/duplicate
        // verdict from a just-ended or different call can't overwrite the
        // CURRENT call's banner.
        if callContactId == nil || callContactId == state.peerId {
            callAssuranceState = assurance
            callAssuranceExpectedNfc = expectedNfc
            callMutualNfcInCommon = mutualNfcInCommon
            callPskMixedThisCall = pskMixedThisCall
        }
    }

    /// Stable wire/telemetry name for an `AssuranceState` — matches the
    /// design doc's own `S<N> NAME` labels (`PEER_LEGACY`, `PSK_CONFIRMED`, …)
    /// so `tune-report.py` and any future cross-platform dashboard can key off
    /// one string regardless of which client emitted it.
    private static func wireString(for state: AssuranceState) -> String {
        switch state {
        case .peerLegacy: return "PEER_LEGACY"
        case .kcFailed: return "KC_FAILED"
        case .nfcAuthenticated: return "NFC_AUTHENTICATED"
        case .nfcIdentityMismatch: return "NFC_IDENTITY_MISMATCH"
        case .nfcUnattestable: return "NFC_UNATTESTABLE"
        case .identityUnverified: return "IDENTITY_UNVERIFIED"
        case .nfcPresentUnconfirmed: return "NFC_PRESENT_UNCONFIRMED"
        case .expectedNfcStripped: return "EXPECTED_NFC_STRIPPED"
        case .pskConfirmed: return "PSK_CONFIRMED"
        case .pskUnconfirmed: return "PSK_UNCONFIRMED"
        case .pqcOnly: return "PQC_ONLY"
        }
    }

    /// W-KCMAC/W-FLOOR — drop this call's key-confirmation state (and, first,
    /// apply this call's final `AssuranceState` verdict to the peer's
    /// persisted `presenceAuth`/`presenceFloor` — see `applyPresenceAuthOutcomeIfAny`).
    /// Called from `endCall()` AFTER `callService.endCall()` (which reads
    /// `getKeyConfirmationTelemetry` during its own teardown) so the dict
    /// entries don't accumulate across the app's lifetime. Safe to call for a
    /// callId that was never tracked (e.g. a legacy-peer call that never fired
    /// `onKcMacReady` at all, or a call that ended before any handshake leg
    /// completed).
    @MainActor
    private func clearKeyConfirmationState(callId: String?) {
        guard let callId, !callId.isEmpty else { return }
        let key = callId.lowercased()
        applyPresenceAuthOutcomeIfAny(callId: key)
        kcCallStates[key]?.deadlineTask?.cancel()
        kcCallStates.removeValue(forKey: key)
        keyConfirmationTelemetryByCall.removeValue(forKey: key)
        finalAssuranceByCall.removeValue(forKey: key)
    }

    /// W-ASSURANCE/W-FLOOR (ship steps 6/8) — the ONLY call site that invokes
    /// `ContactsStore.applyAssuranceOutcome`. Runs at call teardown (see
    /// `clearKeyConfirmationState`'s doc for why teardown rather than the
    /// moment `emitKeyConfirmationTelemetry` decides the verdict): this is
    /// the first point `mediaDwellMs` — computed from `KeyConfirmationCallState
    /// .readyAt` to now — is meaningful.
    ///
    /// No-op if this call never reached a final verdict (`finalAssuranceByCall`
    /// has no entry — e.g. torn down before `onKcMacReady` ever fired) or if
    /// the peer has no `PeerIdentityPinStore` TOFU pin yet (nothing to bind a
    /// presence record to). W-NFCBADGE: `keyFingerprint`/`witnessOk` now carry
    /// the SAME `selectedFp`/witness verdict `emitKeyConfirmationTelemetry`
    /// already computed and fed to `decide()` (stashed on `finalAssuranceByCall`)
    /// — not a second, independently-hardcoded value. Using a different value
    /// here than the one `decide()` saw would let a live S2 verdict persist a
    /// contradictory `witnessTier`, silently downgrading every later call for
    /// this contact to S4.
    @MainActor
    private func applyPresenceAuthOutcomeIfAny(callId: String) {
        guard let final = finalAssuranceByCall[callId] else { return }
        guard let peerIdentityKey = PeerIdentityPinStore().pinnedKey(contactId: final.peerId) else { return }
        guard let readyAt = kcCallStates[callId]?.readyAt else { return }
        let mediaDwellMs = Int(Date().timeIntervalSince(readyAt) * 1000)
        ContactsStore().applyAssuranceOutcome(
            peerUserId: final.peerId,
            peerIdentityKey: peerIdentityKey,
            keyFingerprint: final.selectedFp ?? "",
            callId: callId,
            state: final.state,
            witnessOk: final.witnessOk,
            mediaDwellMs: mediaDwellMs
        )
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
        // media-consent v1 — iOS↔iOS WS-relay leg: on an audio-only call no
        // pipeline exists, so the peer's screen `video_frame`s would decode
        // to nowhere. Bring up a decode-only pipeline (external source ⇒ no
        // camera, paused ⇒ its encoder can never emit) just to render, and
        // tear it down again on stop. WebRTC peers don't need this — their
        // screen rides the RTP track into WebRTCRemoteVideoView.
        if active, videoPipeline == nil, webRtcController == nil {
            decodeOnlyPipelineForPeerScreen = true
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.startVideoPipeline(
                    for: senderId, sourceMode: .external, startPaused: true)
            }
        } else if !active, decodeOnlyPipelineForPeerScreen,
                  !isVideoCall, !isScreenSharing {
            decodeOnlyPipelineForPeerScreen = false
            videoPipeline?.stop()
            videoPipeline = nil
        }
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
        // Item 4 — self-echo guard (see OpaqueSelfEchoFilter doc).
        OpaqueSelfEchoFilter.shared.markSent(wire)
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
        // Sender-identity check (2026-07-11 — mirrors every other
        // call-signaling handler in this file, e.g. handleIncomingUpgradeRequest
        // at ~2843, all of which already guard on `callContactId == senderId`).
        // `ensureResponderIntegration` caches a SINGLE instance for the whole
        // app session and ignores `forCaller` on a cache hit, and the
        // encapsulate path inside `case .offer` never checked its own
        // `fromSenderId` param against anything — so without this guard, any
        // OTHER authenticated user could send an unsolicited OFFER blob
        // (server relays opaque_message to any RecipientID with no
        // contact/call-relationship check) carrying THEIR OWN public key,
        // get it encapsulated against, and have the resulting attacker-known
        // secret installed as this device's relay-sealer key for whatever
        // call happens to be pending — a real key-injection / call-hijack,
        // not just a duplicate-delivery correctness bug. Reject up front,
        // before any PQC work runs, if there's no active call or the sender
        // isn't who this call is actually with.
        if let expected = callContactId {
            guard expected == senderId else {
                print("[AppState] PQC OFFER REJECTED — senderId=\(senderId.prefix(8))… does not match established callContactId=\(expected.prefix(8))…")
                return
            }
        } else {
            // W-OFFERBUFFER — callContactId not set yet (this OFFER arrived
            // before call_incoming). Buffer; replayed only if callContactId
            // is later set to this exact senderId, never otherwise.
            print("[AppState] PQC OFFER buffered — callContactId not yet set, waiting for call_incoming from \(senderId.prefix(8))…")
            bufferOfferReplay(senderId: senderId) { [weak self] in
                self?.routeInboundPqcOffer(blob: blob, senderId: senderId)
            }
            return
        }
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
        // Sender-identity check (2026-07-11 — same reasoning as
        // routeInboundPqcOffer above). Lower practical severity here since
        // `pqc.decapsulate` is deterministic against OUR OWN private key —
        // a spoofed ACCEPT can't hand an attacker a key they control — but
        // an unchecked spoofed ACCEPT could still win a race against the
        // real callee's ACCEPT and get marked as the session's one-and-only
        // init (existing double-ACCEPT dedup), freezing the real call on a
        // garbage key. Guard for the same reason every other handler here
        // already does.
        guard let expected = callContactId, expected == senderId else {
            print("[AppState] PQC ACCEPT REJECTED — senderId=\(senderId.prefix(8))… does not match callContactId=\(callContactId?.prefix(8) ?? "nil")")
            return
        }
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

    /// W-GRPDIAG-4 (2026-07-26) — Android (`PqcHandshake.persistMessagePsk`)
    /// and Desktop (`CallController` "call-${callId.slice(0,8)}") both derive
    /// and persist a per-contact message PSK from every completed 1:1 call's
    /// session key: `HKDF-SHA256(ikm: sessionKey, salt: callId, info:
    /// "q-audion-msg-psk-v1", 32)`, stored under the name `"call-<callId
    /// prefix8>"`. Group-call control envelopes (sender_key_init/_rotate) use
    /// exactly this PSK for their v3 wire tier — both sides derive it
    /// independently from a session key they already share, no extra
    /// exchange needed. iOS never implemented this half: its receive path
    /// (`lookupGroupCtrlPskByEpoch`, below) already knows how to find and use
    /// such an entry, but nothing here ever wrote one, so it always missed —
    /// root cause of the deterministic sender_key_init nack loop against iOS
    /// documented in the W-GRPDIAG-4 investigation (Android/Desktop send v3,
    /// iOS's vault has no matching "call-<epoch>" entry, v3 open fails,
    /// LiveKit reports MISSING_KEY, iOS nacks — every retry, since resending
    /// identical correct bytes cannot fix a receive-side PSK that was never
    /// persisted). Call this once the 1:1 handshake's session key is final.
    private func persistMessagePsk(sessionKey: Data, callId: String, peerContactId: String) {
        guard sessionKey.count == 32, callId.count >= 8 else { return }
        let msgPsk = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey),
            salt: Data(callId.utf8),
            info: Data("q-audion-msg-psk-v1".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let name = "call-" + String(callId.prefix(8))
        let fp = SHA256.hash(data: msgPsk).map { String(format: "%02x", $0) }.joined().prefix(16)
        do {
            try SovereignKeyVault().storePsk(name: name, key: msgPsk, fingerprint: String(fp), keyClass: .shared)
            print("[AppState] persistMessagePsk: stored call-derived PSK name=\(name) contact=\(peerContactId.prefix(8))…")
        } catch {
            print("[AppState] persistMessagePsk failed contact=\(peerContactId.prefix(8))…: \(error)")
        }
        // W-AVATARPSK (2026-08-02) — second, PEER-BOUND copy of the same
        // bytes. The entry above is keyed on the CALL, which is all the
        // group-control lookup (`lookupGroupCtrlPskByEpoch`) needs, but it
        // leaves the key unreachable to anything that asks "what PSK do I
        // share with THIS peer" — `PairwiseChainKeyResolver`, and therefore
        // every avatar/attachment control envelope. Android has no such gap:
        // `PqcHandshake` stores its identical call-derived PSK with
        // `contactId = peerContactId` and its resolver is
        // `findNewestForContact`, which is precisely why a call alone is
        // enough for two Android devices to exchange avatars while iOS —
        // deriving the same secret from the same call — always failed
        // `.pskMissing` and fell back to a ContactKeyExchange OFFER that a
        // dropped WS can (and did, call cdd13e68) silently swallow.
        //
        // The `msg-psk` prefix is deliberate, not cosmetic:
        // `KeyExportPolicy.origin(name:)` classifies it `.callDerived`, which
        // keeps this entry non-exportable AND out of
        // `PskAdvertising.fingerprintsForAdvertisement` — a call-derived key
        // must never become a candidate 1:1 audio PSK. A name outside that
        // convention would have silently defaulted into the eligible set.
        guard !peerContactId.isEmpty else { return }
        let peerBoundName = "msg-psk:" + peerContactId
        do {
            try SovereignKeyVault().storePsk(
                name: peerBoundName, key: msgPsk, fingerprint: String(fp), keyClass: .shared)
            RTLog.info("avatar", "call-derived PSK bound to peer=\(peerContactId.prefix(8))")
        } catch {
            RTLog.warn("avatar", "peer-bound call PSK store failed peer=\(peerContactId.prefix(8)) error=\(error)")
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
        // W574g — install the M-15 WS-relay sealer the instant the engine
        // session key is set, race-free, carrying the handshake's own
        // callId. Responder side: this fires from the inbound OFFER's
        // session-init regardless of whether AppState.callContactId has
        // been set yet (the old onPqcSessionKeyEstablished install raced
        // it and skipped the callee → Android→iOS 100% AEAD fail).
        integration.onRelaySessionReady = { [weak self, weak integration] sessionKey, cid in
            Task { @MainActor [weak self, weak integration] in
                guard let self = self, !cid.isEmpty else { return }
                // W574x — directional relay-sealer keys when both peers
                // negotiated srtpDirKeyV1. Role A = the lexicographically-smaller
                // userId (same rule as Android/Desktop). peerId = the CALLER.
                let selfId: String = self.currentUserId ?? ""
                let peerId: String = callerId
                let neg: Bool = integration?.negotiatedSrtpDirKey ?? false
                let useDir: Bool = neg && !selfId.isEmpty && !peerId.isEmpty
                let roleA: Bool = useDir ? PqcRtpFrameSealer.selfIsRoleA(selfId, peerId) : false
                self.callService.installRelaySealers(
                    sessionKey: sessionKey, callId: cid,
                    srtpDirKeyV1: useDir, selfIsRoleA: roleA)
                // W-GRPDIAG-4 — see persistMessagePsk doc above.
                self.persistMessagePsk(sessionKey: sessionKey, callId: cid, peerContactId: peerId)
                // Cold-start answer race — the relay session key is now live, so
                // engine + integration + contactId are all ready. If the user
                // already answered during the PushKit cold-start gap, replay it.
                self.consumeDeferredAnswerIfReady("relay-session-ready")
            }
        }
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
                // W574e/g — M-15 relay sealer install moved to the race-free
                // integration.onRelaySessionReady callback (wired below); the
                // callContactId guard here raced the inbound OFFER on the
                // callee and skipped the install.
                CallSessionKeyBroker.shared.bind(
                getCallContactId: { [weak self] in self?.callContactId },
                setSessionKey: { [weak self] in self?.callPqcSessionKey = $0 },
                setPskActive: { [weak self] in self?.pskActive = $0 },
                setPskName: { [weak self] in self?.pskName = $0 },
                setPskMethod: { [weak self] in self?.pskMethod = $0 },
                setPskFingerprint: { [weak self] in self?.pskFingerprint = $0 },
                onSessionEstablished: { [weak self] peerId in self?.handleCallSessionEstablished(peerId: peerId) }
            )
                CallSessionKeyBroker.shared.registerPqcSessionKey(
                    sharedSecret, for: peerId)
            }
        }
        // DISPLAY-ONLY: responder JSON path also reports the negotiated PSK
        // fingerprint. Resolve the human name + method on the app side from
        // our own vault, then record it for the in-call key panel. Never
        // gates the call — any failure leaves the PSK row hidden.
        integration.onPqcSessionKeyEstablishedWithPsk = { [weak self] sharedSecret, pskFp in
            let peerId = callerId
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard sharedSecret.contains(where: { $0 != 0 }) else { return }
                guard self.callContactId == peerId else { return }
                let meta = AppState.resolvePskDisplayMeta(fingerprint: pskFp)
                CallSessionKeyBroker.shared.registerPqcSessionKeyWithPsk(
                    sharedSecret,
                    for: peerId,
                    pskFingerprint: pskFp,
                    pskName: meta.name,
                    pskMethod: meta.method)
                // vkey-v1: resolve + publish the raw PSK so K_video's salt
                // matches Android (psk == HKDF salt). nil → default salt.
                self.callVideoPsk = AppState.resolvePskBytes(fingerprint: pskFp)
                #if canImport(WebRTC)
                if let ctrl = self.webRtcController as? QAudionWebRtcCallController {
                    ctrl.videoContactPsk = self.callVideoPsk
                }
                #endif
            }
        }
        // Phase 18 — v4 ratchet bootstrap from the call handshake (matches
        // Android). The integration supplies the REAL §2.5 / chain-derivation
        // inputs — transcriptHash (offer_binding), self + peer Ed25519 identities —
        // all byte-identical to Android's via the shared signed handshake.
        // selfEpochId/peerEpochId are the 16-zero cross-platform constant (Android
        // zeroEpoch). The integration only fires when every input is real, so no
        // placeholder ever reaches here.
        integration.onV4BootstrapReady = { peerId, effectiveSecret, transcriptHash, selfIdentityPub, peerIdentityPub in
            Task {
                let ok = AppState.sharedV4Ratchet.bootstrapV4AndPersist(
                    peerId: peerId,
                    effectiveSecret: effectiveSecret,
                    selfEpochId: Data(count: 16),
                    peerEpochId: Data(count: 16),
                    selfIdentityPub: selfIdentityPub,
                    peerIdentityPub: peerIdentityPub,
                    transcriptHash: transcriptHash
                )
                print("[PQC_DIAG_V4] bootstrapV4AndPersist peer=\(peerId.prefix(8)) ok=\(ok)")
            }
        }
        // W-KCMAC (ship step 5) — responder leg. See `handleKcMacReady`'s doc.
        integration.onKcMacReady = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKcMacReady(event)
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
        // Phase-10b: wire the handshake-signing closures (sign + verify + TOFU
        // pin) for this responder integration. peerContactId = the caller.
        wireHandshakeSigning(on: integration)
        // Phase B: wire the earbud GATT proxy so onAndroidBundleReceived
        // can perform fp_adv GATT operations (c8 write/read) during the
        // V4 KDF wiring. Nil when no earbud is connected → keyClass=0 fallback.
        integration.earbudPairingGattProxy = earbudGattProxy.isConnected ? earbudGattProxy : nil
        responderCallIntegration = integration
        return integration
    }

    /// Phase-10b handshake-signing wiring (HANDSHAKE-SIGNING-SPEC.md §2/§4/§6).
    ///
    /// Installs the sign/verify/pin closures on a `QAudionCallIntegration`.
    /// Called at BOTH integration construction sites (responder via
    /// `ensureResponderIntegration`, caller via `startCall`) so both directions
    /// sign with the local identity and verify against the shared
    /// `PeerIdentityPinStore` + `ContactsStore` trust sources.
    ///
    /// CLAUDE.md §16: takes ONLY the integration (an existing type with a baked-in
    /// AppState reference graph) — every value it captures is a primitive (`Data`,
    /// `String`, `Bool`) or a closure over `self`-weak; no NEW AppState-typed
    /// parameter is introduced, so the new wiring cannot trip the Swift-6
    /// Sendable-inference silent build break.
    ///
    /// ADDITIVE / DEFAULT-OFF: `requireSignedHandshakeFlag` stays `false` (the
    /// integration's default), so a missing signature is a WARN, not an abort.
    /// If the local sovereign identity is absent, `signTranscript` returns nil →
    /// the OFFER/ACCEPT go out UNSIGNED (byte-identical legacy wire).
    private func wireHandshakeSigning(on integration: QAudionCallIntegration) {
        // CONCURRENCY: AppState is `@MainActor`, but the integration invokes
        // these closures synchronously from its (non-main) WS-dispatch path. So
        // we must NOT dereference `self` (AppState) inside the closures. Instead
        // we capture the backing STORES by value here, while we are on MainActor.
        // Each is a plain `final class` whose operations are Keychain / UserDefaults
        // reads+writes (themselves thread-safe), with no MainActor-isolated state,
        // so they are safe to call off-main. The persisted v4-pin set is also
        // read/written directly via UserDefaults inside the closures (thread-safe)
        // rather than through the MainActor-isolated helper methods.
        let identityManager = sovereignIdentity         // SovereignIdentityManager
        let pinStore = peerPinStore                       // PeerIdentityPinStore
        let v4Key = Self.peerV4PinnedDefaultsKey
        let srtpDirKeyV1Key = Self.peerSrtpDirKeyV1PinnedDefaultsKey

        // Local signer: sign a raw transcript with the long-term Ed25519 seed.
        // Returns nil (→ unsigned) when no identity is loaded or the sign throws.
        integration.signTranscript = { transcript in
            guard let id = identityManager.loadIdentity() else { return nil }
            return try? HandshakeTranscript.sign(
                transcript: transcript,
                signingPrivateKeyRaw: id.signingPrivate)
        }
        // Local signer identity pubkey (32-byte raw Ed25519) for the bundle's
        // signerIdentityKey field. Captured by value now (we are on MainActor).
        // nil → unsigned.
        integration.localSignerIdentityKey = identityManager.loadIdentity()?.signingPublic

        // Trust sources (spec §5c): pinned key first, then server/QR-fetched key.
        // D11: per-(peer, device) pin. A nil device id resolves to the legacy
        // bare-contactId pin inside the store (migration anchor / graceful
        // fallback), so a missing `sender_device_id` never manufactures a
        // spurious mismatch.
        integration.resolvePinnedPeerKeyForDevice = { peerId, deviceId in
            pinStore.pinnedKey(contactId: peerId, deviceId: deviceId)
        }
        integration.resolveServerPeerKey = { peerId in
            // Spec §5c "server" trust source (iOS parity with Android
            // EnsurePeerTrustPinnedUseCase / Desktop server-fetch). Read the
            // server-fetched RAW 32-byte Ed25519 identity key from the
            // thread-safe UserDefaults cache populated by
            // `prefetchServerPeerKey(_:)` (kicked at call_incoming / startCall).
            // Falls back to any QR-paired ContactsStore key. A cache MISS
            // returns nil so the verifier falls through to bundle-TOFU on
            // genuine first contact (never a hard abort). NOTE: this is gated
            // on the 2026-06-23 publish fix being fleet-wide — the server must
            // hold each peer's SIGNING key (== its handshake bundle key), else
            // a cached pre-fix device key would trip identity_key_mismatch.
            guard !peerId.isEmpty else { return nil }
            if let raw = UserDefaults.standard.data(forKey: Self.serverPeerKeyDefaultsKey(peerId)),
               raw.count == 32 {
                return raw
            }
            return ContactsStore().findPubkey(userId: peerId)
        }
        // First-contact / set-proven TOFU pin commit (AFTER a signature verified
        // under it). D11: keyed per-(peer, device); a nil device id pins under
        // the legacy bare-contactId account inside the store.
        integration.commitTofuPinForDevice = { peerId, key, deviceId in
            _ = pinStore.pinOrMatch(contactId: peerId, ed25519Pub: key, deviceId: deviceId)
        }

        // D11 trust-on-publish floor: resolve the server's published per-device
        // SET of Ed25519 identity keys for this peer. Read from the thread-safe
        // UserDefaults set cache warmed by `prefetchServerPeerKeySet(_:)` at
        // call_incoming / startCall. Empty set ⇒ "no floor" ⇒ the policy degrades
        // to legacy pin-only TOFU (NEVER a fatal mismatch). The `deviceId` arg is
        // accepted for symmetry but the cache is keyed per-peer (the set already
        // covers all of a peer's devices).
        let setKeyFn = Self.serverPeerKeySetDefaultsKey
        integration.resolvePublishedKeySet = { peerId, _ in
            guard !peerId.isEmpty else { return [] }
            guard let arr = UserDefaults.standard.array(forKey: setKeyFn(peerId)) as? [Data] else {
                return []
            }
            return Set(arr.filter { $0.count == 32 })
        }

        // D11 W-NOBRICK UI advisory: an UNAUTHENTICATED identity-key change
        // (bundle key ∉ the published set) was observed for `peerId`. The verdict
        // handler runs OFF-MAIN, and the banner flag is MainActor-isolated, so we
        // marshal the set onto the main actor. Advisory ONLY — media is never
        // hard-blocked here; this just lights the non-blocking InCallScreen banner.
        integration.onUnauthenticatedIdentityChange = { [weak self] peerId in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Only surface the alert for the peer of the active call to avoid
                // a stale banner from a late/duplicate envelope of another call.
                if self.callContactId == nil || self.callContactId == peerId {
                    self.callIdentityUnauthenticatedChange = true
                }
            }
        }
        // XC-1 — a present-but-INVALID handshake signature (forgery against the
        // established identity). Revoke this peer's stored SAS verification so the
        // in-call SAS card becomes a REQUIRED re-confirmation, and surface the same
        // non-blocking banner. The call still proceeds (W-NOBRICK / signal-not-kill).
        integration.onInvalidHandshakeSignature = { [weak self] peerId in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                SasVerificationStore.shared.clear(peerUserId: peerId)
                if self.callContactId == nil || self.callContactId == peerId {
                    self.callIdentityUnauthenticatedChange = true
                }
            }
        }

        // v4_capable_pinned set (spec §4), persisted in UserDefaults (thread-safe).
        integration.isPeerV4Pinned = { peerId in
            guard !peerId.isEmpty else { return false }
            let set = UserDefaults.standard.stringArray(forKey: v4Key) ?? []
            return set.contains(peerId)
        }
        integration.setPeerV4Pinned = { peerId in
            guard !peerId.isEmpty else { return }
            var set = UserDefaults.standard.stringArray(forKey: v4Key) ?? []
            if !set.contains(peerId) {
                set.append(peerId)
                UserDefaults.standard.set(set, forKey: v4Key)
            }
        }
        // SRTP downgrade fix: TOFU-pin the directional-SRTP-key capability the
        // same additive-only way v4 is pinned above — once a SIGNED bundle from
        // this peer has advertised it, a later unauthenticated bundle can no
        // longer silently strip it (see QAudionCallIntegration's
        // `peerAdvertisedSrtpDirKey` OR-in).
        integration.isPeerSrtpDirKeyV1Pinned = { peerId in
            guard !peerId.isEmpty else { return false }
            let set = UserDefaults.standard.stringArray(forKey: srtpDirKeyV1Key) ?? []
            return set.contains(peerId)
        }
        integration.setPeerSrtpDirKeyV1Pinned = { peerId in
            guard !peerId.isEmpty else { return }
            var set = UserDefaults.standard.stringArray(forKey: srtpDirKeyV1Key) ?? []
            if !set.contains(peerId) {
                set.append(peerId)
                UserDefaults.standard.set(set, forKey: srtpDirKeyV1Key)
            }
        }
        // Verified-channel = the user has confirmed the SAS for this peer AND that
        // confirmation still applies to the identity key currently pinned.
        //
        // C-3 (2026-07-26) — the second half is new. "A stored fingerprint is the
        // proxy for trust >= VERIFIED_CHANNEL" was the old rule and it survived key
        // rotation: a server-substituted identity inherited the user's in-person
        // verification with nothing to notice. Now the record is bound to the pinned
        // key, so a rotation drops this back to unverified by construction.
        //
        // No pin (never contacted / wiped) => not verified. `SasVerificationStore.shared`
        // and `PeerIdentityPinStore` are both Keychain-backed — safe to read off-main.
        integration.isPeerVerifiedChannel = { peerId in
            guard let pinned = PeerIdentityPinStore().pinnedKey(contactId: peerId) else {
                return false
            }
            return SasVerificationStore.shared.hasVerifiedBinding(
                peerUserId: peerId,
                currentIdentityTag: SasVerificationStore.identityTag(forPinnedKey: pinned))
        }
        // Global enforcement flag: the integration default is `true` (Gate #16,
        // enabled 2026-06-18 — see QAudionCallIntegration.requireSignedHandshakeFlag).
        // We intentionally do NOT touch it here. `require_signed_handshake` ON
        // means a MISSING signature is surfaced (sig_required_missing) rather than
        // silently accepted; do NOT set it to `false` (that re-opens the fleet to
        // unsigned/MITM peers — a security downgrade).
        //
        // D11 / W-NOBRICK — what actually happens to a KEY SWAP (corrects the
        // earlier "caught fail-closed" wording, which never matched runtime):
        // a key swap is NOT a hard media block. The identity verdict is advisory.
        //   • A changed key that IS a member of the server-published per-device
        //     set (GET …/identity-key?all=1) is a legitimate new device /
        //     authenticated rotation → it auto-pins SILENTLY (trust-on-publish),
        //     no banner.
        //   • A changed key that is NOT in the published set is an UNAUTHENTICATED
        //     change → surfaced as a NON-BLOCKING in-call alert ONLY (the observed
        //     key is NOT pinned). The call proceeds.
        //   • Media is NEVER hard-blocked on the identity verdict; the SAS (6
        //     out-of-band words) is the terminal anti-MITM gate. Trust-on-publish
        //     is a server-trusted floor, NOT end-to-end identity authentication.
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
            try callService.activateIncomingCallAudio(engine: eng, integration: intg, contactId: cid)
        } catch {
            print("[AppState] startIncomingCallAudioOnAnswer: audio activation failed: \(error)")
        }
        // Speaker override is now in CallService.handleAudioSessionActivated()
        // — calling it here (before the session is active) was silently ignored
        // by iOS, leaving audio on the earpiece (log: out=Receiver).
    }

    /// Cold-start answer race (device report 2026-06-25, call 626ad9af): a
    /// PushKit-woken incoming call rings via the native CallKit UI ~20 s before
    /// the app finishes its cold start (WS reconnect + buffered call_offer SDP
    /// redelivery). If the user answers in that gap, `onAnswerCall` runs while
    /// `engine` / `responderCallIntegration` / `callContactId` are still being
    /// set up, so `startIncomingCallAudioOnAnswer` bails ("audio not started"),
    /// the answer is silently lost, `callState` stays `.idle` (no SAS screen)
    /// and the call times out (endCall state=idle) — exactly what the device
    /// logs showed (A36 computed SAS from the handshake, iOS never connected).
    ///
    /// Fix: `onAnswerCall` latches the answer (`answeredCallKitId`) and this
    /// idempotent method DEFERS the audio start + state advance until the call
    /// machinery is ready. Called from `onAnswerCall` (immediate / normal
    /// path), the WS `call_incoming` handler (integration just built), and the
    /// relay-session-ready / SAS-ready observers (PQC key live). The
    /// `incomingAudioStarted` flag guarantees it runs exactly once.
    @MainActor
    private func consumeDeferredAnswerIfReady(_ trigger: String) {
        guard answeredCallKitId != nil else { return }      // user hasn't answered
        guard !incomingAudioStarted else { return }          // already started once
        guard engine != nil,
              responderCallIntegration != nil,
              let peer = callContactId else {
            print("[AppState] deferred answer not ready yet, will retry: \(trigger)")
            return
        }
        incomingAudioStarted = true
        // Advance the state machine for the native-UI / cold-start case where
        // callState was .idle (background) or .ringing (foreground) at answer.
        // onAnswerCall only advanced from .ringing and the sasReady observer
        // only from .active/.connecting, so a background-answered call would
        // otherwise never reach .encrypted (no SAS screen).
        if callState != .encrypted { callState = .active }
        if callSasKeySource == .mlKem { callState = .encrypted }
        // Start mic capture + speaker playback on the existing responder
        // integration (reuses the negotiated PQC session key).
        startIncomingCallAudioOnAnswer()
        // Tell the caller we answered. The WS-relay path (no WebRTC controller)
        // has no other call_answer emitter, so the caller would stay stuck in
        // .ringing without this. WebRTC calls send their own SDP-bearing
        // call_answer from the controller — skip to avoid a duplicate.
        if webRtcController == nil, let calling = liveProvider?.callingApi {
            Task { try? await calling.sendCallAnswer(recipientId: peer, sdp: "") }
        }
        print("[AppState] deferred answer consumed: \(trigger)")
    }

    /// W-WAKEONLY — "CallKit for wake only". After the user answers a
    /// push-woken call, dismiss the native CallKit in-call UI (which iOS keeps
    /// on top of our window) so the Q-Audion SAS screen becomes the call
    /// surface. The call stays alive in-app (sealed audio); the app then
    /// self-manages the audio session. Gated by the remote flag
    /// `ios_callkit_wake_only` (compiled default OFF) so it can be killed
    /// server-side without a rebuild if it regresses audio. Delayed ~0.6 s so
    /// the audio engine is up before CallKit drops its session hold (re-asserted
    /// here + in onAudioSessionDeactivated). Only dismisses calls whose native
    /// UI was actually shown — releaseFromSystemUI no-ops otherwise.
    @MainActor
    private func dismissNativeCallUIAfterAnswer(_ uuid: UUID) {
        // REVERTED to default OFF (v1.0.691). Device evidence (call 19080DFB,
        // 1.0.690): wake-only fired ("native UI dismissed, app owns the call")
        // but the app STILL did not come to the foreground — iOS does NOT let an
        // app foreground its own UI for a screen-off / locked push call (no API;
        // dismissing the native UI just returns to the lock/home screen, not the
        // app). So wake-only removed the system call UI without showing ours —
        // strictly worse. The SAS screen is reachable only by tapping the
        // Q-Audion icon on the native call screen (standard iOS, same as Signal).
        // Kept behind the flag so it can be force-ON for experiments, but OFF by
        // default restores the standard native call UI.
        guard FeatureFlags.bool("ios_callkit_wake_only", false) else {
            RTLog.info("call", "W-CALLFG-DIAG dismissNativeCallUIAfterAnswer uuid=\(uuid) — ios_callkit_wake_only OFF, native CallKit UI left as-is (expected default)")
            return
        }
        RTLog.info("call", "W-CALLFG-DIAG dismissNativeCallUIAfterAnswer uuid=\(uuid) — ios_callkit_wake_only ON, will attempt release in 0.6s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self,
                  let provider = self.callKit as? CallKitProvider else { return }
            guard provider.releaseFromSystemUI(uuid) else { return }
            self.selfManagedAudioSession = true
            RTLog.info("call", "CallKit-wake-only: native UI dismissed, app owns the call")
            Task { await provider.reactivateAudioSessionForSelfManagedCall() }
        }
    }

    /// Revive the signalling WebSocket on demand. Mirrors the
    /// `UIApplication.willEnterForeground` reconnect logic so a PushKit
    /// incoming-call wake gets the SAME socket recovery a manual foreground does.
    ///
    /// CRITICAL (device logs 2026-06-25, call c6cdbed4): a PushKit VoIP push
    /// wakes the app specifically to take a call, but the signalling socket is
    /// almost always DOWN at that moment — the server fell back to a push BECAUSE
    /// the callee's WS was offline. The PushKit handler used to report the call to
    /// CallKit and touch nothing else, so the buffered call_offer redelivery + the
    /// PQC handshake never arrived: the native UI rang, the answer bound nothing,
    /// and the call hung (no SAS, no audio) until the user MANUALLY foregrounded
    /// the app minutes later (finally firing willEnterForeground → reconnect, long
    /// after the server's buffered-offer TTL had expired → "offer expired; not
    /// redelivering"). Kicking this from the push handler brings the socket up
    /// immediately so the OFFER + handshake flow while the caller is still ringing.
    @MainActor
    private func reviveSignalingSocket() async {
        guard isAuthenticated else { return }
        if let live = liveProvider {
            if live.persistentConnection.state == .disconnected {
                liveProvider = nil
                connectPersistentSocket()
            } else {
                _ = await live.persistentConnection.ensureAuthenticated(timeoutSec: 10)
            }
        } else {
            connectPersistentSocket()
        }
    }

    /// Resolve the incoming-call display name for the native CallKit UI,
    /// preferring the LOCAL address book (rubrica) over the server-supplied push
    /// name — mirrors the WS `call_incoming` resolution so a PushKit-woken call
    /// shows "Mario Rossi" instead of the raw caller id. The encrypted-call
    /// "Cifrata" tag is appended by CallKitProvider.reportIncomingCall (native UI
    /// only), so this returns just the clean name.
    /// PushKit incoming-call setup, extracted from the `onIncomingCall` closure
    /// so the nested `MainActor.run` body is a single call (CLAUDE.md §13/§14
    /// type-checker hygiene). Stamps the active-call ids and returns the native
    /// CallKit display name (rubrica-resolved).
    @MainActor
    private func prepareIncomingPushCall(callId: UUID, callerId: String, hasVideo: Bool, fallbackName: String) -> String {
        activeCallKitId = callId
        callContactId = callerId
        drainPendingOfferReplays(for: callerId)  // W-OFFERBUFFER
        // WIRE_SPEC §8.3 — PushKit-woken incoming call: we answered → polite.
        originalCallRole = .callee
        isVideoCall = hasVideo
        let display = callKitDisplayName(callerId: callerId, fallback: fallbackName)
        // W-1TO1RING — set here too (not just the WS path) so a call that
        // wakes the device via PushKit alone (no WS call_incoming yet, or
        // ever) still has a resolved name/ring-visible flag the instant the
        // app becomes active — same reasoning as the WS site above.
        incomingCallerName = display
        incomingCallRingVisible = true
        return display
    }

    /// W-EXTPREFIX consolidation (2026-07-29): this older, parallel resolver
    /// used to reimplement `DisplayName.forUser`'s tiers by hand (its own
    /// UUID guard per W-GRPTITLE-UUIDGAP, its own bare-numeric check, its
    /// own "Int. " prefix) — now a single call into the canonical function
    /// so PushKit-woken calls resolve through the exact same chain as the
    /// WS `call_incoming` path above instead of a second copy that could
    /// (and did) drift from it.
    @MainActor
    private func callKitDisplayName(callerId: String, fallback: String?) -> String {
        DisplayName.forUser(callerId, serverDisplay: fallback, contacts: cachedContacts)
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
        // W574c — video RX rides the same WS: re-register its inbound
        // handler on the fresh instance too, or remote video freezes
        // after a mid-call reconnect while audio recovers.
        if let pipeline = videoPipeline {
            registerInboundVideoHandler(on: ws, pipeline: pipeline)
        }
        print("[AppState] WS reconnect — call audio re-wired to fresh WS for peer \(peerId.prefix(8))…")
    }

    private func bindPresenceAfterAuth() {
        // W74: presence subscriptions ride the SAME long-lived WS that keeps
        // the user marked online.
        // W-ONESOCKET: presence rides the SINGLE persistent socket. Never
        // open a throwaway WS just to subscribe — that spawned a zombie
        // socket (and a duplicate apns-voip-token POST). If the persistent
        // provider isn't up yet, bind nothing now; the auth-success path
        // re-runs `bindPresenceAfterAuth` once `connectPersistentSocket`
        // settles, so presence lands on the live transport then.
        guard let provider = liveProvider else {
            if authService.loadToken()?.isEmpty == false { connectPersistentSocket() }
            return
        }
        presenceService.attach(provider: provider)
        // Initial subscription set: known contact userIds + recent calls.
        // Views that load additional userIds (chat list with full
        // history) call `presenceService.subscribe(userIds:)` themselves
        // to broaden the tracked set.
        // W-CC: refresh cache at auth time so the freshest contacts list
        // is used for both presence and incoming-call name resolution.
        refreshContactsCache()
        resubscribePresenceForTrackedContacts()
    }

    /// I5: recompute the presence tracked set (contacts ∪ recent calls) and
    /// push it to the engine. `PresenceService.subscribe(userIds:)` replaces
    /// the whole set — the server treats it as authoritative — so calling
    /// this again is always safe, including before `bindPresenceAfterAuth`
    /// has ever attached a manager (it just populates the local tracked set;
    /// the next `attach(provider:)` restores it on the live transport).
    /// Shared by `bindPresenceAfterAuth` (post-auth) and the
    /// `.contactsDidChange` observer — a contact added mid-session
    /// (QR/NFC/phonebook import) must be subscribed too, not just cached.
    ///
    /// The `lastSubscribedUserIds` guard is load-bearing, not decorative:
    /// `ContactsRefreshService.refresh(phonesToCheck:)` calls
    /// `store.upsert(c)` in a loop, once per resolved contact — a
    /// phonebook sync with dozens of matches posts `.contactsDidChange`
    /// (and thus would call this) dozens of times in a tight burst. Without
    /// the early-exit, each one re-sends a full `presence_subscribe` over
    /// the WS even when the resulting set is identical to what's already
    /// live (flagged by external code review, confirmed against the real
    /// call site rather than left as a hypothetical).
    private func resubscribePresenceForTrackedContacts() {
        let contacts = cachedContacts.map { $0.userId }
        let recents = recentCalls
        // NOTE: `Set(...).filter { }` returns `[String]` (Sequence.filter
        // always yields an Array, even from a Set receiver) — wrap the
        // filtered array back in `Set(...)` so `union` is actually
        // comparable to `lastSubscribedUserIds` below.
        let union = Set((contacts + recents).filter { !$0.isEmpty })
        // W-PRESENCETRACKSHRINK — an adversarial review of the dedup guard
        // above caught that requiring `!union.isEmpty` here meant a
        // legitimate shrink-to-zero (the user deletes their last contact,
        // no recent-call history either) returned WITHOUT clearing
        // `lastSubscribedUserIds` and WITHOUT telling the server the
        // tracked set is now empty — the previous, no-longer-justified
        // subscription stayed live for the rest of the session. Comparing
        // only against `lastSubscribedUserIds` still short-circuits the
        // cold-start case for free: both sides start `[]`, so the equality
        // check alone already skips the redundant first call.
        guard union != lastSubscribedUserIds else { return }
        lastSubscribedUserIds = union
        presenceService.subscribe(userIds: Array(union))
    }

    /// I1-RESUME — forces a fresh `presence_subscribe` even when the tracked
    /// set is IDENTICAL to `lastSubscribedUserIds`. That dedup guard exists
    /// to stop a burst of no-op resubscribes; it is wrong for exactly one
    /// case: the gate was OFF (so the last real subscribe — before the gate
    /// flipped off — is what `lastSubscribedUserIds` still holds), and it
    /// just turned back ON. The tracked set the user cares about hasn't
    /// changed, but the server was never told to resume, so the ordinary
    /// path would see `union == lastSubscribedUserIds` and skip the call
    /// that is the entire point of resuming.
    private func forceResubscribePresence() {
        let contacts = cachedContacts.map { $0.userId }
        let union = Set((contacts + recentCalls).filter { !$0.isEmpty })
        lastSubscribedUserIds = union
        presenceService.subscribe(userIds: Array(union))
    }

    /// Last userId set actually pushed via `resubscribePresenceForTrackedContacts`.
    /// Reset on logout (`presenceService.reset()` call site) so the next
    /// session's first subscribe always goes out even if the set happens
    /// to match the previous session's.
    private var lastSubscribedUserIds: Set<String> = []

    // MARK: - W-CC contacts cache

    /// Reload the in-memory contacts snapshot from UserDefaults.
    /// Called at app start (initialize), on auth success (bindPresenceAfterAuth),
    /// and automatically whenever ContactsDidChange posts .contactsDidChange.
    ///
    /// W-UUIDSWEEP migration: legacy rows persisted by the pre-fix
    /// `addScannedContact` carry the RAW 36-char userId as `displayName` —
    /// the direct-`displayName` renderers (contacts list, chat headers,
    /// CarPlay) then show the UUID as the contact's NAME. Rewrite such rows
    /// once, in place, to the humane short fallback; a later server lookup /
    /// user rename upgrades them further. The rewrite triggers ONE extra
    /// .contactsDidChange -> refreshContactsCache pass, which then finds
    /// nothing UUID-shaped and terminates (no loop).
    ///
    /// W-EXTPREFIX consolidation (2026-07-29): extended to every other
    /// recognised placeholder shape too (rule 5 — a stale cached
    /// "Phone #100"/"New User" is "no name set", the server migration
    /// cannot reach a row a client is still holding locally). Recovers the
    /// BEST available replacement (extension, then phone, then short8) via
    /// the side-effect-free `resolvedExtension` primitive rather than the
    /// full `DisplayName.forUser` — this function runs on EVERY
    /// `.contactsDidChange` (including ones this very rewrite causes), so
    /// it must never itself trigger `forUser`'s own `ensureResolved` fetch,
    /// and the `replacement != c.displayName` guard keeps an already-
    /// converged short8 row (nothing left to recover) from re-triggering
    /// `migrated` on every subsequent pass.
    private func refreshContactsCache() {
        let store = ContactsStore()
        var contacts = store.load()
        var migrated = false
        for i in contacts.indices {
            let c = contacts[i]
            guard DisplayName.isPlaceholderName(c.displayName) else { continue }
            let replacement = DisplayName.resolvedExtension(for: c.userId, contacts: [c])
                ?? c.phoneNumber.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                ?? DisplayName.shortUserFallback(c.userId)
            guard replacement != c.displayName else { continue }
            contacts[i] = ContactsStore.StoredContact(
                userId: c.userId,
                displayName: replacement,
                phoneHash: c.phoneHash,
                avatarUrl: c.avatarUrl,
                lastSeen: c.lastSeen,
                isVerified: c.isVerified,
                pubkey: c.pubkey,
                verifiedFingerprintHex: c.verifiedFingerprintHex,
                verifiedAtMs: c.verifiedAtMs,
                verificationMethod: c.verificationMethod,
                // W-ASSURANCE/W-FLOOR — this rewrite touches ONLY
                // displayName; every other field (including these two) must
                // thread through unchanged, same as verifiedFingerprintHex
                // above. Omitting them here would silently wipe a contact's
                // NFC presence record on nothing more than a display-name
                // migration pass.
                presenceAuth: c.presenceAuth,
                presenceFloor: c.presenceFloor,
                phoneNumber: c.phoneNumber,
                extension: c.`extension`,
                // E2EE avatar transport (2026-07-30) — same reasoning as
                // presenceAuth/phoneNumber above: this rewrite touches
                // ONLY displayName.
                avatarVersion: c.avatarVersion)
            migrated = true
        }
        if migrated { store.save(contacts) }
        cachedContacts = contacts
    }

    /// Fail over off a dead node (driven by the WS client's onNodeStalled signal):
    /// cooldown-gated (anti ping-pong) + jittered (anti thundering-herd), then ask
    /// ServerSelector to re-select a different trusted node, which switches the
    /// provider URL. The WS reconnect then lands on the new node.
    @MainActor
    private func handleNodeStalled(_ deadWss: String) async {
        guard let prov = self.liveProvider else { return }
        let now = Date().timeIntervalSince1970 * 1000
        if now - lastFailoverMs < 20_000 { return }
        lastFailoverMs = now
        let jitter = Double.random(in: 0...5_000)
        try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000))
        let newWss = await ServerSelector.shared.reselectExcluding(deadWssUrl: deadWss, provider: prov)
        // CLEARNET-FIRST fallback to Reality (design doc §6). `reselectExcluding`
        // returns nil ONLY when every trusted clearnet node it probed was
        // unreachable — i.e. the network is silently dropping our traffic (the
        // §1 incident shape), not one dead node. That is the hard-failure signal
        // to bring up the Reality censorship-bypass tunnel and retry the SAME
        // wss://voip.bcrypto.com through it. A genuine total-offline also lands
        // here; Reality's own dial then fails harmlessly and the normal
        // reconnect resumes when the network returns. This is only ever reached
        // AFTER clearnet is exhausted — Reality is never the default route.
        if newWss == nil {
            await activateRealityFallback(reason: "auto-clearnet-block")
        }
    }

    /// Bring up the Reality censorship-bypass tunnel and re-point the persistent
    /// signaling WebSocket through its local SOCKS5. Mirrors
    /// `EmbeddedTorManager`'s activation shape (start() → local SOCKS5 port →
    /// dial the WSS through it) — but for the app's real
    /// `wss://voip.bcrypto.com` transport, not the .onion signaling side.
    ///
    /// Reuses the EXISTING `RealityManager` + its xray config builder: this only
    /// sources the server-issued params and feeds them in. The WSS TLS + cert
    /// pinning above the socket run UNCHANGED through the tunnel (see
    /// `BCryptoWebSocketClient.connect(viaSocksPort:)`), so nothing above the
    /// transport layer knows Reality exists.
    ///
    /// Params come from the SAME `/calling/relays` bundle the TURN/onion
    /// selectors already use: the warm in-memory cache first (populated while
    /// clearnet was healthy — covers a mid-session block), then a best-effort
    /// fresh fetch (works on the open network of the manual-force test path). On
    /// a truly blocked cold start neither is available and this no-ops — a known
    /// v1 bootstrap limit the design doc §6.3 explicitly defers, not something
    /// this last-mile solves.
    @MainActor
    func activateRealityFallback(reason: String) async {
        guard let prov = liveProvider else { return }
        // Already tunneling, or a concurrent activation is mid-flight → no-op.
        if transportIsReality || realityActivationInFlight { return }
        realityActivationInFlight = true
        defer { realityActivationInFlight = false }

        guard let relayProvider = ensureRelayProvider() else { return }
        var params = await relayProvider.cachedOrNil()?.reality
        if params == nil {
            params = await relayProvider.currentOrRefresh()?.reality
        }
        guard let reality = params, reality.isUsable else {
            print("[AppState] Reality fallback (\(reason)): server has no usable reality params — cannot bypass")
            return
        }

        // REALITY_PIN fix: TOFU-pin the front's public key by hostname. A
        // mismatch means the server-issued key CHANGED since we last saw it —
        // a compromised/coerced CDN edge could do this with zero other signal.
        // Non-blocking (signal-not-kill): log loud, re-pin to the new value
        // (already done inside checkAndPin), still connect — refusing to
        // connect would break the user's only censorship-bypass path.
        let pinVerdict = RealityPinStore.checkAndPin(hostname: reality.hostname, publicKey: reality.publicKey)
        if pinVerdict == .changed {
            RTLog.error("security", "Reality front public key CHANGED for \(reality.hostname)")
            realityKeyChanged = true
        }

        // Map the server-issued relay block into RealityManager's config shape.
        // The client hardcodes NOTHING — every field is server-chosen (design
        // doc §4.2). fingerprint defaults to "chrome" inside RealityManager.
        let managerParams = RealityManager.Params(
            serverAddress: reality.hostname,
            serverPort: reality.port,
            uuid: reality.uuid,
            publicKey: reality.publicKey,
            shortId: reality.shortId,
            serverName: reality.serverName,
            flow: reality.flow
        )

        do {
            let socksPort = try await RealityManager.shared.start(params: managerParams)
            let ws = prov.getWebSocketClient()
            // Tear the (blocked / direct) socket down first so
            // connect(viaSocksPort:) — which only proceeds from `.disconnected`
            // — takes effect, then re-dial the SAME WSS through the tunnel. The
            // socks port is sticky across the socket's own internal reconnects
            // (see BCryptoWebSocketClient.currentSocksPort), so a later drop
            // keeps routing through Reality instead of silently reverting to the
            // blocked clearnet path.
            ws.disconnect()
            ws.connect(viaSocksPort: Int(socksPort))
            transportIsReality = true
            print("[AppState] Reality fallback (\(reason)) ACTIVE — WSS tunneled via 127.0.0.1:\(socksPort)")
        } catch {
            print("[AppState] Reality fallback (\(reason)) FAILED to start: \(error)")
            errorMessage = "Tunnel Reality non disponibile: \(error.localizedDescription). Connessione diretta in corso."
            // start() threw before we ever got to disconnect()/connect(viaSocksPort:)
            // above, so the socket is left exactly as this function found it — which,
            // for the "auto-clearnet-block" caller, means already disconnected (every
            // trusted clearnet node was just exhausted) with nothing left to bring it
            // back. Without this, the client stays silently offline forever. Fall back
            // to a plain clearnet connect — same call the manual OFF path uses in
            // setForceRealityTransport(_:) — so at minimum normal reconnect/backoff
            // resumes instead of the client going dark.
            let ws = prov.getWebSocketClient()
            ws.connect()
        }
    }

    /// Manual force path (TransportSettingsScreen toggle / debug hook). Persists
    /// the preference and applies it immediately when a live provider exists:
    /// ON → bring Reality up now; OFF → tear the tunnel down and re-dial
    /// clearnet directly. Lets a tester verify the Reality path on an OPEN
    /// network, where the automatic hard-failure trigger would never fire.
    @MainActor
    func setForceRealityTransport(_ on: Bool) {
        AppState.forceRealityEnabled = on
        guard let prov = liveProvider else { return } // applied at next connect
        let ws = prov.getWebSocketClient()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if on {
                await self.activateRealityFallback(reason: "manual-force")
            } else {
                // Revert to clearnet: drop the tunnel + re-dial direct.
                ws.disconnect()
                await RealityManager.shared.stop()
                self.transportIsReality = false
                ws.connect()
                print("[AppState] Reality force OFF — reverted to direct clearnet WSS")
            }
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
        // Reality lifecycle: reset the runtime tunnel state so the next login
        // starts clearnet-first with a correct indicator, and tear the tunnel
        // down (idempotent, fire-and-forget). The PERSISTED force preference
        // (`forceRealityEnabled`) is intentionally left as the tester set it.
        if transportIsReality {
            transportIsReality = false
            Task { await RealityManager.shared.stop() }
        }
        // W72: drop presence subscriptions + cached statuses so the next
        // login starts with a clean slate.
        presenceService.reset()
        lastSubscribedUserIds.removeAll()
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
                // W-EXTPREFIX consolidation (2026-07-29): this used to be an
                // independent copy of the UUID/placeholder check with its
                // own "Int. NNN" formatting — `resolveDialInput` below used
                // to SKIP this entirely and always show "Int. NNN" even
                // when `profile.displayName` was a perfectly good real
                // name, a documented contradiction for the identical
                // account. Both now call the same `DisplayName.forUser`.
                self.incomingCallerName = DisplayName.forUser(
                    profile.userId, serverDisplay: profile.displayName,
                    knownExtension: String(ext))
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
                guard let entry = entries.first else {
                    errorMessage = "Numero \(normalized) non risulta tra gli utenti registrati."
                    return
                }
                let userId = entry.userId
                // Same UUID-leak fix as the extension branch: show the dialed
                // E.164 number on the call screens instead of the raw UUID,
                // unless the discovered account has a real display name.
                self.incomingCallerName = DisplayName.forUser(
                    userId, serverDisplay: entry.displayName, knownPhoneNumber: normalized)
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

    /// Resolution result for `resolveDialInput` below.
    struct ResolvedDialTarget {
        let userId: String
        /// Best available human label for the resolved peer, run through
        /// the SAME canonical `DisplayName.forUser` chain `dialAndCall`
        /// uses for `incomingCallerName` on its identical two branches —
        /// the caller may still want to persist it as the contact's
        /// initial display name.
        let displayLabel: String
    }

    /// 2026-07-29 — same 3-branch resolution heuristic as `dialAndCall`
    /// above (short extension / E.164 phone / already-a-userId), but
    /// returns the resolved target instead of starting a call. Lets
    /// `ChatListScreen`'s "new conversation" flow start a chat by typed
    /// number/extension the same way `dialAndCall` already lets the
    /// DialPad start a CALL by typed number/extension — that capability
    /// existed only for calls before this.
    ///
    /// W-EXTPREFIX consolidation (2026-07-29): this used to be a documented
    /// DELIBERATE parallel implementation that ignored `profile.displayName`
    /// entirely and always synthesized its own "Int. NNN" — a real,
    /// user-visible contradiction with `dialAndCall` for the identical
    /// account (dialing FROM the pad showed a real name; starting a chat by
    /// the SAME number showed "Int. NNN" instead). Both branches below now
    /// call the exact same `DisplayName.forUser` `dialAndCall` uses, so the
    /// two entry points can no longer diverge. Still a separate function
    /// from `dialAndCall` (returns a target instead of starting a call and
    /// has its own error-message wiring) — only the divergent NAME
    /// resolution has been closed, not the two call-start paths themselves.
    @MainActor
    func resolveDialInput(_ rawInput: String) async -> ResolvedDialTarget? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Numero vuoto."
            return nil
        }
        guard let token = authService.loadToken(), !token.isEmpty else {
            errorMessage = "Sessione non autenticata."
            return nil
        }
        let backendConfig = pinnedConfig(token: token)
        let provider = BCryptoBackendProvider(config: backendConfig)

        // Step A — short extension (digits only, length <= 7).
        let digitsOnly = trimmed.allSatisfy { $0.isNumber }
        if digitsOnly, trimmed.count <= 7, let ext = Int64(trimmed) {
            do {
                guard let profile = try await provider.accountApi.lookupByExtension(ext) else {
                    errorMessage = "Interno \(ext) non assegnato — verifica il numero e riprova."
                    return nil
                }
                let label = DisplayName.forUser(
                    profile.userId, serverDisplay: profile.displayName,
                    knownExtension: String(ext))
                return ResolvedDialTarget(userId: profile.userId, displayLabel: label)
            } catch {
                errorMessage = "Risoluzione interno \(ext) fallita: \(error.localizedDescription)"
                return nil
            }
        }

        // Step B — E.164 (+...) via contacts/discover-v2.
        if trimmed.hasPrefix("+") {
            do {
                let normalized = try PhoneHashHelper.normalizeE164(trimmed)
                let v2 = BCryptoContactsDiscoverV2Client(
                    baseUrl: URL(string: serverUrl)!,
                    bearerTokenProvider: { [weak self] in self?.authService.loadToken() })
                let pepper = try await v2.fetchPepper()
                let hash = try PepperedPhoneHash.hash(phone: normalized, pepperBytes: pepper.pepperBytes)
                let entries = try await v2.discover(alg: pepper.alg, hashes: [hash])
                guard let entry = entries.first else {
                    errorMessage = "Numero \(normalized) non risulta tra gli utenti registrati."
                    return nil
                }
                let userId = entry.userId
                let label = DisplayName.forUser(
                    userId, serverDisplay: entry.displayName, knownPhoneNumber: normalized)
                return ResolvedDialTarget(userId: userId, displayLabel: label)
            } catch {
                errorMessage = "Risoluzione \(trimmed) fallita: \(error.localizedDescription)"
                return nil
            }
        }

        // Step C — fallback: assume it's already a userId.
        return ResolvedDialTarget(userId: trimmed, displayLabel: DisplayName.shortUserFallback(trimmed))
    }

    /// UserDefaults key namespace for the server-fetched peer Ed25519 identity
    /// key cache (spec §5c server trust source). Per-peer key so reads are O(1)
    /// and thread-safe (UserDefaults synchronises its own access).
    private static func serverPeerKeyDefaultsKey(_ userId: String) -> String {
        "qaudion.serverpeerkey." + userId
    }

    /// Best-effort warm of the server-fetched identity-key cache for `userId`
    /// BEFORE the handshake verify needs it (kicked at call_incoming for the
    /// caller and at startCall for the callee). Safe to call repeatedly; ONLY a
    /// valid RAW 32-byte key is ever written (404 / transport error / garbage →
    /// no write, so the verifier falls through to bundle-TOFU rather than
    /// aborting). Fire-and-forget; captures only locals so it never retains
    /// self.
    private func prefetchServerPeerKey(_ userId: String) {
        guard !userId.isEmpty, let provider = liveProvider else { return }
        let defaultsKey = Self.serverPeerKeyDefaultsKey(userId)
        Task {
            if let raw = await provider.kmsClient.fetchUserIdentityKey(userId: userId),
               raw.count == 32 {
                UserDefaults.standard.set(raw, forKey: defaultsKey)
            }
        }
        // D11: also warm the published per-device SET (trust-on-publish floor).
        prefetchServerPeerKeySet(userId)
    }

    /// D11 UserDefaults key namespace for the server-published per-device SET
    /// cache (`GET …/identity-key?all=1`). Per-peer; stored as `[Data]` (each a
    /// RAW 32-byte Ed25519 key). UserDefaults synchronises its own access.
    private static func serverPeerKeySetDefaultsKey(_ userId: String) -> String {
        "qaudion.serverpeerkeyset." + userId
    }

    /// Best-effort warm of the D11 published-key-SET cache for `userId` BEFORE
    /// the handshake verify needs it (kicked alongside `prefetchServerPeerKey`).
    /// Fire-and-forget; writes ONLY a non-empty set of valid 32-byte keys. An
    /// empty result (404 / transport error) leaves the cache as-is, so the
    /// verifier degrades to legacy pin-only TOFU (NEVER a fatal mismatch).
    /// Captures only locals so it never retains self.
    private func prefetchServerPeerKeySet(_ userId: String) {
        guard !userId.isEmpty, let provider = liveProvider else { return }
        let setKey = Self.serverPeerKeySetDefaultsKey(userId)
        Task {
            let set = await provider.kmsClient.fetchUserIdentityKeySet(userId: userId)
            let valid = set.filter { $0.count == 32 }
            if !valid.isEmpty {
                // Store as a plain [Data] array; the resolver re-wraps into a Set.
                UserDefaults.standard.set(Array(valid), forKey: setKey)
            }
        }
    }

    func startCall(contactId: String, video: Bool = false) async {
        RTLog.info("call", "startCall contactId=\(contactId.prefix(8))… video=\(video)")
        // D11: a fresh outgoing call clears any stale unauthenticated-change
        // banner from a previous call.
        callIdentityUnauthenticatedChange = false
        // W-ASSURANCE: same reset for the fresh outgoing call.
        callAssuranceState = nil
        callAssuranceExpectedNfc = false
        callMutualNfcInCommon = false
        callPskMixedThisCall = false
        callPeerVoiceKeyEnrolled = false
        // WIRE_SPEC §8.1: a fresh outgoing call clears any stale "peer
        // paused their camera" state from a previous call.
        remoteVideoPaused = false
        localVideoPaused = false
        // #2 (server-fetch trust source): warm the peer's server identity key
        // so the handshake verify of the callee's ACCEPT has the §5c server key.
        prefetchServerPeerKey(contactId)
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
        drainPendingOfferReplays(for: contactId)  // W-OFFERBUFFER (defensive; caller path)
        callState = .connecting
        isInCall = true
        isVideoCall = video
        // Unified call UI — arm the 1 Hz crypto-engine sampler for this call.
        startCryptoMeter()
        // Item 5 — arm the 5 Hz voice-confidence wave sampler for this call.
        startVoiceConfidenceWaveSampler()
        // WIRE_SPEC §8.3 — we placed the call → impolite on any later glare.
        originalCallRole = .caller
        // PersistentCallRecord — register outgoing call. Use activeCallKitId if
        // already set, otherwise mint a placeholder id that endCall will match.
        // The id is updated to the real outgoingCallId once beginAndroidOutgoing
        // runs below; here we use a stable per-session key derived from contactId
        // + startedAt so the record can be matched by endCall(id:).
        let _outgoingRecordId: String = UUID().uuidString
        // W574b — peer label resolution chain for OUTGOING calls. The old
        // code consulted only ContactsStore: a peer dialed by extension
        // (not saved as a contact) fell straight to the UUID truncation
        // "a0184f04…4b8f", which then got SHOWN in-call AND persisted in
        // the history record — so every redial kept showing the UUID
        // (user report 310d3304).
        //
        // W-EXTPREFIX consolidation (2026-07-29): this used to be a further
        // independent copy of the resolution chain — its own UUID-only
        // check (no placeholder-awareness for the ContactsStore name, the
        // dialer label, OR the history record), plus its own digit-token
        // scan to recover an extension from the resolved string (same
        // fragile pattern as `LiveInCallScreen.cachedPeerShortNumber`).
        // The "last real history record" signal is still consulted (a
        // peer dialed by extension but never saved as a contact still
        // benefits from an earlier call's resolved label/extension on
        // redial) but now flows THROUGH `DisplayName.forUser` /
        // `resolvedExtension` as an extra candidate, instead of being a
        // side-channel that bypassed the placeholder check entirely.
        let _dialerLabel = incomingCallerName.trimmingCharacters(in: .whitespaces)
        let _historyRecord = PersistentCallRecordStore.shared.records.first(where: {
            $0.peerUserId == contactId
                && !$0.peerDisplayName.isEmpty
                && !$0.peerDisplayName.contains("…")
        })
        let _candidateLabel: String? = !_dialerLabel.isEmpty ? _dialerLabel : _historyRecord?.peerDisplayName
        let _historyExt: String? = (_historyRecord?.peerExtension
            ?? PersistentCallRecordStore.shared.records
                .first(where: { $0.peerUserId == contactId && $0.peerExtension != nil })?.peerExtension)
            .flatMap { $0 > 0 ? String($0) : nil }
        let _outgoingPeerDisplay: String = DisplayName.forUser(
            contactId, serverDisplay: _candidateLabel, knownExtension: _historyExt,
            contacts: self.cachedContacts)
        // W-CALLBOOK (2026-07-29) — mark the callee as call-linked (see the
        // matching comment on the incoming-call path above) so the rubrica
        // auto-save path is allowed to run for them once the profile fetch
        // resolves. Outgoing calls carry no wire caller_display for the
        // CALLEE (that field only ever describes what THIS device presents
        // to the other side), so no phone signal is passed here — the
        // callee's opt-in public-profile phone number is the only source.
        NameResolutionService.markCallLinkedPeer(contactId)
        // PBX extension for the record — same candidates as the display
        // name above, resolved via the dedicated extension-only primitive
        // instead of scanning the resolved display string for a digit
        // token (which silently returned nil for any real, non-numeric name).
        let _outgoingPeerExt: Int? = DisplayName.resolvedExtension(
            for: contactId, serverDisplay: _candidateLabel, knownExtension: _historyExt,
            contacts: self.cachedContacts).flatMap { Int($0) }
        // Feed the in-call screen: LiveInCallScreen falls back to
        // incomingCallerName when the peer is not in contacts. Without this,
        // calls started OUTSIDE the dialer (history redial, contact row)
        // displayed the truncated UUID even when a good label was known.
        if _dialerLabel.isEmpty && !_outgoingPeerDisplay.contains("…") {
            incomingCallerName = _outgoingPeerDisplay
        }
        activeOutgoingRecordId = _outgoingRecordId
        PersistentCallRecordStore.shared.beginCall(
            id: _outgoingRecordId,
            peerUserId: contactId,
            peerDisplayName: _outgoingPeerDisplay,
            direction: .outgoing,
            isVideo: video,
            peerExtension: _outgoingPeerExt
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
                        self.clearKeyConfirmationState(callId: cid)
                        self.callState = .ended
                        self.isInCall = false
                        self.callContactId = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.callState = .idle
                        }
                    }
                }
                // call_busy — recipient is already in another answered call.
                // Sibling of onCallPeerOffline: today the outgoing call would
                // ring forever (server never sends call_ready/hangup for a busy
                // peer). Stop ringing immediately, briefly show "Occupato", and
                // tear down cleanly — identical teardown to the peer-offline path.
                ws.onCallBusy = { [weak self] _, _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.errorMessage = "Occupato"
                        self.callService.endCall()
                        let cid = (self.liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId()
                        CallMediaTelemetry.shared.recordEnded(callId: cid, reason: "busy")
                        self.clearKeyConfirmationState(callId: cid)
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
                // W-NOCALLKIT — when callKitFreeMode is ON the app uses NO CallKit
                // for outgoing calls either: mint a local call id and self-activate
                // the audio session via the SAME fallback the CallKit-nil/failure
                // branches already use (CallService Bug-B path). Flag OFF keeps the
                // proven CXStartCallAction outgoing integration unchanged.
                if CallsGate.callKitFreeMode {
                    let localId = UUID()
                    await MainActor.run {
                        self.activeCallKitId = localId
                        self.callService.handleAudioSessionActivated()
                    }
                    return
                }
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
                // Phase-10b: wire the handshake-signing closures (sign OFFER +
                // verify ACCEPT + TOFU pin) on the caller-side integration.
                wireHandshakeSigning(on: integration)
                // Phase B: wire the earbud GATT proxy for V4 KDF fp_adv operations.
                integration.earbudPairingGattProxy = earbudGattProxy.isConnected ? earbudGattProxy : nil
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
                // W574g — race-free M-15 relay sealer install (caller side).
                integration.onRelaySessionReady = { [weak self, weak integration] sessionKey, cid in
                    Task { @MainActor [weak self, weak integration] in
                        guard let self = self, !cid.isEmpty else { return }
                        // W574x — directional relay-sealer keys when both peers
                        // negotiated srtpDirKeyV1. Role A = the lexicographically-
                        // smaller userId (same rule as Android/Desktop). peerId =
                        // the callee (contactId).
                        let selfId: String = self.currentUserId ?? ""
                        let peerId: String = contactId
                        let neg: Bool = integration?.negotiatedSrtpDirKey ?? false
                        let useDir: Bool = neg && !selfId.isEmpty && !peerId.isEmpty
                        let roleA: Bool = useDir ? PqcRtpFrameSealer.selfIsRoleA(selfId, peerId) : false
                        self.callService.installRelaySealers(
                            sessionKey: sessionKey, callId: cid,
                            srtpDirKeyV1: useDir, selfIsRoleA: roleA)
                        // W-GRPDIAG-4 — see persistMessagePsk doc above.
                        self.persistMessagePsk(sessionKey: sessionKey, callId: cid, peerContactId: peerId)
                    }
                }
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
                        // W574e/g — M-15 sealer install moved to the race-free
                        // integration.onRelaySessionReady callback (wired below).
                        // Bind broker on first use; idempotent.
                        CallSessionKeyBroker.shared.bind(
                            getCallContactId: { [weak self] in self?.callContactId },
                            setSessionKey: { [weak self] in self?.callPqcSessionKey = $0 },
                            setPskActive: { [weak self] in self?.pskActive = $0 },
                            setPskName: { [weak self] in self?.pskName = $0 },
                            setPskMethod: { [weak self] in self?.pskMethod = $0 },
                            setPskFingerprint: { [weak self] in self?.pskFingerprint = $0 },
                            onSessionEstablished: { [weak self] peerId in self?.handleCallSessionEstablished(peerId: peerId) }
                        )
                        CallSessionKeyBroker.shared.registerPqcSessionKey(
                            sharedSecret, for: peerId)
                    }
                }
                // DISPLAY-ONLY: caller JSON path PSK metadata (mirror of the
                // responder wiring above). Resolves name+method app-side.
                integration.onPqcSessionKeyEstablishedWithPsk = { [weak self] sharedSecret, pskFp in
                    let peerId = contactId
                    let weakSelf = self
                    Task { @MainActor in
                        guard let strongSelf = weakSelf else { return }
                        guard sharedSecret.contains(where: { $0 != 0 }) else { return }
                        guard strongSelf.callContactId == peerId else { return }
                        let meta = AppState.resolvePskDisplayMeta(fingerprint: pskFp)
                        CallSessionKeyBroker.shared.registerPqcSessionKeyWithPsk(
                            sharedSecret,
                            for: peerId,
                            pskFingerprint: pskFp,
                            pskName: meta.name,
                            pskMethod: meta.method)
                        // vkey-v1: publish raw PSK so K_video salt == Android.
                        strongSelf.callVideoPsk = AppState.resolvePskBytes(fingerprint: pskFp)
                        #if canImport(WebRTC)
                        if let ctrl = strongSelf.webRtcController as? QAudionWebRtcCallController {
                            ctrl.videoContactPsk = strongSelf.callVideoPsk
                        }
                        #endif
                    }
                }

                // Phase 18 — v4 ratchet bootstrap from the call handshake (matches
                // Android). The integration supplies the REAL §2.5 / chain-
                // derivation inputs — transcriptHash (offer_binding), self + peer
                // Ed25519 identities — all byte-identical to Android's via the
                // shared signed handshake. selfEpochId/peerEpochId are the 16-zero
                // cross-platform constant (Android zeroEpoch). The integration only
                // fires when every input is real, so no placeholder reaches here.
                integration.onV4BootstrapReady = { peerId, effectiveSecret, transcriptHash, selfIdentityPub, peerIdentityPub in
                    Task {
                        let ok = AppState.sharedV4Ratchet.bootstrapV4AndPersist(
                            peerId: peerId,
                            effectiveSecret: effectiveSecret,
                            selfEpochId: Data(count: 16),
                            peerEpochId: Data(count: 16),
                            selfIdentityPub: selfIdentityPub,
                            peerIdentityPub: peerIdentityPub,
                            transcriptHash: transcriptHash
                        )
                        print("[PQC_DIAG_V4] bootstrapV4AndPersist peer=\(peerId.prefix(8)) ok=\(ok)")
                    }
                }
                // W-KCMAC (ship step 5) — caller leg. See `handleKcMacReady`'s doc.
                integration.onKcMacReady = { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleKcMacReady(event)
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
                    isVideoCall = false
                    callContactId = nil
                    return
                } catch {
                    print("[AppState] beginAndroidOutgoing failed for callId=\(outgoingCallId.prefix(8))…: \(error)")
                    errorMessage = "Avvio chiamata fallito: \(error.localizedDescription)"
                    callService.endCall()
                    callState = .idle
                    isInCall = false
                    isVideoCall = false
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
                // WIRE_SPEC §8.7 — publication rides the RX render gate
                // (parked until the receiver cryptor is ready, 2s failsafe).
                controller.onRemoteVideoTrack = { [weak self] track in
                    Task { @MainActor [weak self] in
                        self?.publishRemoteVideoTrackGated(track)
                    }
                }
                // WIRE_SPEC §8.7 — receiver readiness → call_media_ready
                // (dedup per call+mid inside sendCallMediaReadyOnce).
                controller.onInboundVideoReady = { [weak self] mid in
                    Task { @MainActor [weak self] in
                        self?.sendCallMediaReadyOnce(mid: mid)
                    }
                }
                // WIRE_SPEC §8.7 (INT-4a) — receiver decode stall → nudge sender.
                controller.onVideoStallDetected = { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.requestKeyframeFromSender()
                    }
                }
                // Remote-readable video diagnostics (mirrors Android). Ships
                // outbound/inbound video RTP stats + remote-track arrival to
                // the server so an iOS→Android video failure is diagnosable
                // without a Mac console session.
                controller.videoTelemetry = { [weak self] kind, attrs in
                    TelemetryService.shared.emit(kind: kind, attrs: attrs)
                    // VIDEODIAG — feed the arrived/decoded counters off the
                    // EXISTING 3s stats poll (thread-safe class; any thread).
                    self?.videoDiag.noteVideoStats(kind: kind, attrs: attrs)
                }
                // W-DCAUDIO — RX: inbound sealed-audio DataChannel frames →
                // CallService decrypt + playback (same path as the WS
                // "audio_frame" handler). TX is wired once in the callService
                // config block (sendAudioOverDataChannel).
                controller.onAudioDataChannelFrame = { [weak self] data in
                    self?.callService.handleIncomingDataChannelAudio(data)
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
                    case .failed:
                        Task { @MainActor [weak self] in
                            self?.handleIceTermination(iceIsTerminal: true)
                        }
                    case .disconnected:
                        // W-ICEGRACE — recoverable, not terminal (see
                        // handleIceTermination). Android grants the same 3s.
                        Task { @MainActor [weak self] in
                            self?.handleIceTermination(iceIsTerminal: false)
                        }
                    default:
                        break
                    }
                }
                controller.onIceConnectionState = { [weak self] iceState in
                    switch iceState {
                    case .failed, .closed:
                        Task { @MainActor [weak self] in
                            self?.handleIceTermination(iceIsTerminal: true)
                        }
                    case .disconnected:
                        // W-ICEGRACE — recoverable, not terminal.
                        Task { @MainActor [weak self] in
                            self?.handleIceTermination(iceIsTerminal: false)
                        }
                    case .connected, .completed:
                        // Transport indicator: WebRTC path confirmed.
                        // If the user forced relay (TransportGate.forcesRelay)
                        // or the VPN routes everything through TURN, show "STD"
                        // (→ label "TURN"). Otherwise "PQC" (→ "P2P SRTP").
                        let isRelayForced = TransportGate.forcesRelay
                        Task { @MainActor [weak self] in
                            // W-ICEGRACE — ICE recovered: stand down the
                            // pending teardown countdown, the call lives on.
                            self?.cancelIceDisconnectGrace()
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
            clearKeyConfirmationState(callId: cid)
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
    ///
    /// W-ICEGRACE (2026-07-21) — `iceIsTerminal: false` (a plain
    /// `.disconnected`) no longer tears the call down immediately. ICE
    /// `.disconnected` is explicitly a RECOVERABLE state in the WebRTC spec
    /// (it routinely self-heals within a second or two on a WiFi/cellular
    /// hiccup); only `.failed`/`.closed` are terminal. Android has always
    /// treated it that way — `CallTransportFactory.kt:548` arms
    /// `DISCONNECT_GRACE_MS = 3_000L` and then falls back to the WS relay
    /// rather than hanging up — while iOS called `endCall()` on the very
    /// first `.disconnected` edge with ZERO grace. Device-verified on call
    /// f884668c (2026-07-21, iOS↔Android 1:1 audio): iOS killed the call at
    /// 21.9s (`call.media.summary` end_reason=user_hangup, mic tx frozen at
    /// 970 frames) 0.3s after Android logged its own "ICE DISCONNECTED —
    /// arming 3000ms grace" for the SAME call; Android survived and its own
    /// summary reports duration_ms=85098. Same wire event, opposite
    /// behavior — a pure platform-parity gap, live since 2026-05-18.
    ///
    /// The WS-relay fallback this grace buys time for ALREADY exists on iOS
    /// per-frame: `sendAudioOverDataChannel` (wired to
    /// `QAudionWebRtcCallController.sendAudioFrameData`) returns `false`
    /// whenever the sealed DataChannel isn't open and `CallService` then
    /// routes that frame over the WS relay. So the ONLY thing that was
    /// missing is not killing the call while that fallback does its job.
    @MainActor
    private func handleIceTermination(iceIsTerminal: Bool) {
        // F-1 (2nd-pass regression): C-3 made `isInCall` stay false until
        // the call is ANSWERED. So an ICE / connection failure DURING
        // setup (outgoing `.connecting`, incoming `.ringing`) — i.e. the
        // "can't even connect" case — was swallowed by the old
        // `guard isInCall` and left the call UI / CallKit wedged forever.
        // Tear down on any non-terminal call state, not just answered.
        let callIsLive: Bool
        switch callState {
        case .idle, .ended:
            callIsLive = false
        case .connecting, .ringing, .active, .encrypted:
            callIsLive = true
        }
        switch iceTerminationAction(callIsLive: callIsLive, iceIsTerminal: iceIsTerminal) {
        case .none:
            return
        case .endImmediately:
            cancelIceDisconnectGrace()
            self.endCall()
        case .endAfterGrace:
            // Already counting down from an earlier `.disconnected` edge —
            // don't restart the window (a flapping ICE would otherwise keep
            // pushing the deadline out forever).
            guard iceDisconnectGraceTask == nil else { return }
            RTLog.info("call", "ICE disconnected — arming \(Self.iceDisconnectGraceMs)ms grace before teardown (WS relay covers audio meanwhile)")
            iceDisconnectGraceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.iceDisconnectGraceMs) * 1_000_000)
                guard !Task.isCancelled, let self = self else { return }
                self.iceDisconnectGraceTask = nil
                // Re-check liveness: the call may have ended normally (user
                // hangup / peer hangup) while the grace was running.
                switch self.callState {
                case .idle, .ended:
                    return
                case .connecting, .ringing, .active, .encrypted:
                    RTLog.info("call", "ICE grace expired without recovery — ending call")
                    self.endCall()
                }
            }
        }
    }

    /// W-ICEGRACE — cancel a pending ICE-disconnect grace countdown. Called
    /// when ICE recovers (`.connected`/`.completed`), on a terminal ICE
    /// state, and on teardown so a stale timer can never reach into the
    /// NEXT call and end it.
    @MainActor
    private func cancelIceDisconnectGrace() {
        iceDisconnectGraceTask?.cancel()
        iceDisconnectGraceTask = nil
    }

    /// call_accepted two-flag latch (WIRE_SPEC §3.5) — runs the original
    /// call_answer state-advance (W521/W528) exactly once, the moment
    /// BOTH the local handshake and the callee's real-user accept have
    /// landed for the active call.
    @MainActor
    private func finalizeCallActive() {
        if self.callSasKeySource == .mlKem {
            self.callState = .encrypted
            RTLog.info("call", "call_answer: PQC already done — .ringing → .encrypted")
        } else {
            self.callState = .active
            RTLog.info("call", "call_answer: callee answered — .ringing → .active")
        }
        maybeExchangeAvatarOnCallConnect()
    }

    /// E2EE avatar transport (2026-07-30) — Pavel: "durante la chiamata ci
    /// stiamo già autenticando... in quel momento se hanno avatar/foto
    /// devono scambiarseli e memorizzarli". Before this fix, avatar
    /// exchange was wired ONLY to a successful chat-message decrypt
    /// (`maybeAnnounceAvatarTo`'s only caller) — two contacts who had
    /// only ever called each other, never messaged, never got an avatar
    /// at all, even though the call itself is a strong mutual
    /// authentication event (PQC ML-KEM handshake). Unlike Android's call
    /// handshake (`PqcHandshake.kt`), iOS's PQC call handshake does NOT
    /// itself derive a pairwise message PSK — that comes ONLY from
    /// `ContactKeyExchange`'s separate X25519 OFFER/ACCEPT protocol,
    /// previously triggered only at call END (`endCall()`, W564). Fired
    /// here too, at call CONNECT, so the PSK — and therefore the avatar
    /// exchange the OFFER/ACCEPT completion now also triggers (see
    /// `dispatchInboundOpaque`) — starts as early as possible during a
    /// LIVE call instead of only after hangup.
    ///
    /// Gated on "no PSK yet" so an ordinary call to an already-known
    /// contact doesn't re-send a redundant `KEY_EXCHANGE_OFFER` on every
    /// single call — `ContactKeyExchange.initiate` has no existing-PSK
    /// skip of its own (unlike `force`, which is for explicit desync
    /// recovery), so gating here is what keeps this call-connect hook
    /// from being wire-chatty for repeat contacts. When a PSK already
    /// exists, [maybeAnnounceAvatarTo] is called directly instead —
    /// covers the common case immediately rather than waiting for the
    /// next chat message.
    @MainActor
    private func maybeExchangeAvatarOnCallConnect() {
        // W-AVATARCALLEE (2026-08-01): every branch here logs. This whole
        // feature spent days un-diagnosable because its paths either exited
        // silently or logged via raw print() (which never reaches the remote
        // pipeline), so "no evidence" could not be told apart from "never
        // ran". A nil callContactId here used to be a completely silent
        // return, which would make the callee hook added in
        // performAcceptIncoming look like it had done nothing at all.
        guard let peerId = self.callContactId else {
            RTLog.warn("avatar", "call-connect exchange skipped — callContactId is nil")
            return
        }
        let hasPsk = (try? PairwiseChainKeyResolver.resolvePsk(
            peerId: peerId, vault: SovereignKeyVault()
        )) != nil
        // W-AVATARCOOLDOWN (2026-08-02): the log shipper's deny-scrub eats any
        // token containing "psk", so the first attempt at this line shipped as
        // `[REDACTED:blob] exchange [REDACTED:blob] [REDACTED:blob]` — the one
        // line that says which way a call-connect went, redacted into
        // uselessness. Branch word carries no "psk" substring now, and the two
        // preconditions that decide whether anything can be sent at all ride
        // along, so ONE call is enough to know why nothing happened.
        // Numeric values only: the redactor keeps `selffile=0` but blobs
        // `selffile=yes` (verified by running the shipper's own `redact_body`
        // over these exact strings), and a blobbed value is no evidence at all.
        let keyReady: Int = hasPsk ? 1 : 0
        let selfVer: Int = self.selfAvatarVersion
        let selfFile: Int = AvatarUploader.selfAvatarCacheURL != nil ? 1 : 0
        let line: String = "callconnect ready=\(keyReady) selfver=\(selfVer) selffile=\(selfFile)"
        RTLog.info("avatar", line)
        if hasPsk {
            maybeAnnounceAvatarTo(peerId, trigger: .callConnect)
        } else {
            // No pairwise PSK yet (the call's own PQC handshake does NOT
            // produce one — it persists a separate "call-<id>" key that
            // PairwiseChainKeyResolver deliberately does not look up). Kick
            // the X25519 OFFER now, at connect: Android answers with a QUAD
            // KEY_EXCHANGE_ACCEPT (0x0a), which dispatchInboundOpaque's
            // Path-A handler already follows with maybeAnnounceAvatarTo.
            // Before this hook reached the callee, the only OFFER a
            // call-only relationship ever sent came from endCall() — far too
            // late, with the app heading to background.
            triggerKeyExchange(with: peerId)
        }
    }

    /// call_accepted two-flag latch (WIRE_SPEC §3.5) — peer side. Fired
    /// from `ws.onCallAccepted`. Latches `callId` unconditionally (so an
    /// accept arriving BEFORE the local handshake finishes isn't lost),
    /// then finalizes immediately if the local handshake already stashed
    /// the same callId.
    @MainActor
    private func handleCallAccepted(callId: String) {
        self.callAcceptedCallId = callId
        guard self.callState == .ringing, self.localHandshakeReadyCallId == callId else { return }
        self.finalizeCallActive()
    }

    /// call_accepted rollout-safety net (WIRE_SPEC §3.5) — bounded 4s
    /// fallback so a caller talking to a not-yet-upgraded peer doesn't
    /// wait forever. No-ops if `call_accepted` already finalized the call
    /// (or the call moved on) by the time it fires.
    @MainActor
    private func armAcceptGateTimeout(callId: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.callState == .ringing, self.localHandshakeReadyCallId == callId else { return }
            RTLog.warn("call", "call_accepted not received within timeout, proceeding anyway callId=\(callId)")
            self.finalizeCallActive()
        }
    }

    /// W478 — answer an incoming call from the in-app ringing banner.
    /// Uses CXCallController so the same `provider(_:perform:CXAnswerCallAction)`
    /// delegate path fires as when the user taps Answer on the system sheet.
    /// Shared incoming-call accept path. Run by BOTH the CallKit answer
    /// (`onAnswerCall`, `dismissNativeUI=true`) and the CallKit-FREE path
    /// (`answerIncomingCall` when `CallsGate.callKitFreeMode`,
    /// `dismissNativeUI=false`). Idempotent via the Bug A guard. The crypto +
    /// signalling are unchanged — only WHO triggers the accept differs.
    @MainActor
    private func performAcceptIncoming(uuid: UUID, dismissNativeUI: Bool) {
        RTLog.info("call", "W-CALLFG-DIAG performAcceptIncoming ENTER uuid=\(uuid) dismissNativeUI=\(dismissNativeUI) alreadyAnswered=\(self.answeredCallKitId == uuid)")
        // Bug A — idempotent answer (CallKit/in-app/notification may all target
        // the same call). A repeat would re-enter activateIncomingCallAudio
        // mid-start → uncatchable NSException.
        if self.answeredCallKitId == uuid {
            print("[AppState] performAcceptIncoming: duplicate answer for \(uuid) ignored (Bug A guard)")
            return
        }
        self.answeredCallKitId = uuid
        self.isInCall = true
        RTLog.info("call", "W-CALLFG-DIAG performAcceptIncoming — isInCall=true set for uuid=\(uuid)")
        // W-1TO1RING — the ring screen has done its job, tear it down. All
        // accept entry points (CallKit native/in-app/notification) converge
        // here, so this is the single place to clear it.
        self.incomingCallRingVisible = false
        // Unified call UI — arm the 1 Hz crypto-engine sampler for this call.
        self.startCryptoMeter()
        // Item 5 — arm the 5 Hz voice-confidence wave sampler for this call.
        self.startVoiceConfidenceWaveSampler()
        self.activeCallKitId = uuid
        if self.callState == .ringing {
            self.callState = .active
        }
        // W-TELEMPARITY (2026-07-20) — per-call media lifecycle telemetry for
        // the ANSWER (callee) side. `startCall()` (the OUTGOING/caller path,
        // ~line 8646) has always called `CallMediaTelemetry.shared.
        // recordConnected(...)` right after entering `.active`; this callee
        // path never did. Root-caused on call 689eda51-49c8-4446-ba35-
        // 08d5cb82268d (2026-07-20, Android→iOS 1:1 audio call): server-side
        // telemetry showed a FULL call.media.connected/heartbeat(x30)/summary
        // trio from Android but ONLY a single call.encrypted line from iOS for
        // the entire 150s call — because `CallMediaTelemetry.currentCallId`
        // was never set to this call's id, so its idempotency guards
        // (`recordConnected`'s `cid == currentCallId`, `recordEnded`'s same
        // check) silently no-op'd `call.media.connected`, the 5s heartbeat
        // loop, and `call.media.summary` for every call where this device
        // was the CALLEE. `tune-report.py`'s per-call view depends on this
        // family to anchor+populate the iOS leg, so the leg rendered empty
        // despite iOS's telemetry-batch POSTs succeeding (200 OK) throughout.
        // `getActiveCallId()` is already bound here (bindIncomingCallId ran
        // in the `call_incoming` WS handler before the user could answer).
        if let cid = (self.liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId() {
            CallMediaTelemetry.shared.recordConnected(
                callId: cid,
                peerPrefix: String((self.callContactId ?? "").prefix(8)),
                sasSource: "answered"
            )
        }
        // W521: catch up to .encrypted if PQC completed during ringing.
        if self.callState == .active && self.callSasKeySource == .mlKem {
            self.callState = .encrypted
            RTLog.info("call", "performAcceptIncoming: PQC handshake completed during ringing — state .active → .encrypted")
            TelemetryService.shared.emit(
                kind: "call.encrypted",
                callId: uuid.uuidString.lowercased(),
                attrs: ["path": "answer-fastpath-w521"]
            )
        }
        // call_accepted (WIRE_SPEC §3.5) — a real user just accepted this
        // call (CallKit answer / in-app banner / CallKit-free path all
        // converge here). Distinct from the automatic call_answer
        // network-readiness signal. Only send site in the app.
        if let calling = self.liveProvider?.callingApi {
            Task { try? await calling.sendCallAccepted(callId: uuid.uuidString.lowercased()) }
        }
        // W-AVATARCALLEE (2026-08-01): the CALLEE's avatar hook. Until now
        // `maybeExchangeAvatarOnCallConnect()` was reachable ONLY from
        // `finalizeCallActive()`, whose three inbound edges (the call_answer
        // WS handler, `handleCallAccepted`, and the accept-gate timeout) all
        // fire on frames that only the CALLER ever receives — the callee
        // SENDS call_answer/call_accepted and the server relays them to the
        // peer only. So on every call where this device answered, the avatar
        // exchange never even started. Proven on call 83ef71fa (2026-08-01
        // 19:59 UTC, Android→iOS): the server saw ZERO msg_send and ZERO blob
        // uploads for the whole call, and this device's own log has none of
        // finalizeCallActive's "call_answer:" markers (tag "call", shipped
        // since v1.0.570 — their absence is affirmative proof, not a logging
        // gap). Fire it here, on the single point every accept path converges
        // through, so answering a call is as good a trigger as placing one.
        self.maybeExchangeAvatarOnCallConnect()
        // W450 + cold-start race: boot audio + notify caller (latched/replayed
        // when the responder integration isn't ready yet).
        self.consumeDeferredAnswerIfReady("performAcceptIncoming")
        if dismissNativeUI {
            // W-WAKEONLY — dismiss the native CallKit UI so the SAS screen shows.
            self.dismissNativeCallUIAfterAnswer(uuid)
        }
        // CallKit-free: no native UI. Audio self-activates without CallKit's
        // onAudioSessionActivated via CallService.activateIncomingCallAudio's
        // Bug B fallback (configureForVoIP best-effort setActive + 0.7s
        // self-activate), reached via consumeDeferredAnswerIfReady →
        // startIncomingCallAudioOnAnswer.
    }

    func answerIncomingCall() {
        stopInAppRingtone()
        guard let uuid = activeCallKitId else { return }
        if CallsGate.callKitFreeMode {
            // W-NOCALLKIT — no CallKit; run the accept path directly.
            performAcceptIncoming(uuid: uuid, dismissNativeUI: false)
        } else {
            Task { try? await callKit?.answerCall(uuid: uuid) }
        }
    }

    /// W478 — decline an incoming call from the in-app ringing banner.
    /// Delegates to endCall() which sends call_hangup to the server and
    /// reports the call ended to CallKit with `.declined` reason.
    func declineIncomingCall() {
        endCall()
    }

    // MARK: - Unified call UI — crypto-engine meter sampler

    /// Arm the 1 Hz crypto-engine sampler for the current call. Idempotent:
    /// invalidates any prior timer first, so calling it from both the outgoing
    /// (`startCall`) and incoming (`performAcceptIncoming`) `isInCall = true`
    /// sites is safe. The timer reads the ground-truth `CallService` frame
    /// counters and publishes the per-second delta as `cryptoOpsPerSec` — a
    /// pure READ, never touching the frame-counting hot path. AppState is
    /// `@MainActor`; the timer's target closure hops back to MainActor so the
    /// `@Published` write happens on the main actor.
    private func startCryptoMeter() {
        cryptoMeterTimer?.invalidate()
        cryptoMeterLastTotal = callService.framesEncryptedTx &+ callService.framesDecryptedRx
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let total = self.callService.framesEncryptedTx &+ self.callService.framesDecryptedRx
                let delta = total &- self.cryptoMeterLastTotal
                self.cryptoMeterLastTotal = total
                self.cryptoOpsPerSec = delta > 0 ? Int(delta) : 0
            }
        }
        // .common so the meter keeps ticking while a UITrackingRunLoopMode
        // interaction (e.g. a scroll on the call surface) is in progress.
        RunLoop.main.add(timer, forMode: .common)
        cryptoMeterTimer = timer
    }

    /// Stop the crypto-engine sampler and zero its readout. Called from
    /// `endCall()` so the meter never ticks between calls and the next call
    /// starts from a clean 0 (the ribbon hides the meter when ops == 0).
    private func stopCryptoMeter() {
        cryptoMeterTimer?.invalidate()
        cryptoMeterTimer = nil
        cryptoMeterLastTotal = 0
        cryptoOpsPerSec = 0
    }

    // MARK: - Item 5 (2026-07-31 InCallScreen Android→iOS port) — live
    //         voice-confidence wave sampler

    /// Arm the 5 Hz `voiceConfidenceHistory` sampler for the current call.
    /// Same idempotent/lifecycle pattern as `startCryptoMeter()` immediately
    /// above — call from both the outgoing and incoming `isInCall = true`
    /// sites. Reads `ConfidenceIndex.scoreHistory` off whichever
    /// `QAudionCallIntegration` is actually active (caller vs responder —
    /// same fallback `routeInboundCallPiggyBack`'s FPSET branch already
    /// uses), a pure READ behind that class's own `NSLock`, never touching
    /// the audio-processing hot path.
    private func startVoiceConfidenceWaveSampler() {
        voiceWaveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let integration = self.callService.callIntegration ?? self.responderCallIntegration
                self.voiceConfidenceHistory = integration?.getGuardianMode().getConfidenceIndex().scoreHistory ?? []
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        voiceWaveTimer = timer
    }

    /// Stop the wave sampler and clear its readout. Called from `endCall()`
    /// so the wave never ticks between calls and the next call starts from
    /// an empty history (the flat-line neutral state).
    private func stopVoiceConfidenceWaveSampler() {
        voiceWaveTimer?.invalidate()
        voiceWaveTimer = nil
        voiceConfidenceHistory = []
    }

    // MARK: - Items 2 + 5 (2026-07-31 InCallScreen Android→iOS port) —
    //         call-connect hook: auto voice-enrollment + VOICE_KEY announce

    /// Fired once this call's REAL PQC session key is established for
    /// `peerId` — wired as `CallSessionKeyBroker`'s `onSessionEstablished`
    /// closure (see `connectPersistentSocket`/the two other
    /// `CallSessionKeyBroker.shared.bind(...)` call sites), the single
    /// convergence point every handshake-completion code path (caller,
    /// responder, PSK-metadata variant) already funnels through — mirrors
    /// Android's `CallController.onConnected`. May fire more than once for
    /// the same connect (`onPqcSessionKeyEstablished` and
    /// `onPqcSessionKeyEstablishedWithPsk` can both land) — both callees
    /// below are written to be safe under a duplicate call.
    private func handleCallSessionEstablished(peerId: String) {
        // Tier 2 ("voce remota") — mirrors Android's `onConnected`
        // (`voicePrintBridge.setActiveContact(peerId.value)`), the same
        // unified hook Feature B's `maybeAutoStartVoiceLearning` below
        // already uses. Idempotent (a no-op if `peerId` is already the
        // active contact) — also wired defensively at the `CallService`
        // level (`onStateChanged(.active)` for outgoing,
        // `activateIncomingCallAudio(contactId:)` for incoming) in case a
        // future call-setup path doesn't funnel through this closure;
        // calling both is safe, never double-enrolls or double-counts.
        callService.activateContactVoiceVerification(contactId: peerId)
        maybeAutoStartVoiceLearning(for: peerId)
        startVoiceKeyAnnounceLoop(peerId: peerId)
    }

    /// W-AUTOLEARN parity (Android 2026-07-31) — "voce verificata" no
    /// longer waits for a manual tap: the first time this call's session
    /// key lands for a contact with no existing `VoiceprintStore` template,
    /// silently start the same ~3s background enrollment against the live
    /// RX audio `startVoiceLearning()` already uses. No-op on every later
    /// call once a template exists. Guarded against the double-fire
    /// `handleCallSessionEstablished` documents: only starts when no
    /// session is already running/finished for this call.
    private func maybeAutoStartVoiceLearning(for peerId: String) {
        guard callContactId == peerId else { return }
        switch voiceLearningState {
        case .inProgress, .completed:
            return
        default:
            break
        }
        guard !VoiceprintStore().hasTemplate(contactId: peerId) else { return }
        RTLog.info("call", "auto-starting voice learning for new contact=\(peerId.prefix(8))…")
        startVoiceLearning()
    }

    /// W-VOICEKEYRETRY / W-VOICEKEYPERSIST parity (Android 2026-07-30/31) —
    /// announce THIS device's own Voice-as-Key enrollment to the peer over
    /// the opaque_message piggy-back channel (`VOICE_KEY:1`/`VOICE_KEY:0`),
    /// and keep re-announcing for the whole call rather than a single
    /// fire-and-forget send: a real device-pair repro on Android showed a
    /// one-shot announce silently lost on the relay for an entire call.
    /// Fast burst (`voiceKeyAnnounceRetries`× at
    /// `voiceKeyAnnounceRetryIntervalMs`) covers the common transient-
    /// packet-loss-at-connect case; after that, a low-rate persistent
    /// re-announce (`voiceKeyAnnouncePersistIntervalMs` ± jitter) self-heals
    /// within one interval no matter what caused the original miss — cheap
    /// (one tiny opaque_message roughly every 20s), never blocks/gates the
    /// call either way. Jitter is applied ONLY on the persist phase: both
    /// peers start this loop at roughly the same connect moment, so a FIXED
    /// persist interval would keep both devices' sends in near-lockstep for
    /// the rest of the call — if one cycle ever lands inside
    /// `OpaqueSelfEchoFilter`'s match window it would recur every cycle
    /// after. Jitter breaks that phase-lock (W-SELFECHOSYMMETRIC parity).
    private func startVoiceKeyAnnounceLoop(peerId: String) {
        voiceKeyAnnounceTask?.cancel()
        let enrolled = VoiceprintStore().hasTemplate(contactId: VoiceprintStore.deviceOwnerId)
        voiceKeyAnnounceTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.announceVoiceKeyEnrollment(enrolled: enrolled, peerId: peerId)
                attempt += 1
                let intervalMs: Int
                if attempt <= Self.voiceKeyAnnounceRetries {
                    intervalMs = Self.voiceKeyAnnounceRetryIntervalMs
                } else {
                    intervalMs = Self.voiceKeyAnnouncePersistIntervalMs
                        + Int.random(in: -Self.voiceKeyAnnounceJitterMs...Self.voiceKeyAnnounceJitterMs)
                }
                try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            }
        }
    }

    /// Fast-burst retry count before switching to the persist-phase cadence.
    private static let voiceKeyAnnounceRetries = 5
    /// Fast-burst interval (ms) — matches Android's
    /// `VOICE_KEY_ANNOUNCE_RETRY_INTERVAL_MS`, deliberately ABOVE
    /// `OpaqueSelfEchoFilter`'s 2s match window so a device's own pending
    /// entry always expires between sends.
    private static let voiceKeyAnnounceRetryIntervalMs = 3_000
    /// Persist-phase base interval (ms) — matches Android's
    /// `VOICE_KEY_ANNOUNCE_PERSIST_INTERVAL_MS`.
    private static let voiceKeyAnnouncePersistIntervalMs = 20_000
    /// Persist-phase jitter (± ms) — matches Android's
    /// `VOICE_KEY_ANNOUNCE_JITTER_MS`.
    private static let voiceKeyAnnounceJitterMs = 4_000

    /// Ship a single VOICE_KEY announce — mirrors `announceScreenShare`'s
    /// shape exactly (same `getActiveCallId()` guard, same fire-and-forget
    /// error handling). Marks the wire string as sent in
    /// `OpaqueSelfEchoFilter` BEFORE sending so the (near-certain) server
    /// bounce-back is recognized and dropped rather than mistaken for the
    /// peer's own announce.
    @MainActor
    private func announceVoiceKeyEnrollment(enrolled: Bool, peerId: String) async {
        // Only for the call this loop was armed for — if the call ended (or
        // a different call started) since the last tick, the loop's own
        // `Task.isCancelled` check will catch up on the NEXT iteration, but
        // this guard prevents ever sending a stale-peer announce in the gap.
        guard callContactId == peerId else { return }
        guard let provider = liveProvider,
              let impl = provider.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId(), !callId.isEmpty
        else { return }
        let wire = CallPiggyBack.serializeVoiceKey(callId: callId, enrolled: enrolled)
        OpaqueSelfEchoFilter.shared.markSent(wire)
        do {
            try await provider.callingApi.sendOpaqueMessageString(recipientId: peerId, payload: wire)
        } catch {
            print("[AppState] VOICE_KEY announce failed: \(error)")
        }
    }

    /// "Voce storica" — maps `state` to the wire-level scale and sends
    /// `OWNER_CONT` to the peer only on a real transition (never
    /// polled/periodic, unlike VOICE_KEY's retry+persist loop above — see
    /// `CallPiggyBack.ownerContinuity`'s doc for why the wire cost is near
    /// zero for the overwhelming majority of calls). A single noisy
    /// `.mismatch` tick is downgraded to `.uncertain` on the wire unless
    /// `OwnerContinuityMonitor`'s own hysteresis streak has actually
    /// tripped (`callService.ownerContinuityShouldAlert()`) — mirrors
    /// Android's `onConnected` watcher exactly, so the PEER is never
    /// false-alarmed by one bad window.
    @MainActor
    private func maybeAnnounceOwnerContinuity(_ state: OwnerContinuityMonitor.State) {
        let level: ContactVoiceContinuityGate.Level
        switch state {
        case .inactive:
            level = .unknown
        case .scored(_, let ownerLevel):
            switch ownerLevel {
            case .verified:  level = .verified
            case .uncertain: level = .uncertain
            case .mismatch:  level = callService.ownerContinuityShouldAlert() ? .mismatch : .uncertain
            }
        }
        guard level != lastSentOwnerContinuityLevel else { return }
        lastSentOwnerContinuityLevel = level
        guard let peerId = callContactId else { return }
        Task { await sendOwnerContinuityAnnounce(level: level, peerId: peerId) }
    }

    /// Ship a single OWNER_CONT announce — mirrors `announceVoiceKeyEnrollment`'s
    /// shape exactly (same `getActiveCallId()` guard, same fire-and-forget
    /// error handling, same `OpaqueSelfEchoFilter` self-echo guard).
    @MainActor
    private func sendOwnerContinuityAnnounce(level: ContactVoiceContinuityGate.Level, peerId: String) async {
        guard callContactId == peerId else { return }
        guard let provider = liveProvider,
              let impl = provider.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId(), !callId.isEmpty
        else { return }
        let wire = CallPiggyBack.serializeOwnerContinuity(callId: callId, level: level.rawValue)
        OpaqueSelfEchoFilter.shared.markSent(wire)
        do {
            try await provider.callingApi.sendOpaqueMessageString(recipientId: peerId, payload: wire)
        } catch {
            print("[AppState] OWNER_CONT announce failed: \(error)")
        }
    }

    func endCall() {
        // H-6: idempotency — a second endCall() while teardown is
        // already in flight (CallKit onEndCall racing a remote
        // call_hangup) must be a no-op, otherwise we double-hangup the
        // controller and leak the RTCPeerConnection.
        stopInAppRingtone()
        // W-1TO1RING — covers decline (declineIncomingCall → endCall),
        // caller hangup before answer, and any other teardown path: the
        // ring screen must never outlive the call it was ringing for.
        incomingCallRingVisible = false
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

        // W-NOCALLKIT review H1: skip CallKit teardown in callKitFreeMode — the
        // call was never reported to CallKit, so reportCallEnded would target a
        // UUID CXProvider never saw. Flag OFF path is byte-identical to before.
        if let uuid = activeCallKitId, !CallsGate.callKitFreeMode {
            Task { [weak self] in
                await self?.callKit?.reportCallEnded(uuid: uuid, reason: .userEnded)
            }
        }
        // NIM-fix1: log the call-session UUID, not the raw peer userId, to
        // avoid leaking the social graph through auto-uploaded VPS telemetry.
        let callLogId: String = activeOutgoingRecordId ?? "none"
        RTLog.info("call", "endCall — callId=" + callLogId + " state=\(callState)")

        // W-ENDCALLID (2026-07-26) — `call.end` was shipping the LOCAL persistent
        // record id, not the wire call id, and un-lowercased. Measured on the box:
        // every `call.end` landed in an orphan call of its own — `8B392E49` next to
        // the real `8b392e49`, `498AAF5A` and `A778B3BE` matching nothing at all —
        // so `terminal_state` and `end_reason`, the two fields that say HOW a call
        // died, were never joinable to the call that died. 122 of 138 events had an
        // id and not one of them was usable.
        //
        // The wire id is `callingApi.getActiveCallId()`, the same value every other
        // event on this leg uses, and it is read BEFORE the teardown below clears
        // the provider. Lowercased for the same reason line ~10164 already does it:
        // Swift's `UUID.uuidString` is uppercase and the wire id is not, which is
        // why this file is littered with `caseInsensitiveCompare` workarounds.
        // The record id stays as the fallback — losing the event entirely would be
        // worse than an id that at least ties to the local call record.
        // The downcast mirrors every other reader of this value in this file (see the
        // `onCallVideoState` handler): `getActiveCallId()` lives on the concrete impl,
        // not on the `CallingApi` protocol.
        let wireCallId = (liveProvider?.callingApi as? BCryptoCallingApiImpl)?.getActiveCallId()
        let endCallId = (wireCallId ?? (callLogId == "none" ? nil : callLogId))?.lowercased()

        // W541-3: telemetry event for call end. callState carries the
        // terminal state which the maintainer correlates with peer's
        // own endCall event to detect "iPhone went encrypted but S24
        // gave up at ringing" patterns.
        TelemetryService.shared.emit(
            kind: "call.end",
            callId: endCallId,
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
            // W-KCMAC — drop this call's key-confirmation state. AFTER
            // `callService.endCall()` above (which already read
            // `getKeyConfirmationTelemetry` during its own teardown).
            clearKeyConfirmationState(callId: cid)
        }
        callState = .ended
        isInCall = false
        isVideoCall = false
        deepfakeAlert = false
        // Unified call UI — drop the Guardian voice-biometrics snapshot so
        // it doesn't leak into the next call's security sheet before the
        // first analysis result of that new call arrives.
        voiceAnalysis = nil
        // Unified call UI — drop the last spectrum frame too, so the ribbon
        // bars decay to rest between calls (mirrors the reset above).
        voiceSpectrum = nil
        // Feature B — drop any in-flight/last learning-session state so a
        // stale "Voce imparata" badge doesn't leak into the next call's UI
        // before a new session (if any) reports its own state.
        voiceLearningState = nil
        // Tier 1/Tier 2 — same reasoning: a stale "voce storica"/"voce
        // remota" shield state must not leak into the next call's UI before
        // that call's own first real tick arrives.
        ownerContinuityState = .inactive
        lastSentOwnerContinuityLevel = nil
        peerOwnerContinuityLevel = .unknown
        contactVoiceLevel = .unknown
        // Unified call UI — stop the 1 Hz crypto-engine sampler and zero its
        // readout so the meter hides between calls and the next call starts
        // from 0 (mirrors the voiceAnalysis reset directly above).
        stopCryptoMeter()
        // Item 5 — stop the voice-confidence wave sampler, same lifecycle.
        stopVoiceConfidenceWaveSampler()
        // Item 2 — stop re-announcing VOICE_KEY for the call that just ended,
        // and drop the peer's cached enrollment fact so it doesn't leak into
        // the next call's trust bar before a fresh announce (if any) arrives.
        voiceKeyAnnounceTask?.cancel()
        voiceKeyAnnounceTask = nil
        callPeerVoiceKeyEnrolled = false
        // W564 — proactively trigger X25519 key exchange with the peer right
        // before clearing callContactId. After a call both sides have done a
        // PQC ML-KEM handshake (strong auth) so this is the ideal moment to
        // also establish the pairwise PSK used for E2EE chat messages.
        // Without this, the FIRST message sent after a call uses a deterministic
        // fallback PSK; if one side has a STALE PSK from an old exchange stored
        // in the vault, the other uses the fallback → mismatch → "[messaggio
        // cifrato non leggibile]". Triggering now ensures both sides refresh to
        // a fresh X25519 shared secret before any post-call message is sent.
        // Fire-and-forget (triggerKeyExchange is try?-wrapped inside).
        if let peer = callContactId { triggerKeyExchange(with: peer) }
        callContactId = nil
        incomingCallerName = ""
        activeCallKitId = nil
        answeredCallKitId = nil  // Bug A — re-arm the idempotent-answer guard for the next call
        incomingAudioStarted = false  // re-arm the deferred-answer consume for the next call
        localHandshakeReadyCallId = nil  // call_accepted latch — re-arm for the next call
        callAcceptedCallId = nil  // call_accepted latch — re-arm for the next call
        pendingNotificationAnswer = false  // W-NOCALLKIT — drop any stale latched answer
        pendingNotificationDecline = false // W-NOCALLKIT — drop any stale latched decline
        selfManagedAudioSession = false  // W-WAKEONLY — re-arm for the next call
        // earbud-relay-v1 — drop the one-shot counterparty state so the
        // next earbud call starts a fresh responder (fresh FW-H7 counter).
        earbudCounterparty.reset()
        // W534 — drop any sticky peer-screen-share state from this call
        // so the next call starts with a clean UI. Per SCREEN_SHARE_
        // PROTOCOL.md the call_hangup envelope is authoritative for
        // teardown; we do NOT need (and the spec explicitly says not to
        // send) a final `SCREEN_SHARE:stop` here.
        peerScreenShareActive = false
        // WIRE_SPEC §8.1 — drop any sticky "peer paused their camera" state
        // so the next call starts clean (same reasoning as peerScreenShareActive
        // above: this is UI-only signalling state, not renegotiated per call).
        remoteVideoPaused = false
        localVideoPaused = false
        // media-consent v1 — per-call consent + pending dialogs/watchdogs
        // die with the call.
        videoConsentGranted = false
        upgradeBuildInProgress = false
        audioPinnedToWsRelay = false
        pendingIncomingUpgrade = nil
        pendingUpgradeAutoDeclineTask?.cancel()
        pendingUpgradeAutoDeclineTask = nil
        upgradeResponseTimeoutTask?.cancel()
        upgradeResponseTimeoutTask = nil
        pendingOutgoingUpgradeMedia = nil
        originalCallRole = nil  // WIRE_SPEC §8.3 — next call re-derives its role
        decodeOnlyPipelineForPeerScreen = false
        // WIRE_SPEC §8.7 — drop this call's call_media_ready dedup keys
        // (keys embed the call_id so growth, not correctness, is at stake).
        mediaReadySentKeys.removeAll()
        // W339: drop the PQC session key so the SAS panel hides on the
        // next call setup. Holding stale key material across calls
        // would otherwise let one call's verified SAS appear on the
        // next, unverified call.
        callPqcSessionKey = nil
        // Task 10: drop the pinned video sealer identity alongside the
        // session key so a stale (callId, selfIsRoleA) can't leak into the
        // next call's video pipeline.
        activeVideoCallIdentity = nil
        // vkey-v1: drop the per-call video PSK salt so a stale key from this
        // call can't seed the next call's K_video.
        callVideoPsk = nil
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
        // W-CALLSPKR — drop the latched speaker preference alongside the
        // route reset above so it can't leak into the next call.
        callSpeakerOn = false
        // W-MUTEBTNSRC — same lifetime: a mute latched at the end of one call
        // must not open the next one showing a muted mic.
        callMuted = false
        // W-ICEGRACE — kill any pending ICE-disconnect countdown for the call
        // being torn down here. Without this a grace armed at the very end of
        // one call could fire 3s later, find the NEXT call live in
        // .connecting/.ringing, and end it — turning a one-off hiccup into a
        // cross-call kill. (endCall() is idempotent, but the timer must not
        // outlive its own call regardless.)
        iceDisconnectGraceTask?.cancel()
        iceDisconnectGraceTask = nil
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
        // WIRE_SPEC §8.7 — reset the RX render gate (parked track,
        // failsafe watchdog, readiness memo) for the next call.
        resetRemoteVideoRenderGate()
        // VIDEODIAG — cancel the per-call self-heal watchdog + counters.
        stopVideoDiagWatchdog(reason: "endCall")
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
        // W-MUTEBTNSRC — publish it so every surface follows, including when the
        // change came from CallKit rather than from one of our buttons.
        callMuted = muted
    }

    /// Feature B ("voce verificata") — manual trigger for
    /// `LiveInCallScreen`'s "Avvia apprendimento voce" button. No-op if
    /// there is no bound call peer. `voiceLearningState` publishes progress
    /// via the `onVoiceLearningStateChanged` observer wired in `init()`.
    func startVoiceLearning() {
        guard let peer = callContactId else { return }
        callService.startVoiceLearning(contactId: peer)
    }

    /// Cancel an in-flight voice-learning session (e.g. the call ended, or
    /// the user backed out of the flow) without persisting a partial result.
    func cancelVoiceLearning() {
        callService.cancelVoiceLearning()
        voiceLearningState = nil
    }

    func setSpeaker(_ enabled: Bool) {
        // W520: route audio to the external loudspeaker (or back to the earpiece).
        //
        // W-CALLSPKR — latch the preference BEFORE touching the session so
        // a didActivate refire that lands mid-toggle still sees the
        // intended end state.
        callSpeakerOn = enabled
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
            #if !targetEnvironment(simulator)
            var opts: AVAudioSession.CategoryOptions = [
                .allowBluetoothHFP,
                .interruptSpokenAudioAndMixWithOthers
            ]
            #else
            var opts: AVAudioSession.CategoryOptions = [
                .interruptSpokenAudioAndMixWithOthers
            ]
            #endif
            if enabled { opts.insert(.defaultToSpeaker) }
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
            RTLog.info("call", "setSpeaker(" + String(describing: enabled) + ") ok")
        } catch {
            let msg: String = error.localizedDescription
            RTLog.warn("call", "setSpeaker failed: " + msg)
        }
        updateProximityMonitoring()
    }

    /// W-EARTOUCH (2026-07-27) — 1:1-call parity with Android's
    /// `ProximityScreenLock`/`ProximityScreenPolicy` (W-EARTOUCH there too):
    /// while a call is genuinely up (`.active`/`.encrypted` — never merely
    /// `.ringing`/`.connecting`, so an unanswered call can't blank the
    /// screen) AND the live audio route is the built-in earpiece (not
    /// speaker/Bluetooth/wired — same route-based rule Android uses),
    /// enable `UIDevice.isProximityMonitoringEnabled`. iOS then handles the
    /// screen-off (and, as an inherent side effect, touch-suppression) and
    /// the automatic restore the moment the sensor clears — no separate
    /// notification observer needed for the base behavior, unlike Android's
    /// wake-lock object there is no manual acquire/release here, just the
    /// one flag. Self-gating exactly like Android: this never dims
    /// anything unless something is genuinely close to the sensor.
    ///
    /// Deliberately 1:1-only. Group calls are hands-free-only by design
    /// (`routeGroupCallAudioToSpeaker()` forces speaker unconditionally,
    /// W-GRPSPKR) — there is no "held to the ear" UX to protect there, so
    /// nothing calls this for a group call and `isProximityMonitoringEnabled`
    /// simply stays at its default `false`.
    ///
    /// Called from every `callState` transition (its own `didSet` above)
    /// and from `setSpeaker(_:)` (a route change that does NOT change
    /// `callState`) — together these cover every way the "are we at the
    /// ear" answer can change: answer/end, and manual/automatic route
    /// switches.
    @MainActor
    private func updateProximityMonitoring() {
        guard callState == .active || callState == .encrypted else {
            if UIDevice.current.isProximityMonitoringEnabled {
                UIDevice.current.isProximityMonitoringEnabled = false
                RTLog.info("call", "W-EARTOUCH updateProximityMonitoring — call not active (state=\(callState)), disabled")
            }
            return
        }
        let onEarpiece = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .builtInReceiver
        }
        if UIDevice.current.isProximityMonitoringEnabled != onEarpiece {
            UIDevice.current.isProximityMonitoringEnabled = onEarpiece
            RTLog.info("call", "W-EARTOUCH updateProximityMonitoring — onEarpiece=\(onEarpiece), isProximityMonitoringEnabled=\(onEarpiece)")
        }
    }

    /// W-GRPSPKR (2026-07-20, live 5-way call 694147de): group calls have NO
    /// speaker toggle and NO hold-to-ear UX — the surface is a hands-free
    /// participant grid — yet nothing ever routed their playback off the
    /// session default. `CallKitProvider` (CXStartCallAction / didActivate)
    /// installs `.playAndRecord`/`.voiceChat` WITHOUT `.defaultToSpeaker`,
    /// so on iPhone the LiveKit room's decoded remote audio played through
    /// the EARPIECE: server telemetry showed the leg decoding thousands of
    /// frames while the user heard nothing. iPad has no receiver port, so
    /// the identical build sounded fine there — exactly the reported
    /// asymmetry. Mirrors `setSpeaker(true)`'s two-step category+override
    /// lock, but guarded on the built-in receiver being the CURRENT output
    /// route so it never hijacks Bluetooth/wired routes (and no-ops on
    /// iPad/simulator). Idempotent — safe to re-assert from every hook that
    /// can stomp the route: the group `.active` transition, CallKit's
    /// `didActivate` (which re-installs plain `.voiceChat` mid-call), and
    /// each remote-audio-track subscribe (LiveKit's engine start applies
    /// its own session config AFTER `.active` fired).
    func routeGroupCallAudioToSpeaker() {
        let session = AVAudioSession.sharedInstance()
        let onReceiver = session.currentRoute.outputs.contains {
            $0.portType == .builtInReceiver
        }
        guard onReceiver else { return }
        do {
            #if !targetEnvironment(simulator)
            let opts: AVAudioSession.CategoryOptions = [
                .allowBluetoothHFP,
                .interruptSpokenAudioAndMixWithOthers,
                .defaultToSpeaker
            ]
            #else
            let opts: AVAudioSession.CategoryOptions = [
                .interruptSpokenAudioAndMixWithOthers,
                .defaultToSpeaker
            ]
            #endif
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: opts)
            try session.overrideOutputAudioPort(.speaker)
            RTLog.info("call", "group-call speaker route applied (was receiver)")
        } catch {
            RTLog.warn("call", "group-call speaker route failed: " + error.localizedDescription)
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
    ///
    /// 2026-07-29 fix (call b3d9f465, W-VIDDIAG) — this used to special-case
    /// `webRtcController == nil` into a WS-relay-ONLY branch that skipped any
    /// WebRTC attempt outright (own comment: "if the peer is actually
    /// Android/Desktop (WebRTC), this branch is WRONG... yields one-way/black
    /// video"). It was wrong for exactly this incident: audio had fallen back
    /// to the WS relay (peer lacks dc-mux-v1 / ICE never converged) while the
    /// Android peer still only renders real WebRTC RTP video — so the
    /// WS-relay-only branch produced a black/purple screen with zero
    /// `video_frame` ever reaching the server from either side.
    /// `performWebRtcVideoUpgrade` below already degrades to the identical
    /// WS-HEVC-only behavior whenever `webRtcController` is nil or the SDP
    /// renegotiation throws — so routing through it unconditionally removes
    /// the premature nil-check instead of duplicating (and mis-selecting) its
    /// own safe fallback.
    func upgradeToVideo() {
        guard isInCall, !isVideoCall else { return }
        guard let peerId = callContactId, !peerId.isEmpty else {
            RTLog.warn("call", "upgradeToVideo: callContactId nil — aborting")
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
        //   4. VideoCallPipeline is already running (started in
        //      performWebRtcVideoUpgrade below, before the WebRTC attempt),
        //      so the WS-relay HEVC path carries video too — Android DOES
        //      consume WS `video_frame` while its transport is in
        //      BcryptoWsRelay mode (`CallController.kt` arms
        //      `BcryptoWsVideoRelayTransport` whenever
        //      `mode == BcryptoWsRelay && videoActive`), which is exactly
        //      the state a `dc-mux-v1`/ICE fallback puts it in — this
        //      WS-relay leg is not a no-op for cross-platform peers.
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
        guard let provider = liveProvider,
              let impl = provider.callingApi as? BCryptoCallingApiImpl,
              impl.getActiveCallId() != nil
        else {
            RTLog.warn("call", "upgradeToVideo: callId unavailable — leaving call audio-only")
            return
        }
        // W563 — start the WS-HEVC VideoCallPipeline FIRST so iOS↔iOS video
        // works even when the WebRTC SDP renegotiation fails or is not needed.
        // Previously, isVideoCall + camera + pipeline were only set AFTER a
        // successful controller.upgradeToVideo() call. If that threw (e.g.
        // alreadyHasVideo, videoAddFailed, wrong-state) the caller never
        // started its camera → zero video from caller, UI appeared "blocked".
        // The WS-HEVC path is the primary iOS↔iOS video transport; WebRTC
        // renegotiation is needed for Android/desktop interop but is optional
        // for iOS↔iOS. Starting the pipeline before the WebRTC path guarantees
        // the caller's camera is always live.
        //
        // W571 — pre-check camera permission: if denied, surface the settings
        // prompt and leave the call in audio-only mode (isVideoCall stays false).
        let camAuth = AVCaptureDevice.authorizationStatus(for: .video)
        if camAuth == .denied || camAuth == .restricted {
            errorMessage = "Per attivare il video concedi l'accesso alla fotocamera in Impostazioni → Q-Audion."
            return
        }
        self.isVideoCall = true
        self.setCamera(true)
        // media-consent v1: the pipeline starts PAUSED — camera + mirror
        // preview are live locally, but no frame leaves the device (neither
        // WS-HEVC fragments nor WebRTC bridge pushes) until the peer accepts.
        await startVideoPipeline(for: peerId, startPaused: true)
        // W571 — rollback if the pipeline failed (permission denied at request
        // time, camera unavailable, WS missing). videoPipeline is set inside
        // startVideoPipeline only on success.
        guard self.videoPipeline != nil else {
            self.isVideoCall = false
            self.setCamera(false)
            return
        }
        RTLog.info("call", "upgradeToVideo: WS-HEVC pipeline started (paused) for \(peerId.prefix(8))…")

        // Attempt WebRTC SDP renegotiation for Android/desktop cross-platform.
        // Failure is non-fatal — the WS-HEVC path above already carries video.
        guard let controller = webRtcController as? QAudionWebRtcCallController else {
            RTLog.info("call", "upgradeToVideo: no WebRTC controller — WS-HEVC only (iOS↔iOS)")
            await sendUpgradeConsentRequest(to: peerId, sdp: "", media: "camera")
            return
        }
        // W-VIDUPCALLER — tell the controller VideoCallPipeline (started above)
        // owns the camera, so upgradeToVideo()'s startCameraCapture() creates a
        // WebRTCPixelBufferCapturer instead of its own RTCCameraVideoCapturer.
        // MUST be set before upgradeToVideo() — startCameraCapture() reads this
        // flag synchronously while building the offer. Without it, the
        // controller opens a SECOND, independent AVCaptureSession that
        // contends with VideoCallPipeline.captureSession (the one
        // LocalCameraPreview is bound to) for the same camera hardware —
        // the local self-preview goes black even though the controller's own
        // session keeps streaming real frames to the peer over WebRTC RTP.
        // Mirrors the callee-side upgrade wiring (acceptPendingIncomingUpgrade,
        // above) and the initial-outgoing/-incoming video call wiring
        // (startCall / handleIncomingWebRtcOffer).
        controller.useExternalVideoSource = true
        // W-VIDUPCALLER-CAPS (2026-07-11) — plumb the peer's capabilities into
        // the controller BEFORE upgradeToVideo() so ensureVideoSealer() picks
        // the native AES-256 video cryptor AND keys it. Device-verified root
        // cause of iOS-caller→Desktop one-way black video (call b78dcc77 et al,
        // telemetry 2026-07-11: use_sframe=false, out_bytes=0, in_frames_rec=0,
        // no call_media_ready): on the iOS-CALLER path the peer's caps arrive
        // only via Desktop's control-only `call_answer` (empty sdp), whose
        // handler stashes them in `pendingPeerCapabilities` (AppState.swift
        // :4110) but SKIPS `handleIncomingWebRtcAnswer` — the ONLY place that
        // otherwise calls `controller.acceptPeerCapabilities` (:4132 else
        // branch). So the live controller's `peerNegotiated()` stays empty →
        // `useSFrame=false` → `videoSealer` latches `.legacy` → the native
        // FrameCryptor is installed but NEVER keyed → discardFrameWhenCryptorNotReady
        // silently drops 100% of encoded frames in BOTH directions (out_bytes=0
        // and in_frames_rec=0) → no RTP video either way + call_media_ready
        // never fires. The RESPONDER path already plumbs caps
        // (acceptPendingIncomingUpgrade → acceptPeerCapabilities, :9189), which
        // is exactly why Desktop-CALLER→iOS video works while iOS-CALLER→Desktop
        // does not. `acceptPeerCapabilities` clears the `.legacy` latch + re-runs
        // the sealer pick (QAudionWebRtcCallController.swift:1177-1190), so the
        // native cryptor gets keyed once (the PQC key is already present during
        // the live audio call). Mirrors the responder path; no-op when caps are
        // absent (leaves the legacy fail-closed behaviour untouched).
        if let caps = pendingPeerCapabilities, !caps.isEmpty {
            controller.acceptPeerCapabilities(caps)
        }
        do {
            let offerSdp = try await controller.upgradeToVideo()
            // W-VIDUPCALLER — bridge VideoCallPipeline's captured frames into
            // the WebRTC RTCVideoSource now that upgradeToVideo() has created
            // webrtcPixelBufferCapturer (via startCameraCapture, gated on
            // useExternalVideoSource above). Belt-and-braces alongside the
            // useExternalVideoSource flag: with the flag alone (fix above),
            // the controller's OWN RTCCameraVideoCapturer path is correctly
            // skipped and the dual-AVCaptureSession conflict is gone — but
            // without ALSO wiring this bridge, webrtcPixelBufferCapturer
            // exists yet is never pushed a single frame, so it would carry
            // NOTHING to Android (worse than the pre-fix state, which at
            // least streamed real frames from its own capturer). This is
            // the same class of gap the responder-side comment above
            // documents ("W-VIDTX"). Mirrors that fix + the
            // startCall/acceptIncomingCall wiring for the caller-initiated
            // MID-CALL upgrade path, which never received it.
            #if os(iOS)
            if let capturer = controller.webrtcPixelBufferCapturer {
                self.videoPipeline?.onCapturedPixelBuffer = { [weak capturer] pixelBuffer, timestampNs in
                    capturer?.push(pixelBuffer, rotation: ._0, timestampNs: timestampNs)
                }
            }
            #endif
            await sendUpgradeConsentRequest(to: peerId, sdp: offerSdp, media: "camera")
        } catch QAudionWebRtcCallController.ControllerError.alreadyHasVideo {
            // Peer raced us; their upgrade offer arrives via wireUpgradeHandlers.
            // Their request will show OUR consent dialog (or auto-accept if
            // consent is already granted) — hold our frames meanwhile.
            RTLog.info("call", "upgradeToVideo: already in video — peer raced us")
        } catch {
            // WebRTC renegotiation failed — the WS-HEVC path still works for
            // iOS↔iOS, but consent is required either way.
            RTLog.warn("call", "upgradeToVideo WebRTC renegotiation failed (non-fatal): " + error.localizedDescription)
            await sendUpgradeConsentRequest(to: peerId, sdp: "", media: "camera")
        }
        #else
        // No WebRTC: go straight to WS-HEVC (paused until consent).
        self.isVideoCall = true
        self.setCamera(true)
        await startVideoPipeline(for: peerId, startPaused: true)
        await sendUpgradeConsentRequest(to: peerId, sdp: "", media: "camera")
        RTLog.warn("call", "upgradeToVideo: WebRTC not available — WS-HEVC only")
        #endif
    }

    /// media-consent v1 — ship OUR `call_upgrade_request` and arm the 30s
    /// response watchdog. On timeout the camera/preview roll back exactly
    /// like an explicit decline.
    @MainActor
    private func sendUpgradeConsentRequest(
        to peerId: String, sdp: String, media: String
    ) async {
        guard let impl = liveProvider?.callingApi as? BCryptoCallingApiImpl,
              let callId = impl.getActiveCallId() else {
            RTLog.warn("call", "sendUpgradeConsentRequest: no active callId — rolling back")
            if media == "camera" {
                isVideoCall = false
                setCamera(false)
                videoPipeline?.stop()
                videoPipeline = nil
            }
            return
        }
        pendingOutgoingUpgradeMedia = media
        do {
            try await impl.sendCallUpgradeRequest(
                callId: callId, recipientId: peerId, sdp: sdp, media: media)
            RTLog.info("call", "call_upgrade_request shipped media=\(media) — awaiting response")
        } catch {
            RTLog.warn("call", "sendCallUpgradeRequest failed: " + error.localizedDescription)
        }
        upgradeResponseTimeoutTask?.cancel()
        upgradeResponseTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self = self,
                  self.pendingOutgoingUpgradeMedia != nil else { return }
            RTLog.info("call", "upgrade response timeout — treating as decline")
            self.handleUpgradeResponse(
                callId: callId, senderId: self.callContactId ?? "", accepted: false, sdp: "")
        }
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
        guard let peerId = callContactId, !peerId.isEmpty else {
            RTLog.warn("call", "startScreenShare: callContactId nil — aborting")
            errorMessage = "Impossibile avviare la condivisione: peer sconosciuto."
            return
        }
        // media-consent v1: screen share works from an AUDIO-ONLY call and
        // NEVER opens the camera (the old W538 flow ran a full camera
        // upgrade first — privacy bug). Transport setup without camera:
        //   - WebRTC peers: add the video transceiver with
        //     useExternalVideoSource=true (creates the pixel-buffer capturer,
        //     no camera) and ship a media="screen" re-offer — peers
        //     auto-accept without a consent dialog.
        //   - iOS↔iOS WS relay: bring the pipeline up in .external mode
        //     (encoder only, no camera/permission) and feed ReplayKit
        //     frames via submitExternalFrame.
        #if canImport(WebRTC)
        var capturer: WebRTCPixelBufferCapturer?
        if let controller = webRtcController as? QAudionWebRtcCallController {
            if controller.webrtcPixelBufferCapturer == nil {
                RTLog.info("call", "startScreenShare: adding camera-less video transceiver (media=screen)")
                controller.useExternalVideoSource = true
                do {
                    let offerSdp = try await controller.upgradeToVideo()
                    await sendUpgradeConsentRequest(to: peerId, sdp: offerSdp, media: "screen")
                } catch QAudionWebRtcCallController.ControllerError.alreadyHasVideo {
                    // Transceiver already negotiated — capturer exists below.
                } catch {
                    RTLog.warn("call", "startScreenShare: screen renegotiation failed: " + error.localizedDescription)
                }
            }
            capturer = controller.webrtcPixelBufferCapturer
        }
        #else
        let capturer: WebRTCPixelBufferCapturer? = nil
        #endif
        // WS-HEVC leg (iOS↔iOS): make sure an encoding pipeline exists.
        // On a video call the camera pipeline is already up — we suspend its
        // camera feed below. On an audio call bring up an external-source
        // pipeline (no camera, no permission prompt).
        if videoPipeline == nil {
            await startVideoPipeline(for: peerId, sourceMode: .external)
        }
        guard capturer != nil || videoPipeline != nil else {
            RTLog.warn("call", "startScreenShare: no transport available (WebRTC capturer nil, pipeline nil)")
            errorMessage = "Condivisione schermo non disponibile: trasporto video non pronto."
            return
        }
        // Capture (and clear) the current camera-frame closure so we can
        // restore it on stop; suspend the camera→encoder feed so screen and
        // camera frames don't interleave in the HEVC stream.
        preScreenShareCameraClosure = videoPipeline?.onCapturedPixelBuffer
        videoPipeline?.onCapturedPixelBuffer = nil
        videoPipeline?.externalFeedActive = true
        // Screen frames must flow even if the camera path was consent-paused
        // (sharing the screen is itself the user's explicit choice).
        videoPipeline?.setVideoPaused(false)
        screenShareController.onFrame = { [weak self] pixelBuffer, ts in
            self?.videoPipeline?.submitExternalFrame(pixelBuffer, presentationTimeNs: ts)
        }
        do {
            try await screenShareController.start(into: capturer)
            isScreenSharing = true
            RTLog.info("call", "startScreenShare: ReplayKit capture live (camera untouched)")
            // W538: fire-and-forget peer announce so cross-platform
            // peers can mount the screen-share video sink with the
            // right badge. If the peer doesn't support the SCREEN_SHARE
            // protocol, the opaque message is harmlessly ignored —
            // local capture is unaffected.
            Task { @MainActor [weak self] in
                await self?.announceScreenShare(active: true)
            }
        } catch {
            // Restore the camera path if start failed so the call
            // doesn't get stuck without any video producer.
            videoPipeline?.onCapturedPixelBuffer = preScreenShareCameraClosure
            videoPipeline?.externalFeedActive = false
            screenShareController.onFrame = nil
            preScreenShareCameraClosure = nil
            let msg: String = error.localizedDescription
            RTLog.warn("call", "startScreenShare failed: " + msg)
            errorMessage = msg
        }
        #endif
    }

    public func stopScreenShare() async {
        #if os(iOS)
        guard isScreenSharing else { return }
        await screenShareController.stop()
        // Restore the camera path so VideoCallPipeline frames once
        // again flow to the WebRTC capturer.
        videoPipeline?.onCapturedPixelBuffer = preScreenShareCameraClosure
        videoPipeline?.externalFeedActive = false
        preScreenShareCameraClosure = nil
        isScreenSharing = false
        // media-consent v1: if the pipeline existed only to encode the
        // screen on an audio-only call (external mode, no camera), tear it
        // down — the call drops cleanly back to voice.
        if !isVideoCall, let p = videoPipeline, p.sourceMode == .external,
           !peerScreenShareActive {
            p.stop()
            videoPipeline = nil
            abrController?.stop()
            abrController = nil
        }
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

            // Send over the shared persistent WS (liveProvider) instead of
            // opening a fresh per-send WebSocket — a second socket with the
            // same JWT/deviceID makes the server replace the persistent one
            // ("replacing stale ws device") and triggers a reconnect storm.
            // Pass the same msgId used for AAD so the server echoes it
            // verbatim and the receiver reconstructs the identical AAD.
            // W-ONESOCKET: ride the persistent WS only — never open a
            // throwaway socket for a single send (that made the server
            // replace the live device → reconnect storm + duplicate
            // apns-voip-token). If the persistent socket can't be brought up,
            // surface the failure instead of churning a zombie.
            guard let live = await ensurePersistentProviderConnected() else {
                errorMessage = "Send failed: no connection"
                return
            }
            _ = try await live.messageApi.sendMessage(
                recipientId: contactId, content: payload, clientMsgId: messageId)
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
                    // M-15: bind the derived key to this call session so the
                    // HKDF info string is "q-audion-srtp-master-v1:<callId>".
                    // Set pqcCallId BEFORE pqcSessionKey (didSet calls
                    // applyPqcSealerIfPossible which reads pqcCallId).
                    // M-15: canonical callId = lowercase wire call_id.
                    // UUID.uuidString is UPPERCASE — lowercased() normalises to
                    // the same string the other party received from the wire
                    // (all platforms send the callId lowercase in call_offer).
                    ctrl.pqcCallId = self.activeCallKitId?.uuidString.lowercased() ?? ""
                    // vkey-v1: set the K_video salt PSK before the session key so
                    // the first ensureVideoSealer derives the Android-matching
                    // K_video (salt = psk, not the default string).
                    ctrl.videoContactPsk = self.callVideoPsk
                    ctrl.pqcSessionKey = key
                    print("[AppState] PQC SRTP sealer key forwarded to WebRTC controller (\(key.count) bytes, callId=\(ctrl.pqcCallId))")
                }
                #endif
                // W394 + Task 10: rotate the video pipeline's sealer with
                // the new ML-KEM secret. From this moment forward, every
                // outbound fragment is sealed under the post-handshake
                // key and every inbound fragment is opened with it.
                // REUSES the (callId, selfIsRoleA) pinned by
                // startVideoPipeline (`activeVideoCallIdentity`) rather
                // than recomputing selfIsRoleA from `callContactId` here —
                // two independently-computed values could in principle
                // diverge (this closure has no direct access to
                // startVideoPipeline's `peerId`) and silently swap the
                // send/recv key assignment mid-call. The `callContactId`
                // fallback only fires if this notification somehow arrives
                // before startVideoPipeline ever pinned an identity, which
                // shouldn't happen (the pipeline itself is created there
                // first) — defensive, not the expected path.
                if let pipeline = self.videoPipeline {
                    let pinned = self.activeVideoCallIdentity
                    let videoCallId = pinned?.callId
                        ?? self.activeCallKitId?.uuidString.lowercased() ?? ""
                    let videoSelfIsRoleA = pinned?.selfIsRoleA
                        ?? PqcRtpFrameSealer.selfIsRoleA(self.currentUserId ?? "", self.callContactId ?? "")
                    pipeline.rotatePqcSealer(key, callId: videoCallId, selfIsRoleA: videoSelfIsRoleA)
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
                // Cold-start answer race — PQC key is now live. If the callee
                // answered the PushKit-woken call before the handshake finished,
                // this is the point its audio + .encrypted advance happen.
                self.consumeDeferredAnswerIfReady("sasReady")
            }
        }
    }
}

// MARK: - W372: group chat fan-out

extension AppState {
    /// Subscribe once at AppState init to the group message-send +
    /// sender_key_init fan-out notifications.
    ///
    /// W-GRPMSG: the group TEXT payload now ships as a SINGLE
    /// `group_msg_send` frame (server-side fan-out + self-echo),
    /// replacing the retired per-member `opaque_message` fan-out (W372).
    /// The `qa_grp:1` control envelopes (sender_key_init / rotate /
    /// member deltas) STILL ride the 1:1 ratchet on the opaque path —
    /// only the TEXT transport moved.
    func wireGroupChatFanOut() {
        NotificationCenter.default.addObserver(
            forName: AppState.groupMsgSendNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let groupId = note.userInfo?["groupId"] as? String,
                  let wire = note.userInfo?["wire"] as? Data,
                  let clientMsgId = note.userInfo?["clientMsgId"] as? String,
                  let groupEpoch = note.userInfo?["groupEpoch"] as? Int else {
                return
            }
            // Fase 1B — msg_type distinguishes text (0) from an attachment
            // descriptor (1). Absent ⇒ 0, so the text path is unchanged.
            let msgType = note.userInfo?["msgType"] as? Int ?? 0
            // `liveProvider` is main-actor-isolated; resolve it inside a
            // `@MainActor` Task so Swift 6 strict concurrency doesn't
            // complain about cross-actor capture in the (main-queue)
            // NotificationCenter closure.
            Task { @MainActor [weak self] in
                guard let ws = self?.liveProvider?.getWebSocketClient() else {
                    print("[AppState] group_msg_send dropped — no live WS")
                    return
                }
                // Byte-exact mirror of Android WsCommand.GroupMsgSend:
                // standard base64 (no wrap) of the raw 0xE4 wire, int
                // msg_type (0=TYPE_TEXT, 1=attachment), dashed-UUID group_id.
                ws.send(type: "group_msg_send", data: [
                    "group_id": groupId,
                    "encrypted_payload": wire.base64EncodedString(),
                    "msg_type": msgType,
                    "client_msg_id": clientMsgId,
                    "group_epoch": groupEpoch,
                ])
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
        // W-GRPDEL — an invite for a group this device deleted is still
        // surfaced: that prompt is exactly how the user gets back in, and
        // accepting it (`acceptGroupInvite`) is what lifts the tombstone.
        // Receiving one deliberately does NOT lift it — no local group state
        // is created here, so blocking the prompt would only take away the
        // way back, while auto-clearing would hand the resurrection hole to
        // anyone able to send us an envelope.
        if GroupTombstoneStore.shared.isTombstoned(env.g) {
            RTLog.info("groupdel", "invite prompt for tombstoned g=\(env.g.prefix(8))")
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
        // W-GRPDEL — accepting is the explicit act, so it is what lifts a
        // tombstone. Note the asymmetry with `handleInboundGroupInvite`,
        // which deliberately does NOT: merely RECEIVING an invite creates no
        // local group state, and clearing on receipt would let anyone who
        // can send us one re-open the resurrection hole for a group we
        // deleted.
        if GroupTombstoneStore.shared.isTombstoned(groupId) {
            guard !shouldSkipGroupResurrection(source: .acceptedInvite, hasTombstone: true) else {
                RTLog.info("groupdel", "invite accept refused g=\(groupId.prefix(8))")
                return
            }
            GroupTombstoneStore.shared.clear(groupId, reason: "acceptedInvite")
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
        // W-GRPMSG: the bootstrap above drained the W395 buffered ctl
        // envelopes (installing this group's recv chains). Group TEXT
        // frames that arrived via `group_msg_pending_sync` BEFORE the
        // registry entry existed were buffered in `bufferedGroupWires`
        // with no ACK — and the server has already MarkGroupDelivered'd
        // them after the pending-sync write, so they will NOT be
        // re-delivered on the next reconnect. Retrying only on inbound
        // sender_key_init/rotate (the other retry trigger) misses this
        // path because those inits were themselves buffered under W395
        // and replayed internally without an AppState signal. Drain now.
        retryBufferedGroupMessages()
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

        // SERVER REGISTRATION (Fase 1A, best-effort) — POST /api/v1/groups
        // BEFORE/alongside the P2P fan-out below. Android + Desktop both
        // register the group server-side on create; iOS previously skipped
        // this, so an iOS-CREATED group had NO server record → the group
        // TEXT transport (`group_msg_send`) returned NOT_A_MEMBER and the
        // add/remove REST endpoints 404'd for it. Reuses the same
        // authenticated, cert-pinned client the add/remove path uses. The
        // wire `group_id` is the dashed-UUID form the server + Android key
        // on (NOT the dash-stripped hex `GroupRegistry` keys on). Idempotent:
        // if Android already created this group, the duplicate is rejected
        // (non-2xx) and we keep our local crypto state — never a hard-fail.
        if let groupIdWire = Self.hexToDashedUUID(gidBytes),
           let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken) {
            let regMembers = fullMembers
            let regAdmins = fullAdmins
            Task { @MainActor in
                guard let res = await api.createGroup(
                    groupIdWire: groupIdWire, members: regMembers, admins: regAdmins) else { return }
                if res.isSuccess {
                    GroupRegistry.shared.setEpoch(groupId: gidBytes, epoch: res.groupEpoch)
                    NotificationCenter.default.post(
                        name: AppState.groupRegistryChangedNotification,
                        object: nil, userInfo: ["groupId": gidBytes])
                } else {
                    // Already-exists / other server error — local state stays.
                    print("[AppState] createGroup: server registration HTTP \(res.statusCode) for \(groupIdWire) (kept local state)")
                }
            }
        }

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
            //
            // W-GRPDEL — this envelope names US as the added member, which
            // is an EXPLICIT re-add: it lifts a tombstone rather than being
            // blocked by one. (The `entry != nil` branch above cannot be
            // reached for a tombstoned group — the delete removed the row.)
            if GroupTombstoneStore.shared.isTombstoned(groupId) {
                guard !shouldSkipGroupResurrection(
                    source: .p2pMemberAddedNamingSelf, hasTombstone: true) else {
                    RTLog.info("groupdel", "p2p member_added refused g=\(groupId.prefix(8))")
                    return
                }
                GroupTombstoneStore.shared.clear(groupId, reason: "p2pMemberAddedNamingSelf")
            }
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
            // W-GRPMSG: same rationale as acceptGroupInvite — recv chains
            // just became available, so drain any group TEXT frames that
            // were buffered (and already server-marked-delivered via
            // pending_sync) before this auto-join bootstrapped the session.
            retryBufferedGroupMessages()
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
            let preMembers = entry.members
            GroupRegistry.shared.removeMember(groupId: groupId, userId: member)
            // Fase 1A — mirror the server-consumer forward-secrecy rekey on
            // the P2P channel too, so a P2P-only group (created iOS-side and
            // never registered server-side) still re-keys on removal. Bumps
            // our crypto epoch, rotates our own send chain, drops recv
            // chains, redistributes `sender_key_rotate`. Idempotent with the
            // parallel `group_membership_changed` server path (engine
            // `notMember` guard → the epoch advances exactly once).
            if let selfId = currentUserId, !selfId.isEmpty, member != selfId {
                applyRemovalRekey(groupHex: groupId, members: preMembers,
                                  selfId: selfId, removed: member)
            }
        }
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupId])
    }

    /// W403 — leave a group voluntarily ("Esci dal gruppo").
    ///
    /// W-GRPDEL (2026-08-02): this used to ship a P2P `member_left` envelope,
    /// drop the registry entry and invalidate the crypto session — and NEVER
    /// tell the server. `GET /api/v1/groups` therefore kept listing the group,
    /// and `reconcileAllGroupsFromServer` re-bootstrapped it seconds later,
    /// usually under the `xxxxxxxx…` hex placeholder because the metadata
    /// blob no longer decrypted. That is the "the group I left keeps coming
    /// back with a weird name" report, and it made those chats undeletable.
    ///
    /// Leaving and deleting are the same operation on this platform — once
    /// the row is gone there is no screen that can reach the history — so
    /// this now delegates to ``deleteGroupChat(groupId:)``, which does the
    /// three steps in order: server leave, full local purge, tombstone. The
    /// two entry points differ only in their UI copy (this one is the
    /// "Esci dal gruppo" row; the other is "Elimina chat").
    @MainActor
    public func leaveGroup(groupId: String) {
        deleteGroupChat(groupId: groupId)
    }

    // MARK: - W-GRPDEL: delete a group chat ("delete for me + leave")

    /// Remove a group chat from THIS device, whoever created it.
    ///
    /// Deliberately NOT gated on being creator or admin: any member may get
    /// a conversation off their own phone. What it does, in this order:
    ///
    ///   0. tell the remaining members over the 1:1 ratchet (`member_left`),
    ///      so a P2P-only group converges even if the server never hears;
    ///   1. `POST /api/v1/groups/{gid}/leave` — idempotent since server
    ///      commit 54c9f5d, so a group we already left answers 200;
    ///   2. purge ALL local state for the group (registry row, message
    ///      history + cached blobs, sender-key/vault crypto state, every
    ///      pending queue keyed on it);
    ///   3. write a persistent tombstone.
    ///
    /// **Steps 2 and 3 are unconditional.** If the leave call fails for any
    /// reason — offline, 401, 403, 5xx, timeout, cert pinning, no identity
    /// key — the local delete still happens and the user still sees the chat
    /// disappear. Making the purge depend on the network is exactly how this
    /// bug existed in the first place. The failure is surfaced in the
    /// `groupdel` log, not by refusing to delete.
    ///
    /// Fire-and-forget wrapper for UI call sites; `deleteGroupChatAndWait`
    /// is the awaitable form.
    @MainActor
    public func deleteGroupChat(groupId groupHex: String) {
        Task { @MainActor in
            _ = await self.deleteGroupChatAndWait(groupId: groupHex)
        }
    }

    /// Awaitable form of ``deleteGroupChat(groupId:)``. Returns what the
    /// server leave did, purely so a caller can surface a soft notice — the
    /// local delete has already happened by the time this returns, whatever
    /// the outcome says.
    @MainActor
    @discardableResult
    public func deleteGroupChatAndWait(groupId rawGroupId: String) async -> GroupLeaveOutcome {
        let groupHex = normalizedGroupTombstoneKey(rawGroupId)
        guard !groupHex.isEmpty else {
            RTLog.warn("groupdel", "delete aborted: empty group id")
            return .notAttempted
        }
        let selfId = currentUserId ?? AppState.currentUserIdSnapshot ?? ""
        let known: Int = GroupRegistry.shared.entry(for: groupHex) != nil ? 1 : 0
        let gShort: String = String(groupHex.prefix(8))
        let reqLine: String = "delete requested g=" + gShort + " known=" + String(describing: known)
        RTLog.info("groupdel", reqLine)

        // Step 0 — P2P courtesy notice to the remaining members, sent BEFORE
        // the purge because it needs the roster the purge is about to drop.
        shipMemberLeftEnvelope(groupHex: groupHex, selfId: selfId)

        // Step 1 — server leave (best-effort by design).
        let outcome = await leaveGroupOnServer(groupHex: groupHex, selfId: selfId)
        let outcomeLabel: String = Self.leaveOutcomeLabel(outcome)
        let outLine: String = "leave outcome=" + outcomeLabel + " g=" + gShort
        RTLog.info("groupdel", outLine)

        // Step 2 — purge. Unconditional: see the type-level note.
        if shouldPurgeLocalGroupState(after: outcome) {
            purgeLocalGroupState(groupHex: groupHex, selfId: selfId)
        }

        // Step 3 — tombstone. Also unconditional, and most important
        // precisely when step 1 failed: the server still has us in the
        // group, so the next reconcile would otherwise resurrect it.
        //
        // The tombstone records WHETHER step 1 succeeded, and that single bit
        // is what later lets `reconcileAllGroupsFromServer` tell "an admin
        // re-added me" apart from "my leave never landed" — see
        // `reconcileTombstoneDecision`. Without it, "the server still lists
        // me" is ambiguous and can never be used as a re-add signal, which is
        // what left an offline user locked out of a group forever.
        if shouldWriteGroupTombstone(after: outcome) {
            GroupTombstoneStore.shared.mark(
                groupHex, serverLeaveOk: serverLeaveConfirmed(outcome))
        }

        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupHex])
        let doneLine: String = "delete complete g=" + gShort + " outcome=" + outcomeLabel
        RTLog.info("groupdel", doneLine)
        return outcome
    }

    /// Short, greppable label for a leave outcome — string interpolation of
    /// the enum itself would embed the associated value in a shape that is
    /// awkward to grep for (SWIFT6_PATTERNS also discourages multi-segment
    /// interpolation in log call sites).
    fileprivate static func leaveOutcomeLabel(_ outcome: GroupLeaveOutcome) -> String {
        switch outcome {
        case .left: return "left"
        case .unreachable: return "unreachable"
        case .notAttempted: return "not_attempted"
        // String(describing:) not String(_:) — SWIFT6_PATTERNS rule 3.
        case .rejected(let status): return "rejected_" + String(describing: status)
        }
    }

    /// Ship the P2P `qa_grp:1 member_left` envelope to every other member
    /// over the 1:1 ratchet. Best-effort and silent-by-design when we have
    /// no local roster (a group known only to the server, or already
    /// purged) — the server fan-out is the other half of this signal.
    @MainActor
    fileprivate func shipMemberLeftEnvelope(groupHex: String, selfId: String) {
        guard !selfId.isEmpty else {
            RTLog.warn("groupdel", "member_left skipped g=\(groupHex.prefix(8)) why=no_self_id")
            return
        }
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else {
            RTLog.info("groupdel", "member_left skipped g=\(groupHex.prefix(8)) why=no_local_roster")
            return
        }
        let now = Int64(Date().timeIntervalSince1970)
        let env = GroupInviteEnvelope.MemberLeft(
            g: groupHex, e: entry.epoch, member: selfId, from: selfId, ts: now)
        guard let json = GroupInviteEnvelope.encodeMemberLeft(env) else {
            RTLog.warn("groupdel", "member_left skipped g=\(groupHex.prefix(8)) why=encode_failed")
            return
        }
        var shipped = 0
        for recipient in entry.members where recipient != selfId {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: [
                    "recipient": recipient,
                    "envelopeJson": json,
                ])
            shipped += 1
        }
        let shipLine: String = "member_left shipped g=" + String(groupHex.prefix(8)) + " n=" + String(describing: shipped)
        RTLog.info("groupdel", shipLine)
    }

    /// Step 1 — `POST /api/v1/groups/{gid}/leave`, signed with this
    /// device's Ed25519 identity key.
    ///
    /// Every "we cannot even try" branch returns `.notAttempted` WITH a log
    /// line rather than failing silently: a delete that quietly skipped the
    /// server is precisely the kind of thing that stayed undiagnosable here
    /// for days.
    @MainActor
    fileprivate func leaveGroupOnServer(groupHex: String, selfId: String) async -> GroupLeaveOutcome {
        guard !selfId.isEmpty else {
            RTLog.warn("groupdel", "leave not attempted g=\(groupHex.prefix(8)) why=no_self_id")
            return .notAttempted
        }
        guard let groupIdWire = Self.hexToDashedUUID(groupHex) else {
            RTLog.warn("groupdel", "leave not attempted g=\(groupHex.prefix(8)) why=bad_group_id")
            return .notAttempted
        }
        guard let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken) else {
            RTLog.warn("groupdel", "leave not attempted g=\(groupHex.prefix(8)) why=no_auth")
            return .notAttempted
        }
        guard let identity = sovereignIdentity.loadIdentity() else {
            RTLog.warn("groupdel", "leave not attempted g=\(groupHex.prefix(8)) why=no_identity")
            return .notAttempted
        }
        // `e_proposed` for a leave is current + 1 (leave bumps, §7.2). The
        // server does not validate it on this endpoint (`store.LeaveGroup`
        // ignores the field), and by design we may no longer have a local
        // entry at all — so a missing epoch falls back to 1 rather than
        // aborting a delete the user already confirmed.
        let baseEpoch = GroupRegistry.shared.entry(for: groupHex)?.epoch ?? 1
        let now = Int64(Date().timeIntervalSince1970)
        let envelope = GroupMembershipEnvelope.build(
            actorUserId: selfId,
            eProposed: baseEpoch &+ 1,
            groupIdWire: groupIdWire,
            operation: GroupMembershipEnvelope.opLeave,
            tsUnixSeconds: now,
            subjectUserId: selfId)
        guard let sig = try? sovereignIdentity.signChallenge(envelope, identity: identity) else {
            RTLog.warn("groupdel", "leave not attempted g=\(groupHex.prefix(8)) why=sign_failed")
            return .notAttempted
        }
        guard let res = await api.leaveGroup(
            groupIdWire: groupIdWire,
            signedEnvelopeB64: envelope.base64EncodedString(),
            leaverSignatureB64: sig.base64EncodedString()) else {
            // No HTTP response at all — offline, DNS, TLS/pinning, timeout.
            return classifyGroupLeave(succeeded: false, httpStatus: nil)
        }
        return classifyGroupLeave(succeeded: res.isSuccess, httpStatus: res.statusCode)
    }

    /// Retry a server leave that never landed, from the reconcile sweep.
    ///
    /// W-GRPDEL — the delete is fail-open by design: if the leave call could
    /// not be made or was refused, the chat still disappears locally and a
    /// tombstone is written. That leaves one loose end, though — the server
    /// (and therefore every other member) still believes this user is in the
    /// group. Nothing used to close it: the UI said the user had left, and
    /// the code never tried again. This is the retry that makes that true.
    ///
    /// Only ever called for a group that HAS a tombstone whose
    /// `serverLeaveOk` is false and which the server still lists us in —
    /// i.e. `reconcileTombstoneDecision` returning
    /// `.keepTombstoneAndRetryLeave`. It never clears the tombstone: a
    /// successful retry means the delete finally completed, not that the
    /// user wants the chat back.
    ///
    /// Throttled by `shouldRetryServerLeaveNow`, because the reconcile sweep
    /// fires on every chat-list appear and every WS reconnect and this is a
    /// signed POST.
    @MainActor
    fileprivate func retryPendingGroupLeave(groupHex: String, selfId: String) async {
        let gShort: String = String(groupHex.prefix(8))
        let lastAttempt = GroupTombstoneStore.shared.lastLeaveRetryAt(groupHex)
        guard shouldRetryServerLeaveNow(lastAttemptAt: lastAttempt, now: Date()) else {
            RTLog.debug("groupdel", "leave retry throttled g=" + gShort)
            return
        }
        // Claim the slot BEFORE awaiting the network, not after.
        // `reconcileAllGroupsFromServer` has several call sites (chat-list
        // appear, WS reconnect) and two sweeps can overlap across this
        // suspension point — stamping only on completion would let both see
        // a stale `lastLeaveRetryAt` and both fire, which is exactly the
        // storm the throttle exists to prevent. `serverLeaveOk: false` never
        // downgrades a recorded success, so this claim cannot lose
        // information.
        GroupTombstoneStore.shared.noteLeaveRetry(groupHex, serverLeaveOk: false)
        RTLog.info("groupdel", "leave retry starting g=" + gShort)
        let outcome = await leaveGroupOnServer(groupHex: groupHex, selfId: selfId)
        let confirmed = serverLeaveConfirmed(outcome)
        if confirmed {
            GroupTombstoneStore.shared.noteLeaveRetry(groupHex, serverLeaveOk: true)
        }
        let outcomeLabel: String = Self.leaveOutcomeLabel(outcome)
        let line: String = "leave retry outcome=" + outcomeLabel + " g=" + gShort
        RTLog.info("groupdel", line)
        // A leave that lands here can only mean the local state was already
        // purged at delete time, so there is nothing further to tear down —
        // the tombstone stays, and the next sweep will simply not see this
        // group in the listing any more.
    }

    /// Step 2 — drop every piece of local state keyed on this group.
    ///
    /// Scoped to ONE group throughout: the registry row, its message
    /// history (and the decrypted attachment blobs on disk), its
    /// sender-key/vault crypto state, and every pending/in-flight queue
    /// that keys on it. No other group is touched — deleting one chat must
    /// never cost the user a group they are still in.
    @MainActor
    fileprivate func purgeLocalGroupState(groupHex: String, selfId: String) {
        GroupRegistry.shared.remove(groupId: groupHex)
        // W-GRPDEL: `clear` had zero callers before this — group history
        // (and its decrypted blobs) survived every leave, unreachable from
        // any screen. It is also what makes this a real delete rather than
        // a hide.
        GroupMessageStore.shared.clear(groupHex: groupHex)
        // In-memory session + EVERY persisted vault snapshot for this
        // group. `invalidate` alone would leave the Keychain snapshots, and
        // the next `session(...)` would reload the group we just deleted.
        GroupChatService.shared.purgeLocalState(groupId: groupHex, selfId: selfId)

        // Pending queues. A buffered frame for a deleted group would
        // otherwise sit there occupying one of the 128 slots shared with
        // every OTHER group's genuinely-recoverable frames.
        let beforeWires = bufferedGroupWires.count
        bufferedGroupWires.removeAll { buffered in
            guard let raw = buffered.data["group_id"] as? String else { return false }
            return normalizedGroupTombstoneKey(raw) == groupHex
        }
        let droppedWires: Int = beforeWires - bufferedGroupWires.count
        bufferedGroupMetadata.removeValue(forKey: groupHex)
        attemptedEpochReseal.removeValue(forKey: groupHex)

        // Typing debounce is keyed on the DASHED id (GroupChatScreen passes
        // `groupId.uuidString.lowercased()`); both forms are removed so a
        // future call-site change cannot leave a stranded timer that fires
        // `group_typing` for a group we left.
        let dashed = Self.hexToDashedUUID(groupHex) ?? groupHex
        for key in [dashed, groupHex] {
            groupTypingStopWorkItems[key]?.cancel()
            groupTypingStopWorkItems.removeValue(forKey: key)
            groupTypingActive.removeValue(forKey: key)
        }

        let purgeLine: String = "purged g=" + String(groupHex.prefix(8)) + " wires=" + String(describing: droppedWires)
        RTLog.info("groupdel", purgeLine)
    }

    // MARK: - Fase 1A — admin add / remove member

    /// Admin adds one or more members to `groupHex` (dash-stripped hex id).
    /// Fires THREE channels, mirroring `createGroup`:
    ///   1. CRYPTO — install each new member into our roster and ship them
    ///      our `sender_key_init` over the 1:1 ratchet (does NOT bump the
    ///      crypto epoch, §7.1).
    ///   2. P2P — ship the iOS `group_invite` (full state) to each new
    ///      member so their client auto-bootstraps, plus a `member_added`
    ///      delta to the existing members. Keeps iOS↔iOS working even for a
    ///      P2P-only group the server has no record of.
    ///   3. SERVER — best-effort signed `POST …/members` so the server fans
    ///      `group_membership_changed` to Android/Desktop peers. A 404
    ///      (P2P-only group) / network error never rolls back 1 or 2.
    @MainActor
    public func addGroupMembers(groupId groupHex: String, newMembers rawNew: [String]) {
        guard let selfId = currentUserId, !selfId.isEmpty else { return }
        guard var entry = GroupRegistry.shared.entry(for: groupHex) else {
            print("[AppState] addGroupMembers: unknown group \(groupHex)")
            return
        }
        guard entry.admins.contains(selfId) else {
            print("[AppState] addGroupMembers: self not admin of \(groupHex)")
            return
        }
        let newMembers = rawNew.filter {
            !$0.isEmpty && $0 != selfId && !entry.members.contains($0)
        }
        guard !newMembers.isEmpty else { return }

        let now = Int64(Date().timeIntervalSince1970)
        // Add does NOT bump the CRYPTO epoch; the server `e_proposed` base is
        // the current persisted server epoch (server bumps it on its side).
        let eProposed = entry.epoch

        for newMember in newMembers {
            // 1) CRYPTO — install + ship sender_key_init to the new member.
            if let pending = GroupChatService.shared.addMemberLocally(
                groupId: groupHex, members: entry.members,
                selfId: selfId, newMember: newMember) {
                NotificationCenter.default.post(
                    name: AppState.groupSenderKeyCtlNotification, object: nil,
                    userInfo: ["recipient": pending.recipientId,
                               "envelopeJson": pending.envelopeJson])
            }
            // 2) local registry.
            GroupRegistry.shared.addMember(groupId: groupHex, userId: newMember)
            entry = GroupRegistry.shared.entry(for: groupHex) ?? entry
        }

        // 2b) P2P fan-out (hex `g`). group_invite → new members;
        //     member_added → the pre-existing members.
        let fullMembers = entry.members
        let fullAdmins = entry.admins
        let inviteJson = GroupInviteEnvelope.encodeInvite(
            GroupInviteEnvelope.Invite(
                g: groupHex, name: entry.name, members: fullMembers,
                admins: fullAdmins, from: selfId, e: eProposed, ts: now))
        for newMember in newMembers {
            if let json = inviteJson {
                NotificationCenter.default.post(
                    name: AppState.groupSenderKeyCtlNotification, object: nil,
                    userInfo: ["recipient": newMember, "envelopeJson": json])
            }
            if let addedJson = GroupInviteEnvelope.encodeMemberAdded(
                GroupInviteEnvelope.MemberAdded(
                    g: groupHex, e: eProposed, member: newMember,
                    from: selfId, ts: now)) {
                for recipient in fullMembers
                where recipient != selfId && !newMembers.contains(recipient) {
                    NotificationCenter.default.post(
                        name: AppState.groupSenderKeyCtlNotification, object: nil,
                        userInfo: ["recipient": recipient, "envelopeJson": addedJson])
                }
            }
        }

        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil, userInfo: ["groupId": groupHex])

        // 3) SERVER REST (best-effort, one signed envelope per new member).
        guard let groupIdWire = Self.hexToDashedUUID(groupHex),
              let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken),
              let identity = sovereignIdentity.loadIdentity() else { return }
        for newMember in newMembers {
            let envelope = GroupMembershipEnvelope.build(
                actorUserId: selfId, eProposed: eProposed, groupIdWire: groupIdWire,
                operation: GroupMembershipEnvelope.opAdd,
                tsUnixSeconds: now, subjectUserId: newMember)
            guard let sig = try? sovereignIdentity.signChallenge(envelope, identity: identity) else { continue }
            let envB64 = envelope.base64EncodedString()
            let sigB64 = sig.base64EncodedString()
            Task { @MainActor in
                guard let res = await api.addMember(
                    groupIdWire: groupIdWire, userId: newMember,
                    signedEnvelopeB64: envB64, adminSignatureB64: sigB64),
                    res.isSuccess else { return }
                GroupRegistry.shared.setEpoch(groupId: groupHex, epoch: res.groupEpoch)
                NotificationCenter.default.post(
                    name: AppState.groupRegistryChangedNotification,
                    object: nil, userInfo: ["groupId": groupHex])
            }
        }
    }

    /// Admin removes `removed` from `groupHex`. Fires the same three
    /// channels, but the CRYPTO side is the FORWARD-SECRECY rekey (§7.2):
    /// bump the crypto epoch, rotate our own send chain, drop recv chains,
    /// redistribute `sender_key_rotate` to the remaining members. Use
    /// `leaveGroup` to remove yourself — this path refuses `removed == self`.
    @MainActor
    public func removeGroupMember(groupId groupHex: String, member removed: String) {
        guard let selfId = currentUserId, !selfId.isEmpty else { return }
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else { return }
        guard entry.admins.contains(selfId) else {
            print("[AppState] removeGroupMember: self not admin of \(groupHex)")
            return
        }
        guard removed != selfId else {
            print("[AppState] removeGroupMember: use leaveGroup to remove self")
            return
        }
        guard entry.members.contains(removed) else { return }

        let now = Int64(Date().timeIntervalSince1970)
        let preMembers = entry.members
        // Remove DOES bump: the server `e_proposed` is current + 1.
        let eProposed = entry.epoch &+ 1

        // 1) CRYPTO — rekey + ship sender_key_rotate to remaining members.
        applyRemovalRekey(groupHex: groupHex, members: preMembers,
                          selfId: selfId, removed: removed)

        // 2) local registry + P2P member_removed to remaining members.
        GroupRegistry.shared.removeMember(groupId: groupHex, userId: removed)
        let remaining = GroupRegistry.shared.entry(for: groupHex)?.members ?? []
        if let removedJson = GroupInviteEnvelope.encodeMemberRemoved(
            GroupInviteEnvelope.MemberRemoved(
                g: groupHex, e: eProposed, member: removed, from: selfId, ts: now)) {
            for recipient in remaining where recipient != selfId {
                NotificationCenter.default.post(
                    name: AppState.groupSenderKeyCtlNotification, object: nil,
                    userInfo: ["recipient": recipient, "envelopeJson": removedJson])
            }
        }
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil, userInfo: ["groupId": groupHex])

        // 3) SERVER REST (best-effort).
        guard let groupIdWire = Self.hexToDashedUUID(groupHex),
              let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken),
              let identity = sovereignIdentity.loadIdentity() else { return }
        let envelope = GroupMembershipEnvelope.build(
            actorUserId: selfId, eProposed: eProposed, groupIdWire: groupIdWire,
            operation: GroupMembershipEnvelope.opRemove,
            tsUnixSeconds: now, subjectUserId: removed)
        guard let sig = try? sovereignIdentity.signChallenge(envelope, identity: identity) else { return }
        let envB64 = envelope.base64EncodedString()
        let sigB64 = sig.base64EncodedString()
        Task { @MainActor in
            guard let res = await api.removeMember(
                groupIdWire: groupIdWire, userId: removed,
                signedEnvelopeB64: envB64, adminSignatureB64: sigB64),
                res.isSuccess else { return }
            GroupRegistry.shared.setEpoch(groupId: groupHex, epoch: res.groupEpoch)
            NotificationCenter.default.post(
                name: AppState.groupRegistryChangedNotification,
                object: nil, userInfo: ["groupId": groupHex])
        }
    }

    // MARK: - Fase 1C — admin promote / demote

    /// Admin promotes `uid` (an existing member) to admin. Does NOT touch
    /// membership or the crypto epoch (server contract, verbatim) — only
    /// the local admin set + the server-canonical epoch (defensive, same
    /// monotonic guard as add/remove) are updated on success.
    @MainActor
    public func promoteGroupAdmin(groupId groupHex: String, member uid: String) {
        guard let selfId = currentUserId, !selfId.isEmpty else { return }
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else { return }
        guard entry.admins.contains(selfId) else {
            print("[AppState] promoteGroupAdmin: self not admin of \(groupHex)")
            return
        }
        guard entry.members.contains(uid), !entry.admins.contains(uid) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        // Neither add nor remove — the server `e_proposed` base is the
        // CURRENT persisted epoch (unchanged by admin promote/demote).
        let eProposed = entry.epoch

        guard let groupIdWire = Self.hexToDashedUUID(groupHex),
              let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken),
              let identity = sovereignIdentity.loadIdentity() else { return }
        let envelope = GroupMembershipEnvelope.build(
            actorUserId: selfId, eProposed: eProposed, groupIdWire: groupIdWire,
            operation: GroupMembershipEnvelope.opAdminAdd,
            tsUnixSeconds: now, subjectUserId: uid)
        guard let sig = try? sovereignIdentity.signChallenge(envelope, identity: identity) else { return }
        let envB64 = envelope.base64EncodedString()
        let sigB64 = sig.base64EncodedString()
        Task { @MainActor in
            guard let res = await api.promoteAdmin(
                groupIdWire: groupIdWire, userId: uid,
                signedEnvelopeB64: envB64, adminSignatureB64: sigB64),
                res.isSuccess else { return }
            GroupRegistry.shared.setAdmin(groupId: groupHex, userId: uid, isAdmin: true)
            if res.groupEpoch > 0 {
                GroupRegistry.shared.setEpoch(groupId: groupHex, epoch: res.groupEpoch)
            }
            NotificationCenter.default.post(
                name: AppState.groupRegistryChangedNotification,
                object: nil, userInfo: ["groupId": groupHex])
        }
    }

    /// Admin demotes `uid` from admin. Server replies 409 if `uid` is the
    /// last remaining admin — left untouched locally on any non-2xx reply.
    @MainActor
    public func demoteGroupAdmin(groupId groupHex: String, member uid: String) {
        guard let selfId = currentUserId, !selfId.isEmpty else { return }
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else { return }
        guard entry.admins.contains(selfId) else {
            print("[AppState] demoteGroupAdmin: self not admin of \(groupHex)")
            return
        }
        guard entry.admins.contains(uid) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let eProposed = entry.epoch

        guard let groupIdWire = Self.hexToDashedUUID(groupHex),
              let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken),
              let identity = sovereignIdentity.loadIdentity() else { return }
        let envelope = GroupMembershipEnvelope.build(
            actorUserId: selfId, eProposed: eProposed, groupIdWire: groupIdWire,
            operation: GroupMembershipEnvelope.opAdminRemove,
            tsUnixSeconds: now, subjectUserId: uid)
        guard let sig = try? sovereignIdentity.signChallenge(envelope, identity: identity) else { return }
        let envB64 = envelope.base64EncodedString()
        let sigB64 = sig.base64EncodedString()
        Task { @MainActor in
            guard let res = await api.demoteAdmin(
                groupIdWire: groupIdWire, userId: uid,
                signedEnvelopeB64: envB64, adminSignatureB64: sigB64),
                res.isSuccess else {
                print("[AppState] demoteGroupAdmin: server rejected (last admin?) for \(uid)")
                return
            }
            GroupRegistry.shared.setAdmin(groupId: groupHex, userId: uid, isAdmin: false)
            if res.groupEpoch > 0 {
                GroupRegistry.shared.setEpoch(groupId: groupHex, epoch: res.groupEpoch)
            }
            NotificationCenter.default.post(
                name: AppState.groupRegistryChangedNotification,
                object: nil, userInfo: ["groupId": groupHex])
        }
    }

    // MARK: - Fase 1C — group rename / avatar (admin-gated)

    /// Admin renames the group and/or sets its avatar. Packs `{name,
    /// avatar_ref}` as JSON and encrypts it with the group's own 0xE4
    /// GroupSenderKey engine — the SAME primitive `sendGroupOverWire` uses
    /// for group TEXT (the CURRENT sender's send-chain via
    /// `GroupChatService.encryptForWire`), so no new key is introduced.
    ///
    /// `newName` nil/blank keeps the current name (the packed JSON always
    /// carries a name — the contract's "omit" clause is for `avatar_ref`
    /// only). `avatarData` nil keeps the current avatar; pass already
    /// resized+JPEG-encoded bytes (the caller does that, mirroring
    /// `GroupAttachmentSender`'s plain `Data` contract instead of a
    /// `UIImage` one, so this file needs no UIKit import). Avatar upload
    /// reuses the SAME tus primitive as `AvatarUploader`/
    /// `GroupAttachmentSender` (`storageApi.uploadFile` → file_id) and the
    /// SAME plain `GET /api/v1/files/{file_id}` convention `AvatarUploader`
    /// uses for the profile avatar (no per-member capability token — the
    /// server contract's `{name, avatar_ref}` shape has no room for a `dl`
    /// map like group attachments carry).
    @MainActor
    public func updateGroupMetadata(groupId groupHex: String, newName: String?, avatarData: Data?) {
        guard let selfId = currentUserId, !selfId.isEmpty else { return }
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else { return }
        guard entry.admins.contains(selfId) else {
            print("[AppState] updateGroupMetadata: self not admin of \(groupHex)")
            return
        }
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (trimmed?.isEmpty == false) ? trimmed! : entry.name
        guard !resolvedName.isEmpty else { return }

        guard let groupIdWire = Self.hexToDashedUUID(groupHex),
              let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken),
              let identity = sovereignIdentity.loadIdentity() else { return }
        // Pre-captured (not `self`) so the Task below closes over values,
        // not the AppState instance — same lifetime discipline as
        // addGroupMembers/removeGroupMember.
        let identityMgr = sovereignIdentity
        let uploadProvider = makeUploadProvider()
        let members = entry.members
        let priorAvatarRef = entry.avatarRef
        let eProposed = entry.epoch

        Task { @MainActor in
            // 1) Avatar upload (best-effort tus upload — same primitive as
            //    AvatarUploader/GroupAttachmentSender: POST /files/upload →
            //    file_id). A failure here aborts the WHOLE update (rather
            //    than silently shipping a rename that drops the avatar the
            //    admin thought they were setting).
            var avatarRef = priorAvatarRef
            if let data = avatarData {
                do {
                    avatarRef = try await uploadProvider.storageApi.uploadFile(
                        data: data, filename: "grpavatar-\(groupHex.prefix(8)).jpg")
                } catch {
                    print("[AppState] updateGroupMetadata: avatar upload failed: \(error)")
                    return
                }
            }

            let payload = GroupMetadataPayload(name: resolvedName, avatarRef: avatarRef)
            guard let payloadData = try? JSONEncoder().encode(payload),
                  let payloadJson = String(data: payloadData, encoding: .utf8) else {
                print("[AppState] updateGroupMetadata: payload encode failed")
                return
            }

            // 2) Encrypt with the CURRENT sender's 0xE4 send-chain.
            guard let sealed = GroupChatService.shared.encryptForWire(
                plaintext: payloadJson, groupId: groupHex,
                members: members, selfId: selfId) else {
                print("[AppState] updateGroupMetadata: encrypt failed for \(groupHex)")
                return
            }
            let blobB64 = sealed.wire.base64EncodedString()
            // Server contract: envelope `uid` = lowercase-hex SHA-256 of
            // the RAW pre-base64 encrypted blob bytes (NOT a user id).
            let blobHashHex = SHA256.hash(data: sealed.wire)
                .map { String(format: "%02x", $0) }.joined()
            let now = Int64(Date().timeIntervalSince1970)
            let envelope = GroupMembershipEnvelope.build(
                actorUserId: selfId, eProposed: eProposed, groupIdWire: groupIdWire,
                operation: GroupMembershipEnvelope.opMetadataUpdated,
                tsUnixSeconds: now, subjectUserId: blobHashHex)
            guard let sig = try? identityMgr.signChallenge(envelope, identity: identity) else { return }

            guard let res = await api.updateMetadata(
                groupIdWire: groupIdWire, metadataBlobB64: blobB64,
                signedEnvelopeB64: envelope.base64EncodedString(),
                adminSignatureB64: sig.base64EncodedString()),
                res.isSuccess else {
                print("[AppState] updateGroupMetadata: server rejected for \(groupHex)")
                return
            }
            // 3) Apply locally — same treatment the actor gets synchronously
            //    that OTHER members get asynchronously from
            //    `group_metadata_changed`.
            GroupRegistry.shared.renameGroup(groupId: groupHex, newName: resolvedName)
            GroupRegistry.shared.setAvatarRef(groupId: groupHex, avatarRef: avatarRef)
            if res.metadataVersion > 0 {
                GroupRegistry.shared.setMetadataVersion(groupId: groupHex, version: res.metadataVersion)
            }
            NotificationCenter.default.post(
                name: AppState.groupRegistryChangedNotification,
                object: nil, userInfo: ["groupId": groupHex])
        }
    }

    /// Reconstruct the dashed-UUID server wire id from the dash-stripped
    /// 32-char hex the local `GroupRegistry` keys on. Returns nil if the
    /// input isn't a 32-char hex string (a non-UUID / malformed id).
    fileprivate static func hexToDashedUUID(_ hex: String) -> String? {
        let clean = hex.lowercased()
        guard clean.count == 32,
              clean.allSatisfy({ $0.isHexDigit }) else { return nil }
        let c = Array(clean)
        let p1 = String(c[0..<8]); let p2 = String(c[8..<12])
        let p3 = String(c[12..<16]); let p4 = String(c[16..<20])
        let p5 = String(c[20..<32])
        return "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
    }
}

// MARK: - W-GRPMEMBER: server `group_membership_changed` consumer

extension AppState {

    /// Apply one server-authoritative `group_membership_changed` event.
    ///
    /// Wire (verified against `bcrypto-server/cmd/bcrypto-lite/groups_membership.go`
    /// `fanOutMembershipChanged`, 2026-07-14):
    /// ```
    /// {group_id, group_epoch, members[], admins[], admins_empty,
    ///  operation: "add"|"remove"|"leave"|"snapshot"|<log op>,
    ///  subject_user_id, actor_user_id,
    ///  envelope_canonical_b64, envelope_signature_b64, server_ts,
    ///  replay?: true}
    /// ```
    /// The event is fanned out to the CURRENT members only — a removed /
    /// leaving user is already out of `members` and therefore does NOT receive
    /// their own removal (they get the REST reply). We still handle
    /// `subject == self` defensively (federation replay / catch-up).
    ///
    /// `members` / `admins` are SERVER-AUTHORITATIVE: we overwrite the local
    /// roster with them rather than incrementally patching (the incremental
    /// `qa_grp:1 member_added/removed` P2P envelopes keep their own path in
    /// `applyMemberAdded` / `applyMemberRemoved` — this is the parallel
    /// server-side channel Android/Desktop already consume).
    @MainActor
    fileprivate func handleGroupMembershipChanged(_ data: [String: Any]) {
        guard let rawGroupId = data["group_id"] as? String, !rawGroupId.isEmpty,
              let members = data["members"] as? [String] else {
            print("[AppState] group_membership_changed missing required fields: \(data.keys)")
            return
        }
        // dashed UUID (server wire) → hex (GroupChatService / registry key),
        // same normalization as `handleIncomingGroupMessage`.
        let groupHex = rawGroupId.replacingOccurrences(of: "-", with: "").lowercased()
        let admins = data["admins"] as? [String] ?? []
        let operation = (data["operation"] as? String) ?? ""
        let subject = (data["subject_user_id"] as? String) ?? ""
        let actor = (data["actor_user_id"] as? String) ?? ""
        let replay = (data["replay"] as? Bool) ?? false
        let serverEpoch = Self.uint32Field(data["group_epoch"])
        let selfId = currentUserId ?? AppState.currentUserIdSnapshot ?? ""
        guard !selfId.isEmpty else { return }

        let isRemoval = Self.isMembershipRemoval(operation)
        let existing = GroupRegistry.shared.entry(for: groupHex)

        // We are OUT of this group. Two ways to learn it:
        //   • the event names us as the subject of a remove/leave (defensive:
        //     the live fan-out excludes the subject, but a federated replay or
        //     a cross-node delivery can still reach us), or
        //   • the SERVER-AUTHORITATIVE roster simply no longer lists us — the
        //     shape a `snapshot`/catch-up replay takes for a removal that
        //     happened while we were offline (the live event went only to the
        //     then-current members, so this is the ONLY way we ever hear of it).
        // Either way tear the group down locally, so a half-dead group (registry
        // entry with a live GroupState we can no longer use) can never linger.
        if (isRemoval && subject == selfId) || !members.contains(selfId) {
            guard existing != nil else { return }
            GroupRegistry.shared.remove(groupId: groupHex)
            GroupChatService.shared.invalidate(groupId: groupHex)
            NotificationCenter.default.post(
                name: AppState.groupRegistryChangedNotification,
                object: nil,
                userInfo: ["groupId": groupHex])
            print("[AppState] group_membership_changed: removed from \(groupHex) (op=\(operation))")
            return
        }

        guard existing != nil else {
            // Unknown group. If the server says we ARE a member, this is the
            // add that onboards us (no preceding iOS `group_invite` envelope —
            // e.g. an Android/Desktop admin added us). Bootstrap exactly like
            // `applyMemberAdded`'s auto-bootstrap branch.
            guard members.contains(selfId) else { return }
            // W-GRPDEL — the roster containing us says nothing about whether
            // this is a re-add: it contains us on every snapshot/catch-up
            // replay too. Only `operation` + `subject_user_id` distinguish
            // "an admin added me back" (lifts a tombstone) from "the server
            // re-stated the roster" (must respect one).
            //
            // `replay` is load-bearing here, not decoration. The server runs
            // `replayMembershipCatchup` at EVERY start — so after every
            // deploy — and it rebuilds each event from the group's last
            // membership-log entry, meaning a replayed event carries a real
            // `member_added` with a real `subject_user_id`. Field for field
            // it is identical to a genuine re-add; `replay: true` (set by
            // `fanOutMembershipChanged`, parsed above) is the only thing
            // that separates them. Ignore it and every deploy resurrects
            // every deleted group chat.
            let source = classifyMembershipEventForTombstone(
                operation: operation, subjectUserId: subject, selfUserId: selfId,
                isReplay: replay)
            bootstrapGroupFromServer(
                groupHex: groupHex, members: members, admins: admins,
                actor: actor, selfId: selfId, replay: replay, serverEpoch: serverEpoch,
                source: source)
            return
        }

        // Server-authoritative roster.
        applyServerRoster(groupHex: groupHex, members: members, admins: admins, serverEpoch: serverEpoch)

        // Crypto side-effects. Fase 1C — admin promote/demote ("admin_add" /
        // "admin_remove") reuse this SAME event but never touch membership
        // or the crypto epoch (server contract, verbatim) — `admins` is
        // already applied above via the server-authoritative roster write,
        // so there is nothing further to do for those two operations: no
        // rekey (nobody was removed), no sender_key_init ship (nobody was
        // added).
        let isAdminOp = Self.isAdminMembershipOp(operation)
        if isAdminOp {
            // no-op — admin set already applied above.
        } else if isRemoval, !subject.isEmpty, subject != selfId {
            // Fase 1A — the FORWARD-SECRECY path (§7.2). A remaining member
            // bumps the crypto epoch, rotates its own send chain to a fresh
            // SK_0 the removed member never learned, drops all recv chains,
            // and redistributes `sender_key_rotate` to the OTHER remaining
            // members. Idempotent (engine `notMember` guard) — safe even when
            // the parallel P2P `member_removed` envelope also drives us here.
            // This REPLACES the pre-Fase-1A `invalidate`, which (with the old
            // hardcoded epoch-1 load) silently reverted the group to a stale
            // key state on the next send/receive.
            applyRemovalRekey(groupHex: groupHex, members: members, selfId: selfId, removed: subject)
        } else if !isRemoval, !subject.isEmpty, subject != selfId {
            // A member was ADDED: ship OUR sender_key_init to them over the 1:1
            // ratchet so they can decrypt our group frames. Identical fan-out to
            // `createGroup` (groupSenderKeyCtlNotification → ChatMessageSendService).
            // `pendingInitsAfterBootstrap` is idempotent — it returns only the
            // members we have not shipped to yet (i.e. the new one).
            shipSenderKeyInits(groupHex: groupHex, members: members, selfId: selfId)
        }

        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupHex])
        // Pre-bound locals — SWIFT6_PATTERNS rule 1/2 (no multi-segment
        // interpolation, no `+` inside `print`).
        let gShort: String = String(groupHex.prefix(8))
        let memberCount: String = String(describing: members.count)
        let applied: String = "[AppState] group_membership_changed g=" + gShort + " op=" + operation + " members=" + memberCount
        print(applied)
    }

    /// Onboard a group we have no local state for, from a server membership
    /// event that lists us as a member. Mirrors the auto-bootstrap branch of
    /// `applyMemberAdded` (registry entry → GroupChatService session →
    /// markBootstrapped → drain buffered group frames → snackbar).
    /// - Parameter source: how we learned about this group. W-GRPDEL — this
    ///   is the single choke point every server-driven resurrection goes
    ///   through, so the tombstone check lives here rather than being
    ///   re-implemented at each call site. A PASSIVE source (a reconcile
    ///   listing, a snapshot replay) is refused for a group the user
    ///   deleted; an EXPLICIT re-add lifts the tombstone and proceeds.
    ///   Deliberately not defaulted: defaulting it either way makes one of
    ///   the two user-visible failures (a resurrected chat, or a group the
    ///   user can never be re-added to) the silent outcome of forgetting it.
    @MainActor
    fileprivate func bootstrapGroupFromServer(
        groupHex: String, members: [String], admins: [String],
        actor: String, selfId: String, replay: Bool, serverEpoch: UInt32,
        source: GroupResurrectionSource
    ) {
        if GroupTombstoneStore.shared.isTombstoned(groupHex) {
            guard !shouldSkipGroupResurrection(source: source, hasTombstone: true) else {
                let refusedLine: String = "bootstrap refused g=" + String(groupHex.prefix(8)) + " src=" + String(describing: source)
                RTLog.info("groupdel", refusedLine)
                return
            }
            // An explicit re-add: an admin put this user back. Lift the mark
            // so the group can live again, otherwise the tombstone would be
            // a life sentence on this device.
            GroupTombstoneStore.shared.clear(groupHex, reason: String(describing: source))
        }
        let adminForName = admins.first ?? actor
        let entry = GroupRegistry.Entry(
            id: groupHex,
            name: String(groupHex.prefix(8)) + "…",  // placeholder; renameable
            members: members,
            admins: admins.isEmpty ? [actor] : admins,
            joinedAt: Date(),
            bootstrapped: false,
            epoch: max(serverEpoch, 1))
        GroupRegistry.shared.upsert(entry)
        _ = GroupChatService.shared.session(
            groupId: groupHex, members: members, selfId: selfId)
        GroupRegistry.shared.markBootstrapped(groupId: groupHex)
        // Recv chains just became available — drain the group TEXT frames that
        // were buffered (and already server-marked-delivered) before we joined.
        retryBufferedGroupMessages()
        // Ship our own send chain to everyone else in the roster.
        shipSenderKeyInits(groupHex: groupHex, members: members, selfId: selfId)
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupHex])
        // `replay` == server catch-up burst → suppress the UI side-effect
        // (toast spam on every reconnect), exactly as the server intends.
        if !replay {
            NotificationCenter.default.post(
                name: AppState.groupAutoJoinedNotification,
                object: nil,
                userInfo: [
                    "groupId": groupHex,
                    "fromAdmin": adminForName,
                ])
        }
        print("[AppState] group_membership_changed: auto-joined \(groupHex.prefix(8))… (\(members.count) members)")

        // Fase 1C — a fresh device only learns members/admins from this
        // event (no name/avatar travels on `group_membership_changed`).
        // Best-effort GET recovers the current `metadata_blob_b64` so the
        // placeholder "xxxxxxxx…" name above doesn't linger until the next
        // LIVE rename. Failure (offline / 404 / no metadata set yet) just
        // keeps the placeholder — never blocks the bootstrap above.
        recoverGroupMetadataOnBootstrap(groupHex: groupHex, selfId: selfId)
    }

    /// Write the server-authoritative roster (members/admins/epoch) onto an
    /// EXISTING GroupRegistry entry. Factored out of the live
    /// `group_membership_changed` handler so `reconcileAllGroupsFromServer`
    /// and `fetchAndApplyGroupMetadata` can apply the exact same
    /// roster/epoch fields a bulk or per-group GET returns — both
    /// previously discarded `members`/`admins`/`group_epoch` from the GET
    /// reply entirely, so a rename/avatar refresh (or launch-time
    /// reconcile) never backfilled a membership change the live WS event
    /// was missed for (2026-07-17 bug). No-op if the group isn't locally
    /// known yet — callers needing bootstrap use `bootstrapGroupFromServer`.
    @MainActor
    private func applyServerRoster(groupHex: String, members: [String], admins: [String], serverEpoch: UInt32) {
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else { return }
        var updated = entry
        updated.members = members
        updated.admins = admins
        GroupRegistry.shared.upsert(updated)
        // Fase 1A — persist the server-canonical membership epoch so the
        // GroupChatService vault probe stays anchored across launches.
        if serverEpoch > 0 {
            GroupRegistry.shared.setEpoch(groupId: groupHex, epoch: serverEpoch)
        }
    }

    /// Reconciliation backstop (2026-07-17) — lists every group the server
    /// says this account currently belongs to (`GET /api/v1/groups`) and
    /// applies each one:
    ///   - unknown group_id (never bootstrapped locally) → this is a group
    ///     the user was added to while offline / before the WS handler for
    ///     `group_membership_changed` ever fired for it. Bootstrap it
    ///     exactly like the live event does (`replay: true` — no toast
    ///     spam, mirrors the WS catch-up burst's own UX contract).
    ///   - known group_id → apply the server-authoritative roster/epoch
    ///     (`applyServerRoster`) so a membership change missed live (added/
    ///     removed while this device was offline or mid-reconnect) is
    ///     backfilled — same "snapshot" semantics as the WS catch-up
    ///     replay: roster/epoch only, no additional crypto rekey here
    ///     (peers independently re-emit `sender_key_rotate` on their own
    ///     snapshot receipt, same as the live snapshot op does).
    ///   - fresh metadata blob (if present) is decrypted + version-gated
    ///     applied via the same path `fetchAndApplyGroupMetadata` uses.
    /// Call on app launch and WS reconnect. Best-effort: a network/auth
    /// failure silently no-ops (the live WS path remains the primary
    /// channel; this only fills the gap when that path was missed).
    @MainActor
    func reconcileAllGroupsFromServer() async {
        guard let selfId = currentUserId ?? AppState.currentUserIdSnapshot, !selfId.isEmpty,
              let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken) else { return }
        guard let entries = await api.fetchAllGroups() else { return }
        for entry in entries {
            guard entry.members.contains(selfId) else { continue }
            let groupHex = entry.groupIdWire.replacingOccurrences(of: "-", with: "").lowercased()
            // W-GRPDEL — THE resurrection path, AND the only clear path that
            // works for a user who was offline.
            //
            // This sweep runs on every chat-list appear and every WS
            // reconnect. Whenever the leave call did not land the server
            // still lists the user as a member, so a deleted group would
            // reappear within seconds (typically renamed to the `xxxxxxxx…`
            // hex placeholder, since its metadata blob no longer decrypts).
            // A bare listing is not consent.
            //
            // But a listing paired with the recorded leave outcome IS
            // decisive, and that is what fixes the hole the live path could
            // never cover: `fanOutMembershipChanged` only reaches members
            // holding a fresh WebSocket at that instant, so a user whose
            // phone was off when an admin re-added them never saw the event
            // and stayed locked out of that group permanently. Ten minutes
            // offline was enough. Membership STATE, unlike an event, is
            // still true whenever the device next comes back — and it is
            // immune to the catch-up replay, which changes no state.
            let decision = reconcileTombstoneDecision(
                hasTombstone: GroupTombstoneStore.shared.isTombstoned(groupHex),
                serverLeaveConfirmed: GroupTombstoneStore.shared.isServerLeaveConfirmed(groupHex),
                serverListsSelfAsMember: true)  // guarded by `members.contains(selfId)` above
            switch decision {
            case .reconcileNormally:
                break  // not tombstoned — fall through to the ordinary path
            case .keepTombstone:
                // Unreachable while `serverListsSelfAsMember` is pinned true
                // above, but switched exhaustively so a future edit that
                // loosens that guard has to say what it means here.
                RTLog.info("groupdel", "reconcile kept tombstone g=\(groupHex.prefix(8))")
                continue
            case .keepTombstoneAndRetryLeave:
                // The leave never reached the server. NOT a re-add — nobody
                // was ever told this user left, so there was nothing to add
                // them back from. The chat stays gone (the user asked for
                // that) and we finally deliver the retry.
                await retryPendingGroupLeave(groupHex: groupHex, selfId: selfId)
                continue
            case .clearTombstoneAndAdmit:
                // Leave confirmed, yet the server lists this user again: the
                // only thing that makes both true is somebody re-adding
                // them. Lift the mark and let the group reconcile fresh, as
                // a new group.
                RTLog.info("groupdel", "reconcile re-add detected g=\(groupHex.prefix(8))")
                GroupTombstoneStore.shared.clear(
                    groupHex, reason: "reconcileReAddAfterConfirmedLeave")
            }
            if GroupRegistry.shared.entry(for: groupHex) == nil {
                // `source` distinguishes the two ways we can reach this line.
                // After a `.clearTombstoneAndAdmit` the tombstone is already
                // gone, so `bootstrapGroupFromServer`'s guard is a no-op
                // either way — passing the deduced source keeps the reconcile
                // path honest in the same vocabulary as the live one rather
                // than relying on that ordering.
                let source: GroupResurrectionSource =
                    decision == .clearTombstoneAndAdmit
                    ? .reconcileReAddAfterConfirmedLeave
                    : .passiveReconcileListing
                bootstrapGroupFromServer(
                    groupHex: groupHex, members: entry.members, admins: entry.admins,
                    actor: entry.admins.first ?? "", selfId: selfId, replay: true,
                    serverEpoch: entry.groupEpoch,
                    source: source)
            } else {
                applyServerRoster(
                    groupHex: groupHex, members: entry.members, admins: entry.admins,
                    serverEpoch: entry.groupEpoch)
                NotificationCenter.default.post(
                    name: AppState.groupRegistryChangedNotification,
                    object: nil,
                    userInfo: ["groupId": groupHex])
                if let blobB64 = entry.metadataBlobB64, !blobB64.isEmpty {
                    decryptAndApplyGroupMetadataBlob(
                        groupHex: groupHex, blobB64: blobB64,
                        version: entry.metadataVersion, selfId: selfId)
                }
            }
        }
        print("[AppState] reconcileAllGroupsFromServer: reconciled \(entries.count) group(s)")
    }

    /// Fase 1C — `GET /api/v1/groups/{gid}` best-effort fetch + decrypt,
    /// used at fresh-device bootstrap (see call site above). Thin wrapper
    /// over `fetchAndApplyGroupMetadata` — kept as its own name so the
    /// bootstrap call site above reads self-documenting.
    @MainActor
    fileprivate func recoverGroupMetadataOnBootstrap(groupHex: String, selfId: String) {
        fetchAndApplyGroupMetadata(groupHex: groupHex, selfId: selfId)
    }

    /// GAP FIX (avatar pipeline + GET-recovery) — the SAME `GET
    /// /api/v1/groups/{gid}` fetch+decrypt+version-gated-apply as
    /// `recoverGroupMetadataOnBootstrap`, but callable from ANY ordinary
    /// call site that already has a local roster for `groupHex` — opening
    /// a group chat, the chat-list's app-launch refresh, etc. — not just
    /// fresh-device bootstrap. `applyGroupMetadataPayload` is itself
    /// version-gated (a stale/equal `metadata_version` is a no-op), so
    /// calling this redundantly (e.g. every time a group chat is opened)
    /// is cheap and safe — it only ever moves the local name/avatar
    /// forward to what the server currently has.
    @MainActor
    public func refreshGroupMetadataFromServer(groupHex: String) {
        guard let selfId = currentUserId ?? AppState.currentUserIdSnapshot, !selfId.isEmpty,
              GroupRegistry.shared.entry(for: groupHex) != nil else { return }
        fetchAndApplyGroupMetadata(groupHex: groupHex, selfId: selfId)
    }

    /// Shared core of `recoverGroupMetadataOnBootstrap` /
    /// `refreshGroupMetadataFromServer` — GET the group, apply the
    /// server-authoritative roster/epoch (2026-07-17 fix: this used to
    /// fetch `members`/`admins`/`group_epoch` in `res` and silently
    /// discard all three, so a membership change missed live never
    /// backfilled here even though the data was already in hand), then
    /// decrypt+apply the metadata blob via `decryptAndApplyGroupMetadataBlob`.
    @MainActor
    private func fetchAndApplyGroupMetadata(groupHex: String, selfId: String) {
        guard let groupIdWire = Self.hexToDashedUUID(groupHex),
              let api = GroupMembershipApi.from(serverUrl: serverUrl, token: currentAccessToken) else { return }
        Task { @MainActor in
            guard let res = await api.fetchGroup(groupIdWire: groupIdWire), res.isSuccess else { return }
            if GroupRegistry.shared.entry(for: groupHex) != nil {
                applyServerRoster(
                    groupHex: groupHex, members: res.members, admins: res.admins,
                    serverEpoch: res.groupEpoch)
            }
            guard let blobB64 = res.metadataBlobB64, !blobB64.isEmpty else { return }
            self.decryptAndApplyGroupMetadataBlob(
                groupHex: groupHex, blobB64: blobB64, version: res.metadataVersion, selfId: selfId)
        }
    }

    /// Decrypt + version-gate + apply an already-fetched metadata blob —
    /// shared core of `fetchAndApplyGroupMetadata`'s per-group GET and
    /// `reconcileAllGroupsFromServer`'s bulk GET, which arrive with the
    /// identical `metadata_blob_b64`/`metadata_version` shape from two
    /// different REST calls.
    @MainActor
    private func decryptAndApplyGroupMetadataBlob(groupHex: String, blobB64: String, version: UInt32, selfId: String) {
        guard let wire = Data(base64Encoded: blobB64) else { return }
        guard let entry = GroupRegistry.shared.entry(for: groupHex) else { return }
        // The GET reply doesn't carry `actor_user_id`, but the 0xE4
        // wire header itself embeds `sender_id` (`GroupSenderKey`
        // wire layout, spec §2) — unpack it instead of guessing.
        guard let parsed = try? GroupSenderKey.unpackGroupWire(wire) else {
            print("[AppState] decryptAndApplyGroupMetadataBlob: malformed wire g=\(groupHex.prefix(8))")
            return
        }
        guard let plaintext = GroupChatService.shared.decrypt(
            wire: wire, senderId: parsed.senderId, groupId: groupHex,
            members: entry.members, selfId: selfId) else {
            // 2026-07-17 — the single most common reason this fails: this
            // device discovered the group via reconciliation and never
            // lived through the renaming admin's sender_key_init, so no
            // recv chain is installed for `parsed.senderId` yet. Buffer
            // instead of dropping — `retryBufferedGroupMetadata` re-runs
            // this the moment ANY sender_key_init/rotate installs (see
            // that call site), same "buffer + retry on next key install"
            // shape as `bufferGroupWire`/`retryBufferedGroupMessages` for
            // TEXT frames. Before this fix, a decrypt failure here was
            // final — the placeholder/stale name lingered forever even
            // once the key eventually arrived.
            // W-TAGDROP: was print() — it reached the device console and the
            // "stdout" tee only, which is why a log pull showed it as an
            // unattributed blob. Tagged "group" now (allow-listed), with the
            // redaction-proof numeric tail.
            RTLog.warn("group", "metadata undec=1 g=\(groupHex.prefix(8))")
            bufferedGroupMetadata[groupHex] = (blobB64: blobB64, version: version, selfId: selfId)
            maybeReSealStaleGroupMetadata(groupHex: groupHex, wireGroupEpoch: parsed.groupEpoch, selfId: selfId)
            return
        }
        self.applyGroupMetadataPayload(groupHex: groupHex, json: plaintext, version: version)
    }

    /// 2026-07-19 — retroactive gap-close (see `attemptedEpochReseal`'s
    /// doc). Only fires when the failed blob was sealed at an epoch
    /// STRICTLY BEHIND our own live crypto epoch — that is architecturally
    /// permanent (the remove/leave that bumped us past it wiped every recv
    /// chain for the old epoch, `GroupSession.handleMemberRemoved`), unlike
    /// a wire epoch AHEAD of us (we simply haven't caught up yet — the
    /// existing buffer-and-retry-on-next-key-install path already handles
    /// that correctly and must be left alone) or an equal-epoch AEAD
    /// failure (genuine corruption/attack — must still be rejected, never
    /// papered over). Requires self to be admin AND to already hold a real
    /// cached name (not the "xxxxxxxx…" bootstrap placeholder) so a
    /// still-uninitialized joiner never republishes garbage over a
    /// legitimate rename it just hasn't seen yet.
    @MainActor
    private func maybeReSealStaleGroupMetadata(groupHex: String, wireGroupEpoch: UInt32, selfId: String) {
        guard let entry = GroupRegistry.shared.entry(for: groupHex),
              entry.admins.contains(selfId) else { return }
        guard let state = GroupChatService.shared.session(
            groupId: groupHex, members: entry.members, selfId: selfId) else { return }
        let liveEpoch = state.groupEpoch
        guard wireGroupEpoch < liveEpoch else { return }
        let bootstrapPlaceholder = String(groupHex.prefix(8)) + "…"
        guard !entry.name.isEmpty, entry.name != bootstrapPlaceholder else { return }
        if attemptedEpochReseal[groupHex] == liveEpoch { return }
        attemptedEpochReseal[groupHex] = liveEpoch
        print("[AppState] proactively re-sealing stale group metadata g=\(groupHex.prefix(8)) wireEpoch=\(wireGroupEpoch) liveEpoch=\(liveEpoch)")
        updateGroupMetadata(groupId: groupHex, newName: nil, avatarData: nil)
    }

    /// Ship our `sender_key_init` to every member of `groupHex` that has not
    /// received it yet, over the 1:1 ratchet. Same emission path as
    /// `createGroup` (the notification is consumed by `wireGroupChatFanOut`).
    @MainActor
    fileprivate func shipSenderKeyInits(groupHex: String, members: [String], selfId: String) {
        let pending = GroupChatService.shared.pendingInitsAfterBootstrap(
            groupId: groupHex, members: members, selfId: selfId)
        for init_ in pending {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: [
                    "recipient": init_.recipientId,
                    "envelopeJson": init_.envelopeJson,
                ])
        }
    }

    /// Fase 1A — run the remaining-member forward-secrecy rekey (§7.2) and
    /// ship the resulting `sender_key_rotate` envelopes over the 1:1
    /// ratchet. `members` MUST still include `removed` (the engine drops
    /// them); a fresh-bootstrap fallback re-adds `removed` defensively.
    /// Idempotent — the engine's `notMember` guard makes a second call
    /// (server + P2P both firing) a no-op, so the crypto epoch advances
    /// exactly once.
    @MainActor
    fileprivate func applyRemovalRekey(groupHex: String, members: [String],
                                       selfId: String, removed: String) {
        let cryptoMembers = members.contains(removed) ? members : members + [removed]
        guard let rekey = GroupChatService.shared.removeMemberLocally(
            groupId: groupHex, members: cryptoMembers,
            selfId: selfId, removed: removed) else { return }
        // Fase 1A KEYSTONE — persist the just-bumped CRYPTO epoch into the
        // local registry so the GroupChatService vault probe anchors at (or
        // above) it on the NEXT launch. Without this, a P2P-only group (REST
        // 404 → server epoch never set) keeps registry epoch < crypto epoch,
        // and `loadFromVault`'s descending probe returns the STALE pre-removal
        // snapshot (KeychainGroupSessionVault NEVER deletes old-epoch items)
        // BEFORE it ever reaches the live post-removal snapshot → the removal
        // is silently reverted on relaunch, forward secrecy is lost (the
        // removed member's send chain still decrypts) and cross-platform
        // decrypt breaks. `setEpoch` is monotonic, so on a server-tracked
        // group (where serverEpoch ≥ cryptoEpoch was already persisted) this
        // is a safe no-op. This is the single sink for all three remove paths
        // (admin `removeGroupMember`, P2P `applyMemberRemoved`, server
        // `handleGroupMembershipChanged`), so every path is covered once.
        GroupRegistry.shared.setEpoch(groupId: groupHex, epoch: rekey.newCryptoEpoch)
        for rot in rekey.rotates {
            NotificationCenter.default.post(
                name: AppState.groupSenderKeyCtlNotification,
                object: nil,
                userInfo: [
                    "recipient": rot.recipientId,
                    "envelopeJson": rot.envelopeJson,
                ])
        }
        // 2026-07-17 — group metadata (name/avatar) is sealed via this SAME
        // per-epoch 0xE4 send-chain (updateGroupMetadata → encryptForWire →
        // encryptForGroup), so once group_epoch advances past whatever
        // epoch it was last sealed at, it becomes PERMANENTLY undecryptable
        // for anyone who has since moved on — this very rekey just wiped
        // every recv chain. Confirmed live on Desktop (same architecture):
        // a stale rename threw "group_epoch mismatch: wire=0 state=1", not
        // a missing/delayed key. Self-heal: whichever admin's device
        // processes this rekey immediately re-seals the CURRENT known
        // name/avatar (newName/avatarData nil = keep-as-is, per
        // updateGroupMetadata's own contract) under the fresh epoch, so the
        // group converges again without waiting for a manual rename.
        // No-op for non-admins — updateGroupMetadata's own admin guard
        // would reject anyway, checked here first to avoid a noisy log for
        // the common (non-admin) case.
        if GroupRegistry.shared.entry(for: groupHex)?.admins.contains(selfId) == true {
            updateGroupMetadata(groupId: groupHex, newName: nil, avatarData: nil)
        }
    }

    /// Robustly read a UInt32 field from a WS JSON payload (values arrive
    /// as `NSNumber` under JSONSerialization; be lenient about String too).
    fileprivate static func uint32Field(_ value: Any?) -> UInt32 {
        if let n = value as? NSNumber { return UInt32(truncatingIfNeeded: n.int64Value) }
        if let s = value as? String, let v = UInt32(s) { return v }
        return 0
    }

    /// The server's `operation` token is the REST verb ("add" / "remove" /
    /// "leave") on a live mutation, but the membership-LOG token
    /// ("member_added" / "member_removed" / "member_left") on the start-up
    /// catch-up replay — and "snapshot" when no log entry exists. Treat both
    /// vocabularies, default to "not a removal" (a snapshot only re-states the
    /// roster, which we apply either way).
    fileprivate static func isMembershipRemoval(_ operation: String) -> Bool {
        switch operation {
        case "remove", "leave", "member_removed", "member_left":
            return true
        default:
            return false
        }
    }

    /// Fase 1C — the `group_membership_changed` `operation` values for
    /// admin promote/demote (server contract, verbatim: `"admin_add"` /
    /// `"admin_remove"` — NOT the envelope `t`, which is
    /// `"admin_added"`/`"admin_removed"`). Neither membership nor the
    /// crypto epoch changes for these two.
    fileprivate static func isAdminMembershipOp(_ operation: String) -> Bool {
        switch operation {
        case "admin_add", "admin_remove":
            return true
        default:
            return false
        }
    }
}

// MARK: - Fase 1C: server `group_metadata_changed` consumer

extension AppState {

    /// Apply one server-authoritative `group_metadata_changed` event —
    /// decrypt the 0xE4 blob with the ACTOR's recv chain (same engine as
    /// group TEXT) and update the local name/avatar.
    ///
    /// Wire: `{group_id, metadata_blob_b64, metadata_version, actor_user_id,
    /// envelope_canonical_b64, envelope_signature_b64, server_ts, replay?}`
    /// (server contract, verbatim). No `members`/`admins` array travels on
    /// this event — the roster is unaffected (`group_epoch` is unchanged).
    ///
    /// Signature verification: NOT performed client-side, matching the
    /// EXISTING precedent set by `handleGroupMembershipChanged` (which also
    /// trusts the server-authoritative payload over the bearer-authed,
    /// cert-pinned WS session rather than re-verifying `envelope_*_b64`).
    /// The AEAD decrypt below is itself an authentication check: only a
    /// client with a valid recv chain for `actor_user_id` can produce a
    /// plaintext at all — a forged/corrupted blob fails here and is dropped.
    @MainActor
    fileprivate func handleGroupMetadataChanged(_ data: [String: Any]) {
        guard let rawGroupId = data["group_id"] as? String, !rawGroupId.isEmpty,
              let blobB64 = data["metadata_blob_b64"] as? String, !blobB64.isEmpty,
              let wire = Data(base64Encoded: blobB64) else {
            print("[AppState] group_metadata_changed missing required fields: \(data.keys)")
            return
        }
        let groupHex = rawGroupId.replacingOccurrences(of: "-", with: "").lowercased()
        let actor = (data["actor_user_id"] as? String) ?? ""
        let version = Self.uint32Field(data["metadata_version"])
        let selfId = currentUserId ?? AppState.currentUserIdSnapshot ?? ""
        guard !selfId.isEmpty, !actor.isEmpty else { return }

        guard let entry = GroupRegistry.shared.entry(for: groupHex) else {
            // Unknown group locally (no roster ⇒ no recv chain to decrypt
            // against). The next `group_membership_changed` bootstrap (or a
            // future GET-on-open) re-anchors us; nothing to apply yet.
            print("[AppState] group_metadata_changed: unknown group \(groupHex.prefix(8))")
            return
        }
        guard let plaintext = GroupChatService.shared.decrypt(
            wire: wire, senderId: actor, groupId: groupHex,
            members: entry.members, selfId: selfId) else {
            print("[AppState] group_metadata_changed: decrypt failed g=\(groupHex.prefix(8)) actor=\(actor.prefix(8))")
            // 2026-07-19 — same retroactive gap-close as the GET-recovery
            // path (`decryptAndApplyGroupMetadataBlob`): a live push can be
            // this stale for the identical reason (sealed at an epoch our
            // crypto state has since moved past). Unpacking here only to
            // read the epoch field — no crypto/decrypt attempted twice.
            if let parsed = try? GroupSenderKey.unpackGroupWire(wire) {
                maybeReSealStaleGroupMetadata(groupHex: groupHex, wireGroupEpoch: parsed.groupEpoch, selfId: selfId)
            }
            return
        }
        applyGroupMetadataPayload(groupHex: groupHex, json: plaintext, version: version)
    }

    /// Parse+apply a decrypted `{name, avatar_ref}` payload (shared by the
    /// live WS consumer above and the GET-on-bootstrap recovery path).
    @MainActor
    fileprivate func applyGroupMetadataPayload(groupHex: String, json: String, version: UInt32) {
        guard let jsonData = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(GroupMetadataPayload.self, from: jsonData) else {
            print("[AppState] group_metadata_changed: undecodable payload for \(groupHex.prefix(8))")
            return
        }
        // Replay/downgrade defense — `setMetadataVersion` alone is monotonic,
        // but that guard is useless unless the name/avatar WRITE below is
        // gated by the SAME check: a stale/replayed event (e.g. a federated
        // catch-up burst delivered out of order) must not overwrite a
        // NEWER local rename with older data.
        if version > 0,
           let entry = GroupRegistry.shared.entry(for: groupHex),
           version <= entry.metadataVersion {
            print("[AppState] group_metadata_changed: stale version \(version) <= \(entry.metadataVersion) for \(groupHex.prefix(8)), ignored")
            return
        }
        if !payload.name.isEmpty {
            GroupRegistry.shared.renameGroup(groupId: groupHex, newName: payload.name)
        }
        GroupRegistry.shared.setAvatarRef(groupId: groupHex, avatarRef: payload.avatarRef)
        if version > 0 {
            GroupRegistry.shared.setMetadataVersion(groupId: groupHex, version: version)
        }
        NotificationCenter.default.post(
            name: AppState.groupRegistryChangedNotification,
            object: nil,
            userInfo: ["groupId": groupHex])
    }
}

// MARK: - W-GRPRING: incoming GROUP call (ring + accept/reject)

extension AppState {

    /// Where an incoming group call reached us. The two sources are deduped by
    /// `call_id`: the server fans BOTH out (WS `group_call_invite` to everyone,
    /// plus an APNs VoIP push to every invitee not on a fresh socket) and
    /// deliberately omits the 1:1 `armCallPushAck` delay — one group `call_id`
    /// has N invitees, so the ack cannot disambiguate them.
    enum IncomingGroupCallSource {
        case webSocket
        case push
    }

    /// CallKit UUID for a group call. The room id is a UUID string today
    /// (`uuid.New()` server-side / `UUID().uuidString` client-side) — if it
    /// ever isn't, we still MUST report SOMETHING to CallKit for a VoIP push,
    /// so fall back to a fresh UUID (routing is done via `groupCallKitId`, not
    /// by parsing the uuid back).
    static func callKitUUID(forGroupCallId callId: String) -> UUID {
        return UUID(uuidString: callId) ?? UUID()
    }

    /// Ring for an incoming group call. Returns true when a ring is live for
    /// `invite.callId` after this call (either newly presented, or already up
    /// from the other source) — the PushKit path uses that to decide whether
    /// the CallKit call it MUST report can stay up or has to be ended at once.
    @discardableResult
    @MainActor
    func presentIncomingGroupCall(
        _ invite: IncomingGroupCallInvite,
        source: IncomingGroupCallSource
    ) -> Bool {
        // Already accepted or rejected (push ⇄ WS race, or a WS reconnect
        // replaying the invite) — never ring twice for the same room.
        if handledGroupCallIds.contains(invite.callId) {
            let dupId: String = String(invite.callId.prefix(8))
            let dupMsg: String = "[AppState] W-GRPRING dup dropped (already handled) call=" + dupId
            print(dupMsg)
            return false
        }
        // Already ringing for THIS call from the other source: adopt the richer
        // payload (the WS invite and the push carry the same fields, but an
        // older peer may omit the group context on one of them).
        if let current = incomingGroupCallInvite, current.callId == invite.callId {
            if current.groupName.isEmpty && !invite.groupName.isEmpty {
                incomingGroupCallInvite = invite
            }
            if source == .push {
                // CallKit is now ringing natively — silence the in-app ringtone
                // so the user doesn't get two dialers (single-dialer rule,
                // W450/W520).
                stopInAppRingtone()
            }
            return true
        }
        // Busy: in a 1:1 call, ringing for one, or already in a group call.
        // We simply do not join — there is no `group_call_decline` wire type
        // and the room stays open for the other invitees.
        if isInCall || callState != .idle || groupCallControllerState != .idle {
            let shortId: String = String(invite.callId.prefix(8))
            let busyMsg: String = "[AppState] W-GRPRING busy — ignoring group call " + shortId
            print(busyMsg)
            return false
        }

        incomingGroupCallInvite = invite
        let shortId: String = String(invite.callId.prefix(8))
        let ringMsg: String = "[AppState] W-GRPRING ring " + shortId + " type=" + invite.callType
        print(ringMsg)

        switch source {
        case .push:
            // The PushKit handler reports the call to CallKit itself (iOS
            // mandate) — the system UI IS the ring. No in-app ringtone.
            break
        case .webSocket:
            presentGroupCallRingSurface(invite)
        }
        armGroupCallRingTimeout(callId: invite.callId)
        return true
    }

    /// A ringing invitee who never joins is NOT in `GroupCall.Participants`, so
    /// the server's `group_call_ended` fan-out (participants only — verified in
    /// `cmd/bcrypto-lite/main.go`, case "group_call_end") never reaches them:
    /// nothing on the wire would ever take this ring down if the creator hangs
    /// up first. Bounded client-side timeout → treat as a MISSED group call.
    /// Same `asyncAfter` idiom as `armAcceptGateTimeout`.
    @MainActor
    private func armGroupCallRingTimeout(callId: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45.0) { [weak self] in
            guard let self = self,
                  self.incomingGroupCallInvite?.callId == callId else { return }
            print("[AppState] W-GRPRING ring timed out (unanswered) call=\(callId.prefix(8))…")
            self.stopInAppRingtone()
            self.markGroupCallHandled(callId)
            self.incomingGroupCallInvite = nil
            NotificationCenterService.shared.clearIncomingCall(callId: callId)
            self.clearGroupCallKitCall(reason: .unanswered)
        }
    }

    /// W-GRPRING-JOIN (2026-07-19, incident "invito di gruppo rimasto in
    /// sospeso"): bound how long we wait after ACCEPTING a group-call invite
    /// for the server to confirm the join (`group_call_update` → controller
    /// `.active`). The server can reject `group_call_join` for a stale/ended
    /// call_id, a no-longer-invited user, or a full room (cmd/bcrypto-lite/
    /// main.go, case "group_call_join": "group call not found" / "not invited
    /// to this group call" / "group call full") — but that rejection is a
    /// generic `{type:"error"}` envelope with no `call_id`/`code` (see W329's
    /// handler), so it cannot be reliably correlated back to THIS join. Only
    /// a client-side bound self-clears it, same idiom as
    /// `armGroupCallRingTimeout` for the PRE-accept ring. Without this, a
    /// rejected/stale join left `groupCallControllerState` stuck at
    /// `.connecting` forever: the call cover never dismisses (not
    /// actionable), AND — per the busy-guard in `presentIncomingGroupCall`
    /// (`groupCallControllerState != .idle`) — every subsequent incoming
    /// group-call invite is silently dropped as "busy" until the app
    /// restarts.
    @MainActor
    private func armGroupCallJoinTimeout(callId: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [weak self] in
            guard let self = self,
                  case .connecting(let cid) = self.groupCallControllerState,
                  cid == callId else { return }
            print("[AppState] W-GRPRING-JOIN join timed out (no group_call_update) call=\(callId.prefix(8))…")
            // Best-effort server-side cleanup (safe no-op if the join never
            // actually registered us — see group_call_leave's `wasParticipant`
            // guard server-side) + local state unwind so the busy-gate clears.
            self.groupCallController?.leave()
            self.groupCallControllerState = .idle
            self.clearGroupCallKitCall(reason: .failed("group_call_join_timeout"))
        }
    }

    /// Ring surface for a group call that arrived over the LIVE WS. Mirrors the
    /// 1:1 `call_incoming` fork exactly:
    ///   foreground        → in-app full-screen ring + in-app ringtone
    ///   background + CallKit  → native CallKit incoming call
    ///   background + CallKit-free (W-NOCALLKIT) → local INCOMING_CALL notification
    @MainActor
    private func presentGroupCallRingSurface(_ invite: IncomingGroupCallInvite) {
        let foreground = UIApplication.shared.applicationState == .active
        if foreground {
            startInAppRingtone()
            return
        }
        if CallsGate.callKitFreeMode {
            let callId = invite.callId
            let peer = invite.creatorId
            let name = invite.displayTitle
            let video = invite.hasVideo
            let creator = invite.creatorName
            let gid = invite.groupId
            let gname = invite.groupName
            // `groupCall: true` stamps type=incoming_group_call + the group
            // context into userInfo, so an Answer tap AFTER the app has been
            // killed (the notification outlives the process) still routes to the
            // GROUP accept path instead of the 1:1 one.
            Task {
                await NotificationCenterService.shared.postIncomingCall(
                    callId: callId, peerId: peer, callerName: name, hasVideo: video,
                    groupCall: true, creatorName: creator, groupId: gid, groupName: gname)
            }
            return
        }
        let uuid = Self.callKitUUID(forGroupCallId: invite.callId)
        groupCallKitId = uuid
        let name = invite.displayTitle
        Task { [weak self] in
            // W-CALLKITVIDEOFORCE — force hasVideo=true (see the PushKit
            // group branch above for the full rationale); `invite.hasVideo`
            // still drives the real group-call UI/behavior elsewhere.
            await self?.callKit?.reportIncomingCall(
                uuid: uuid, callerName: name, hasVideo: true)
        }
    }

    /// PushKit VoIP entry point for a group call: build the invite, ring, and
    /// hand the caller what it needs for the MANDATORY `reportNewIncomingCall`
    /// (a VoIP push that does not report an incoming call gets the app killed
    /// and future VoIP pushes throttled — so the caller reports the returned
    /// uuid unconditionally, and ends it at once when `presented == false`).
    /// The CallKit uuid is DERIVED from the call_id, so a WS invite and a push
    /// for the same room resolve to the same uuid (idempotent report).
    /// Body extracted from the closure per CLAUDE.md §13/§14 (keep nested
    /// MainActor.run closures to one call).
    @MainActor
    func prepareIncomingPushGroupCall(
        _ payload: PushKitProvider.ParsedGroupPayload
    ) -> (uuid: UUID, display: String, presented: Bool) {
        // Prefer the LOCAL rubrica for the creator's name (the push carries a
        // server-supplied one) — same 3-tier resolution as the 1:1 push path.
        let creatorName = callKitDisplayName(
            callerId: payload.creatorId, fallback: payload.creatorName)
        let invite = IncomingGroupCallInvite(
            callId: payload.callId,
            creatorId: payload.creatorId,
            creatorName: creatorName,
            callType: payload.callType,
            groupId: payload.groupId,
            groupName: payload.groupName)
        let uuid = Self.callKitUUID(forGroupCallId: payload.callId)
        // Do NOT latch `groupCallKitId` before we know the invite is
        // presentable. When we are ALREADY in a group call that property holds
        // the CallKit id of the LIVE call: overwriting it (and then nil-ing it
        // on the not-presentable path) ORPHANS that call — `onEndCall` would
        // stop matching it and fall through to the 1:1 `endCall()`, so "End" on
        // the system UI would tear down the wrong call and leave the group call
        // running with a dead CallKit entry. Everything here runs on the
        // MainActor, so a racing WS `group_call_invite` cannot interleave
        // between the present and the latch — it dedups on
        // `incomingGroupCallInvite`/`handledGroupCallIds`, not on this uuid.
        let presented = presentIncomingGroupCall(invite, source: .push)
        if presented {
            groupCallKitId = uuid
        }
        // Not presented (busy / already handled): the caller STILL reports to
        // CallKit — the PushKit contract is non-negotiable — and then ends that
        // uuid immediately, without touching the live call's id.
        return (uuid, invite.displayTitle, presented)
    }

    /// Accept from the in-app ring surface. When CallKit owns the ring, route
    /// through CXAnswerCallAction so the system UI resolves; the provider's
    /// `onAnswerCall` then lands back on `performAcceptIncomingGroupCall()`.
    /// Mirrors `answerIncomingCall()`.
    ///
    /// W-GRPDOUBLEDIALER FOLLOW-UP (2026-07-27, CRITICAL — live-confirmed
    /// regression): `presentIncomingGroupCall`'s foreground push case calls
    /// `releaseFromSystemUI(prepared.uuid)` to hide the redundant native
    /// banner, but does NOT (and must not — see below) clear
    /// `groupCallKitId`. Before this fix, tapping "Accetta" on our own
    /// screen in exactly that case silently did NOTHING: `try?` swallowed
    /// `CXAnswerCallAction`'s failure (CallKit has no record of a call we
    /// already told it had ended) and `performAcceptIncomingGroupCall()`
    /// never ran. Root-caused from Pavel's live device report + screenshot
    /// showing the accept button doing nothing. Falling back to the direct
    /// accept path on ANY CallKit answerCall failure — not just this one
    /// case — makes "Accetta" unconditionally work regardless of whatever
    /// state CallKit's own registration is in. `groupCallKitId` itself is
    /// deliberately left untouched by the release (busy/dedup guards
    /// elsewhere key off it meaning "a group call is ringing/active",
    /// which is still true here — only CallKit's OWN bookkeeping for that
    /// uuid was released, not our call state).
    @MainActor
    func answerIncomingGroupCall() {
        if let uuid = groupCallKitId, !CallsGate.callKitFreeMode {
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.callKit?.answerCall(uuid: uuid)
                } catch {
                    RTLog.warn("call", "W-GRPDOUBLEDIALER answerIncomingGroupCall: CXAnswerCallAction failed (\(error.localizedDescription)) — falling back to direct accept so the button always works")
                    await MainActor.run { self.performAcceptIncomingGroupCall() }
                }
            }
            return
        }
        performAcceptIncomingGroupCall()
    }

    /// Shared accept path — run by the in-app ring button, the CallKit answer
    /// (`onAnswerCall`), and the notification "Rispondi" action. Idempotent
    /// (the invite is nil after the first pass).
    @MainActor
    func performAcceptIncomingGroupCall() {
        guard let invite = incomingGroupCallInvite else {
            RTLog.info("call", "W-CALLFG-DIAG performAcceptIncomingGroupCall — no incomingGroupCallInvite, no-op (already handled?)")
            return
        }
        RTLog.info("call", "W-CALLFG-DIAG performAcceptIncomingGroupCall ENTER callId=\(invite.callId.prefix(8))")
        stopInAppRingtone()
        markGroupCallHandled(invite.callId)
        incomingGroupCallInvite = nil
        NotificationCenterService.shared.clearIncomingCall(callId: invite.callId)
        // The CallKit call (if any) stays UP for the duration of the group call
        // — `onEndCall` on it routes to `endGroupCallFromSystemUI()`.
        guard let controller = groupCallController else {
            // Cold start: the WS (and the controller) do not exist yet — the
            // push woke us. Latch; `connectPersistentSocket()` consumes it.
            pendingGroupCallJoinId = invite.callId
            pendingGroupCallJoinVideo = invite.hasVideo
            // In-call chat panel — latch the group id too (see
            // `pendingGroupCallJoinGroupId` kdoc); "" for an ad-hoc call.
            pendingGroupCallJoinGroupId = invite.groupId
            print("[AppState] W-GRPRING accept latched (no controller yet) call=\(invite.callId.prefix(8))…")
            return
        }
        // Flip the surface state SYNCHRONOUSLY: the group-call cover in
        // ContentView is presented while (invite != nil || state != .idle), and
        // the controller re-publishes `.connecting` only on a LATER main-queue
        // hop (its onStateChange bounces through DispatchQueue.main.async). Not
        // setting it here would leave one runloop turn where both are false →
        // the cover dismisses and immediately re-presents (flicker / dropped
        // presentation). The controller's own emission moments later carries the
        // identical value, so this is a no-op then.
        groupCallControllerState = .connecting(callId: invite.callId)
        // In-call chat panel — bind the persisted-group id (if any) BEFORE
        // join, same reasoning as the cold-start branch above: the panel's
        // binding must already be in place by the time the call UI appears.
        groupCallViewModel?.bindGroupId(invite.groupId)
        // The SAME join path as before: single source of truth for the WS
        // `group_call_join` AND the GroupSession crypto bootstrap.
        controller.join(callId: invite.callId, video: invite.hasVideo)
        armGroupCallJoinTimeout(callId: invite.callId)
    }

    /// Reject the incoming group call. There is deliberately NO wire message:
    /// the server has no `group_call_decline` type and the room must stay open
    /// for the other invitees — rejecting just means we never send
    /// `group_call_join`. (If a "X ha rifiutato" indicator is ever wanted, it
    /// needs a NEW server type — flagged, not invented here.)
    @MainActor
    func declineIncomingGroupCall() {
        guard let invite = incomingGroupCallInvite else { return }
        stopInAppRingtone()
        markGroupCallHandled(invite.callId)
        incomingGroupCallInvite = nil
        NotificationCenterService.shared.clearIncomingCall(callId: invite.callId)
        clearGroupCallKitCall(reason: .declined)
        print("[AppState] W-GRPRING rejected group call \(invite.callId.prefix(8))… (no wire decline — room stays open)")
    }

    /// True when an INCOMING_CALL notification belongs to a GROUP call. Two
    /// ways to know:
    ///   • a ring is already up for that call_id (WS invite → local
    ///     notification, app alive but backgrounded), or
    ///   • the payload IS the server's group ALERT push — `type ==
    ///     "incoming_group_call"` (internal/push/apns.go
    ///     SendAlertGroupCallInvite). This is the ONLY signal available on a
    ///     cold start (app killed ⇒ no WS invite was ever seen).
    /// `didReceive` stringifies every userInfo value, so `type` arrives as a
    /// plain String here.
    @MainActor
    func isGroupCallNotification(callId: String, info: [String: String]) -> Bool {
        if incomingGroupCallInvite?.callId == callId { return true }
        return info["type"] == "incoming_group_call"
    }

    /// Answer / decline / open for a GROUP call arriving through the
    /// CallKit-FREE notification surface (W-NOCALLKIT). On a cold start the ring
    /// state does not exist yet — rebuild it from the push userInfo (the ALERT
    /// payload carries the SAME fields as the VoIP one) before acting, so the
    /// accept reaches `performAcceptIncomingGroupCall()` (which latches the join
    /// until `connectPersistentSocket()` builds the controller).
    @MainActor
    func handleGroupCallNotificationAction(
        _ action: NotificationCenterService.CallAction,
        callId: String,
        info: [String: String]
    ) {
        if incomingGroupCallInvite?.callId != callId {
            let creatorId = info["creator_id"] ?? ""
            let invite = IncomingGroupCallInvite(
                callId: callId,
                creatorId: creatorId,
                creatorName: callKitDisplayName(
                    callerId: creatorId, fallback: info["creator_name"]),
                callType: info["call_type"] ?? "audio",
                groupId: info["group_id"] ?? "",
                groupName: info["group_name"] ?? "")
            guard presentIncomingGroupCall(invite, source: .push) else {
                // Busy, or this room was already accepted/rejected — there is
                // nothing left to answer. Drop the stale notification.
                NotificationCenterService.shared.clearIncomingCall(callId: callId)
                return
            }
        }
        switch action {
        case .answer:
            performAcceptIncomingGroupCall()
        case .decline:
            declineIncomingGroupCall()
        case .open:
            // Plain tap: bring the ring surface forward (the cover is driven by
            // `incomingGroupCallInvite`, now non-nil) and ring audibly. Does NOT
            // answer — same semantics as the 1:1 `.open` branch.
            startInAppRingtone()
        }
    }

    /// "End" pressed on the SYSTEM (CallKit) UI of a group call: a reject while
    /// still ringing, a leave once joined.
    @MainActor
    func endGroupCallFromSystemUI() {
        if incomingGroupCallInvite != nil {
            declineIncomingGroupCall()
            return
        }
        groupCallController?.leave()   // → onStateChange(.idle) → clears CallKit
        clearGroupCallKitCall(reason: .userEnded)
    }

    /// Tear down the CallKit call we reported for a group call (if any). Safe
    /// to call repeatedly — nil-guarded.
    @MainActor
    func clearGroupCallKitCall(reason: CallEndReason) {
        guard let uuid = groupCallKitId else { return }
        groupCallKitId = nil
        Task { [weak self] in
            await self?.callKit?.reportCallEnded(uuid: uuid, reason: reason)
        }
    }

    /// Remember an accepted/rejected room so neither source re-rings it.
    /// Bounded at 32 (a hostile peer must not be able to grow this forever).
    @MainActor
    private func markGroupCallHandled(_ callId: String) {
        guard !handledGroupCallIds.contains(callId) else { return }
        handledGroupCallIds.append(callId)
        if handledGroupCallIds.count > 32 {
            handledGroupCallIds.removeFirst(handledGroupCallIds.count - 32)
        }
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
    func startVideoPipeline(
        for peerId: String,
        sourceMode: VideoCallPipeline.SourceMode = .camera,
        startPaused: Bool = false
    ) async {
        // Tear down any leftover pipeline from a previous call.
        videoPipeline?.stop()

        let pipeline = VideoCallPipeline()
        // media-consent v1:
        //  - sourceMode .external = no camera ever (screen-share encode, or
        //    decode-only rendering of a WS peer's screen).
        //  - startPaused = camera + local mirror preview run, but NOTHING
        //    leaves the device until the peer accepts the upgrade.
        pipeline.sourceMode = sourceMode
        if startPaused { pipeline.setVideoPaused(true) }

        // Resolve transport (WS client). Reuse the already-authenticated
        // liveProvider WS — creating a new BCryptoBackendProvider would
        // produce a disconnected WS whose sendVideoFrame calls are all
        // silently dropped (webSocketTask == nil → "DROPPED" log).
        guard let ws = liveProvider?.getWebSocketClient() else {
            print("[AppState] startVideoPipeline: no live WS provider, skipping")
            return
        }

        // W525: capture a weak reference to the calling impl so each
        // fragment can stamp the current call_id onto the WS envelope.
        // Without this Android/Desktop drop every video_frame the same
        // way they drop audio_frames without call_id.
        // Captured strongly because BCryptoCallingApiImpl is owned by
        // liveProvider (also captured via `ws`) and outlives the call;
        // a weak capture on an optional reference here would just add
        // optional chaining noise without lifetime benefit.
        let callingImpl: BCryptoCallingApiImpl? = liveProvider?.callingApi as? BCryptoCallingApiImpl

        // W392 + W394 + Task 10: PQC seal/unwrap on the video transport,
        // with mid-call rekey support. The pipeline owns its own
        // PqcFrameEncryptor / Decryptor (under sealerLock) and
        // re-rotates whenever AppState calls rotatePqcSealer with a
        // fresh ML-KEM secret. Initial install with the current call
        // key (transitional or post-handshake); the wireSasReady-
        // ToController observer re-fires this with the real key once
        // the W389 broker reports. `callId` is the same wire call_id
        // stamped on every outbound video_frame envelope below (via
        // callingImpl.getActiveCallId()) so the HKDF-bound sealer key
        // and the envelope's call_id can never drift apart.
        //
        // `activeVideoCallIdentity` PINS (callId, selfIsRoleA) here so
        // wireSasReadyToController's LATER rotate (fired asynchronously
        // once the real ML-KEM secret lands) reuses the exact same
        // identity instead of independently recomputing selfIsRoleA from
        // `callContactId` — two independently-computed values could in
        // principle diverge (peerId here vs. callContactId there) and
        // silently swap the send/recv key assignment mid-call. Pinning
        // removes that risk by construction.
        let videoCallId = callingImpl?.getActiveCallId() ?? ""
        let videoSelfIsRoleA = PqcRtpFrameSealer.selfIsRoleA(self.currentUserId ?? "", peerId)
        self.activeVideoCallIdentity = (callId: videoCallId, selfIsRoleA: videoSelfIsRoleA)
        pipeline.rotatePqcSealer(self.callPqcSessionKey, callId: videoCallId, selfIsRoleA: videoSelfIsRoleA)

        // Task 10 (2026-07-01) — Android's real, shipped WS-relay video
        // fallback (`BcryptoWsVideoRelayTransport`) never uses
        // `WireRelayFrameCodec` for video: it ships `frame` as exactly
        // `base64(PqcRtpFrameSealer.seal(rawFragment))` — nonce||ciphertext
        // ||tag over the UNTOUCHED VideoFrameFragmenter output (7-byte
        // sub-header + NAL chunk) — with `frag_idx`/`total_frags`/
        // `is_key_frame` as TOP-LEVEL WS JSON fields, not embedded in a
        // binary mux wrapper. The old `AndroidVideoWireAdapter.encodeForAndroid`
        // path (this file's previous behaviour, opt-in via the now-removed
        // `qaudion.video.android_wire_compat` UserDefaults toggle) wrapped
        // sealed fragments in `WireRelayFrameCodec.encodeVideo` — an
        // assumption about Android's wire format that was never verified
        // against real Android code and is now confirmed wrong (see the
        // "Task 10 correction" note at the top of AndroidVideoWireAdapter.swift).
        // `parseIosFragment` is still used here — purely to read the
        // fragIdx/totalFrags/isKeyFrame metadata for the WS envelope's
        // top-level fields; it does not wrap or alter the sealed bytes.
        pipeline.onOutboundFragment = { [weak self, weak ws, weak pipeline, callingImpl] fragment in
            // Task 10 holistic-review fix — sealOutboundFragment now
            // returns nil (drop) when no encryptor is installed or seal
            // fails, instead of a non-optional Data that used to fall back
            // to shipping the raw fragment unsealed. `pipeline == nil` (the
            // pipeline itself deallocated) is treated the same way: no
            // sealed bytes, no send — never fall back to `fragment`.
            guard let pipeline, let sealed = pipeline.sealOutboundFragment(fragment) else { return }
            // W-STALEPIPE (2026-07-13) — confirmed server-side (call
            // a92d7e90-b4a9-469c-8cc8-2665428e3607, 2026-07-10): a real call's
            // sender kept shipping video_frame WS messages for 19+ seconds
            // AFTER its own call.media.summary(end_reason=user_hangup)
            // telemetry fired, all correctly rejected server-side as
            // "not an established call party" (fleet-wide: ~5300 rejections/
            // week across 4 accounts, every affected call's rejections start
            // at the logged call-end timestamp). `endCall()` calls
            // `videoPipeline?.stop()` synchronously and `onCapturedPixelBuffer
            // = nil` inside `stop()` should cut this closure off immediately —
            // if frames keep arriving after that, `pipeline` here is a STALE
            // instance no longer referenced by `self.videoPipeline` (e.g. a
            // lingering AVCaptureSession delegate reference outliving
            // `stop()`), not the current call's pipeline. This guard is
            // unconditionally correct regardless of the retain mechanism —
            // a stale pipeline's frames must never reach the wire — and the
            // log proves/refutes the theory on the next occurrence instead
            // of guessing further.
            guard let activePipeline = self?.videoPipeline, activePipeline === pipeline else {
                RTLog.error("call", "W-STALEPIPE onOutboundFragment fired for a pipeline that is no longer self.videoPipeline — dropping frame (would have been rejected server-side anyway)")
                return
            }
            let parsed = AndroidVideoWireAdapter.parseIosFragment(fragment)
            let cid = callingImpl?.getActiveCallId()
            let effectiveWs = self?.liveProvider?.getWebSocketClient() ?? ws
            effectiveWs?.sendVideoFrame(
                recipientId: peerId, frame: sealed, callId: cid,
                fragIdx: parsed?.fragIdx ?? 0,
                totalFrags: parsed?.totalFrags ?? 1,
                isKeyFrame: parsed?.isKeyFrame ?? false)
        }

        // Inbound — register the WS handler. Feeds the base64-decoded
        // `frame` bytes (the raw PqcRtpFrameSealer-sealed envelope, no
        // outer wrapper) straight to acceptInboundFragment, which applies
        // PQC unwrap internally before defragmentation.
        // W574c: extracted to registerInboundVideoHandler so the same
        // registration can be replayed on the FRESH WS instance after a
        // mid-call reconnect (see rewireCallAudioOnReconnect) — without
        // it, video RX stayed bound to the dead instance.
        registerInboundVideoHandler(on: ws, pipeline: pipeline)

        do {
            try await pipeline.start()
            self.videoPipeline = pipeline
            // W398: spin up ABR loop on the same lifecycle.
            let abr = AbrController(pipeline: pipeline)
            // W574o — attach the active call_id so call.video.tune telemetry
            // lands on the per-call server timeline (same source the audio
            // tuner + wire audio_frame use).
            abr.callIdProvider = { [weak self] in
                guard let live = self?.liveProvider,
                      let impl = live.callingApi as? BCryptoCallingApiImpl else { return nil }
                return impl.getActiveCallId()
            }
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

    /// W574c — inbound video_frame handler registration, shared between
    /// startVideoPipeline (initial WS) and rewireCallAudioOnReconnect
    /// (fresh WS instance after a mid-call reconnect).
    ///
    /// Task 10 (2026-07-01) — `frame` is always the raw PqcRtpFrameSealer
    /// envelope (nonce||ciphertext||tag), matching Android's real shipped
    /// `BcryptoWsVideoRelayTransport` wire format. No outer wrapper is
    /// ever applied on the wire (the previous `AndroidVideoWireAdapter
    /// .decodeFromAndroid` / `WireRelayFrameCodec` unwrap branch assumed
    /// one that Android never sends — see the matching note on the send
    /// side in `startVideoPipeline`).
    ///
    /// Task 11 holistic-review fix (2026-07-01) — a `call_id` check on
    /// the inbound envelope was missing entirely: every video_frame was
    /// fed to `acceptInboundFragment` regardless of which call (or
    /// which stale/overlapping session) it was relayed for, relying
    /// solely on AEAD auth succeeding as the only safety net. Android's
    /// `BcryptoWsVideoRelayTransport.parseAndUnseal` (`if (cid != callId)
    /// return null`) and Desktop's `BcryptoWsVideoRelayTransport
    /// .acceptRawEnvelope` (`if (raw.call_id !== this.opts.callId)
    /// return`) both reject on ANY mismatch — including an unknown/empty
    /// active call_id — with no nil-passthrough. This mirrors that exact
    /// strict semantics (deliberately stricter than the audio path's
    /// `handleIncomingEncryptedFrame`, which allows the frame through
    /// when either side is nil/unbound — video's fragment reassembler
    /// has no such tolerant fallback and Android/Desktop don't either).
    /// `getActiveCallId()` is re-resolved on every frame (not captured
    /// once at registration time) via the live `liveProvider`, so a
    /// reconnect or a fresh call after this closure was created is
    /// always compared against the CURRENT active call — mirrors the
    /// `callService.getCallId` live-getter pattern used for the audio
    /// WS handler (see `AppState.wireCallService` / CallService.swift's
    /// `attachIncomingAudioHandler`).
    @MainActor
    func registerInboundVideoHandler(on ws: BCryptoWebSocketClient,
                                     pipeline: VideoCallPipeline) {
        ws.registerHandler(type: "video_frame") { [weak self, weak pipeline] _, data in
            guard let pipeline = pipeline,
                  let b64 = data["frame"] as? String,
                  let raw = Data(base64Encoded: b64) else { return }
            let incomingCallId = data["call_id"] as? String
            guard let live = self?.liveProvider,
                  let impl = live.callingApi as? BCryptoCallingApiImpl,
                  let activeCallId = impl.getActiveCallId(),
                  let cid = incomingCallId,
                  cid.caseInsensitiveCompare(activeCallId) == .orderedSame
            else { return }
            pipeline.acceptInboundFragment(raw)
        }
    }

    /// W393: bridge for VideoCallView's "Inverti" button.
    @MainActor
    func videoFlipCamera() {
        videoPipeline?.flipCamera()
    }

    /// W393: bridge for VideoCallView's "Cam ON/OFF" toggle.
    ///
    /// WIRE_SPEC §8.1 — additionally ships a best-effort `call_video_state`
    /// so the peer's UI knows this is an intentional pause (badge / audio-only
    /// fallback) rather than a silent stall. Purely informational: the local
    /// capture pipeline pause/resume above is unchanged and untouched by
    /// whether the send succeeds — never blocks, never throws into the UI.
    @MainActor
    func videoSetCameraEnabled(_ enabled: Bool) {
        videoPipeline?.setCameraEnabled(enabled)
        videoTransitionCause = enabled ? "local-camera-start" : "local-camera-stop"
        localVideoPaused = !enabled
        // WIRE_SPEC §8.9 — on-change trigger; the heartbeat re-states it so a
        // lost frame is not permanent.
        announceVideoState(force: false)
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
            // W-GRPSTALEMGR (2026-07-19, TestFlight v1.0.812/813 3-way test):
            // `connectPersistentSocket` re-runs on every socket rebuild
            // (willEnterForeground / `reviveSignalingSocket` on the very
            // push that announces the group call) and hands us a FRESH
            // manager bound to the live WS each time. Returning the
            // existing controller WITHOUT rebinding left it wired to the
            // previous (dead/stale) manager: `join()` went out on the old
            // socket and the new manager's `group_call_update` — a late
            // joiner's only full-roster snapshot — fired into nil slots,
            // so an iPad answering a group invite after any background
            // reconnect sat in the call UI with zero participants. No-op
            // when the manager instance is unchanged.
            existing.rebind(manager: manager)
            return existing
        }
        let controller = GroupCallController(manager: manager)
        // Attach the shared audio capture / playback so the
        // controller drives them in lockstep with call state.
        let capture = AudioCapture()
        let playback = AudioPlayback()
        controller.attachAudioPipeline(capture: capture, playback: playback)
        // W-GRPTELEM: group-call SFU A/V telemetry — QAudionEngine cannot
        // import QAudionApp, so this closure is the ONLY place
        // `call.media.connected`/`call.media.ended` (emitted by
        // `LiveKitGroupCallRoom`/`GroupCallController` respectively) get
        // routed into `CallMediaTelemetry.shared`, the SAME per-call
        // connected/heartbeat/summary tracker the 1:1 path uses (see that
        // class's kdoc) — reused here rather than duplicated because a
        // device is never in a 1:1 AND a group call at once, so the
        // singleton's one `currentCallId` slot is never actually contended
        // between the two paths. Everything else passes straight through
        // to `TelemetryService`, mirroring `videoTelemetry`'s wiring below.
        controller.groupTelemetry = { kind, callId, attrs in
            guard let cid = callId else {
                TelemetryService.shared.emit(kind: kind, attrs: attrs)
                return
            }
            switch kind {
            case "call.media.connected":
                // `CallMediaTelemetry` is `@MainActor`-isolated but this
                // closure is invoked off arbitrary threads (RoomDelegate's
                // own doc comment: "not guaranteed to be main") — hop
                // explicitly rather than calling it synchronously.
                let peerPrefix = (attrs["peer_prefix"] as? String) ?? "group"
                let sasSource = (attrs["sas_source"] as? String) ?? "sfu"
                Task { @MainActor in
                    CallMediaTelemetry.shared.recordConnected(callId: cid, peerPrefix: peerPrefix, sasSource: sasSource)
                }
            case "call.media.ended":
                let reason = (attrs["reason"] as? String) ?? "unknown"
                Task { @MainActor in
                    CallMediaTelemetry.shared.recordEnded(callId: cid, reason: reason)
                }
            default:
                TelemetryService.shared.emit(kind: kind, callId: cid, attrs: attrs)
            }
        }
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

    /// Phase 18 — the SINGLE shared `MessageRatchet` instance used for v4 routed
    /// dispatch on BOTH the send (``ChatMessageSendService``) and receive (this
    /// file) sides. Android serializes both directions through one `MessageRatchet`
    /// + `@Synchronized`; on iOS the v3.1 send/receive use two separate instances,
    /// which is safe there because each v3.1 direction is a SEPARATE chain key
    /// inside ONE serialized snapshot only when the same instance owns both — but
    /// the v4 routed methods persist the WHOLE opaque session blob per op, so a
    /// concurrent send and receive on DIFFERENT instances could last-writer-wins
    /// clobber each other's chain advance. Routing all v4 ops through this one
    /// shared instance restores Android's single-lock invariant (its
    /// `v4RoutingLock` then serializes both directions). Same Keychain-backed
    /// vault as ``ratchet`` so v3.1 and v4 share the device trust boundary.
    static let sharedV4Ratchet: MessageRatchet = MessageRatchet(vault: KeychainRatchetVault())

    /// GAP A2 (2026-07-15 group-video-call incident recon) — group-call
    /// KMS-prebootstrap fallback, mirroring Android's ADR-014a
    /// `KmsPreBootstrapSender` (`core-data/.../kms/KmsPreBootstrapSender.kt`,
    /// wired from `GroupCallController.kt::sendControlEnvelope` L865+ /
    /// commit tag W-GRPKMSPB). When a group-call peer has no contact-bound
    /// 1:1 PSK at all (never called/messaged before this call), this
    /// asynchronously bootstraps one from the peer's published
    /// identity-key bundle + a one-time prekey (X3DH-style, no prior
    /// interaction required) instead of silently failing to deliver
    /// `sender_key_init`/`sender_key_rotate`.
    ///
    /// **iOS status: REAL, not a stub** (2026-07-15, closes gap A2's iOS
    /// half). Ports `KmsPreBootstrap.encode`/`.decode`
    /// (`KmsPreBootstrap.swift`, byte-for-byte mirror of Android's
    /// `crypto/KmsPreBootstrap.kt`) + the canonical-CBOR envelope codec
    /// (`KmsPreBootstrapCbor.swift`, mirrors `KmsPreBootstrapCbor.kt`) +
    /// the bundle self-sig preimage (`IdentityKeyV2Preimage.swift`, mirrors
    /// `core-data/.../security/IdentityKeyV2Preimage.kt`). Verified against
    /// the shared cross-platform KAT fixture
    /// (`kms-prebootstrap-kat.json`, structural/ad_bytes fidelity — see
    /// `KmsPreBootstrapKatTests.swift`) plus a self-consistency
    /// encode-then-decode round-trip test, both CI-gated (no Swift
    /// toolchain on this dev box — see that test file's header).
    ///
    /// Flow (mirrors `KmsPreBootstrapSender.build` step-for-step):
    ///  1. Fetch the peer's v2 identity bundle
    ///     (`kmsClient.fetchUserIdentityBundleV2`) — bails (`nil`) on 404 /
    ///     no PQ leg (pre-v2 peer).
    ///  2. Verify the bundle's self-sig via `IdentityKeyV2Preimage.buildV2`
    ///     + Ed25519 verify against the bundle's OWN `ed25519Pub` — TOFU
    ///     accept when `selfSig` is absent (pre-Day-4c-server compat path,
    ///     kept intentionally, mirrors Android).
    ///  3. Fetch one peer one-time prekey (`kmsClient.fetchNextPrekey`) and
    ///     verify its per-prekey sig (Ed25519 over
    ///     `sha256(pq_pub‖x25519_pub‖be64(createdAtMs))`) against the
    ///     bundle's pinned Ed25519 key — falls through to the bundle's
    ///     long-term keys on ANY failure (204/404/sig-mismatch), per
    ///     ADR-014a §3.4.
    ///  4. `KmsPreBootstrap.encode(...)`, signing with THIS device's
    ///     sovereign Ed25519 identity (`SovereignIdentityManager`,
    ///     `.signingPrivate`) — the SAME key published via
    ///     `publishUserIdentityKey` (see `runKmsSweep`'s 2026-06-23
    ///     root-cause-fix comment for why it must be the sovereign key,
    ///     not `DeviceKeyManager`'s device key).
    ///  5. Install the resulting `RK_0` as a contact-bound PSK via
    ///     `SovereignKeyVault` under the exact `auto:<prefix8>:<peerId>`
    ///     name `resolveGroupCtrlPsk` reads, so THIS device's own next send
    ///     to `peer` (and its receive of the peer's first reply) routes
    ///     through the now-shared v1 ratchet.
    ///  6. Return the `{"qa_kms":1,"env_b64":...}` wrapper for the caller
    ///     to ship AS the `opaque_message` body verbatim — it is already
    ///     self-authenticating, so the caller must NOT additionally wrap it
    ///     in `qa_grpcall_ctrl`/`ratchet.encrypt` (mirrors Android's
    ///     `sendControlEnvelope` — see the `.noPsk` case in
    ///     `connectPersistentSocket`'s `onSendControlEnvelope` wiring).
    ///
    /// Known gap (NOT fixed here, out of this TODO's scope): iOS has no
    /// code path that PUBLISHES its own v2 identity bundle (`ik_pq_pub_b64`/
    /// `ik_x25519_pub_b64`/`self_sig_b64` via the dedicated v2 POST route —
    /// only Android does that today). Practically this means a REMOTE
    /// sender (Android/Desktop) trying to KMS-prebootstrap TO an iOS
    /// receiver will see "no PQ leg" and skip prebootstrap — the RECEIVE
    /// side below (`decodeKmsPreBootstrapEnvelope`) is implemented correctly
    /// and forward-compatible, but won't see real traffic until iOS also
    /// publishes a v2 bundle (separate follow-up, not requested here).
    /// iOS also has no local one-time-prekey pool of its own (mirrors
    /// Android's `OneTimePrekeyDao`) — `oneTimePrekeyLookup` on the decode
    /// side is therefore always-miss by construction, which is the
    /// correct fail-closed behaviour given iOS never published any OTPs.
    static func attemptGroupCtrlKmsPreBootstrap(
        peer: String, selfId: String, envelopeJson: String, kmsClient: BCryptoKmsClient
    ) async -> String? {
        guard let selfUuidRaw = try? KmsPreBootstrapCbor.uuidStringToRaw(selfId) else {
            print("[AppState] KmsPreBootstrap encode: selfId not a UUID (\(selfId.prefix(8))…)")
            return nil
        }
        guard let sovereign = SovereignIdentityManager().loadIdentity(),
              sovereign.signingPrivate.count == 32 else {
            print("[AppState] KmsPreBootstrap encode: no sovereign identity loaded yet")
            return nil
        }

        guard let bundle = await kmsClient.fetchUserIdentityBundleV2(userId: peer),
              bundle.pqPub.count == 1568, bundle.ed25519Pub.count == 32 else {
            // 404 / pre-v2 peer (no PQ leg) — caller falls back to the
            // existing default flow, exactly like Android's fallback.
            return nil
        }
        guard verifyPeerBundleSelfSig(bundle) else {
            print("[AppState] KmsPreBootstrap encode: peer bundle self-sig FAILED peer=\(peer.prefix(8))…")
            return nil
        }

        let otp = await fetchAndVerifyPrekey(peer: peer, peerEdPub: bundle.ed25519Pub, kmsClient: kmsClient)

        let receiverView = KmsPreBootstrap.ReceiverBundleView(
            uuidRaw: bundle.uuidRaw, ikEdPub: bundle.ed25519Pub,
            ikPqPub: bundle.pqPub, ikX25519Pub: bundle.x25519Pub
        )
        let otpView = otp.map {
            KmsPreBootstrap.ReceiverOneTimePrekeyView(prekeyId: $0.prekeyId, pqPub: $0.pqPub, x25519Pub: $0.x25519Pub)
        }
        let senderIdentity = KmsPreBootstrap.IdentityKeys(
            uuidRaw: selfUuidRaw, ikEdPub: sovereign.signingPublic, ikEdPriv: sovereign.signingPrivate,
            ikPqPub: Data(), ikPqPriv: nil, ikX25519Pub: nil, ikX25519Priv: nil
        )

        let result: KmsPreBootstrap.EncodeResult
        do {
            result = try KmsPreBootstrap.encode(
                sender: senderIdentity, receiverBundle: receiverView, oneTimePrekey: otpView,
                senderKeyInitPayload: Data(envelopeJson.utf8),
                nowMs: Int64((Date().timeIntervalSince1970 * 1000).rounded())
            )
        } catch {
            print("[AppState] KmsPreBootstrap.encode failed peer=\(peer.prefix(8))…: \(error)")
            return nil
        }

        // Phase 14a Day 4c parity — install our own outgoing PSK seeded by
        // the SAME RK_0 the receiver will derive, so the peer's first reply
        // (which will use this now-shared PSK) is decryptable on our side.
        installKmsPreBootstrapPsk(rk0: result.rk0, peer: peer)

        let wrapper: [String: Any] = [
            "qa_kms": 1,
            "env_b64": result.envelopeBytes.base64EncodedString(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Receive-side counterpart of `attemptGroupCtrlKmsPreBootstrap` — mirrors
    /// Android's `KmsPreBootstrapReceiver.consume` + `GroupCallController.
    /// onOpaqueMessage`'s `qa_kms` branch. Called from `dispatchInboundOpaque`'s
    /// Path D (checked BEFORE Path C's `qa_grpcall_ctrl`, since a
    /// KMS-prebootstrap envelope travels UNWRAPPED — no further 1:1-ratchet
    /// encryption, the envelope is already self-authenticating).
    ///
    /// Fetches the SENDER's (not receiver's) pinned Ed25519 key to verify the
    /// envelope's transcript signature — the receiver's own long-term
    /// ML-KEM/X25519 identity keys come from `DeviceKeyManager` (the only
    /// long-term PQ/X25519 keypair iOS has today; see the "known gap" note
    /// on the send-side sibling above for why this device's OWN v2 bundle
    /// currently has no real long-term ML-KEM/X25519 publish path).
    static func decodeKmsPreBootstrapEnvelope(
        envelopeBytes: Data, senderId: String, selfId: String, kmsClient: BCryptoKmsClient
    ) async -> String? {
        guard let senderEdPub = await kmsClient.fetchUserIdentityKey(userId: senderId),
              senderEdPub.count == 32 else {
            return nil
        }
        guard let selfUuidRaw = try? KmsPreBootstrapCbor.uuidStringToRaw(selfId) else { return nil }
        guard let sovereign = SovereignIdentityManager().loadIdentity() else { return nil }

        let vault = SovereignKeyVault()
        let deviceKeyManager = DeviceKeyManager(vault: vault, kmsClient: kmsClient)
        guard let deviceKeys = try? deviceKeyManager.currentKeys(),
              let mlkemPub = deviceKeys.mlkemPub, let mlkemPriv = deviceKeys.mlkemPriv,
              mlkemPub.count == 1568, mlkemPriv.count == 3168 else {
            print("[AppState] KmsPreBootstrap decode: device ML-KEM identity keys not provisioned yet")
            return nil
        }
        let x25519Pub = try? deviceKeyManager.currentX25519Pub()

        let receiverIdentity = KmsPreBootstrap.IdentityKeys(
            uuidRaw: selfUuidRaw, ikEdPub: sovereign.signingPublic, ikEdPriv: nil,
            ikPqPub: mlkemPub, ikPqPriv: mlkemPriv,
            ikX25519Pub: x25519Pub, ikX25519Priv: deviceKeys.x25519Priv
        )

        do {
            let (payload, rk0) = try KmsPreBootstrap.decode(
                envelopeBytes: envelopeBytes,
                receiver: receiverIdentity,
                // iOS has no local one-time-prekey pool yet (see the "known
                // gap" note above) — always miss, which correctly fails
                // closed if a sender ever did reference an OTP id we can't
                // possibly have.
                oneTimePrekeyLookup: { _ in nil },
                senderIkEdPub: senderEdPub,
                replayCache: Self.kmsPreBootstrapReplayCache,
                nowMs: Int64((Date().timeIntervalSince1970 * 1000).rounded())
            )
            installKmsPreBootstrapPsk(rk0: rk0, peer: senderId)
            return String(data: payload, encoding: .utf8)
        } catch {
            print("[AppState] KmsPreBootstrap.decode failed sender=\(senderId.prefix(8))…: \(error)")
            return nil
        }
    }

    /// Shared replay-window cache for the receive side — one process-wide
    /// instance (mirrors Android's `@Singleton KmsPreBootstrapReceiver`
    /// owning one `ReplayCache`), so a resend of the same envelope (e.g. a
    /// server redelivery) is caught regardless of which call/thread
    /// decodes it.
    private static let kmsPreBootstrapReplayCache = KmsPreBootstrapReplayCache()

    /// ADR-014a §2.5 step "bundle self-sig" — TOFU-accept when `selfSig` is
    /// absent (pre-Day-4c-server compat path, mirrors Android's
    /// `KmsPreBootstrapSender.parseAndVerifyIdentityKey`). When present, a
    /// bundle with no X25519 leg is a contradiction (only a v2 publish
    /// computes a self-sig, and v2 always carries the X25519 leg) — treated
    /// as verify-failure rather than guessed at.
    private static func verifyPeerBundleSelfSig(_ bundle: BCryptoKmsClient.IdentityBundleV2) -> Bool {
        guard let sig = bundle.selfSig, !sig.isEmpty else { return true }
        guard sig.count == 64, let xPub = bundle.x25519Pub, xPub.count == 32 else { return false }
        guard let preimage = try? IdentityKeyV2Preimage.buildV2(
            uuidRaw: bundle.uuidRaw, ed25519Pub: bundle.ed25519Pub,
            ikPqPub: bundle.pqPub, ikX25519Pub: xPub, createdAtMs: bundle.createdAtMs
        ) else { return false }
        guard let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: bundle.ed25519Pub) else {
            return false
        }
        return verifier.isValidSignature(sig, for: preimage)
    }

    /// ADR-014a §4.1 — verify a fetched one-time prekey's per-prekey sig
    /// (`Ed25519(peerEdPub, sha256(pq_pub‖x25519_pub‖be64(createdAtMs)))`)
    /// against the peer's PINNED bundle key. Falls through to `nil` (long-
    /// term keys) on 204/404/transport error/sig-mismatch, mirrors
    /// Android's `KmsPreBootstrapSender.fetchAndVerifyPrekey`.
    private static func fetchAndVerifyPrekey(
        peer: String, peerEdPub: Data, kmsClient: BCryptoKmsClient
    ) async -> BCryptoKmsClient.OneTimePrekeyDTO? {
        guard let dto = await kmsClient.fetchNextPrekey(userId: peer),
              dto.pqPub.count == 1568, dto.x25519Pub.count == 32, dto.sig.count == 64 else {
            return nil
        }
        var tsBe = dto.createdAtMs.bigEndian
        var digestInput = Data()
        digestInput.append(dto.pqPub)
        digestInput.append(dto.x25519Pub)
        digestInput.append(withUnsafeBytes(of: &tsBe) { Data($0) })
        let digest = Data(SHA256.hash(data: digestInput))
        guard let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: peerEdPub),
              verifier.isValidSignature(dto.sig, for: digest) else {
            print("[AppState] KmsPreBootstrap: prekey sig FAIL peer=\(peer.prefix(8))… prekeyId=\(dto.prekeyId)")
            return nil
        }
        return dto
    }

    /// Phase 14a Day 4c parity — install the freshly-derived `RK_0` as a
    /// contact-bound PSK under the EXACT `auto:<prefix8>:<peerId>` name
    /// `resolveGroupCtrlPsk` reads (see that function below), on BOTH the
    /// sender side (so our own next send routes through it) and the
    /// receiver side (so subsequent control envelopes from this peer use
    /// the now-shared v1 ratchet instead of re-bootstrapping every time).
    /// iOS's `SovereignKeyVault` has no ratchet-version field to set
    /// (confirmed this session — unlike Android's `setRatchetVersion`),
    /// so storing the raw 32-byte key is the whole job here.
    private static func installKmsPreBootstrapPsk(rk0: Data, peer: String) {
        let vault = SovereignKeyVault()
        let prefix = peer.count > 8 ? String(peer.prefix(8)) : peer
        let name = "auto:\(prefix):\(peer)"
        let fingerprint = String(Data(SHA256.hash(data: rk0)).map { String(format: "%02x", $0) }.joined().prefix(16))
        do {
            try vault.storePsk(name: name, key: rk0, fingerprint: fingerprint)
            print("[AppState] KmsPreBootstrap: installed RK_0 PSK peer=\(peer.prefix(8))… name=\(name)")
        } catch {
            print("[AppState] KmsPreBootstrap: installRatchetSeed failed peer=\(peer.prefix(8))…: \(error)")
        }
    }

    /// W-GRPSENDERKEY (2026-07-13): PSK lookup ladder for the group-call
    /// `qa_grpcall_ctrl` control channel — same `auto:<prefix>:<peerId>`
    /// then bare-`peerId` convention already duplicated inline in
    /// `handleIncomingMessage`/`ChatMessageSendService`. Factored out here
    /// (not touching those existing call sites) so the group-call path
    /// shares the identical resolution without a 3rd/4th inline copy.
    static func resolveGroupCtrlPsk(peer: String) -> Data? {
        return resolveGroupCtrlPskNamed(peer: peer)?.psk
    }

    /// W-GRPCTRL-PARITY (2026-07-20): same ladder as ``resolveGroupCtrlPsk``
    /// but ALSO returns the vault NAME the PSK was found under. On the
    /// group-ctrl channel the name IS the wire epoch tag (Desktop
    /// `vault.forContactWithMeta().name` / Android
    /// `findNewestForContact().name` — both platforms derive the sealed
    /// wire's epoch from it), so the receiver can look the key up by name,
    /// or fall back to its own contact-bound ladder when the name is
    /// sender-local (as `auto:<peerPrefix>:<peerId>` names are — each side
    /// names the SHARED key after its own peer).
    static func resolveGroupCtrlPskNamed(peer: String) -> (name: String, psk: Data)? {
        let vault = SovereignKeyVault()
        let prefix = peer.count > 8 ? String(peer.prefix(8)) : peer
        let autoName = "auto:\(prefix):\(peer)"
        if let stored = (try? vault.loadPsk(name: autoName)) ?? nil, !stored.isEmpty {
            return (autoName, stored)
        }
        if let stored = (try? vault.loadPsk(name: peer)) ?? nil, !stored.isEmpty {
            return (peer, stored)
        }
        return nil
    }

    /// W-GRPCTRL-PARITY (2026-07-20): receive-side PSK resolution for an
    /// epoch tag parsed FROM a v3/v2 group-ctrl wire — mirror of Desktop's
    /// `forContactByName(sender, call-…) ?? forContactByName(sender, tag) ??
    /// forContactWithMeta(sender)` and Android `decryptV3`/`decryptV2`'s
    /// `findByNameForContact("call-$tag") ?? findByNameForContact(tag)` (+
    /// v2's try-all fallback). Exact-name hits cover symmetric names
    /// (KMS-delivered keyIds, call-derived `call-*`); the contact-bound
    /// ladder covers sender-local names (`auto:*`, bare peerId) and legacy
    /// 'v1'-epoch wires — a wrong PSK just fails the AEAD, never a
    /// downgrade.
    static func lookupGroupCtrlPskByEpoch(epochTag: String, sender: String) -> Data? {
        let vault = SovereignKeyVault()
        let targetName = epochTag.hasPrefix("call-") ? epochTag : "call-\(epochTag)"
        for name in [targetName, epochTag] {
            if let stored = (try? vault.loadPsk(name: name)) ?? nil, !stored.isEmpty {
                return stored
            }
        }
        return resolveGroupCtrlPsk(peer: sender)
    }

    /// W-GRPCTRLPSKSWEEP (2026-07-28) — every PSK worth TRYING for a
    /// `qa_grpcall_ctrl` envelope, best guess first, mirroring Android's
    /// `MessageCrypto.tryAllPsks` fallthrough.
    ///
    /// [lookupGroupCtrlPskByEpoch] returns a single best guess, and both call
    /// sites used to attempt exactly ONE decrypt with it. That is three
    /// candidates in total (`call-<tag>`, `<tag>`, one contact-bound key), and
    /// Desktop matches none of them: it seals with
    /// `vault.forContactWithMeta(peer)` and puts THAT key's own name on the
    /// wire as the epoch tag (live value observed: `9d8f98fe`). So iOS never
    /// installed Desktop's sender key even once. Server-side corpus over three
    /// days: `ctrl envelope RECEIVED+decrypted sender=81ad802f` = 0 against
    /// `RECEIVE FAILED sender=81ad802f` = 41. In a live call Desktop's audio
    /// then arrived ~100% concealed (in_concealed_samples 13 200 -> 213 840 in
    /// ~5 s) and its video never rendered, while Android's tracks in the SAME
    /// call were fine — exactly the asymmetry reported as "on iOS I don't see
    /// Desktop, the others do".
    ///
    /// Trying rather than guessing is safe and bounded: AEAD authenticates, so
    /// a wrong key fails the tag and can never yield a forged plaintext; the
    /// extra work is at most one open() per stored PSK and is paid ONLY when
    /// the targeted lookup already missed. Deduped so the common case still
    /// costs a single attempt.
    static func groupCtrlPskCandidates(epochTag: String, sender: String) -> [Data] {
        let vault = SovereignKeyVault()
        var out: [Data] = []
        var seen = Set<Data>()
        func add(_ d: Data?) {
            guard let d, !d.isEmpty, !seen.contains(d) else { return }
            seen.insert(d)
            out.append(d)
        }
        let targetName = epochTag.hasPrefix("call-") ? epochTag : "call-\(epochTag)"
        for name in [targetName, epochTag] {
            add((try? vault.loadPsk(name: name)) ?? nil)
        }
        add(resolveGroupCtrlPsk(peer: sender))
        for name in vault.listPskNames() {
            add((try? vault.loadPsk(name: name)) ?? nil)
        }
        return out
    }

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

    /// Phase 18 — decrypt a v4 native PQ-ratchet frame (opaque 0xE5). Routes by
    /// PEER id (`senderId`) only through the engine-encapsulated
    /// ``MessageRatchet/decryptV4Routed(peerId:frame:)`` on the SHARED v4 instance.
    /// The frame is NEVER parsed here. Returns `nil` (fail-closed) when the v4 path
    /// is disabled, no v4 session exists for this peer, or auth/replay/parse fails —
    /// the caller surfaces that as a decrypt failure (NEVER a downgrade).
    ///
    /// NOTE: unlike v3.1, there is NO `psk`/`ensureSession` lazy bootstrap here —
    /// a v4 session must already have been bootstrapped + persisted by the
    /// handshake (it carries identity pubkeys + transcript hash the message PSK
    /// alone cannot supply). No session ⇒ fail closed.
    func ratchetDecryptV4(wire: Data, senderId: String) -> Data? {
        return Self.sharedV4Ratchet.decryptV4Routed(peerId: senderId, frame: wire)
    }
}

/// Phase 18 — fail-closed sentinel thrown when an inbound 0xE5 v4 frame cannot be
/// routed/decrypted (v4 disabled, no per-peer session, or auth failure). Kept
/// distinct from `MessageWireFormat.WireError` so the surrounding catch treats it
/// as a hard decrypt failure and never falls through to a weaker version.
enum RatchetV4DispatchError: Error {
    case unroutableOrFailedClosed
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
        print("[AppState] W-VIDDIAG handleIncomingWebRtcOffer: caller=\(callerId.prefix(8)) sdpLen=\(sdp.count) hasVideo=\(hasVideo) — building WebRTC controller")
        guard let provider = liveProvider else {
            print("[AppState] W-VIDDIAG handleIncomingWebRtcOffer: liveProvider nil — NO controller built")
            return
        }
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
        // WIRE_SPEC §8.7 — publication rides the RX render gate (parked
        // until the receiver cryptor is ready, 2s failsafe).
        controller.onRemoteVideoTrack = { [weak self] track in
            Task { @MainActor [weak self] in
                self?.publishRemoteVideoTrackGated(track)
            }
        }
        // WIRE_SPEC §8.7 — receiver readiness → call_media_ready (dedup
        // per call+mid inside sendCallMediaReadyOnce; responder side).
        controller.onInboundVideoReady = { [weak self] mid in
            Task { @MainActor [weak self] in
                self?.sendCallMediaReadyOnce(mid: mid)
            }
        }
        // WIRE_SPEC §8.7 (INT-4a) — receiver decode stall → nudge the sender.
        controller.onVideoStallDetected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestKeyframeFromSender()
            }
        }
        // Remote-readable video diagnostics (responder side, mirrors caller).
        controller.videoTelemetry = { [weak self] kind, attrs in
            TelemetryService.shared.emit(kind: kind, attrs: attrs)
            // VIDEODIAG — feed the arrived/decoded counters off the
            // EXISTING 3s stats poll (thread-safe class; any thread).
            self?.videoDiag.noteVideoStats(kind: kind, attrs: attrs)
        }
        // W-DCAUDIO — RX: inbound sealed-audio DataChannel frames → CallService
        // decrypt + playback (same path as the WS "audio_frame" handler).
        controller.onAudioDataChannelFrame = { [weak self] data in
            self?.callService.handleIncomingDataChannelAudio(data)
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
            case .failed:
                Task { @MainActor [weak self] in
                    self?.handleIceTermination(iceIsTerminal: true)
                }
            case .disconnected:
                // W-ICEGRACE — recoverable, not terminal (callee-side mirror
                // of the caller path above; both must behave identically or
                // the same call dies from whichever side answered).
                Task { @MainActor [weak self] in
                    self?.handleIceTermination(iceIsTerminal: false)
                }
            default:
                break
            }
        }
        controller.onIceConnectionState = { [weak self] iceState in
            switch iceState {
            case .failed, .closed:
                Task { @MainActor [weak self] in
                    self?.handleIceTermination(iceIsTerminal: true)
                }
            case .disconnected:
                // W-ICEGRACE — recoverable, not terminal.
                Task { @MainActor [weak self] in
                    self?.handleIceTermination(iceIsTerminal: false)
                }
            case .connected, .completed:
                let isRelayForced = TransportGate.forcesRelay
                Task { @MainActor [weak self] in
                    // W-ICEGRACE — ICE recovered: stand down the countdown.
                    self?.cancelIceDisconnectGrace()
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
