import Foundation
import SwiftUI
import QAudionEngine

enum CallState: String {
    case idle
    case connecting
    case ringing
    case active
    case ended
}

@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isInCall: Bool = false
    @Published var callState: CallState = .idle
    @Published var currentUserId: String?
    @Published var deepfakeAlert: Bool = false
    @Published var errorMessage: String?

    var engine: QAudionEngine?
    let authService = AuthService()
    let callService = CallService()

    private let defaultServerUrl = "https://api.qaudion.com"

    func initialize() {
        let config = EngineConfig.production()
        let engine = QAudionEngine(config: config)
        do {
            try engine.initialize()
            self.engine = engine
        } catch {
            errorMessage = "Engine initialization failed: \(error.localizedDescription)"
            return
        }

        callService.onDeepfakeAlert = { [weak self] isAlert in
            Task { @MainActor in
                self?.deepfakeAlert = isAlert
            }
        }

        if let token = authService.loadToken() {
            let backendConfig = BackendConfig(serverUrl: defaultServerUrl, accessToken: token)
            let rest = BCryptoRestClient(config: backendConfig)
            let accountApi = BCryptoAccountApiImpl(rest: rest)
            Task {
                do {
                    let profile = try await accountApi.getProfile()
                    self.currentUserId = profile.userId
                    self.isAuthenticated = true
                } catch {
                    authService.clearToken()
                    self.isAuthenticated = false
                }
            }
        }
    }

    func login(userId: String, credential: String) async {
        do {
            let token = try await authService.login(
                userId: userId, credential: credential, serverUrl: defaultServerUrl
            )
            authService.saveToken(token)
            currentUserId = userId
            isAuthenticated = true
            errorMessage = nil
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    func logout() {
        authService.clearToken()
        engine?.destroySession()
        engine?.release()
        engine = nil
        currentUserId = nil
        isAuthenticated = false
        callState = .idle
        isInCall = false
        deepfakeAlert = false
    }

    func startCall(contactId: String) async {
        guard let engine = engine else {
            errorMessage = "Engine not available"
            return
        }
        callState = .connecting
        isInCall = true
        do {
            try callService.startCall(engine: engine, contactId: contactId)
            callState = .active
        } catch {
            callState = .ended
            isInCall = false
            errorMessage = "Call failed: \(error.localizedDescription)"
        }
    }

    func endCall() {
        callService.endCall()
        callState = .ended
        isInCall = false
        deepfakeAlert = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.callState = .idle
        }
    }
}
