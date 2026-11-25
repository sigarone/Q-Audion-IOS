import Foundation

/// `constants.cpu`: the process-wide budget and the pending list.
struct VoiceCpuConstants: Decodable, Equatable {
    /// The share of one core that all voice-model inference in the process may use over the window.
    var budgetTotalCore: Double
    var windowS: Int
    /// The most windows that may wait for the budget; one more drops one of them.
    var maxPending: Int
    /// The wall time that the end-of-call embeddings of the pending windows may take.
    var postCallMaxS: Int
}

/// The part of `constants.json` that only the engine orchestration reads: `cpu`, and the cap of speech that one call may add to
/// a template (`update.max_speech_ms`). The other sections have their own types (`VoiceConstants`, `VoiceScoringConstants`,
/// `VoiceStateConstants`).
struct VoiceEngineConstants: Equatable {
    var cpu: VoiceCpuConstants
    var updateMaxSpeechMs: Int

    private struct File: Decodable {
        struct Update: Decodable {
            var maxSpeechMs: Int
        }

        var cpu: VoiceCpuConstants
        var update: Update
    }

    static func parse(_ data: Data) throws -> VoiceEngineConstants {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file: File
        do {
            file = try decoder.decode(File.self, from: data)
        } catch {
            throw VoiceBundleError.malformed("constants.json: \(error)")
        }
        let c = file.cpu
        guard c.budgetTotalCore > 0, c.budgetTotalCore.isFinite, c.windowS > 0, c.maxPending >= 1, c.postCallMaxS >= 0 else {
            throw VoiceBundleError.malformed("constants.json: cpu")
        }
        guard file.update.maxSpeechMs >= 32 else {
            throw VoiceBundleError.malformed("constants.json: update.max_speech_ms")
        }
        return VoiceEngineConstants(cpu: c, updateMaxSpeechMs: file.update.maxSpeechMs)
    }
}
