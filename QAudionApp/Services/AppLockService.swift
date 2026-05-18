import Foundation
import LocalAuthentication

extension Notification.Name {
    /// SECURITY H-14 — posted when app-lock is enabled but the device
    /// has no biometry AND no passcode set, so the policy cannot be
    /// evaluated. UI should advise the user to set a device passcode;
    /// the app stays LOCKED rather than silently unlocking.
    static let appLockUnavailable = Notification.Name("qaudion.appLock.unavailable")
}

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

    /// SECURITY H-13 — UserDefaults key persisting the wall-clock time
    /// the app last entered background. Survives process death so a
    /// cold start (app killed in background, relaunched) still locks:
    /// an in-memory-only timestamp was lost on kill, bypassing the lock.
    private static let backgroundedAtKey = "qaudion.lock.backgroundedAt"

    // MARK: - Scene phase callbacks

    func handleBackground() {
        // SECURITY H-13: persist to disk, not just memory, so a kill +
        // relaunch still sees a background timestamp.
        UserDefaults.standard.set(Date().timeIntervalSince1970,
                                  forKey: Self.backgroundedAtKey)
    }

    func handleForeground() {
        guard PrivacyGate.appLockEnabled else {
            isLocked = false
            // Consume any stale timestamp so a later enable starts clean.
            UserDefaults.standard.removeObject(forKey: Self.backgroundedAtKey)
            return
        }
        let graceMs = PrivacyGate.appLockTimeoutMs
        let graceSec = Double(graceMs) / 1000.0

        // SECURITY H-13: read persisted timestamp. Absent → distantPast
        // so a first launch (or post-kill cold start) with appLock
        // enabled LOCKS instead of bypassing.
        let defaults = UserDefaults.standard
        let backgroundedAt: Date
        if defaults.object(forKey: Self.backgroundedAtKey) != nil {
            backgroundedAt = Date(timeIntervalSince1970:
                defaults.double(forKey: Self.backgroundedAtKey))
        } else {
            backgroundedAt = Date.distantPast
        }
        // Consume the persisted key after reading it.
        defaults.removeObject(forKey: Self.backgroundedAtKey)

        let elapsed = Date().timeIntervalSince(backgroundedAt)
        if elapsed < graceSec {
            // Within grace window — don't lock (e.g. quick task switch).
            return
        }
        isLocked = true
        Task { await evaluatePolicy() }
    }

    // MARK: - Biometric / passcode evaluation

    /// Present the system authentication prompt. On success, clears isLocked.
    func evaluatePolicy() async {
        let context = LAContext()
        var nsError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsError) else {
            // SECURITY H-14: no biometry AND no passcode set. DO NOT
            // auto-unlock (the previous behavior defeated the lock for
            // any user without a device passcode). Stay locked and tell
            // the UI so it can advise the user to set a passcode.
            isLocked = true
            NotificationCenter.default.post(name: .appLockUnavailable, object: nil)
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

    /// Call-active bypass: the lock screen must not obstruct in-call
    /// controls. The bypass MUST be limited to a genuinely *active*
    /// call — `isInCall` is also true at `.ringing` (pre-answer), and
    /// bypassing the lock there lets anyone holding the device dismiss
    /// the lock simply by triggering / receiving a ringing call without
    /// ever answering it.
    ///
    /// SECURITY M-25 / L-7: gate the bypass on `callState == .active`
    /// (or the post-key-exchange `.encrypted`). When the caller can
    /// supply the state we enforce it here; when it cannot (`nil`) we
    /// fall back to the legacy permissive behavior and flag the gap.
    ///
    /// - Parameter callState: the current `AppState.callState`. Pass it
    ///   from the scene-phase handler. `nil` = caller couldn't supply
    ///   state (legacy path, see TODO below).
    func bypassForCall(callState: CallState? = nil) {
        if let callState = callState {
            // Only an answered/established call may suppress the lock.
            guard callState == .active || callState == .encrypted else { return }
            isLocked = false
            return
        }
        // Legacy/defensive fallback: only reached if a caller passes
        // `nil`. The production call site (QAudionApp.swift) DOES pass
        // `appState.callState`, so the `guard` above is the live
        // enforcement — `.ringing` no longer bypasses the lock.
        isLocked = false
    }
}
