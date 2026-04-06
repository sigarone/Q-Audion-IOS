import Foundation

public final class CallRouter: @unchecked Sendable {
    public struct CallSession {
        public let callId: String
        public let remoteId: String
        public let backend: BackendProvider
        public let sendOpaque: (Data) async throws -> Void
        public var isActive: Bool
    }

    private let lock = NSLock()
    private let selectionPolicy = BackendSelectionPolicy()
    private var activeSessions: [String: CallSession] = [:]
    public var onIncomingCall: ((String, String, BackendProvider) -> Void)?

    public init() {}

    public func initiateCall(remoteId: String) throws -> CallSession {
        guard let backend = selectionPolicy.selectBackend(for: remoteId) else {
            throw CallRouterError.noBackendAvailable
        }
        let callId = UUID().uuidString
        let session = CallSession(
            callId: callId, remoteId: remoteId, backend: backend,
            sendOpaque: { data in try await backend.callingApi.sendOpaqueMessage(recipientId: remoteId, data: data) },
            isActive: true
        )
        lock.lock(); activeSessions[callId] = session; lock.unlock()
        return session
    }

    public func endCall(callId: String) {
        lock.lock()
        activeSessions[callId]?.isActive = false
        activeSessions.removeValue(forKey: callId)
        lock.unlock()
    }

    public func getActiveSession(callId: String) -> CallSession? {
        lock.lock(); defer { lock.unlock() }; return activeSessions[callId]
    }

    public func getSelectionPolicy() -> BackendSelectionPolicy { selectionPolicy }
}

public enum CallRouterError: Error { case noBackendAvailable }
