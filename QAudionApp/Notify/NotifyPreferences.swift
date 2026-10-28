import Foundation

/// Choices the notification extension reads from the notify App Group defaults (shared with the app).
/// Foundation only: the extension compiles this file directly.
struct NotifyPreferences {

    static let appGroupId = "group.com.bcrypto.qaudion.notify"
    static let keySiriDonations = "qaudion.notify.siri_donations_enabled"
    /// Group identifier of every interaction the extension donates, followed by the local conversation hash.
    static let donationGroupPrefix = "qaudion.notify."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: NotifyPreferences.appGroupId) ?? .standard) {
        self.defaults = defaults
    }

    /// Whether the extension donates the sender of a message to Siri (the notification then shows name and photo).
    /// It mirrors the user's Siri messaging consent (Settings > Privacy > Siri), which the extension cannot read
    /// itself: the app copies it here. Off until the user has consented.
    var siriDonationsEnabled: Bool {
        get { defaults.object(forKey: Self.keySiriDonations) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.keySiriDonations) }
    }

    static func donationGroupIdentifier(thread: String) -> String { donationGroupPrefix + thread }
}
