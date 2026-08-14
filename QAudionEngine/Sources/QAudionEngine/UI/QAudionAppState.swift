import SwiftUI
import Combine
#if canImport(Security)
import Security
#endif

/// Central app state coordinator matching Android's ViewModel pattern.
/// Manages auth flow, backend connection, and UI state.
public final class QAudionAppState: ObservableObject {

    public enum AuthState: Equatable {
        case loading
        case welcome
        case login
        case sovereignSetup
        case authenticated
    }

    // MARK: - Published State

    @Published public var authState: AuthState = .loading
    @Published public var conversations: [ConversationItem] = []
    @Published public var callHistory: [CallHistoryItem] = []
    @Published public var contacts: [ContactItem] = []
    @Published public var totalUnread: Int = 0
    @Published public var showContactDiscovery: Bool = false
    @Published public var errorMessage: String?

    // MARK: - Backend

    public private(set) var backend: BCryptoBackendProvider?
    private var config: BackendConfig

    public init(serverUrl: String = "https://voip.bcrypto.com") {
        self.config = BackendConfig(serverUrl: serverUrl)
        checkExistingAuth()
    }

    // MARK: - Auth Flow

    private func checkExistingAuth() {
        // Check if we have stored credentials
        if let token = loadStoredToken() {
            config.accessToken = token.accessToken
            config.refreshToken = token.refreshToken
            config.userId = token.userId
            config.deviceId = token.deviceId
            initializeBackend()
            authState = .authenticated
        } else if SovereignIdentityManager().hasSovereignIdentity() {
            authState = .login
        } else {
            authState = .welcome
        }
    }

    /// Register with phone number + password.
    public func register(phoneNumber: String, password: String, inviteCode: String? = nil, displayName: String? = nil) async {
        do {
            let tempBackend = BCryptoBackendProvider(config: config)
            _ = try await tempBackend.accountApi.register(
                phoneNumber: phoneNumber,
                password: password,
                inviteCode: inviteCode,
                displayName: displayName
            )
            let phoneHash = try PhoneHash.hash(phoneNumber)
            // Auto-login after registration
            let creds = try await tempBackend.accountApi.login(phoneHash: phoneHash, password: password, deviceName: deviceName())
            saveCredentials(creds)
            config.accessToken = creds.accessToken
            config.refreshToken = creds.refreshToken
            config.userId = creds.userId
            config.deviceId = creds.deviceId
            initializeBackend()
            await MainActor.run { authState = .authenticated }
        } catch {
            await MainActor.run { errorMessage = "Registration failed: \(error.localizedDescription)" }
        }
    }

    /// Login with phone hash + password.
    public func login(phoneNumber: String, password: String) async {
        do {
            let tempBackend = BCryptoBackendProvider(config: config)
            let phoneHash = try PhoneHash.hash(phoneNumber)
            let creds = try await tempBackend.accountApi.login(phoneHash: phoneHash, password: password, deviceName: deviceName())
            saveCredentials(creds)
            config.accessToken = creds.accessToken
            config.refreshToken = creds.refreshToken
            config.userId = creds.userId
            config.deviceId = creds.deviceId
            initializeBackend()
            await MainActor.run { authState = .authenticated }
        } catch {
            await MainActor.run { errorMessage = "Login failed: \(error.localizedDescription)" }
        }
    }

    /// Sovereign identity registration.
    public func registerSovereign(displayName: String?) async {
        do {
            let mgr = SovereignIdentityManager()
            let identity = mgr.generateIdentity(serverUrl: config.serverUrl, displayName: displayName)
            let tempBackend = BCryptoBackendProvider(config: config)
            let (userId, challenge) = try await mgr.registerWithServer(identity: identity, rest: tempBackend.getRestClient())
            // Sign challenge
            let challengeData = Data(hex: challenge)
            let updatedIdentity = SovereignIdentityManager.SovereignIdentity(
                userId: userId,
                encryptionPrivate: identity.encryptionPrivate,
                encryptionPublic: identity.encryptionPublic,
                signingPrivate: identity.signingPrivate,
                signingPublic: identity.signingPublic,
                serverUrl: identity.serverUrl,
                displayName: identity.displayName,
                identityType: identity.identityType
            )
            let signature = try mgr.signChallenge(challengeData, identity: updatedIdentity)
            let creds = try await mgr.verifySovereignRegistration(userId: userId, signature: signature, rest: tempBackend.getRestClient())
            try mgr.saveIdentity(updatedIdentity)
            saveCredentials(creds)
            config.accessToken = creds.accessToken
            config.userId = creds.userId
            config.deviceId = creds.deviceId
            initializeBackend()
            await MainActor.run { authState = .authenticated }
        } catch {
            await MainActor.run { errorMessage = "Sovereign registration failed: \(error.localizedDescription)" }
        }
    }

    /// Logout and clear state.
    public func logout() async {
        try? await backend?.accountApi.logout()
        backend?.shutdown()
        backend = nil
        clearCredentials()
        await MainActor.run {
            authState = .welcome
            conversations = []
            callHistory = []
            contacts = []
            totalUnread = 0
        }
    }

    // MARK: - Backend Initialization

    private func initializeBackend() {
        backend = BCryptoBackendProvider(config: config)
        Task {
            try? await backend?.initialize()
            await loadContacts()
        }
    }

    public func loadContacts() async {
        guard let api = backend?.contactsApi else { return }
        do {
            let discovered = try await api.listContacts()
            await MainActor.run {
                contacts = discovered.map { c in
                    ContactItem(id: c.userId, displayName: c.displayName ?? c.userId, trustLevel: .tofu)
                }
            }
        } catch { /* silently fail */ }
    }

    // MARK: - Token Persistence (Keychain, sensitive)
    //
    // SEC-ENGINE-2 (2026-08-14) — this was UserDefaults (plaintext .plist,
    // readable from an unencrypted backup/jailbreak/file-system access).
    // QAudionEngine is a Swift Package the QAudionApp target depends on, not
    // the other way around, so this cannot import/call QAudionApp's own
    // TokenVault (the real app's single source of truth for auth tokens) —
    // that would be a backwards package dependency. This is therefore a
    // deliberately SEPARATE Keychain store, under its own service string
    // (never TokenVault's "com.qaudion.auth"), specifically so that if this
    // view-model is ever wired up again, `clearCredentials()`/
    // `loadStoredToken()` here can never read, overwrite, or delete
    // TokenVault's real session tokens by account-name collision.
    //
    // QAudionRootView, the only place that constructs this class, has zero
    // instantiations anywhere in the shipped app today (QAudionApp.swift's
    // real @main uses a different AppState + ContentView) — so this closes
    // a real defense-in-depth gap without being on any live user's path.

    private let authKeychainService = "com.qaudion.engine.qaudionappstate.auth"
    private let accessAccount = "access_token"
    private let refreshAccount = "refresh_token"
    private let userIdAccount = "user_id"
    private let deviceIdAccount = "device_id"

    private func saveCredentials(_ creds: AuthCredentials) {
        saveToKeychain(account: accessAccount, value: creds.accessToken)
        if let refresh = creds.refreshToken {
            saveToKeychain(account: refreshAccount, value: refresh)
        } else {
            // Preserve the original UserDefaults.set(nil, ...) behavior: no
            // refresh token means any previously-stored one is stale and
            // must be cleared, not silently left in place.
            deleteFromKeychain(account: refreshAccount)
        }
        saveToKeychain(account: userIdAccount, value: creds.userId)
        saveToKeychain(account: deviceIdAccount, value: creds.deviceId)
    }

    private func loadStoredToken() -> AuthCredentials? {
        guard let token = loadFromKeychain(account: accessAccount),
              let userId = loadFromKeychain(account: userIdAccount) else { return nil }
        return AuthCredentials(
            userId: userId,
            deviceId: loadFromKeychain(account: deviceIdAccount) ?? "",
            accessToken: token,
            refreshToken: loadFromKeychain(account: refreshAccount),
            expiresIn: nil
        )
    }

    private func clearCredentials() {
        deleteFromKeychain(account: accessAccount)
        deleteFromKeychain(account: refreshAccount)
        deleteFromKeychain(account: userIdAccount)
        deleteFromKeychain(account: deviceIdAccount)
    }

    // MARK: - Keychain primitives

    private func baseQuery(account: String) -> [String: Any] {
        #if canImport(Security)
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: authKeychainService,
            kSecAttrAccount as String: account
        ]
        #else
        return [:]
        #endif
    }

    private func saveToKeychain(account: String, value: String) {
        #if canImport(Security)
        guard let data = value.data(using: .utf8) else { return }
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            for (k, v) in attributes { query[k] = v }
            SecItemAdd(query as CFDictionary, nil)
            return
        }
        // Any other status (e.g. duplicate after a race): hard-reset the
        // item so the value is never left stale.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var addQuery = baseQuery(account: account)
        for (k, v) in attributes { addQuery[k] = v }
        SecItemAdd(addQuery as CFDictionary, nil)
        #endif
    }

    private func loadFromKeychain(account: String) -> String? {
        #if canImport(Security)
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    private func deleteFromKeychain(account: String) {
        #if canImport(Security)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        #endif
    }

    private func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iOS Device"
        #endif
    }
}

// MARK: - Hex Data Extension

private extension Data {
    init(hex: String) {
        self.init()
        var hex = hex
        while hex.count >= 2 {
            let pair = String(hex.prefix(2))
            hex = String(hex.dropFirst(2))
            if let byte = UInt8(pair, radix: 16) {
                append(byte)
            }
        }
    }
}
