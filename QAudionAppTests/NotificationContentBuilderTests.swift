import XCTest
import UserNotifications
import QAudionEngine
@testable import QAudionApp

/// What the notification extension puts into a rewritten message alert: title, body, thread, sound and mute.
final class NotificationContentBuilderTests: XCTestCase {

    private func plan(sender: String = "s1", group: String? = nil, rubrica: NotifyRubrica) -> NotifyContentPlan {
        let plaintext = NotifyEnvelope.Plaintext(
            kind: group == nil ? .dm : .grp, senderID: sender, groupID: group, timestamp: 1)
        return NotifyContentPlan.make(from: plaintext, rubrica: rubrica)
    }

    private func rubrica() -> NotifyRubrica {
        NotifyRubrica.build(
            people: [(id: "s1", person: .init(name: "Anna", avatar: "x.jpg")),
                     (id: "s2", person: .init(name: "Bruno", muted: true))],
            groups: [(id: "g1", group: .init(name: "Famiglia")), (id: "g2", group: .init(name: "Lavoro", muted: true))])
    }

    private func generic() -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Q-Audion"
        content.body = "generic"
        content.threadIdentifier = "messages"
        content.categoryIdentifier = "QAUDION_MESSAGE_DELIVERED"
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "qa_msg.wav"))
        return content
    }

    private let on = MessageSoundSettings(soundEnabled: true, soundId: "nota", hapticEnabled: true)
    private let off = MessageSoundSettings(soundEnabled: false, soundId: "nota", hapticEnabled: true)

    func testTitleBodyAndThreadOfAKnownSender() {
        let content = generic()
        let p = plan(rubrica: rubrica())
        NotificationContentBuilder.apply(p, to: content, settings: on, body: "New message")
        XCTAssertEqual(content.title, "Anna")
        XCTAssertEqual(content.body, "New message")
        XCTAssertEqual(content.threadIdentifier, p.threadIdentifier)
        XCTAssertNotEqual(content.threadIdentifier, "messages")
        XCTAssertEqual(content.categoryIdentifier, "QAUDION_MESSAGE_DELIVERED")
    }

    func testGroupTitle() {
        let content = generic()
        NotificationContentBuilder.apply(plan(group: "g1", rubrica: rubrica()), to: content, settings: on, body: "b")
        XCTAssertEqual(content.title, "Anna \u{00B7} Famiglia")
    }

    func testUnknownSenderKeepsTheGenericTitle() {
        let content = generic()
        NotificationContentBuilder.apply(plan(sender: "nobody", rubrica: rubrica()), to: content, settings: on, body: "b")
        XCTAssertEqual(content.title, "Q-Audion")
        XCTAssertEqual(content.body, "b")
    }

    func testSoundFollowsTheSettings() {
        let chosen = generic()
        NotificationContentBuilder.apply(plan(rubrica: rubrica()), to: chosen, settings: on, body: "b")
        XCTAssertNotNil(chosen.sound)
        let silent = generic()
        NotificationContentBuilder.apply(plan(rubrica: rubrica()), to: silent, settings: off, body: "b")
        XCTAssertNil(silent.sound)
        let system = generic()
        NotificationContentBuilder.apply(
            plan(rubrica: rubrica()), to: system,
            settings: MessageSoundSettings(soundEnabled: true, soundId: "system", hapticEnabled: true), body: "b")
        XCTAssertNotNil(system.sound)
    }

    func testMutedConversationIsSilentAndPassive() {
        for p in [plan(sender: "s2", rubrica: rubrica()), plan(group: "g2", rubrica: rubrica())] {
            let content = generic()
            NotificationContentBuilder.apply(p, to: content, settings: on, body: "b")
            XCTAssertTrue(p.muted)
            XCTAssertNil(content.sound)
            XCTAssertEqual(content.interruptionLevel, .passive)
        }
    }

    func testFilteringStaysOffUntilTheEntitlementExists() {
        XCTAssertFalse(NotificationContentBuilder.suppressesMutedConversations)
    }

    func testGenericKeepsTheContentAndAppliesTheSoundChoice() {
        let content = generic()
        NotificationContentBuilder.applyGeneric(to: content, settings: off)
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.title, "Q-Audion")
        XCTAssertEqual(content.threadIdentifier, "messages")
    }

    func testTheRewrittenAlertCarriesTheMarkersTheAppReads() {
        let content = generic()
        NotificationContentBuilder.apply(plan(group: "g1", rubrica: rubrica()), to: content, settings: on, body: "b")
        let info = content.userInfo as? [String: String] ?? [:]
        XCTAssertEqual(info[NotificationContentBuilder.enrichedKey], "1")
        let target = NotificationContentBuilder.conversationTarget(userInfo: info)
        XCTAssertEqual(target?.isGroup, true)
        XCTAssertEqual(target?.id, "g1")
        XCTAssertFalse(RemoteMessageAlertPolicy.isGenericTap(userInfo: info))
        XCTAssertNil(NotificationContentBuilder.conversationTarget(userInfo: [:]))
        XCTAssertNil(NotificationContentBuilder.conversationTarget(userInfo: [NotificationContentBuilder.conversationKey: "x:1"]))
    }

    func testRewrittenAlertsAreClearedWithTheGenericOnes() {
        let delivered = [
            RemoteMessageAlertPolicy.Delivered(identifier: "a", category: "QAUDION_MESSAGE_DELIVERED", thread: "qa-1", enriched: true),
            RemoteMessageAlertPolicy.Delivered(identifier: "b", category: "QAUDION_MESSAGE_DELIVERED", thread: "qa-2"),
            RemoteMessageAlertPolicy.Delivered(identifier: "c", category: "INCOMING_CALL", thread: "x", enriched: true),
        ]
        XCTAssertEqual(RemoteMessageAlertPolicy.identifiersToRemove(from: delivered), ["a"])
    }

    private func freshPreferences() -> NotifyPreferences {
        let name = "NotifyPreferencesTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return NotifyPreferences(defaults: defaults)
    }

    func testDonationsAreOffUntilTheUserConsentsToSiriMessaging() {
        let prefs = freshPreferences()
        XCTAssertFalse(prefs.siriDonationsEnabled)
        var deleted = 0
        NotifyDonations.syncConsent(consent: false, preferences: prefs, deleter: { deleted += 1 })
        XCTAssertFalse(prefs.siriDonationsEnabled)
        XCTAssertEqual(deleted, 0)
        NotifyDonations.syncConsent(consent: true, preferences: prefs, deleter: { deleted += 1 })
        XCTAssertTrue(prefs.siriDonationsEnabled)
        XCTAssertEqual(deleted, 0)
    }

    func testWithdrawingConsentDeletesTheDonationsOnce() {
        let prefs = freshPreferences()
        var deleted = 0
        NotifyDonations.consentChanged(to: true, preferences: prefs, deleter: { deleted += 1 })
        XCTAssertTrue(prefs.siriDonationsEnabled)
        NotifyDonations.consentChanged(to: false, preferences: prefs, deleter: { deleted += 1 })
        XCTAssertFalse(prefs.siriDonationsEnabled)
        XCTAssertEqual(deleted, 1)
        NotifyDonations.consentChanged(to: false, preferences: prefs, deleter: { deleted += 1 })
        XCTAssertEqual(deleted, 1)
        // A withdrawal noticed only at the next launch also deletes.
        NotifyDonations.consentChanged(to: true, preferences: prefs, deleter: { deleted += 1 })
        NotifyDonations.syncConsent(consent: false, preferences: prefs, deleter: { deleted += 1 })
        XCTAssertEqual(deleted, 2)
    }

    func testDonationGroupIdentifierCarriesThePrefixAndTheThread() {
        let thread = NotifyContentPlan.threadIdentifier(forKey: "u:abc")
        let id = NotifyPreferences.donationGroupIdentifier(thread: thread)
        XCTAssertTrue(id.hasPrefix("qaudion.notify."))
        XCTAssertTrue(id.hasSuffix(thread))
    }
}
