import UIKit

/// Two cover layers over the key window, both independent of the secure canvas so they still work if UIKit changes
/// its private internals:
///  - a blur while the app is about to leave the foreground (the App Switcher snapshot is taken right after);
///  - an opaque cover with a short notice while the screen is being recorded or mirrored and a protected screen is up.
@MainActor
enum PrivacyShield {

    private static var started = false
    private static weak var blurView: UIView?
    private static weak var captureCover: UIView?

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

    static func refreshCaptureCover() {
        guard let window = keyWindow() else { return }
        let want = shouldCoverCapture(isCaptured: window.screen.isCaptured, lockHeld: ScreenshotLockService.isLocked)
        if want, captureCover == nil {
            let cover = UIView(frame: window.bounds)
            cover.accessibilityIdentifier = ScreenshotLockService.shieldIdentifier
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.backgroundColor = .black
            let label = UILabel()
            label.text = String(localized: "privacy.capture_cover", defaultValue: "Registrazione schermo attiva: contenuto nascosto", comment: "Full-screen notice shown instead of a protected screen while the screen is being recorded or mirrored.")
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .headline)
            label.translatesAutoresizingMaskIntoConstraints = false
            cover.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 32),
                label.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -32)
            ])
            window.addSubview(cover)
            captureCover = cover
            RTLog.info("privacy", "capcover shown=1")
        } else if !want, let cover = captureCover {
            cover.removeFromSuperview()
            captureCover = nil
        }
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
