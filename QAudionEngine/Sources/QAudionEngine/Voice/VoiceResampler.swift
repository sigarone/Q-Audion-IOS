import Foundation

/// Streaming rational polyphase FIR resampler to 16 kHz for 24, 32 and 48 kHz input (16 kHz is passed through).
///
/// The output depends only on the sample stream: the history is carried from one sample to the next, so no block
/// boundary matters. The sum for every output runs in float32 with the taps in ascending order, one rounded product at
/// a time.
final class VoiceResampler {
    static let supportedRates: [Int] = [16_000, 24_000, 32_000, 48_000]

    let rate: Int
    /// Interpolation factor, decimation factor and prototype length (1, 1, 1 for the pass-through).
    let upFactor: Int
    let downFactor: Int
    let prototypeLength: Int

    private let passThrough: Bool
    private let taps: [Float]
    private let span: Int
    private let ringSize: Int
    private var ring: [Float]
    private var head = 0
    private var consumed = 0
    private var nextOutput = 0

    init?(rate: Int, constants: VoiceConstants) {
        var up = 1
        var down = 1
        var length = 1
        var tapValues: [Float] = []
        let pass = rate == 16_000
        if !pass {
            guard let filter = constants.resampler.filters[String(rate)] else { return nil }
            up = filter.L
            down = filter.M
            length = filter.taps.count
            guard up > 0, down > 0, length > 0, length % up == 0 else { return nil }
            tapValues = filter.taps.map { Float($0) }
        }
        self.rate = rate
        self.upFactor = up
        self.downFactor = down
        self.prototypeLength = length
        self.passThrough = pass
        self.taps = tapValues
        self.span = length / up
        let size = pass ? 1 : length / up + 2
        self.ringSize = size
        self.ring = [Float](repeating: 0, count: size)
    }

    /// Input samples consumed since the last reset.
    var inputCount: Int { consumed }

    /// Zeroes the history and restarts the decimation phase.
    func reset() {
        for i in 0..<ring.count {
            ring[i] = 0
        }
        head = 0
        consumed = 0
        nextOutput = 0
    }

    /// Consumes one input sample; returns the output sample that it completes, if any (at most one per input).
    func push(_ sample: Int16) -> Float? {
        let x = Float(Int32(sample)) / 32_768.0
        consumed += 1
        if passThrough {
            nextOutput = consumed
            return x
        }
        head += 1
        if head == ringSize {
            head = 0
        }
        ring[head] = x
        let m = nextOutput
        if m * downFactor >= upFactor * consumed {
            return nil
        }
        nextOutput = m + 1
        var tapIndex = (m * downFactor) % upFactor
        var ringIndex = head
        let step = upFactor
        let last = ringSize - 1
        let history = ring
        var acc: Float = 0
        for _ in 0..<span {
            acc += taps[tapIndex] * history[ringIndex]
            tapIndex += step
            ringIndex = ringIndex == 0 ? last : ringIndex - 1
        }
        return acc
    }
}
