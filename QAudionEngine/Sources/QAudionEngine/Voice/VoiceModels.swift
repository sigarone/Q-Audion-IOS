import Foundation

/// Overwrites a buffer with zeros in a way that the optimizer may not remove.
enum VoiceWipe {
    static func floats(_ values: inout [Float]) {
        values.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 {
                _ = memset_s(base, raw.count, 0, raw.count)
            }
        }
    }

    static func int16s(_ values: inout [Int16]) {
        values.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 {
                _ = memset_s(base, raw.count, 0, raw.count)
            }
        }
    }
}

/// The speech model of the call with the time of its last inference (every voice-model inference counts in the budget).
final class TimedSileroVad: TimedVadModel {
    private let inner: VoiceVadModel
    private let clock: () -> Int64
    private(set) var lastCostNs: Int64 = 0

    init(_ inner: VoiceVadModel, clock: @escaping () -> Int64 = VoiceClock.nowNs) {
        self.inner = inner
        self.clock = clock
    }

    func reset() {
        inner.reset()
    }

    func step(_ chunk: [Float]) throws -> Float {
        let started = clock()
        let p = try inner.step(chunk)
        lastCostNs = max(0, clock() - started)
        return p
    }
}

/// The speaker model for the engine: the filter bank of the window, the model run, the time it took. The model stays under the
/// rules of the other voice work: it does not run while the protected data is unreadable (the phone is locked: the model files
/// are mapped from storage) and it is held back by the CPU governor in the background. A window that is not embedded for either
/// reason is dropped like a model failure.
///
/// The features are wiped after the run, and the engine wipes the window's samples.
final class CamPlusWindowEmbedder: VoiceWindowEmbedder {
    private let fbank: VoiceFbank
    private let model: VoiceEmbedder
    private let protectedData: ProtectedDataFlag
    private let governor: BackgroundCpuGovernor?
    private let clock: () -> Int64

    init(fbank: VoiceFbank, model: VoiceEmbedder, protectedData: ProtectedDataFlag = .shared,
         governor: BackgroundCpuGovernor? = BackgroundCpuGovernor(flag: .shared), clock: @escaping () -> Int64 = VoiceClock.nowNs) {
        self.fbank = fbank
        self.model = model
        self.protectedData = protectedData
        self.governor = governor
        self.clock = clock
    }

    func embed(window: VoiceWindowResult) throws -> VoiceEmbedding? {
        guard protectedData.isAvailable else { return nil }
        if let governor, !governor.decide().run { return nil }
        let started = clock()
        var features = fbank.fbank(window.samples)
        defer { VoiceWipe.floats(&features) }
        let raw = try model.embed(fbank: features)
        let cost = max(0, clock() - started)
        guard let raw else { return nil }
        return VoiceEmbedding(raw: raw.raw, costNs: cost)
    }
}
