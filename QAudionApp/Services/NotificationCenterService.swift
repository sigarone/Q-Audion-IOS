import Foundation
import UserNotifications
import UIKit

@MainActor
final class NotificationCenterService: NSObject, UNUserNotificationCenterDelegate {

    enum Category: String {
        case kmsKeyAvailable = "QAUDION_KMS_KEY"
        case threatAlert = "QAUDION_THREAT_ALERT"
        case messageDelivered = "QAUDION_MESSAGE_DELIVERED"
        case missedCall = "QAUDION_MISSED_CALL"
        case wipeRequest = "QAUDION_WIPE_REQUEST"
    }

    enum AuthorizationState: Equatable {
        case notDetermined
        case authorized
        case denied
        case provisional
        case ephemeral
    }

    static let shared = NotificationCenterService()

    private let center = UNUserNotificationCenter.current()
    /// Handler for notification taps; caller wires to navigation.
    /// Notification-tap handler. Receives the notification category + the
    /// userInfo flattened to a Sendable `[String: String]` dictionary
    /// (string-coerced from the original `[AnyHashable: Any]`).
    var onNotificationTap: ((Category, [String: String]) -> Void)?

    /// Latest known authorization state (refreshed via `refreshAuthorizationState()`).
    @Published private(set) var authorization: AuthorizationState = .notDetermined

    private override init() {
        super.init()
        center.delegate = self
        Task { await self.refreshAuthorizationState() }
    }

    /// Request alert + sound + badge authorization. Returns the result.
    func requestAuthorization() async -> AuthorizationState {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                self.authorization = granted ? .authorized : .denied
            }
            // Register categories on first authorization.
            if granted { registerCategories() }
            // Register for remote notifications (APNs token delivery).
            if granted {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
            return self.authorization
        } catch {
            return .denied
        }
    }

    func refreshAuthorizationState() async {
        let settings = await center.notificationSettings()
        let state: AuthorizationState
        switch settings.authorizationStatus {
        case .notDetermined: state = .notDetermined
        case .denied: state = .denied
        case .authorized: state = .authorized
        case .provisional: state = .provisional
        case .ephemeral: state = .ephemeral
        @unknown default: state = .denied
        }
        await MainActor.run { self.authorization = state }
    }

    /// Register custom notification categories with actions (Reply, View, Dismiss).
    private func registerCategories() {
        let viewAction = UNNotificationAction(
            identifier: "VIEW",
            title: "View",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: [.destructive]
        )

        let kmsCategory = UNNotificationCategory(
            identifier: Category.kmsKeyAvailable.rawValue,
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let threatCategory = UNNotificationCategory(
            identifier: Category.threatAlert.rawValue,
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )
        let messageCategory = UNNotificationCategory(
            identifier: Category.messageDelivered.rawValue,
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )
        let missedCallCategory = UNNotificationCategory(
            identifier: Category.missedCall.rawValue,
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let wipeCategory = UNNotificationCategory(
            identifier: Category.wipeRequest.rawValue,
            actions: [viewAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([
            kmsCategory, threatCategory, messageCategory, missedCallCategory, wipeCategory
        ])
    }

    /// Schedule a local notification for testing or for offline-only events
    /// (e.g. user-set reminders). Real server-pushed notifications come via APNs.
    func scheduleLocal(category: Category,
                       title: String,
                       body: String,
                       userInfo: [AnyHashable: Any] = [:],
                       delay: TimeInterval = 0.5) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category.rawValue
        content.userInfo = userInfo
        content.threadIdentifier = category.rawValue

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(0.1, delay), repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    func clearAllDelivered() {
        center.removeAllDeliveredNotifications()
    }

    func clearBadge() {
        if #available(iOS 16.0, *) {
            center.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show as banner + sound when app is foreground.
        return [.banner, .sound, .list, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let category = Category(rawValue: response.notification.request.content.categoryIdentifier)
        // Convert userInfo to a Sendable [String: String] dictionary by JSON-stringifying
        // each value. Loses fidelity for non-string types but satisfies Sendable contract
        // for Swift 6 strict concurrency. Callers that need the raw dictionary can
        // re-fetch from UNUserNotificationCenter.
        let raw = response.notification.request.content.userInfo
        var sendableInfo: [String: String] = [:]
        for (key, value) in raw {
            if let k = key as? String {
                sendableInfo[k] = "\(value)"
            }
        }
        let categoryFinal = category
        let infoFinal = sendableInfo
        await MainActor.run {
            if let cat = categoryFinal {
                self.onNotificationTap?(cat, infoFinal)
            }
        }
    }
}
