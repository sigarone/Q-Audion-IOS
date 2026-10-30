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
    /// What the diagnostics breadcrumb needs, filled while the alert is handled (under `lock`).
    private var diag = DiagContext()

    private struct DiagContext {
        var enabled = true
        var keyPresent = false
        var soundId = "system"
        var kindBefore = "silent"
        var muted = false
        var origSound = false
        var sndBefore = "none"
    }

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.lock()
        self.contentHandler = contentHandler
        lock.unlock()

        let original = request.content
        let generic = (original.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        let soundStore = MessageSoundStore()
        let soundSnapshot = soundStore.snapshot(legacyInAppSound: true)
        let soundSettings = soundSnapshot.settings
        lock.lock()
        diag = DiagContext(enabled: soundSettings.soundEnabled, keyPresent: soundSnapshot.keyPresent,
                           soundId: soundSettings.soundId, kindBefore: NotifySoundDiag.kind(of: original.sound),
                           muted: false, origSound: original.sound != nil,
                           sndBefore: NotifySoundDiag.info(of: original.sound).snd)
        lock.unlock()
        NotificationContentBuilder.applyGeneric(to: generic, settings: soundSettings)
        setBest(generic)

        guard let plan = Self.openPlan(userInfo: original.userInfo) else {
            deliver(generic, step: "generic")
            return
        }
        lock.lock()
        diag.muted = plan.muted
        lock.unlock()
        let bundle = NotificationContentBuilder.appBundle(from: .main)
        let rewritten = (original.mutableCopy() as? UNMutableNotificationContent) ?? generic
        NotificationContentBuilder.apply(plan, to: rewritten, settings: soundSettings,
                                         body: NotificationContentBuilder.newMessageBody(bundle: bundle))
        // Muted conversations: the place where the filtering entitlement will return an empty content.
        if NotificationContentBuilder.suppressesMutedConversations && plan.muted {
            deliver(UNNotificationContent(), step: "rewritten")
            return
        }
        setBest(rewritten)

        guard NotifyPreferences().siriDonationsEnabled else {
            deliver(rewritten, step: "rewritten")
            return
        }
        donate(plan, content: rewritten)
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let content = best
        lock.unlock()
        if let content { deliver(content, step: "expired") }
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
                self.deliver(try content.updating(from: intent), step: "donated")
            } catch {
                self.deliver(content, step: "donateFailed")
            }
        }
    }

    // MARK: - Delivery

    private func setBest(_ content: UNNotificationContent) {
        lock.lock()
        best = content
        lock.unlock()
    }

    /// Hands the content to the system once. `step` names the path for the diagnostics breadcrumb, written (one small
    /// synchronous defaults write, nothing awaited) before the handler runs and only for the delivery that counts.
    private func deliver(_ content: UNNotificationContent, step: String) {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        let context = diag
        lock.unlock()
        guard let handler else { return }
        var level = "active"
        if #available(iOS 15.0, *) { level = NotifySoundDiag.interruption(content.interruptionLevel) }
        NotifySoundDiag.record(NotifySoundDiag.Breadcrumb(
            step: step, enabled: context.enabled, keyPresent: context.keyPresent, soundId: context.soundId,
            kindBefore: context.kindBefore, kindAfter: NotifySoundDiag.kind(of: content.sound), muted: context.muted,
            interruption: level, origSound: context.origSound, sndBefore: context.sndBefore,
            snd: NotifySoundDiag.info(of: content.sound).snd, time: Int(Date().timeIntervalSince1970)))
        handler(content)
    }
}
