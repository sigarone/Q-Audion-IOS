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
    /// M3 — the participant whose identity verification the "unverified participants" banner opened
    /// (nil while no sheet is up). Identifiable so `.sheet(item:)` can drive it.
    @State private var verificationTarget: VerificationTarget?

    private struct VerificationTarget: Identifiable {
        let id: String
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chiamata di gruppo")
                            .font(.headline).foregroundColor(.white)
                        // 2026-07-29 fix (Pavel: answering a group call shows
                        // "0 partecipanti" — a real, physically-accurate
                        // count during the genuine window between screen
                        // presentation and the roster's first
                        // `group_call_update` WS reply, which is a SEPARATE
                        // signal from the media connect — see
                        // `onParticipantsChanged`.
                        // Say so instead of showing a number that reads as
                        // "the room is empty" when it's actually just not
                        // loaded yet.
                        Text(viewModel.participants.isEmpty
                             ? "Connessione…"
                             : "\(viewModel.participants.count) partecipanti")
                            .font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                    if viewModel.callState == .active {
                        Text(viewModel.elapsedTime)
                            .font(.caption).monospacedDigit()
                            .foregroundColor(Color(red: 0, green: 0.9, blue: 0.47))
                    }
                    // Item 5 (2026-07-16 wire contract) — pure client-side
                    // layout toggle, no wire message at all (the engine's
                    // active-speaker detection, wired through
                    // `GroupCallController.onActiveSpeakersChanged`). Placed
                    // in the header rather than the already-crowded control
                    // bar below; icon shows the CURRENT layout, same
                    // current-state-not-destination convention as every
                    // control-bar toggle (mute/video) below.
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

                // M3 — at least one participant is not verified: say so, and offer the verification of
                // the first one. Never hides on its own; it goes away when the verification is done.
                if viewModel.verification.showsBanner {
                    unverifiedBanner
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                }

                // W-GRPSCREENSHARE: spotlight tile for whichever remote
                // participant is currently sharing their screen — rendered
                // full-width, ABOVE the regular participant grid, so a
                // shared screen reads with visual priority over the small
                // per-participant tiles (mirrors the common Meet/Zoom
                // pattern: shared content dominates, faces stay small).
                // Simple policy: if more than one participant is somehow
                // sharing at once, this shows whichever one appears FIRST in
                // `participants` — the server-side call model doesn't
                // arbitrate concurrent shares, so ties are not expected in
                // practice. Only remote shares are rendered: sharing the
                // screen from iOS is not offered in group calls.
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
                // kdoc for where the speaker comes from.
                if viewModel.layoutMode == .speaker,
                   let speakerId = viewModel.currentSpeakerId,
                   let speaker = viewModel.participants.first(where: { $0.id == speakerId }) {
                    ParticipantTile(
                        participant: speaker,
                        isPinned: true,
                        isSelf: speaker.id == viewModel.selfUserId,
                        localMuted: viewModel.isMuted,
                        reactionEmoji: viewModel.latestReactionEmoji(for: speaker.id),
                        onRequestMute: { viewModel.requestMute(participantId: speaker.id) },
                        showsUnverifiedBadge: viewModel.verification.isUnverified(speaker.id)
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
                    // W-GRPVIEWPORT: exactly which identities this grid is
                    // ACTUALLY rendering right now — the visibility signal
                    // `updateVideoViewport` needs, read straight off the
                    // pagination state this view already maintains for
                    // layout, no separate tracking required. `.speaker`
                    // mode's pinned spotlight tile lives OUTSIDE `pages`
                    // entirely (`gridParticipants` excludes it, see that
                    // property's kdoc), so it's threaded in as its own
                    // value rather than folded into `visibleIds`.
                    let visibleIds = Set((pages.indices.contains(currentGridPage) ? pages[currentGridPage] : []).map(\.id))
                    let spotlightId = viewModel.layoutMode == .speaker ? viewModel.currentSpeakerId : nil
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
                                                localMuted: viewModel.isMuted,
                                                reactionEmoji: viewModel.latestReactionEmoji(for: participant.id),
                                                onRequestMute: { viewModel.requestMute(participantId: participant.id) },
                                                tileSize: CGSize(width: layout.tileW, height: layout.tileH),
                                                showsUnverifiedBadge: viewModel.verification.isUnverified(participant.id)
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
                    // W-GRPVIEWPORT: `.task(id:)` runs once immediately (the
                    // initial page/roster, before any `.onChange` would ever
                    // fire) AND again every time `visibleIds`/`spotlightId`
                    // actually change (page swipe, roster change reshuffling
                    // pages, `.speaker` pin moving) — exactly the "set now +
                    // resync on change" shape this needs, cancelling any
                    // in-flight previous call the way `.task(id:)` always
                    // does. `VideoViewportKey` (below) is a plain
                    // `Set<String>` + `String?` pair so SwiftUI can diff it.
                    .task(id: VideoViewportKey(visible: visibleIds, spotlight: spotlightId)) {
                        viewModel.updateVideoViewport(visible: visibleIds, spotlight: spotlightId)
                    }
                }
                .padding(.horizontal, 16)

                // Control bar — responsive sizing (2026-07-20, live 5-way
                // call 694147de): the old fixed `HStack(spacing: 32)` of
                // 56pt circles needed ~584pt for the full 7-button row
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
                    // mute, camera (once the media link exists), hand,
                    // reaction, chat, end.
                    let buttonCount = CGFloat(viewModel.isMediaReady ? 6 : 5)
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

            // W-GRPSELFGRID (2026-07-20, live 2-way call 3A5A03DE) — REMOVED
            // the old "W-GRPVIDEO self-preview PiP" floating overlay that
            // used to live here. Root cause of the reported "iOS shows its
            // own video as a separate disconnected mirror instead of a
            // participant like Android does": the "Tu" (self) entry has
            // always existed inside `viewModel.participants` (seeded by
            // `BCryptoGroupCallManager._participants = [Participant(id:
            // selfUserId, displayName: "Tu")]` and confirmed present in every
            // server `group_call_update` roster since), so it always rendered
            // as a real tile in the SAME grid as remote participants below —
            // but that tile's `videoTrack` was never populated (only
            // `viewModel.selfVideoTrack` was, feeding exclusively this now-
            // removed PiP), so the grid tile stayed a blank avatar while the
            // REAL live camera floated in its own corner box outside the
            // shared grid entirely. Android's `GroupCallScreen.ParticipantTile`
            // call site has no equivalent PiP — it swaps `localVideoTrack`
            // straight into the SAME tile (`videoTrack = if (uid == selfId)
            // localVideoTrack else remoteVideoTracks[uid]`). Fixed by
            // `GroupCallViewModel.onLocalVideoTrack` now writing straight
            // into `participants[idx].videoTrack` for the self entry (see
            // its kdoc), so `ParticipantTile`'s existing `isSelf` rendering
            // (highlighted border) is now paired with the live feed itself,
            // in the grid, matching Android — no separate view needed here.
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
        .onAppear {
            // SECURITY H-18: the group call surface renders per-participant
            // verification state + peer identity. Same secure-window
            // lifecycle as LiveInCallScreen / VideoCallView.
            ScreenshotLockService.lock()
            refreshChatUnreadCount()
            viewModel.refreshVerification(force: true)
        }
        .onDisappear {
            // Unconditional unlock, same pattern as LiveInCallScreen.
            ScreenshotLockService.unlock()
        }
        // M3 — the verification of one participant, opened from the banner. The contact screen is the
        // app's existing verification surface (safety number, SAS, in-person); when it closes, the
        // verification state is read again so a badge and the banner clear at once.
        .sheet(item: $verificationTarget, onDismiss: { viewModel.refreshVerification(force: true) }) { target in
            ContactDetailScreen(item: verificationItem(for: target.id))
        }
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
        // W-GRPVIDEOPUBFIX — same one-shot snackbar idiom as
        // `muteRequestToastText` above, `.error` severity (see
        // `videoPublishErrorToastText`'s kdoc for what sets it — a refused
        // camera; the call itself continues audio-only).
        .onChange(of: viewModel.videoPublishErrorToastText) { text in
            guard let text else { return }
            snackbar?.show(.init(text: text, severity: .error))
            viewModel.videoPublishErrorToastText = nil
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
            .accessibilityLabel(viewModel.isMuted ? "Riattiva microfono" : "Disattiva microfono")

            // W-GRPVIDEO: camera on/off. Shown once the call has a media
            // link (`isMediaReady`) — before that there is no publisher to
            // toggle. Works whether the call started as audio or video:
            // switching the camera on mid-call needs no renegotiation (see
            // `GroupCallController.setVideoEnabled`'s kdoc).
            if viewModel.isMediaReady {
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
                .accessibilityLabel(viewModel.isVideoEnabled ? "Disattiva video" : "Attiva video")
            }

            // Item 1 (2026-07-16 wire contract) — raise/lower
            // hand, state-dependent background color exactly like
            // the mute button above (`Color.red.opacity(0.3)`
            // muted / `Color.white.opacity(0.15)` unmuted) — same
            // pattern, orange being the raised-hand's own semantic
            // (distinct from mute's red)
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
            .accessibilityLabel("Termina chiamata")
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
        // Single stable pass (was two `filter` passes, each re-reading the
        // @Published set per element): same partition, same relative order.
        let activeIds: Set<String> = viewModel.activeSpeakerIds
        var speaking: [GroupCallViewModel.ParticipantUI] = []
        var resting: [GroupCallViewModel.ParticipantUI] = []
        for participant in base {
            if activeIds.contains(participant.id) {
                speaking.append(participant)
            } else {
                resting.append(participant)
            }
        }
        return speaking + resting
    }

    /// 2026-07-17 — splits the (already speaker-sorted) `gridParticipants`
    /// into pages of at most `pageCapacity` each, for the `TabView(.page)`
    /// pager above. A page with fewer participants than capacity still
    /// gets full-size tiles via `adaptiveGridLayout` (capacity is a
    /// CEILING per page, not a per-page target).
    private func gridPages(pageCapacity: Int) -> [[GroupCallViewModel.ParticipantUI]] {
        // Evaluate the (filter + partition) computed property ONCE — the
        // previous body re-ran it up to five times per call.
        let all: [GroupCallViewModel.ParticipantUI] = gridParticipants
        guard pageCapacity > 0, !all.isEmpty else { return all.isEmpty ? [] : [all] }
        return stride(from: 0, to: all.count, by: pageCapacity).map {
            Array(all[$0..<min($0 + pageCapacity, all.count)])
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

    /// W-GRPVIEWPORT: `.task(id:)`'s identity value for the visible-tile
    /// tracking above — plain `Equatable`/`Hashable` data (a `Set<String>`
    /// + a `String?`) so SwiftUI can diff it and only re-run
    /// `updateVideoViewport` when what's actually on-screen changes.
    private struct VideoViewportKey: Equatable, Hashable {
        let visible: Set<String>
        let spotlight: String?
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

    /// M3 — short banner shown while at least one participant is not verified. The action opens the
    /// verification of the first unverified participant (roster order).
    private var unverifiedBanner: some View {
        let state = viewModel.verification
        let firstId = state.firstUnverifiedId
        let firstName = firstId.flatMap { id in viewModel.participants.first(where: { $0.id == id })?.displayName } ?? ""
        let message = state.count == 1
            ? String(localized: "group_call.unverified_banner.one",
                     defaultValue: "Un partecipante non è verificato",
                     comment: "Group call banner — exactly one participant has not been verified (no SAS confirmation, no in-person pairing)")
            : String(localized: "group_call.unverified_banner.many",
                     defaultValue: "\(state.count) partecipanti non sono verificati",
                     comment: "Group call banner — several participants have not been verified; %lld is how many")
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
            Text(message)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let firstId {
                Button {
                    verificationTarget = VerificationTarget(id: firstId)
                } label: {
                    Text(String(localized: "group_call.unverified_banner.action",
                                defaultValue: "Verifica",
                                comment: "Group call banner — button that opens the identity verification of the first unverified participant"))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(Capsule().stroke(Color.orange.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "group_call.unverified_banner.action_a11y",
                                           defaultValue: "Apri la verifica dell'identità di \(firstName)",
                                           comment: "Group call banner — accessibility label of the verify button; %@ is the display name of the participant it opens"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// M3 — the contact-list row the contact screen needs, from the stored contact when there is one
    /// and from the roster otherwise (a participant who is not a contact still opens the screen).
    private func verificationItem(for userId: String) -> ContactsListViewModel.Item {
        let stored = ContactsStore().load().first(where: { $0.userId == userId })
        let rosterName = viewModel.participants.first(where: { $0.id == userId })?.displayName
        return ContactsListViewModel.Item(
            userId: userId,
            displayName: rosterName ?? DisplayName.forUser(userId),
            phoneHash: stored?.phoneHash ?? "",
            avatarUrl: stored?.avatarUrl,
            isOnline: false,
            unreadMessageCount: 0,
            isVerified: stored?.isVerified ?? false,
            extension: stored?.`extension`)
    }

    /// Unified call UI (group-call adaptation) — same "chip row ending in
    /// a shield button" shape as `InCallScreen.trustBar` (see that file's
    /// header comment for the full 1:1 pattern). Always visible, never
    /// covers the participant grid; tapping the shield opens
    /// `GroupSecuritySheet`. Chips shown are group-call constants (every
    /// group call runs over DTLS 1.3 with the hybrid X25519MLKEM768 and
    /// carries AES-256-GCM content E2EE — see `GroupSecuritySheet.
    /// overviewBody`) rather than per-call conditionals like the
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
    /// W-GRPSELFMUTE (2026-07-24) — the LOCAL mic authority, for the self tile
    /// only. `participant.isMuted` comes from the WS roster, which moves only
    /// when WE call `manager.toggleMute()`; a mute applied because ANOTHER
    /// participant requested it deliberately does not touch the roster (see
    /// `onMuteRequested`), so our own tile kept showing an un-muted mic while
    /// the mic was genuinely muted. Remote tiles keep using the roster: it is
    /// the only thing we know about them.
    var localMuted: Bool = false
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
    /// M3 — this participant is not verified (no confirmed SAS pin, no in-person pairing): the tile
    /// carries a "Non verificato" badge. Never set for the local participant.
    var showsUnverifiedBadge: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let track = participant.videoTrack {
                    GroupCallVideoView(track: track, mirrored: isSelf)
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

            if showsUnverifiedBadge {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(String(localized: "group_call.unverified_badge",
                                defaultValue: "Non verificato",
                                comment: "Group call participant tile — badge: this participant's identity has not been verified (no SAS confirmation, no in-person pairing)"))
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(Color.orange)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "group_call.unverified_badge_a11y",
                                           defaultValue: "\(participant.displayName): identità non verificata",
                                           comment: "Group call participant tile — accessibility label of the unverified badge; %@ is the participant's display name"))
            }

            if isSelf ? localMuted : participant.isMuted {
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
            return max(24, tileSize.height - Self.chromeReserve - (showsUnverifiedBadge ? Self.badgeReserve : 0))
        }
        if isPinned { return participant.videoTrack != nil ? 220 : 140 }
        return participant.videoTrack != nil ? 120 : 64
    }

    private static let chromeReserve: CGFloat = 50
    /// Extra height the unverified badge row takes below the name.
    private static let badgeReserve: CGFloat = 22
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

// MARK: - Verification state (M3)

/// Reads the app's existing verification stores for a group-call roster: the contact rows, the persisted
/// SAS confirmations (bound to the pinned identity keys) and the peer pins. The decision itself is the
/// engine's `GroupParticipantVerification` (unit-tested there).
enum GroupVerificationResolver {
    static func state(participantIds: [String], selfId: String) -> GroupVerificationState {
        let contacts = Dictionary(
            ContactsStore().load().map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        let pins = PeerIdentityPinStore()
        let sas = SasVerificationStore.shared
        return GroupVerificationState(participantIds: participantIds, selfId: selfId) { id in
            GroupParticipantVerification.isVerified(
                contact: contacts[id],
                sasBinding: sas.storedBinding(peerUserId: id),
                pinnedKeys: pins.allPinnedKeys(contactId: id))
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
        /// W-GRPVIDEO: type-erased WebRTC video track (the app layer never
        /// imports the WebRTC module) — nil until the engine delivers this
        /// participant's camera; cleared again when the stream goes away or
        /// the participant leaves. Rendered via `GroupCallVideoView`.
        var videoTrack: AnyObject? = nil
        /// W-GRPSCREENSHARE: type-erased WebRTC video track for this
        /// participant's SCREEN-SHARE stream — kept SEPARATE from
        /// `videoTrack` (camera) since a participant can publish both at
        /// once (see `GroupCallController.onRemoteScreenShareTrack`'s
        /// kdoc). Nil until delivered / after the share stops.
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
    /// M3 — who in this call is not verified (drives the tile badges and the banner). Recomputed when the
    /// roster's membership changes, when the contacts change, and on `refreshVerification(force: true)`.
    @Published private(set) var verification = GroupVerificationState()
    /// Resolves the verification state of a roster from the app's stores; replaceable in tests.
    var verificationResolver: (_ participantIds: [String], _ selfId: String) -> GroupVerificationState =
        GroupVerificationResolver.state
    private var verifiedRosterIds: [String] = []
    private var contactsObserver: NSObjectProtocol?
    @Published var callState: BCryptoGroupCallManager.State = .idle
    @Published var isMuted = false
    @Published var elapsedTime = "0:00"
    /// W-GRPVIDEO: our own camera preview (type-erased WebRTC video track),
    /// nil when off. W-GRPSELFGRID (2026-07-20): `GroupCallView.body` no
    /// longer renders this directly (the removed self-preview PiP) — the
    /// same track is now also written into `participants[selfIdx].videoTrack`
    /// (see `onLocalVideoTrack` below) so the grid tile is the one live
    /// consumer. Kept as its own published slot rather than removed outright:
    /// it is the raw signal `onLocalVideoTrack` writes into both places from,
    /// and a future non-grid surface (e.g. a picture-in-picture mode) may
    /// still want it directly.
    @Published var selfVideoTrack: AnyObject? = nil
    /// W-GRPVIDEO: mirrors whether OUR camera is currently publishing —
    /// seeded from the call's `callType` on the `.active` transition
    /// (`GroupCallController.wantsVideo`, surfaced via `callWantsVideo`),
    /// then flipped by `toggleVideo()`.
    /// W-GRPCAMSRC (2026-07-24) — DERIVED from the camera track the engine is
    /// actually publishing for us, never from "was this call created as a video
    /// call". It used to be seeded on `.active` from `controller.callWantsVideo`
    /// and thereafter moved only by our own button, so joining a video-typed
    /// group call painted the camera button ON before (or without) any capture
    /// ever being published — the group-call twin of the 1:1 `isVideoCall`
    /// defect fixed the same day (W-CAMBTNSRC).
    ///
    /// `selfVideoTrack` is written by `controller.onLocalVideoTrack`, which
    /// the engine fires with the track once capture runs and with nil when it
    /// stops — nil exactly when the camera is off. Deriving costs one lag: the
    /// button follows the track landing rather than the tap. That is the point.
    var isVideoEnabled: Bool { selfVideoTrack != nil }
    /// Whether the call has a media link (`GroupCallController.hasMediaLink`,
    /// connecting or connected): gates the camera button, since there is no
    /// publisher to toggle before it. Refreshed on every manager state change,
    /// on every roster update and from `controller.onMediaConnected`.
    @Published var isMediaReady = false
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
    /// (user ids, loudest first, computed by the engine from decoded audio
    /// levels) — see `currentSpeakerId`'s kdoc for the roster fallback.
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
    /// W-GRPVIDEOPUBFIX (2026-09-29): one-shot toast for a camera problem
    /// (`GroupCallMediaError.cameraPermissionDenied` / `.cameraUnavailable`,
    /// reported by `GroupCallController.setVideoEnabled` through
    /// `onMediaError`, whether from `toggleVideo()` or from the initial
    /// video-call publish), so the user sees SOME explanation instead of the
    /// video button silently staying off (see `toggleVideo()`'s kdoc). The
    /// call itself continues audio-only. Same one-shot set-then-clear idiom
    /// as `muteRequestToastText` above; `.error` severity distinguishes it
    /// from that `.info` toast.
    @Published var videoPublishErrorToastText: String? = nil
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
    /// purposes: the loudest user of `GroupCallController.
    /// onActiveSpeakersChanged` (engine-side, from decoded audio levels), or
    /// — when the engine reports nobody — the first roster entry whose
    /// `isSpeaking` flag is set (the flag that already rings a tile's border).
    var currentSpeakerId: String? {
        activeSpeakerId ?? participants.first(where: { $0.isSpeaking })?.id
    }
    /// Item 3: the freshest still-live reaction for one participant, or
    /// nil if none is currently displayed.
    func latestReactionEmoji(for participantId: String) -> String? {
        reactionEvents.last(where: { $0.senderId == participantId })?.emoji
    }

    /// W-GRPVIEWPORT: called by `GroupCallView` (via `.task(id:)`, so once
    /// immediately + again on every real change) with the identities
    /// currently on the visible grid page and the current `.speaker`-mode
    /// spotlight identity, if any — `GroupCallView`'s own existing
    /// `gridPages`/`currentGridPage` pagination state already tracks
    /// exactly this, no new visibility plumbing needed on that side. Fans
    /// each participant out to `GroupCallController.
    /// setRemoteVideoRenderPriority` (which picks the simulcast substream and
    /// the subscription of that tile, spec §4.6), skipping our own entry (no
    /// remote publication exists for the local tile).
    func updateVideoViewport(visible: Set<String>, spotlight: String?) {
        guard let controller else { return }
        for participant in participants where participant.id != selfUserId {
            let priority: RemoteVideoRenderPriority
            if participant.id == spotlight {
                priority = .onScreenSpotlight
            } else if visible.contains(participant.id) {
                priority = .onScreenSmall
            } else {
                priority = .offScreen
            }
            controller.setRemoteVideoRenderPriority(identity: participant.id, priority: priority)
        }
    }

    private let manager: BCryptoGroupCallManager
    /// The `GroupCallController` that owns the media path. When set, mute
    /// toggles, camera and end-call route through it; falls back to direct
    /// manager calls if nil (legacy preview path).
    private let controller: GroupCallController?
    /// The call clock behind `elapsedTime`: starts once, whichever thread reports `.active` (see
    /// `GroupCallElapsedTimer`).
    private let elapsedTimer = GroupCallElapsedTimer()
    /// Item 3: local mirror of `GroupCallController.raisedHands`, used to
    /// seed each `ParticipantUI.handRaised` when the roster rebuilds in
    /// `onParticipants` below (that closure only ever has the fresh
    /// `[Participant]` list from the manager, not the controller's
    /// separate raised-hand set, so this cache bridges the two).
    private var raisedHandsCache: Set<String> = []
    /// Roster/track race: `manager.onParticipantsChanged` (WS control-plane
    /// roster) and `controller.onRemoteVideoTrack`/`onRemoteScreenShareTrack`
    /// (media plane, over Janus) are two INDEPENDENT event streams over two
    /// different transports — there is no ordering guarantee between them. In
    /// a bigger call (roster broadcast fan-out takes longer with more
    /// members) the media layer can deliver a remote track for a user before
    /// this device's roster lists that participant yet; that used to just drop
    /// the track on the floor forever (only the roster-rebuild's
    /// `existingTracks` dictionary carries a track forward, and a track that
    /// was never attached in the first place isn't in it). These two caches
    /// hold a track that arrived with no matching tile YET, so the very next
    /// roster rebuild in `onParticipants` below can attach it instead of
    /// silently losing it. A nil track (stream gone) removes the entry.
    private var pendingVideoTracks: [String: AnyObject] = [:]
    private var pendingScreenShareTracks: [String: AnyObject] = [:]

    init(manager: BCryptoGroupCallManager, controller: GroupCallController? = nil) {
        self.manager = manager
        self.controller = controller
        // The clock delivers on the main queue (`GroupCallElapsedTimer.onChange`).
        elapsedTimer.onChange = { [weak self] text in self?.elapsedTime = text }

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
                // W-GRPCAMSRC — `isVideoEnabled` is derived from
                // `selfVideoTrack` now; nothing to seed. `callWantsVideo`
                // only ever said what the call was CREATED as.
                if state == .ended {
                    self.isMediaReady = false
                    // This ViewModel is long-lived across calls (same
                    // rationale as `activeGroupId` below): a track cached for
                    // a user of THIS call must not attach to a later call.
                    self.pendingVideoTracks.removeAll()
                    self.pendingScreenShareTracks.removeAll()
                } else {
                    // The camera button follows the media link, which
                    // appears after the call state does; `onMediaConnected`
                    // (below) covers the connect itself.
                    self.isMediaReady = controller?.hasMediaLink ?? false
                }
            }
            if state == .active { self?.elapsedTimer.start() }
            if state == .ended {
                self?.elapsedTimer.stop()
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
                // The server's roster is authoritative: qjanus removes a ghost
                // (a member whose signaling is gone) from the Janus room
                // itself, so `participants` is exactly this list — no tile is
                // ever synthesized from the media plane.
                self.participants = list.map { entry in
                    // Roster/track race fix (see `pendingVideoTracks`' kdoc):
                    // a track that arrived before this identity had a tile
                    // gets attached NOW, on the roster refresh that finally
                    // introduces that tile, instead of staying lost.
                    //
                    // W-GRPSELFGRID (2026-07-20): the self entry never goes
                    // through `pendingVideoTracks` (that dictionary is only
                    // ever written by `onRemoteVideoTrack`, which the engine
                    // never fires for our own identity) — fall back to
                    // `self.selfVideoTrack` directly for `entry.id ==
                    // selfUserId` so a roster broadcast introducing this
                    // entry for the FIRST time (e.g. a callee joining via
                    // `joinGroupCall`, which — unlike `createGroupCall` —
                    // does not pre-seed a "Tu" row) still picks up an
                    // already-published camera track instead of rendering a
                    // blank tile until the next roster refresh.
                    let video: AnyObject?
                    if entry.id == self.selfUserId {
                        video = existingTracks[entry.id] ?? self.selfVideoTrack
                    } else {
                        video = existingTracks[entry.id] ?? self.pendingVideoTracks.removeValue(forKey: entry.id)
                    }
                    let screenShare = existingScreenShareTracks[entry.id] ?? self.pendingScreenShareTracks.removeValue(forKey: entry.id)
                    return ParticipantUI(id: entry.id, displayName: entry.displayName,
                                  isMuted: entry.isMuted, isSpeaking: entry.isSpeaking,
                                  videoTrack: video,
                                  screenShareTrack: screenShare,
                                  handRaised: self.raisedHandsCache.contains(entry.id))
                }
                self.refreshVerification()
                self.refreshMediaReady()
            }
        }
        if let controller = controller {
            // W-GRPUI: `manager.onStateChanged`/`onParticipantsChanged` are
            // single-slot closures already owned by `controller` (it needs
            // them for the audio-pipeline lifecycle) — observe its
            // passthrough instead of overwriting them directly.
            controller.onManagerStateChanged = onState
            controller.onParticipantsChanged = onParticipants
            // W-GRPVIDEO: bind the media track callbacks here (rather than in
            // AppState) — this ViewModel is the render target, and
            // `onRemoteVideoTrack`/`onLocalVideoTrack` are single-slot
            // closures on the controller just like the two above, so the same
            // "bind once, here" pattern applies. A nil track means the
            // stream went away.
            controller.onRemoteVideoTrack = { [weak self] identity, track in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard let idx = self.participants.firstIndex(where: { $0.id == identity }) else {
                        // Roster/track race (see `pendingVideoTracks`'s kdoc):
                        // hold the track instead of dropping it — the next
                        // `onParticipants` roster refresh will attach it (a
                        // nil track removes the cached entry).
                        print("[GroupCallController][telemetry] remote video track for identity=\(identity.prefix(8)) has NO matching participant tile yet (roster race) — cached pending roster catch-up")
                        self.pendingVideoTracks[identity] = track
                        return
                    }
                    let verb = track == nil ? "cleared from" : "bound to"
                    print("[GroupCallController][telemetry] remote video track \(verb) tile identity=\(identity.prefix(8))")
                    self.participants[idx].videoTrack = track
                }
            }
            controller.onLocalVideoTrack = { [weak self] track in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.selfVideoTrack = track
                    // W-GRPSELFGRID (2026-07-20): route our own live camera
                    // into the SAME grid tile every remote participant
                    // renders through, instead of leaving that tile's
                    // `videoTrack` permanently nil and showing the live feed
                    // only in a disconnected floating PiP (see `GroupCallView.
                    // body`'s removed self-preview overlay for the incident
                    // this closes). Mirrors Android's `GroupCallScreen.
                    // ParticipantTile` call site exactly: `videoTrack = if
                    // (uid == selfId) localVideoTrack else remoteVideoTracks[uid]`.
                    // `track` is nil-able (camera can also turn back off
                    // mid-call), so this both attaches AND clears in lockstep
                    // with `selfVideoTrack` above.
                    if let idx = self.participants.firstIndex(where: { $0.id == self.selfUserId }) {
                        self.participants[idx].videoTrack = track
                    }
                }
            }
            // W-GRPSCREENSHARE: same "bind once, here" pattern as
            // `onRemoteVideoTrack`/`onLocalVideoTrack` above — see
            // `GroupCallController.onRemoteScreenShareTrack`'s kdoc. Only a
            // REMOTE share is rendered (spotlight in `GroupCallView.body`);
            // sharing the screen from iOS is not offered in group calls.
            controller.onRemoteScreenShareTrack = { [weak self] identity, track in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard let idx = self.participants.firstIndex(where: { $0.id == identity }) else {
                        // Same roster/track race as `onRemoteVideoTrack` above —
                        // cache it for the next roster refresh instead of
                        // dropping it (a nil track removes the cached entry).
                        self.pendingScreenShareTracks[identity] = track
                        return
                    }
                    self.participants[idx].screenShareTrack = track
                }
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
            // The controller owns the microphone switch: the button, a peer's mute
            // request, CallKit and the state a call BEGINS with (a muted 1:1 call that
            // is promoted to a group starts muted) all reach the button and the self
            // tile through here, and the reset at the end of a call clears a mute this
            // long-lived view model would otherwise carry into the next call.
            controller.onMutedChanged = { [weak self] muted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isMuted = self.manager.setLocalMuted(muted)
                }
            }
            controller.onMuteRequested = { [weak self] requesterId in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Item 4(a): the REAL mute (the mic switch on the media
                    // link) is already applied by
                    // `GroupCallController.handleMuteRequest` before this
                    // callback fires — see that method's kdoc. Here we
                    // only need item 4(b): "update local mute-button UI
                    // state" — this control-bar button's own flag.
                    // The roster's self-entry mute badge follows through the
                    // manager's idempotent setter.
                    self.isMuted = self.manager.setLocalMuted(true)
                    // Item 4(c): one-shot, non-blocking toast — resolve
                    // the requester's display name from the live roster,
                    // falling back to the raw id if it hasn't caught up
                    // yet.
                    // Never fall back to the raw id — resolve through the
                    // central chain (rubrica → "Utente a1b2c3d4…").
                    let displayName = self.participants.first(where: { $0.id == requesterId })?.displayName
                        ?? DisplayName.forUser(requesterId)
                    self.muteRequestToastText = String(localized: "group_call.mute_request_toast", defaultValue: "\(displayName) ti ha silenziato", comment: "Snackbar — one-shot toast shown when another participant force-mutes you in a group call; %@ is the requester's display name")
                }
            }
            // Media errors (spec §2.4 / §8). A camera problem is a soft toast
            // (W-GRPVIDEOPUBFIX: the call continues audio-only). Every other
            // error is fatal: the engine ends the call right after reporting it,
            // which takes this screen down, so `AppState` shows THAT toast from
            // `ContentView` (it outlives the call cover).
            controller.onMediaError = { [weak self] error in
                guard !error.isFatal else { return }
                DispatchQueue.main.async {
                    self?.videoPublishErrorToastText = GroupCallViewModel.toastText(for: error)
                }
            }
            // The media path is up (fires on every (re)connect): the camera
            // can be switched now. Single slot — `AppState` wraps it after this
            // view model is built and keeps calling it.
            controller.onMediaConnected = { [weak self] in
                DispatchQueue.main.async { self?.refreshMediaReady() }
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
        // W-GRPSTALEMGR follow-up: same snapshot-at-bind rationale for the
        // media link — one that already exists when this view model is
        // (re)bound (a mid-call socket rebuild, see `GroupCallController.
        // rebind(manager:)`) would otherwise not show the camera button
        // until the next event.
        isMediaReady = controller?.hasMediaLink ?? false
        // M3 — a verification written elsewhere in the app (a contact verified, a pairing completed) is
        // reflected on the tiles and the banner without waiting for the next roster change.
        contactsObserver = NotificationCenter.default.addObserver(
            forName: .contactsDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshVerification(force: true) }
    }

    deinit {
        if let contactsObserver { NotificationCenter.default.removeObserver(contactsObserver) }
    }

    /// M3 — re-evaluate who is unverified. Skipped when the roster's membership is the one already
    /// evaluated, unless `force` (roster updates also carry speaking/mute flags and arrive often; the
    /// stores are read only when something that can change the answer happened). Main thread only.
    func refreshVerification(force: Bool = false) {
        let ids = participants.map(\.id)
        if !force && ids == verifiedRosterIds { return }
        verifiedRosterIds = ids
        let previous = verification
        verification = verificationResolver(ids, selfUserId)
        // 2026-10-02 — whether the "not verified" banner is up, in the phone log
        // (`grp check verified=<n> count=<remote participants>`, numbers only): the banner
        // is a security notice, and a report of an "error" on the group screen has to be
        // checkable against it.
        if verification != previous || !force {
            let remotes = Set(ids.filter { $0 != selfUserId && !$0.isEmpty }).count
            RTLog.info("group", "grp check verified=\(max(0, remotes - verification.count)) count=\(remotes)")
        }
    }

    /// Re-reads whether the controller has a media link (the camera button's
    /// gate). Main thread only, like every other mutation of published state.
    private func refreshMediaReady() {
        isMediaReady = controller?.hasMediaLink ?? false
    }

    /// The Italian toast text of a media error. Camera problems (shown by this
    /// view model) and the fatal errors (shown by `AppState`, see
    /// `groupCallFatalErrorToastText`) share this one mapping.
    static func toastText(for error: GroupCallMediaError) -> String {
        switch error {
        case .cameraPermissionDenied:
            return String(
                localized: "group_call.camera_permission_denied_toast",
                defaultValue: "Consenti l'accesso alla videocamera in Impostazioni per attivare il video.",
                comment: "Snackbar — one-shot toast shown when the user turns the camera on in a group call but the app has no camera permission; the call itself continues audio-only")
        case .cameraUnavailable:
            return String(
                localized: "group_call.video_publish_failed_toast",
                defaultValue: "Non è stato possibile attivare la videocamera per questa chiamata.",
                comment: "Snackbar — one-shot toast shown when publishing/toggling the local camera in a group call fails at the SDK level; the call itself continues audio-only")
        case .full:
            return String(
                localized: "group_call.media_error.full",
                defaultValue: "La chiamata è piena.",
                comment: "Snackbar — the group call has reached its participant limit; shown when the media server refuses to admit us, the call is then ended")
        case .noNode:
            return String(
                localized: "group_call.media_error.no_node",
                defaultValue: "Nessun server media disponibile.",
                comment: "Snackbar — no media server could be assigned to the group call, the call is then ended")
        case .roomCreateFailed:
            return String(
                localized: "group_call.media_error.room_create_failed",
                defaultValue: "Impossibile creare la stanza media della chiamata.",
                comment: "Snackbar — the media server could not create the room for the group call, the call is then ended")
        case .notMember:
            return String(
                localized: "group_call.media_error.not_member",
                defaultValue: "Non risulti tra i partecipanti di questa chiamata.",
                comment: "Snackbar — the server says we are not a participant of the group call we tried to reach media for, the call is then ended")
        case .entitlementRequired:
            return String(
                localized: "group_call.media_error.entitlement",
                defaultValue: "Le videochiamate di gruppo non sono disponibili per il tuo account.",
                comment: "Snackbar — the server refused to open the media room of the group call because this account does not hold the group-call entitlement; the call is then ended")
        case .transportPolicy:
            return String(
                localized: "group_call.media_error.transport_policy",
                defaultValue: "Connessione non sicura rifiutata: la chiamata è stata terminata.",
                comment: "Snackbar — the media connection did not meet the required security level (DTLS pin or transport policy) and was refused; the call is ended")
        case .mediaLost:
            return String(
                localized: "group_call.media_error.media_lost",
                defaultValue: "Connessione media persa: la chiamata è stata terminata.",
                comment: "Snackbar — the media connection of the group call was lost and could not be recovered; the call is ended")
        case .other:
            return String(
                localized: "group_call.media_error.other",
                defaultValue: "Errore di connessione media: la chiamata è stata terminata.",
                comment: "Snackbar — generic fatal media error of a group call; the call is ended")
        }
    }

    /// The system (CallKit) asked for a mute state: applied through the same path
    /// as the button, and only when it changes something.
    func applyMuteFromSystem(_ muted: Bool) {
        if isMuted != muted { toggleMute() }
    }

    func toggleMute() {
        // `setLocalMuted` (not `toggleMute`): the roster flag follows OUR state, so a mute
        // applied by a peer's request or by CallKit can never be flipped back by the
        // next tap.
        isMuted = manager.setLocalMuted(!isMuted)
        // The roster flag above is what the OTHER participants see; the real
        // mic switch is the controller's (it gates the published audio track).
        controller?.setMuted(isMuted)
        // W-GRPMUTEFIX (item 6, 2026-07-16 wire contract): the button must
        // silence the outbound track, not just the roster badge.
        // `setMicrophoneEnabled` is the async form of the same switch and a
        // no-op (returns false) without a live media link, so firing it
        // unconditionally is safe.
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
    /// idiom as `toggleMute` above. No-op with no controller bound
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

    /// W-GRPVIDEO: flip the local camera. The button follows `selfVideoTrack`
    /// (see `isVideoEnabled`), so a refused camera surfaces only through
    /// `controller.onMediaError` (-> `videoPublishErrorToastText`).
    func toggleVideo() {
        // W-GRPCAMSRC — no optimistic flip and no rollback any more: the button
        // renders `selfVideoTrack != nil`, so a failed `setVideoEnabled` simply
        // never moves it. The old optimistic write could also be left stranded
        // by a camera that stopped publishing for a reason other than this call.
        let target = !isVideoEnabled
        guard let controller = controller else {
            // W-GRPVIDEOTELEM (2026-09-30): no controller bound at all
            // (legacy preview path, or a tap racing view teardown) — the
            // ONE early exit `GroupCallController.setVideoEnabled` can
            // never itself observe, so it has to be logged right here or
            // it leaves no trace anywhere. Tonight's group-call incident
            // (call cd87caee) showed exactly this: no toggle-related log
            // line at all, so a missed tap was indistinguishable from a
            // lost one.
            RTLog.warn("call", "call.media.video_toggle stage=no_controller code=0 target=\(target ? 1 : 0)")
            return
        }
        // W-GRPVIDEOTELEM (2026-09-30): the only record that the tap itself
        // happened — `GroupCallController.setVideoEnabled` reports how the
        // attempt ended (`onMediaError` for a refused camera), but nothing
        // fires at all if this `Task` never runs, so without this "tap" line
        // a dropped tap is indistinguishable from one the user never made.
        RTLog.info("call", "call.media.video_toggle stage=tap code=0 target=\(target ? 1 : 0)")
        Task { _ = await controller.setVideoEnabled(target) }
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
}
