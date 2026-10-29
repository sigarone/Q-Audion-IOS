import XCTest
import UserNotifications
@testable import QAudionApp

/// The generic server-pushed message alert is cleared before the app posts its own banner, and never touches the
/// app's local banners or other categories.
final class RemoteMessageAlertPolicyTests: XCTestCase {

    private typealias D = RemoteMessageAlertPolicy.Delivered

    func testRemoteAlertIsRecognised() {
        XCTAssertTrue(RemoteMessageAlertPolicy.isRemoteMessageAlert(category: "QAUDION_MESSAGE_DELIVERED", thread: "messages"))
    }

    func testLocalBannerIsNotRemote() {
        // The local banner uses the category as its thread.
        XCTAssertFalse(RemoteMessageAlertPolicy.isRemoteMessageAlert(
            category: "QAUDION_MESSAGE_DELIVERED", thread: "QAUDION_MESSAGE_DELIVERED"))
    }

    func testOtherCategoryOnSameThreadIsNotRemoteMessage() {
        XCTAssertFalse(RemoteMessageAlertPolicy.isRemoteMessageAlert(category: "QAUDION_MISSED_CALL", thread: "messages"))
        XCTAssertFalse(RemoteMessageAlertPolicy.isRemoteMessageAlert(category: "", thread: "messages"))
    }

    func testOnlyRemoteAlertsAreSelected() {
        let delivered = [
            D(identifier: "a", category: "QAUDION_MESSAGE_DELIVERED", thread: "messages"),
            D(identifier: "b", category: "QAUDION_MESSAGE_DELIVERED", thread: "QAUDION_MESSAGE_DELIVERED"),
            D(identifier: "c", category: "INCOMING_CALL", thread: "calls"),
            D(identifier: "d", category: "QAUDION_MESSAGE_DELIVERED", thread: "messages"),
        ]
        XCTAssertEqual(RemoteMessageAlertPolicy.identifiersToRemove(from: delivered), ["a", "d"])
    }

    func testNothingToRemoveWhenNoneDelivered() {
        XCTAssertEqual(RemoteMessageAlertPolicy.identifiersToRemove(from: []), [])
    }
}

/// What the notification center holds is converted to the policy's view of it, and every moment that makes the generic
/// alert useless clears it without touching anything else.
final class RemoteMessageAlertCleanerTests: XCTestCase {

    private typealias D = RemoteMessageAlertPolicy.Delivered

    private final class FakeCenter: DeliveredAlertCenter {
        var delivered: [D]
        private(set) var removed: [[String]] = []
        init(_ delivered: [D]) { self.delivered = delivered }
        func deliveredAlerts() async -> [D] { delivered }
        func removeDelivered(identifiers: [String]) {
            removed.append(identifiers)
            delivered.removeAll { identifiers.contains($0.identifier) }
        }
    }

    private let generic = D(identifier: "g1", category: "QAUDION_MESSAGE_DELIVERED", thread: "messages")
    private let local = D(identifier: "l1", category: "QAUDION_MESSAGE_DELIVERED", thread: "QAUDION_MESSAGE_DELIVERED")
    private let call = D(identifier: "c1", category: "INCOMING_CALL", thread: "calls")

    func testContentIsConvertedToDelivered() {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "QAUDION_MESSAGE_DELIVERED"
        content.threadIdentifier = "messages"
        XCTAssertEqual(
            RemoteMessageAlertPolicy.delivered(identifier: "x", content: content),
            D(identifier: "x", category: "QAUDION_MESSAGE_DELIVERED", thread: "messages"))
    }

    func testContentWithoutCategoryOrThreadIsConvertedToEmptyFields() {
        XCTAssertEqual(
            RemoteMessageAlertPolicy.delivered(identifier: "y", content: UNMutableNotificationContent()),
            D(identifier: "y", category: "", thread: ""))
    }

    func testEveryTriggerClearsTheGenericAlertAndOnlyThat() async {
        for trigger in RemoteMessageAlertPolicy.Trigger.allCases {
            let center = FakeCenter([generic, local, call])
            let removed = await RemoteMessageAlertCleaner(center: center).clear(for: trigger)
            XCTAssertEqual(removed, ["g1"], "\(trigger)")
            XCTAssertEqual(center.delivered, [local, call], "\(trigger)")
        }
    }

    func testNothingIsRemovedWhenNoGenericAlertIsDelivered() async {
        let center = FakeCenter([local, call])
        let removed = await RemoteMessageAlertCleaner(center: center).clear(for: .sceneActive)
        XCTAssertEqual(removed, [])
        XCTAssertTrue(center.removed.isEmpty)
    }

    func testAnAlertThatArrivesAfterwardsIsClearedByTheNextTrigger() async {
        let center = FakeCenter([generic])
        let cleaner = RemoteMessageAlertCleaner(center: center)
        await cleaner.clear(for: .inboundStored)
        center.delivered.append(D(identifier: "g2", category: "QAUDION_MESSAGE_DELIVERED", thread: "messages"))
        let removed = await cleaner.clear(for: .sceneActive)
        XCTAssertEqual(removed, ["g2"])
    }

    func testTapOnGenericAlertIsRecognised() {
        XCTAssertTrue(RemoteMessageAlertPolicy.isGenericTap(userInfo: [:]))
        XCTAssertTrue(RemoteMessageAlertPolicy.isGenericTap(userInfo: ["aps": "x"]))
    }

    func testTapOnLocalBannerIsNotGeneric() {
        XCTAssertFalse(RemoteMessageAlertPolicy.isGenericTap(userInfo: ["conversationId": "1"]))
        XCTAssertFalse(RemoteMessageAlertPolicy.isGenericTap(userInfo: ["groupId": "ab"]))
    }

    func testPushedMessageAlertIsHiddenWhileTheAppIsInFront() {
        XCTAssertTrue(RemoteMessageAlertPolicy.isHiddenInForeground(
            category: "QAUDION_MESSAGE_DELIVERED", thread: "messages", enriched: false))
        // Rewritten by the notification extension: its thread is the conversation's, the marker tells it apart.
        XCTAssertTrue(RemoteMessageAlertPolicy.isHiddenInForeground(
            category: "QAUDION_MESSAGE_DELIVERED", thread: "u:abc", enriched: true))
    }

    func testLocalBannerAndOtherCategoriesStayVisibleInFront() {
        XCTAssertFalse(RemoteMessageAlertPolicy.isHiddenInForeground(
            category: "QAUDION_MESSAGE_DELIVERED", thread: "QAUDION_MESSAGE_DELIVERED", enriched: false))
        XCTAssertFalse(RemoteMessageAlertPolicy.isHiddenInForeground(
            category: "INCOMING_CALL", thread: "calls", enriched: false))
        XCTAssertFalse(RemoteMessageAlertPolicy.isHiddenInForeground(
            category: "QAUDION_MISSED_CALL", thread: "messages", enriched: true))
    }
}
