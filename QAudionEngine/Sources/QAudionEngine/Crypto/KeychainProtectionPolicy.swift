import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// IOS-SE (audit 2026-06-12) — single source of truth for whether the
/// high-value Keychain items (SOVEREIGN PSKs = chat/call session keys) are
/// gated behind device-owner authentication (Face ID / Touch ID, with
/// passcode fallback), and the shared authenticated `LAContext` that gives
/// an "authenticate once per app-unlock" UX instead of a prompt on every read.
///
/// DESIGN — deliberately conservative so it cannot brick existing users:
///   • **Default = device capability (2026-08-21, MASVS-AUTH A1b/I4).** When
///     the user has never explicitly chosen, the default now resolves to
///     [isAuthenticationAvailable] instead of a hardcoded `false` — on by
///     default wherever the device can actually satisfy it (mirrors the
///     device's own security posture), inert on a device with no biometry/
///     passcode enrolled at all (never bricks, matches concern #5 below).
///     This ONLY changes what a never-set preference resolves to — the
///     enable/migrate mechanism itself is untouched, and an EXISTING user
///     who already has an explicit choice recorded keeps it exactly as-is:
///     **no silent migration on update**, that guarantee still holds.
///   • **`.userPresence`, NOT `.biometryCurrentSet`.** `.userPresence`
///     accepts biometry OR the device passcode and SURVIVES a Face/Touch
///     re-enrollment, so a user can never be permanently locked out of their
///     own keys. `.biometryCurrentSet` would invalidate the item the moment
///     the biometric set changes — unacceptable for identity material.
///   • **Session reuse.** A single `LAContext`, evaluated once at app unlock,
///     is passed to Keychain reads via `kSecUseAuthenticationContext`. Within
///     the reuse window iOS does not re-prompt → "unlock once per session".
///
/// ⚠️ DEVICE VALIDATION REQUIRED before flipping the default to ON:
///   1. Fresh install, toggle ON  → store + read a PSK round-trips with one
///      Face ID prompt per session.
///   2. Upgrade with existing PSKs, toggle ON → `migrate(enable:)` re-protects
///      every item WITHOUT data loss (verified copy before delete).
///   3. Toggle OFF again → items become readable without a prompt; no loss.
///   4. Re-enroll Face ID while ON → keys still readable via passcode.
///   5. Biometry-unavailable device (no Face/Touch) → toggle refuses to enable
///      (or falls back to passcode) rather than locking the vault.
public final class KeychainProtectionPolicy: @unchecked Sendable {

    public static let shared = KeychainProtectionPolicy()

    /// UserDefaults key for the persisted opt-in flag. Default = false.
    private static let enabledDefaultsKey = "qaudion.security.biometricKeyProtection.enabled"

    private let defaults: UserDefaults
    private let lock = NSLock()

    /// The shared context authenticated at app unlock and reused for reads.
    /// `nil` until `prepareSession` succeeds; reset on `invalidateSession`.
    private var sessionContext: AnyObject?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Toggle state

    /// Whether biometric key protection is currently enabled (persisted).
    ///
    /// MASVS-AUTH remediation (2026-08-21, A1b/I4) — `UserDefaults.bool`
    /// alone can't distinguish "never set" from "explicitly false" (both
    /// read as `false`), so the never-set case is checked explicitly and
    /// resolves to [isAuthenticationAvailable] as the computed default. An
    /// explicit prior choice (either value) is always honored unchanged.
    public var isEnabled: Bool {
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            return isAuthenticationAvailable
        }
        return defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    /// Persist the toggle state. Callers MUST run `SovereignKeyVault.migrate*`
    /// to (un)protect existing items; this only records the preference.
    public func setEnabledFlag(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    // MARK: - Biometry availability

    /// True if the device can perform device-owner authentication
    /// (biometry or passcode). UI uses this to decide whether the toggle is
    /// offerable and to warn if no biometry is enrolled.
    public var isAuthenticationAvailable: Bool {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        #else
        return false
        #endif
    }

    /// "faceID" | "touchID" | "opticID" | "none" — for picking the UI icon.
    public var biometryType: String {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return "none" }
        switch ctx.biometryType {
        case .faceID:  return "faceID"
        case .touchID: return "touchID"
        case .opticID: return "opticID"
        case .none:    return "none"
        @unknown default: return "unknown"
        }
        #else
        return "none"
        #endif
    }

    // MARK: - Access control (write side)

    /// The `SecAccessControl` to attach to a protected Keychain item when the
    /// policy is enabled, or `nil` when disabled (caller then uses the plain
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` path, unchanged).
    ///
    /// `.userPresence` ⇒ biometry-or-passcode, survives re-enrollment.
    public func makeAccessControl() -> SecAccessControl? {
        #if canImport(Security)
        guard isEnabled else { return nil }
        var error: Unmanaged<CFError>?
        let ac = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        )
        return ac
        #else
        return nil
        #endif
    }

    // MARK: - Session (read side)

    /// Authenticate once (typically at app unlock) so subsequent protected
    /// reads in this session do not re-prompt. Returns true on success or if
    /// the policy is disabled (nothing to do). Safe to call repeatedly.
    @discardableResult
    public func prepareSession(reason: String = "Sblocca le chiavi sicure di Q-Audion") async -> Bool {
        guard isEnabled else { return true }
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Usa codice"
        // Allow Keychain reads to reuse this evaluation within the window so we
        // don't prompt on every PSK access during a call/chat session.
        ctx.touchIDAuthenticationAllowableReuseDuration = LATouchIDAuthenticationMaximumAllowableReuseDuration
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        let ok: Bool = await withCheckedContinuation { cont in
            ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                cont.resume(returning: success)
            }
        }
        if ok { setSessionContext(ctx) }
        return ok
        #else
        return false
        #endif
    }

    private func setSessionContext(_ ctx: AnyObject) {
        lock.lock(); sessionContext = ctx; lock.unlock()
    }

    /// Drop the authenticated session (e.g. on app background / lock). The next
    /// protected read will require a fresh `prepareSession`.
    public func invalidateSession() {
        lock.lock(); sessionContext = nil; lock.unlock()
    }

    /// The authenticated `LAContext` to attach to a protected read via
    /// `kSecUseAuthenticationContext`, or `nil` when disabled / not yet
    /// authenticated (Keychain will then prompt on demand for that read).
    public func authenticationContext() -> AnyObject? {
        guard isEnabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        return sessionContext
    }
}
