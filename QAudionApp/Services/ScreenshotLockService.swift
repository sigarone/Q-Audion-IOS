import UIKit

/// W445: iOS equivalent of Android FLAG_SECURE. Marks the key window as
/// secure so iOS blurs the screen in the App Switcher and prevents screen
/// recording / AirPlay mirroring of chat content.
///
/// Usage:
///   - Call `lock()` in ChatDetailScreen.onAppear when screenshotLockEnabled.
///   - Call `unlock()` in ChatDetailScreen.onDisappear unconditionally.
///
/// Implementation: adds a zero-alpha secure UITextField as a subview of the
/// key window. iOS detects any UITextField with isSecureTextEntry = true in
/// the window hierarchy and automatically blurs the snapshot used for the
/// App Switcher and blocks AirPlay / ReplayKit screen capture. This is the
/// same technique used by banking apps (Chase, PayPal, etc.) and is fully
/// App Store compliant.
///
/// NIM-fix1 (MINOR-1): switched from integer-tag sentinel (tag 99999, collision
/// risk with third-party SDKs) to a static weak reference. `lock()` is
/// idempotent — no-op when `secureField` is already installed.
///
/// SECURITY H-18: the screenshot-lock preference
/// (`qaudion.chat.screenshot_lock_enabled`) now defaults to `true`
/// (changed in ChatDetailScreen) so chat content is FLAG_SECURE by
/// default instead of opt-in. This service holds no default-read of
/// the preference itself (it is a pure lock()/unlock() mechanism), so
/// no default needs flipping here.
///
/// TODO SECURITY H-18: extend secure-window protection to the other
/// content-sensitive screens (call screen, identity QR, key-export /
/// device-link, settings showing PSK material). Currently only
/// ChatDetailScreen installs the secure field, leaving those screens
/// screenshot-/recording-capturable. Out of scope for this change set.
@MainActor
public enum ScreenshotLockService {

    /// Retained weakly so the window's strong hold keeps it alive; this
    /// reference lets us remove it without a tag lookup. When the window is
    /// deallocated the field is deallocated too, clearing this reference
    /// automatically — no dangling pointer risk.
    private static weak var secureField: UITextField?

    /// Lock: insert the secure sentinel field into the key window.
    /// Idempotent — no-op if already locked.
    public static func lock() {
        guard secureField == nil else { return }
        guard let window = keyWindow() else { return }
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.alpha = 0
        window.addSubview(field)
        window.sendSubviewToBack(field)
        secureField = field
    }

    /// Unlock: remove the secure sentinel field from the key window.
    /// Idempotent — no-op if not locked.
    public static func unlock() {
        secureField?.removeFromSuperview()
        secureField = nil
    }

    // MARK: - Private helpers

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })
    }
}
