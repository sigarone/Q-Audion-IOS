import Foundation
import LocalAuthentication

/// W441 — App lock service. Mirrors Android's AppLockGate / BiometricPrompt flow.
///
/// Lifecycle:
///   1. App goes to background  → `handleBackground()` records the timestamp.
///   2. App comes to foreground → `handleForeground()` decides whether to lock:
///        • if enabled AND grace period elapsed → isLocked = true → triggers biometric
///        • if within grace period → stay unlocked (e.g. quick task-switcher visit)
///   3. Biometric / passcode succeeds → isLocked = false
///   4. Active call → `bypassForCall()` clears the lock so call controls stay accessible
///
/// QAudionApp.swift reads `isLocked` via @ObservedObject and overlays AppLockGateView.
@MainActor
final class AppLockService: ObservableObject {

    @Published private(set) var isLocked: Bool = false

    /// When the app last entered background. nil = app was never backgrounded.
    private var backgroundedAt: Date?

    // MARK: - Scene phase callbacks

    func handleBackground() {
        backgroundedAt = Date()
    }

    func handleForeground() {
        guard PrivacyGate.appLockEnabled else {
            isLocked = false
            return
        }
        let graceMs = PrivacyGate.appLockTimeoutMs
        let graceSec = Double(graceMs) / 1000.0
        if let bg = backgroundedAt, Date().timeIntervalSince(bg) < graceSec {
            // Within grace window — don't lock.
            backgroundedAt = nil
            return
        }
        backgroundedAt = nil
        isLocked = true
        Task { await evaluatePolicy() }
    }

    // MARK: - Biometric / passcode evaluation

    /// Present the system authentication prompt. On success, clears isLocked.
    func evaluatePolicy() async {
        let context = LAContext()
        var nsError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsError) else {
            // No biometry and no passcode set — unlock silently.
            isLocked = false
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Sblocca Q-Audion"
            )
            if success {
                isLocked = false
            }
        } catch {
            // User cancelled or failed — remain locked; they can tap "Sblocca" again.
        }
    }

    // MARK: - Call bypass

    /// Call-active bypass: the lock screen must not obstruct in-call controls.
    func bypassForCall() {
        isLocked = false
    }
}
