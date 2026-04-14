import SwiftUI
import Combine

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

    /// Register with phone number.
    public func register(phoneNumber: String, inviteCode: String?) async {
        do {
            let tempBackend = BCryptoBackendProvider(config: config)
            let userId = try await tempBackend.accountApi.register(phoneNumber: phoneNumber, inviteCode: inviteCode)
            let phoneHash = BCryptoAccountApiImpl.hashPhone(phoneNumber)
            // Auto-login after registration
            let creds = try await tempBackend.accountApi.login(phoneHash: phoneHash, password: inviteCode ?? "", deviceName: deviceName())
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
            let phoneHash = BCryptoAccountApiImpl.hashPhone(phoneNumber)
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
            var updatedIdentity = SovereignIdentityManager.SovereignIdentity(
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

    // MARK: - Token Persistence (UserDefaults, non-sensitive)

    private func saveCredentials(_ creds: AuthCredentials) {
        UserDefaults.standard.set(creds.accessToken, forKey: "qaudion_access_token")
        UserDefaults.standard.set(creds.refreshToken, forKey: "qaudion_refresh_token")
        UserDefaults.standard.set(creds.userId, forKey: "qaudion_user_id")
        UserDefaults.standard.set(creds.deviceId, forKey: "qaudion_device_id")
    }

    private func loadStoredToken() -> AuthCredentials? {
        guard let token = UserDefaults.standard.string(forKey: "qaudion_access_token"),
              let userId = UserDefaults.standard.string(forKey: "qaudion_user_id") else { return nil }
        return AuthCredentials(
            userId: userId,
            deviceId: UserDefaults.standard.string(forKey: "qaudion_device_id") ?? "",
            accessToken: token,
            refreshToken: UserDefaults.standard.string(forKey: "qaudion_refresh_token"),
            expiresIn: nil
        )
    }

    private func clearCredentials() {
        UserDefaults.standard.removeObject(forKey: "qaudion_access_token")
        UserDefaults.standard.removeObject(forKey: "qaudion_refresh_token")
        UserDefaults.standard.removeObject(forKey: "qaudion_user_id")
        UserDefaults.standard.removeObject(forKey: "qaudion_device_id")
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
