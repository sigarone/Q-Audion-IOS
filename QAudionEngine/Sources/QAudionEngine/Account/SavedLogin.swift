import Foundation
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// The extension and password a person chose to keep behind biometrics, so the password never has to
/// be typed again.
public struct SavedLogin: Equatable, Sendable {
    public let extensionNumber: String
    public let password: String

    public init(extensionNumber: String, password: String) {
        self.extensionNumber = extensionNumber
        self.password = password
    }
}

/// What the person answered when asked whether to keep the password.
public enum SavedLoginDecision: String, Sendable {
    case unasked
    case declined
    case saved
}

/// Result of reading the protected item.
public enum SavedLoginReadResult: Equatable, Sendable {
    case found(SavedLogin)
    case notFound
    /// The person cancelled the biometric prompt, or it failed: the item is still there.
    case notAuthenticated
}

/// The Keychain seam of ``SavedLoginStore``: bytes in, bytes out. The production implementation puts
/// the bytes behind biometrics; a test passes an in-memory one.
public protocol SavedLoginKeychain: AnyObject {
    /// Replaces whatever is stored. False when the item could not be written.
    func write(_ data: Data) -> Bool
    /// Reads the item; the production implementation asks for biometrics with `reason`.
    func read(reason: String) -> (data: Data?, authenticationFailed: Bool)
    /// True when an item exists. Never prompts.
    func exists() -> Bool
    /// True when the item can never be read again because the enrolled biometric set changed (or none is
    /// enrolled any more). Never prompts.
    func isInvalidated() -> Bool
    func delete()
}

public extension SavedLoginKeychain {
    func isInvalidated() -> Bool { false }
}

/// Decides, without prompting, whether the biometric set changed since the item was written.
/// `stored` is the LAContext `evaluatedPolicyDomainState` recorded at save time, `current` the one now.
public enum BiometrySetCheck {
    public static func isInvalidated(stored: Data?, current: Data?, notEnrolled: Bool) -> Bool {
        if notEnrolled { return true }
        guard let stored, let current else { return false }
        return stored != current
    }
}

/// Keeps the extension + password behind biometrics in the Keychain and remembers the person's answer.
///
/// Rules:
///  - the item is only readable after a biometric check by one of the fingerprints / faces enrolled when it
///    was written (`.biometryCurrentSet`): enrolling another one invalidates it, and the person types the
///    password once more;
///  - it is available only on this device with a passcode set, never synced, never in a backup;
///  - a password is never logged;
///  - a normal sign-out keeps it; deleting the account, a remote wipe, a locked account, turning it off in
///    settings, or the server rejecting the saved password remove it (`deleteAll()`), and the answer starts over.
public final class SavedLoginStore: @unchecked Sendable {
    public static let shared = SavedLoginStore(keychain: SystemSavedLoginKeychain(),
                                               defaults: .standard)

    static let decisionKey = "com.qaudion.savedLogin.decision"

    private let keychain: SavedLoginKeychain
    private let defaults: UserDefaults

    public init(keychain: SavedLoginKeychain, defaults: UserDefaults) {
        self.keychain = keychain
        self.defaults = defaults
    }

    public var decision: SavedLoginDecision {
        get {
            SavedLoginDecision(rawValue: defaults.string(forKey: Self.decisionKey) ?? "") ?? .unasked
        }
        set { defaults.set(newValue.rawValue, forKey: Self.decisionKey) }
    }

    /// True when the person should be asked now: not decided yet.
    public var shouldAsk: Bool { decision == .unasked }

    /// True when a protected item exists. Never prompts.
    /// An item made unusable by a changed biometric set is removed on the spot (and the decision reset),
    /// so the button is hidden and the question is asked again.
    public var hasSavedLogin: Bool {
        // Purge first: the production exists() already reports an invalidated item as absent, which would
        // otherwise leave the dead item and the "saved" answer behind.
        if purgeIfInvalidated() { return false }
        return keychain.exists()
    }

    /// Deletes the item and resets the decision when the biometric set changed. True if it purged.
    @discardableResult
    public func purgeIfInvalidated() -> Bool {
        // Only a saved login can be invalidated; with another answer there is nothing to purge and a
        // "no" must not be turned back into a question.
        guard decision == .saved, keychain.isInvalidated() else { return false }
        keychain.delete()
        decision = .unasked
        return true
    }

    /// Stores (replacing) and records the "saved" answer. False when the Keychain refused.
    @discardableResult
    public func save(_ login: SavedLogin) -> Bool {
        guard let data = Self.encode(login) else { return false }
        guard keychain.write(data) else { return false }
        decision = .saved
        return true
    }

    /// After a sign-in or a password change: when the person already said yes, the stored value follows
    /// the new password. Does nothing otherwise.
    public func updateIfSaved(_ login: SavedLogin) {
        // An item made unusable by a changed biometric set is not re-saved silently: the decision goes
        // back to undecided and the caller asks again.
        if purgeIfInvalidated() { return }
        guard decision == .saved else { return }
        if !save(login) {
            // The write failed: an old password must not stay behind.
            keychain.delete()
            decision = .unasked
        }
    }

    public func decline() {
        keychain.delete()
        decision = .declined
    }

    /// Turns the feature back on after a "no": the next sign-in or password change asks again.
    public func resetDecision() {
        keychain.delete()
        decision = .unasked
    }

    /// Account deletion, remote wipe, account locked, or a saved password the server no longer accepts.
    /// A normal sign-out does NOT call this: the saved login is what "Accedi con Face ID" uses afterwards.
    public func deleteAll() {
        keychain.delete()
        defaults.removeObject(forKey: Self.decisionKey)
    }

    /// Reads the item. In production this shows the Face ID / Touch ID prompt.
    public func load(reason: String) -> SavedLoginReadResult {
        if purgeIfInvalidated() { return .notFound }
        let (data, authFailed) = keychain.read(reason: reason)
        if authFailed { return .notAuthenticated }
        guard let data else { return .notFound }
        guard let login = Self.decode(data) else {
            // Unreadable content is as good as no item: drop it so the screen stops offering it.
            keychain.delete()
            return .notFound
        }
        return .found(login)
    }

    // MARK: - Encoding

    private struct Stored: Codable {
        let e: String
        let p: String
    }

    static func encode(_ login: SavedLogin) -> Data? {
        try? JSONEncoder().encode(Stored(e: login.extensionNumber, p: login.password))
    }

    static func decode(_ data: Data) -> SavedLogin? {
        guard let s = try? JSONDecoder().decode(Stored.self, from: data),
              !s.e.isEmpty, !s.p.isEmpty else { return nil }
        return SavedLogin(extensionNumber: s.e, password: s.p)
    }
}

/// What the device can do for the biometric lock: which one, if any.
public enum SavedLoginBiometry: Equatable, Sendable {
    case none
    case faceID
    case touchID

    /// The biometry available right now, `.none` when there is none enrolled.
    public static func current() -> SavedLoginBiometry {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
        #else
        return .none
        #endif
    }

    /// The system's own name for it (not translated, like the system settings).
    public var displayName: String {
        switch self {
        case .none: return ""
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        }
    }
}

/// The production Keychain item: generic password, biometry-protected.
public final class SystemSavedLoginKeychain: SavedLoginKeychain {
    private let service = "com.bcrypto.qaudion.saved-login"
    private let account = "extension_password"
    private let stateAccount = "biometric_domain_state"

    public init() {}

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func write(_ data: Data) -> Bool {
        delete()
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &error
        ) else { return false }
        var q = base
        q[kSecAttrAccessControl as String] = access
        q[kSecValueData as String] = data
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
        storeDomainState()
        return true
    }

    private var stateBase: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: stateAccount]
    }

    /// The biometric set at save time, kept in a plain (non-biometric) item so it can be compared silently.
    private func storeDomainState() {
        SecItemDelete(stateBase as CFDictionary)
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err),
              let state = context.evaluatedPolicyDomainState else { return }
        var q = stateBase
        q[kSecValueData as String] = state
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
        #endif
    }

    private func storedDomainState() -> Data? {
        var q = stateBase
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public func isInvalidated() -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        var err: NSError?
        let can = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        let notEnrolled = !can && (err?.code == LAError.biometryNotEnrolled.rawValue)
        return BiometrySetCheck.isInvalidated(
            stored: storedDomainState(),
            current: can ? context.evaluatedPolicyDomainState : nil,
            notEnrolled: notEnrolled)
        #else
        return false
        #endif
    }

    public func read(reason: String) -> (data: Data?, authenticationFailed: Bool) {
        var q = base
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.localizedReason = reason
        q[kSecUseAuthenticationContext as String] = context
        #endif
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return (item as? Data, false)
        case errSecItemNotFound:
            return (nil, false)
        case errSecUserCanceled, errSecAuthFailed:
            return (nil, true)
        default:
            // Biometry changed or removed (the item is permanently unusable), or any other failure.
            return (nil, false)
        }
    }

    public func exists() -> Bool {
        var q = base
        q[kSecReturnAttributes as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        #endif
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecInteractionNotAllowed else { return false }
        return !isInvalidated()
    }

    public func delete() {
        SecItemDelete(base as CFDictionary)
        SecItemDelete(stateBase as CFDictionary)
    }
}
