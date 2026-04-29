import SwiftUI

/// Dev-mode visual showcase for the W21+W22 call screens. Available
/// from `Settings → System → Call Design Showcase` so the new screens
/// (Incoming, Outgoing, InCall, GroupCall) can be QA'd visually
/// against the Android source and the Stitch desktop reference WITHOUT
/// touching the production call lifecycle.
///
/// This entry exists because the engine has not yet surfaced the
/// fields the new `InCallScreen` reads (sasWords, keyInfo,
/// transportMode, rekeyInSeconds). The legacy `CallView` /
/// `InCallView` / `VideoCallView` keep handling real-time calls until
/// `AppState` and `InCallContainer` expose the new state, at which
/// point ContentView's `if appState.isInCall` branch is repointed to
/// `InCallScreen` and this showcase becomes redundant.
struct CallDesignShowcase: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    var body: some View {
        List {
            Section("Ringing") {
                NavigationLink("Incoming · Audio") {
                    IncomingCallScreen(
                        peerDisplayName: "Mario Rossi",
                        callType: .audio,
                        confidence: 0.94,
                        onAccept: {}, onReject: {}
                    )
                    .navigationBarBackButtonHidden(false)
                }
                NavigationLink("Incoming · Video") {
                    IncomingCallScreen(
                        peerDisplayName: "Anna Bianchi",
                        callType: .video,
                        confidence: 0.81,
                        onAccept: {}, onReject: {}
                    )
                }
                NavigationLink("Outgoing · Dialing") {
                    OutgoingCallScreen(
                        peerDisplayName: "Mario Rossi",
                        state: .dialing,
                        elapsedSeconds: 3,
                        onHangup: {}
                    )
                }
                NavigationLink("Outgoing · Handshaking") {
                    OutgoingCallScreen(
                        peerDisplayName: "Anna Bianchi",
                        state: .handshaking,
                        elapsedSeconds: 8,
                        onHangup: {}
                    )
                }
                NavigationLink("Outgoing · Error") {
                    OutgoingCallScreen(
                        peerDisplayName: "Luigi Verdi",
                        state: .ended,
                        elapsedSeconds: 27,
                        errorMessage: "Negoziazione PQC fallita: timeout dopo 25s.",
                        onHangup: {}
                    )
                }
            }

            Section("Active") {
                NavigationLink("InCall · Connected + SAS + KeyInfo") {
                    InCallScreen(
                        peerDisplayName: "Mario Rossi",
                        durationSeconds: 754,
                        confidence: 0.92,
                        recentSamples: [0.84, 0.86, 0.89, 0.91, 0.92, 0.92, 0.93, 0.92],
                        rekeyInSeconds: 252,
                        rekeyTotalSeconds: 300,
                        pqcActive: true,
                        sasWords: ["OXYGEN", "ZEPHYR", "GLYPH", "RADIUS", "VESTIGE", "ECHO"],
                        sasVerified: false,
                        keyInfo: .init(pqcAlgorithm: "ML-KEM-1024 + X25519",
                                       sessionFingerprint: "7f3b…d2e9",
                                       pskMethodLabel: "NFC",
                                       pskName: "Yubi5",
                                       pskFingerprint: "a83c-9f12"),
                        transportMode: .p2pSrtp,
                        onHangup: {}
                    )
                }
                NavigationLink("InCall · Connecting / no SAS") {
                    InCallScreen(
                        peerDisplayName: "Anna Bianchi",
                        durationSeconds: 12,
                        confidence: 0.55,
                        rekeyInSeconds: 295,
                        transportMode: .disconnected,
                        onHangup: {}
                    )
                }
                NavigationLink("InCall · SAS verified") {
                    InCallScreen(
                        peerDisplayName: "Luigi Verdi",
                        durationSeconds: 1840,
                        confidence: 0.95,
                        recentSamples: [0.93, 0.94, 0.95, 0.96, 0.95, 0.95, 0.94, 0.95],
                        rekeyInSeconds: 78,
                        rekeyTotalSeconds: 300,
                        sasWords: ["OXYGEN", "ZEPHYR", "GLYPH", "RADIUS", "VESTIGE", "ECHO"],
                        sasVerified: true,
                        transportMode: .turn,
                        onHangup: {}
                    )
                }
            }

            Section("Group") {
                NavigationLink("Group call · 5 participants") {
                    GroupCallScreen(
                        callId: "f3a8b07c-9d51-4f2a-87e2-a1d0f5bb1a2e",
                        participants: ["user-mario", "user-anna",
                                       "user-luigi", "user-self",
                                       "user-paolo"],
                        selfUserId: "user-self",
                        muted: false,
                        onToggleMute: {}, onLeave: {}
                    )
                }
            }

            Section {
                Text("Queste schermate sono in modalità anteprima visiva. La logica di chiamata reale (push, audio, deepfake guard) usa ancora il flusso legacy `CallView`. Il wiring definitivo arriva una volta che l'engine espone sasWords / keyInfo / transportMode.")
                    .qaudionStyle(type.bodySmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            } header: {
                Text("Stato wiring")
            }
        }
        .navigationTitle("Call Design Showcase")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { CallDesignShowcase() }
        .qAudionTheme(dark: true)
}
