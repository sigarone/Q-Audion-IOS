import Foundation

public final class RespiratoryAnalyzer {
    private var energyHistory: [Float] = []
    private let windowSize = 250  // ~5 seconds at 50fps

    public init() {}

    /// Analyze respiratory pattern from PCM. Returns coherence score [0,1].
    public func analyze(pcmFrame: Data) -> Float {
        let energy = computeEnergy(pcmFrame)
        energyHistory.append(energy)
        if energyHistory.count > windowSize { energyHistory.removeFirst() }
        guard energyHistory.count >= 50 else { return 0.5 }
        // Detect periodic breathing pattern via autocorrelation peak
        let periodicity = detectPeriodicity(energyHistory)
        return periodicity
    }

    public func reset() { energyHistory.removeAll() }

    private func computeEnergy(_ data: Data) -> Float {
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<(data.count / 2) { let s = Float(ptr[i]); sum += s * s }
        }
        return sum / max(1, Float(data.count / 2))
    }

    private func detectPeriodicity(_ signal: [Float]) -> Float {
        let n = signal.count
        guard n > 20 else { return 0.5 }
        let mean = signal.reduce(0, +) / Float(n)
        var maxCorr: Float = 0
        for lag in 10..<(n / 2) {
            var corr: Float = 0
            for i in 0..<(n - lag) { corr += (signal[i] - mean) * (signal[i + lag] - mean) }
            corr /= Float(n - lag)
            maxCorr = max(maxCorr, corr)
        }
        let variance = signal.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(n)
        return variance > 0 ? min(1, maxCorr / variance) : 0.5
    }
}
