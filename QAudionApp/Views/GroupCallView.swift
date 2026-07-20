import SwiftUI
import QAudionEngine

/// Group call screen with participant grid and controls.
/// The gallery grid packs participants adaptively (`adaptiveGridLayout`)
/// rather than a fixed column count — column/row counts and tile size are
/// recomputed from the live participant count and the real available
/// space so e.g. 3 participants render as a centered 2x2-with-one-gap
/// layout at full size instead of a fixed 2-column grid with a dangling
/// empty half-row. Documented/tested call sizes go up to 8.
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
    /// Item 4 (2026-07-16 wire contract) — one-shot mute-request toast,
    /// same environment-provided host every other screen in this codebase
    /// uses (`GroupCallChatPanel`/`ChatListScreen`/etc. all follow this
    /// exact `@Environment(\.qaudionSnackbar) private var snackbar` +
    /// `snackbar?.show(.init(text:severity:))` idiom).
    @Environment(\.qaudionSnackbar) private var snackbar
    /// Security sheet presentation state — purely a "is the aggregating
    /// sheet open" UI flag, nothing security-critical is gated by it
    /// (mirrors `InCallScreen.showSecuritySheet` exactly).
    @State private var showSecuritySheet = false
    /// Item 1 (2026-07-16 wire contract) — reaction-picker popup
    /// presentation state, same "icon toggle -> dismissible popup"
    /// mechanism as `showSecuritySheet`/`showChatPanel`.
    @State private var showReactionPicker = false

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
    /// 2026-07-17 — which page of the paginated gallery grid is showing.
    /// Clamped back on-screen if a departure shrinks the page count below
    /// this index — see the `.onChange(of: gridPages.count)` below.
    @State private var currentGridPage = 0

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
                    // Item 5 (2026-07-16 wire contract) — pure client-side
                    // layout toggle, no wire message at all (LiveKit's own
                    // native active-speaker detection, wired through
                    // `GroupCallController.onActiveSpeakersChanged`). Placed
                    // in the header rather than the already-crowded control
                    // bar below; icon shows the CURRENT layout, same
                    // current-state-not-destination convention as every
                    // control-bar toggle (mute/video/screen-share) below.
                    Button {
                        viewModel.toggleLayoutMode()
                    } label: {
                        Image(systemName: viewModel.layoutMode == .speaker
                              ? "person.crop.rectangle.fill" : "square.grid.2x2.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .padding(.leading, 10)
                    .accessibilityLabel(viewModel.layoutMode == .speaker
                        ? "Passa a vista griglia" : "Passa a vista relatore")
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

                // Item 5 (2026-07-16 wire contract) — speaker-mode
                // spotlight: mirrors the pre-existing screen-share
                // spotlight tile above (full-width, ABOVE the regular
                // grid) rather than restructuring the grid itself, same
                // "shared content dominates, faces stay small" policy
                // extended to whichever participant the active-speaker
                // signal currently names. Moved out of the (now-removed)
                // `ScrollView` into this outer `VStack`, alongside the
                // screen-share spotlight above — same "fixed panel above
                // the flexible grid" placement; the tile's own rendering
                // is untouched. See `GroupCallViewModel.currentSpeakerId`'s
                // kdoc for the SFU-vs-mesh source.
                if viewModel.layoutMode == .speaker,
                   let speakerId = viewModel.currentSpeakerId,
                   let speaker = viewModel.participants.first(where: { $0.id == speakerId }) {
                    ParticipantTile(
                        participant: speaker,
                        isPinned: true,
                        isSelf: speaker.id == viewModel.selfUserId,
                        reactionEmoji: viewModel.latestReactionEmoji(for: speaker.id),
                        onRequestMute: { viewModel.requestMute(participantId: speaker.id) }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                // Participant grid — ADAPTIVE packing (replaces the old
                // fixed 2-column `LazyVGrid` inside a `ScrollView`, which
                // always left half a row empty for e.g. 3 participants —
                // "tutto lo spazio vuoto e il video in 3 pallini").
                // `GeometryReader` gives the REAL bounded space this
                // section occupies (between the fixed header/spotlights
                // above and the fixed control bar below); `adaptiveGridLayout`
                // then computes the (cols, rows, tileW, tileH) that
                // maximizes rendered tile area for the current PAGE's
                // participant count.
                //
                // 2026-07-17 — live-test report (same fix as Android/
                // Desktop): `adaptiveGridLayout` alone kept shrinking every
                // tile to squeeze the WHOLE roster onto one screen, useless
                // once a real meeting-sized call made every tile illegible.
                // `gridPageCapacity` is purely a property of the container
                // size + a minimum-legible-tile floor (`gridMinTileWidth`),
                // independent of the actual headcount — a bigger/landscape
                // screen naturally fits more per page, never a hardcoded
                // count. Once the roster exceeds that capacity it's split
                // into pages (native `TabView(.page)` swipe + dot
                // indicator) instead of shrinking tiles further, with
                // whoever is CURRENTLY SPEAKING (`activeSpeakerIds`) sorted
                // to the front so they land on page 1.
                GeometryReader { geo in
                    let pageCapacity = Self.gridPageCapacity(width: geo.size.width, height: geo.size.height)
                    let pages = gridPages(pageCapacity: pageCapacity)
                    TabView(selection: $currentGridPage) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, pageParticipants in
                            let layout = Self.adaptiveGridLayout(
                                count: pageParticipants.count,
                                width: geo.size.width,
                                height: geo.size.height
                            )
                            let participantRows = Self.chunkRows(pageParticipants, cols: layout.cols)
                            VStack(spacing: Self.gridSpacing) {
                                ForEach(Array(participantRows.enumerated()), id: \.offset) { _, row in
                                    HStack(spacing: Self.gridSpacing) {
                                        Spacer(minLength: 0)
                                        ForEach(row) { participant in
                                            ParticipantTile(
                                                participant: participant,
                                                isSelf: participant.id == viewModel.selfUserId,
                                                reactionEmoji: viewModel.latestReactionEmoji(for: participant.id),
                                                onRequestMute: { viewModel.requestMute(participantId: participant.id) },
                                                tileSize: CGSize(width: layout.tileW, height: layout.tileH)
                                            )
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .tag(pageIndex)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
                    .onChange(of: pages.count) { newCount in
                        // A member leaving can shrink page count below the
                        // page the user was looking at — clamp back onto
                        // the last real page instead of a blank tab.
                        if currentGridPage > newCount - 1 {
                            currentGridPage = max(newCount - 1, 0)
                        }
                    }
                }
                .padding(.horizontal, 16)

                // Control bar — responsive sizing (2026-07-20, live 5-way
                // call 694147de): the old fixed `HStack(spacing: 32)` of
                // 56pt circles needed ~584pt for the full 7-button SFU row
                // — wider than ANY iPhone in portrait (390-430pt logical),
                // so the row overflowed the screen on BOTH sides (the mute
                // and end-call buttons landed fully OFF-SCREEN) and
                // inflated the enclosing VStack past the device width,
                // while iPad (≥744pt) happened to fit — "layout fisso che
                // non fitta il telefono". Same container-driven philosophy
                // as the grid's `gridPageCapacity` above: derive the button
                // diameter and gap from the REAL row width, each capped at
                // the original 56pt/32pt so any screen that already fit
                // (iPad, landscape) renders exactly as before.
                GeometryReader { controlGeo in
                    let buttonCount = CGFloat(viewModel.isSfuActive ? 7 : 5)
                    // max(0, …) guards the zero-size first layout pass a
                    // GeometryReader can report — a negative frame dimension
                    // is a SwiftUI runtime error, not just a visual glitch.
                    let controlSize = max(0, min(56, (controlGeo.size.width - 8 * (buttonCount - 1)) / buttonCount))
                    let controlSpacing = max(0, min(32, (controlGeo.size.width - controlSize * buttonCount) / max(buttonCount - 1, 1)))
                    controlBar(buttonSize: controlSize, spacing: controlSpacing)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 56)
                .padding(.horizontal, 8)
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
        // Item 4 (2026-07-16 wire contract) — one-shot mute-request toast.
        // The ViewModel is a plain `ObservableObject` with no reach into
        // the environment-provided `QAudionSnackbarHostState`, so it just
        // publishes the resolved text and this View pushes it through the
        // same snackbar every other screen uses, then clears it back to
        // nil so a later identical message can still re-fire (`current` on
        // `QAudionSnackbarHostState` de-dupes only by that instance, but
        // `.onChange` needs a real value transition to fire at all).
        .onChange(of: viewModel.muteRequestToastText) { text in
            guard let text else { return }
            snackbar?.show(.init(text: text, severity: .info))
            viewModel.muteRequestToastText = nil
        }
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

    /// The control-row buttons, extracted from `body` verbatim (2026-07-20
    /// responsive-control-bar fix — see the call site's comment): every
    /// button used to hard-code `.frame(width: 56, height: 56)` inside an
    /// `HStack(spacing: 32)`; both constants now arrive from the call
    /// site's `GeometryReader`, capped at those same values, so nothing
    /// changes visually wherever the old row already fit.
    private func controlBar(buttonSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            // Mute button
            Button {
                viewModel.toggleMute()
            } label: {
                Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: buttonSize, height: buttonSize)
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
                        .frame(width: buttonSize, height: buttonSize)
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
                        .frame(width: buttonSize, height: buttonSize)
                        .background(viewModel.isScreenSharing ? Color.blue.opacity(0.35) : Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                .accessibilityLabel(viewModel.isScreenSharing ? "Interrompi condivisione schermo" : "Condividi schermo")
            }

            // Item 1 (2026-07-16 wire contract) — raise/lower
            // hand, state-dependent background color exactly like
            // the mute button above (`Color.red.opacity(0.3)`
            // muted / `Color.white.opacity(0.15)` unmuted) — same
            // pattern, orange being the raised-hand's own semantic
            // (distinct from mute's red / screen-share's blue)
            // since it's not an error/alert state.
            Button {
                viewModel.toggleHandRaised()
            } label: {
                Image(systemName: viewModel.isHandRaised ? "hand.raised.fill" : "hand.raised")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(viewModel.isHandRaised ? Color.orange.opacity(0.35) : Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .accessibilityLabel(viewModel.isHandRaised ? "Abbassa la mano" : "Alza la mano")

            // Item 1 — reaction picker: small popup with the fixed
            // 6-emoji set (see `reactionPicker` below). `.popover`
            // gives the "small popup" shape for free.
            Button {
                showReactionPicker = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .popover(isPresented: $showReactionPicker) {
                reactionPicker
            }
            .accessibilityLabel("Invia una reazione")

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
                    .frame(width: buttonSize, height: buttonSize)
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
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Color.red)
                    .clipShape(Circle())
            }
        }
    }

    /// Item 5: the regular grid's participant list — in `.speaker` layout
    /// mode the pinned spotlight tile above already renders the active
    /// speaker, so exclude them here to avoid a duplicate tile (mirrors
    /// the pre-existing screen-share spotlight's "small tiles stay
    /// small, shared content dominates" policy). 2026-07-17 — additionally
    /// sorted so anyone currently in `activeSpeakerIds` comes first, so
    /// `gridPages` below lands them on page 1 (stable otherwise: everyone
    /// not currently speaking keeps their existing relative order).
    private var gridParticipants: [GroupCallViewModel.ParticipantUI] {
        let base: [GroupCallViewModel.ParticipantUI]
        if viewModel.layoutMode == .speaker, let speakerId = viewModel.currentSpeakerId {
            base = viewModel.participants.filter { $0.id != speakerId }
        } else {
            base = viewModel.participants
        }
        let speaking = base.filter { viewModel.activeSpeakerIds.contains($0.id) }
        let resting = base.filter { !viewModel.activeSpeakerIds.contains($0.id) }
        return speaking + resting
    }

    /// 2026-07-17 — splits the (already speaker-sorted) `gridParticipants`
    /// into pages of at most `pageCapacity` each, for the `TabView(.page)`
    /// pager above. A page with fewer participants than capacity still
    /// gets full-size tiles via `adaptiveGridLayout` (capacity is a
    /// CEILING per page, not a per-page target).
    private func gridPages(pageCapacity: Int) -> [[GroupCallViewModel.ParticipantUI]] {
        guard pageCapacity > 0, !gridParticipants.isEmpty else { return gridParticipants.isEmpty ? [] : [gridParticipants] }
        return stride(from: 0, to: gridParticipants.count, by: pageCapacity).map {
            Array(gridParticipants[$0..<min($0 + pageCapacity, gridParticipants.count)])
        }
    }

    /// Chunks an explicit participant array (one page's worth) into rows of
    /// `cols` for the adaptive grid's `VStack`-of-`HStack`s render —
    /// `LazyVGrid` has no API for "N columns, but size every cell to an
    /// externally computed tileW/tileH and center a short last row", so
    /// this manual chunk + render replaces it (see `adaptiveGridLayout`
    /// below). Static + explicit-array (rather than reading `gridParticipants`
    /// directly) so each page in the pager can chunk its OWN slice.
    private static func chunkRows(
        _ items: [GroupCallViewModel.ParticipantUI], cols: Int
    ) -> [[GroupCallViewModel.ParticipantUI]] {
        guard cols > 0 else { return [] }
        return stride(from: 0, to: items.count, by: cols).map {
            Array(items[$0..<min($0 + cols, items.count)])
        }
    }

    /// Adaptive gallery grid — result of `adaptiveGridLayout`: render
    /// exactly `cols` columns x `rows` rows, each tile sized `tileW` x
    /// `tileH`.
    private struct AdaptiveGridLayout {
        let cols: Int
        let rows: Int
        let tileW: CGFloat
        let tileH: CGFloat
    }

    /// TARGET_ASPECT — matches the existing video aspect convention
    /// already used on Desktop's `.tile` CSS, kept consistent across all
    /// 3 platforms per this feature's spec.
    private static let targetAspect: CGFloat = 16.0 / 9.0
    private static let gridSpacing: CGFloat = 12

    /// 2026-07-17 — floor below which a tile is no longer legible
    /// (face/name unreadable). Same value and same role as Android's
    /// `GRID_MIN_TILE_WIDTH`/Desktop's `--grid-min-tile-width`: below this
    /// width `gridPageCapacity` paginates instead of `adaptiveGridLayout`
    /// shrinking every tile further to fit the whole roster on one screen.
    private static let gridMinTileWidth: CGFloat = 110

    /// How many tiles fit in `width` x `height` without any tile dropping
    /// below `gridMinTileWidth`. Independent of the actual participant
    /// count — purely a property of the container + the readability floor
    /// — so the interface adapts the page size to whatever screen it's
    /// given (iPad/landscape fits more per page than a small iPhone in
    /// portrait) instead of a hardcoded number.
    private static func gridPageCapacity(width: CGFloat, height: CGFloat) -> Int {
        guard width > 0, height > 0 else { return 1 }
        var best = 1
        var cols = 1
        while cols <= 12 {
            let cellW = (width - CGFloat(cols - 1) * gridSpacing) / CGFloat(cols)
            if cellW < gridMinTileWidth { break }
            let cellH = cellW / targetAspect
            let rows = max(Int((height + gridSpacing) / (cellH + gridSpacing)), 1)
            best = max(best, cols * rows)
            cols += 1
        }
        return best
    }

    /// The adaptive video-grid packing algorithm — applied identically
    /// per spec (this is the exact packing logic, not a suggestion to
    /// redesign). For every candidate column count from 1 to N, compute
    /// the resulting row count, the per-cell size, and the largest
    /// `targetAspect`-conformant tile that fits in that cell — then keep
    /// whichever (cols, rows) maximizes the rendered tile's area.
    /// `width`/`height` must be the REAL bounded container size (from
    /// `GeometryReader`), not an unbounded/scrolling area — see this
    /// method's call site for why the old `ScrollView` was dropped.
    /// `gridSpacing` is subtracted from the raw container size before
    /// dividing into cells — an addition beyond the literal pseudocode,
    /// needed so N tiles PLUS their inter-tile gaps actually fit inside
    /// `width`/`height` rather than overflowing it by the total gap
    /// amount.
    private static func adaptiveGridLayout(count: Int, width: CGFloat, height: CGFloat) -> AdaptiveGridLayout {
        guard count > 0, width > 0, height > 0 else {
            return AdaptiveGridLayout(cols: 1, rows: max(count, 1), tileW: max(width, 0), tileH: max(height, 0))
        }
        var best: AdaptiveGridLayout?
        var bestArea: CGFloat = -1
        for cols in 1...count {
            let rows = (count + cols - 1) / cols // ceil(count / cols), integer-only (no Foundation `ceil` needed)
            let cellW = (width - CGFloat(cols - 1) * gridSpacing) / CGFloat(cols)
            let cellH = (height - CGFloat(rows - 1) * gridSpacing) / CGFloat(rows)
            guard cellW > 0, cellH > 0 else { continue }
            let tileW: CGFloat
            let tileH: CGFloat
            if cellW / cellH > targetAspect {
                tileH = cellH
                tileW = cellH * targetAspect
            } else {
                tileW = cellW
                tileH = tileW / targetAspect
            }
            let area = tileW * tileH
            if area > bestArea {
                bestArea = area
                best = AdaptiveGridLayout(cols: cols, rows: rows, tileW: tileW, tileH: tileH)
            }
        }
        // Only reachable if EVERY candidate's cell math went non-positive
        // (a container smaller than `gridSpacing` itself) — fall back to
        // a single column rather than rendering nothing.
        return best ?? AdaptiveGridLayout(cols: 1, rows: count, tileW: max(width, 1), tileH: max(height / CGFloat(count), 1))
    }

    /// Item 1: the reaction-picker popup content — the wire contract's
    /// fixed 6-emoji set. Tapping one sends it and dismisses the popup;
    /// the sender renders their own reaction optimistically (see
    /// `GroupCallViewModel.sendReaction`'s kdoc chain), so no spinner/wait
    /// state is needed here.
    private var reactionPicker: some View {
        HStack(spacing: 14) {
            ForEach(["👍", "❤️", "😂", "👏", "😮", "🤔"], id: \.self) { emoji in
                Button {
                    viewModel.sendReaction(emoji: emoji)
                    showReactionPicker = false
                } label: {
                    Text(emoji).font(.system(size: 30))
                }
            }
        }
        .padding(20)
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
    /// Item 5: enlarged spotlight rendering when this tile is the pinned
    /// active speaker in `.speaker` layout mode. Defaults `false` so the
    /// pre-existing regular-grid call site (now explicit about it too)
    /// needs no behavior change.
    var isPinned: Bool = false
    /// Item 2: whether this tile is the local user's own — gates the
    /// mute-others context menu (can't request muting yourself). Defaults
    /// `false`; a preview/call site that never passes it simply never
    /// shows the menu, which is the safe default.
    var isSelf: Bool = false
    /// Item 3: the freshest still-live reaction for this participant, or
    /// nil — `GroupCallViewModel.latestReactionEmoji(for:)` already only
    /// ever returns a not-yet-2s-expired entry, so this view just renders
    /// whatever is currently live with no timer of its own.
    var reactionEmoji: String? = nil
    /// Item 2: invoked from the mute-others context-menu action.
    var onRequestMute: (() -> Void)? = nil
    /// Adaptive gallery grid (`GroupCallView.adaptiveGridLayout`) — the
    /// exact (width, height) this tile must render at, computed by the
    /// packing algorithm so N tiles fill the available screen space with
    /// no half-empty row. `nil` for every OTHER call site (the speaker-mode
    /// spotlight tile above, and any preview) — those keep the
    /// pre-existing fixed-constant sizing (`mediaHeight` below) completely
    /// untouched via `AdaptiveGridClamp`'s no-op branch, exactly as specced
    /// ("keep the spotlight panels exactly as they are").
    var tileSize: CGSize? = nil

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

                // Item 3: transient reaction overlay — floats over this
                // same ZStack (video or avatar), matching the wire
                // contract's "transient floating/fading overlay over the
                // sender's participant tile" spec.
                if let reactionEmoji {
                    Text(reactionEmoji)
                        .font(.system(size: isPinned ? 44 : 28))
                        .transition(.scale.combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: reactionEmoji)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: mediaHeight)
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
            // Item 3: raised-hand badge — topTrailing, a DIFFERENT corner
            // than the screen-share badge (bottomTrailing) above to avoid
            // collision when both are showing on the same tile at once.
            .overlay(alignment: .topTrailing) {
                if participant.handRaised {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Circle().fill(Color.orange.opacity(0.9)))
                }
            }

            Text(participant.displayName)
                .font(isPinned ? .body : .caption).foregroundColor(.white)
                .lineLimit(1)

            if participant.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.caption2).foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isPinned ? 20 : 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        // Item 2: mute-others UI — long-press context menu on any OTHER
        // participant's tile (never shown on the local user's own tile).
        // Flat/non-admin-gated per the wire contract: no client-side
        // permission check beyond "not self" — the server enforces the
        // only real gate (both must be current participants).
        .contextMenu {
            if !isSelf, let onRequestMute {
                Button {
                    onRequestMute()
                } label: {
                    Label("Silenzia \(participant.displayName)", systemImage: "mic.slash")
                }
            }
        }
        // Adaptive gallery grid — the ONLY new modifier in this whole view;
        // everything above is byte-for-byte unchanged. A no-op (`content`
        // passed straight through) whenever `tileSize` is nil, which is
        // true for every pre-existing call site (the speaker spotlight
        // above, previews) — see `AdaptiveGridClamp`'s kdoc. Deliberately
        // LAST in the chain: it clamps the FULLY composed view (padding +
        // background + cornerRadius already applied) to the packing
        // algorithm's exact tileW x tileH, which is what the parent
        // HStack/VStack row math in `GroupCallView.body` depends on to
        // avoid rows structurally overflowing the available height —
        // independent of whether this tile's own natural content (video +
        // label + padding) is a perfect pixel match for that size.
        .modifier(AdaptiveGridClamp(tileSize: tileSize))
    }

    /// Item 5: taller/more prominent sizing for the pinned spotlight tile,
    /// otherwise identical to the pre-existing per-content-type sizing —
    /// UNLESS the adaptive grid assigned this tile a `tileSize`, in which
    /// case the media area scales with it (reserving `chromeReserve` for
    /// the name label / mute icon / padding below) instead of using the
    /// old fixed constants. Purely cosmetic best-effort sizing — the outer
    /// `AdaptiveGridClamp` above is what actually guarantees the tile's
    /// REPORTED size to its parent never exceeds the packing budget, so an
    /// imperfect estimate here only risks a few points of blank space or
    /// visual overflow WITHIN this one tile, never a structural row
    /// overflow.
    private var mediaHeight: CGFloat {
        if let tileSize {
            return max(24, tileSize.height - Self.chromeReserve)
        }
        if isPinned { return participant.videoTrack != nil ? 220 : 140 }
        return participant.videoTrack != nil ? 120 : 64
    }

    private static let chromeReserve: CGFloat = 50
}

/// Adaptive gallery grid — clamps a `ParticipantTile` to an exact size
/// computed by `GroupCallView.adaptiveGridLayout`, or passes the view
/// through completely untouched when no size was assigned. Kept as a
/// standalone `ViewModifier` (rather than an inline `if/else` in
/// `ParticipantTile.body`) specifically so the `nil` branch is
/// syntactically guaranteed to be a no-op — there is no risk of the two
/// branches' modifier chains silently drifting apart over time.
private struct AdaptiveGridClamp: ViewModifier {
    let tileSize: CGSize?
    func body(content: Content) -> some View {
        if let tileSize {
            content.frame(width: tileSize.width, height: tileSize.height)
        } else {
            content
        }
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
        /// Tier-1 (item 3, 2026-07-16 wire contract) — mirrors
        /// `GroupCallController.raisedHands` for this participant; seeded/
        /// refreshed from the ViewModel's `raisedHandsCache` (see the
        /// `onRaisedHandsChanged` wiring in `init` and the roster-rebuild
        /// in `onParticipantsChanged` below). KNOWN ACCEPTED LIMITATION
        /// (wire contract item 3): ephemeral, fed only by the
        /// `group_call_raise_hand_recv` stream since joining — a
        /// participant who joins/reconnects mid-call won't see who
        /// currently has a hand raised.
        var handRaised: Bool = false
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
    /// Tier-1 (2026-07-16 wire contract) — mirrors `GroupCallController.
    /// reactionEvents` 1:1 (bound via `onReactionEventsChanged` in `init`
    /// below). `GroupCallController` already only ever hands back
    /// not-yet-2s-expired entries (its own removal timer), so this array
    /// is always "currently live" — no extra expiry bookkeeping here.
    @Published var reactionEvents: [GroupCallController.ReactionEvent] = []
    /// Item 1: our OWN raised-hand toggle state — flipped optimistically
    /// by `toggleHandRaised()`, same self-authoritative shape as
    /// `isMuted`/`isVideoEnabled` above (not derived from the roster, so
    /// the button responds instantly regardless of roster-refresh timing).
    @Published var isHandRaised = false
    /// Item 5: pure client-side layout toggle — no wire message at all.
    /// Starts `.gallery` (today's existing grid) so a call that never
    /// touches the new header button behaves exactly as before.
    @Published var layoutMode: LayoutMode = .gallery
    enum LayoutMode {
        case gallery
        case speaker
    }
    /// Item 5: passthrough of `GroupCallController.onActiveSpeakersChanged`
    /// (LiveKit's own native active-speaker detection) — only ever set
    /// while riding the SFU; see `currentSpeakerId`'s kdoc for the mesh
    /// fallback.
    @Published var activeSpeakerId: String? = nil
    /// 2026-07-17 — the FULL currently-speaking set (identities.first alone,
    /// stored above as [activeSpeakerId], is only ever used for the single
    /// spotlight pin). The paginated gallery grid needs everyone who's
    /// currently talking, not just the loudest one, to sort them to page 1
    /// — see [GroupCallView]'s grid-paging kdoc.
    @Published var activeSpeakerIds: Set<String> = []
    /// Item 4: resolved toast text for a just-received
    /// `group_call_mute_request_recv`, or nil. This plain
    /// `ObservableObject` has no reach into the environment-provided
    /// `QAudionSnackbarHostState`, so `GroupCallView` observes this via
    /// `.onChange` and pushes it through that snackbar itself, then
    /// clears it back to nil (see that call site's kdoc).
    @Published var muteRequestToastText: String? = nil
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
    /// Item 2/3: our own participant id — used to gate the mute-others
    /// context menu (can't target yourself) and to look up our own
    /// raised-hand/reaction state alongside everyone else's.
    var selfUserId: String { manager.selfUserId }
    /// Item 5: which participant is currently "the speaker" for layout
    /// purposes. Over the LiveKit SFU this is `activeSpeakerId` (LiveKit's
    /// own native active-speaker detection). On the WS-relay mesh
    /// fallback (no SFU room, so that callback never fires) this instead
    /// reuses each participant's pre-existing `isSpeaking` flag — already
    /// driven by `BCryptoGroupCallManager`'s own 500ms-decay speaking
    /// heuristic (the SAME flag that already rings a tile's border) — per
    /// the wire contract's explicit "reuse the existing heuristic, no new
    /// mesh plumbing" instruction.
    var currentSpeakerId: String? {
        if isSfuActive { return activeSpeakerId }
        return participants.first(where: { $0.isSpeaking })?.id
    }
    /// Item 3: the freshest still-live reaction for one participant, or
    /// nil if none is currently displayed.
    func latestReactionEmoji(for participantId: String) -> String? {
        reactionEvents.last(where: { $0.senderId == participantId })?.emoji
    }

    /// W-GRPSFUGHOST: append a synthesized tile for any `sfuPresentIdentities`
    /// entry missing from `participants` — called both right after a
    /// `group_call_update` roster rebuild (`onParticipants`) and immediately
    /// on a fresh `Room.participantDidConnect` (`onSfuParticipant`), so
    /// neither path can leave a real SFU room member without a tile for
    /// longer than one runloop turn. MainActor-only (both call sites already
    /// hop via `DispatchQueue.main.async`), so no locking needed here —
    /// mirrors every other mutation of `participants` in this class.
    private func mergeSfuOnlyParticipants() {
        let known = Set(participants.map(\.id))
        for identity in sfuPresentIdentities where !known.contains(identity) && identity != selfUserId {
            print("[GroupCallViewModel][telemetry] SFU-only participant identity=\(identity.prefix(8)) has no WS-roster tile — synthesizing one from LiveKit presence")
            participants.append(ParticipantUI(
                id: identity,
                displayName: DisplayName.forUser(identity),
                videoTrack: pendingVideoTracks.removeValue(forKey: identity),
                screenShareTrack: pendingScreenShareTracks.removeValue(forKey: identity),
                handRaised: raisedHandsCache.contains(identity)
            ))
        }
    }

    private let manager: BCryptoGroupCallManager
    /// W367: optional GroupCallController (W354/W358/W366) bound to
    /// the audio pipeline. When set, mute toggles and end-call route
    /// through the controller so capture/playback start/stop in
    /// lockstep with call state. Falls back to direct manager calls
    /// if nil (legacy preview path).
    private let controller: GroupCallController?
    private var startTime = Date()
    private var timer: Timer?
    /// Item 3: local mirror of `GroupCallController.raisedHands`, used to
    /// seed each `ParticipantUI.handRaised` when the roster rebuilds in
    /// `onParticipants` below (that closure only ever has the fresh
    /// `[Participant]` list from the manager, not the controller's
    /// separate raised-hand set, so this cache bridges the two).
    private var raisedHandsCache: Set<String> = []
    /// W-GRPCALL-DIAG follow-up (was diagnostic-only since 2026-07-15,
    /// incident 419eb1dc — see the `onRemoteVideoTrack`/
    /// `onRemoteScreenShareTrack` kdoc below): `manager.onParticipantsChanged`
    /// (WS control-plane roster) and `room.onRemoteVideoTrack`/
    /// `onRemoteScreenShareTrack` (LiveKit SFU data-plane track-subscribe)
    /// are two INDEPENDENT event streams over two different transports —
    /// there is no ordering guarantee between them. In a bigger call
    /// (roster broadcast fan-out takes longer with more members) the SFU
    /// can subscribe a remote track for an identity before this device's
    /// WS roster lists that participant yet; that used to just drop the
    /// track on the floor forever (only the roster-rebuild's
    /// `existingTracks` dictionary carries a track forward, and a track
    /// that was never attached in the first place isn't in it). These two
    /// caches hold a track that arrived with no matching tile YET, so the
    /// very next roster rebuild in `onParticipants` below can attach it
    /// instead of silently losing it.
    private var pendingVideoTracks: [String: AnyObject] = [:]
    private var pendingScreenShareTracks: [String: AnyObject] = [:]
    /// W-GRPSFUGHOST (2026-07-20, live 3-way call DC7D18B9): identities
    /// LiveKit itself has told us are actual room members
    /// (`Room.participantDidConnect`, via `onSfuParticipant(_, true)`),
    /// independent of whether the WS-signaling roster
    /// (`manager.onParticipantsChanged`, fed by `group_call_update`) has
    /// ever listed them. These two rosters are two INDEPENDENT sources of
    /// truth — before this fix `participants` (tile existence) was driven
    /// 100% by the WS roster, with the SFU-native signal used only to
    /// attach/detach tracks onto an ALREADY-existing tile. Live-repro: the
    /// server reaps a participant from `GroupCall.Participants` after an
    /// ungraceful-disconnect grace window (commit 5a3b2e1) even while that
    /// participant's LiveKit session — and its WS opaque-message
    /// ctrl-channel — stays fully alive; a peer stuck in exactly that state
    /// was invisible in the grid forever (both iPhones exchanged
    /// sender-key rotates with a Desktop peer neither ever rendered a tile
    /// for), because no `group_call_update` was ever coming to introduce
    /// one. `mergeSfuOnlyParticipants` keeps any identity in this set
    /// present in `participants` even across a roster rebuild that still
    /// doesn't mention them — the next roster update that DOES include them
    /// simply supersedes the synthesized entry (same id, so `list.map`'s
    /// own entry wins the position; the merge only appends what's missing).
    private var sfuPresentIdentities: Set<String> = []

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
                // W-GRPSFUGHOST: when WE hang up, LiveKit does not fire a
                // per-remote `participantDidDisconnect` for everyone else
                // still in the room (only OUR OWN room teardown runs) — so
                // without this, `sfuPresentIdentities` would carry stale
                // identities from THIS call into the next one, and
                // `mergeSfuOnlyParticipants` could synthesize a ghost tile
                // for someone who isn't even in the new call. This
                // ViewModel is long-lived across calls (same rationale as
                // `activeGroupId` above), so this state must be reset
                // explicitly rather than relying on per-departure cleanup.
                self?.sfuPresentIdentities.removeAll()
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
                self.participants = list.map { entry in
                    // Roster/SFU race fix (see `pendingVideoTracks`' kdoc):
                    // a track that arrived before this identity had a tile
                    // gets attached NOW, on the roster refresh that finally
                    // introduces that tile, instead of staying lost.
                    let video = existingTracks[entry.id] ?? self.pendingVideoTracks.removeValue(forKey: entry.id)
                    let screenShare = existingScreenShareTracks[entry.id] ?? self.pendingScreenShareTracks.removeValue(forKey: entry.id)
                    return ParticipantUI(id: entry.id, displayName: entry.displayName,
                                  isMuted: entry.isMuted, isSpeaking: entry.isSpeaking,
                                  videoTrack: video,
                                  screenShareTrack: screenShare,
                                  handRaised: self.raisedHandsCache.contains(entry.id))
                }
                // W-GRPSFUGHOST: a stale/incomplete WS roster (see
                // `sfuPresentIdentities`' kdoc) must not erase a tile for
                // someone LiveKit itself confirms is still in the room —
                // `list.map` above is a full REPLACE keyed only off the
                // server's `participants` array, so without this a synthesized
                // tile added by `onSfuParticipant` would vanish again on the
                // very next unrelated roster broadcast (e.g. a THIRD member
                // joining/leaving) if the server still hasn't reconciled.
                self.mergeSfuOnlyParticipants()
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
                        // Roster/SFU race (see `pendingVideoTracks`'s kdoc):
                        // hold the track instead of dropping it — the next
                        // `onParticipants` roster refresh will attach it.
                        print("[GroupCallController][telemetry] remote video track for identity=\(identity.prefix(8)) has NO matching participant tile yet (roster/SFU race) — cached pending roster catch-up")
                        self.pendingVideoTracks[identity] = track
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
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard present else {
                        // A participant can leave before the roster/SFU race
                        // above ever resolved for them — drop any pending track
                        // too, so it can't get misattached to a later identity.
                        // KNOWN RESIDUAL: this only clears tracks, it does NOT
                        // remove a tile that exists ONLY because
                        // `mergeSfuOnlyParticipants` synthesized it (no
                        // per-tile "was this WS-confirmed" provenance is
                        // tracked) — relies on the WS roster's own eventual
                        // `group_call_update` to fully drop the tile, same as
                        // it always has for a roster-known departure. Still
                        // strictly better than the pre-fix behavior (that
                        // participant never getting a tile at all).
                        self.sfuPresentIdentities.remove(identity)
                        self.pendingVideoTracks.removeValue(forKey: identity)
                        self.pendingScreenShareTracks.removeValue(forKey: identity)
                        guard let idx = self.participants.firstIndex(where: { $0.id == identity }) else { return }
                        self.participants[idx].videoTrack = nil
                        self.participants[idx].screenShareTrack = nil
                        return
                    }
                    // W-GRPSFUGHOST: see `sfuPresentIdentities`'/
                    // `mergeSfuOnlyParticipants`'s kdoc — this is the
                    // ground-truth "LiveKit says this identity is really in
                    // the room" signal, tracked independently of whatever the
                    // WS-signaling roster currently believes.
                    self.sfuPresentIdentities.insert(identity)
                    self.mergeSfuOnlyParticipants()
                }
            }
            // W-GRPSCREENSHARE: same "bind once, here" pattern as
            // `onRemoteVideoTrack`/`onLocalVideoTrack` above — see
            // `GroupCallController.onRemoteScreenShareTrack`'s kdoc.
            controller.onRemoteScreenShareTrack = { [weak self] identity, track in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard let idx = self.participants.firstIndex(where: { $0.id == identity }) else {
                        // Same roster/SFU race as `onRemoteVideoTrack` above —
                        // cache it for the next roster refresh instead of
                        // dropping it.
                        self.pendingScreenShareTracks[identity] = track
                        return
                    }
                    self.participants[idx].screenShareTrack = track
                }
            }
            controller.onLocalScreenShareChanged = { [weak self] active in
                DispatchQueue.main.async { self?.isScreenSharing = active }
            }
            // Tier-1 (2026-07-16 wire contract) — reactions/raised-hand/
            // active-speaker/mute-request data-layer passthroughs. Same
            // "bind once, here" pattern as every other `controller.on*`
            // callback above.
            controller.onReactionEventsChanged = { [weak self] events in
                DispatchQueue.main.async { self?.reactionEvents = events }
            }
            controller.onRaisedHandsChanged = { [weak self] raised in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.raisedHandsCache = raised
                    for idx in self.participants.indices {
                        self.participants[idx].handRaised = raised.contains(self.participants[idx].id)
                    }
                }
            }
            controller.onActiveSpeakersChanged = { [weak self] identities in
                DispatchQueue.main.async {
                    self?.activeSpeakerId = identities.first
                    self?.activeSpeakerIds = Set(identities)
                }
            }
            controller.onMuteRequested = { [weak self] requesterId in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Item 4(a): the REAL mute (legacy WS-relay gate +
                    // SFU mic toggle) is already applied by
                    // `GroupCallController.handleMuteRequest` before this
                    // callback fires — see that method's kdoc. Here we
                    // only need item 4(b): "update local mute-button UI
                    // state" — this control-bar button's own flag.
                    // Deliberately NOT also poking `manager.toggleMute()`
                    // to sync the roster's separate self-entry mute badge:
                    // `BCryptoGroupCallManager` exposes only a pure
                    // `toggleMute() -> Bool` (no idempotent setter, no
                    // current-value getter), so a blind call here could
                    // flip it back to unmuted if the roster already
                    // agreed — not worth the risk for a purely cosmetic
                    // second badge.
                    self.isMuted = true
                    // Item 4(c): one-shot, non-blocking toast — resolve
                    // the requester's display name from the live roster,
                    // falling back to the raw id if it hasn't caught up
                    // yet.
                    // Never fall back to the raw id — resolve through the
                    // central chain (rubrica → "Utente a1b2c3d4…").
                    let displayName = self.participants.first(where: { $0.id == requesterId })?.displayName
                        ?? DisplayName.forUser(requesterId)
                    self.muteRequestToastText = "\(displayName) ti ha silenziato"
                }
            }
        } else {
            manager.onStateChanged = onState
            manager.onParticipantsChanged = onParticipants
        }

        // W-GRPSTALEMGR belt-and-suspenders (2026-07-19): every closure
        // above only observes FUTURE events — a roster/state the manager
        // already holds at construction time would otherwise never render
        // (this ViewModel is rebuilt on every socket rebuild, and a
        // group_call_update that landed before this init ran is the late
        // joiner's ONLY full-roster snapshot; the next one needs someone
        // else to join/leave). Android's Compose `collectAsState` reads the
        // CURRENT StateFlow value at composition, making it immune to this
        // whole missed-event class by construction — this seed is the iOS
        // equivalent. Both closures hop to the main queue internally, so
        // invoking them directly here is safe from any context.
        let participantsSnapshot = manager.participants
        if !participantsSnapshot.isEmpty {
            onParticipants(participantsSnapshot)
        }
        let stateSnapshot = manager.state
        if stateSnapshot != .idle {
            onState(stateSnapshot)
        }
        // W-GRPSFUGHOST follow-up (2026-07-20): same snapshot-at-bind
        // rationale as `participantsSnapshot`/`stateSnapshot` above, but for
        // the INDEPENDENT SFU-presence source `sfuPresentIdentities` tracks
        // (see that property's kdoc) — `onSfuParticipant` above only ever
        // observes FUTURE LiveKit connect/disconnect events, so a remote
        // participant already connected to the SFU room before THIS
        // (re)bind (e.g. a mid-call socket rebuild that reconstructs this
        // ViewModel — `GroupCallController.rebind(manager:)`'s kdoc) would
        // otherwise never get a tile via that path either.
        if let controller = controller {
            let sfuSnapshot = controller.sfuConnectedIdentities
            if !sfuSnapshot.isEmpty {
                sfuPresentIdentities.formUnion(sfuSnapshot)
                mergeSfuOnlyParticipants()
            }
        }
    }

    func toggleMute() {
        isMuted = manager.toggleMute()
        // W367: also flip the controller's mute so the audio pipeline
        // gates outgoing PCM frames (without this, mute is UI-only and
        // audio still streams to peers).
        controller?.setMuted(isMuted)
        // W-GRPMUTEFIX (item 6, 2026-07-16 wire contract): the two calls
        // above only ever gated the LEGACY WS-relay-mesh pipeline —
        // pressing this SAME button during an actual LiveKit-SFU call (the
        // default/production transport) did NOT silence the outbound
        // LiveKit audio track. `setMicrophoneEnabled` is a real no-op
        // (returns false) when the call isn't riding the SFU, so firing it
        // unconditionally (rather than branching on `isSfuActive`) is safe
        // — this makes the action itself SFU-aware instead of gating the
        // button's visibility (see `GroupCallController.
        // setMicrophoneEnabled`'s kdoc for the bug this closes). Same
        // unwrap-and-fire idiom as `toggleScreenShare` below.
        if let controller = controller {
            let micEnabled = !isMuted
            Task {
                _ = await controller.setMicrophoneEnabled(micEnabled)
            }
        }
    }

    /// Item 1 (2026-07-16 wire contract): send + optimistically render our
    /// own group-call reaction. The controller (not the manager directly)
    /// owns the optimistic local render — see `GroupCallController.
    /// sendReaction`'s kdoc — so route through it, same unwrap-and-fire
    /// idiom as `toggleScreenShare` below. No-op with no controller bound
    /// (legacy preview path has no group-call features to show).
    func sendReaction(emoji: String) {
        controller?.sendReaction(emoji: emoji)
    }

    /// Item 1: raise/lower our own hand — explicit boolean toggle,
    /// idempotent resend is safe (see `GroupCallController.setHandRaised`'s
    /// kdoc). `isHandRaised` flips optimistically, same self-authoritative
    /// shape as `isMuted`.
    func toggleHandRaised() {
        guard let controller = controller else { return }
        isHandRaised.toggle()
        controller.setHandRaised(isHandRaised)
    }

    /// Item 2 (2026-07-16 wire contract): request another participant mute
    /// themselves. Sent straight through the manager — unlike `sendReaction`/
    /// `setHandRaised`, a mute-request has no crypto/session state of its
    /// own for the controller to own (see `BCryptoGroupCallManager.
    /// sendGroupCallMuteRequest`'s kdoc). Flat, non-admin-gated by design:
    /// any participant can target any other current participant — the
    /// server enforces the only real gate.
    func requestMute(participantId: String) {
        manager.sendGroupCallMuteRequest(targetId: participantId)
    }

    /// Item 5: toggle between gallery (today's existing grid) and speaker
    /// (pinned active-speaker spotlight) layout. Pure client-side state,
    /// no wire message.
    func toggleLayoutMode() {
        layoutMode = layoutMode == .gallery ? .speaker : .gallery
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
        // W-GRPEND-CREATOR (2026-07-20, live incident): this used to call
        // endCallForAll() UNCONDITIONALLY — every iOS participant's red
        // hang-up button terminated the call for the whole roster (live
        // repro: a non-creator iPad hung up and the 5-way call died for
        // everyone). Android's "Termina" and Desktop's hang-up both send
        // group_call_leave; iOS was the only platform sending
        // group_call_end. Hang-up now LEAVES (server also gates end on the
        // creator since the same incident, downgrading a non-creator's end
        // to leave — this client fix makes the intent explicit rather than
        // relying on the server downgrade). endCallForAll() remains
        // available for a future explicit creator-only "end for all" UI.
        if let controller = controller {
            controller.leave()
        } else {
            manager.leaveGroupCall()
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
