import SwiftUI
import QAudionEngine

/// Bridge between the live `AppState` + `CallService` and the new
/// `InCallScreen` design-system view.
///
/// W29 production wiring step. Allows the new InCallScreen to render
/// real call data (peer name, duration, confidence, mute state,
/// recent samples) WITHOUT touching the legacy CallView / InCallView /
/// InCallContainer plumbing — those still own the CallKit + AVAudioSession
/// + video-track mechanics.
///
/// Available live fields (mapped from AppState):
///   - `peerDisplayName`     ← `appState.callContactId` (best-effort lookup
///                              from ContactsStore; falls back to userId)
///   - `durationSeconds`     ← `appState.callService.callDurationSeconds`
///                              (refreshed once per second via TimelineView)
///   - `confidence`          ← `appState.confidenceScore` (@Published, live
///                              feed from deepfake detector)
///   - `recentSamples`       ← `appState.txWaveform` (last N tx samples)
///   - `muted`               ← local @State mirror, set + read by button tap
///   - `transportMode`       ← `.bcryptoWsRelay` if `backendType == "PQC"`
///                              else `.disconnected` (richer mapping when
///                              engine surfaces real transport feedback)
///
/// Stub fields (kept until engine exposes them — see W29 spec from
/// the parallel agent):
///   - `recentSamples` if empty → fallback to confidenceScore-derived
///                                 5-point sparkline
///   - `rekeyInSeconds` / `rekeyTotalSeconds` — fixed 252/300
///   - `sasWords` — empty (panel hidden)
///   - `keyInfo` — nil (panel hidden)
///   - `voiceEnhancement` — local @State only
///   - `speakerOn` — local @State only (real AVAudioSession routing
///                   stays inside legacy InCallView for now)
@MainActor
struct LiveInCallScreen: View {
    @EnvironmentObject var appState: AppState
    // ContactsStore is a plain final class (not ObservableObject) — used
    // as a one-shot lookup helper, not as reactive state.
    private let contactsStore = ContactsStore()

    @State private var muted: Bool = false
    @State private var speakerOn: Bool = false
    @State private var voiceEnhancement: Bool = false

    /// Cached peer display name. Resolved once on appear / on
    /// callContactId change so the contacts-store lookup doesn't run
    /// on every TimelineView tick (OpenRouter review on v1.0.75 flagged
    /// the disk I/O on the main thread). Fallback to "Sconosciuto"
    /// when no peer is bound (e.g. between calls).
    @State private var cachedPeerDisplayName: String = "Sconosciuto"

    /// Reference timestamp (UNIX epoch seconds) used to derive a
    /// counting-down rekey clock until the engine surfaces a real
    /// rekey timer. We anchor it on `.onAppear` and decrement it as
    /// the TimelineView ticks; resets every `rekeyTotalSeconds`.
    private static let rekeyTotalSeconds = 300
    @State private var rekeyAnchorEpoch: TimeInterval = Date().timeIntervalSince1970

    var body: some View {
        // TimelineView refreshes the body once per second so the
        // duration label + sparkline tick without forcing CallService
        // to push @Published updates.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            inCallScreenView
        }
        .overlay(alignment: .topTrailing) {
            // W324: stub disclaimer next to the rekey countdown. The
            // rekey timer rendered inside InCallScreen is a local
            // anchor, not the engine's real next-rekey-ETA. Surface
            // that to testers so a "ticking" 252→0 doesn't look
            // load-bearing.
            stubRekeyDisclaimer
                .padding(.top, 56)
                .padding(.trailing, 12)
        }
        .onAppear {
            resolvePeerDisplayName()
            rekeyAnchorEpoch = Date().timeIntervalSince1970
        }
        .onChange(of: appState.callContactId) { _ in
            // Re-resolve when the call peer changes (e.g. switching
            // between successive calls on the same showcase entry).
            resolvePeerDisplayName()
        }
    }

    // MARK: - Sub-views (extracted to keep TimelineView body shallow,
    //                   per SWIFT6_PATTERNS §5/§6).

    /// W324: composing all the InCallScreen args inline used to be a
    /// 22-arg call inside a TimelineView closure — wrapping it in a
    /// computed property keeps the type-checker scope clean.
    @ViewBuilder
    private var inCallScreenView: some View {
        InCallScreen(
                peerDisplayName: cachedPeerDisplayName,
                avatarUrl: nil,
                durationSeconds: Int(appState.callService.callDurationSeconds),
                confidence: Double(appState.confidenceScore),
                recentSamples: liveSamples,
                rekeyInSeconds: liveRekeyInSeconds,
                rekeyTotalSeconds: Self.rekeyTotalSeconds,
                pqcActive: appState.backendType == "PQC",
                // W339: real SAS from ComputeSasUseCase — derived from
                // appState.callPqcSessionKey when set by the call setup
                // path. While the key is nil (current state in most
                // builds) the array is empty and the panel hides.
                sasWords: appState.callSasWords,
                // W368: surface SAS verification persistence — if the
                // user already confirmed coincidence with this peer
                // for the current SAS-words fingerprint, render the
                // panel as VERIFIED and disable the confirm button.
                sasVerified: liveSasVerified,
                keyInfo: nil,
                transportMode: liveTransportMode,
                muted: liveMuted,
                speakerOn: speakerOn,
                voiceEnhancement: voiceEnhancement,
                onToggleMute: {
                    // Source of truth = CallService.isMuted. We flip it
                    // via AppState.setMuted then re-read; the @State
                    // mirror updates on the next tick anyway, but
                    // toggling locally first avoids one frame of
                    // visual lag.
                    let next = !appState.callService.isMuted
                    muted = next
                    appState.setMuted(next)
                },
                onToggleSpeaker: {
                    speakerOn.toggle()
                    appState.setSpeaker(speakerOn)
                },
                onToggleVoiceEnhancement: {
                    voiceEnhancement.toggle()
                    // Real audio-processing flag will land when the engine
                    // exposes a voice-enhancement toggle. For now this
                    // is UI-only.
                },
                onAddParticipant: {
                    // 1:1 call → no-op placeholder. Group calling has
                    // its own GroupCallScreen surface.
                },
                onHangup: {
                    appState.endCall()
                },
                onConfirmSas: {
                    // W368: persist the SAS confirmation under the
                    // current peer + words fingerprint so the next
                    // call between the same pair starts pre-verified.
                    let words = appState.callSasWords
                    guard !words.isEmpty,
                          let peer = appState.callContactId else { return }
                    let fp = SasVerificationStore.fingerprint(forWords: words)
                    SasVerificationStore.shared.recordVerified(
                        peerUserId: peer, fingerprint: fp)
                }
            )
    }

    /// W324: tiny "DEMO" badge anchored to the top-trailing corner.
    /// Italian copy. Static formatting (no closures, no multi-segment
    /// interpolation) per SWIFT6_PATTERNS §1.
    @ViewBuilder
    private var stubRekeyDisclaimer: some View {
        Text(Self.stubRekeyText)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().stroke(Color.orange.opacity(0.6), lineWidth: 1)
            )
            .accessibilityLabel("Rekey demo, contatore non collegato al motore")
    }

    /// W324: static helper — keep the literal out of @ViewBuilder.
    private static let stubRekeyText: String = "REKEY DEMO"

    // MARK: - Derived state

    /// Always re-reads `CallService.isMuted` so external mute changes
    /// (Bluetooth headset, programmatic) propagate to the UI on each
    /// TimelineView tick. The local `@State muted` mirror is still
    /// updated on tap to avoid a one-frame flicker.
    private var liveMuted: Bool {
        appState.callService.isMuted
    }

    /// W368: live SAS verification flag. Returns true iff the
    /// SasVerificationStore has the current SAS words' fingerprint
    /// stored under the call's peer id. Computed every TimelineView
    /// tick — cheap (one UserDefaults string read).
    private var liveSasVerified: Bool {
        let words = appState.callSasWords
        guard !words.isEmpty,
              let peer = appState.callContactId else { return false }
        let fp = SasVerificationStore.fingerprint(forWords: words)
        return SasVerificationStore.shared.isVerified(
            peerUserId: peer, currentFingerprint: fp)
    }

    private func resolvePeerDisplayName() {
        guard let id = appState.callContactId else {
            cachedPeerDisplayName = "Sconosciuto"
            return
        }
        let stored = contactsStore.load()
        if let match = stored.first(where: { $0.userId == id }) {
            cachedPeerDisplayName = match.displayName
        } else {
            // Fallback: trim "user-" prefix if present.
            cachedPeerDisplayName = id.hasPrefix("user-")
                ? String(id.dropFirst(5)).capitalized
                : id
        }
    }

    /// Stub rekey countdown derived from a local anchor. Counts down
    /// 300→0 then loops back to 300 — purely visual until the engine
    /// exposes the real next-rekey timer (see W29 GAP analysis).
    private var liveRekeyInSeconds: Int {
        let elapsed = Int(Date().timeIntervalSince1970 - rekeyAnchorEpoch)
        let inWindow = ((elapsed % Self.rekeyTotalSeconds) + Self.rekeyTotalSeconds)
            % Self.rekeyTotalSeconds
        return Self.rekeyTotalSeconds - inWindow
    }

    /// Live samples for the SessionStatusStrip mini-spark inside InCallScreen.
    /// Prefers the engine's `txWaveform` feed when populated; falls back to
    /// a 5-point sparkline derived from `confidenceScore` so the panel
    /// renders something meaningful even before any audio is captured.
    private var liveSamples: [Float] {
        let tx = appState.txWaveform
        if !tx.isEmpty {
            // Downsample / take the last 16 points for the strip.
            let suffix = tx.suffix(16)
            return Array(suffix)
        }
        // Confidence-derived stub series (slowly drifts ±5%).
        let c = max(0.05, min(1.0, appState.confidenceScore))
        return [c, c * 0.98, c * 1.02, c * 0.99, c, c * 1.03, c * 0.97, c]
    }

    private var liveTransportMode: InCallScreen.TransportMode {
        switch appState.backendType {
        case "PQC":  return .p2pSrtp
        case "BCR":  return .bcryptoWsRelay
        case "STD":  return .turn
        default:     return .disconnected
        }
    }
}

#Preview {
    LiveInCallScreen()
        .environmentObject({
            let s = AppState()
            s.callContactId = "user-mario"
            s.confidenceScore = 0.92
            s.backendType = "PQC"
            s.isInCall = true
            return s
        }())
        .qAudionTheme(dark: true)
}
