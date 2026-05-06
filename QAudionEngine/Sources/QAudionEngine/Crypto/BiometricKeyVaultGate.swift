import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

/// W373 — biometric-gated wrapper around SovereignKeyVault accesses.
///
/// The keychain items used by `SovereignKeyVault` already use
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so a casual
/// device-grab after a passcode unlock can read them. For high-value
/// material (PSKs that bind chat / call sessions), we want stronger:
/// every read requires a fresh biometric prompt (Face ID / Touch ID)
/// or device-owner passcode.
///
/// This is an **opt-in upgrade** — production callers who want the
/// extra friction on high-value PSKs can route reads through
/// `BiometricKeyVaultGate.shared.protectedLoad(...)`. Lower-value
/// reads keep using `SovereignKeyVault.loadPsk` directly.
///
/// **Cross-platform parity:** mirrors Android's
/// `EncryptedSharedPreferences` + Keystore biometric-gated
/// constructor for the SOVEREIGN tier (see
/// `qaudion-android/.../SovereignVault.kt`).
public final class BiometricKeyVaultGate: @unchecked Sendable {

    public static let shared = BiometricKeyVaultGate()

    public enum GateError: Error, LocalizedError {
        case biometryUnavailable
        case userCancelled
        case authFailed(String)
        case loadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .biometryUnavailable:  return "Biometria non disponibile su questo dispositivo"
            case .userCancelled:        return "Sblocco annullato"
            case .authFailed(let m):    return "Autenticazione fallita: \(m)"
            case .loadFailed(let m):    return "Vault load fallito: \(m)"
            }
        }
    }

    private let underlying: SovereignKeyVault

    public init(underlying: SovereignKeyVault = SovereignKeyVault()) {
        self.underlying = underlying
    }

    /// Prompt the user with Face ID / Touch ID (passcode fallback) and,
    /// on success, return the named PSK. Reasoning string is shown in
    /// the system biometric sheet.
    public func protectedLoad(
        name: String,
        reason: String = "Sblocca per usare la chiave PSK"
    ) async throws -> Data? {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Usa codice"
        var laError: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &laError) else {
            throw GateError.biometryUnavailable
        }
        do {
            // W385: avoid name collision with the iOS 16+ stock
            // `evaluatePolicy(_:localizedReason:)` async overload —
            // use a distinct helper name on our extension to keep the
            // call unambiguous on every deployment target.
            try await Self.runEvaluatePolicy(
                ctx: ctx,
                policy: .deviceOwnerAuthentication,
                reason: reason
            )
        } catch let err as LAError {
            switch err.code {
            case .userCancel, .systemCancel, .appCancel:
                throw GateError.userCancelled
            default:
                throw GateError.authFailed(err.localizedDescription)
            }
        }
        do {
            return try underlying.loadPsk(name: name)
        } catch {
            throw GateError.loadFailed(String(describing: error))
        }
        #else
        // Non-iOS host (e.g. Linux test runner) — fall back to plain load.
        return try underlying.loadPsk(name: name)
        #endif
    }

    /// Synchronous availability probe — UI uses this to decide whether
    /// to render a "biometric lock" badge next to a PSK item.
    public var isBiometryAvailable: Bool {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
        #else
        return false
        #endif
    }

    /// Returns the kind of biometry the device exposes (faceID,
    /// touchID, opticID, or none) so the UI can pick the right icon.
    public var biometryType: String {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return "none"
        }
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
}

#if canImport(LocalAuthentication)
extension BiometricKeyVaultGate {
    /// W385 — distinct helper name (not `evaluatePolicy`) so we don't
    /// collide with the iOS 16+ stock async overload of the same
    /// signature on LAContext. The completion-handler form is the
    /// stable cross-version primitive; we always wrap it ourselves so
    /// behavior is predictable.
    fileprivate static func runEvaluatePolicy(
        ctx: LAContext,
        policy: LAPolicy,
        reason: String
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ctx.evaluatePolicy(policy, localizedReason: reason) { success, err in
                if success {
                    cont.resume()
                } else if let err = err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume(throwing: LAError(.authenticationFailed))
                }
            }
        }
    }
}
#endif
