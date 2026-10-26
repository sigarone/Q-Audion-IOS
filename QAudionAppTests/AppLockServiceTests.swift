import XCTest
@testable import QAudionApp

/// The app lock as a reader with no window to prompt on sees it: the car screen of a process that is already running
/// asks `lockIfGraceExpiredWithoutPrompt` whether the grace period has run out while the phone window sat in the
/// background. The settings come in through the `policy` closure, so nothing here touches the Keychain; the background
/// time is the one `handleBackground()` persists, and every test removes it again.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class AppLockServiceTests: XCTestCase {

    private var key: String { AppLockService.backgroundedAtKey }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let graceMs = 60_000

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    private func persistBackgroundTime(secondsAgo: TimeInterval) {
        UserDefaults.standard.set(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970, forKey: key)
    }

    private func refresh(_ service: AppLockService, enabled: Bool = true) {
        let grace = graceMs
        service.lockIfGraceExpiredWithoutPrompt(now: now, policy: { (enabled: enabled, graceMs: grace) })
    }

    func test_anAppInTheForegroundHasNoBackgroundTimeAndStaysUnlocked() {
        let service = AppLockService()
        refresh(service)
        XCTAssertFalse(service.isLocked)
    }

    func test_withinTheGracePeriodItStaysUnlocked() {
        let service = AppLockService()
        persistBackgroundTime(secondsAgo: 30)
        refresh(service)
        XCTAssertFalse(service.isLocked)
    }

    func test_afterTheGracePeriodItLocksAndKeepsTheBackgroundTimeForTheWindow() {
        let service = AppLockService()
        persistBackgroundTime(secondsAgo: 61)
        refresh(service)
        XCTAssertTrue(service.isLocked)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key),
                        "the window reads the background time when it comes to the foreground and asks then")
    }

    func test_whenTheGracePeriodHasJustRunOutItLocks() {
        let service = AppLockService()
        persistBackgroundTime(secondsAgo: 60)
        refresh(service)
        XCTAssertTrue(service.isLocked)
    }

    func test_withTheLockSwitchedOffNothingIsLocked() {
        let service = AppLockService()
        persistBackgroundTime(secondsAgo: 600)
        refresh(service, enabled: false)
        XCTAssertFalse(service.isLocked)
    }

    func test_aLockThatIsAlreadyUpStaysUp() {
        let service = AppLockService()
        persistBackgroundTime(secondsAgo: 61)
        refresh(service)
        refresh(service)
        XCTAssertTrue(service.isLocked)
    }

    func test_theSettingsAreNotReadWhileThereIsNothingToDecide() {
        let service = AppLockService()
        var reads = 0
        service.lockIfGraceExpiredWithoutPrompt(now: now, policy: {
            reads += 1
            return (enabled: true, graceMs: 60_000)
        })
        XCTAssertEqual(reads, 0)
        persistBackgroundTime(secondsAgo: 61)
        refresh(service)
        var readsWhileLocked = 0
        service.lockIfGraceExpiredWithoutPrompt(now: now, policy: {
            readsWhileLocked += 1
            return (enabled: true, graceMs: 60_000)
        })
        XCTAssertEqual(readsWhileLocked, 0)
    }

    func test_theGraceBoundaryIsInclusive() {
        let backgroundedAt = now
        XCTAssertFalse(AppLockService.graceExpired(
            backgroundedAt: backgroundedAt, graceMs: 60_000, now: now.addingTimeInterval(59.9)))
        XCTAssertTrue(AppLockService.graceExpired(
            backgroundedAt: backgroundedAt, graceMs: 60_000, now: now.addingTimeInterval(60)))
        XCTAssertTrue(AppLockService.graceExpired(
            backgroundedAt: backgroundedAt, graceMs: 60_000, now: now.addingTimeInterval(61)))
    }

    func test_aBypassForAnAnsweredCallConsumesTheBackgroundTime() {
        let service = AppLockService()
        persistBackgroundTime(secondsAgo: 600)
        service.bypassForCall(answered: true)
        XCTAssertFalse(service.isLocked)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        refresh(service)
        XCTAssertFalse(service.isLocked, "the car screen must not lock a window that the bypass brought to the foreground")
    }

    func test_thePhoneWindowGoingToTheBackgroundLocksAfterTheGraceWhileTheCarIsConnected() {
        let bridge = CarPlayBridge.shared
        bridge.carPlayConnected()
        defer { bridge.carPlayDisconnected() }
        let service = AppLockService()
        service.handleBackground()
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key), "the phone window's background time is stored")
        service.lockIfGraceExpiredWithoutPrompt(
            now: Date().addingTimeInterval(61), policy: { (enabled: true, graceMs: 60_000) })
        XCTAssertTrue(service.isLocked)
    }

    func test_aBypassThatDoesNotApplyKeepsTheBackgroundTime() {
        let service = AppLockService()
        persistBackgroundTime(secondsAgo: 600)
        service.bypassForCall(callState: .ringing, answered: false)
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key))
    }
}
