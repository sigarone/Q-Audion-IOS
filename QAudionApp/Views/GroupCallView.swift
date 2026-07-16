import SwiftUI
import QAudionEngine

/// Group call screen with participant grid and controls.
/// Max 8 participants in 2-column layout with speaking indicators.
struct GroupCallView: View {
    @ObservedObject var viewModel: GroupCallViewModel
    @Environment(\.dismiss) private var dismiss

    // Unified call UI (group-call adaptation) — trust bar + security
    // sheet, 1:1 ported from `InCallScreen.trustBar`/`securitySheet` (see
    // that file's header comment for the full pattern, and
    // `GroupSecuritySheet.swift` for this screen's sheet). These design
    // tokens are ambient via `ContentView`'s root `.qAudionTheme` — no
    // need to reapply it here, same as every other sheet call site in
    // this codebase.
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type
    /// Security sheet presentation state — purely a "is the aggregating
    /// sheet open" UI flag, nothing security-critical is gated by it
    /// (mirrors `InCallScreen.showSecuritySheet` exactly).
    @State private var showSecuritySheet = false

    /// In-call chat + attachments panel — same "icon toggle -> dismissible
    /// sheet" mechanism as `showSecuritySheet` above, reused verbatim for a
    /// new "chat" icon in the control row (see `GroupCallChatPanel.swift`).
    @State private var showChatPanel = false
    /// Badge shown on the chat toggle icon while the panel is CLOSED,
    /// mirroring the existing group-chat-list unread badge
    /// (`GroupMessageStore.unreadCount(forGroupHex:)` — see
    /// `ChatListScreen`'s identical `Capsule`-badge use of that same call).
    /// Refreshed on appear and on every `GroupMessageStore.didChangeNotification`
    /// for this call's group; cleared to 0 whenever the panel is open (the
    /// panel itself calls `GroupMessageStore.shared.markRead`, same as
    /// `GroupChatScreen.onAppear`/`reloadMessagesFromStore`).
    @State private var chatUnreadCount = 0

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chiamata di gruppo")
                            .font(.headline).foregroundColor(.white)
                        Text("\(viewModel.participants.count) partecipanti")
                            .font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                    if viewModel.callState == .active {
                        Text(viewModel.elapsedTime)
                            .font(.caption).monospacedDigit()
                            .foregroundColor(Color(red: 0, green: 0.9, blue: 0.47))
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

                // Unified call UI (group-call adaptation) — always-visible
                // chip row + shield button, matching the 1:1 screen's
                // `trustBar` position (right below the header, above the
                // main content) so it never steals space from the
                // participant grid.
                groupTrustBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                // W-GRPSCREENSHARE: spotlight tile for whichever remote
                // participant is currently sharing their screen — rendered
                // full-width, ABOVE the regular participant grid, so a
                // shared screen reads with visual priority over the small
                // per-participant tiles (mirrors the common Meet/Zoom
                // pattern: shared content dominates, faces stay small).
                // Simple, documented policy (no Android UI reference existed
                // yet to mirror at the time this was written — see this
                // file's own header for the recon note): if more than one
                // participant is somehow sharing at once, this shows
                // whichever one appears FIRST in `participants` — the
                // control bar toggle only ever lets ONE local share exist at
                // a time, and the server-side call model doesn't otherwise
                // arbitrate concurrent shares, so ties are not expected in
                // practice.
                if let sharer = viewModel.participants.first(where: { $0.screenShareTrack != nil }),
                   let screenTrack = sharer.screenShareTrack {
                    VStack(alignment: .leading, spacing: 6) {
                        GroupCallVideoView(track: screenTrack)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                HStack(spacing: 4) {
                                    Image(systemName: "rectangle.on.rectangle")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("Schermo di \(sharer.displayName)")
                                        .font(.caption2).fontWeight(.semibold)
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .padding(8)
                            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                // Participant grid
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ], spacing: 12) {
                        ForEach(viewModel.participants) { participant in
                            ParticipantTile(participant: participant)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Spacer()

                // Control bar
                HStack(spacing: 32) {
                    // Mute button
                    Button {
                        viewModel.toggleMute()
                    } label: {
                        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(viewModel.isMuted ? Color.red.opacity(0.3) : Color.white.opacity(0.15))
                            .clipShape(Circle())
                    }

                    // W-GRPVIDEO: camera on/off. Only shown once the call is
                    // actually riding the LiveKit SFU (isUsingSfu) — the
                    // WS-relay mesh fallback path has no video pipeline, so
                    // there is nothing to toggle. Works whether the call
                    // started as audio or video: publishing a fresh camera
                    // track mid-call is a supported LiveKit path (see
                    // GroupCallController.setVideoEnabled kdoc).
                    if viewModel.isSfuActive {
                        Button {
                            viewModel.toggleVideo()
                        } label: {
                            Image(systemName: viewModel.isVideoEnabled ? "video.fill" : "video.slash.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(viewModel.isVideoEnabled ? Color.white.opacity(0.15) : Color.red.opacity(0.3))
                                .clipShape(Circle())
                        }
                    }

                    // W-GRPSCREENSHARE: screen-share on/off. Same SFU-only
                    // gating as the camera toggle above — screen share, like
                    // camera, only exists over the LiveKit SFU transport.
                    // Tapping this calls straight into `GroupCallController.
                    // setScreenShareEnabled`, which itself calls LiveKit's
                    // own `LocalParticipant.setScreenShare(enabled:)` — that
                    // SDK call is what shows the SYSTEM broadcast picker
                    // (`RPSystemBroadcastPickerView`, via `BroadcastManager.
                    // shared.requestActivation()`) when starting; there is no
                    // custom in-app permission flow to build here (see
                    // `LiveKitGroupCallRoom.setScreenShareEnabled`'s kdoc for
                    // the verified source trail).
                    if viewModel.isSfuActive {
                        Button {
                            viewModel.toggleScreenShare()
                        } label: {
                            Image(systemName: viewModel.isScreenSharing
                                  ? "rectangle.on.rectangle.circle.fill"
                                  : "rectangle.on.rectangle")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 56, height: 56)
                                .background(viewModel.isScreenSharing ? Color.blue.opacity(0.35) : Color.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel(viewModel.isScreenSharing ? "Interrompi condivisione schermo" : "Condividi schermo")
                    }

                    // In-call chat + attachments panel toggle — same
                    // icon-toggle -> dismissible-sheet mechanism as the
                    // security shield button in `groupTrustBar` above,
                    // reused here per the control-row placement this
                    // feature was specced against (rather than the trust
                    // bar, which is reserved for always-visible crypto
                    // chips). Disabled placement decision: kept enabled
                    // even for an ad-hoc call with no persisted group —
                    // `GroupCallChatPanel` itself renders the "unavailable"
                    // explanation in that case rather than hiding the
                    // entry point (so the user isn't left wondering why a
                    // control silently vanished).
                    Button {
                        showChatPanel = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.white.opacity(0.15))
                            .clipShape(Circle())
                            .overlay(alignment: .topTrailing) {
                                if chatUnreadCount > 0 {
                                    Text(chatUnreadCount > 99 ? "99+" : "\(chatUnreadCount)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.red))
                                        .offset(x: 6, y: -4)
                                }
                            }
                    }
                    .accessibilityLabel("Chat di gruppo")

                    // End call button
                    Button {
                        viewModel.endCall()
                        dismiss()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 40)
            }

            // W-GRPVIDEO: self-preview PiP, bottom-trailing — mirrors the
            // 1:1 VideoCallView's localPreview placement. Only shown while
            // our own camera track is actually publishing.
            if let selfTrack = viewModel.selfVideoTrack {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        GroupCallVideoView(track: selfTrack)
                            .frame(width: 90, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
                            .padding(.trailing, 16)
                            .padding(.bottom, 120)
                    }
                }
            }
        }
        // Unified call UI (group-call adaptation) — same aggregating
        // security sheet pattern as `InCallScreen.securitySheet`: system
        // sheet (native drag-to-dismiss), not a custom overlay.
        .sheet(isPresented: $showSecuritySheet) {
            GroupSecuritySheet(
                participants: viewModel.participants,
                epoch: viewModel.currentEpoch,
                onDismiss: { showSecuritySheet = false }
            )
        }
        // In-call chat + attachments panel — same system-sheet mechanism as
        // the security sheet above (native drag-to-dismiss, never a custom
        // overlay that could get stuck covering the video).
        .sheet(isPresented: $showChatPanel) {
            GroupCallChatPanel(
                groupIdDashed: viewModel.activeGroupId,
                onDismiss: { showChatPanel = false }
            )
            .onDisappear { refreshChatUnreadCount() }
        }
        .onAppear { refreshChatUnreadCount() }
        // Defensive: `activeGroupId` is normally already bound by the time
        // this view appears (both AppState bind sites run synchronously
        // before the call surface presents — see `GroupCallViewModel.
        // activeGroupId`'s kdoc), but re-checking on every change costs
        // nothing and guards against any future reordering.
        .onChange(of: viewModel.activeGroupId) { _ in refreshChatUnreadCount() }
        // Badge upkeep — mirrors `ChatListScreen`'s reactive unread badge,
        // driven off the SAME `GroupMessageStore.didChangeNotification` the
        // list screen and `GroupChatScreen` both already observe. Fires
        // regardless of which screen is on top (the receive path in
        // AppState is view-independent — see `GroupCallChatPanel`'s header
        // comment) so a message that arrives while this call is on screen
        // but the panel is closed still bumps the badge live.
        .onReceive(NotificationCenter.default.publisher(
            for: GroupMessageStore.didChangeNotification)) { note in
            guard (note.userInfo?["groupHex"] as? String) == viewModel.activeGroupHex else { return }
            refreshChatUnreadCount()
        }
    }

    /// While the panel is open it owns read-marking itself (mirrors
    /// `GroupChatScreen.reloadMessagesFromStore`'s `markRead` call), so the
    /// toggle badge stays at 0 during that time rather than racing the
    /// panel's own reload.
    private func refreshChatUnreadCount() {
        guard !viewModel.activeGroupHex.isEmpty else { chatUnreadCount = 0; return }
        chatUnreadCount = showChatPanel ? 0
            : GroupMessageStore.shared.unreadCount(forGroupHex: viewModel.activeGroupHex)
    }

    /// Unified call UI (group-call adaptation) — same "chip row ending in
    /// a shield button" shape as `InCallScreen.trustBar` (see that file's
    /// header comment for the full 1:1 pattern). Always visible, never
    /// covers the participant grid; tapping the shield opens
    /// `GroupSecuritySheet`. Chips shown are group-call constants (every
    /// group call bootstraps via ML-KEM-1024 and rides the AES-256-GCM
    /// LiveKit media path — see `GroupSecuritySheet.overviewBody` for the
    /// full, sourced detail) rather than per-call conditionals like the
    /// 1:1 bar's `sasVerified`/`pqcActive` (group calls have no in-call
    /// SAS ceremony of their own).
    private var groupTrustBar: some View {
        HStack(spacing: 7) {
            groupTrustChip(icon: "lock.shield.fill", label: "PQC", color: extras.pqcAccent)
            groupTrustChip(icon: nil, label: "AES-256", color: scheme.onSurfaceVariant)
            Spacer(minLength: 0)
            Button {
                showSecuritySheet = true
            } label: {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(extras.pqcAccent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(scheme.surfaceVariant)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apri sicurezza chiamata di gruppo")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(scheme.surfaceVariant.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(scheme.outline.opacity(0.5), lineWidth: 1)
        )
    }

    /// Same small monospace chip `InCallScreen.trustChip` renders. Kept
    /// local (not extracted from that file into a shared component): the
    /// 1:1 screen's version is `private` to `InCallScreen` and nothing
    /// else needs this exact shape yet, so duplicating ~15 lines here
    /// avoids modifying the 1:1 screen for a cosmetic-only reuse.
    private func groupTrustChip(icon: String?, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(label)
                .qaudionStyle(type.labelSmall)
                .tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.4), lineWidth: 1)
        )
    }
}

struct ParticipantTile: View {
    let participant: GroupCallViewModel.ParticipantUI

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let track = participant.videoTrack {
                    GroupCallVideoView(track: track)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 64, height: 64)

                    Text(String(participant.displayName.prefix(1)).uppercased())
                        .font(.title).fontWeight(.semibold)
                        .foregroundColor(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: participant.videoTrack != nil ? 120 : 64)
            .overlay(
                RoundedRectangle(cornerRadius: participant.videoTrack != nil ? 12 : 32)
                    .stroke(participant.isSpeaking ? Color(red: 0, green: 0.9, blue: 0.47) : Color.clear, lineWidth: 3)
            )
            // W-GRPSCREENSHARE: small badge marking WHO is sharing, visible
            // even while looking at the regular grid (the big spotlight
            // tile above only shows the shared content itself, not whose
            // tile it came from at a glance while scrolling).
            .overlay(alignment: .bottomTrailing) {
                if participant.screenShareTrack != nil {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Circle().fill(Color.blue.opacity(0.85)))
                }
            }

            Text(participant.displayName)
                .font(.caption).foregroundColor(.white)
                .lineLimit(1)

            if participant.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.caption2).foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
    }
}

// MARK: - ViewModel

class GroupCallViewModel: ObservableObject {
    struct ParticipantUI: Identifiable {
        let id: String
        var displayName: String
        var isMuted: Bool = false
        var isSpeaking: Bool = false
        /// W-GRPVIDEO: type-erased `RemoteVideoTrack` (see
        /// `LiveKitGroupCallRoom`'s doc comment for why) — nil until the
        /// SFU subscribes this participant's camera; cleared again on
        /// participant departure. Rendered via `GroupCallVideoView`.
        var videoTrack: AnyObject? = nil
        /// W-GRPSCREENSHARE: type-erased `RemoteVideoTrack` for this
        /// participant's SCREEN-SHARE publication — kept SEPARATE from
        /// `videoTrack` (camera) since a participant can publish both at
        /// once (see `GroupCallController.onRemoteScreenShareTrack`'s
        /// kdoc). Nil until subscribed / after unsubscribe.
        var screenShareTrack: AnyObject? = nil
    }

    @Published var participants: [ParticipantUI] = []
    @Published var callState: BCryptoGroupCallManager.State = .idle
    @Published var isMuted = false
    @Published var elapsedTime = "0:00"
    /// W-GRPVIDEO: our own camera preview (type-erased `LocalVideoTrack`),
    /// nil when off.
    @Published var selfVideoTrack: AnyObject? = nil
    /// W-GRPVIDEO: mirrors whether OUR camera is currently publishing —
    /// seeded from the call's `callType` on the `.active` transition
    /// (`GroupCallController.wantsVideo`, surfaced via `callWantsVideo`),
    /// then flipped by `toggleVideo()`.
    @Published var isVideoEnabled = false
    /// W-GRPVIDEO: whether the call is riding the LiveKit SFU right now —
    /// gates the camera-toggle button (the WS-relay mesh fallback has no
    /// video pipeline).
    @Published var isSfuActive = false
    /// W-GRPSCREENSHARE: whether OUR OWN screen share is actually live right
    /// now. Deliberately NOT flipped optimistically by `toggleScreenShare()`
    /// — the real transition is asynchronous (system broadcast picker +
    /// the user actually starting the recording, both outside this app's
    /// control) and this is driven authoritatively by
    /// `GroupCallController.onLocalScreenShareChanged`. See that property's
    /// kdoc chain down to `LiveKitGroupCallRoom.setScreenShareEnabled` for
    /// the full mechanism.
    @Published var isScreenSharing = false
    /// In-call chat panel — the persisted-group id (DASHED UUID, server wire
    /// form) this ACTIVE call is associated with, or "" for an ad-hoc group
    /// call started from the contact picker with no persisted group behind
    /// it (see `BCryptoGroupCallManager.IncomingGroupInvite.groupId` kdoc —
    /// that field is already documented as "empty for an ad-hoc call").
    ///
    /// Neither `BCryptoGroupCallManager` nor `GroupCallController` retain
    /// this anywhere for the lifetime of a call (the crypto/audio layers
    /// only ever need `callId`, a distinct concept — see the "groupId
    /// mismatch" ctrl-envelope check in `GroupCallController`, which is
    /// about the call's own crypto domain, NOT this persisted-chat-group
    /// id). So AppState binds it here explicitly at the two points the
    /// value is actually known: `GroupChatScreen.handleStartGroupCall`
    /// (caller, already has `groupId: UUID`) and
    /// `AppState.performAcceptIncomingGroupCall` (callee, from
    /// `incomingGroupCallInvite.groupId` before it's cleared). Reset to ""
    /// on `.ended` below, mirroring how `participants`/`selfVideoTrack`
    /// already reset per-call state.
    @Published private(set) var activeGroupId: String = ""
    /// Hex form (dashes stripped, lowercase) — the key space
    /// `GroupMessageStore`/`GroupRegistry`/`GroupChatService` all use.
    var activeGroupHex: String {
        activeGroupId.isEmpty ? "" : activeGroupId.replacingOccurrences(of: "-", with: "").lowercased()
    }
    func bindGroupId(_ dashedGroupId: String) {
        activeGroupId = dashedGroupId
    }
    /// Unified call UI (group security sheet) — server-canonical
    /// sender-key epoch, plain passthrough of
    /// `BCryptoGroupCallManager.senderKeyEpoch` (already thread-safe via
    /// its own lock). Read on-demand when the sheet opens rather than
    /// mirrored into a separate `@Published` slot: the sheet is not a
    /// continuously-live surface, so a computed passthrough avoids a
    /// second state copy that could drift from the source of truth.
    var currentEpoch: Int64 { manager.senderKeyEpoch }

    private let manager: BCryptoGroupCallManager
    /// W367: optional GroupCallController (W354/W358/W366) bound to
    /// the audio pipeline. When set, mute toggles and end-call route
    /// through the controller so capture/playback start/stop in
    /// lockstep with call state. Falls back to direct manager calls
    /// if nil (legacy preview path).
    private let controller: GroupCallController?
    private var startTime = Date()
    private var timer: Timer?

    init(manager: BCryptoGroupCallManager, controller: GroupCallController? = nil) {
        self.manager = manager
        self.controller = controller

        // W-GRPVIDEO: `controller` is captured `weak` here even though this
        // closure is only ever installed ONTO `controller.onManagerStateChanged`
        // itself — a strong capture would make controller <-> closure a
        // self-cycle (controller retains the closure, closure retains
        // controller) that ARC can never break, independent of this
        // ViewModel's own (separate) strong `self.controller` reference.
        // Mirrors `[weak self]` on every `manager.on*` closure in
        // `GroupCallController.wireManagerCallbacks()`.
        let onState: (BCryptoGroupCallManager.State) -> Void = { [weak self, weak controller] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.callState = state
                if state == .active {
                    self.isSfuActive = controller?.isUsingSfu ?? false
                    self.isVideoEnabled = controller?.callWantsVideo ?? false
                }
            }
            if state == .active { self?.startTimer() }
            if state == .ended {
                self?.timer?.invalidate()
                // In-call chat panel — clear the previous call's group
                // binding so a subsequent, different call (this ViewModel
                // is long-lived across calls) doesn't leak the old one.
                self?.activeGroupId = ""
            }
        }
        let onParticipants: ([BCryptoGroupCallManager.Participant]) -> Void = { [weak self] list in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Preserve any already-attached video track for a
                // participant that survives this roster refresh — a plain
                // `list.map` would otherwise drop it every time the WS
                // roster updates (join/leave of ANY member re-sends the
                // full list).
                let existingTracks = Dictionary(uniqueKeysWithValues: self.participants.map { ($0.id, $0.videoTrack) })
                // W-GRPSCREENSHARE: same preserve-across-refresh rationale as
                // `existingTracks` above, for the separate screen-share slot.
                let existingScreenShareTracks = Dictionary(uniqueKeysWithValues: self.participants.map { ($0.id, $0.screenShareTrack) })
                self.participants = list.map {
                    ParticipantUI(id: $0.id, displayName: $0.displayName,
                                  isMuted: $0.isMuted, isSpeaking: $0.isSpeaking,
                                  videoTrack: existingTracks[$0.id] ?? nil,
                                  screenShareTrack: existingScreenShareTracks[$0.id] ?? nil)
                }
            }
        }
        if let controller = controller {
            // W-GRPUI: `manager.onStateChanged`/`onParticipantsChanged` are
            // single-slot closures already owned by `controller` (it needs
            // them for the audio-pipeline lifecycle) — observe its
            // passthrough instead of overwriting them directly.
            controller.onManagerStateChanged = onState
            controller.onParticipantsChanged = onParticipants
            // W-GRPVIDEO: bind the LiveKit track callbacks here (rather
            // than in AppState) — this ViewModel is the SFU render-target,
            // and `onRemoteVideoTrack`/`onLocalVideoTrack`/`onSfuParticipant`
            // are single-slot closures on the controller just like the two
            // above, so the same "bind once, here" pattern applies.
            controller.onRemoteVideoTrack = { [weak self] identity, track in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // W-GRPCALL-DIAG (2026-07-15, incident 419eb1dc): the
                    // final hop of hypothesis B (tile-binding) — proves
                    // WHICH tile (by participant id) a remote track was
                    // actually bound to, or that no matching tile existed
                    // yet (roster hadn't caught up with the SFU subscribe).
                    guard let idx = self.participants.firstIndex(where: { $0.id == identity }) else {
                        print("[GroupCallController][telemetry] remote video track for identity=\(identity.prefix(8)) has NO matching participant tile yet (roster/SFU race)")
                        return
                    }
                    print("[GroupCallController][telemetry] remote video track bound to tile identity=\(identity.prefix(8))")
                    self.participants[idx].videoTrack = track
                }
            }
            controller.onLocalVideoTrack = { [weak self] track in
                DispatchQueue.main.async { self?.selfVideoTrack = track }
            }
            controller.onSfuParticipant = { [weak self] identity, present in
                guard !present else { return }
                DispatchQueue.main.async {
                    guard let self = self, let idx = self.participants.firstIndex(where: { $0.id == identity }) else { return }
                    self.participants[idx].videoTrack = nil
                    self.participants[idx].screenShareTrack = nil
                }
            }
            // W-GRPSCREENSHARE: same "bind once, here" pattern as
            // `onRemoteVideoTrack`/`onLocalVideoTrack` above — see
            // `GroupCallController.onRemoteScreenShareTrack`'s kdoc.
            controller.onRemoteScreenShareTrack = { [weak self] identity, track in
                DispatchQueue.main.async {
                    guard let self = self, let idx = self.participants.firstIndex(where: { $0.id == identity }) else { return }
                    self.participants[idx].screenShareTrack = track
                }
            }
            controller.onLocalScreenShareChanged = { [weak self] active in
                DispatchQueue.main.async { self?.isScreenSharing = active }
            }
        } else {
            manager.onStateChanged = onState
            manager.onParticipantsChanged = onParticipants
        }
    }

    func toggleMute() {
        isMuted = manager.toggleMute()
        // W367: also flip the controller's mute so the audio pipeline
        // gates outgoing PCM frames (without this, mute is UI-only and
        // audio still streams to peers).
        controller?.setMuted(isMuted)
    }

    /// W-GRPVIDEO: flip the local camera. Optimistic UI update (mirrors
    /// `toggleMute`'s pattern of flipping first) — reverted if the async
    /// LiveKit call actually fails.
    func toggleVideo() {
        guard let controller = controller else { return }
        let target = !isVideoEnabled
        isVideoEnabled = target
        Task { [weak self] in
            let ok = await controller.setVideoEnabled(target)
            if !ok {
                await MainActor.run { self?.isVideoEnabled = !target }
            }
        }
    }

    /// W-GRPSCREENSHARE: toggle screen sharing. Unlike `toggleVideo()`, this
    /// does NOT optimistically flip `isScreenSharing` first — the real
    /// transition is asynchronous and outside this call's control (system
    /// broadcast picker, then the user actually starting the recording), so
    /// flipping the UI here would show "sharing" the instant the button is
    /// tapped even though nothing has started yet. `isScreenSharing` is
    /// driven authoritatively by `onLocalScreenShareChanged` (wired above).
    func toggleScreenShare() {
        guard let controller = controller else { return }
        let target = !isScreenSharing
        Task {
            _ = await controller.setScreenShareEnabled(target)
        }
    }

    func endCall() {
        // W367: stop the audio pipeline cleanly via the controller; if
        // no controller is bound (legacy preview), fall through to the
        // raw manager.endGroupCall().
        if let controller = controller {
            controller.endCallForAll()
        } else {
            manager.endGroupCall()
        }
    }

    private func startTimer() {
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let elapsed = Int(Date().timeIntervalSince(self.startTime))
            let min = elapsed / 60
            let sec = elapsed % 60
            DispatchQueue.main.async {
                self.elapsedTime = String(format: "%d:%02d", min, sec)
            }
        }
    }
}
