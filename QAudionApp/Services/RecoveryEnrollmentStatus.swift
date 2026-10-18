import Foundation

/// Whether the recovery-seed nudges (Settings banner, chat-list banner) should
/// be shown for THIS account on THIS device.
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
/// The signal is POSITIVE evidence, not the absence of a record. The server
/// has no endpoint that says whether an account has a recovery hash on file
/// (`recovery-setup` and `recovery-verify` are POST-only, and neither the
/// profile nor the login response carries the fact), so this device cannot
/// ask. The first version of this type kept only an "enrolled" flag and
/// nagged every account without one. That flag is per install, and it did
/// not exist before this change, so an account enrolled on an earlier build,
/// or signing in on a second device, read as "not enrolled" and got a banner
/// it could not get rid of (the Settings one is not dismissable) until it ran
/// the flow again.
///
/// Now the nudge needs two facts: the onboarding reveal of a brand-new
/// registration made on this device recorded that it was starting
/// (`markAwaitingEnrollment`), and no successful enrolment has been recorded
/// since (`markEnrolled`). An account this build never saw being created has
/// no "awaiting" record and is never nagged; it can still enrol from the
/// "Seed di recupero" row in Settings. The cost of that choice is that an
/// account created by an earlier build whose `recoverySetup` failed is not
/// reminded either; the price of reminding it would be a banner that cannot
/// be dismissed for every account that is in fact enrolled.
///
/// A Bool is enough. Android persists the raw entropy (`KEY_ENTROPY_HEX`)
/// because it supports re-revealing the mnemonic and deriving a phone-list
/// key from it; iOS has neither feature, so storing entropy here would add
/// a new at-rest secret for no functional reason.
///
/// Keyed by the account's own userId, not a bare global key — mirrors the
/// shape `MeshRoutingPreferenceStore` and `LastSeenTracker` already use for
/// per-user UserDefaults keys — so signing out and back in as a DIFFERENT
/// account never inherits a stale state. Every function takes the
/// `UserDefaults` it works on (the standard one in the app) so the rules can
/// be tested against a private suite.
enum RecoveryEnrollmentStatus {
    private static let enrolledPrefix = "qa.recoveryEnrolled."
    private static let awaitingPrefix = "qa.recoveryAwaiting."
    private static let dismissPrefix = "qa.recoveryBannerDismissed."

    /// True only while the account is known to be unenrolled: its onboarding
    /// reveal started here and no enrolment succeeded afterwards. This is the
    /// one question the banners ask.
    static func needsReminder(userId: String, defaults: UserDefaults = .standard) -> Bool {
        guard !userId.isEmpty else { return false }
        guard defaults.bool(forKey: awaitingPrefix + userId) else { return false }
        return !defaults.bool(forKey: enrolledPrefix + userId)
    }

    /// Recorded by the mandatory reveal at the end of a brand-new
    /// registration, before the phrase is shown. Left in place when
    /// `recoverySetup` then fails or the app is closed mid-reveal, which is
    /// exactly the account the reminder exists for. Only a registration may
    /// call this: a sign-in to an existing account proves nothing about its
    /// recovery state.
    static func markAwaitingEnrollment(userId: String, defaults: UserDefaults = .standard) {
        guard !userId.isEmpty else { return }
        defaults.set(true, forKey: awaitingPrefix + userId)
    }

    static func isEnrolled(userId: String, defaults: UserDefaults = .standard) -> Bool {
        guard !userId.isEmpty else { return false }
        return defaults.bool(forKey: enrolledPrefix + userId)
    }

    /// Set-only, deliberately. There is no "un-enroll recovery" action on
    /// iOS (VoiceprintStore.delete resets Voice-as-Key, not this), so
    /// nothing ever needs to flip an already-enrolled account back to
    /// false. Also drops the "awaiting" record, which has been answered.
    static func markEnrolled(userId: String, defaults: UserDefaults = .standard) {
        guard !userId.isEmpty else { return }
        defaults.set(true, forKey: enrolledPrefix + userId)
        defaults.removeObject(forKey: awaitingPrefix + userId)
    }

    static func isBannerDismissed(userId: String, defaults: UserDefaults = .standard) -> Bool {
        guard !userId.isEmpty else { return false }
        return defaults.bool(forKey: dismissPrefix + userId)
    }

    static func dismissBanner(userId: String, defaults: UserDefaults = .standard) {
        guard !userId.isEmpty else { return }
        defaults.set(true, forKey: dismissPrefix + userId)
    }
}
