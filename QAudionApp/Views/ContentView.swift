import SwiftUI
import QAudionEngine

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
    @ViewBuilder
    private var inCallStack: some View {
        let cs = appState.callState
        if cs == .active || cs == .encrypted {
            if appState.isVideoCall {
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
            outgoingDisplayName = id.hasPrefix("user-")
                ? String(id.dropFirst(5)).capitalized
                : id
            outgoingShortNumber = nil
        }
    }
}
