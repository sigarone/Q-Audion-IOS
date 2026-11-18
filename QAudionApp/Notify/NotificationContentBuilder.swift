import Foundation
import UserNotifications
#if canImport(QAudionEngine)
import QAudionEngine
#endif

/// Turns the plan of an opened envelope into the content of the notification. Pure over its inputs, so the app tests
/// it; the notification extension compiles this file and `NotifyContentPlan` directly.
enum NotificationContentBuilder {

    /// userInfo marker of a notification the extension rewrote (the app clears these like the generic alerts).
    static let enrichedKey = "qaEnriched"
    /// userInfo key naming the conversation (`u:<user>` or `g:<group>`); never leaves the device.
    static let conversationKey = "qaConv"

    /// Where filtering (an empty content for a muted conversation) will go once the filtering entitlement exists.
    /// Off: without the entitlement the system would show an empty alert.
    static let suppressesMutedConversations = false

    /// Body of a rewritten notification: no message text, ever. The strings live in the app's catalog; the extension
    /// passes the bundle of the app that contains it.
    static func newMessageBody(bundle: Bundle) -> String {
        String(localized: "notification.message.new_body", defaultValue: "Nuovo messaggio", bundle: bundle,
               comment: "Body of a message notification once the sender is known. No message text is ever shown.")
    }

    /// The bundle with the app's strings, from inside the extension (`App.app/PlugIns/X.appex`) or the app itself.
    static func appBundle(from bundle: Bundle) -> Bundle {
        guard bundle.bundleURL.pathExtension == "appex" else { return bundle }
        let app = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app) ?? bundle
    }

    /// The generic alert kept as it is, with the sound the user chose.
    static func applyGeneric(to content: UNMutableNotificationContent, settings: MessageSoundSettings) {
        content.sound = MessageSoundPolicy.sound(for: settings, quietNow: false).notificationSound
    }

    /// The rewritten notification.
    static func apply(_ plan: NotifyContentPlan, to content: UNMutableNotificationContent,
                      settings: MessageSoundSettings, body: String) {
        if let title = plan.title { content.title = title }
        content.body = body
        content.threadIdentifier = plan.threadIdentifier
        var info = content.userInfo
        info[enrichedKey] = "1"
        info[conversationKey] = plan.conversationKey
        content.userInfo = info
        if plan.muted {
            content.sound = nil
            if #available(iOS 15.0, *) { content.interruptionLevel = .passive }
        } else {
            content.sound = MessageSoundPolicy.sound(for: settings, quietNow: false).notificationSound
        }
    }

    /// The alert while this device shares its screen: no name, no photo and no thread of the conversation, so the
    /// banner names nobody. The title stays the generic one, the body is the fixed text, and the sound follows the mute
    /// of the conversation. The markers the app reads (to clear the alert, to open the conversation) are kept.
    static func applyWhileSharing(_ plan: NotifyContentPlan, to content: UNMutableNotificationContent,
                                  settings: MessageSoundSettings, body: String) {
        content.body = body
        var info = content.userInfo
        info[enrichedKey] = "1"
        info[conversationKey] = plan.conversationKey
        content.userInfo = info
        if plan.muted {
            content.sound = nil
            if #available(iOS 15.0, *) { content.interruptionLevel = .passive }
        } else {
            content.sound = MessageSoundPolicy.sound(for: settings, quietNow: false).notificationSound
        }
    }

    /// The texts of a banner of the app that would name a person (a message, a missed call) while this device shares
    /// its screen: the name of the app and a fixed text.
    static func sharingBanner(isMissedCall: Bool, bundle: Bundle) -> (title: String, body: String) {
        let body = isMissedCall
            ? String(localized: "notification.call.missed.title", defaultValue: "Chiamata persa", bundle: bundle,
                     comment: "Title of the local notification posted for a missed call.")
            : newMessageBody(bundle: bundle)
        return ("Q-Audion", body)
    }

    /// The conversation a rewritten notification belongs to, from its userInfo.
    static func conversationTarget(userInfo: [String: String]) -> (isGroup: Bool, id: String)? {
        guard let key = userInfo[conversationKey], key.count > 2 else { return nil }
        let id = String(key.dropFirst(2))
        switch key.prefix(2) {
        case "u:": return (false, id)
        case "g:": return (true, id)
        default: return nil
        }
    }
}
