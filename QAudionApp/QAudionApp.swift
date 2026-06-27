import SwiftUI
import UIKit
import BackgroundTasks
import QAudionEngine

/// W-NOCALLKIT — minimal UIApplicationDelegate, attached via
/// `@UIApplicationDelegateAdaptor`, to capture the STANDARD APNs device token.
/// Needed only in `CallsGate.callKitFreeMode` (the server sends an INCOMING_CALL
/// *alert* push to this token when the app is killed). The token is forwarded
/// via NotificationCenter so AppState can register it server-side without a
/// static AppState reference (same pattern as the BGTask bridge). When the flag
/// is OFF, AppState.handleApnsDeviceToken ignores the token → no behavior change.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02hhx", $0) }.joined()
        NotificationCenter.default.post(name: AppState.apnsTokenReceived, object: hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[AppDelegate] APNs registration failed: \(error.localizedDescription)")
    }
}

@main
struct QAudionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    /// W441: App lock service. isLocked drives the gate overlay in body.
    @StateObject private var lockService = AppLockService()
    @Environment(\.scenePhase) private var scenePhase

    /// W441: reactive screenshot-protection flag — @AppStorage so the ZStack
    /// modifier re-evaluates when the user toggles the setting in PrivacySettings.
    @AppStorage("qaudion.privacy.screenshot_protection")
    private var screenshotProtectionEnabled: Bool = false

    init() {
        // W472 — install the native-crash catcher as the very first
        // thing, before any code that could crash. It persists a
        // backtrace on a signal / NSException; the report is flushed to
        // the W417 telemetry on the NEXT launch (see `flushPendingReport`
        // in `.onAppear`, which must run AFTER the stdout tee attaches).
        CrashReporter.installHandlers()

        // W-BGK: BGAppRefreshTask must be registered before the app finishes
        // launching (Apple requirement). We forward it via NotificationCenter
        // so AppState.handleWsKeepaliveTask() can access the live auth state
        // without a static reference to AppState.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.bcrypto.qaudion.ws-keepalive",
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            NotificationCenter.default.post(
                name: AppState.bgWsKeepalive,
                object: refreshTask
            )
        }
    }

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
                // W472 — flush any crash report from the previous launch.
                // MUST be after attachStdoutTee() so the prints are
                // captured by the W417 telemetry and shipped to the server.
                CrashReporter.flushPendingReport()
                // W-MK — register the MetricKit subscriber. MUST be after
                // attachStdoutTee() so the per-payload prints are captured
                // by the W417 telemetry, same rationale as the crash flush.
                MetricKitDiagnostics.start()
                // W-FLAGS — start the remote feature-flag poll. Primitive-only
                // signature (CLAUDE.md §16): a compile-time flags URL String,
                // NO AppState. Plain URLSession (public, un-authed, NOT the
                // pinned voip host) — see FeatureFlags.swift header. Placed
                // after attachStdoutTee() so the "[FeatureFlags] fetched: ..."
                // line is captured by the W417 telemetry. Fire-and-forget:
                // never blocks launch, fails safe to the compiled defaults.
                FeatureFlags.shared.start(flagsUrl: "https://dash.bcrypto.com/flags.json")
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
                lockService.bypassForCall(
                    callState: appState.callState,
                    answered: appState.callWasAnswered
                )
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
