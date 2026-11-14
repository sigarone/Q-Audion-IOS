import XCTest
@testable import QAudionApp

/// The secure container: the topmost view's layer lives inside the secure text field's canvas while the lock is held
/// (so captures come out black), the view tree is untouched, and the lock is released with the last owner.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-ci.yml`.
@MainActor
final class ScreenshotLockServiceTests: XCTestCase {

    private func makeWindow() -> (UIWindow, UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (window, controller)
    }

    override func tearDown() {
        ScreenshotLockService.unlock(owner: "a")
        ScreenshotLockService.unlock(owner: "b")
        ScreenshotLockService.unlock()
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

    func test_captureCoverOnlyWhileCapturedAndLocked() {
        XCTAssertTrue(PrivacyShield.shouldCoverCapture(isCaptured: true, lockHeld: true))
        XCTAssertFalse(PrivacyShield.shouldCoverCapture(isCaptured: true, lockHeld: false))
        XCTAssertFalse(PrivacyShield.shouldCoverCapture(isCaptured: false, lockHeld: true))
    }

    func test_snapshotBlurWhenLockHeldOrSettingOn() {
        XCTAssertTrue(PrivacyShield.shouldBlurSnapshot(lockHeld: true, protectionSetting: false))
        XCTAssertTrue(PrivacyShield.shouldBlurSnapshot(lockHeld: false, protectionSetting: true))
        XCTAssertFalse(PrivacyShield.shouldBlurSnapshot(lockHeld: false, protectionSetting: false))
    }
}
