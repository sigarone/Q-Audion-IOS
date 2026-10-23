import XCTest
@testable import QAudionApp

/// `CarPlayBridge`, the seam between the CarPlay scene and the live app: the way a launch with only the car reaches the
/// app (nothing has run `AppState.initialize()` yet, so `placeCall` is not wired), the session that is not known yet at
/// that point and the hook that redraws the car screen when it is, the app lock, the Siri call request that arrives
/// through the car, and the notices for the car screen. The bridge is a process-wide singleton, so every test puts it
/// back the way it found it.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class CarPlayBridgeTests: XCTestCase {

    private var bridge: CarPlayBridge { CarPlayBridge.shared }

    private var saved: (
        boot: (@MainActor () -> Void)?, siri: (@MainActor (NSUserActivity) -> Void)?,
        place: ((String, String) -> Void)?, session: (@MainActor () -> CarPlaySession)?,
        locked: (@MainActor () -> Bool)?, connected: (@MainActor () -> Void)?
    )!
    private var savedRefresh: (@MainActor () -> Void)?

    override func setUp() {
        super.setUp()
        saved = (bridge.bootApp, bridge.continueStartCall, bridge.placeCall, bridge.sessionState,
                 bridge.isAppLocked, bridge.onCarPlayConnected)
        savedRefresh = bridge.refreshAppLock
        bridge.refreshAppLock = nil
        bridge.bootApp = nil
        bridge.continueStartCall = nil
        bridge.placeCall = nil
        bridge.sessionState = nil
        bridge.isAppLocked = { false }
        bridge.noticeSink = nil
        bridge.onCarPlayConnected = nil
        bridge.onCarPlayDisconnected = nil
        bridge.carPlayDisconnected()
    }

    override func tearDown() {
        bridge.carPlayDisconnected()
        bridge.bootApp = saved.boot
        bridge.continueStartCall = saved.siri
        bridge.placeCall = saved.place
        bridge.sessionState = saved.session
        bridge.isAppLocked = saved.locked
        bridge.onCarPlayConnected = saved.connected
        bridge.refreshAppLock = savedRefresh
        bridge.onCarPlayDisconnected = nil
        super.tearDown()
    }

    private func startCallActivity() -> NSUserActivity {
        NSUserActivity(activityType: CarPlayBridge.startCallActivityType)
    }

    // MARK: - placing a call

    func test_aCallRequestReachesThePlaceCallClosure() {
        var placed: [(String, String)] = []
        bridge.placeCall = { placed.append(($0, $1)) }
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-1", displayName: "Anna"), .handedOver)
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed.first?.0, "peer-1")
        XCTAssertEqual(placed.first?.1, "Anna")
    }

    func test_onALaunchWithOnlyTheCarTheAppIsStartedBeforeTheCallIsPlaced() {
        var placed: [String] = []
        var boots = 0
        // The start-up wires placeCall, the way AppState.initialize() does.
        bridge.bootApp = { [unowned self] in
            boots += 1
            self.bridge.placeCall = { peer, _ in placed.append(peer) }
        }
        XCTAssertNil(bridge.placeCall)
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-2", displayName: "Luca"), .handedOver)
        XCTAssertEqual(boots, 1)
        XCTAssertEqual(placed, ["peer-2"])
    }

    func test_whenTheAppCannotBeStartedTheRequestIsReportedNotDropped() {
        var boots = 0
        bridge.bootApp = { boots += 1 }
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-3", displayName: "Eva"), .appNotReady)
        XCTAssertEqual(boots, 1)
    }

    func test_withNothingWiredAtAllTheRequestIsReportedToo() {
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-4", displayName: "Gio"), .appNotReady)
    }

    func test_theAppIsNotStartedAgainOncePlaceCallIsWired() {
        var boots = 0
        bridge.bootApp = { boots += 1 }
        bridge.placeCall = { _, _ in }
        _ = bridge.requestCall(peerUserId: "peer-5", displayName: "")
        _ = bridge.requestCall(peerUserId: "peer-5", displayName: "")
        XCTAssertEqual(boots, 0)
    }

    // MARK: - the app lock

    func test_aCallRequestIsNotPlacedWhileTheAppLockIsUp() {
        var placed = 0
        bridge.placeCall = { _, _ in placed += 1 }
        bridge.isAppLocked = { true }
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-6", displayName: "Ida"), .locked)
        XCTAssertEqual(placed, 0)
        bridge.isAppLocked = { false }
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-6", displayName: "Ida"), .handedOver)
        XCTAssertEqual(placed, 1)
    }

    func test_anAppThatNeverSaidWhetherItIsLockedCountsAsLocked() {
        bridge.isAppLocked = nil
        XCTAssertTrue(bridge.appIsLocked())
        var placed = 0
        bridge.placeCall = { _, _ in placed += 1 }
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-7", displayName: "Leo"), .locked)
        XCTAssertEqual(placed, 0)
    }

    func test_aLockedAppIsReportedAsNotReadyOnlyWhenItCannotBeStartedAtAll() {
        bridge.isAppLocked = { true }
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-8", displayName: "Zoe"), .appNotReady)
    }

    func test_aSiriCallRequestIsNotContinuedWhileTheAppLockIsUpAndTheCarSaysSo() {
        var continued = 0
        var told: [CarPlayNotice] = []
        bridge.continueStartCall = { _ in continued += 1 }
        bridge.noticeSink = { told.append($0) }
        bridge.isAppLocked = { true }
        XCTAssertFalse(bridge.deliverSiriActivity(startCallActivity()))
        XCTAssertEqual(continued, 0)
        XCTAssertEqual(told, [.appLocked])
    }

    func test_everyReadOfTheLockBringsItUpToDateFirst() {
        var locked = false
        bridge.refreshAppLock = { locked = true }
        bridge.isAppLocked = { locked }
        XCTAssertTrue(bridge.appIsLocked())
    }

    func test_aCallRequestSeesALockThatCameUpWhileThePhoneWasInTheBackground() {
        var locked = false
        var placed = 0
        bridge.placeCall = { _, _ in placed += 1 }
        bridge.refreshAppLock = { locked = true }
        bridge.isAppLocked = { locked }
        XCTAssertEqual(bridge.requestCall(peerUserId: "peer-9", displayName: "Noa"), .locked)
        XCTAssertEqual(placed, 0)
    }

    func test_aSiriRequestSeesALockThatCameUpWhileThePhoneWasInTheBackground() {
        var locked = false
        var continued = 0
        var told: [CarPlayNotice] = []
        bridge.continueStartCall = { _ in continued += 1 }
        bridge.noticeSink = { told.append($0) }
        bridge.refreshAppLock = { locked = true }
        bridge.isAppLocked = { locked }
        XCTAssertFalse(bridge.deliverSiriActivity(startCallActivity()))
        XCTAssertEqual(continued, 0)
        XCTAssertEqual(told, [.appLocked])
    }

    func test_theCarScreenIsToldWhenTheLockChangesAndNotAfterItDisconnects() {
        var redraws = 0
        bridge.onLockChanged = { redraws += 1 }
        bridge.lockDidChange()
        XCTAssertEqual(redraws, 1)
        bridge.carPlayDisconnected()
        bridge.lockDidChange()
        XCTAssertEqual(redraws, 1)
    }

    // MARK: - the session after a cold launch

    func test_theSessionIsNotKnownUntilTheAppSaysSo() {
        XCTAssertEqual(bridge.currentSession(), .unknown)
        bridge.sessionState = { .signedOut }
        XCTAssertEqual(bridge.currentSession(), .signedOut)
    }

    func test_theCarScreenRedrawsWhenTheRestoredSessionBecomesSignedIn() {
        // The car connects before the session is restored: nothing is listed. When the restore finishes the app says
        // so through the hook, and the scene reads the session again.
        var session: CarPlaySession = .unknown
        bridge.sessionState = { session }
        var seen: [CarPlaySession] = []
        bridge.onSignInChanged = { [unowned self] in seen.append(self.bridge.currentSession()) }
        bridge.carPlayConnected()
        XCTAssertEqual(CarPlayListBuilder.access(session: bridge.currentSession(), isLocked: false), .starting)
        session = .signedIn
        bridge.signInDidChange()
        XCTAssertEqual(seen, [.signedIn])
        XCTAssertEqual(CarPlayListBuilder.access(session: bridge.currentSession(), isLocked: false), .open)
    }

    func test_theSignInHookIsGoneOnceTheCarDisconnects() {
        var redraws = 0
        bridge.onSignInChanged = { redraws += 1 }
        bridge.carPlayDisconnected()
        bridge.signInDidChange()
        XCTAssertEqual(redraws, 0)
    }

    // MARK: - connecting

    func test_connectingStartsTheAppFirstAndThenTellsTheListener() {
        var order: [String] = []
        bridge.bootApp = { order.append("boot") }
        bridge.onCarPlayConnected = { order.append("connected") }
        bridge.carPlayConnected()
        XCTAssertEqual(order, ["boot", "connected"])
        XCTAssertTrue(bridge.isConnected)
    }

    func test_connectingBringsTheLockUpToDateBeforeTellingTheListener() {
        var order: [String] = []
        bridge.bootApp = { order.append("boot") }
        bridge.refreshAppLock = { order.append("refresh") }
        bridge.onCarPlayConnected = { order.append("connected") }
        bridge.carPlayConnected()
        XCTAssertEqual(order, ["boot", "refresh", "connected"])
    }

    func test_disconnectingForgetsTheSessionAndItsNoticeSink() {
        var told: [CarPlayNotice] = []
        bridge.noticeSink = { told.append($0) }
        bridge.carPlayConnected()
        var disconnected = 0
        bridge.onCarPlayDisconnected = { disconnected += 1 }
        bridge.carPlayDisconnected()
        XCTAssertFalse(bridge.isConnected)
        XCTAssertEqual(disconnected, 1)
        bridge.report(.callNotStarted)
        XCTAssertTrue(told.isEmpty, "nobody is listening once the car is gone")
    }

    // MARK: - notices

    func test_aNoticeReachesTheCarScreenWhileASessionListens() {
        var told: [CarPlayNotice] = []
        bridge.noticeSink = { told.append($0) }
        bridge.report(.contactNotFound)
        bridge.report(.notReady)
        XCTAssertEqual(told, [.contactNotFound, .notReady])
    }

    func test_aNoticeWithoutASessionIsDroppedQuietly() {
        bridge.report(.contactNotFound)
    }

    // MARK: - Siri

    func test_aSiriCallRequestInTheCarStartsTheAppAndIsContinued() {
        var order: [String] = []
        bridge.bootApp = { order.append("boot") }
        bridge.continueStartCall = { _ in order.append("continued") }
        XCTAssertTrue(bridge.deliverSiriActivity(startCallActivity()))
        XCTAssertEqual(order, ["boot", "continued"])
    }

    func test_anotherKindOfActivityIsNotTakenAndStartsNothing() {
        var order: [String] = []
        bridge.bootApp = { order.append("boot") }
        bridge.continueStartCall = { _ in order.append("continued") }
        XCTAssertFalse(bridge.deliverSiriActivity(NSUserActivity(activityType: "com.example.other")))
        XCTAssertTrue(order.isEmpty)
    }

    func test_aSiriRequestIsNotLostSilentlyWhenNoOneCanContinueIt() {
        XCTAssertFalse(bridge.deliverSiriActivity(startCallActivity()))
    }

    func test_theSiriActivityTypeIsTheOneTheInfoPlistDeclares() {
        XCTAssertEqual(CarPlayBridge.startCallActivityType, "INStartCallIntent")
    }
}
