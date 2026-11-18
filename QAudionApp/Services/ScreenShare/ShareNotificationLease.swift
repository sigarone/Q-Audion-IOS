import Foundation

/// Tells the notification extension, through the notify App Group, that this device shares its screen, so the banners
/// it builds name nobody and show no photo.
///
/// The state is a lease: a time in the future that the app renews while the share runs and clears when it ends. If
/// the app is killed without ending the share, the lease runs out by itself within `NotifyPreferences.shareLeaseSeconds`,
/// and the app clears it at launch. Writes and the renewal timer run on one serial queue, so a clear that follows a
/// start is never overtaken by a renewal.
final class ShareNotificationLease: @unchecked Sendable {

    private let preferences: NotifyPreferences
    private let renewEvery: TimeInterval
    private let queue = DispatchQueue(label: "qaudion.share.lease", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(preferences: NotifyPreferences = NotifyPreferences(),
         renewEvery: TimeInterval = NotifyPreferences.shareLeaseRenewSeconds) {
        self.preferences = preferences
        self.renewEvery = renewEvery
    }

    /// The share started: the lease is written now and renewed until `end()`.
    func begin() {
        queue.sync {
            timer?.cancel()
            preferences.setSharingScreen(true)
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + renewEvery, repeating: renewEvery)
            source.setEventHandler { [preferences] in preferences.setSharingScreen(true) }
            source.resume()
            timer = source
        }
    }

    /// The share ended (or the app starts): the lease is cleared and nothing renews it.
    func end() {
        queue.sync {
            timer?.cancel()
            timer = nil
            preferences.setSharingScreen(false)
        }
    }
}
