import XCTest
import UIKit
@testable import QAudionApp

/// The Home Screen quick actions: which items the icon menu shows, which type the app accepts, and when a request left for the chat
/// list is shown, kept or dropped (session, app lock, remote switch, account, age). Pure: the inputs of `QuickActions` are replaced.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class QuickActionTests: XCTestCase {

    private let account = "99999999-9999-9999-9999-999999999999"
    private let other = "88888888-8888-8888-8888-888888888888"
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func request(_ kind: QuickActionKind, account: String?, at: Date? = nil) -> QuickActionRequest {
        QuickActionRequest(kind: kind, accountId: account, createdAt: at ?? t0)
    }

    private func take(
        _ slot: inout QuickActionRequest?, signedIn: Bool = true, location: Bool = true, locked: Bool = false, offset: TimeInterval = 1
    ) -> QuickActionPresentation? {
        QuickActionPolicy.take(
            &slot, accountId: account, signedIn: signedIn, locationEnabled: location, appLocked: locked,
            now: t0.addingTimeInterval(offset))
    }

    // MARK: Items

    func testSignedOutShowsNoItems() {
        XCTAssertEqual(QuickActionPolicy.visibleKinds(signedIn: false, locationEnabled: true), [])
        XCTAssertEqual(QuickActionPolicy.visibleKinds(signedIn: false, locationEnabled: false), [])
    }

    func testLocationItemFollowsTheRemoteSwitch() {
        XCTAssertEqual(QuickActionPolicy.visibleKinds(signedIn: true, locationEnabled: true), [.shareLocation, .newMessage])
        XCTAssertEqual(QuickActionPolicy.visibleKinds(signedIn: true, locationEnabled: false), [.newMessage])
    }

    func testItemsCarryTypeTitleAndSymbol() {
        let savedSignedIn = QuickActions.signedIn
        let savedLocation = QuickActions.locationEnabled
        defer {
            QuickActions.signedIn = savedSignedIn
            QuickActions.locationEnabled = savedLocation
        }
        QuickActions.signedIn = { true }
        QuickActions.locationEnabled = { true }
        let items = QuickActions.items()
        XCTAssertEqual(items.map { $0.type }, [QuickActionKind.shareLocation.rawValue, QuickActionKind.newMessage.rawValue])
        XCTAssertTrue(items.allSatisfy { !$0.localizedTitle.isEmpty })
        XCTAssertTrue(items.allSatisfy { $0.icon != nil })
        QuickActions.locationEnabled = { false }
        XCTAssertEqual(QuickActions.items().map { $0.type }, [QuickActionKind.newMessage.rawValue])
        QuickActions.signedIn = { false }
        XCTAssertTrue(QuickActions.items().isEmpty)
    }

    func testRefreshSetsTheMenu() {
        let savedSignedIn = QuickActions.signedIn
        let savedLocation = QuickActions.locationEnabled
        let savedSet = QuickActions.setItems
        defer {
            QuickActions.signedIn = savedSignedIn
            QuickActions.locationEnabled = savedLocation
            QuickActions.setItems = savedSet
        }
        var menus: [[String]] = []
        QuickActions.setItems = { menus.append($0.map { $0.type }) }
        QuickActions.signedIn = { true }
        QuickActions.locationEnabled = { false }
        QuickActions.refresh()
        QuickActions.signedIn = { false }
        QuickActions.refresh()
        XCTAssertEqual(menus, [[QuickActionKind.newMessage.rawValue], []])
    }

    // MARK: Tap

    func testKnownAndUnknownTypes() {
        XCTAssertEqual(QuickActionPolicy.kind(forType: QuickActionKind.shareLocation.rawValue), .shareLocation)
        XCTAssertEqual(QuickActionPolicy.kind(forType: QuickActionKind.newMessage.rawValue), .newMessage)
        XCTAssertNil(QuickActionPolicy.kind(forType: "com.example.other"))
        XCTAssertNil(QuickActionPolicy.kind(forType: ""))
    }

    func testHandleRecordsAKnownTypeAndIgnoresAnUnknownOne() {
        let savedSignedIn = QuickActions.signedIn
        let savedAccount = QuickActions.accountId
        let savedNow = QuickActions.now
        let savedDeliver = QuickActions.deliver
        defer {
            QuickActions.signedIn = savedSignedIn
            QuickActions.accountId = savedAccount
            QuickActions.now = savedNow
            QuickActions.deliver = savedDeliver
        }
        var delivered: [QuickActionRequest] = []
        QuickActions.deliver = { delivered.append($0) }
        let start: Date = t0
        QuickActions.now = { start }
        let me: String = account
        QuickActions.accountId = { me }
        QuickActions.signedIn = { true }
        XCTAssertTrue(QuickActions.handle(type: QuickActionKind.shareLocation.rawValue))
        XCTAssertFalse(QuickActions.handle(type: "com.example.other"))
        // A cold launch has no restored session yet: the request is not bound to an account.
        QuickActions.signedIn = { false }
        XCTAssertTrue(QuickActions.handle(type: QuickActionKind.newMessage.rawValue))
        XCTAssertEqual(delivered, [
            QuickActionRequest(kind: .shareLocation, accountId: me, createdAt: start),
            QuickActionRequest(kind: .newMessage, accountId: nil, createdAt: start)
        ])
    }

    // MARK: Take

    func testNewMessageIsShownOnceAndTheSlotIsCleared() {
        var slot: QuickActionRequest? = request(.newMessage, account: account)
        XCTAssertEqual(take(&slot), .newMessage)
        XCTAssertNil(slot)
        XCTAssertNil(take(&slot))
    }

    func testLocationPickerIsShownWhenTheSwitchIsOn() {
        var slot: QuickActionRequest? = request(.shareLocation, account: account)
        XCTAssertEqual(take(&slot), .locationPicker)
        XCTAssertNil(slot)
    }

    func testLocationRequestIsDroppedWhenTheSwitchIsOff() {
        var slot: QuickActionRequest? = request(.shareLocation, account: account)
        XCTAssertNil(take(&slot, location: false))
        XCTAssertNil(slot)
        // New message does not depend on the switch.
        slot = request(.newMessage, account: account)
        XCTAssertEqual(take(&slot, location: false), .newMessage)
    }

    func testRequestWaitsBehindTheAppLockThenIsShown() {
        var slot: QuickActionRequest? = request(.newMessage, account: account)
        XCTAssertNil(take(&slot, locked: true))
        XCTAssertNotNil(slot)
        XCTAssertEqual(take(&slot, locked: false, offset: 60), .newMessage)
        XCTAssertNil(slot)
    }

    func testRequestExpiresBehindTheAppLock() {
        var slot: QuickActionRequest? = request(.newMessage, account: account)
        XCTAssertNil(take(&slot, locked: true, offset: QuickActionPolicy.requestLifetime + 1))
        XCTAssertNil(slot)
    }

    func testSignedOutDropsTheRequest() {
        var slot: QuickActionRequest? = request(.newMessage, account: account)
        XCTAssertNil(take(&slot, signedIn: false))
        XCTAssertNil(slot)
    }

    func testRequestOfAnotherAccountIsDropped() {
        var slot: QuickActionRequest? = request(.newMessage, account: other)
        XCTAssertNil(take(&slot))
        XCTAssertNil(slot)
    }

    func testColdLaunchRequestWithoutAccountIsShownOnceSignedIn() {
        var slot: QuickActionRequest? = request(.shareLocation, account: nil)
        XCTAssertEqual(take(&slot), .locationPicker)
        XCTAssertNil(slot)
    }

    func testFutureRequestIsDropped() {
        var slot: QuickActionRequest? = request(.newMessage, account: account)
        XCTAssertNil(take(&slot, offset: -5))
        XCTAssertNil(slot)
    }

    func testEmptySlotAnswersNil() {
        var slot: QuickActionRequest?
        XCTAssertNil(take(&slot))
    }
}
