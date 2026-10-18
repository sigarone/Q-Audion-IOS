import Foundation

/// Whether THIS account has ever successfully enrolled a recovery
/// mnemonic on THIS device — the signal the recovery-seed nudges (Settings
/// banner, chat-list banner) key off.
///
/// This is not "nothing prompts the user to set up recovery" — the
/// mandatory onboarding reveal (`OnboardingRoot.startRecoveryReveal`)
/// already forces every brand-new account through the flow before it lets
/// them into the app, exactly like Android. What this covers is the
/// SECOND net Android also ships: `RecoverySeedContainer.confirmSetup`'s
/// own kdoc documents that when `recoverySetup` fails server-side, the
/// onboarding reveal activates the session anyway rather than stranding
/// the user on an unrecoverable error screen — a deliberate choice, not a
/// bug, but it means an account can genuinely reach the app unenrolled.
/// Those users get nudged here instead.
///
/// A Bool is enough. Android persists the raw entropy (`KEY_ENTROPY_HEX`)
/// because it supports re-revealing the mnemonic and deriving a phone-list
/// key from it; iOS has neither feature, so storing entropy here would add
/// a new at-rest secret for no functional reason.
///
/// Keyed by the account's own userId, not a bare global key — mirrors the
/// shape `MeshRoutingPreferenceStore` and `LastSeenTracker` already use for
/// per-user UserDefaults keys — so signing out and back in as a DIFFERENT
/// account never inherits a stale "enrolled" or "dismissed" state.
enum RecoveryEnrollmentStatus {
    private static let enrolledPrefix = "qa.recoveryEnrolled."
    private static let dismissPrefix = "qa.recoveryBannerDismissed."

    static func isEnrolled(userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: enrolledPrefix + userId)
    }

    /// Set-only, deliberately. There is no "un-enroll recovery" action on
    /// iOS (VoiceprintStore.delete resets Voice-as-Key, not this), so
    /// nothing ever needs to flip an already-enrolled account back to
    /// false.
    static func markEnrolled(userId: String) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: enrolledPrefix + userId)
    }

    static func isBannerDismissed(userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: dismissPrefix + userId)
    }

    static func dismissBanner(userId: String) {
        guard !userId.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: dismissPrefix + userId)
    }
}
