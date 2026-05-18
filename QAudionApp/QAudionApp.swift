import SwiftUI
import QAudionEngine

@main
struct QAudionApp: App {
    @StateObject private var appState = AppState()
    /// W441: App lock service. isLocked drives the gate overlay in body.
    @StateObject private var lockService = AppLockService()
    @Environment(\.scenePhase) private var scenePhase

    /// W441: reactive screenshot-protection flag — @AppStorage so the ZStack
    /// modifier re-evaluates when the user toggles the setting in PrivacySettings.
    @AppStorage("qaudion.privacy.screenshot_protection")
    private var screenshotProtectionEnabled: Bool = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(appState)
                    // W441: hide app content from app-switcher snapshots when
                    // screenshot protection is on (iOS 15+ system API).
                    .privacySensitive(screenshotProtectionEnabled)
                    .allowsHitTesting(!lockService.isLocked)

                if lockService.isLocked {
                    AppLockGateView(lockService: lockService)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lockService.isLocked)
            .onChange(of: scenePhase) { newPhase in
                handleScenePhase(newPhase)
            }
            .onAppear {
                // W416: ring-buffer stdout tee from launch for live telemetry.
                RuntimeLogSink.shared.attachStdoutTee()
                appState.initialize()
                // W441: sweep expired messages immediately + every 60s.
                EphemeralMessageJanitor.shared.start()
                // W441: listen for OS screenshot events and warn in the log.
                registerScreenshotObserver()
            }
        }
    }

    // MARK: - Scene phase

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            lockService.handleBackground()
        case .active:
            // Active call bypasses the lock so in-call controls stay reachable.
            // SECURITY M-25/L-7: pass the real callState so the bypass only
            // applies to an answered/established call (.active/.encrypted),
            // NOT a mere .ringing (pre-answer) state — otherwise anyone
            // holding the device could dismiss the lock by triggering an
            // incoming call without answering it.
            if appState.isInCall {
                lockService.bypassForCall(callState: appState.callState)
            } else {
                lockService.handleForeground()
            }
        default:
            break
        }
    }

    // MARK: - Screenshot detection

    private func registerScreenshotObserver() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { _ in
            guard PrivacyGate.screenshotProtectionEnabled else { return }
            RTLog.warn("privacy", "screenshot taken while protection is active")
        }
    }
}
