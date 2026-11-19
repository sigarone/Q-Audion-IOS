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
/// No view of this type takes a touch during the share, and no cover of any kind goes up from the moment the person
/// starts the share until it is completely over: while the system capture is starting, while it runs (also when the
/// canvas cannot host the content), and, when the capture did not stop as asked, until the screen is no longer
/// captured. The one exception is a display that shows up as a scene while the share runs: the screen is then seen by
/// somebody else too, and the protection is the one of any capture, with a cover that takes no touches (the share ends
/// at once). Everything is back as soon as the share is over.
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

    /// Whether the person has started a share that is not yet confirmed running: the capture is being set up or has
    /// just begun. No cover goes up in that span either. Set before the capture starts; cleared by `setShareStarting`,
    /// by `setOwnShareActive` and by `endOwnShare`.
    private(set) static var shareStarting = false

    /// What a stop of the share answered.
    enum StopOutcome {
        /// The capture is over; the screen state may still lag the answer for a moment.
        case stopped
        /// The capture is still running after the stop.
        case stillCapturing
    }

    /// Whether the share is over but the screen may still be captured by it. After a stop that reported the capture
    /// still running it holds until the screen is no longer captured; after a stop that answered "stopped" it only
    /// absorbs the lag of the screen state: it clears at the first refresh that sees the screen not captured or when
    /// `endingBound` has passed, so a mirror that started meanwhile gets its cover.
    private(set) static var shareEnding = false

    /// Whether the ending state follows a stop that reported the capture still running: no bound applies.
    private(set) static var shareEndingStillCapturing = false

    /// Counts the ending states and share starts, so a bound of an older state never clears a newer one.
    private(set) static var endingGeneration = 0

    /// How long the ending state after a stop that answered "stopped" can last, in seconds.
    static var endingBound: TimeInterval = 3

    /// The own share as far as covers are concerned: from the start of the share until it is completely over.
    static var ownShareSpan: Bool { ownShareActive || shareStarting || shareEnding }

    /// Tag carried by the cover (and by no other view), so every cover can be found and removed.
    private static let coverTag = 0x51_43_4F_56

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
    /// only the screens that hold a secret count: they get the canvas and the notice and never a cover, also where the
    /// canvas could not host the content (`canvasHosted` false), where nothing extra is shown.
    static func protection(isCaptured: Bool, lockHeld: Bool, secretHeld: Bool, ownShareActive: Bool,
                           externalDisplay: Bool, canvasHosted: Bool = true) -> Protection {
        let takesTouches = !ownShareActive
        if ownShareActive && !externalDisplay {
            return Protection(cover: false, canvas: secretHeld,
                              notice: secretHeld && canvasHosted, coverTakesTouches: takesTouches)
        }
        return Protection(cover: lockHeld && isCaptured, canvas: lockHeld, notice: false, coverTakesTouches: takesTouches)
    }

    /// The protection for the state of the app right now.
    static func currentProtection(isCaptured: Bool) -> Protection {
        protection(isCaptured: isCaptured,
                   lockHeld: ScreenshotLockService.isHeld,
                   secretHeld: ScreenshotLockService.isSecretHeld,
                   ownShareActive: ownShareSpan,
                   externalDisplay: ownShareSpan && externalDisplayPresent(),
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
        capturedOverride ?? keyWindow()?.screen.isCaptured ?? false
    }

    /// A capture state that stands in for the screen's own. Only a test sets it.
    static var capturedOverride: Bool?

    /// Set by the app: true once this device's own screen share is capturing and its capture is confirmed running,
    /// false whenever it is over (a stop, a failure, the end of the call).
    static func setOwnShareActive(_ active: Bool) {
        guard active != ownShareActive || (active && shareStarting) else { return }
        ownShareActive = active
        if active { shareStarting = false }
        protectionInputsChanged()
    }

    /// Set by the app before the capture of a share starts and cleared when the share is confirmed running or is over.
    static func setShareStarting(_ starting: Bool) {
        guard starting != shareStarting else { return }
        shareStarting = starting
        if starting { clearShareEnding() }
        protectionInputsChanged()
    }

    /// The own share is completely over (a stop, a failure, a refusal, the end of the call): neither the running nor the
    /// starting state is left.
    /// A capture that is still open stays in the own-share span (`shareEnding`) until the screen is no longer captured.
    static func endOwnShare() {
        let ending = shareEnding && isScreenCaptured()
        guard ownShareActive || shareStarting || shareEnding != ending else { return }
        ownShareActive = false
        shareStarting = false
        shareEnding = ending
        if !ending { shareEndingStillCapturing = false }
        protectionInputsChanged()
    }

    /// Called after every stop of the own share. While the screen is captured it can still be the person's own capture
    /// (the state of the screen lags the answer of the stop), so no cover goes up. After a stop that reported the
    /// capture still running the state holds until a refresh sees the screen not captured; otherwise it also ends
    /// after `endingBound`. A stop that reported the capture still running is not downgraded by a later "stopped".
    static func markShareEnding(_ outcome: StopOutcome) {
        let isCaptured = isScreenCaptured()
        endingGeneration += 1
        shareEnding = isCaptured
        shareEndingStillCapturing = isCaptured && (outcome == .stillCapturing || shareEndingStillCapturing)
        if shareEnding && !shareEndingStillCapturing {
            let generation = endingGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + endingBound) {
                MainActor.assumeIsolated { endingBoundPassed(generation: generation) }
            }
        }
        protectionInputsChanged()
    }

    /// The bound of an ending state passed: clears it, unless a newer state superseded it or the capture is still
    /// running after the stop.
    static func endingBoundPassed(generation: Int) {
        guard generation == endingGeneration, shareEnding, !shareEndingStillCapturing else { return }
        clearShareEnding()
        protectionInputsChanged()
    }

    private static func clearShareEnding() {
        shareEnding = false
        shareEndingStillCapturing = false
        endingGeneration += 1
    }

    /// Clears the ending state once the screen is no longer captured. Returns whether it changed anything.
    @discardableResult
    static func refreshShareEnding(isCaptured: Bool) -> Bool {
        guard shareEnding, !isCaptured else { return false }
        clearShareEnding()
        return true
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
        let captured = capturedOverride ?? (window ?? captureCover?.window)?.screen.isCaptured ?? false
        if refreshShareEnding(isCaptured: captured) { ScreenshotLockService.protectionDidChange() }
        let wanted = currentProtection(isCaptured: captured)
        apply(wanted, in: window)
    }

    /// Puts the cover and the notice of `wanted` in `window`. Without a window, what is wanted and already up stays.
    static func apply(_ wanted: Protection, in window: UIWindow?) {
        if !wanted.cover { removeCaptureCover(also: window) }
        if !wanted.notice { removeShareNotice() }
        guard let window else { return }
        if wanted.cover { placeCover(wanted, in: window) }
        if wanted.notice { placeNotice(in: window) }
    }

    private static func placeCover(_ wanted: Protection, in window: UIWindow) {
        let forShare = !wanted.coverTakesTouches
        let up = coversUp(also: window)
        if let cover = captureCover, up.count == 1, up[0] === cover, cover.superview === window, shownShareCover == forShare {
            cover.isUserInteractionEnabled = wanted.coverTakesTouches
            // A presented screen is added above the cover: keep the cover on top.
            if window.subviews.last !== cover { window.bringSubviewToFront(cover) }
            return
        }
        // Any other cover goes first, so there is never more than one.
        removeCaptureCover(also: window)
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

    /// Every cover view in every window of every connected scene (and in the extra window), and the one this type remembers.
    private static func coversUp(also extra: UIWindow? = nil) -> [UIView] {
        var found: [UIView] = []
        var windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        if let extra, !windows.contains(where: { $0 === extra }) { windows.append(extra) }
        for window in windows {
            for view in window.subviews where view.tag == coverTag
                && view.accessibilityIdentifier == ScreenshotLockService.shieldIdentifier {
                found.append(view)
            }
        }
        if let cover = captureCover, !found.contains(where: { $0 === cover }) { found.append(cover) }
        return found
    }

    /// Removes every cover, wherever it sits, and logs one line with how many were removed. Does nothing when none is up.
    private static func removeCaptureCover(also window: UIWindow? = nil) {
        let covers = coversUp(also: window)
        captureCover = nil
        guard !covers.isEmpty else { return }
        for cover in covers { cover.removeFromSuperview() }
        RTLog.info("privacy", "capcover shown=0 n=\(covers.count)")
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
        cover.tag = coverTag
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
