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

    var body: some View {
        // TimelineView refreshes the body once per second so the
        // duration label + sparkline tick without forcing CallService
        // to push @Published updates.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            InCallScreen(
                peerDisplayName: peerDisplayName,
                avatarUrl: nil,
                durationSeconds: Int(appState.callService.callDurationSeconds),
                confidence: Double(appState.confidenceScore),
                recentSamples: liveSamples,
                rekeyInSeconds: 252,
                rekeyTotalSeconds: 300,
                pqcActive: appState.backendType == "PQC",
                sasWords: [],
                sasVerified: false,
                keyInfo: nil,
                transportMode: liveTransportMode,
                muted: muted,
                speakerOn: speakerOn,
                voiceEnhancement: voiceEnhancement,
                onToggleMute: {
                    muted.toggle()
                    appState.setMuted(muted)
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
                }
            )
        }
        .onAppear {
            // Sync local mute mirror to whatever CallService thinks.
            muted = appState.callService.isMuted
        }
    }

    // MARK: - Derived state

    private var peerDisplayName: String {
        guard let id = appState.callContactId else { return "Sconosciuto" }
        // Try a friendly display name from the local contacts store.
        let stored = contactsStore.load()
        if let match = stored.first(where: { $0.userId == id }) {
            return match.displayName
        }
        // Fallback: trim "user-" prefix if present.
        return id.hasPrefix("user-") ? String(id.dropFirst(5)).capitalized : id
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
