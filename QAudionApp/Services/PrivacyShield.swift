import UIKit

/// Two cover layers over the key window, both independent of the secure canvas so they still work if UIKit changes
/// its private internals:
///  - a blur while the app is about to leave the foreground (the App Switcher snapshot is taken right after);
///  - an opaque cover with a short notice while the screen is being recorded or mirrored and a protected screen is up.
///    While this device's own screen share is what is being captured, the cover also carries a control that stops it.
@MainActor
enum PrivacyShield {

    /// What the capture cover shows.
    enum CaptureCoverMode: Equatable {
        /// No cover.
        case absent
        /// A notice only: the capture is somebody else's (a recording, a mirror).
        case notice
        /// A notice and a control that stops this device's own screen share.
        case noticeWithStop
    }

    /// Set by the app: whether this device's own screen share is running, and the action that stops it.
    struct OwnShareHook {
        let isActive: @MainActor () -> Bool
        let stop: @MainActor () -> Void
    }

    static var ownShare: OwnShareHook?

    private static var started = false
    private static weak var blurView: UIView?
    private static weak var captureCover: UIView?
    private static var shownCoverMode: CaptureCoverMode = .absent

    /// Registers the observers once per process.
    static func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { showBlurIfNeeded() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideBlur(); ScreenshotLockService.revalidate(); refreshCaptureCover() }
        }
        center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refreshCaptureCover() }
        }
    }

    /// Whether the app switcher snapshot must be blurred: a protected screen is up or the protection setting is on.
    static func shouldBlurSnapshot(lockHeld: Bool, protectionSetting: Bool) -> Bool {
        lockHeld || protectionSetting
    }

    /// Whether the capture cover must be up.
    static func shouldCoverCapture(isCaptured: Bool, lockHeld: Bool) -> Bool {
        isCaptured && lockHeld
    }

    /// Which cover is wanted: none, the notice, or the notice with the control that stops this device's own share.
    static func captureCoverMode(isCaptured: Bool, lockHeld: Bool, ownShareActive: Bool) -> CaptureCoverMode {
        guard shouldCoverCapture(isCaptured: isCaptured, lockHeld: lockHeld) else { return .absent }
        return ownShareActive ? .noticeWithStop : .notice
    }

    /// Brings the cover in line with the capture state, the lock and the own-share state. A cover that is no longer
    /// wanted is removed whatever the key window is; a cover that sits in another window than the key window is moved.
    static func refreshCaptureCover() {
        let window = keyWindow()
        let mode = captureCoverMode(
            isCaptured: (window ?? captureCover?.window)?.screen.isCaptured ?? false,
            lockHeld: ScreenshotLockService.isLocked,
            ownShareActive: ownShare?.isActive() ?? false)
        guard mode != .absent else {
            removeCaptureCover()
            return
        }
        // Wanted, but there is no window to put it in: the one that is up stays.
        guard let window else { return }
        if let cover = captureCover, cover.superview === window, shownCoverMode == mode {
            // A presented screen is added above the cover: keep the stop control reachable.
            if window.subviews.last !== cover { window.bringSubviewToFront(cover) }
            return
        }
        removeCaptureCover()
        let cover = makeCaptureCover(mode: mode, frame: window.bounds)
        window.addSubview(cover)
        captureCover = cover
        shownCoverMode = mode
        RTLog.info("privacy", "capcover shown=1 own=\(mode == .noticeWithStop ? 1 : 0)")
    }

    private static func removeCaptureCover() {
        shownCoverMode = .absent
        guard let cover = captureCover else { return }
        cover.removeFromSuperview()
        captureCover = nil
        RTLog.info("privacy", "capcover shown=0")
    }

    private static func makeCaptureCover(mode: CaptureCoverMode, frame: CGRect) -> UIView {
        let cover = UIView(frame: frame)
        cover.accessibilityIdentifier = ScreenshotLockService.shieldIdentifier
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .black
        let label = UILabel()
        if mode == .noticeWithStop {
            label.text = String(localized: "privacy.share_cover", defaultValue: "Condivisione schermo attiva: contenuto protetto nascosto", comment: "Full-screen notice shown instead of a protected screen while this device is sharing its screen in a call.")
        } else {
            label.text = String(localized: "privacy.capture_cover", defaultValue: "Registrazione schermo attiva: contenuto nascosto", comment: "Full-screen notice shown instead of a protected screen while the screen is being recorded or mirrored.")
        }
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(label)
        var constraints = [
            label.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -32)
        ]
        if mode == .noticeWithStop {
            var configuration = UIButton.Configuration.borderedProminent()
            configuration.title = String(localized: "privacy.share_cover.stop", defaultValue: "Interrompi condivisione", comment: "Button on the full-screen notice shown while this device is sharing its screen in a call: stops the screen share.")
            let button = UIButton(configuration: configuration, primaryAction: UIAction { action in
                MainActor.assumeIsolated {
                    (action.sender as? UIControl)?.isEnabled = false
                    PrivacyShield.ownShare?.stop()
                }
            })
            button.translatesAutoresizingMaskIntoConstraints = false
            cover.addSubview(button)
            constraints += [
                button.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
                button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return cover
    }

    private static func showBlurIfNeeded() {
        guard blurView == nil, let window = keyWindow() else { return }
        guard shouldBlurSnapshot(lockHeld: ScreenshotLockService.isLocked,
                                 protectionSetting: PrivacyGate.screenshotProtectionEnabled) else { return }
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.frame = window.bounds
        blur.accessibilityIdentifier = ScreenshotLockService.shieldIdentifier
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(blur)
        blurView = blur
    }

    private static func hideBlur() {
        blurView?.removeFromSuperview()
        blurView = nil
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
    }
}
