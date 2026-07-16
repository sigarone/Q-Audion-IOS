import SwiftUI
import QAudionEngine
import MediaPlayer   // MPVolumeView — keeps AVAudioSession KVO alive

// MARK: - Shake-to-report (W559 enhancement)
// iOS delivers shake gestures via UIResponder.motionBegan. SwiftUI apps
// have no UIViewController so we inject a hidden UIViewControllerRepresentable
// that becomes first responder and forwards the motion to BugReporter.
struct ShakeDetectorView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ShakeViewController { ShakeViewController() }
    func updateUIViewController(_ vc: ShakeViewController, context: Context) {}
    class ShakeViewController: UIViewController {
        override var canBecomeFirstResponder: Bool { true }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated); becomeFirstResponder()
        }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake else { return }
            Task { @MainActor in BugReporter.shared.triggerManualPublic() }
        }
    }
}

// MARK: - MPVolumeView keepalive (W559 enhancement)
// Keeping an MPVolumeView allocated — even with zero frame, not in the view
// hierarchy visually — is enough to make iOS route AVAudioSession.outputVolume
// KVO notifications to the app while it's in foreground. Without it,
// AVAudioSession is inactive (no audio session category set), and
// UIKit only changes the RINGER volume silently, never firing the KVO.
struct HiddenMPVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView()
        v.isHidden = true      // not visible; the mere allocation activates KVO
        v.alpha = 0.001        // belt-and-suspenders for SwiftUI layout passes
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    /// Tracks whether the SplashScreen has resolved. Mirrors Android's
    /// `SplashViewModel.state: Loading | GoHome | GoOnboarding`.
    @State private var splashResolved: Bool = false

    /// W34: Global snackbar host. Available to any descendant view via
    /// `@Environment(\.qaudionSnackbar)`. Callers push messages via
    /// `host.show(QAudionSnackbarMessage(...))`. Auto-dismisses after the
    /// configured duration, or on tap of the trailing close icon /
    /// action label. Renders as the topmost overlay so it floats above
    /// every screen + every sheet inside the same NavigationStack.
    @StateObject private var snackbarHost = QAudionSnackbarHostState()

    /// W400 — pending group invite from a NotificationCenter post.
    /// When non-nil, the sheet pops up. Set/cleared by the observer.
    @State private var pendingGroupInvite: PendingGroupInvite?

    // Outgoing-call display name resolved from ContactsStore.
    // Cached here so OutgoingCallScreen doesn't re-query on every
    // TimelineView tick. Updated whenever callContactId changes.
    @State private var outgoingDisplayName: String = ""
    @State private var outgoingShortNumber: String? = nil
    private let contactsStore = ContactsStore()

    var body: some View {
        ZStack(alignment: .top) {
            mainStack
            QAudionSnackbarHost(state: snackbarHost)
            // W559 — bug report overlay (volume-gesture or auto-trigger).
            BugReportOverlay()
            // W559 enhancement — shake-to-report: hidden ShakeDetectorView
            // stays first responder and fires BugReporter.triggerManualPublic()
            // on device shake. Works on ANY screen with no AVAudioSession
            // dependency. ZeroFrame so it has no visual impact.
            ShakeDetectorView().frame(width: 0, height: 0)
            // W559 enhancement — MPVolumeView keepalive: a zero-frame hidden
            // MPVolumeView activates the AVAudioSession KVO path that
            // BugReporter's volume observer reads. Without this the KVO
            // notification is only emitted while an active audio session
            // exists (i.e. during a call); on all other screens the volume
            // buttons change the ringer but never fire the KVO → the
            // up-then-down gesture is silently swallowed. MPVolumeView is
            // the documented Apple workaround (used by e.g. Shazam,
            // WhatsApp) for observing outputVolume app-wide.
            HiddenMPVolumeView().frame(width: 0, height: 0)
        }
        // W559 — show a non-intrusive snackbar when an auto report fires.
        .onReceive(NotificationCenter.default.publisher(for: BugReporter.autoReportNotification)) { note in
            let tag = note.userInfo?["tag"] as? String ?? "unknown"
            let msg = "Report automatico inviato (tag: " + tag + ")"
            snackbarHost.show(.init(text: msg, severity: .info, durationSeconds: 2))
        }
        // W400: subscribe to inbound group invites so the user gets a
        // sheet immediately. Posts come from
        // AppState.handleInboundGroupInvite (qa_grp:1, t:"group_invite"
        // arriving via 1:1 ratchet).
        .onReceive(NotificationCenter.default.publisher(for: AppState.groupInviteReceivedNotification)) { note in
            guard let info = note.userInfo,
                  let gid = info["groupId"] as? String,
                  let name = info["groupName"] as? String,
                  let members = info["members"] as? [String],
                  let admins = info["admins"] as? [String],
                  let from = info["from"] as? String else {
                return
            }
            pendingGroupInvite = PendingGroupInvite(
                id: gid, name: name, members: members,
                admins: admins, fromAdmin: from)
        }
        .sheet(item: $pendingGroupInvite) { invite in
            GroupInviteSheet(
                groupId: invite.id,
                groupName: invite.name,
                members: invite.members,
                admins: invite.admins,
                fromAdmin: invite.fromAdmin)
                .environmentObject(appState)
        }
        // W-GRPUI / W-GRPRING: the single group-call surface.
        //
        //   • `incomingGroupCallInvite != nil`  → RING (accept/reject). Fed by
        //     BOTH the live WS `group_call_invite` and the `incoming_group_call`
        //     push, deduped by call_id in AppState. Previously an invite
        //     auto-joined the callee silently — no ring, no accept, no reject.
        //   • `groupCallControllerState != .idle` → the LIVE call. Covers the
        //     creator (createCall → .connecting) and the invitee once they
        //     ACCEPT (→ GroupCallController.join → .connecting).
        //
        // One cover, two contents: the ring is up only while the controller is
        // still `.idle`, so the two states never overlap — accepting swaps the
        // content in place (ring → live call) with no second presentation.
        // Uses the SAME persistent `groupCallViewModel` built once in
        // `connectPersistentSocket()` rather than a fresh one per presentation.
        .fullScreenCover(isPresented: Binding(
            get: {
                appState.incomingGroupCallInvite != nil
                    || appState.groupCallControllerState != .idle
            },
            set: { _ in }
        )) {
            if let invite = appState.incomingGroupCallInvite {
                incomingGroupCallScreen(invite)
            } else if let vm = appState.groupCallViewModel {
                // GroupSecuritySheet (unified call UI — group-call
                // adaptation) reads `appState.liveProvider` for its
                // per-member `PeerTrustEvaluator` lookups. Explicit
                // re-apply here mirrors the same defensive pattern already
                // used a few lines up for `GroupInviteSheet`.
                GroupCallView(viewModel: vm)
                    .environmentObject(appState)
            }
        }
        // W403: cross-platform auto-join — when a Desktop or Android
        // peer adds us to a group via `member_added` (without a
        // preceding iOS `group_invite` envelope), surface a snackbar
        // so the user has visibility. The auto-bootstrap already
        // happened in handleInboundMemberAdded; this is just UX.
        .onReceive(NotificationCenter.default.publisher(for: AppState.groupAutoJoinedNotification)) { note in
            guard let info = note.userInfo,
                  let gid = info["groupId"] as? String,
                  let from = info["fromAdmin"] as? String else { return }
            let shortFrom = from.count > 12 ? String(from.prefix(8)) + "…" : from
            let shortGid = String(gid.prefix(8)) + "…"
            snackbarHost.show(.init(
                text: "Aggiunto al gruppo \(shortGid) da \(shortFrom)",
                severity: .info,
                durationSeconds: 5
            ))
        }
        // W18.A: apply the Q-Audion design system at the very top so
        // every descendant view can read tokens via @Environment without
        // each having to re-apply the modifier.
        .qAudionTheme(dark: true)
        .environment(\.qaudionSnackbar, snackbarHost)
        .animation(.easeInOut, value: appState.isAuthenticated)
        .animation(.easeInOut, value: appState.isInCall)
        .animation(.easeInOut, value: appState.isVideoCall)
        .animation(.easeInOut, value: appState.callState)
        .animation(.easeInOut, value: splashResolved)
        // WIRE_SPEC §8.1 — animate the auto-fallback to the audio-only
        // call screen when both sides pause their camera.
        .animation(.easeInOut, value: appState.localVideoPaused)
        .animation(.easeInOut, value: appState.remoteVideoPaused)
        .onChange(of: appState.callContactId) { id in
            resolveOutgoingName(id)
        }
        .onAppear {
            resolveOutgoingName(appState.callContactId)
        }
        // W37: bridge globale del deepfake detector. Quando AppState
        // alza il flag (DeepfakeMonitor → confidenceLevel == "red"
        // sustained), pushiamo una snackbar error visibile su qualsiasi
        // schermo. Il pattern Android è "color-only inline durante la
        // chiamata" — ma l'iOS ha l'esigenza extra di notificare anche
        // se l'utente ha messo l'app in background o aperto un altro
        // tab. La snackbar svanisce dopo 6s; il detector continua a
        // pulsare l'avatar halo via confidenceColor in parallelo.
        .onChange(of: appState.deepfakeAlert) { isAlert in
            guard isAlert else { return }
            // Mostra l'opzione "Termina chiamata" solo se siamo
            // effettivamente in chiamata; altrimenti il bottone non
            // avrebbe senso.
            let inCall = appState.isInCall
            snackbarHost.show(.init(
                text: "Voce sospetta rilevata. Controlla l'identità del peer.",
                severity: .error,
                actionLabel: inCall ? "Termina chiamata" : nil,
                onAction: inCall ? { appState.endCall() } : nil,
                durationSeconds: 6
            ))
        }
    }

    /// W-GRPRING — the incoming-GROUP-call ring. Reuses the 1:1
    /// `IncomingCallScreen` (same ringing design: dual halo + avatar + identity
    /// + accept/reject), with the quick-reply button hidden (no 1:1 chat to
    /// reply into) and a group-specific subtitle. The ringtone is driven by
    /// AppState (`startInAppRingtone`), exactly as for a 1:1 call.
    ///
    /// Reject deliberately sends NOTHING on the wire: the server has no
    /// `group_call_decline` type and the room must stay open for the other
    /// invitees — we simply never send `group_call_join`.
    private func incomingGroupCallScreen(
        _ invite: AppState.IncomingGroupCallInvite
    ) -> some View {
        IncomingCallScreen(
            peerDisplayName: invite.displayTitle,
            avatarUrl: groupAvatarUrl(forGroupId: invite.groupId),
            callType: invite.hasVideo ? .video : .audio,
            subtitle: Self.groupCallSubtitle(invite),
            showReplyAction: false,
            onAccept: { appState.answerIncomingGroupCall() },
            onReject: { appState.declineIncomingGroupCall() }
        )
    }

    /// GAP FIX — group-call "room identity" avatar. `invite.groupId` is
    /// the server's dashed-UUID wire form; `GroupRegistry` keys on the
    /// dash-stripped hex (same conversion as `AppState.hexToDashedUUID`'s
    /// inverse, used elsewhere e.g. `ChatListScreen.hexToUUID`). Empty
    /// `groupId` (ad-hoc call, no real group) or no avatar set both
    /// resolve to nil → `IncomingCallScreen` falls back to its initials
    /// placeholder, same as before this fix.
    private func groupAvatarUrl(forGroupId groupId: String) -> URL? {
        guard !groupId.isEmpty else { return nil }
        let hex = groupId.replacingOccurrences(of: "-", with: "").lowercased()
        guard let avatarRef = GroupRegistry.shared.entry(for: hex)?.avatarRef else { return nil }
        return URL(string: "\(appState.serverUrl)/api/v1/files/\(avatarRef)")
    }

    /// "Chiamata di gruppo · <chi ha chiamato>" (video variant included).
    /// Static so it has its own clean type-check scope (CLAUDE.md §13).
    private static func groupCallSubtitle(
        _ invite: AppState.IncomingGroupCallInvite
    ) -> String {
        let kind = invite.hasVideo ? "Videochiamata di gruppo" : "Chiamata di gruppo"
        let creator = invite.creatorName.trimmingCharacters(in: .whitespaces)
        if creator.isEmpty || creator == invite.displayTitle { return kind }
        return kind + " · " + creator
    }

    @ViewBuilder
    private var mainStack: some View {
        if appState.isInCall {
            inCallStack
        } else if !splashResolved {
            // W18.C: brand splash on cold start. Resolves itself
            // after the 400ms minimum window and toggles
            // `splashResolved` so the conditional below picks the
            // right destination (HomeView if a session is already
            // alive, else OnboardingRoot).
            SplashScreen(
                onGoHome:       { splashResolved = true },
                onGoOnboarding: { splashResolved = true }
            )
        } else if appState.isAuthenticated {
            HomeView()
        } else {
            // Wave 17: replaced the old `LoginView` (which exposed a
            // free-text Server URL with the placeholder
            // `bcrypto.example.com` and a generic username/password
            // form) with `OnboardingRoot` — a 1:1 visual + behavioural
            // port of the Android canonical Welcome → FastSetup flow
            // (`qaudion-android-new/feature/feature-auth/`). The
            // server URL is now pinned to `PinnedServerHost.url`
            // (`https://voip.bcrypto.com`) so a malicious or stale
            // QR cannot redirect the phone to a different origin.
            OnboardingRoot()
        }
    }

    /// Routes among the three in-call surfaces based on `callState`.
    /// - `.connecting` / `.ringing` → OutgoingCallScreen (no audio yet)
    /// - `.active` / `.encrypted` + video → VideoCallView
    /// - `.active` / `.encrypted` + audio → LiveInCallScreen
    /// - anything else (e.g. `.ended` during teardown) → OutgoingCallScreen
    ///
    /// W534 — also route to `VideoCallView` when the peer has announced
    /// a screen-share via `SCREEN_SHARE:start` on an otherwise
    /// audio-only call. The pre-allocated `m=video` transceiver is
    /// already negotiated; the announce just tells the UI to mount the
    /// remote video sink so the encrypted RTP frames actually render.
    /// See `apps/qaudion-desktop/docs/SCREEN_SHARE_PROTOCOL.md`.
    ///
    /// WIRE_SPEC §8.1 — when BOTH sides have paused their camera
    /// (`localVideoPaused && remoteVideoPaused`), fall back to
    /// `LiveInCallScreen` even though this is nominally a video call
    /// (`isVideoCall` stays true — the call TYPE hasn't changed, only
    /// what's currently rendered). Matches Android's existing
    /// both-paused → audio-screen behavior. Purely a UI-layer switch:
    /// the call session, PeerConnection and negotiated `m=video` line
    /// are all untouched — LiveInCallScreen already renders correctly
    /// with `hasVideo: true, cameraOn: false` (see its InCallScreen
    /// wiring), so this is a safe surface to fall back to.
    @ViewBuilder
    private var inCallStack: some View {
        let cs = appState.callState
        if cs == .active || cs == .encrypted {
            let bothCamerasPaused = appState.localVideoPaused && appState.remoteVideoPaused
            if (appState.isVideoCall || appState.peerScreenShareActive) && !bothCamerasPaused {
                VideoCallView()
            } else {
                LiveInCallScreen()
            }
        } else {
            makeOutgoingScreen()
        }
    }

    private func makeOutgoingScreen() -> OutgoingCallScreen {
        let cs = appState.callState
        let outState: OutgoingCallScreen.State = (cs == .connecting) ? .dialing : .handshaking
        let name: String = outgoingDisplayName.isEmpty
            ? (appState.callContactId ?? "…")
            : outgoingDisplayName
        return OutgoingCallScreen(
            peerDisplayName: name,
            state: outState,
            elapsedSeconds: Int(appState.callService.callDurationSeconds),
            peerShortNumber: outgoingShortNumber,
            onHangup: { appState.endCall() }
        )
    }

    private func resolveOutgoingName(_ contactId: String?) {
        guard let id = contactId else {
            outgoingDisplayName = ""
            outgoingShortNumber = nil
            return
        }
        let contacts = contactsStore.load()
        if let match = contacts.first(where: { $0.userId == id }) {
            outgoingDisplayName = match.displayName
            let tokens = match.displayName
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            if let numTok = tokens.first(where: { $0.allSatisfy({ $0.isNumber }) }) {
                outgoingShortNumber = String(numTok.prefix(3))
            } else {
                outgoingShortNumber = nil
            }
        } else {
            // Priority: incomingCallerName (resolved to "Int. 112" by
            // call_incoming handler for incoming calls) → truncated UUID.
            // Never show the full 36-char UUID on any call screen.
            let resolved = appState.incomingCallerName
            if !resolved.isEmpty {
                outgoingDisplayName = resolved
                let toks = resolved.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if let num = toks.first(where: { $0.allSatisfy({ $0.isNumber }) }) {
                    outgoingShortNumber = String(num.prefix(3))
                } else {
                    outgoingShortNumber = nil
                }
            } else if id.hasPrefix("user-") {
                outgoingDisplayName = String(id.dropFirst(5)).capitalized
                outgoingShortNumber = nil
            } else if id.count > 12 {
                outgoingDisplayName = String(id.prefix(8)) + "…" + String(id.suffix(4))
                outgoingShortNumber = nil
            } else {
                outgoingDisplayName = id
                outgoingShortNumber = nil
            }
        }
    }
}
