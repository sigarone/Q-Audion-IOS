import Foundation

/// Choices the notification extension reads from the notify App Group defaults (shared with the app).
/// Foundation only: the extension compiles this file directly.
struct NotifyPreferences {

    static let appGroupId = "group.com.bcrypto.qaudion.notify"
    static let keySiriDonations = "qaudion.notify.siri_donations_enabled"
    /// Seconds since 1970 until which the app says this device is sharing its screen. The app renews it while the
    /// share runs and clears it when the share ends; the extension trusts it only while it lies in the future and
    /// within one lease from now, so a share that was never cleared (the app died) stops hiding names by itself.
    static let keyShareLeaseUntil = "qaudion.notify.share_lease_until"
    /// How long one lease lasts.
    static let shareLeaseSeconds: TimeInterval = 45
    /// How often the app renews the lease while sharing.
    static let shareLeaseRenewSeconds: TimeInterval = 15
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

    /// The app: this device shares its screen (a lease of `shareLeaseSeconds` from `now`), or it does not (cleared).
    func setSharingScreen(_ sharing: Bool, now: Date = Date()) {
        if sharing {
            defaults.set(now.timeIntervalSince1970 + Self.shareLeaseSeconds, forKey: Self.keyShareLeaseUntil)
        } else {
            defaults.removeObject(forKey: Self.keyShareLeaseUntil)
        }
    }

    /// Whether this device is sharing its screen right now: the lease lies in the future, and not further away than
    /// one lease (a value from a clock that was set back is not believed).
    func isSharingScreen(now: Date = Date()) -> Bool {
        let until = defaults.double(forKey: Self.keyShareLeaseUntil)
        let current = now.timeIntervalSince1970
        return until > current && until <= current + Self.shareLeaseSeconds + 5
    }
}
