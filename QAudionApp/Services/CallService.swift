import Foundation
import QAudionEngine

final class CallService {
    var callIntegration: QAudionCallIntegration?
    var onDeepfakeAlert: ((Bool) -> Void)?
    var onDeepfakeScore: ((ConfidenceIndex.Level, Float) -> Void)?
    var onTxWaveformUpdate: (([Float]) -> Void)?
    var onRxWaveformUpdate: (([Float]) -> Void)?
    var onCipherWaveformUpdate: (([Float]) -> Void)?

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
            self.onDeepfakeScore?(level, score)
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
        let encrypted = try integration.processOutgoingAudio(pcmFrame: pcmFrame)

        // Update TX waveform from raw PCM
        let txSamples = updateWaveformSamples(from: pcmFrame)
        onTxWaveformUpdate?(txSamples)

        // Update cipher waveform from encrypted output
        let cipherSamples = updateCipherSamples(from: encrypted)
        onCipherWaveformUpdate?(cipherSamples)

        return encrypted
    }

    func processIncomingAudio(frame: Data) throws -> Data {
        guard let integration = callIntegration else {
            throw CallServiceError.noActiveCall
        }
        let pcm = try integration.processIncomingAudio(serializedFrame: frame)

        // Update RX waveform from decoded PCM
        let rxSamples = updateWaveformSamples(from: pcm)
        onRxWaveformUpdate?(rxSamples)

        return pcm
    }

    // MARK: - Waveform Helpers

    /// Converts PCM Int16 data to a normalized Float array suitable for waveform display.
    /// Each sample is divided by 32768.0 to produce values in the range [-1.0, 1.0].
    func updateWaveformSamples(from pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: sampleCount)
        pcmData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                samples[i] = Float(int16Buffer[i]) / 32768.0
            }
        }
        return samples
    }

    /// Takes encrypted frame bytes and normalizes them as Float values for the cipher waveform.
    /// Each byte is mapped from [0, 255] to [-1.0, 1.0] to visualize the encrypted stream.
    func updateCipherSamples(from encryptedData: Data) -> [Float] {
        guard !encryptedData.isEmpty else { return [] }
        var samples = [Float](repeating: 0, count: encryptedData.count)
        encryptedData.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for i in 0..<encryptedData.count {
                samples[i] = (Float(bytes[i]) / 127.5) - 1.0
            }
        }
        return samples
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
