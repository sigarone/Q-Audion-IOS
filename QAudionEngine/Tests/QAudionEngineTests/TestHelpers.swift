import Foundation

/// Shared test utilities for generating synthetic PCM audio data.
enum TestAudioHelpers {
    /// Generate PCM Int16 data of a pure sine wave.
    static func makeSinePCM(frequency: Float, sampleCount: Int, sampleRate: Float = 48000, amplitude: Float = 0.8) -> Data {
        var data = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            let sample = Int16(amplitude * 32767.0 * sin(2.0 * .pi * frequency * Float(i) / sampleRate))
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Generate random noise PCM data.
    static func makeRandomPCM(sampleCount: Int) -> Data {
        var data = Data(count: sampleCount * 2)
        data.withUnsafeMutableBytes { buffer in
            for i in 0..<sampleCount {
                let sample = Int16.random(in: -16384...16384)
                buffer.storeBytes(of: sample.littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
        }
        return data
    }

    /// Generate silent PCM data (all zeros).
    static func makeSilentPCM(sampleCount: Int) -> Data {
        return Data(count: sampleCount * 2)
    }
}
