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
        RTLog.info("call", "W-CALLFG-DIAG AppLockService.handleBackground — timestamp persisted")
    }

    func handleForeground() {
        guard PrivacyGate.appLockEnabled else {
            isLocked = false
            // Consume any stale timestamp so a later enable starts clean.
            UserDefaults.standard.removeObject(forKey: Self.backgroundedAtKey)
            RTLog.info("call", "W-CALLFG-DIAG AppLockService.handleForeground — appLock disabled, isLocked=false")
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
            RTLog.info("call", "W-CALLFG-DIAG AppLockService.handleForeground — within grace (elapsed=\(String(format: "%.1f", elapsed))s < \(String(format: "%.1f", graceSec))s), staying unlocked")
            return
        }
        isLocked = true
        RTLog.warn("call", "W-CALLFG-DIAG AppLockService.handleForeground — LOCKING (elapsed=\(String(format: "%.1f", elapsed))s >= grace=\(String(format: "%.1f", graceSec))s), triggering biometric prompt")
        Task { await evaluatePolicy() }
    }

    // MARK: - Biometric / passcode evaluation

    /// Present the system authentication prompt. On success, clears isLocked.
    func evaluatePolicy() async {
        RTLog.info("call", "W-CALLFG-DIAG AppLockService.evaluatePolicy — presenting biometric/passcode prompt")
        let context = LAContext()
        var nsError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &nsError) else {
            // SECURITY H-14: no biometry AND no passcode set. DO NOT
            // auto-unlock (the previous behavior defeated the lock for
            // any user without a device passcode). Stay locked and tell
            // the UI so it can advise the user to set a passcode.
            isLocked = true
            RTLog.warn("call", "W-CALLFG-DIAG AppLockService.evaluatePolicy — canEvaluatePolicy failed: \(nsError?.localizedDescription ?? "?")")
            NotificationCenter.default.post(name: .appLockUnavailable, object: nil)
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Sblocca Q-Audion"
            )
            RTLog.info("call", "W-CALLFG-DIAG AppLockService.evaluatePolicy — result success=\(success)")
            if success {
                isLocked = false
            }
        } catch {
            // User cancelled or failed — remain locked; they can tap "Sblocca" again.
            RTLog.warn("call", "W-CALLFG-DIAG AppLockService.evaluatePolicy — threw: \(error.localizedDescription)")
        }
    }

    /// Feature A ("Voice-as-Key") — additive re-authentication path.
    /// `AppLockGateView` calls this ONLY after `VoiceUnlockController`
    /// reports a `VoiceAuthGate` `.passed` verdict against the enrolled
    /// device-owner voiceprint. This is ADDITIVE to `evaluatePolicy()`
    /// (PIN/biometric) — it never replaces it, never disables it, and the
    /// UI never removes the existing "Sblocca" (Face ID/passcode) button.
    /// A device with no enrolled voiceprint never reaches this method at
    /// all (`VoiceUnlockController.isAvailable` gates the button itself).
    func unlockViaVoice() {
        isLocked = false
        RTLog.info("call", "W441-VOICE AppLockService.unlockViaVoice — voice re-auth passed, isLocked=false")
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
    /// - Parameter groupCallActive: W-CALLFG (2026-07-27) — true when
    ///   `AppState.groupCallControllerState` is `.connecting` or `.active`.
    ///   Group calls never set `isInCall` (a SEPARATE, parallel signal —
    ///   see `AppState`'s own busy-check `isInCall || callState != .idle ||
    ///   groupCallControllerState != .idle`, which treats them as
    ///   independent), so before this parameter existed a live GROUP call
    ///   had NO path to this function at all — QAudionApp's scenePhase
    ///   handler only ever called `bypassForCall` when `appState.isInCall`
    ///   was true, which is 1:1-only. Every foreground during an active
    ///   group call hit the plain `handleForeground()` grace-window path
    ///   instead, so the in-app Face ID/passcode gate could fire mid-group-
    ///   call — same class of friction `answered`/`callState` already
    ///   solve for 1:1, just never extended to the other call type. Both
    ///   `.connecting` and `.active` are safe to bypass on: unlike 1:1's
    ///   `.ringing` (received but NOT yet accepted), group's `.connecting`
    ///   already implies the user (or the creator) chose to join/create —
    ///   there is no pre-accept "ringing-only" case that maps to
    ///   `.connecting`.
    func bypassForCall(callState: CallState? = nil, answered: Bool = false, groupCallActive: Bool = false) {
        RTLog.info("call", "W-CALLFG-DIAG AppLockService.bypassForCall called — answered=\(answered) callState=\(String(describing: callState)) groupCallActive=\(groupCallActive) isLocked(before)=\(isLocked)")
        // An EXPLICIT CallKit answer (user accepted) may suppress the lock even
        // before the handshake reaches .active/.encrypted, so a PushKit-woken,
        // just-answered call surfaces the Q-Audion in-call screen (securing →
        // SAS) instead of the biometric lock. `answered` is driven by
        // AppState.callWasAnswered (answeredCallKitId), set ONLY in onAnswerCall —
        // a mere incoming ring never trips it, so an unanswered call still holds
        // the lock (SECURITY M-25/L-7 preserved).
        if answered || groupCallActive {
            isLocked = false
            RTLog.info("call", "W-CALLFG-DIAG AppLockService.bypassForCall — bypassed (answered=\(answered) groupCallActive=\(groupCallActive)), isLocked=false")
            return
        }
        if let callState = callState {
            // Only an answered/established call may suppress the lock.
            guard callState == .active || callState == .encrypted else {
                RTLog.info("call", "W-CALLFG-DIAG AppLockService.bypassForCall — NOT bypassed, callState=\(callState) is pre-answer, lock stays as-is (isLocked=\(isLocked))")
                return
            }
            isLocked = false
            RTLog.info("call", "W-CALLFG-DIAG AppLockService.bypassForCall — bypassed via callState=\(callState), isLocked=false")
            return
        }
        // Legacy/defensive fallback: only reached if a caller passes
        // `nil`. The production call site (QAudionApp.swift) DOES pass
        // `appState.callState`, so the `guard` above is the live
        // enforcement — `.ringing` no longer bypasses the lock.
        isLocked = false
        RTLog.info("call", "W-CALLFG-DIAG AppLockService.bypassForCall — legacy fallback (no callState/groupCallActive supplied), isLocked=false")
    }
}
