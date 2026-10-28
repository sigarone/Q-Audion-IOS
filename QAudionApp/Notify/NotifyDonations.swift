import Foundation
import Intents

/// The Siri donations of the notification extension (sender name and photo) follow the user's Siri messaging
/// consent and are removed when the consent is withdrawn and when the account leaves.
enum NotifyDonations {

    /// Copies the consent into the notify defaults (the extension reads it there). Call at launch.
    /// `deleter` is called when donations are not allowed, so a donation left from an earlier state is removed.
    static func syncConsent(consent: Bool = SiriMessagingConsent.isEnabled,
                            preferences: NotifyPreferences = NotifyPreferences(),
                            deleter: () -> Void = deleteAll) {
        let wasEnabled = preferences.siriDonationsEnabled
        preferences.siriDonationsEnabled = consent
        if wasEnabled && !consent { deleter() }
    }

    /// The consent switch changed.
    static func consentChanged(to consent: Bool,
                               preferences: NotifyPreferences = NotifyPreferences(),
                               deleter: () -> Void = deleteAll) {
        let wasEnabled = preferences.siriDonationsEnabled
        preferences.siriDonationsEnabled = consent
        if wasEnabled && !consent { deleter() }
    }

    /// Removes every interaction the app donated. (This also drops the app's call suggestions; they are donated
    /// again on the next call.)
    static func deleteAll() {
        INInteraction.deleteAll { _ in }
    }
}
