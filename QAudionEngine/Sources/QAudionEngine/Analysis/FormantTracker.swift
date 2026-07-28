import Foundation

public final class FormantTracker {
    public init() {}

    public func extract(pcmFrame: Data) -> VoiceAnalysisResult.Formants {
        let samples = pcmToFloat(pcmFrame)
        guard samples.count >= 256 else { return VoiceAnalysisResult.Formants(f1: 0, f2: 0, f3: 0, f4: 0) }
        // Simplified LPC-based formant estimation
        let lpcOrder = 12
        let coeffs = computeLPC(samples, order: lpcOrder)
        let roots = findFormantFrequencies(coeffs, sampleRate: 48000)
        return VoiceAnalysisResult.Formants(
            f1: !roots.isEmpty ? roots[0] : 0,
            f2: roots.count > 1 ? roots[1] : 0,
            f3: roots.count > 2 ? roots[2] : 0,
            f4: roots.count > 3 ? roots[3] : 0
        )
    }

    private func computeLPC(_ samples: [Float], order: Int) -> [Float] {
        // Levinson-Durbin autocorrelation method (simplified)
        var r = [Float](repeating: 0, count: order + 1)
        for k in 0...order {
            for i in 0..<(samples.count - k) { r[k] += samples[i] * samples[i + k] }
        }
        guard r[0] > 0 else { return [Float](repeating: 0, count: order) }
        var a = [Float](repeating: 0, count: order)
        var e = r[0]
        for i in 0..<order {
            var lambda: Float = 0
            for j in 0..<i { lambda += a[j] * r[i - j] }
            lambda = (r[i + 1] - lambda) / e
            a[i] = lambda
            for j in 0..<(i / 2) {
                let tmp = a[j]; a[j] += lambda * a[i - 1 - j]; a[i - 1 - j] += lambda * tmp
            }
            if i % 2 == 0 { a[i / 2] += lambda * a[i / 2] }
            e *= (1 - lambda * lambda)
        }
        return a
    }

    private func findFormantFrequencies(_ lpc: [Float], sampleRate: Int) -> [Float] {
        // Simplified: evaluate LPC spectrum and find peaks
        let nfft = 256
        var spectrum = [Float](repeating: 0, count: nfft)
        for k in 0..<nfft {
            let freq = Float(k) * Float(sampleRate) / Float(nfft * 2)
            var real: Float = 1; var imag: Float = 0
            for i in 0..<lpc.count {
                let angle = -2.0 * Float.pi * freq * Float(i + 1) / Float(sampleRate)
                real -= lpc[i] * cos(angle); imag -= lpc[i] * sin(angle)
            }
            spectrum[k] = 1.0 / max(0.001, sqrt(real * real + imag * imag))
        }
        // Find peaks
        var peaks: [(freq: Float, mag: Float)] = []
        for k in 1..<(nfft - 1) {
            if spectrum[k] > spectrum[k-1] && spectrum[k] > spectrum[k+1] {
                let freq = Float(k) * Float(sampleRate) / Float(nfft * 2)
                if freq > 200 && freq < 5000 { peaks.append((freq, spectrum[k])) }
            }
        }
        peaks.sort { $0.freq < $1.freq }
        return peaks.prefix(4).map { $0.freq }
    }

    private func pcmToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(ptr[i]) / 32768.0 }
        }
        return floats
    }
}
