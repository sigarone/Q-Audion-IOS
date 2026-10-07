import Foundation

/// Builds the Tier 1 (`GuardianMode`) inference windows from decoded RX PCM.
///
/// W-GUARDIAN1CONTIG (2026-10-07). Every voiced chunk goes in, whole and in order, whatever its length (10 ms
/// native SRTP, 20 or 60 ms DataChannel), and a window is handed out each time `windowSamples` voiced samples
/// have accumulated. Windows do not overlap: a chunk that crosses the end of one window carries its remainder
/// into the next, so no voiced sample is dropped and none is scored twice. A window completes every
/// `windowSamples / 48 000` s (4.04 s) of voiced remote speech, on every transport; `GuardianMode` scores at most
/// one window per `GuardianMode.minVoicedMsBetweenInferences` (8 s) of it.
///
/// Before this, `GuardianMode` passed ONE chunk per 100 ms of audio to `VoiceprintAnalyzer`, which kept half of
/// each window for overlap: 50% of the audio at 60 ms chunks, 20% at 20 ms and 10% at the 10 ms chunks of native
/// SRTP, where the first score took 40 s of voiced speech (a 25-minute SRTP call of 2026-10-05: first Tier 1
/// update after 2 min 26 s, then one every ~68 s).
///
/// Silence (chunk RMS below `vadRmsThreshold`) contributes nothing: not to the window, not to the count, so it
/// can neither pull the score down nor trigger an inference. Pure value type, no clock, no model, no locks:
/// `GuardianMode` owns it under its own lock.
struct GuardianWindowAccumulator {

    /// 48 kHz input, 16 kHz model: the model's 64 600-sample input is 193 800 samples here (4.0375 s).
    static let defaultWindowSamples = ModelManager.modelInputLength * 3
    /// Same normalised-float RMS gate as `SpeakerVerifier.voiceActivityRmsThreshold` and the gate
    /// `VoiceprintAnalyzer` applied per analysed frame before (W-GUARDIANVAD).
    static let defaultVadRmsThreshold: Float = 360.0 / 32_768.0

    let windowSamples: Int
    let vadRmsThreshold: Float

    private var buffer: [Float]
    private var count = 0

    /// Voiced chunks taken in / silent chunks skipped since creation (diagnostics only).
    private(set) var voicedChunks = 0
    private(set) var silentChunks = 0

    init(windowSamples: Int = Self.defaultWindowSamples, vadRmsThreshold: Float = Self.defaultVadRmsThreshold) {
        precondition(windowSamples > 0, "a window must hold at least one sample")
        self.windowSamples = windowSamples
        self.vadRmsThreshold = vadRmsThreshold
        self.buffer = [Float](repeating: 0, count: windowSamples)
    }

    /// Voiced samples currently waiting for the next window.
    var pendingSamples: Int { count }

    /// Takes one chunk of little-endian Int16 mono PCM. Returns the windows it completed, in order: none for
    /// silence or a partial window, one in the ordinary case, more only if a single chunk is longer than a whole
    /// window. A trailing odd byte is ignored.
    mutating func append(int16LE pcm: Data) -> [[Float]] {
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return [] }

        // Two passes over the bytes, no temporary array per chunk: RMS first, then (voiced only) straight
        // into the window buffer.
        let sumSquares: Float = pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Float in
            var acc: Float = 0
            for i in 0..<sampleCount {
                let v = Self.sample(raw, i)
                acc += v * v
            }
            return acc
        }
        guard (sumSquares / Float(sampleCount)).squareRoot() >= vadRmsThreshold else {
            silentChunks += 1
            return []
        }
        voicedChunks += 1

        var windows: [[Float]] = []
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<sampleCount {
                buffer[count] = Self.sample(raw, i)
                count += 1
                if count == windowSamples {
                    windows.append(buffer)
                    count = 0
                }
            }
        }
        return windows
    }

    /// Sample `i` of little-endian Int16 bytes, as Float in [-1, 1). Byte-wise read: valid for any alignment
    /// of the backing storage.
    private static func sample(_ raw: UnsafeRawBufferPointer, _ i: Int) -> Float {
        let bits = UInt16(raw[2 * i]) | (UInt16(raw[2 * i + 1]) << 8)
        return Float(Int16(bitPattern: bits)) / 32_768.0
    }
}
