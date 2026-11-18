import UIKit

/// Two cover layers over the key window, both independent of the secure canvas so they still work if UIKit changes
/// its private internals:
///  - a blur while the app is about to leave the foreground (the App Switcher snapshot is taken right after);
///  - an opaque cover with a short notice while the screen is being recorded or mirrored and a protected screen is up.
///
/// While this device shares its own screen in a call, the cover and the secure canvas are not used for the screens the
/// person shares on purpose, so the shared image is the real screen. Screens that hold a secret or the content of other
/// people (see `ScreenshotLockService.secretOwners`) keep both and show a notice in place of their content. Everything
/// is back as soon as the share is over, or as soon as another display shows the screen. A recording, a mirror or a
/// display that is already there when the share starts keeps the full protection for that whole share.
///
/// The system reports one captured state for the screen: while the share runs, a second recorder or a mirror that has
/// no scene is not told apart from it. Displays that show up as scenes are.
@MainActor
enum PrivacyShield {

    /// What the capture protection does for one state.
    struct Protection: Equatable {
        /// The opaque cover over a protected screen that is being captured.
        let cover: Bool
        /// The secure canvas hosting the window content of the screens that hold the lock.
        let canvas: Bool
        /// The cover says that the share is why the content is hidden, not a recording.
        let shareNotice: Bool
    }

    /// Whether this device's own screen share is capturing the screen and its capture is confirmed running. False at
    /// launch; `setOwnShareActive` is its only writer.
    private(set) static var ownShareActive = false

    private static var started = false
    private static weak var blurView: UIView?
    private static weak var captureCover: UIView?
    private static var shownShareNotice = false
    /// The last lifted state that was logged.
    private static var liftedLogged = false

    /// Registers the observers once per process.
    static func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { showBlurIfNeeded() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { hideBlur(); protectionInputsChanged() }
        }
        center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refreshCaptureCover() }
        }
        // A scene on another display comes or goes: the protection follows at once, during the share and not only at
        // its start. A mirror gives the app no scene and the screen list is deprecated, so a mirror that starts during
        // the share is not told apart from our own capture.
        for name in [UIScene.willConnectNotification, UIScene.didDisconnectNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { displaysDidChange() }
            }
        }
    }

    /// Whether the app switcher snapshot must be blurred: a protected screen is up or the protection setting is on.
    static func shouldBlurSnapshot(lockHeld: Bool, protectionSetting: Bool) -> Bool {
        lockHeld || protectionSetting
    }

    /// The protection for a state. The cover needs a capture and a screen that holds the lock, the canvas needs a
    /// screen that holds the lock. While this device's own share is capturing and no other display shows the screen,
    /// only the screens that hold a secret count as held, and the cover is up for them whatever the capture flag says.
    static func protection(isCaptured: Bool, lockHeld: Bool, secretHeld: Bool, ownShareActive: Bool,
                           externalDisplay: Bool) -> Protection {
        let lifted = ownShareActive && !externalDisplay
        let held = lifted ? secretHeld : lockHeld
        let cover = held && (isCaptured || lifted)
        return Protection(cover: cover, canvas: held, shareNotice: cover && lifted)
    }

    /// The protection for the state of the app right now.
    static func currentProtection(isCaptured: Bool) -> Protection {
        protection(isCaptured: isCaptured,
                   lockHeld: ScreenshotLockService.isHeld,
                   secretHeld: ScreenshotLockService.isSecretHeld,
                   ownShareActive: ownShareActive,
                   externalDisplay: ownShareActive && externalDisplayPresent())
    }

    /// True while the screen is shown on another display: a scene with the external display role, application scenes
    /// that sit on more than one screen.
    static func externalDisplayPresent() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if scenes.contains(where: { $0.session.role != .windowApplication }) { return true }
        if Set(scenes.map { ObjectIdentifier($0.screen) }).count > 1 { return true }
        return false
    }

    /// Whether the screen of the key window is being captured: a recording, a mirror, or this device's own share.
    static func isScreenCaptured() -> Bool {
        keyWindow()?.screen.isCaptured ?? false
    }

    /// Whether the own share lifts the protection of the screens: its capture is confirmed running and the screen was
    /// not already captured or shown on another display when the share was started.
    static func liftsProtection(shareRunning: Bool, captureConfirmed: Bool, captureBeforeShare: Bool) -> Bool {
        shareRunning && captureConfirmed && !captureBeforeShare
    }

    /// Called right before this device's own capture is started: whether the screen is already captured (a recording, a
    /// mirror) or shown on another display. The answer is kept for the whole share, and one line is logged when it is
    /// yes (`own=2`: the protection stays up for this share).
    static func sampleCaptureBeforeShare() -> Bool {
        let display = externalDisplayPresent()
        guard isScreenCaptured() || display else { return false }
        RTLog.info("privacy", "canvas hosted=\(ScreenshotLockService.isHostedInSecureCanvas ? 1 : 0) own=2 display=\(display ? 1 : 0)")
        return true
    }

    /// Set by the app: true once this device's own screen share is capturing and its capture is confirmed running,
    /// false whenever it is over (a stop, a failure, the end of the call).
    static func setOwnShareActive(_ active: Bool) {
        guard active != ownShareActive else { return }
        ownShareActive = active
        protectionInputsChanged()
    }

    /// Puts the protection in line with its inputs (the own share, the displays, the screens that hold the lock) and
    /// logs one line each time the protection is lifted or comes back.
    static func protectionInputsChanged() {
        ScreenshotLockService.protectionDidChange()
        refreshCaptureCover()
        let display = ownShareActive && externalDisplayPresent()
        let lifted = ownShareActive && !display
        guard lifted != liftedLogged else { return }
        liftedLogged = lifted
        RTLog.info("privacy", "canvas hosted=\(ScreenshotLockService.isHostedInSecureCanvas ? 1 : 0) own=\(ownShareActive ? 1 : 0) display=\(display ? 1 : 0)")
    }

    /// A scene on another display came or went. The list of scenes can lag behind the notification, so it is read
    /// again shortly after.
    private static func displaysDidChange() {
        protectionInputsChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { protectionInputsChanged() }
        }
    }

    /// Brings the cover in line with the capture state, the lock and the own-share state. A cover that is no longer
    /// wanted is removed whatever the key window is; a cover that sits in another window than the key window is moved.
    static func refreshCaptureCover() {
        let window = keyWindow()
        let wanted = currentProtection(isCaptured: (window ?? captureCover?.window)?.screen.isCaptured ?? false)
        guard wanted.cover else {
            removeCaptureCover()
            return
        }
        // Wanted, but there is no window to put it in: the one that is up stays.
        guard let window else { return }
        if let cover = captureCover, cover.superview === window, shownShareNotice == wanted.shareNotice {
            // A presented screen is added above the cover: keep the cover on top.
            if window.subviews.last !== cover { window.bringSubviewToFront(cover) }
            return
        }
        removeCaptureCover()
        let cover = makeCaptureCover(frame: window.bounds, shareNotice: wanted.shareNotice)
        window.addSubview(cover)
        captureCover = cover
        shownShareNotice = wanted.shareNotice
        RTLog.info("privacy", "capcover shown=1")
    }

    private static func removeCaptureCover() {
        guard let cover = captureCover else { return }
        cover.removeFromSuperview()
        captureCover = nil
        RTLog.info("privacy", "capcover shown=0")
    }

    private static func makeCaptureCover(frame: CGRect, shareNotice: Bool) -> UIView {
        let cover = UIView(frame: frame)
        cover.accessibilityIdentifier = ScreenshotLockService.shieldIdentifier
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .black
        let label = UILabel()
        if shareNotice {
            label.text = String(localized: "privacy.share_hidden", defaultValue: "Nascosto durante la condivisione dello schermo", comment: "Full-screen notice shown instead of a screen with secret content while this device shares its screen in a call.")
        } else {
            label.text = String(localized: "privacy.capture_cover", defaultValue: "Registrazione schermo attiva: contenuto nascosto", comment: "Full-screen notice shown instead of a protected screen while the screen is being recorded or mirrored.")
        }
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
        return cover
    }

    private static func showBlurIfNeeded() {
        guard blurView == nil, let window = keyWindow() else { return }
        guard shouldBlurSnapshot(lockHeld: ScreenshotLockService.isHeld,
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
