import UIKit

/// W445: iOS equivalent of Android FLAG_SECURE. Keeps what is on screen out of
/// screenshots, screen recording, mirroring and the App Switcher snapshot.
///
/// Usage: each screen takes the lock under its own owner key
/// (`lock(owner: "chat_detail")`) and releases only that key, so one screen can
/// never remove another screen protection. The protection stays up while any
/// owner is registered.
///
/// Implementation: every layer directly under the window layer (the root
/// container and each presentation or transition container) is re-parented into
/// the internal canvas layer of its own secure UITextField. Content drawn inside
/// that canvas is withheld from captures (it comes out black). A new
/// window sublayer (a sheet or cover being presented) is hosted in the same run
/// loop pass, before it is drawn; a short timer and didBecomeActive are a safety
/// net. The secure field forwards touches to the content it hosts. If the
/// private canvas cannot be found, a window-level secure field is used instead
/// and one log line says so.
///
/// SECURITY H-18: the screenshot-lock preference
/// (`qaudion.chat.screenshot_lock_enabled`) defaults to `true`. This service
/// holds no default-read of the preference itself.
@MainActor
public enum ScreenshotLockService {

    /// Secure text field that hosts one window layer in its canvas. It never edits text; touches go to the content.
    final class SecureCanvasField: UITextField {
        override var canBecomeFirstResponder: Bool { false }

        /// The view whose layer sits in this field canvas. Only its layer moved, so UIKit still knows it as a window
        /// subview; touches are handed to it directly.
        weak var hostedView: UIView?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let view = hostedView, view.window != nil else { return nil }
            return view.hitTest(view.convert(point, from: self), with: event)
        }
    }

    private final class Hosted {
        let field: SecureCanvasField
        weak var layer: CALayer?
        weak var originalSuperlayer: CALayer?
        let originalIndex: Int
        var boundsObservation: NSKeyValueObservation?

        init(field: SecureCanvasField, layer: CALayer, originalSuperlayer: CALayer?, originalIndex: Int) {
            self.field = field
            self.layer = layer
            self.originalSuperlayer = originalSuperlayer
            self.originalIndex = originalIndex
        }
    }

    private static var hosted: [Hosted] = []
    /// Window-level hidden sibling secure field, used only while the canvas could not be used.
    private static var windowFallback: UITextField?
    private static var owners: Set<String> = []
    private static var loggedNoCanvas = false
    private static var watchdog: Timer?
    private static weak var lastWindow: UIWindow?
    private static weak var observedWindow: UIWindow?
    private static var sublayersObservation: NSKeyValueObservation?
    private static var installing = false

    /// Identifier of the cover views of PrivacyShield: they must stay visible to a recording, so they are not hosted.
    static let shieldIdentifier = "qa.privacy.shield"

    /// Lock under one owner key. Idempotent per owner.
    public static func lock(owner: String = "legacy", in window: UIWindow? = nil) {
        owners.insert(owner)
        startWatchdog()
        install(in: window ?? keyWindow())
    }

    /// Unlock one owner key; the protection is removed when no owner is left.
    public static func unlock(owner: String = "legacy") {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        uninstallAll()
    }

    /// True while the protection is installed on at least one live layer (or the window fallback is up).
    public static var isLocked: Bool {
        hosted.contains(where: { $0.layer != nil }) || windowFallback != nil
    }

    /// True when content is inside the secure canvas (not just the fallback field).
    public static var isHostedInSecureCanvas: Bool { hosted.contains(where: { $0.layer != nil }) }

    /// Remove the protection for one capture and hand back what to restore.
    static func suspendAll() -> Set<String> {
        let held = owners
        owners = []
        uninstallAll()
        return held
    }

    static func resume(_ held: Set<String>) {
        for owner in held { lock(owner: owner) }
    }

    /// Safety net: re-hosts any window layer that is not inside a canvas. Runs on a short timer while any owner holds
    /// the lock, and when the app becomes active. The primary mechanism is the sublayer observer.
    static func revalidate() {
        guard !owners.isEmpty else { return }
        install(in: lastWindow ?? keyWindow())
    }

    // MARK: - Install / uninstall

    /// Hosts every content layer of `window`. Internal so a test can drive it with its own window.
    static func install(in window: UIWindow?) {
        guard let window, !installing else { return }
        installing = true
        defer { installing = false }
        lastWindow = window
        startWatchdog()
        observeWindow(window)
        // Layers that went away are forgotten.
        for entry in hosted where entry.layer == nil { release(entry) }
        hosted.removeAll(where: { $0.layer == nil })
        var hostFailed = false
        for layer in contentLayers(of: window) {
            if let entry = host(layer, in: window) {
                hosted.append(entry)
            } else {
                hostFailed = true
            }
        }
        if hosted.isEmpty || hostFailed {
            installWindowFallback(in: window)
        } else {
            windowFallback?.removeFromSuperview()
            windowFallback = nil
        }
        PrivacyShield.refreshCaptureCover()
    }

    /// The layers directly under the window layer that are neither one of our fields nor a shield cover.
    private static func contentLayers(of window: UIWindow) -> [CALayer] {
        (window.layer.sublayers ?? []).filter { layer in
            if layer.delegate is SecureCanvasField { return false }
            if let view = layer.delegate as? UIView, view.accessibilityIdentifier == shieldIdentifier { return false }
            if view(of: layer) === windowFallback { return false }
            return true
        }
    }

    private static func view(of layer: CALayer) -> UIView? { layer.delegate as? UIView }

    /// Hosts one layer. Returns nil (and logs once) when the private canvas cannot be found.
    private static func host(_ layer: CALayer, in window: UIWindow) -> Hosted? {
        let parent = window.layer
        let index = parent.sublayers?.firstIndex(of: layer) ?? 0
        let field = SecureCanvasField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.isAccessibilityElement = false
        field.backgroundColor = .clear
        field.frame = window.bounds
        window.addSubview(field)
        field.layoutIfNeeded()
        guard let canvas = canvasLayer(of: field) else {
            field.removeFromSuperview()
            if !loggedNoCanvas {
                loggedNoCanvas = true
                RTLog.warn("privacy", "canvas hosted=0 why=1")
            }
            return nil
        }
        // The field layer takes the place of the hosted layer in the z order.
        parent.insertSublayer(field.layer, below: layer)
        field.hostedView = layer.delegate as? UIView
        canvas.addSublayer(layer)
        let entry = Hosted(field: field, layer: layer, originalSuperlayer: parent, originalIndex: index)
        entry.boundsObservation = window.layer.observe(\.bounds, options: [.new]) { [weak field, weak window] _, _ in
            Task { @MainActor in
                guard let field, let window else { return }
                field.frame = window.bounds
            }
        }
        RTLog.info("privacy", "canvas hosted=1")
        return entry
    }

    private static func installWindowFallback(in window: UIWindow) {
        guard windowFallback == nil else { return }
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.alpha = 0
        window.addSubview(field)
        window.sendSubviewToBack(field)
        windowFallback = field
    }

    private static func release(_ state: Hosted) {
        state.boundsObservation?.invalidate()
        if let layer = state.layer, let parent = state.originalSuperlayer {
            let count = parent.sublayers?.count ?? 0
            parent.insertSublayer(layer, at: UInt32(min(state.originalIndex, count)))
        }
        state.field.removeFromSuperview()
    }

    /// A new window sublayer (a presentation container) is hosted in the same run loop pass, before it is drawn.
    private static func observeWindow(_ window: UIWindow) {
        guard observedWindow !== window else { return }
        observedWindow = window
        sublayersObservation?.invalidate()
        sublayersObservation = window.layer.observe(\.sublayers, options: []) { _, _ in
            MainActor.assumeIsolated { if !installing { revalidate() } }
        }
    }

    private static func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { revalidate() }
        }
    }

    private static func uninstallAll() {
        watchdog?.invalidate()
        watchdog = nil
        sublayersObservation?.invalidate()
        sublayersObservation = nil
        observedWindow = nil
        installing = true
        defer { installing = false }
        let all = hosted
        hosted = []
        // Last hosted first, so each layer returns to the position it came from.
        for entry in all.reversed() { release(entry) }
        windowFallback?.removeFromSuperview()
        windowFallback = nil
        PrivacyShield.refreshCaptureCover()
    }

    // MARK: - Private helpers

    /// The internal canvas of a secure text field: the subview whose class name contains "CanvasView".
    /// A private detail of UIKit; when it is not found the window-level field is used.
    static func canvasLayer(of field: UITextField) -> CALayer? {
        if let view = field.subviews.first(where: { String(describing: type(of: $0)).contains("CanvasView") }) {
            view.isUserInteractionEnabled = true
            return view.layer
        }
        return nil
    }

    private static func keyWindow() -> UIWindow? {
        // The window of the foreground phone scene, never a CarPlay or other scene.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
        return scene?.windows.first(where: { $0.isKeyWindow })
    }
}
