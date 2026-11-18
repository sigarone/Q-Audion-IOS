import UIKit

/// Two cover layers over the key window, both independent of the secure canvas so they still work if UIKit changes
/// its private internals:
///  - a blur while the app is about to leave the foreground (the App Switcher snapshot is taken right after);
///  - an opaque cover with a short notice while the screen is being recorded or mirrored and a protected screen is up.
///
/// While this device's own share is capturing, the person shares their own screens: the shared image is the real
/// screen and every control of the app stays reachable. The screens that hold a secret or the content of other people
/// (see `ScreenshotLockService.secretOwners`) stay inside the secure canvas, so they come out black in the shared image
/// while the person sees and uses them normally; a small notice at the top of the window, outside the canvas, says so.
/// No view of this type takes a touch during the share. When the canvas cannot host the content, a cover that takes no
/// touches stands in for it. Everything is back as soon as the share is over.
///
/// A share does not start while the screen is already captured or shown on another display, and it ends when a display
/// shows up during it (`onDisplayAppeared`).
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
        /// The small notice at the top of the window: the canvas hides a screen from the share.
        let notice: Bool
        /// Whether the cover takes touches. It never does while this device's own share is capturing.
        let coverTakesTouches: Bool
    }

    /// Whether this device's own screen share is capturing the screen and its capture is confirmed running. False at
    /// launch; `setOwnShareActive` is its only writer.
    private(set) static var ownShareActive = false

    private static var started = false
    private static weak var blurView: UIView?
    private static weak var captureCover: UIView?
    private static weak var shareNotice: UIView?
    /// Whether the cover that is up carries the text of the share.
    private static var shownShareCover = false
    /// Called on the main actor when this device's own share is capturing and another display shows up. Set by the app.
    static var onDisplayAppeared: (() -> Void)?
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
    /// only the screens that hold a secret count: they get the canvas and the notice and never a cover, except where
    /// the canvas could not host the content (`canvasHosted` false), where a cover that takes no touches stands in.
    static func protection(isCaptured: Bool, lockHeld: Bool, secretHeld: Bool, ownShareActive: Bool,
                           externalDisplay: Bool, canvasHosted: Bool = true) -> Protection {
        let takesTouches = !ownShareActive
        if ownShareActive && !externalDisplay {
            return Protection(cover: secretHeld && !canvasHosted, canvas: secretHeld,
                              notice: secretHeld && canvasHosted, coverTakesTouches: takesTouches)
        }
        return Protection(cover: lockHeld && isCaptured, canvas: lockHeld, notice: false, coverTakesTouches: takesTouches)
    }

    /// The protection for the state of the app right now.
    static func currentProtection(isCaptured: Bool) -> Protection {
        protection(isCaptured: isCaptured,
                   lockHeld: ScreenshotLockService.isHeld,
                   secretHeld: ScreenshotLockService.isSecretHeld,
                   ownShareActive: ownShareActive,
                   externalDisplay: ownShareActive && externalDisplayPresent(),
                   canvasHosted: !ScreenshotLockService.isOnFallback)
    }

    /// True while the screen is shown on another display: a scene with the external display role, application scenes
    /// that sit on more than one screen.
    static func externalDisplayPresent() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if scenes.contains(where: { $0.session.role != .windowApplication }) { return true }
        if Set(scenes.map { ObjectIdentifier($0.screen) }).count > 1 { return true }
        return false
    }

    /// Whether the screen of the key window is being captured: a recording, a mirror, or this device's own share. Asked
    /// before this device's own capture starts, it is about something else.
    static func isScreenCaptured() -> Bool {
        keyWindow()?.screen.isCaptured ?? false
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
        reportDisplayDuringShare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                protectionInputsChanged()
                reportDisplayDuringShare()
            }
        }
    }

    /// Tells the app when another display shows the screen while this device's own share is capturing.
    static func reportDisplayDuringShare() {
        guard ownShareActive, externalDisplayPresent() else { return }
        onDisplayAppeared?()
    }

    /// Brings the cover and the notice in line with the capture state, the lock and the own-share state. A view that is
    /// no longer wanted is removed whatever the key window is; one that sits in another window than the key window is
    /// moved.
    static func refreshCaptureCover() {
        let window = keyWindow()
        let wanted = currentProtection(isCaptured: (window ?? captureCover?.window)?.screen.isCaptured ?? false)
        apply(wanted, in: window)
    }

    /// Puts the cover and the notice of `wanted` in `window`. Without a window, what is wanted and already up stays.
    static func apply(_ wanted: Protection, in window: UIWindow?) {
        if !wanted.cover { removeCaptureCover() }
        if !wanted.notice { removeShareNotice() }
        guard let window else { return }
        if wanted.cover { placeCover(wanted, in: window) }
        if wanted.notice { placeNotice(in: window) }
    }

    private static func placeCover(_ wanted: Protection, in window: UIWindow) {
        let forShare = !wanted.coverTakesTouches
        if let cover = captureCover, cover.superview === window, shownShareCover == forShare {
            cover.isUserInteractionEnabled = wanted.coverTakesTouches
            // A presented screen is added above the cover: keep the cover on top.
            if window.subviews.last !== cover { window.bringSubviewToFront(cover) }
            return
        }
        removeCaptureCover()
        let cover = makeCaptureCover(frame: window.bounds, forShare: forShare)
        cover.isUserInteractionEnabled = wanted.coverTakesTouches
        window.addSubview(cover)
        captureCover = cover
        shownShareCover = forShare
        RTLog.info("privacy", "capcover shown=1")
    }

    private static func placeNotice(in window: UIWindow) {
        if let notice = shareNotice, notice.superview === window {
            if window.subviews.last !== notice { window.bringSubviewToFront(notice) }
            return
        }
        removeShareNotice()
        let notice = makeShareNotice()
        window.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 6),
            notice.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 16),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -16)
        ])
        shareNotice = notice
    }

    private static func removeCaptureCover() {
        guard let cover = captureCover else { return }
        cover.removeFromSuperview()
        captureCover = nil
        RTLog.info("privacy", "capcover shown=0")
    }

    private static func removeShareNotice() {
        shareNotice?.removeFromSuperview()
        shareNotice = nil
    }

    /// The text that says a screen is hidden from the share.
    private static var shareHiddenText: String {
        String(localized: "privacy.share_notice", defaultValue: "Nascosto a chi guarda la condivisione", comment: "Notice at the top of the screen while this device shares its screen in a call: the screen that is up is hidden from the people watching the share.")
    }

    /// The small notice: a pill with the text, outside the secure canvas so the person and the peer both see it. It takes
    /// no touches.
    private static func makeShareNotice() -> UIView {
        let pill = UIView()
        pill.accessibilityIdentifier = ScreenshotLockService.shieldIdentifier
        pill.isUserInteractionEnabled = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        pill.layer.cornerRadius = 12
        let label = UILabel()
        label.text = shareHiddenText
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12)
        ])
        return pill
    }

    private static func makeCaptureCover(frame: CGRect, forShare: Bool) -> UIView {
        let cover = UIView(frame: frame)
        cover.accessibilityIdentifier = ScreenshotLockService.shieldIdentifier
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.backgroundColor = .black
        let label = UILabel()
        label.text = forShare
            ? shareHiddenText
            : String(localized: "privacy.capture_cover", defaultValue: "Registrazione schermo attiva: contenuto nascosto", comment: "Full-screen notice shown instead of a protected screen while the screen is being recorded or mirrored.")
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
        blur.isUserInteractionEnabled = !ownShareActive
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
