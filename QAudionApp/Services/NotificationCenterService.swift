import Foundation
import UserNotifications
import UIKit
import QAudionEngine

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

    /// Tap on the notice of a pending phone-number transfer (custom key `type` =
    /// `phone_transfer_pending`): AppState shows the chat list and reads the transfer state again.
    var onPhoneTransferPendingTap: (@MainActor () -> Void)?

    /// Cold-start latch for that tap, like `pendingIncomingAction`: a tap that launches the app can
    /// arrive before AppState sets the handler.
    private var pendingPhoneTransferTap = false

    /// W-MISSEDQUIET (2026-10-04) — "the user has a call in flight" (in a call, ringing for one, or a CallKit call
    /// still open): the missed-call notification that arrives then is presented quietly
    /// (`MissedCallAlertPolicy`). A closure over primitives and not the AppState type (CLAUDE.md §16); AppState
    /// wires it in `initialize()`. Unset (tests, a launch before AppState exists) reads as "no call".
    typealias CallInFlightProvider = @MainActor () -> Bool
    var callInFlightProvider: CallInFlightProvider?

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
            title: String(localized: "push.action.view", defaultValue: "Visualizza", comment: "Button on a notification: open the related item in the app."),
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: String(localized: "push.action.dismiss", defaultValue: "Ignora", comment: "Button on a notification: dismiss it without opening the app."),
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
            title: String(localized: "push.action.answer", defaultValue: "Rispondi", comment: "Button on the incoming-call notification: answer the call (opens the app)."),
            options: [.foreground]
        )
        let declineCallAction = UNNotificationAction(
            identifier: CallAction.decline.rawValue,
            title: String(localized: "Rifiuta"),
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
        // BLOCK — a banner about a private message or call of a contact the user blocked is never shown.
        // The receive paths already drop those; this is the backstop at the one place every local banner
        // goes through. Group notifications carry a group id and are not filtered (`BlockPolicy`).
        if BlockPolicy.suppressesNotification(userInfo: userInfo, blocked: BlockedContactsStore.loadBlockedIds()) {
            return
        }
        // W405: respect the user's quiet-hours setting — if we're
        // inside the configured window, drop the local notification
        // entirely. Banner stays suppressed; the message is already
        // persisted in the conversation store either way.
        if NotificationsGate.isQuietNow {
            print("[NotificationCenterService] quiet-hours active, suppressing banner")
            return
        }
        // The server may already have shown its generic alert for this burst while the app had no live socket;
        // this banner carries the real sender and text, so the generic one goes first.
        if category == .messageDelivered { await clearRemoteMessageAlerts(for: .inboundStored) }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // W405: gate the chime on the in-app sound toggle. Setting
        // `sound = nil` makes APNs deliver a silent notification.
        // W-MISSEDQUIET: and never for a missed call that arrives while a call is in flight (it can be delivered with
        // the app in the background, where `willPresent` is not asked and this content is all there is).
        let hasSound: Bool = MissedCallAlertPolicy.localContentHasSound(
            inAppSoundEnabled: NotificationsGate.inAppSoundEnabled,
            isMissedCall: category == .missedCall,
            callInFlight: callInFlightProvider?() ?? false)
        if category == .messageDelivered {
            // The chat-message sound is the user's choice (Settings > Notifications > Message sounds).
            content.sound = MessageSoundPolicy.sound(for: MessageSoundStore.current, quietNow: false).notificationSound
        } else {
            content.sound = hasSound ? .default : nil
        }
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
    ///
    /// W-GRPRING — `groupCall` stamps the SAME `type` marker the server puts on
    /// its group ALERT push (`"incoming_group_call"`, internal/push/apns.go
    /// SendAlertGroupCallInvite) plus the group context. Without it, a user who
    /// answers this notification AFTER the app was killed (the notification
    /// outlives the process) lands in AppState's 1:1 answer branch — the group
    /// call would never be joined and a stale 1:1 auto-answer would be armed.
    /// Additive: the 1:1 call site passes nothing and its userInfo is unchanged.
    func postIncomingCall(callId: String, peerId: String, callerName: String, hasVideo: Bool,
                          groupCall: Bool = false, creatorName: String = "",
                          groupId: String = "", groupName: String = "") async {
        // BLOCK — no ringing banner for a call from a blocked contact, nor for a group call that contact created
        // (`peerId` is the creator of a group call): a backstop, the call paths drop it first.
        if BlockPolicy.isBlocked(peerId, in: BlockedContactsStore.loadBlockedIds()) {
            return
        }
        let content = UNMutableNotificationContent()
        // W-L10N-BATCH1 (2026-09-08) — UNMutableNotificationContent.title/
        // body are plain String, not LocalizedStringKey; explicit lookup.
        content.title = callerName.isEmpty
            ? String(localized: "notification.incoming_call.title", defaultValue: "Chiamata in arrivo", comment: "Local notification title when the caller name is unknown")
            : callerName
        if groupCall {
            content.body = hasVideo
                ? String(localized: "notification.incoming_call.body.group_video", defaultValue: "Videochiamata di gruppo Q-Audion", comment: "Local notification body — incoming group video call")
                : String(localized: "notification.incoming_call.body.group_audio", defaultValue: "Chiamata di gruppo Q-Audion", comment: "Local notification body — incoming group audio call")
        } else {
            content.body = hasVideo
                ? String(localized: "notification.incoming_call.body.video", defaultValue: "Videochiamata Q-Audion", comment: "Local notification body — incoming 1:1 video call")
                : String(localized: "notification.incoming_call.body.audio", defaultValue: "Chiamata Q-Audion", comment: "Local notification body — incoming 1:1 audio call")
        }
        // Ring sound. defaultRingtone (iOS 15.2+) loops like a call; else default.
        if #available(iOS 15.2, *) {
            content.sound = .defaultRingtone
        } else {
            content.sound = .default
        }
        content.categoryIdentifier = Category.incomingCall.rawValue
        var info: [String: String] = [
            "call_id": callId,
            "peer_id": peerId,
            "caller_name": callerName,
            "has_video": hasVideo ? "1" : "0",
        ]
        if groupCall {
            // Same key set the server's group push carries, so AppState's
            // rebuild path is identical for a local notification and an APNs one.
            info["type"] = "incoming_group_call"
            info["creator_id"] = peerId
            info["creator_name"] = creatorName.isEmpty ? callerName : creatorName
            info["call_type"] = hasVideo ? "video" : "audio"
            info["group_id"] = groupId
            info["group_name"] = groupName
        }
        content.userInfo = info as [AnyHashable: Any]
        content.threadIdentifier = Category.incomingCall.rawValue
        // Break through Focus/DnD. Needs the Time Sensitive Notifications entitlement
        // (com.apple.developer.usernotifications.time-sensitive, in the entitlements files).
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

    /// Runs a phone-transfer notice tap that arrived before `onPhoneTransferPendingTap` was set.
    /// Idempotent: no-op when nothing is latched or the handler still isn't set.
    func flushPendingPhoneTransferTap() {
        guard pendingPhoneTransferTap, let handler = onPhoneTransferPendingTap else { return }
        pendingPhoneTransferTap = false
        handler()
    }

    /// W-NOCALLKIT — clear a posted incoming-call notification (answered/ended).
    func clearIncomingCall(callId: String) {
        let id = "incoming-call-\(callId)"
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Removes the generic message alerts pushed by the server (see `RemoteMessageAlertPolicy`). Local banners and
    /// other categories are left alone.
    func clearRemoteMessageAlerts(for trigger: RemoteMessageAlertPolicy.Trigger) async {
        await RemoteMessageAlertCleaner(center: center).clear(for: trigger)
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
    //
    // Both callbacks take the completion-handler form and call the handler on the main actor: UIKit requires its
    // completion handler on the main thread, and the `async` form of a `nonisolated` method returns on a
    // background executor, where the compiler-generated bridge would call it.

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // BLOCK — an alert about a private message or call of a contact the user blocked (one the server pushed
        // before the block, or a local banner scheduled earlier) is not shown while the app is in front: no
        // banner, no list entry, no sound, no badge. In the background or with the app killed the system shows
        // the alert without asking the app, and only the server can keep it from being sent. A group call alert
        // of a blocked creator is suppressed like a private one; a group message alert carries a group id and is
        // not filtered (`BlockPolicy`).
        let alertInfo: [AnyHashable: Any] = notification.request.content.userInfo
        let blocked = BlockPolicy.suppressesNotification(userInfo: alertInfo, blocked: BlockedContactsStore.loadBlockedIds())
        let categoryId: String = notification.request.content.categoryIdentifier
        Task { @MainActor in
            completionHandler(self.foregroundPresentation(categoryId: categoryId, blocked: blocked))
        }
    }

    /// W405: foreground presentation respects the user's preferences. Banner suppressed if banners disabled; sound
    /// suppressed if in-app sound disabled or in quiet hours.
    ///
    /// W-MISSEDQUIET (2026-10-04): a missed-call notification that arrives while a call is in flight is shown
    /// quietly (banner / list, no sound). Every other notification, and a missed call outside a call, is
    /// presented exactly as before. The decision is `MissedCallAlertPolicy.foreground`.
    private func foregroundPresentation(categoryId: String, blocked: Bool) -> UNNotificationPresentationOptions {
        if blocked {
            RTLog.info("call", "block drop=1 kind=notif")
            return []
        }
        let isMissedCall: Bool = categoryId == Category.missedCall.rawValue
        let callInFlight: Bool = isMissedCall ? isCallInFlight() : false
        let presentation = MissedCallAlertPolicy.foreground(
            bannersEnabled: NotificationsGate.bannersEnabled,
            quietNow: NotificationsGate.isQuietNow,
            inAppSoundEnabled: NotificationsGate.inAppSoundEnabled,
            isMissedCall: isMissedCall,
            callInFlight: callInFlight)
        var options: UNNotificationPresentationOptions = []
        if presentation.banner { options.insert(.banner) }
        if presentation.sound { options.insert(.sound) }
        if presentation.list { options.insert(.list) }
        if presentation.badge { options.insert(.badge) }
        if categoryId == Category.messageDelivered.rawValue {
            // A message alert names the system sound (the server's push) or the chosen one (the app's own banner).
            // In front, the app plays the user's choice itself and tells the system to stay silent.
            options.remove(.sound)
            let settings = MessageSoundStore.current
            let quiet = NotificationsGate.isQuietNow
            let play = MessageSoundPolicy.foreground(settings, quietNow: quiet, masterHaptics: HapticFeedback.masterEnabled)
            // The message sound has its own switch; the banner switch still decides whether anything shows at all.
            if presentation.banner {
                MessageSoundPlayer.shared.play(play.sound)
                if play.vibrate { MessageSoundPlayer.shared.vibrate() }
            }
        }
        return options
    }

    /// W-MISSEDQUIET — `callInFlightProvider`, read on the main actor.
    private func isCallInFlight() -> Bool {
        callInFlightProvider?() ?? false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
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
        Task { @MainActor in
            self.handleResponse(category: categoryFinal, actionId: actionFinal, info: infoFinal)
            completionHandler()
        }
    }

    private func handleResponse(category categoryFinal: Category?, actionId actionFinal: String, info infoFinal: [String: String]) {
        if categoryFinal != .incomingCall,
           actionFinal == UNNotificationDefaultActionIdentifier,
           PhoneTransferNotice.isPendingPush(userInfo: infoFinal) {
            if let handler = self.onPhoneTransferPendingTap {
                handler()
            } else {
                self.pendingPhoneTransferTap = true
            }
        } else if categoryFinal == .incomingCall {
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
            if cat == .messageDelivered, RemoteMessageAlertPolicy.isGenericTap(userInfo: infoFinal) {
                // Generic alert pushed by the server: the alerts of the burst go; the messages arrive over the socket.
                Task { await self.clearRemoteMessageAlerts(for: .alertTapped) }
            }
            self.onNotificationTap?(cat, infoFinal)
        }
    }
}
