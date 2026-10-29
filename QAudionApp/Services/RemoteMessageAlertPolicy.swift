import Foundation
import UserNotifications

/// A server-pushed generic message alert (title and body come from the app's own strings through loc-keys) is shown
/// while the app has no live connection. Once the app is running again it posts its own banner with the real sender
/// and text, so the generic one must go first or the user sees the same message twice. The decision is a pure
/// function over the delivered notifications so it can be tested without a notification center.
enum RemoteMessageAlertPolicy {

    /// Thread identifier the server stamps on the generic message alert (the app's own local banners use the
    /// category as their thread, so the two never share a group).
    static let remoteThreadIdentifier = "messages"

    /// Category of every message alert, remote or local.
    static let messageCategory = "QAUDION_MESSAGE_DELIVERED"

    struct Delivered: Equatable {
        let identifier: String
        let category: String
        let thread: String
        /// Rewritten by the notification extension (it carries the `qaEnriched` marker): it replaced the generic text
        /// and thread but is still the server's alert, so it goes with the generic ones.
        var enriched: Bool = false
    }

    /// True for the generic alert pushed by the server.
    static func isRemoteMessageAlert(category: String, thread: String) -> Bool {
        category == messageCategory && thread == remoteThreadIdentifier
    }

    /// True for an alert the server pushed (generic, or rewritten by the notification extension) that must not be
    /// shown while the app is in front: a message reaches the open app over its socket and the app shows its own
    /// banner, so the pushed one would only repeat it. The server sends the alert for a socket that did not report
    /// the foreground yet (a reconnect, the moment before the app comes forward).
    static func isHiddenInForeground(category: String, thread: String, enriched: Bool) -> Bool {
        isRemoteMessageAlert(category: category, thread: thread) || (enriched && category == messageCategory)
    }

    /// Identifiers of the delivered notifications to remove before the app posts a local message banner or once
    /// the user has seen the messages.
    static func identifiersToRemove(from delivered: [Delivered]) -> [String] {
        delivered
            .filter { isRemoteMessageAlert(category: $0.category, thread: $0.thread)
                || ($0.enriched && $0.category == messageCategory) }
            .map(\.identifier)
    }

    /// Maps a delivered notification's content to the fields the policy looks at.
    static func delivered(identifier: String, content: UNNotificationContent) -> Delivered {
        Delivered(identifier: identifier, category: content.categoryIdentifier, thread: content.threadIdentifier,
                  enriched: content.userInfo[NotificationContentBuilder.enrichedKey] as? String == "1")
    }

    /// A tap on a message alert that names neither a 1:1 conversation nor a group is the generic alert: the app
    /// opens on its chat list.
    static func isGenericTap(userInfo: [String: String]) -> Bool {
        userInfo["conversationId"] == nil && userInfo["groupId"] == nil
            && NotificationContentBuilder.conversationTarget(userInfo: userInfo) == nil
    }

    /// Moments at which the generic alert is no longer needed.
    enum Trigger: CaseIterable {
        /// The socket drain stored inbound messages (a banner may or may not follow; muted or open chats post none).
        case inboundStored
        /// The app became active, with or without a chat already open.
        case sceneActive
        /// A chat was opened.
        case chatOpened
        /// The generic alert itself was tapped.
        case alertTapped
    }
}

/// The part of the notification center the clearing needs, so tests can stand in for it.
protocol DeliveredAlertCenter {
    func deliveredAlerts() async -> [RemoteMessageAlertPolicy.Delivered]
    func removeDelivered(identifiers: [String])
}

extension UNUserNotificationCenter: DeliveredAlertCenter {
    func deliveredAlerts() async -> [RemoteMessageAlertPolicy.Delivered] {
        await withCheckedContinuation { cont in
            getDeliveredNotifications { delivered in
                cont.resume(returning: delivered.map {
                    RemoteMessageAlertPolicy.delivered(identifier: $0.request.identifier, content: $0.request.content)
                })
            }
        }
    }

    func removeDelivered(identifiers: [String]) {
        removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Removes the delivered generic message alerts from a notification center.
struct RemoteMessageAlertCleaner {
    let center: DeliveredAlertCenter

    @discardableResult
    func clear(for trigger: RemoteMessageAlertPolicy.Trigger) async -> [String] {
        let ids = RemoteMessageAlertPolicy.identifiersToRemove(from: await center.deliveredAlerts())
        if !ids.isEmpty { center.removeDelivered(identifiers: ids) }
        return ids
    }
}
