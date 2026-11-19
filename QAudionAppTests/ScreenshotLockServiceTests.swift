import XCTest
@testable import QAudionApp

/// The secure container: the topmost view's layer lives inside the secure text field's canvas while the lock is held
/// (so captures come out black), the view tree is untouched, and the lock is released with the last owner. While this
/// device shares its own screen only the screens that hold a secret stay hosted, with a notice and without a cover that
/// takes touches, and everything is back when the share is over or another display shows the screen.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-ci.yml`.
@MainActor
final class ScreenshotLockServiceTests: XCTestCase {

    /// The owner keys of the screens of the app that take the lock.
    private static let screenOwners = [
        ScreenshotLockService.recoveryOwner, ScreenshotLockService.deviceLinkOwner,
        ScreenshotLockService.pairingOwner, ScreenshotLockService.chatDetailOwner,
        ScreenshotLockService.groupChatOwner, ScreenshotLockService.chatListOwner, "call", "call_video", "call_group"]

    private func makeWindow() -> (UIWindow, UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (window, controller)
    }

    private static let noShieldViews = PrivacyShield.Protection(cover: false, canvas: false, notice: false,
                                                                 coverTakesTouches: true)

    private static let ownShareNothing = PrivacyShield.Protection(cover: false, canvas: false, notice: false,
                                                                  coverTakesTouches: false)

    private func shieldViews(_ window: UIWindow) -> [UIView] {
        window.subviews.filter { $0.accessibilityIdentifier == ScreenshotLockService.shieldIdentifier }
    }

    override func tearDown() {
        PrivacyShield.apply(Self.noShieldViews, in: nil)
        ScreenshotLockService.unlock(owner: "a")
        ScreenshotLockService.unlock(owner: "b")
        for owner in Self.screenOwners { ScreenshotLockService.unlock(owner: owner) }
        ScreenshotLockService.unlock()
        PrivacyShield.endOwnShare()
        PrivacyShield.capturedOverride = nil
        PrivacyShield.refreshShareEnding(isCaptured: false)
        super.tearDown()
    }

    /// Layers directly under the window layer that are not secure fields.
    private func contentLayers(_ window: UIWindow) -> [CALayer] {
        (window.layer.sublayers ?? []).filter { !($0.delegate is UITextField) }
    }

    func test_lockHostsTheWindowContentInTheSecureCanvas_andUnlockRestoresIt() {
        let (window, _) = makeWindow()
        let layers = contentLayers(window)
        XCTAssertFalse(layers.isEmpty)

        ScreenshotLockService.lock(in: window)

        XCTAssertTrue(ScreenshotLockService.isLocked)
        XCTAssertTrue(ScreenshotLockService.isHostedInSecureCanvas, "the private canvas of the secure field was not found")
        XCTAssertTrue(contentLayers(window).isEmpty, "a window layer is outside the secure canvas")
        for layer in layers {
            let canvasOwner = layer.superlayer?.delegate as? UIView
            XCTAssertNotNil(canvasOwner)
            if let canvasOwner {
                XCTAssertTrue(String(describing: type(of: canvasOwner)).contains("CanvasView"))
            }
        }

        ScreenshotLockService.unlock()

        XCTAssertFalse(ScreenshotLockService.isLocked)
        for layer in layers {
            XCTAssertTrue(layer.superlayer === window.layer)
        }
    }

    func test_touchesStillReachTheHostedContent() {
        let (window, controller) = makeWindow()
        ScreenshotLockService.lock(in: window)
        let hit = window.hitTest(CGPoint(x: 160, y: 320), with: nil)
        XCTAssertNotNil(hit)
        XCTAssertFalse(hit is UITextField)
        XCTAssertTrue(hit === controller.view || hit?.isDescendant(of: controller.view) == true)
        ScreenshotLockService.unlock()
    }

    func test_aPresentedSheetIsHostedWithoutWaitingForTheTimer() {
        let (window, controller) = makeWindow()
        ScreenshotLockService.lock(in: window)
        controller.present(UIViewController(), animated: false)
        // No revalidate() here: the sublayer observer must have hosted the new container already.
        XCTAssertTrue(ScreenshotLockService.isLocked)
        XCTAssertTrue(contentLayers(window).isEmpty, "a window layer is outside the secure canvas")
        ScreenshotLockService.unlock()
    }

    func test_lockIsHeldUntilTheLastOwnerReleases() {
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        ScreenshotLockService.lock(owner: "b", in: window)
        ScreenshotLockService.unlock(owner: "a")
        XCTAssertTrue(ScreenshotLockService.isLocked)
        ScreenshotLockService.unlock(owner: "b")
        XCTAssertFalse(ScreenshotLockService.isLocked)
    }

    func test_protectionDecisionTable() {
        for isCaptured in [false, true] {
            for lockHeld in [false, true] {
                for secretHeld in [false, true] where !secretHeld || lockHeld {
                    for canvasHosted in [false, true] {
                        // No own share, or another display shows the screen as well: the cover needs a capture and a
                        // held lock, the canvas needs a held lock, there is no notice.
                        for (ownShareActive, externalDisplay) in [(false, false), (false, true), (true, true)] {
                            XCTAssertEqual(
                                PrivacyShield.protection(isCaptured: isCaptured, lockHeld: lockHeld, secretHeld: secretHeld,
                                                         ownShareActive: ownShareActive, externalDisplay: externalDisplay,
                                                         canvasHosted: canvasHosted),
                                PrivacyShield.Protection(cover: isCaptured && lockHeld, canvas: lockHeld, notice: false,
                                                         coverTakesTouches: !ownShareActive))
                        }
                        // The own share alone, whatever the capture flag says: only a screen that holds a secret is
                        // protected, with the canvas and the notice and no cover, also where the canvas could not
                        // host the content. Nothing takes a touch.
                        XCTAssertEqual(
                            PrivacyShield.protection(isCaptured: isCaptured, lockHeld: lockHeld, secretHeld: secretHeld,
                                                     ownShareActive: true, externalDisplay: false, canvasHosted: canvasHosted),
                            PrivacyShield.Protection(cover: false, canvas: secretHeld,
                                                     notice: secretHeld && canvasHosted, coverTakesTouches: false))
                    }
                }
            }
        }
    }

    func test_secretOwners() {
        // Each owner with its decision: the screens that show secret material or the content of other people stay
        // protected while this device shares its screen; the call screens, which show the person's own data, are
        // shared.
        for owner in [ScreenshotLockService.recoveryOwner, ScreenshotLockService.deviceLinkOwner,
                      ScreenshotLockService.pairingOwner, ScreenshotLockService.chatDetailOwner,
                      ScreenshotLockService.groupChatOwner, ScreenshotLockService.chatListOwner] {
            XCTAssertTrue(ScreenshotLockService.secretOwners.contains(owner), owner)
        }
        XCTAssertEqual(ScreenshotLockService.secretOwners.count, 6)
        for owner in ["call", "call_video", "call_group", "a", "legacy"] {
            XCTAssertFalse(ScreenshotLockService.secretOwners.contains(owner), owner)
        }
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        XCTAssertFalse(ScreenshotLockService.isSecretHeld)
        ScreenshotLockService.lock(owner: ScreenshotLockService.pairingOwner, in: window)
        XCTAssertTrue(ScreenshotLockService.isSecretHeld)
        ScreenshotLockService.unlock(owner: ScreenshotLockService.pairingOwner)
        XCTAssertFalse(ScreenshotLockService.isSecretHeld)
    }

    func test_ownShareIsOffAtLaunch() {
        XCTAssertFalse(PrivacyShield.ownShareActive)
    }

    func test_ownShareUnhostsTheContentAndKeepsTheOwner() {
        let (window, _) = makeWindow()
        let layers = contentLayers(window)
        ScreenshotLockService.lock(owner: "a", in: window)
        XCTAssertTrue(ScreenshotLockService.isHostedInSecureCanvas)

        PrivacyShield.setOwnShareActive(true)

        XCTAssertTrue(PrivacyShield.ownShareActive)
        XCTAssertFalse(ScreenshotLockService.isLocked)
        XCTAssertFalse(ScreenshotLockService.isHostedInSecureCanvas)
        XCTAssertTrue(ScreenshotLockService.isHeld, "the owner stays registered")
        XCTAssertEqual(contentLayers(window).count, layers.count)
        for layer in layers {
            XCTAssertTrue(layer.superlayer === window.layer, "the window content is back in the window")
        }
        XCTAssertFalse((window.layer.sublayers ?? []).contains(where: { $0.delegate is UITextField }), "a secure field is left in the window")
    }

    func test_nothingIsHostedWhileTheOwnShareRuns_andEverythingIsWhenItEnds() {
        let (window, controller) = makeWindow()
        PrivacyShield.setOwnShareActive(true)

        ScreenshotLockService.lock(owner: "a", in: window)
        controller.present(UIViewController(), animated: false)
        ScreenshotLockService.revalidate()

        XCTAssertFalse(ScreenshotLockService.isLocked)
        XCTAssertFalse(contentLayers(window).isEmpty, "the content stays visible to the share")

        PrivacyShield.setOwnShareActive(false)

        XCTAssertTrue(ScreenshotLockService.isLocked)
        XCTAssertTrue(ScreenshotLockService.isHostedInSecureCanvas)
        XCTAssertTrue(contentLayers(window).isEmpty, "a window layer is outside the secure canvas")
    }

    /// The share is stopped from the call screen or from the system.
    func test_stop_putsTheCanvasBackForTheScreenThatHoldsTheLock() {
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        PrivacyShield.setOwnShareActive(true)

        PrivacyShield.setOwnShareActive(false)

        XCTAssertFalse(PrivacyShield.ownShareActive)
        XCTAssertTrue(ScreenshotLockService.isLocked)
        XCTAssertTrue(contentLayers(window).isEmpty, "a window layer is outside the secure canvas")
    }

    /// The capture fails right after it started, while another screen takes the lock.
    func test_failure_putsTheCanvasBackForAScreenThatLockedDuringTheShare() {
        let (window, _) = makeWindow()
        PrivacyShield.setOwnShareActive(true)
        ScreenshotLockService.lock(owner: "b", in: window)

        PrivacyShield.setOwnShareActive(false)

        XCTAssertTrue(ScreenshotLockService.isLocked)
        XCTAssertTrue(contentLayers(window).isEmpty, "a window layer is outside the secure canvas")
    }

    /// The call ends: its screen releases its lock while the share ends; the other screen stays protected.
    func test_callEnd_hostsOnlyWhatStillHoldsTheLock() {
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        ScreenshotLockService.lock(owner: "b", in: window)
        PrivacyShield.setOwnShareActive(true)
        ScreenshotLockService.unlock(owner: "a")

        PrivacyShield.setOwnShareActive(false)

        XCTAssertTrue(ScreenshotLockService.isHeld)
        XCTAssertTrue(ScreenshotLockService.isLocked)
        ScreenshotLockService.unlock(owner: "b")
        XCTAssertFalse(ScreenshotLockService.isHeld)
        XCTAssertFalse(ScreenshotLockService.isLocked)
    }

    /// A screen of the person's own data (the call screens) takes the lock while the share runs: nothing is hosted and
    /// no cover goes up, so the controls stay reachable.
    func test_theCallScreensAreNeitherHostedNorCoveredWhileTheOwnShareRuns() {
        for owner in ["call", "call_video", "call_group", "a"] {
            let (window, _) = makeWindow()
            let layers = contentLayers(window)
            PrivacyShield.setOwnShareActive(true)
            ScreenshotLockService.lock(owner: owner, in: window)

            XCTAssertTrue(ScreenshotLockService.isHeld, owner)
            XCTAssertFalse(ScreenshotLockService.isLocked, owner)
            XCTAssertEqual(PrivacyShield.currentProtection(isCaptured: false), Self.ownShareNothing, owner)
            XCTAssertEqual(PrivacyShield.currentProtection(isCaptured: true), Self.ownShareNothing, owner)
            for layer in layers {
                XCTAssertTrue(layer.superlayer === window.layer, "the window content stays in the window: \(owner)")
            }

            // The share is over: the screen that still holds the lock is hosted again.
            PrivacyShield.setOwnShareActive(false)
            XCTAssertTrue(ScreenshotLockService.isHostedInSecureCanvas, owner)
            ScreenshotLockService.unlock(owner: owner)
            XCTAssertFalse(ScreenshotLockService.isLocked, owner)
        }
    }

    /// Whichever secret screen takes the lock while the share runs, the window layers are inside the canvas when the
    /// call returns, and the protection is the canvas and the notice, without a cover.
    func test_everySecretOwnerIsHostedWithoutACoverWhileTheOwnShareRuns() {
        for owner in ScreenshotLockService.secretOwners.sorted() {
            let (window, _) = makeWindow()
            let layers = contentLayers(window)
            PrivacyShield.setOwnShareActive(true)
            ScreenshotLockService.lock(owner: "a", in: window)
            XCTAssertFalse(ScreenshotLockService.isLocked, owner)

            ScreenshotLockService.lock(owner: owner, in: window)

            XCTAssertTrue(ScreenshotLockService.isSecretHeld, owner)
            XCTAssertTrue(ScreenshotLockService.isHostedInSecureCanvas, owner)
            XCTAssertTrue(contentLayers(window).isEmpty, "\(owner): a window layer is outside the secure canvas")
            for isCaptured in [false, true] {
                XCTAssertEqual(PrivacyShield.currentProtection(isCaptured: isCaptured),
                               PrivacyShield.Protection(cover: false, canvas: true, notice: true, coverTakesTouches: false), owner)
            }

            // The secret screen goes away: the screens left are shared.
            ScreenshotLockService.unlock(owner: owner)
            XCTAssertFalse(ScreenshotLockService.isLocked, owner)
            for layer in layers {
                XCTAssertTrue(layer.superlayer === window.layer, "the window content is back in the window: \(owner)")
            }
            PrivacyShield.setOwnShareActive(false)
            ScreenshotLockService.unlock(owner: "a")
        }
    }

    /// A secret screen that comes up during the share is hosted at once, and stays hosted when the share is over.
    func test_aSecretScreenThatComesUpDuringTheShareIsHostedAtOnce() {
        let (window, _) = makeWindow()
        PrivacyShield.setOwnShareActive(true)
        ScreenshotLockService.lock(owner: "a", in: window)
        ScreenshotLockService.lock(owner: ScreenshotLockService.pairingOwner, in: window)
        XCTAssertTrue(ScreenshotLockService.isHostedInSecureCanvas)
        XCTAssertTrue(contentLayers(window).isEmpty, "a window layer is outside the secure canvas")

        PrivacyShield.setOwnShareActive(false)
        XCTAssertTrue(ScreenshotLockService.isHostedInSecureCanvas)
        ScreenshotLockService.unlock(owner: ScreenshotLockService.pairingOwner)
        XCTAssertTrue(ScreenshotLockService.isHostedInSecureCanvas, "owner a still holds the lock")
    }

    /// No view of the shield takes a touch while the own share runs, and the cover of a canvas that could not host the
    /// content is gone: only the notice remains. A recording keeps its cover that takes touches.
    func test_noShieldViewTakesTouchesDuringTheOwnShare() {
        let (window, controller) = makeWindow()
        for canvasHosted in [true, false] {
            let wanted = PrivacyShield.protection(isCaptured: true, lockHeld: true, secretHeld: true, ownShareActive: true,
                                                  externalDisplay: false, canvasHosted: canvasHosted)
            PrivacyShield.apply(wanted, in: window)

            let views = shieldViews(window)
            XCTAssertEqual(views.count, canvasHosted ? 1 : 0, "canvasHosted \(canvasHosted): the notice, and no cover")
            for view in views { XCTAssertFalse(view.isUserInteractionEnabled) }
            let hit = window.hitTest(CGPoint(x: 160, y: 320), with: nil)
            XCTAssertTrue(hit === controller.view || hit?.isDescendant(of: controller.view) == true,
                          "a touch reaches the content under the shield views")
            PrivacyShield.apply(Self.noShieldViews, in: window)
            XCTAssertTrue(shieldViews(window).isEmpty)
        }

        let recording = PrivacyShield.protection(isCaptured: true, lockHeld: true, secretHeld: false, ownShareActive: false,
                                                 externalDisplay: false)
        PrivacyShield.apply(recording, in: window)
        XCTAssertEqual(shieldViews(window).count, 1)
        XCTAssertTrue(shieldViews(window).allSatisfy { $0.isUserInteractionEnabled })
    }

    /// The cover that was up for a recording is removed when the share starts; the notice is shown only when the canvas
    /// is hosting.
    func test_aCoverGoesAwayWhenTheShareStarts() {
        let (window, _) = makeWindow()
        PrivacyShield.apply(PrivacyShield.protection(isCaptured: true, lockHeld: true, secretHeld: true, ownShareActive: false,
                                                     externalDisplay: false), in: window)
        XCTAssertTrue(shieldViews(window).allSatisfy { $0.isUserInteractionEnabled })

        PrivacyShield.apply(PrivacyShield.protection(isCaptured: true, lockHeld: true, secretHeld: true, ownShareActive: true,
                                                     externalDisplay: false, canvasHosted: false), in: window)
        XCTAssertTrue(shieldViews(window).isEmpty)
    }

    /// While the share is starting, a captured screen that holds the lock gets no cover, and the share state that comes
    /// after it is the same.
    func test_noCoverWhileTheShareIsStarting() {
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        PrivacyShield.setShareStarting(true)
        XCTAssertEqual(PrivacyShield.currentProtection(isCaptured: true).cover, false)
        PrivacyShield.setOwnShareActive(true)
        XCTAssertFalse(PrivacyShield.shareStarting)
        XCTAssertEqual(PrivacyShield.currentProtection(isCaptured: true).cover, false)
        PrivacyShield.endOwnShare()
        XCTAssertFalse(PrivacyShield.ownShareSpan)
        XCTAssertTrue(PrivacyShield.currentProtection(isCaptured: true).cover)
    }

    /// After a stop the share stays an own capture while the screen is captured, and the state clears at the first
    /// refresh that sees the screen not captured; a foreign capture after that gets the cover again.
    func test_theEndingStateHoldsNoCoverUntilTheCaptureIsOver() {
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        PrivacyShield.capturedOverride = true
        PrivacyShield.markShareEnding(.stillCapturing)
        XCTAssertTrue(PrivacyShield.shareEnding)
        XCTAssertFalse(PrivacyShield.currentProtection(isCaptured: true).cover)
        PrivacyShield.refreshCaptureCover()
        XCTAssertTrue(PrivacyShield.shareEnding, "still captured: still the own capture")
        PrivacyShield.endingBoundPassed(generation: PrivacyShield.endingGeneration)
        XCTAssertTrue(PrivacyShield.shareEnding, "a capture that is still running has no bound")

        PrivacyShield.capturedOverride = false
        PrivacyShield.refreshCaptureCover()
        XCTAssertFalse(PrivacyShield.shareEnding)
        XCTAssertTrue(PrivacyShield.currentProtection(isCaptured: true).cover)
    }

    /// After a stop that answered "stopped" the ending state absorbs the lag of the screen state and clears at its
    /// bound, so a mirror that keeps the screen captured gets its cover; an older bound does not clear a newer state.
    func test_theEndingStateAfterAStopClearsAtItsBound() {
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        PrivacyShield.capturedOverride = true
        PrivacyShield.markShareEnding(.stopped)
        XCTAssertTrue(PrivacyShield.shareEnding)
        XCTAssertFalse(PrivacyShield.currentProtection(isCaptured: true).cover)
        let first = PrivacyShield.endingGeneration
        PrivacyShield.markShareEnding(.stopped)

        PrivacyShield.endingBoundPassed(generation: first)
        XCTAssertTrue(PrivacyShield.shareEnding, "the bound of an older state is ignored")
        PrivacyShield.endingBoundPassed(generation: PrivacyShield.endingGeneration)
        XCTAssertFalse(PrivacyShield.shareEnding)
        XCTAssertTrue(PrivacyShield.currentProtection(isCaptured: true).cover)
    }

    /// A foreign capture with the lock held and no share keeps its cover.
    func test_aForeignCaptureStillGetsTheCover() {
        let wanted = PrivacyShield.protection(isCaptured: true, lockHeld: true, secretHeld: false, ownShareActive: false,
                                              externalDisplay: false)
        XCTAssertTrue(wanted.cover)
    }

    /// Removing the cover removes every cover view, also one that the shield no longer remembers.
    func test_removingTheCoverRemovesEveryCoverView() {
        let (window, _) = makeWindow()
        let recording = PrivacyShield.protection(isCaptured: true, lockHeld: true, secretHeld: false, ownShareActive: false,
                                                 externalDisplay: false)
        PrivacyShield.apply(recording, in: window)
        XCTAssertEqual(shieldViews(window).count, 1)
        let stray = UIView(frame: window.bounds)
        stray.tag = shieldViews(window)[0].tag
        stray.accessibilityIdentifier = ScreenshotLockService.shieldIdentifier
        window.addSubview(stray)

        PrivacyShield.apply(recording, in: window)
        XCTAssertEqual(shieldViews(window).count, 1, "a second cover is removed before the cover is placed")

        PrivacyShield.apply(Self.noShieldViews, in: window)
        XCTAssertTrue(shieldViews(window).isEmpty)
    }

    func test_aLockReleasedDuringTheOwnShareLeavesNothingToHost() {
        let (window, _) = makeWindow()
        let layers = contentLayers(window)
        ScreenshotLockService.lock(owner: "a", in: window)
        PrivacyShield.setOwnShareActive(true)
        ScreenshotLockService.unlock(owner: "a")

        PrivacyShield.setOwnShareActive(false)

        XCTAssertFalse(ScreenshotLockService.isHeld)
        XCTAssertFalse(ScreenshotLockService.isLocked)
        for layer in layers {
            XCTAssertTrue(layer.superlayer === window.layer)
        }
    }

    func test_ownShareCanStartAndEndRepeatedly() {
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        for _ in 0..<3 {
            PrivacyShield.setOwnShareActive(true)
            PrivacyShield.setOwnShareActive(true)
            XCTAssertFalse(ScreenshotLockService.isLocked)
            PrivacyShield.setOwnShareActive(false)
            PrivacyShield.setOwnShareActive(false)
            XCTAssertTrue(ScreenshotLockService.isLocked)
            XCTAssertTrue(contentLayers(window).isEmpty, "a window layer is outside the secure canvas")
        }
    }

    func test_snapshotBlurWhenLockHeldOrSettingOn() {
        XCTAssertTrue(PrivacyShield.shouldBlurSnapshot(lockHeld: true, protectionSetting: false))
        XCTAssertTrue(PrivacyShield.shouldBlurSnapshot(lockHeld: false, protectionSetting: true))
        XCTAssertFalse(PrivacyShield.shouldBlurSnapshot(lockHeld: false, protectionSetting: false))
    }

    func test_snapshotBlurStillFollowsTheHeldLockWhileTheOwnShareRuns() {
        let (window, _) = makeWindow()
        ScreenshotLockService.lock(owner: "a", in: window)
        PrivacyShield.setOwnShareActive(true)
        XCTAssertTrue(PrivacyShield.shouldBlurSnapshot(lockHeld: ScreenshotLockService.isHeld, protectionSetting: false))
    }
}
