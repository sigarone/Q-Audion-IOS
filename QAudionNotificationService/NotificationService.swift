import Foundation
import Intents
import UserNotifications

/// Rewrites a message alert with the name and photo of the sender.
///
/// The server seals "who wrote" (and the group) into the `qn` value of the alert for this device only. This extension
/// opens it with the notification key from the shared keychain group, looks the sender up in the small list the app
/// keeps in the App Group container, and shows the name, a photo and a fixed "New message" body. The message text is
/// never in the push. Whatever goes wrong, the generic alert stays. Nothing is logged: no blob, key or name.
final class NotificationService: UNNotificationServiceExtension {

    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var best: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        self.contentHandler = contentHandler
        lock.unlock()

        let original = request.content
        let generic = (original.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let soundSettings = MessageSoundStore().load(legacyInAppSound: true)
        NotificationContentBuilder.applyGeneric(to: generic, settings: soundSettings)
        setBest(generic)

        guard let plan = Self.openPlan(userInfo: original.userInfo) else {
            deliver(generic)
            return
        }
        let bundle = NotificationContentBuilder.appBundle(from: .main)
        let rewritten = (original.mutableCopy() as? UNMutableNotificationContent) ?? generic
        NotificationContentBuilder.apply(plan, to: rewritten, settings: soundSettings,
                                         body: NotificationContentBuilder.newMessageBody(bundle: bundle))
        // Muted conversations: the place where the filtering entitlement will return an empty content.
        if NotificationContentBuilder.suppressesMutedConversations && plan.muted {
            deliver(UNNotificationContent())
            return
        }
        setBest(rewritten)

        guard NotifyPreferences().siriDonationsEnabled else {
            deliver(rewritten)
            return
        }
        donate(plan, content: rewritten)
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let content = best
        lock.unlock()
        if let content { deliver(content) }
    }

    // MARK: - Opening

    /// The plan for this alert, or nil when it carries no usable envelope (missing, wrong key, old, malformed).
    private static func openPlan(userInfo: [AnyHashable: Any]) -> NotifyContentPlan? {
        guard let blob = userInfo["qn"] as? String,
              let keychain = NotifyKeychain.production(),
              let privateKey = keychain.load(),
              let plaintext = try? NotifyEnvelope.open(blobBase64: blob, devicePrivateKey: privateKey),
              plaintext.isFresh() else { return nil }
        let rubrica = NotifyRubricaFiles.defaultDirectory().flatMap { NotifyRubricaFiles.read(from: $0) }
        return NotifyContentPlan.make(from: plaintext, rubrica: rubrica)
    }

    // MARK: - Siri donation

    private func donate(_ plan: NotifyContentPlan, content: UNMutableNotificationContent) {
        var image: INImage?
        if let file = plan.avatarFile, let directory = NotifyRubricaFiles.defaultDirectory(),
           let url = NotifyRubricaFiles.avatarURL(file, in: directory),
           let data = try? Data(contentsOf: url) {
            image = INImage(imageData: data)
        }
        let handle = INPersonHandle(value: plan.senderID, type: .unknown)
        let sender = INPerson(personHandle: handle, nameComponents: nil,
                              displayName: plan.senderName ?? content.title, image: image,
                              contactIdentifier: nil, customIdentifier: plan.senderID)
        let group = plan.groupName.map { INSpeakableString(spokenPhrase: $0) }
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
                                         content: nil, speakableGroupName: group,
                                         conversationIdentifier: plan.threadIdentifier, serviceName: nil,
                                         sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        // Lets the app remove these donations (consent withdrawn, logout).
        interaction.groupIdentifier = NotifyPreferences.donationGroupIdentifier(thread: plan.threadIdentifier)
        interaction.donate { [weak self] _ in
            guard let self else { return }
            do {
                self.deliver(try content.updating(from: intent))
            } catch {
                self.deliver(content)
            }
        }
    }

    // MARK: - Delivery

    private func setBest(_ content: UNNotificationContent) {
        lock.lock()
        best = content
        lock.unlock()
    }

    /// Hands the content to the system once.
    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        handler?(content)
    }
}
