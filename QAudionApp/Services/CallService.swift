import Foundation
import QAudionEngine

final class CallService {
    var callIntegration: QAudionCallIntegration?
    var onDeepfakeAlert: ((Bool) -> Void)?

    func startCall(engine: QAudionEngine, contactId: String) throws {
        let integration = QAudionCallIntegration()

        integration.onStateChanged = { [weak self] state in
            guard let self else { return }
            switch state {
            case .active:
                break
            case .error, .fallback:
                self.endCall()
            default:
                break
            }
        }

        integration.onDeepfakeAlert = { [weak self] level, score in
            guard let self else { return }
            let isAlert: Bool
            switch level {
            case .high, .critical:
                isAlert = true
            default:
                isAlert = false
            }
            self.onDeepfakeAlert?(isAlert)
        }

        try integration.onCallSetupStarted { data in
            // Transport layer sends opaque message to remote peer.
            // Actual network transport is handled by the signaling layer.
        }

        self.callIntegration = integration
    }

    func endCall() {
        callIntegration?.onCallEnded()
        callIntegration = nil
        onDeepfakeAlert?(false)
    }

    func processOutgoingAudio(pcmFrame: Data) throws -> Data {
        guard let integration = callIntegration else {
            throw CallServiceError.noActiveCall
        }
        return try integration.processOutgoingAudio(pcmFrame: pcmFrame)
    }

    func processIncomingAudio(frame: Data) throws -> Data {
        guard let integration = callIntegration else {
            throw CallServiceError.noActiveCall
        }
        return try integration.processIncomingAudio(serializedFrame: frame)
    }
}

enum CallServiceError: Error, LocalizedError {
    case noActiveCall
    case setupFailed

    var errorDescription: String? {
        switch self {
        case .noActiveCall: return "No active call session"
        case .setupFailed: return "Call setup failed"
        }
    }
}
