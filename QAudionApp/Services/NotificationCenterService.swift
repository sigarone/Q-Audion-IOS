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
        /// W-NOCALLKIT — incoming call ring delivered as a standard APNs ALERT
        /// (no PushKit/CallKit). Carries Answer/Decline actions. The server sets
        /// this category + interruption-level=time-sensitive on the push.
        case incomingCall = "INCOMING_CALL"
    }

    /// W-NOCALLKIT — action identifiers for the incomingCall category.
    /// `answer`/`decline` map to the two notification buttons; `open` is a plain
    /// tap on the notification body (UNNotificationDefaultActionIdentifier) — it
    /// brings the app forward + shows the in-app ring UI but does NOT answer.
    enum CallAction: String {
        case answer = "ANSWER_CALL"
        case decline = "DECLINE_CALL"
        case open = "OPEN_CALL_UI"
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

    /// W-NOCALLKIT — invoked for the `incomingCall` category with the chosen
    /// action (`.answer` for the Answer button OR a plain notification tap;
    /// `.decline` for the Decline button). AppState wires this to
    /// `acceptIncoming` / decline. Kept separate from `onNotificationTap` so the
    /// answer/decline decision (which carries the actionIdentifier) is explicit.
    var onIncomingCallAction: ((CallAction, [String: String]) -> Void)?

    /// W-NOCALLKIT cold-start latch. On an app-KILLED launch via a notification
    /// action, `didReceive` can fire BEFORE AppState.initialize() assigns
    /// `onIncomingCallAction`. Stash the action here when the handler isn't wired
    /// yet; AppState drains it via `flushPendingIncomingAction()` right after
    /// wiring so the user's Answer/Decline tap is never lost.
    private var pendingIncomingAction: (CallAction, [String: String])?

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
        // W-NOCALLKIT — incoming-call category. Answer launches the app
        // (.foreground) so it can open the custom ring/active-call UI; Decline
        // is handled in the background. .hiddenPreviewsShowTitle keeps the
        // caller name visible even when previews are hidden on the lock screen.
        let answerCallAction = UNNotificationAction(
            identifier: CallAction.answer.rawValue,
            title: "Rispondi",
            options: [.foreground]
        )
        let declineCallAction = UNNotificationAction(
            identifier: CallAction.decline.rawValue,
            title: "Rifiuta",
            options: [.destructive]
        )
        let incomingCallCategory = UNNotificationCategory(
            identifier: Category.incomingCall.rawValue,
            actions: [answerCallAction, declineCallAction],
            intentIdentifiers: [],
            options: [.hiddenPreviewsShowTitle]
        )

        center.setNotificationCategories([
            kmsCategory, threatCategory, messageCategory, missedCallCategory,
            wipeCategory, incomingCallCategory
        ])
    }

    /// Schedule a local notification for testing or for offline-only events
    /// (e.g. user-set reminders). Real server-pushed notifications come via APNs.
    func scheduleLocal(category: Category,
                       title: String,
                       body: String,
                       userInfo: [AnyHashable: Any] = [:],
                       delay: TimeInterval = 0.5) async {
        // W405: respect the user's quiet-hours setting — if we're
        // inside the configured window, drop the local notification
        // entirely. Banner stays suppressed; the message is already
        // persisted in the conversation store either way.
        if NotificationsGate.isQuietNow {
            print("[NotificationCenterService] quiet-hours active, suppressing banner")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // W405: gate the chime on the in-app sound toggle. Setting
        // `sound = nil` makes APNs deliver a silent notification.
        content.sound = NotificationsGate.inAppSoundEnabled ? .default : nil
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

    /// W-NOCALLKIT — post a LOCAL incoming-call notification (INCOMING_CALL
    /// category → Answer/Decline) for a call that arrived while the app is alive
    /// but NOT foreground (callKitFreeMode; CallKit is not used). The server
    /// posts the SAME-shaped APNs ALERT for the app-killed case, so the
    /// onIncomingCallAction handler treats both identically. userInfo carries the
    /// routing ids the answer path needs.
    func postIncomingCall(callId: String, peerId: String, callerName: String, hasVideo: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = callerName.isEmpty ? "Chiamata in arrivo" : callerName
        content.body = hasVideo ? "Videochiamata Q-Audion" : "Chiamata Q-Audion"
        // Ring sound. defaultRingtone (iOS 15.2+) loops like a call; else default.
        if #available(iOS 15.2, *) {
            content.sound = .defaultRingtone
        } else {
            content.sound = .default
        }
        content.categoryIdentifier = Category.incomingCall.rawValue
        content.userInfo = [
            "call_id": callId,
            "peer_id": peerId,
            "caller_name": callerName,
            "has_video": hasVideo ? "1" : "0",
        ]
        content.threadIdentifier = Category.incomingCall.rawValue
        // Break through Focus/DnD (no special entitlement needed for time-sensitive).
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let request = UNNotificationRequest(
            identifier: "incoming-call-\(callId)",
            content: content,
            trigger: nil   // deliver immediately
        )
        try? await center.add(request)
    }

    /// W-NOCALLKIT — flush a notification action that arrived during a cold
    /// launch before `onIncomingCallAction` was wired. Idempotent: no-op when
    /// nothing is latched or the handler still isn't set.
    func flushPendingIncomingAction() {
        guard let pending = pendingIncomingAction,
              let handler = onIncomingCallAction else { return }
        pendingIncomingAction = nil
        handler(pending.0, pending.1)
    }

    /// W-NOCALLKIT — clear a posted incoming-call notification (answered/ended).
    func clearIncomingCall(callId: String) {
        let id = "incoming-call-\(callId)"
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
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

    /// W109: set the app icon badge to a specific count (clamped to
    /// 999 so a hostile peer can't spam the icon to absurd numbers).
    /// Calling with 0 hides the badge entirely.
    func setBadge(_ count: Int) {
        let clamped = max(0, min(count, 999))
        if #available(iOS 16.0, *) {
            center.setBadgeCount(clamped)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = clamped
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // W405: foreground presentation respects the user's preferences.
        // Banner suppressed if banners disabled; sound suppressed if
        // in-app sound disabled or in quiet hours.
        if !NotificationsGate.bannersEnabled {
            return [.list, .badge]
        }
        if NotificationsGate.isQuietNow {
            return [.list, .badge]
        }
        if NotificationsGate.inAppSoundEnabled {
            return [.banner, .sound, .list, .badge]
        }
        return [.banner, .list, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let category = Category(rawValue: response.notification.request.content.categoryIdentifier)
        let actionId = response.actionIdentifier  // ANSWER_CALL / DECLINE_CALL / default tap
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
        let actionFinal = actionId
        await MainActor.run {
            if categoryFinal == .incomingCall {
                // W-NOCALLKIT — explicit buttons answer/decline; a plain tap on the
                // notification body opens the in-app ring UI WITHOUT answering.
                let action: CallAction
                if actionFinal == CallAction.decline.rawValue {
                    action = .decline
                } else if actionFinal == CallAction.answer.rawValue {
                    action = .answer
                } else {
                    action = .open  // UNNotificationDefaultActionIdentifier / dismiss
                }
                if let handler = self.onIncomingCallAction {
                    handler(action, infoFinal)
                } else {
                    // Cold launch: handler not wired yet — latch for the drain.
                    self.pendingIncomingAction = (action, infoFinal)
                }
            } else if let cat = categoryFinal {
                self.onNotificationTap?(cat, infoFinal)
            }
        }
    }
}
